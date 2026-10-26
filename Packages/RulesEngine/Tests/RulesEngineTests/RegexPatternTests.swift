import Foundation
import Testing
import os

@testable import RulesEngine

/// A monotonic clock that advances a fixed step on every read and counts the reads.
private final class FakeClock: @unchecked Sendable {  // guarded by `lock`
    private let lock = NSLock()
    private var now: Duration = .zero
    private var reads = 0
    let step: Duration
    init(step: Duration = .milliseconds(1)) { self.step = step }
    var readCount: Int { lock.withLock { reads } }
    func read() -> Duration {
        lock.withLock {
            reads += 1
            now += step
            return now
        }
    }
    func budget(maxStrikes: Int = 3) -> RegexBudget {
        RegexBudget(maxDuration: .milliseconds(2), maxStrikes: maxStrikes, clock: { [self] in read() })
    }
}

@Suite("RegexPattern")
struct RegexPatternTests {
    private func regex(_ pattern: String, ci: Bool = false) throws -> RegexPattern {
        try RegexPattern(pattern, caseInsensitive: ci)
    }

    @Test func matchIsAnchoredBothEnds() throws {
        #expect(try regex("a").matches("a") == .matched)
        #expect(try regex("a").matches("ab") == .noMatch)
        #expect(try regex("a").matches("ba") == .noMatch)
        #expect(try regex("a.*").matches("abc") == .matched)
        #expect(try regex("a|b").matches("bx") == .noMatch)
    }

    @Test func caseInsensitiveOnlyWhenAsked() throws {
        #expect(try regex("abc").matches("ABC") == .noMatch)
        #expect(try regex("abc", ci: true).matches("ABC") == .matched)
    }

    @Test func invalidPatternThrows() {
        #expect(throws: PatternError.invalidRegex) { try RegexPattern("(", caseInsensitive: false) }
        #expect(throws: PatternError.invalidRegex) { try RegexPattern("[a-", caseInsensitive: false) }
        #expect(throws: PatternError.invalidRegex) { try RegexPattern("a)(b", caseInsensitive: false) }
        #expect(throws: PatternError.empty) { try RegexPattern("", caseInsensitive: false) }
    }

    @Test func tooLongPatternThrows() {
        let long = String(repeating: "a", count: RegexPattern.maxPatternBytes + 1)
        #expect(throws: PatternError.tooLong) { try RegexPattern(long, caseInsensitive: false) }
    }

