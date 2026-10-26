import Foundation
import Testing
import os

@testable import RulesEngine

/// A fake clock: every read advances `step` and is counted.
final class BodyTestClock: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (now: Duration.zero, reads: 0))
    let step: Duration
    init(step: Duration = .milliseconds(1)) { self.step = step }
    var readCount: Int { state.withLock { $0.reads } }
    func read() -> Duration {
        state.withLock { state in
            state.reads += 1
            state.now += step
            return state.now
        }
    }
    func budget(maxDuration: Duration = .milliseconds(5), maxStrikes: Int = 3) -> RegexBudget {
        RegexBudget(maxDuration: maxDuration, maxStrikes: maxStrikes, clock: { [self] in read() })
    }
}

let catastrophicFind = "(a|aa)+c"
let catastrophicInput = String(repeating: "a", count: 60) + "b"

@Suite("BodySearchPattern")
struct BodySearchPatternTests {
    private func pattern(
        _ find: String, syntax: BodyFindSyntax = .text, caseSensitive: Bool = true, cache: PatternCache = PatternCache()
    ) throws -> BodySearchPattern {
        try cache.bodyPattern(BodyRewriteAction(find: find, replacement: "", syntax: syntax, caseSensitive: caseSensitive))
    }

    @Test func textModeIsLiteral() throws {
        let p = try pattern("a.b*")
        #expect(p.replace(in: "axbb", with: "X", scope: .all) == .noMatch)
        #expect(p.replace(in: "see a.b* here", with: #"$1\n"#, scope: .all) == .replaced(#"see $1\n here"#, count: 1))
        #expect(try pattern("(x)").replace(in: "a(x)b", with: "[]", scope: .all) == .replaced("a[]b", count: 1))
    }

