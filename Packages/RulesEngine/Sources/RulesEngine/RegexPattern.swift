import Foundation
import os

/// Time budget for one regular-expression match. A match that outlasts `maxDuration` is stopped
/// and counts as a strike; `maxStrikes` strikes disable the pattern.
public struct RegexBudget: Sendable {
    public var maxDuration: Duration
    /// Consecutive timeouts that disable a pattern; always at least 1, so a pattern gets to run.
    public var maxStrikes: Int { didSet { maxStrikes = max(1, maxStrikes) } }
    /// A monotonic clock; injectable so tests need no real time.
    public var clock: @Sendable () -> Duration

    public static let standard = RegexBudget()

    private static let origin = ContinuousClock.now
    public static let monotonicNow: @Sendable () -> Duration = {
        RegexBudget.origin.duration(to: ContinuousClock.now)
    }

    public init(
        maxDuration: Duration = .milliseconds(2),
        maxStrikes: Int = 3,
        clock: @escaping @Sendable () -> Duration = RegexBudget.monotonicNow
    ) {
        self.maxDuration = maxDuration
        self.maxStrikes = max(1, maxStrikes)
        self.clock = clock
    }
}

public enum RegexMatchResult: Sendable, Equatable {
    case matched, noMatch, timedOut, inputTooLong, disabled
}

/// Counts consecutive timeouts of one pattern. It is separate from `RegexPattern` so that the
/// state outlives a cache eviction: `PatternCache` keeps one per pattern text. Locked; the
/// lock is never held while a match runs.
public final class RegexBreaker: Sendable {
    private struct State {
        var strikes = 0
        /// Set when the streak reached its limit; only `reset()` clears it, so a match that began
        /// before the trip and finished in time cannot close the breaker again.
        var tripped = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let onTrip: (@Sendable () -> Void)?

    public init() { onTrip = nil }

    init(onTrip: @escaping @Sendable () -> Void) { self.onTrip = onTrip }

    /// Consecutive timeouts so far.
    public var count: Int { state.withLock { $0.strikes } }

    func isOpen(limit: Int) -> Bool { state.withLock { $0.strikes >= limit } }

    /// One more timeout. Reaching `limit` calls the trip observer once, outside the lock.
    func recordTimeout(limit: Int) {
        let tripped = state.withLock { state -> Bool in
            state.strikes += 1
            if state.strikes >= limit { state.tripped = true }
            return state.strikes == limit
        }
        if tripped { onTrip?() }
    }

    /// A match that finished within its budget ends the streak, unless the breaker already tripped.
    func recordCompletion() {
        state.withLock { state in if !state.tripped, state.strikes != 0 { state.strikes = 0 } }
    }

    public func reset() { state.withLock { $0 = State() } }
}

/// A whole-string (`\A(?:...)\z`) ICU regular expression that only runs under a time budget and
/// an input-length cap. Never match anything with `NSRegularExpression` outside this type.
///
/// The circuit breaker counts *consecutive* timeouts: a match that finishes in time resets the
/// count, so a pattern that is only occasionally slow stays enabled. `maxStrikes` in a row disable
/// it until `resetStrikes()` (saving the rule does that).
public final class RegexPattern: Sendable {
    public static let maxPatternBytes = 1024
    public static let maxInputBytes = 8192
    /// The default cap on what a replacement may produce.
    static let maxOutputBytes = 65_536

    /// `whole` anchors the pattern at both ends; `find` looks for it anywhere in the text.
    public enum Mode: Sendable, Hashable { case whole, find }

    private let expression: NSRegularExpression  // immutable and documented thread-safe
    private let mode: Mode
    private let budget: RegexBudget
    private let breaker: RegexBreaker

    public convenience init(
        _ pattern: String, caseInsensitive: Bool, budget: RegexBudget = .standard, breaker: RegexBreaker = RegexBreaker()
    ) throws {
        try self.init(pattern, mode: .whole, caseInsensitive: caseInsensitive, budget: budget, breaker: breaker)
    }