    @Test func riskyNestedQuantifiersAreRejected() {
        for pattern in ["(a+)+", "(a*)*", "(.*x)+", "(\\d+){2,}", "((a)+)+", "((a+))+"] {
            #expect(throws: PatternError.regexTooComplex, "\(pattern)") {
                try RegexPattern(pattern, caseInsensitive: false)
            }
        }
    }

    @Test func safeShapesAreAccepted() throws {
        for pattern in ["(ab)+", "a+b+", "(a|b)+", "[+*]+", "\\(a+\\)+", "(a|aa)+c", "(a+){2}", "([+*])+"] {
            #expect(!RegexComplexity.isRisky(pattern), "\(pattern)")
            _ = try RegexPattern(pattern, caseInsensitive: false)
        }
    }

    @Test func inputTooLongReturnsInputTooLong() throws {
        let pattern = try regex(".*")
        #expect(pattern.matches(String(repeating: "a", count: RegexPattern.maxInputBytes + 1)) == .inputTooLong)
        #expect(pattern.matches(String(repeating: "a", count: RegexPattern.maxInputBytes)) == .matched)
        // The limit is in UTF-8 bytes, not characters.
        #expect(pattern.matches(String(repeating: "😀", count: 2049)) == .inputTooLong)
    }

    @Test func budgetStopsCatastrophicPatternWithFakeClock() throws {
        let clock = FakeClock()
        let pattern = try RegexPattern("(a|aa)+c", caseInsensitive: false, budget: clock.budget())
        let input = String(repeating: "a", count: 60) + "b"
        #expect(pattern.matches(input) == .timedOut)
        #expect(clock.readCount >= 3)
        #expect(clock.readCount < 100_000)
        #expect(pattern.timeoutCount == 1)
    }

    @Test func threeStrikesDisableThePattern() throws {
        let clock = FakeClock()
        let pattern = try RegexPattern("(a|aa)+c", caseInsensitive: false, budget: clock.budget())
        let input = String(repeating: "a", count: 60) + "b"
        for _ in 0..<3 {
            #expect(!pattern.isDisabled)
            #expect(pattern.matches(input) == .timedOut)
        }
        #expect(pattern.isDisabled)
        let reads = clock.readCount
        #expect(pattern.matches(input) == .disabled)
        #expect(pattern.matches("aac") == .disabled)
        #expect(clock.readCount == reads)
        pattern.resetStrikes()
        #expect(!pattern.isDisabled)
        #expect(pattern.timeoutCount == 0)
        #expect(pattern.matches("aac") == .matched)
        #expect(pattern.matches(input) == .timedOut)
    }

    @Test func fastMatchDoesNotStrike() throws {
        let clock = FakeClock(step: .microseconds(1))
        let pattern = try RegexPattern("(ab)+c", caseInsensitive: false, budget: clock.budget())
        for _ in 0..<10 { #expect(pattern.matches("ababc") == .matched) }
        #expect(pattern.timeoutCount == 0)
        #expect(!pattern.isDisabled)
    }

    @Test func successResetsTheConsecutiveTimeoutCount() throws {
        let clock = FakeClock()
        let pattern = try RegexPattern("(a|aa)+c", caseInsensitive: false, budget: clock.budget())
        let slow = String(repeating: "a", count: 60) + "b"
        #expect(pattern.matches(slow) == .timedOut)
        #expect(pattern.matches(slow) == .timedOut)
        #expect(pattern.timeoutCount == 2)
        #expect(pattern.matches("aac") == .matched)
        #expect(pattern.timeoutCount == 0)
        #expect(pattern.matches("ab") == .noMatch)
        // Two more timeouts are not three in a row: scattered slow inputs never disable the pattern.
        #expect(pattern.matches(slow) == .timedOut)
        #expect(pattern.matches(slow) == .timedOut)
        #expect(!pattern.isDisabled)
        #expect(pattern.matches(slow) == .timedOut)
        #expect(pattern.isDisabled)
    }

    @Test func tooLongInputDoesNotResetTheCount() throws {
        let clock = FakeClock()
        let pattern = try RegexPattern("(a|aa)+c", caseInsensitive: false, budget: clock.budget())
        #expect(pattern.matches(String(repeating: "a", count: 60) + "b") == .timedOut)
        #expect(pattern.matches(String(repeating: "a", count: RegexPattern.maxInputBytes + 1)) == .inputTooLong)
        #expect(pattern.timeoutCount == 1)
    }
}

@Suite("PatternCache")
struct PatternCacheTests {
    private let slow = String(repeating: "a", count: 60) + "b"

    @Test func cacheReturnsSameInstanceAndIsBounded() throws {
        let cache = PatternCache()
        #expect(cache.count == 0)
        let a = try cache.regex("a+", caseInsensitive: false)
        let b = try cache.regex("a+", caseInsensitive: false)
        #expect(a === b)
        let w1 = try cache.wildcard("*.x")
        let w2 = try cache.wildcard("*.x")
        #expect(w1 == w2)
        for index in 0..<300 {
            _ = try cache.regex("p\(index)", caseInsensitive: false)
            _ = try cache.wildcard("w\(index)*")
        }
        #expect(cache.count <= 512)
        #expect(cache.count > 256)
        // Most recently used entries survive; the first regex was evicted.
        let again = try cache.regex("a+", caseInsensitive: false)
        #expect(again !== a)
    }

    @Test func cacheEvictsLeastRecentlyUsed() throws {
        let cache = PatternCache()
        let keep = try cache.regex("keep", caseInsensitive: false)
        for index in 0..<255 { _ = try cache.regex("x\(index)", caseInsensitive: false) }
        _ = try cache.regex("keep", caseInsensitive: false)  // refresh
        _ = try cache.regex("new", caseInsensitive: false)  // evicts x0, not keep
        #expect(try cache.regex("keep", caseInsensitive: false) === keep)
    }

    @Test func cacheDistinguishesCaseInsensitivity() throws {
        let cache = PatternCache()
        let sensitive = try cache.regex("abc", caseInsensitive: false)
        let insensitive = try cache.regex("abc", caseInsensitive: true)
        #expect(sensitive !== insensitive)
        #expect(sensitive.matches("ABC") == .noMatch)
        #expect(insensitive.matches("ABC") == .matched)
    }