    @Test func regexTemplateUsesCaptures() throws {
        let p = try pattern(#"(\w+)@(\w+)"#, syntax: .regex)
        #expect(p.replace(in: "me@host and you@there", with: "$2:$1", scope: .all)
            == .replaced("host:me and there:you", count: 2))
        #expect(p.replace(in: "me@host and you@there", with: #"\$1"#, scope: .first)
            == .replaced("$1 and you@there", count: 1))
    }

    @Test func caseInsensitiveOption() throws {
        #expect(try pattern("Hello", caseSensitive: false).replace(in: "hello HELLO", with: "x", scope: .all)
            == .replaced("x x", count: 2))
        #expect(try pattern("Hello", caseSensitive: true).replace(in: "hello HELLO", with: "x", scope: .all) == .noMatch)
    }

    @Test func firstScopeReplacesOnlyFirst() throws {
        #expect(try pattern("a").replace(in: "banana", with: "o", scope: .first) == .replaced("bonana", count: 1))
    }

    @Test func allScopeReplacesNonOverlapping() throws {
        #expect(try pattern("aa").replace(in: "aaaaa", with: "b", scope: .all) == .replaced("bba", count: 2))
        #expect(try pattern("é").replace(in: "caf\u{e9} 😀 caf\u{e9}", with: "e", scope: .all) == .replaced("cafe 😀 cafe", count: 2))
    }

    @Test func noMatchReturnsNoMatch() throws {
        #expect(try pattern("zzz").replace(in: "abc", with: "x", scope: .all) == .noMatch)
        #expect(try pattern("zzz").replace(in: "", with: "x", scope: .all) == .noMatch)
    }

    @Test func invalidAndRiskyRegexThrowAtCompile() {
        let cache = PatternCache()
        #expect(throws: PatternError.invalidRegex) {
            try cache.bodyPattern(BodyRewriteAction(find: "(", replacement: "", syntax: .regex))
        }
        #expect(throws: PatternError.regexTooComplex) {
            try cache.bodyPattern(BodyRewriteAction(find: "(a+)+", replacement: "", syntax: .regex))
        }
        // Text mode never compiles user syntax, so these are plain strings there.
        #expect(throws: Never.self) { try cache.bodyPattern(BodyRewriteAction(find: "(a+)+", replacement: "")) }
        #expect(throws: Never.self) { try cache.bodyPattern(BodyRewriteAction(find: "(", replacement: "")) }
    }

    @Test func emptyAndOverlongFindThrow() {
        let cache = PatternCache()
        #expect(throws: PatternError.empty) { try cache.bodyPattern(BodyRewriteAction(find: "", replacement: "x")) }
        #expect(throws: PatternError.tooLong) {
            try cache.bodyPattern(BodyRewriteAction(find: String(repeating: "a", count: 1025), replacement: "x"))
        }
        #expect(throws: Never.self) {
            try cache.bodyPattern(BodyRewriteAction(find: String(repeating: "a", count: 1024), replacement: "x"))
        }
    }

    @Test func compiledPatternIsCachedPerFindSyntaxAndCase() throws {
        let cache = PatternCache()
        let a = try cache.bodyPattern(BodyRewriteAction(find: "x", replacement: "1"))
        let b = try cache.bodyPattern(BodyRewriteAction(find: "x", replacement: "2", scope: .first))
        #expect(a === b)
        #expect(try cache.bodyPattern(BodyRewriteAction(find: "x", replacement: "1", caseSensitive: false)) !== a)
        #expect(try cache.bodyPattern(BodyRewriteAction(find: "x", replacement: "1", syntax: .regex)) !== a)
    }

    @Test func catastrophicPatternTimesOutAndStrikesDisable() throws {
        let clock = BodyTestClock()
        let cache = PatternCache(bodyBudget: clock.budget(maxDuration: .milliseconds(5)))
        let action = BodyRewriteAction(find: catastrophicFind, replacement: "x", syntax: .regex)
        let p = try cache.bodyPattern(action)
        for _ in 0..<3 {
            #expect(p.replace(in: catastrophicInput, with: "x", scope: .all) == .timedOut)
        }
        #expect(cache.isBodyPatternDisabled(action))
        let reads = clock.readCount
        #expect(p.replace(in: catastrophicInput, with: "x", scope: .all) == .disabled)
        #expect(clock.readCount == reads)

        try cache.prepareBodyPattern(action)
        #expect(!cache.isBodyPatternDisabled(action))
        #expect(p.replace(in: catastrophicInput, with: "x", scope: .all) == .timedOut)
    }

    @Test func aCompletedReplaceEndsTheStrikeStreak() throws {
        let clock = BodyTestClock()
        let cache = PatternCache(bodyBudget: clock.budget(maxDuration: .milliseconds(5)))
        let action = BodyRewriteAction(find: catastrophicFind, replacement: "x", syntax: .regex)
        let p = try cache.bodyPattern(action)
        for _ in 0..<2 { #expect(p.replace(in: catastrophicInput, with: "x", scope: .all) == .timedOut) }
        #expect(p.replace(in: "aac", with: "x", scope: .all) == .replaced("x", count: 1))
        for _ in 0..<2 { #expect(p.replace(in: catastrophicInput, with: "x", scope: .all) == .timedOut) }
        #expect(!cache.isBodyPatternDisabled(action))
    }

    @Test func bodyBreakerIsSeparateFromMatchBreaker() throws {
        let matchClock = BodyTestClock(), bodyClock = BodyTestClock()
        let cache = PatternCache(budget: matchClock.budget(maxDuration: .milliseconds(2)), bodyBudget: bodyClock.budget())
        let action = BodyRewriteAction(find: catastrophicFind, replacement: "x", syntax: .regex)

        // Trip the match-side regex of the same text.
        let matching = try cache.regex(catastrophicFind, caseInsensitive: false)
        for _ in 0..<3 { #expect(matching.matches(catastrophicInput) == .timedOut) }
        #expect(cache.isRegexDisabled(catastrophicFind, caseInsensitive: false))
        #expect(!cache.isBodyPatternDisabled(action))
        #expect(try cache.bodyPattern(action).replace(in: "aac", with: "x", scope: .all) == .replaced("x", count: 1))

        // And the other way round, on a fresh cache.
        let fresh = PatternCache(budget: BodyTestClock().budget(maxDuration: .milliseconds(2)), bodyBudget: BodyTestClock().budget())
        let body = try fresh.bodyPattern(action)
        for _ in 0..<3 { #expect(body.replace(in: catastrophicInput, with: "x", scope: .all) == .timedOut) }
        #expect(fresh.isBodyPatternDisabled(action))
        #expect(!fresh.isRegexDisabled(catastrophicFind, caseInsensitive: false))
        #expect(try fresh.regex(catastrophicFind, caseInsensitive: false).matches("aac") == .matched)
    }

    @Test func disableObserversHearAboutBodyPatternsToo() throws {
        let cache = PatternCache(bodyBudget: BodyTestClock().budget())
        let heard = OSAllocatedUnfairLock(initialState: 0)
        cache.addDisableObserver { heard.withLock { $0 += 1 } }
        let p = try cache.bodyPattern(BodyRewriteAction(find: catastrophicFind, replacement: "x", syntax: .regex))
        for _ in 0..<3 { _ = p.replace(in: catastrophicInput, with: "x", scope: .all) }
        #expect(heard.withLock { $0 } == 1)
    }

    @Test func cancellationStopsReplace() async throws {
        // The clock cancels the running task on its third read; the scan must stop at the next
        // progress callback instead of running the (exponential) match to the end.
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let budget = RegexBudget(maxDuration: .seconds(100_000), maxStrikes: 3, clock: {
            let n = reads.withLock { $0 += 1; return $0 }
            if n == 3 { withUnsafeCurrentTask { $0?.cancel() } }
            return .zero
        })
        let cache = PatternCache(bodyBudget: budget)
        let action = BodyRewriteAction(find: catastrophicFind, replacement: "x", syntax: .regex)
        let p = try cache.bodyPattern(action)
        let result = await Task { p.replace(in: catastrophicInput, with: "x", scope: .all) }.value
        #expect(reads.withLock { $0 } == 3)
        #expect(result == .noMatch)
        // Cancellation is not a timeout, so it never counts toward disabling the pattern.
        #expect(!cache.isBodyPatternDisabled(action))
    }

    @Test func outputOverTheCapReturnsInputTooLong() throws {
        let p = try pattern("a")
        #expect(p.replace(in: "aaaa", with: "bbbb", scope: .all, maxOutputUnits: 8) == .inputTooLong)
        #expect(p.replace(in: "aaaa", with: "bb", scope: .all, maxOutputUnits: 8) == .replaced("bbbbbbbb", count: 4))
    }
}