    public init(
        _ pattern: String, mode: Mode, caseInsensitive: Bool, budget: RegexBudget = .standard,
        breaker: RegexBreaker = RegexBreaker()
    ) throws {
        guard !pattern.isEmpty else { throw PatternError.empty }
        guard pattern.utf8.count <= Self.maxPatternBytes else { throw PatternError.tooLong }
        guard !RegexComplexity.isRisky(pattern) else { throw PatternError.regexTooComplex }
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        // The bare pattern must be valid on its own so it cannot escape the anchoring wrapper
        // (for example `a)(b`).
        guard let bare = try? NSRegularExpression(pattern: pattern, options: options) else {
            throw PatternError.invalidRegex
        }
        switch mode {
        case .find:
            self.expression = bare
        case .whole:
            guard let anchored = try? NSRegularExpression(pattern: "\\A(?:" + pattern + ")\\z", options: options) else {
                throw PatternError.invalidRegex
            }
            self.expression = anchored
        }
        self.mode = mode
        self.budget = budget
        self.breaker = breaker
    }

    public func matches(_ text: String) -> RegexMatchResult {
        run(text, limit: budget.maxDuration, allowanceBound: false)
    }

    /// A match against a message body: the pattern's own budget and breaker, no shared allowance, and the
    /// caller's input cap in place of the 8192-byte one (`PatternCache.bodyRegex` builds these).
    /// `maxDuration` holds one match below the budget; a timeout the cap caused is not a strike.
    func matchesBody(_ text: String, maxInputBytes: Int, maxDuration: Duration? = nil) -> RegexMatchResult {
        let capped = maxDuration.map { $0 < budget.maxDuration } ?? false
        return run(text, limit: capped ? maxDuration! : budget.maxDuration, allowanceBound: capped, inputCap: maxInputBytes)
    }

    /// Like `matches(_:)`, but the time also comes out of the exchange's shared `allowance`: one
    /// match gets at most the standard budget and at most what is left. A timeout caused by the
    /// allowance running out is not the pattern's fault, so it is not a strike.
    public func matches(_ text: String, allowance: RegexAllowance) -> RegexMatchResult {
        let limit: Duration, limited: Bool
        switch grantTime(for: text, from: allowance) {
        case .refused(let refusal): return refusal
        case .run(let granted, let isLimited): (limit, limited) = (granted, isLimited)
        }
        let started = allowance.now()
        let result = run(text, limit: limit, allowanceBound: limited)
        allowance.consume(allowance.now() - started)
        return result
    }

    private enum Grant {
        case run(limit: Duration, limited: Bool)
        case refused(RegexMatchResult)
    }

    /// The shared preamble of the allowance-bound runs: input cap, breaker, and how long one match may
    /// take (the standard budget, or what is left of the allowance when that is less).
    private func grantTime(for text: String, from allowance: RegexAllowance) -> Grant {
        guard text.utf8.count <= Self.maxInputBytes else { return .refused(.inputTooLong) }
        guard !breaker.isOpen(limit: budget.maxStrikes) else { return .refused(.disabled) }
        let remaining = allowance.remaining
        guard remaining > .zero else { return .refused(.timedOut) }
        let limited = remaining < budget.maxDuration
        return .run(limit: limited ? remaining : budget.maxDuration, limited: limited)
    }

    public enum ReplaceResult: Sendable, Equatable {
        case replaced(String)
        case noMatch, timedOut, inputTooLong, disabled
    }