    @Test func cacheDoesNotStoreFailures() {
        let cache = PatternCache()
        #expect(throws: PatternError.invalidRegex) { try cache.regex("(", caseInsensitive: false) }
        #expect(throws: PatternError.invalidEscape) { try cache.wildcard("a\\x") }
        #expect(cache.count == 0)
    }

    @Test func eachCacheUsesItsOwnBudgetAndKeepsItsOwnState() throws {
        let clock = FakeClock()
        let slowCache = PatternCache(budget: clock.budget())
        let otherCache = PatternCache()
        let pattern = try slowCache.regex("(a|aa)+c", caseInsensitive: false)
        #expect(pattern.matches(slow) == .timedOut)
        #expect(clock.readCount >= 3)
        #expect(try otherCache.regex("(a|aa)+c", caseInsensitive: false) !== pattern)
        #expect(otherCache.count == 1)
        #expect(!otherCache.isRegexDisabled("(a|aa)+c", caseInsensitive: false))
    }

    @Test func aTrippedPatternStaysDisabledAfterItsCacheEntryIsEvicted() throws {
        let clock = FakeClock()
        let cache = PatternCache(budget: clock.budget(), capacity: 2)
        let first = try cache.regex("(a|aa)+c", caseInsensitive: false)
        for _ in 0..<3 { #expect(first.matches(slow) == .timedOut) }
        #expect(cache.isRegexDisabled("(a|aa)+c", caseInsensitive: false))
        for index in 0..<5 { _ = try cache.regex("e\(index)", caseInsensitive: false) }
        let recompiled = try cache.regex("(a|aa)+c", caseInsensitive: false)
        #expect(recompiled !== first, "the entry really was evicted")
        #expect(recompiled.isDisabled)
        #expect(recompiled.matches("aac") == .disabled)
        // The breaker is keyed by pattern text and case option.
        #expect(!cache.isRegexDisabled("(a|aa)+c", caseInsensitive: true))
    }

    @Test func breakerTablePrefersDroppingHealthyPatterns() throws {
        let clock = FakeClock()
        let cache = PatternCache(budget: clock.budget(), capacity: 2, breakerCapacity: 3)
        let tripped = try cache.regex("(a|aa)+c", caseInsensitive: false)
        for _ in 0..<3 { _ = tripped.matches(slow) }
        for index in 0..<10 { _ = try cache.regex("h\(index)", caseInsensitive: false) }
        #expect(cache.isRegexDisabled("(a|aa)+c", caseInsensitive: false))
    }

    @Test func resetStrikesReEnablesAndPrepareCompilesAndResets() throws {
        let clock = FakeClock()
        let cache = PatternCache(budget: clock.budget())
        let pattern = try cache.regex("(a|aa)+c", caseInsensitive: false)
        for _ in 0..<3 { _ = pattern.matches(slow) }
        #expect(cache.isRegexDisabled("(a|aa)+c", caseInsensitive: false))
        cache.resetStrikes("(a|aa)+c", caseInsensitive: false)
        #expect(!cache.isRegexDisabled("(a|aa)+c", caseInsensitive: false))
        #expect(pattern.matches("aac") == .matched)

        for _ in 0..<3 { _ = pattern.matches(slow) }
        #expect(pattern.isDisabled)
        try cache.prepareRegex("(a|aa)+c", caseInsensitive: false)
        #expect(!pattern.isDisabled)
        #expect(throws: PatternError.invalidRegex) { try cache.prepareRegex("(", caseInsensitive: false) }
    }

    @Test func observersHearAboutEachTripExactlyOnce() throws {
        let clock = FakeClock()
        let cache = PatternCache(budget: clock.budget())
        let trips = OSAllocatedCounter()
        cache.addDisableObserver { trips.increment() }
        let pattern = try cache.regex("(a|aa)+c", caseInsensitive: false)
        _ = pattern.matches(slow)
        _ = pattern.matches(slow)
        #expect(trips.value == 0)
        _ = pattern.matches(slow)
        #expect(trips.value == 1)
        #expect(pattern.matches(slow) == .disabled)
        #expect(trips.value == 1)
        cache.resetStrikes("(a|aa)+c", caseInsensitive: false)
        for _ in 0..<3 { _ = pattern.matches(slow) }
        #expect(trips.value == 2)
    }
}

/// Deferred minors of P2 T1 / the P2 re-review, fixed on fix/deferred-core-minors.
@Suite("RegexBreakerAndLookup")
struct RegexBreakerAndLookupTests {
    /// P2 re-review m1: a match that started before the breaker tripped and finished in time must
    /// not close it again; only an explicit reset re-enables a pattern.
    @Test func aLateCompletionDoesNotReCloseATrippedBreaker() {
        let breaker = RegexBreaker()
        breaker.recordTimeout(limit: 2)
        breaker.recordTimeout(limit: 2)
        #expect(breaker.isOpen(limit: 2))
        breaker.recordCompletion()  // the in-flight match that finished within its budget
        #expect(breaker.isOpen(limit: 2), "a tripped breaker stays open until reset()")
        breaker.reset()
        #expect(!breaker.isOpen(limit: 2))
        // Below the limit a completion still ends the streak.
        breaker.recordTimeout(limit: 2)
        breaker.recordCompletion()
        #expect(breaker.count == 0)
    }

