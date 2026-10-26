import FlowStore
import Foundation
import Testing

@testable import RulesEngine

@Suite("URLEditing")
struct URLEditingTests {
    private func target(
        _ scheme: String = "https", host: String = "a.com", port: Int = 443, method: String = "GET",
        path: String = "/x/1?q=1"
    ) -> HTTPMessageTarget {
        HTTPMessageTarget(scheme: scheme, host: host, port: port, method: method, pathAndQuery: path)
    }

    private func run(_ action: URLEditAction, _ target: HTTPMessageTarget, cache: PatternCache = PatternCache())
        -> Result<HTTPMessageTarget, URLEditFailure>
    {
        URLEditing.apply(action, to: target, allowance: RegexAllowance(), cache: cache)
    }

    @Test func resultLimitComesFromTheLimitsPassedIn() throws {
        let action = URLEditAction(mode: .findReplace, find: "x/1", replacement: String(repeating: "z", count: 10_000))
        // The default field size refuses it; a larger one the caller passes allows it.
        #expect(run(action, target()) == .failure(.invalidResult))
        let roomy = RulesLimits(fieldBytes: 20_000)
        let allowed = URLEditing.apply(action, to: target(), allowance: RegexAllowance(), cache: PatternCache(), limits: roomy)
        #expect(try allowed.get().pathAndQuery.utf8.count > 10_000)
        let tight = RulesLimits(fieldBytes: 16)
        let edit = URLEditAction(mode: .findReplace, find: "x/1", replacement: "yyyyyyyyyyyyyyyy")
        #expect(
            URLEditing.apply(edit, to: target(), allowance: RegexAllowance(), cache: PatternCache(), limits: tight)
                == .failure(.invalidResult))
    }

    @Test func regexOutputOverTheLimitIsRefused() {
        let action = URLEditAction(mode: .regex, find: "x*", replacement: String(repeating: "t", count: 50))
        #expect(
            URLEditing.apply(
                action, to: target(), allowance: RegexAllowance(), cache: PatternCache(),
                limits: RulesLimits(fieldBytes: 100)) == .failure(.inputTooLarge))
    }

    @Test func setReplacesTheWholeURL() throws {
        let result = try run(URLEditAction(mode: .set, replacement: "http://B.example.org:8080/p?z=2"), target()).get()
        #expect(result == target("http", host: "b.example.org", port: 8080, path: "/p?z=2"))
    }

    @Test func setRejectsUserinfoAndFragment() {
        for text in ["https://u:p@a.com/x", "https://a.com/x#frag", "ftp://a.com/x", "/relative", "https://a.com:0/x"] {
            #expect(run(URLEditAction(mode: .set, replacement: text), target()) == .failure(.invalidResult), "\(text)")
        }
    }

    @Test func findReplaceIsLiteralAndHonoursCase() throws {
        let insensitive = URLEditAction(mode: .findReplace, find: "A.COM", replacement: "b.com", caseSensitive: false)
        #expect(try run(insensitive, target()).get().host == "b.com")
        let sensitive = URLEditAction(mode: .findReplace, find: "A.COM", replacement: "b.com", caseSensitive: true)
        #expect(try run(sensitive, target()).get() == target())
        let literal = URLEditAction(mode: .findReplace, find: "x/1?q", replacement: "y/2?r")
        #expect(try run(literal, target()).get().pathAndQuery == "/y/2?r=1")
        let dot = URLEditAction(mode: .findReplace, find: "a.com", replacement: "z.com")
        #expect(try run(dot, target(host: "abcom")).get().host == "abcom")
    }

    @Test func regexUsesFindModeAndTemplate() throws {
        let action = URLEditAction(mode: .regex, find: #"/x/(\d+)"#, replacement: "/y/$1")
        let result = try run(action, target(path: "/x/1")).get()
        #expect(result.pathAndQuery == "/y/1")
        #expect(result.host == "a.com")
    }

    @Test func regexInputOverCapIsRejected() {
        let long = target(path: "/" + String(repeating: "a", count: 8200))
        #expect(run(URLEditAction(mode: .regex, find: "a", replacement: "b"), long) == .failure(.inputTooLarge))
    }

    @Test func regexTimeoutUsesTheSharedAllowance() {
        let cache = PatternCache(budget: StepClock().budget)
        let hostile = target(path: "/" + String(repeating: "a", count: 60) + "b")
        let action = URLEditAction(mode: .regex, find: "/(a|aa)+c", replacement: "/")
        #expect(run(action, hostile, cache: cache) == .failure(.patternTimedOut))
    }

    @Test func regexThatMatchesNothingKeepsTheTarget() throws {
        let action = URLEditAction(mode: .regex, find: "nomatch", replacement: "z")
        #expect(try run(action, target()).get() == target())
    }

    @Test func unreadableRegexIsRejectedLikeAnInvalidResult() {
        let action = URLEditAction(mode: .regex, find: "(", replacement: "z")
        #expect(run(action, target()) == .failure(.invalidResult))
    }

    @Test func comparisonIsByteWiseNotCanonical() throws {
        // "é" as one scalar vs "e" + combining acute: equal to Swift's ==, different bytes.
        let nfc = "\u{e9}", nfd = "e\u{301}"
        let action = URLEditAction(mode: .findReplace, find: nfd, replacement: "X", caseSensitive: true)
        #expect(try run(action, target(path: "/\(nfc)")).get().pathAndQuery == "/\(nfc)")
        #expect(try run(action, target(path: "/\(nfd)")).get().pathAndQuery == "/X")
    }

    @Test func defaultPortIsOmittedInText() {
        #expect(URLEditing.text(of: target()) == "https://a.com/x/1?q=1")
        #expect(URLEditing.text(of: target("http", port: 80, path: "/")) == "http://a.com/")
        #expect(URLEditing.text(of: target(port: 8443, path: "/")) == "https://a.com:8443/")
        #expect(URLEditing.text(of: target("http", port: 443, path: "/")) == "http://a.com:443/")
    }

    @Test func ipv6HostKeepsBrackets() throws {
        let parsed = try #require(URLEditing.parse("http://[::1]:8080/p", method: "GET"))
        #expect(parsed.host == "[::1]")
        #expect(parsed.port == 8080)
        #expect(URLEditing.text(of: parsed) == "http://[::1]:8080/p")
        let plain = try #require(URLEditing.parse("https://[2001:db8::1]/", method: "GET"))
        #expect(plain.port == 443)
        #expect(URLEditing.text(of: plain) == "https://[2001:db8::1]/")
    }

    @Test func methodIsKept() throws {
        let post = target(method: "POST")
        let result = try run(URLEditAction(mode: .set, replacement: "https://c.com/"), post).get()
        #expect(result.method == "POST")
        #expect(URLEditing.parse("https://c.com", method: "PUT")?.method == "PUT")
    }

    @Test func parseHandlesBareAuthorityAndQuery() throws {
        #expect(try #require(URLEditing.parse("https://c.com", method: "GET")).pathAndQuery == "/")
        #expect(try #require(URLEditing.parse("https://c.com?a=1", method: "GET")).pathAndQuery == "/?a=1")
        #expect(URLEditing.parse("https://c.com:/x", method: "GET") == nil)
        #expect(URLEditing.parse("https://:80/x", method: "GET") == nil)
        #expect(URLEditing.parse("https://c.com/a b", method: "GET") == nil)
    }

    @Test func separatorsFollowedByCombiningMarksStillSplit() throws {
        let parsed = try #require(URLEditing.parse("https://a.com/x\u{301}/y?\u{301}q=1", method: "GET"))
        #expect(parsed.host == "a.com")
        #expect(parsed.pathAndQuery == "/x\u{301}/y?\u{301}q=1")
        // "/" + mark is one Character, which the (existing) path validator's hasPrefix("/") refuses: rejected, not mis-split.
        #expect(URLEditing.parse("https://a.com/\u{301}x", method: "GET") == nil)
        let query = try #require(URLEditing.parse("https://a.com?\u{301}q=1", method: "GET"))
        #expect(query.pathAndQuery == "/?\u{301}q=1")
    }
}