    /// Replaces every match of a `find`-mode pattern, expanding `$1`-style templates. Budgeting and
    /// strikes follow `matches(_:allowance:)`: the time comes out of the exchange's shared `allowance`,
    /// and a timeout the allowance caused is not a strike. A replacement that would grow past `outputLimit`
    /// bytes (an empty-match pattern with a large template multiplies the text) stops and answers
    /// `inputTooLong`, as an oversized input does.
    func replacingMatches(
        in text: String, template: String, allowance: RegexAllowance, outputLimit: Int = RegexPattern.maxOutputBytes
    ) -> ReplaceResult {
        guard mode == .find else { return .noMatch }
        let limit: Duration, limited: Bool
        switch grantTime(for: text, from: allowance) {
        case .refused(let refusal):
            switch refusal {
            case .inputTooLong: return .inputTooLong
            case .disabled: return .disabled
            default: return .timedOut
            }
        case .run(let granted, let isLimited): (limit, limited) = (granted, isLimited)
        }
        let started = allowance.now()
        let clock = budget.clock
        let deadline = clock() + limit
        let source = Array(text.utf16)
        var output: [UInt16] = []
        var cursor = 0
        var count = 0
        var timedOut = false
        var tooLong = false
        // The matching below never runs while a lock is held.
        expression.enumerateMatches(
            in: text, options: [.reportProgress], range: NSRange(location: 0, length: source.count)
        ) { result, flags, stop in
            if let result {
                output.append(contentsOf: source[cursor..<result.range.location])
                output.append(contentsOf: expression.replacementString(
                    for: result, in: text, offset: 0, template: template).utf16)
                // A UTF-16 unit is at least one byte, so this stops early; the exact size is checked below.
                if output.count > outputLimit {
                    tooLong = true
                    stop.pointee = true
                }
                cursor = result.range.location + result.range.length
                count += 1
                if count.isMultiple(of: 256), clock() > deadline {
                    timedOut = true
                    stop.pointee = true
                }
            } else if flags.contains(.progress), clock() > deadline {
                timedOut = true
                stop.pointee = true
            }
        }
        allowance.consume(allowance.now() - started)
        if timedOut {
            if !limited { breaker.recordTimeout(limit: budget.maxStrikes) }
            return .timedOut
        }
        breaker.recordCompletion()
        if tooLong { return .inputTooLong }
        guard count > 0 else { return .noMatch }
        output.append(contentsOf: source[cursor...])
        let replaced = String(decoding: output, as: UTF16.self)
        return replaced.utf8.count > outputLimit ? .inputTooLong : .replaced(replaced)
    }

    private func run(
        _ text: String, limit: Duration, allowanceBound: Bool, inputCap: Int = RegexPattern.maxInputBytes
    ) -> RegexMatchResult {
        guard text.utf8.count <= inputCap else { return .inputTooLong }
        guard !breaker.isOpen(limit: budget.maxStrikes) else { return .disabled }
        let clock = budget.clock
        let deadline = clock() + limit
        var matched = false
        var timedOut = false
        let options: NSRegularExpression.MatchingOptions = mode == .whole ? [.reportProgress, .anchored] : [.reportProgress]
        // The matching below never runs while a lock is held.
        expression.enumerateMatches(
            in: text,
            options: options,
            range: NSRange(text.startIndex..., in: text)
        ) { result, flags, stop in
            if result != nil {
                matched = true
                stop.pointee = true
            } else if flags.contains(.progress), !timedOut, clock() > deadline {
                timedOut = true
                stop.pointee = true
            }
        }
        if matched {
            breaker.recordCompletion()
            return .matched
        }
        guard timedOut else {
            breaker.recordCompletion()
            return .noMatch
        }
        if !allowanceBound { breaker.recordTimeout(limit: budget.maxStrikes) }
        return .timedOut
    }

    /// True once the pattern timed out `maxStrikes` times in a row.
    public var isDisabled: Bool { breaker.isOpen(limit: budget.maxStrikes) }

    public func resetStrikes() { breaker.reset() }