    /// P2 T1 minor: `maxStrikes <= 0` used to disable a pattern before it ever ran.
    @Test func aNonPositiveStrikeLimitStillAllowsTheFirstMatch() throws {
        for strikes in [0, -3] {
            let pattern = try RegexPattern("a", caseInsensitive: false, budget: RegexBudget(maxStrikes: strikes))
            #expect(pattern.matches("a") == .matched, "maxStrikes \(strikes)")
            #expect(!pattern.isDisabled)
        }
    }

    /// P2 M2: a hit used to cost O(capacity) under the cache lock. Looking up the least recently
    /// used key is the worst case of that scan; with a large table 10 000 such hits take seconds
    /// before the fix and milliseconds after it.
    @Test func lookupCostDoesNotGrowWithTheNumberOfCachedPatterns() throws {
        let count = 10_000
        let cache = PatternCache(capacity: count)
        for index in 0..<count { _ = try cache.wildcard("w\(index)*") }
        let start = ContinuousClock.now
        for index in 0..<count { _ = try cache.wildcard("w\(index)*") }  // each is the oldest when asked
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .seconds(1), "10 000 hits took \(elapsed)")
        #expect(cache.count == count)
    }
}

private final class OSAllocatedCounter: Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)
    func increment() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}

@Suite("RegexFindMode")
struct RegexFindModeTests {
    private func regex(_ pattern: String, ci: Bool = false) throws -> RegexPattern {
        try RegexPattern(pattern, caseInsensitive: ci)
    }

    // MARK: find mode and allowance (Rules 2.0 R3)

    @Test func findModeMatchesAnywhere() throws {
        let find = try RegexPattern("b+", mode: .find, caseInsensitive: false)
        #expect(find.matches("aabbcc") == .matched)
        #expect(find.matches("xyz") == .noMatch)
        #expect(try RegexPattern("^ab", mode: .find, caseInsensitive: false).matches("abc") == .matched)
        #expect(try RegexPattern("B", mode: .find, caseInsensitive: true).matches("abc") == .matched)
    }

    @Test func wholeModeStillAnchors() throws {
        let whole = try RegexPattern("b+", mode: .whole, caseInsensitive: false)
        #expect(whole.matches("aabbcc") == .noMatch)
        #expect(whole.matches("bbb") == .matched)
        #expect(try regex("a").matches("ab") == .noMatch)
    }

    @Test func cacheKeepsModesApart() throws {
        let cache = PatternCache(budget: StepClock().budget)
        let whole = try cache.regex("a", mode: .whole, caseInsensitive: false)
        let find = try cache.regex("a", mode: .find, caseInsensitive: false)
        #expect(whole !== find)
        #expect(try cache.regex("a", caseInsensitive: false) === whole)
        #expect(whole.matches("ba") == .noMatch)
        #expect(find.matches("ba") == .matched)
        // Independent breakers.
        let slow = try cache.regex("(a|b)+c", mode: .find, caseInsensitive: false)
        for _ in 0..<3 { _ = slow.matches(String(repeating: "ab", count: 50)) }
        #expect(cache.isRegexDisabled("(a|b)+c", mode: .find, caseInsensitive: false))
        #expect(!cache.isRegexDisabled("(a|b)+c", mode: .whole, caseInsensitive: false))
    }

