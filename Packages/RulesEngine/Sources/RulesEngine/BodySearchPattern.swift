import Foundation

/// A find expression for body rewriting that only runs under a time budget and a circuit
/// breaker, and notices task cancellation. Never run a body search with `NSRegularExpression`
/// outside this type.
///
/// Text syntax escapes the find text and uses the replacement verbatim; regex syntax uses both
/// as ICU pattern and template. The breaker counts consecutive timeouts of *this* pattern (see
/// `PatternCache.bodyPattern`); a replace that finishes in time ends the streak.
public final class BodySearchPattern: Sendable {
    public enum ReplaceResult: Sendable, Equatable {
        case replaced(String, count: Int)
        case noMatch
        case timedOut
        case disabled
        /// The result would be longer than the caller's `maxOutputUnits`.
        case inputTooLong
    }

    private let expression: NSRegularExpression  // immutable and documented thread-safe
    private let isRegex: Bool
    private let budget: RegexBudget
    private let breaker: RegexBreaker

    init(
        find: String, syntax: BodyFindSyntax, caseSensitive: Bool, budget: RegexBudget, breaker: RegexBreaker
    ) throws {
        guard !find.isEmpty else { throw PatternError.empty }
        guard find.utf8.count <= BodyRewriteAction.maxFindBytes else { throw PatternError.tooLong }
        if syntax == .regex, RegexComplexity.isRisky(find) { throw PatternError.regexTooComplex }
        let source = syntax == .regex ? find : NSRegularExpression.escapedPattern(for: find)
        let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
        guard let expression = try? NSRegularExpression(pattern: source, options: options) else {
            throw PatternError.invalidRegex
        }
        self.expression = expression
        self.isRegex = syntax == .regex
        self.budget = budget
        self.breaker = breaker
    }

    /// Replaces matches of the pattern in `text`, building the result piece by piece (not with
    /// `stringByReplacingMatches`, which cannot be interrupted). Calling it inside a cancelled
    /// task stops at the next progress report and returns `.noMatch` without counting a strike;
    /// the caller checks `Task.isCancelled` itself. `maxOutputUnits` bounds the result in UTF-16
    /// units (it cannot be known in advance because of capture templates). `countsStrikes: false` is a
    /// look-alike run (a condition reading the body as an earlier rewrite would leave it): it respects
    /// a tripped breaker but never adds a strike or ends a streak, so only the real rewrite counts.
    public func replace(
        in text: String, with replacement: String, scope: BodyReplaceScope, maxOutputUnits: Int = .max,
        countsStrikes: Bool = true
    ) -> ReplaceResult {
        guard !breaker.isOpen(limit: budget.maxStrikes) else { return .disabled }
        guard !Task.isCancelled else { return .noMatch }
        let clock = budget.clock
        let deadline = clock() + budget.maxDuration

        let source = Array(text.utf16)
        let literal = Array(replacement.utf16)
        var output: [UInt16] = []
        var cursor = 0
        var count = 0
        var timedOut = false, cancelled = false, tooLong = false

        // The matching below never runs while a lock is held.
        expression.enumerateMatches(
            in: text, options: [.reportProgress], range: NSRange(location: 0, length: source.count)
        ) { result, flags, stop in
            if let result {
                let range = result.range
                output.append(contentsOf: source[cursor..<range.location])
                if isRegex {
                    output.append(contentsOf: expression.replacementString(
                        for: result, in: text, offset: 0, template: replacement).utf16)
                } else {
                    output.append(contentsOf: literal)
                }
                cursor = range.location + range.length
                count += 1
                if output.count > maxOutputUnits {
                    tooLong = true
                    stop.pointee = true
                } else if scope == .first {
                    stop.pointee = true
                } else if Task.isCancelled {
                    cancelled = true
                    stop.pointee = true
                } else if count.isMultiple(of: 256), clock() > deadline {
                    timedOut = true
                    stop.pointee = true
                }
            } else if flags.contains(.progress) {
                if Task.isCancelled {
                    cancelled = true
                    stop.pointee = true
                } else if clock() > deadline {
                    timedOut = true
                    stop.pointee = true
                }
            }
        }

        if cancelled { return .noMatch }
        if tooLong {
            if countsStrikes { breaker.recordCompletion() }
            return .inputTooLong
        }
        if timedOut {
            if countsStrikes { breaker.recordTimeout(limit: budget.maxStrikes) }
            return .timedOut
        }
        if countsStrikes { breaker.recordCompletion() }
        guard count > 0 else { return .noMatch }
        output.append(contentsOf: source[cursor...])
        guard output.count <= maxOutputUnits else { return .inputTooLong }
        return .replaced(String(decoding: output, as: UTF16.self), count: count)
    }

    var isDisabled: Bool { breaker.isOpen(limit: budget.maxStrikes) }
}
