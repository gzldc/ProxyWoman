import FlowStore
import Foundation
import Testing

@testable import RulesEngine

private func target(
    _ host: String = "api.example.com", scheme: String = "https", port: Int = 443,
    method: String = "GET", path: String = "/v1/items"
) -> HTTPMessageTarget {
    HTTPMessageTarget(scheme: scheme, host: host, port: port, method: method, pathAndQuery: path)
}

private func hostMatcher(_ pattern: String, _ syntax: PatternSyntax) -> RuleMatcher {
    RuleMatcher(hostPattern: pattern, hostSyntax: syntax)
}

private func code(_ matcher: RuleMatcher) -> (RuleValidationError.Code, RuleValidationError.Field)? {
    do { try matcher.validate(); return nil } catch let error as RuleValidationError { return (error.code, error.field) } catch { return nil }
}

@Suite("RuleMatcherSyntax")
struct RuleMatcherSyntaxTests {
    private let hostile = "/" + String(repeating: "a", count: 60) + "b"

    @Test func wildcardHostMatchesAcrossDots() {
        let star = hostMatcher("*.example.com", .wildcard)
        #expect(star.matches(target("a.b.example.com"), status: nil))
        #expect(!star.matches(target("example.com"), status: nil))
        let one = hostMatcher("api-?.example.com", .wildcard)
        #expect(one.matches(target("api-1.example.com"), status: nil))
        #expect(!one.matches(target("api-12.example.com"), status: nil))
    }

    @Test func wildcardHostIsCaseAndTrailingDotInsensitive() {
        let matcher = hostMatcher("*.Example.com", .wildcard)
        #expect(matcher.matches(target("API.Example.COM."), status: nil))
    }

    @Test func wildcardHostIPv6SpellingsMatch() {
        let matcher = hostMatcher("2001:db8::1", .wildcard)
        #expect(matcher.matches(target("[2001:0db8:0:0:0:0:0:1]"), status: nil))
        #expect(!matcher.matches(target("[2001:0db8:0:0:0:0:0:2]"), status: nil))
    }