    package var timeoutCount: Int { breaker.count }
}

/// Heuristic detector of the classic catastrophic shape: a group that contains an unbounded
/// quantifier (`+`, `*`, `{n,}`) and is itself followed by an unbounded quantifier. Escaped
/// characters and character classes are ignored. Patterns that slip through are caught by the
/// runtime `RegexBudget`.
public enum RegexComplexity {
    public static func isRisky(_ pattern: String) -> Bool {
        let chars = Array(pattern.unicodeScalars)
        var groups: [Bool] = []  // per open group: contains an unbounded quantifier
        var i = 0

        func unboundedQuantifier(at index: Int) -> Int? {
            guard index < chars.count else { return nil }
            switch chars[index] {
            case "+", "*": return 1
            case "{":
                var j = index + 1
                var digits = 0
                while j < chars.count, ("0"..."9").contains(chars[j]) {
                    j += 1
                    digits += 1
                }
                guard digits > 0, j < chars.count, chars[j] == "," else { return nil }
                j += 1
                while j < chars.count, ("0"..."9").contains(chars[j]) { j += 1 }
                // `{n,}` is unbounded; `{n,m}` has an upper bound.
                if j < chars.count, chars[j] == "}", chars[j - 1] == "," { return j - index + 1 }
                return nil
            default: return nil
            }
        }

        func markTop() {
            if !groups.isEmpty { groups[groups.count - 1] = true }
        }

        while i < chars.count {
            let c = chars[i]
            switch c {
            case "\\":
                i += 2
                continue
            case "[":
                i += 1
                if i < chars.count, chars[i] == "^" { i += 1 }
                if i < chars.count, chars[i] == "]" { i += 1 }  // leading `]` is a literal
                while i < chars.count, chars[i] != "]" {
                    i += chars[i] == "\\" ? 2 : 1
                }
                i += 1
                continue
            case "(":
                groups.append(false)
            case ")":
                guard let inner = groups.popLast() else { break }
                let quantified = unboundedQuantifier(at: i + 1) != nil
                if quantified && inner { return true }
                if inner || quantified { markTop() }
            default:
                if let length = unboundedQuantifier(at: i) {
                    markTop()
                    i += length
                    continue
                }
            }
            i += 1
        }
        return false
    }
}

/// Bounded LRU caches of compiled patterns (256 wildcard + 256 regex entries), plus the circuit
/// breaker of every regex that was compiled. Compilation runs outside the lock; failures are not
/// cached.
///
/// An instance holds all of its own state (including the regex time budget), so tests use private
/// instances and never touch each other or the app's `shared` one. Breakers are kept apart from
/// the compiled patterns and keyed by pattern text and case option, so evicting a compiled
/// pattern does not forget that it was disabled; when the breaker table is full it drops the
/// oldest breaker that has no timeouts before it drops a tripped one.
public final class PatternCache: Sendable {
    public static let shared = PatternCache()

    private struct RegexKey: Hashable, Sendable {
        let pattern: String
        let mode: RegexPattern.Mode
        let caseInsensitive: Bool
    }

    /// A body search is keyed by what makes it compile differently; the replacement and scope are
    /// arguments of each replace, not part of the compiled pattern.
    private struct BodyKey: Hashable, Sendable {
        let find: String
        let syntax: BodyFindSyntax
        let caseSensitive: Bool
    }

    /// A bounded table with least-recently-used eviction. A hit stamps the entry with a new tick
    /// (O(1)); the O(n) search for the least recently used entry runs only when an insert finds the
    /// table full, which is already the slow path (the caller just compiled a pattern).
    private struct Table<Key: Hashable & Sendable, Value: Sendable>: Sendable {
        private struct Entry: Sendable {
            var value: Value
            var tick: UInt64
        }
        private var entries: [Key: Entry] = [:]
        private var clock: UInt64 = 0

        var count: Int { entries.count }

        /// The stored value without touching the recency order.
        func peek(_ key: Key) -> Value? { entries[key]?.value }

        mutating func lookup(_ key: Key) -> Value? {
            guard var entry = entries[key] else { return nil }
            clock += 1
            entry.tick = clock
            entries[key] = entry
            return entry.value
        }

        /// Inserts unless another thread won the race; returns the stored value. At capacity the
        /// least recently used entry goes, preferring one for which `expendable` is true.
        mutating func insert(
            _ value: Value, for key: Key, capacity: Int, expendable: (Value) -> Bool = { _ in true }
        ) -> Value {
            if let existing = lookup(key) { return existing }
            if entries.count >= capacity {
                var oldest: (key: Key, tick: UInt64)?
                var oldestExpendable: (key: Key, tick: UInt64)?
                for (candidate, entry) in entries {
                    if oldest.map({ entry.tick < $0.tick }) ?? true { oldest = (candidate, entry.tick) }
                    if expendable(entry.value), oldestExpendable.map({ entry.tick < $0.tick }) ?? true {
                        oldestExpendable = (candidate, entry.tick)
                    }
                }
                if let victim = oldestExpendable?.key ?? oldest?.key { entries[victim] = nil }
            }
            clock += 1
            entries[key] = Entry(value: value, tick: clock)
            return value
        }
    }