    @Test func findModeObeysTheInputCap() throws {
        let find = try RegexPattern("a", mode: .find, caseInsensitive: false)
        #expect(find.matches(String(repeating: "a", count: 8193)) == .inputTooLong)
        #expect(find.matches(String(repeating: "a", count: 8192)) == .matched)
        #expect(find.matches("a", allowance: RegexAllowance()) == .matched)
        #expect(find.matches(String(repeating: "a", count: 8193), allowance: RegexAllowance()) == .inputTooLong)
    }

    /// A clock whose reads the test scripts: every read returns the next value.
    private final class ScriptedClock: @unchecked Sendable {  // guarded by `lock`
        private let lock = NSLock()
        private var values: [Duration]
        init(_ millis: [Int]) { values = millis.map { .milliseconds($0) } }
        func read() -> Duration { lock.withLock { values.isEmpty ? .seconds(1000) : values.removeFirst() } }
    }

    @Test func allowanceIsSharedAcrossRows() throws {
        // Each match reads the allowance clock twice (start, end): 3 ms used each time.
        let allowanceClock = ScriptedClock([0, 3, 3, 6, 6, 8, 8, 9])
        let allowance = RegexAllowance(total: .milliseconds(8), clock: { allowanceClock.read() })
        let find = try RegexPattern("a", mode: .find, caseInsensitive: false)
        #expect(allowance.remaining == .milliseconds(8))
        #expect(find.matches("a", allowance: allowance) == .matched)
        #expect(allowance.remaining == .milliseconds(5))
        #expect(find.matches("a", allowance: allowance) == .matched)
        #expect(allowance.remaining == .milliseconds(2))
        #expect(find.matches("a", allowance: allowance) == .matched)
        #expect(allowance.remaining == .zero)
        // Used up: every further row times out without even looking at the text.
        #expect(find.matches("a", allowance: allowance) == .timedOut)
        #expect(find.matches("a", allowance: allowance) == .timedOut)
    }

    @Test func allowanceTimeoutDoesNotTripTheBreaker() throws {
        let breaker = RegexBreaker()
        let find = try RegexPattern("a", mode: .find, caseInsensitive: false, budget: RegexBudget(maxStrikes: 1), breaker: breaker)
        let allowance = RegexAllowance(total: .zero)
        for _ in 0..<5 { #expect(find.matches("a", allowance: allowance) == .timedOut) }
        #expect(find.timeoutCount == 0)
        #expect(!find.isDisabled)
        #expect(find.matches("a") == .matched)
    }

    @Test func allowanceCutShortTimeoutDoesNotCountEither() throws {
        // 1 ms left of the allowance; the pattern's own clock then runs out that 1 ms budget.
        let patternClock = FakeClock(step: .milliseconds(5))
        let find = try RegexPattern(
            "(a|b)+c", mode: .find, caseInsensitive: false, budget: patternClock.budget(maxStrikes: 1))
        let allowance = RegexAllowance(total: .milliseconds(1))
        #expect(find.matches(String(repeating: "ab", count: 50), allowance: allowance) == .timedOut)
        #expect(find.timeoutCount == 0)
    }

    @Test func allowanceNeverExceedsTheStandardBudgetPerMatch() throws {
        // Plenty of allowance left: the pattern's own 2 ms still applies and a timeout is a strike.
        let patternClock = FakeClock(step: .milliseconds(1))
        let find = try RegexPattern(
            "(a|b)+c", mode: .find, caseInsensitive: false, budget: patternClock.budget(maxStrikes: 3))
        let allowance = RegexAllowance(total: .seconds(10))
        #expect(find.matches(String(repeating: "ab", count: 50), allowance: allowance) == .timedOut)
        #expect(find.timeoutCount == 1)
    }

    @Test func preparedFindPatternIsReEnabledOnPublish() throws {
        let cache = PatternCache(budget: StepClock().budget)
        let rule = Rule(
            name: "r",
            conditions: ConditionGroup(rows: [ConditionRow(field: .url, op: .regex, value: "(a|b)+c", caseSensitive: true)]),
            actions: [RuleAction(.hide)])
        let find = try cache.regex("(a|b)+c", mode: .find, caseInsensitive: false)
        for _ in 0..<3 { _ = find.matches(String(repeating: "ab", count: 50)) }
        #expect(cache.isRegexDisabled("(a|b)+c", mode: .find, caseInsensitive: false))
        rule.preparePatterns(in: cache)
        #expect(!cache.isRegexDisabled("(a|b)+c", mode: .find, caseInsensitive: false))
    }
}