    @Test func regexHostFullMatch() {
        let matcher = hostMatcher(#"(a|b)\.example\.com"#, .regex)
        #expect(matcher.matches(target("a.example.com"), status: nil))
        #expect(matcher.matches(target("B.Example.com."), status: nil))
        #expect(!matcher.matches(target("xa.example.com"), status: nil))
        // `^` and `$` are redundant because matching is anchored anyway.
        #expect(hostMatcher(#"^(a|b)\.example\.com$"#, .regex).matches(target("a.example.com"), status: nil))
    }

    @Test func regexHostInputIsCappedAt255Bytes() {
        let matcher = hostMatcher(".*", .regex)
        #expect(matcher.matches(target(String(repeating: "a", count: 255)), status: nil))
        #expect(!matcher.matches(target(String(repeating: "a", count: 256)), status: nil))
    }

    @Test func wildcardPathMatchesRawPathAndQuery() {
        let matcher = RuleMatcher(path: .wildcard("/api/*/items?id=*"))
        #expect(matcher.matches(target(path: "/api/v1/items?id=7"), status: nil))
        #expect(!matcher.matches(target(path: "/api/v1/items"), status: nil))
        #expect(!matcher.matches(target(path: "/API/v1/items?id=7"), status: nil))
    }

    @Test func pathIsNotPercentDecoded() {
        #expect(!RuleMatcher(path: .wildcard("/a b")).matches(target(path: "/a%20b"), status: nil))
        #expect(RuleMatcher(path: .wildcard("/a%20b")).matches(target(path: "/a%20b"), status: nil))
        #expect(!RuleMatcher(path: .regex("/a b")).matches(target(path: "/a%20b"), status: nil))
        #expect(RuleMatcher(path: .regex("/a%20b")).matches(target(path: "/a%20b"), status: nil))
    }

    @Test func regexPathIsCaseSensitiveAndAnchored() {
        let matcher = RuleMatcher(path: .regex("/v[0-9]+/items"))
        #expect(matcher.matches(target(path: "/v12/items"), status: nil))
        #expect(!matcher.matches(target(path: "/V12/items"), status: nil))
        #expect(!matcher.matches(target(path: "/v12/items/extra"), status: nil))
        #expect(!matcher.matches(target(path: "/x/v12/items"), status: nil))
        #expect(RuleMatcher(path: .regex("(?i)/v[0-9]+/items")).matches(target(path: "/V12/ITEMS"), status: nil))
    }

    @Test func regexTimeoutMeansNoMatchAndIsReported() throws {
        let cache = PatternCache(budget: StepClock().budget)
        let matcher = RuleMatcher(path: .regex("/(a|aa)+c"))
        #expect(matcher.evaluate(target(path: hostile), status: nil, cache: cache) == .patternTimedOut)
        #expect(!matcher.matches(target(path: hostile), status: nil, cache: cache))
        let cached = try cache.regex("/(a|aa)+c", caseInsensitive: false)
        #expect(cached.timeoutCount == 2)
        // A harmless input still matches under the same (fake) budget and ends the streak.
        #expect(matcher.evaluate(target(path: "/aac"), status: nil, cache: cache) == .matched)
        #expect(cached.timeoutCount == 0)
    }

    @Test func aDisabledPatternIsReportedAsDisabledNotAsAMiss() throws {
        let cache = PatternCache(budget: StepClock().budget)
        let matcher = RuleMatcher(path: .regex("/(a|aa)+c"))
        for _ in 0..<3 { #expect(matcher.evaluate(target(path: hostile), status: nil, cache: cache) == .patternTimedOut) }
        #expect(matcher.hasDisabledPattern(in: cache))
        #expect(matcher.evaluate(target(path: hostile), status: nil, cache: cache) == .patternDisabled)
        // Even a harmless input is not matched by a disabled pattern.
        #expect(matcher.evaluate(target(path: "/aac"), status: nil, cache: cache) == .patternDisabled)
    }

    @Test func aFieldThatAlreadyDoesNotMatchHidesTheDisabledPattern() {
        let cache = PatternCache(budget: StepClock().budget)
        let trip = RuleMatcher(path: .regex("/(a|aa)+c"))
        for _ in 0..<3 { _ = trip.evaluate(target(path: hostile), status: nil, cache: cache) }
        let guarded = RuleMatcher(port: 8080, path: .regex("/(a|aa)+c"))
        #expect(guarded.evaluate(target(path: hostile), status: nil, cache: cache) == .noMatch)
        #expect(RuleMatcher(method: "POST", path: .regex("/(a|aa)+c")).evaluate(target(path: hostile), status: nil, cache: cache) == .noMatch)
        #expect(RuleMatcher(path: .regex("/(a|aa)+c"), statusRange: 500...599).evaluate(target(path: hostile), status: 200, cache: cache) == .noMatch)
    }

    @Test func hostRegexTimeoutIsReportedToo() {
        let cache = PatternCache(budget: StepClock().budget)
        let host = hostMatcher("(a|aa)+c", .regex)
        let slow = target(String(repeating: "a", count: 60) + "b")
        #expect(host.evaluate(slow, status: nil, cache: cache) == .patternTimedOut)
        #expect(!host.hasDisabledPattern(in: cache))
        for _ in 0..<2 { _ = host.evaluate(slow, status: nil, cache: cache) }
        #expect(host.hasDisabledPattern(in: cache))
        #expect(host.evaluate(slow, status: nil, cache: cache) == .patternDisabled)
    }

    @Test func literalAndWildcardMatchersNeverReportPatternProblems() {
        let cache = PatternCache()
        #expect(RuleMatcher(hostPattern: "*.example.com").evaluate(target(), status: nil, cache: cache) == .matched)
        #expect(RuleMatcher(hostPattern: "other").evaluate(target(), status: nil, cache: cache) == .noMatch)
        #expect(!RuleMatcher(hostPattern: "x*", path: .wildcard("/a*"), hostSyntax: .wildcard).hasDisabledPattern(in: cache))
    }

    @Test func catastrophicPathRuleDoesNotMatchAndDoesNotHang() throws {
        // Real clock on a private cache: the ICU progress callback cuts the match off.
        let cache = PatternCache()
        let matcher = RuleMatcher(path: .regex("/(a|aa)+c"))
        for _ in 0..<3 { #expect(!matcher.matches(target(path: hostile), status: nil, cache: cache)) }
        #expect(cache.isRegexDisabled("/(a|aa)+c", caseInsensitive: false))
        // A disabled pattern never matches, even a harmless input.
        #expect(!matcher.matches(target(path: "/aac"), status: nil, cache: cache))
    }

    struct LiteralCase: Sendable {
        var matcher: RuleMatcher
        var host: String
        var port: Int
        var method: String
        var path: String
        var expected: Bool
    }

    static let literalCases: [LiteralCase] = [
        LiteralCase(matcher: RuleMatcher(hostPattern: "example.com"), host: "Example.COM.", port: 443, method: "GET", path: "/", expected: true),
        LiteralCase(matcher: RuleMatcher(hostPattern: "*.example.com"), host: "example.com", port: 443, method: "GET", path: "/", expected: false),
        LiteralCase(matcher: RuleMatcher(hostPattern: "*.example.com"), host: "a.b.example.com", port: 443, method: "GET", path: "/", expected: true),
        LiteralCase(matcher: RuleMatcher(hostPattern: "a*.com"), host: "ab.com", port: 443, method: "GET", path: "/", expected: false),
        LiteralCase(matcher: RuleMatcher(port: 443), host: "x.test", port: 8443, method: "GET", path: "/", expected: false),
        LiteralCase(matcher: RuleMatcher(method: "GET"), host: "x.test", port: 443, method: "get", path: "/", expected: false),
        LiteralCase(matcher: RuleMatcher(path: .prefix("/api/")), host: "x.test", port: 443, method: "GET", path: "/api/x?y=1", expected: true),
        LiteralCase(matcher: RuleMatcher(path: .exact("/a")), host: "x.test", port: 443, method: "GET", path: "/a?x", expected: false),
        LiteralCase(matcher: RuleMatcher(hostPattern: "[2001:db8::1]"), host: "2001:0db8:0:0:0:0:0:1", port: 443, method: "GET", path: "/", expected: true),
        LiteralCase(matcher: RuleMatcher(path: .prefix("/A")), host: "x.test", port: 443, method: "GET", path: "/a", expected: false),
    ]

    @Test(arguments: literalCases) func literalBehaviourUnchangedTable(_ item: LiteralCase) {
        let message = HTTPMessageTarget(
            scheme: "https", host: item.host, port: item.port, method: item.method, pathAndQuery: item.path)
        #expect(item.matcher.matches(message, status: nil) == item.expected)
        #expect(item.matcher.hostSyntax == .literal)
    }

    @Test func validationRejectsWithTypedFieldErrors() {
        #expect(code(hostMatcher(#"a\x"#, .wildcard))?.0 == .invalidWildcard)
        #expect(code(hostMatcher(#"a\x"#, .wildcard))?.1 == .hostPattern)
        #expect(code(hostMatcher("a b", .wildcard))?.0 == .invalidWildcard)
        #expect(code(hostMatcher("a/b", .wildcard))?.0 == .invalidWildcard)
        #expect(code(hostMatcher("", .wildcard))?.0 == .invalidWildcard)
        #expect(code(hostMatcher(String(repeating: "a", count: 256), .wildcard))?.0 == .invalidWildcard)
        #expect(code(hostMatcher("*.example.com", .wildcard)) == nil)

        #expect(code(hostMatcher("(", .regex))?.0 == .invalidRegex)
        #expect(code(hostMatcher("(a+)+", .regex))?.0 == .regexTooComplex)
        #expect(code(hostMatcher("(a+)+", .regex))?.1 == .hostPattern)
        #expect(code(hostMatcher(#"(a|b)\.example\.com"#, .regex)) == nil)

        let bad = code(RuleMatcher(path: .regex("[a-")))
        #expect(bad?.0 == .invalidRegex && bad?.1 == .path)
        let complex = code(RuleMatcher(path: .regex("(a+)+")))
        #expect(complex?.0 == .regexTooComplex && complex?.1 == .path)
        let wildcard = code(RuleMatcher(path: .wildcard(#"/a\x"#)))
        #expect(wildcard?.0 == .invalidWildcard && wildcard?.1 == .path)
        #expect(code(RuleMatcher(path: .wildcard("/a#b")))?.0 == .invalidPath)
        #expect(code(RuleMatcher(path: .wildcard("/a b")))?.0 == .invalidPath)
        #expect(code(RuleMatcher(path: .wildcard("/api/*"))) == nil)

        #expect(code(RuleMatcher(path: .regex("(?i)^/v[0-9]+/.*"))) == nil)
        // `#` and whitespace are legal in a regular expression.
        #expect(code(RuleMatcher(path: .regex(#"/a#b\s"#))) == nil)
        // Length is still bounded by the field limit.
        let long = code(RuleMatcher(path: .regex(String(repeating: "a", count: 9000))))
        #expect(long?.0 == .fieldTooLong && long?.1 == .path)
    }

    @Test func validationNeitherCompilesIntoTheCacheNorResetsStrikes() throws {
        let cache = PatternCache(budget: StepClock().budget)
        let matcher = RuleMatcher(path: .regex("/(a|aa)+c"))
        for _ in 0..<3 { _ = matcher.evaluate(target(path: hostile), status: nil, cache: cache) }
        #expect(matcher.hasDisabledPattern(in: cache))
        // The editor validates on every keystroke: that must not undo the circuit breaker.
        try matcher.validate()
        #expect(matcher.hasDisabledPattern(in: cache))
        let before = cache.count
        try RuleMatcher(hostPattern: "(x|y)+z", path: .regex("/new"), hostSyntax: .regex).validate()
        try RuleMatcher(path: .wildcard("/w*")).validate()
        #expect(cache.count == before)
    }

    @Test func preparingPatternsReEnablesThem() throws {
        let cache = PatternCache(budget: StepClock().budget)
        let matcher = RuleMatcher(path: .regex("/(a|aa)+c"))
        for _ in 0..<3 { _ = matcher.evaluate(target(path: hostile), status: nil, cache: cache) }
        #expect(matcher.hasDisabledPattern(in: cache))
        matcher.preparePatterns(in: cache)
        #expect(!matcher.hasDisabledPattern(in: cache))

        let host = hostMatcher("(a|aa)+c", .regex)
        for _ in 0..<3 { _ = host.evaluate(target(String(repeating: "a", count: 60) + "b"), status: nil, cache: cache) }
        #expect(host.hasDisabledPattern(in: cache))
        host.preparePatterns(in: cache)
        #expect(!host.hasDisabledPattern(in: cache))
        // A matcher that is not valid or not advanced is skipped without a trace.
        RuleMatcher(path: .regex("(")).preparePatterns(in: cache)
        RuleMatcher(hostPattern: "a.test").preparePatterns(in: cache)
    }

    @Test func statusRangeStillRequestRuleError() {
        let rule = LegacyRule(
            id: UUID(), name: "r", enabled: true, order: 0,
            matcher: RuleMatcher(path: .regex("/a.*"), statusRange: 400...499, hostSyntax: .wildcard),
            action: .breakpoint(direction: .request, mode: .headers))
        do {
            try rule.validate()
            Issue.record("expected a status range error")
        } catch let error as RuleValidationError {
            #expect(error.code == .statusRangeNotAllowed && error.field == .statusRange)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func usesAdvancedSyntaxReflectsHostAndPath() {
        #expect(!RuleMatcher().usesAdvancedSyntax)
        #expect(!RuleMatcher(hostPattern: "a.com", path: .prefix("/x")).usesAdvancedSyntax)
        #expect(hostMatcher("*.a.com", .wildcard).usesAdvancedSyntax)
        #expect(hostMatcher("a", .regex).usesAdvancedSyntax)
        #expect(RuleMatcher(path: .wildcard("/*")).usesAdvancedSyntax)
        #expect(RuleMatcher(path: .regex("/.*")).usesAdvancedSyntax)
    }
}