    private struct State: Sendable {
        var wildcards = Table<String, WildcardPattern>()
        var regexes = Table<RegexKey, RegexPattern>()
        var breakers = Table<RegexKey, RegexBreaker>()
        var bodies = Table<BodyKey, BodySearchPattern>()
        var bodyBreakers = Table<BodyKey, RegexBreaker>()
        var bodyFinds = Table<BodyKey, RegexPattern>()
    }

    private let capacity: Int
    private let breakerCapacity: Int
    private let budget: RegexBudget
    let bodyBudget: RegexBudget
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let observers = OSAllocatedUnfairLock<[@Sendable () -> Void]>(initialState: [])

    /// `bodyBudget` is the (much larger, 5 s) time allowance of one body find-and-replace, with its
    /// own breakers: a pattern text that is slow on bodies stays usable for matching and the
    /// other way round.
    public init(
        budget: RegexBudget = .standard, bodyBudget: RegexBudget = RegexBudget(maxDuration: .seconds(5)),
        capacity: Int = 256, breakerCapacity: Int? = nil
    ) {
        self.budget = budget
        self.bodyBudget = bodyBudget
        self.capacity = max(1, capacity)
        self.breakerCapacity = max(1, breakerCapacity ?? max(1024, capacity * 4))
    }

    public func wildcard(_ pattern: String) throws -> WildcardPattern {
        if let hit = state.withLock({ $0.wildcards.lookup(pattern) }) { return hit }
        let compiled = try WildcardPattern(pattern)
        return state.withLock { $0.wildcards.insert(compiled, for: pattern, capacity: capacity) }
    }

    public func regex(_ pattern: String, caseInsensitive: Bool) throws -> RegexPattern {
        try regex(pattern, mode: .whole, caseInsensitive: caseInsensitive)
    }

    public func regex(_ pattern: String, mode: RegexPattern.Mode, caseInsensitive: Bool) throws -> RegexPattern {
        let key = RegexKey(pattern: pattern, mode: mode, caseInsensitive: caseInsensitive)
        if let hit = state.withLock({ $0.regexes.lookup(key) }) { return hit }
        let breaker = self.breaker(for: key)
        let compiled = try RegexPattern(
            pattern, mode: mode, caseInsensitive: caseInsensitive, budget: budget, breaker: breaker)
        return state.withLock { $0.regexes.insert(compiled, for: key, capacity: capacity) }
    }

    /// Compiles the pattern into the cache and forgets earlier timeouts: the way a saved rule
    /// re-enables a pattern that was disabled at run time.
    public func prepareRegex(_ pattern: String, caseInsensitive: Bool) throws {
        try prepareRegex(pattern, mode: .whole, caseInsensitive: caseInsensitive)
    }

    public func prepareRegex(_ pattern: String, mode: RegexPattern.Mode, caseInsensitive: Bool) throws {
        _ = try regex(pattern, mode: mode, caseInsensitive: caseInsensitive)
        resetStrikes(pattern, mode: mode, caseInsensitive: caseInsensitive)
    }

    public func resetStrikes(_ pattern: String, caseInsensitive: Bool) {
        resetStrikes(pattern, mode: .whole, caseInsensitive: caseInsensitive)
    }

    public func resetStrikes(_ pattern: String, mode: RegexPattern.Mode, caseInsensitive: Bool) {
        let key = RegexKey(pattern: pattern, mode: mode, caseInsensitive: caseInsensitive)
        state.withLock { $0.breakers.peek(key) }?.reset()
    }

    /// True while the pattern is switched off by its circuit breaker. Looks nothing up in the
    /// compiled-pattern cache and does not touch the LRU order.
    public func isRegexDisabled(_ pattern: String, caseInsensitive: Bool) -> Bool {
        isRegexDisabled(pattern, mode: .whole, caseInsensitive: caseInsensitive)
    }

    public func isRegexDisabled(_ pattern: String, mode: RegexPattern.Mode, caseInsensitive: Bool) -> Bool {
        let key = RegexKey(pattern: pattern, mode: mode, caseInsensitive: caseInsensitive)
        return state.withLock { $0.breakers.peek(key) }?.isOpen(limit: budget.maxStrikes) ?? false
    }

    /// The compiled body search for `action` (its find text, syntax and case option; the
    /// replacement and scope are passed to `replace`). Throws `PatternError` for an empty, too
    /// long, invalid or too complex find text.
    public func bodyPattern(_ action: BodyRewriteAction) throws -> BodySearchPattern {
        let key = BodyKey(find: action.find, syntax: action.syntax, caseSensitive: action.caseSensitive)
        if let hit = state.withLock({ $0.bodies.lookup(key) }) { return hit }
        let breaker = bodyBreaker(for: key)
        let compiled = try BodySearchPattern(
            find: action.find, syntax: action.syntax, caseSensitive: action.caseSensitive,
            budget: bodyBudget, breaker: breaker)
        return state.withLock { $0.bodies.insert(compiled, for: key, capacity: capacity) }
    }

    /// A find-mode regular expression for a body condition row (D12): compiled with the body budget and
    /// the breaker of the same pattern text as a body search, so a pattern that is slow on bodies is
    /// switched off for both. Throws `PatternError` like `regex(_:mode:caseInsensitive:)`.
    func bodyRegex(_ pattern: String, caseInsensitive: Bool) throws -> RegexPattern {
        let key = BodyKey(find: pattern, syntax: .regex, caseSensitive: !caseInsensitive)
        if let hit = state.withLock({ $0.bodyFinds.lookup(key) }) { return hit }
        let compiled = try RegexPattern(
            pattern, mode: .find, caseInsensitive: caseInsensitive, budget: bodyBudget, breaker: bodyBreaker(for: key))
        return state.withLock { $0.bodyFinds.insert(compiled, for: key, capacity: capacity) }
    }

    /// Compiles the body search into the cache and forgets earlier timeouts (saving or publishing
    /// a rule calls this).
    public func prepareBodyPattern(_ action: BodyRewriteAction) throws {
        _ = try bodyPattern(action)
        let key = BodyKey(find: action.find, syntax: action.syntax, caseSensitive: action.caseSensitive)
        state.withLock { $0.bodyBreakers.peek(key) }?.reset()
    }

    /// True while the body search is switched off by its circuit breaker.
    public func isBodyPatternDisabled(_ action: BodyRewriteAction) -> Bool {
        let key = BodyKey(find: action.find, syntax: action.syntax, caseSensitive: action.caseSensitive)
        return state.withLock { $0.bodyBreakers.peek(key) }?.isOpen(limit: bodyBudget.maxStrikes) ?? false
    }

    /// Calls `handler` (from whichever thread ran the match) each time a pattern is switched off.
    /// Observers live as long as the cache.
    public func addDisableObserver(_ handler: @escaping @Sendable () -> Void) {
        observers.withLock { $0.append(handler) }
    }

    private func breaker(for key: RegexKey) -> RegexBreaker {
        let candidate = RegexBreaker(onTrip: { [weak self] in self?.patternDisabled(key.pattern) })
        return state.withLock { state in
            state.breakers.insert(
                candidate, for: key, capacity: breakerCapacity, expendable: { $0.count == 0 })
        }
    }

    private func bodyBreaker(for key: BodyKey) -> RegexBreaker {
        let candidate = RegexBreaker(onTrip: { [weak self] in self?.patternDisabled(key.find) })
        return state.withLock { state in
            state.bodyBreakers.insert(
                candidate, for: key, capacity: breakerCapacity, expendable: { $0.count == 0 })
        }
    }

    private func patternDisabled(_ pattern: String) {
        Self.log.notice(
            "regular expression switched off after consecutive timeouts: \(pattern, privacy: .private(mask: .hash))")
        let handlers = observers.withLock { $0 }
        for handler in handlers { handler() }
    }

    private static let log = Logger(subsystem: "ProxyWoman", category: "RulesEngine")

    package var count: Int {
        state.withLock { $0.wildcards.count + $0.regexes.count }
    }
}
