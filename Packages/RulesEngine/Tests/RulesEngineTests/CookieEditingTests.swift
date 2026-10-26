import FlowStore
import Foundation
import Testing

@testable import RulesEngine

@Suite("CookieEditing")
struct CookieEditingTests {
    private func f(_ name: String, _ value: String) -> HeaderField { HeaderField(name: name, value: value) }
    private func request(_ edits: [CookieEdit], _ headers: [HeaderField], cache: PatternCache = PatternCache())
        -> CookieEditResult
    {
        CookieEditing.applyToRequest(edits, headers: headers, allowance: RegexAllowance(), cache: cache)
    }
    private func response(_ edits: [CookieEdit], _ headers: [HeaderField], cache: PatternCache = PatternCache())
        -> CookieEditResult
    {
        CookieEditing.applyToResponse(edits, headers: headers, allowance: RegexAllowance(), cache: cache)
    }

    @Test func requestSetReplacesValueInPlace() {
        let result = request([.set(name: "b", value: "9")], [f("Host", "h"), f("Cookie", "a=1; b=2; c=3"), f("X", "y")])
        #expect(result.headers == [f("Host", "h"), f("Cookie", "a=1; b=9; c=3"), f("X", "y")])
        #expect(result.patternProblem == nil)
    }

    @Test func requestSetAddsWhenMissing() {
        #expect(request([.set(name: "z", value: "1")], [f("Cookie", "a=1")]).headers == [f("Cookie", "a=1; z=1")])
        #expect(request([.set(name: "z", value: "1")], [f("Host", "h")]).headers == [f("Host", "h"), f("Cookie", "z=1")])
    }

    @Test func requestAddIfMissingKeepsExisting() {
        #expect(request([.addIfMissing(name: "a", value: "9")], [f("Cookie", "a=1")]).headers == [f("Cookie", "a=1")])
        #expect(request([.addIfMissing(name: "b", value: "9")], [f("Cookie", "a=1")]).headers == [f("Cookie", "a=1; b=9")])
    }

    @Test func requestRemove() {
        #expect(request([.remove(name: "a")], [f("Cookie", "a=1; b=2; a=3")]).headers == [f("Cookie", "b=2")])
        #expect(request([.remove(name: "a")], [f("Host", "h"), f("Cookie", "a=1")]).headers == [f("Host", "h")])
    }

    @Test func requestFindReplaceAndRegex() {
        let find = CookieEdit.findReplace(name: "a", find: "X", replacement: "y", caseSensitive: false)
        #expect(request([find], [f("Cookie", "a=xx; b=x")]).headers == [f("Cookie", "a=yy; b=x")])
        let all = CookieEdit.findReplace(name: nil, find: "1", replacement: "2", caseSensitive: true)
        #expect(request([all], [f("Cookie", "a=1; b=1")]).headers == [f("Cookie", "a=2; b=2")])
        let regex = CookieEdit.regex(name: "sid", pattern: #"(\d+)-(\d+)"#, replacement: "$2-$1", caseSensitive: true)
        #expect(request([regex], [f("Cookie", "sid=12-34; o=1-2")]).headers == [f("Cookie", "sid=34-12; o=1-2")])
        let sensitive = CookieEdit.regex(name: nil, pattern: "ABC", replacement: "z", caseSensitive: true)
        #expect(request([sensitive], [f("Cookie", "a=abc")]).headers == [f("Cookie", "a=abc")])
    }

    @Test func requestMergesSplitCookieFieldsOnlyWhenChanged() {
        let split = [f("Cookie", "a=1"), f("X", "y"), f("cookie", "b=2")]
        #expect(request([.remove(name: "zz")], split).headers == split)
        #expect(request([.set(name: "b", value: "3")], split).headers == [f("Cookie", "a=1; b=3"), f("X", "y")])
    }

    @Test func requestKeepsTheBytesOfUntouchedItems() {
        #expect(request([.set(name: "b", value: "2")], [f("Cookie", "a=1;b=1;  flag")]).headers
            == [f("Cookie", "a=1; b=2; flag")])
    }

    @Test func responseSetKeepsAttributes() {
        let result = response([.set(name: "id", value: "2")], [f("Set-Cookie", "id=1; Path=/; HttpOnly")])
        #expect(result.headers == [f("Set-Cookie", "id=2; Path=/; HttpOnly")])
    }

    @Test func responseSetAddsNewSetCookie() {
        let result = response([.set(name: "n", value: "1")], [f("Set-Cookie", "id=1; Path=/"), f("X", "y")])
        #expect(result.headers == [f("Set-Cookie", "id=1; Path=/"), f("X", "y"), f("Set-Cookie", "n=1")])
        #expect(response([.addIfMissing(name: "id", value: "9")], [f("Set-Cookie", "id=1")]).headers == [f("Set-Cookie", "id=1")])
    }

    @Test func responseRemoveDropsTheWholeField() {
        let result = response([.remove(name: "id")], [f("Set-Cookie", "id=1; Path=/"), f("Set-Cookie", "o=2")])
        #expect(result.headers == [f("Set-Cookie", "o=2")])
    }

    @Test func responseOtherSetCookiesUntouched() {
        let headers = [f("Set-Cookie", "a=1; Secure"), f("Set-Cookie", "b=2; Max-Age=5"), f("Set-Cookie", "c=3")]
        let result = response([.set(name: "b", value: "9")], headers)
        #expect(result.headers == [f("Set-Cookie", "a=1; Secure"), f("Set-Cookie", "b=9; Max-Age=5"), f("Set-Cookie", "c=3")])
        #expect(response([.remove(name: "zz")], headers).headers == headers)
    }

    @Test func responseFindReplaceAndRegexTouchValueOnly() {
        let find = CookieEdit.findReplace(name: "a", find: "Path", replacement: "X", caseSensitive: true)
        #expect(response([find], [f("Set-Cookie", "a=Path1; Path=/")]).headers == [f("Set-Cookie", "a=X1; Path=/")])
        let regex = CookieEdit.regex(name: nil, pattern: #"\d"#, replacement: "#", caseSensitive: true)
        #expect(response([regex], [f("Set-Cookie", "a=12; Max-Age=5")]).headers == [f("Set-Cookie", "a=##; Max-Age=5")])
    }

    @Test func namesAreCaseSensitive() {
        #expect(request([.remove(name: "A")], [f("Cookie", "a=1")]).headers == [f("Cookie", "a=1")])
        #expect(response([.remove(name: "A")], [f("Set-Cookie", "a=1")]).headers == [f("Set-Cookie", "a=1")])
    }

    @Test func regexTimeoutReportsPatternProblem() {
        let cache = PatternCache(budget: StepClock().budget)
        let hostile = String(repeating: "a", count: 60) + "b"
        let edit = CookieEdit.regex(name: nil, pattern: "(a|aa)+c", replacement: "z", caseSensitive: true)
        let headers = [f("Cookie", "k=\(hostile)")]
        let result = request([edit], headers, cache: cache)
        #expect(result.headers == headers)
        #expect(result.patternProblem == .patternTimedOut)
        let again = response([edit], [f("Set-Cookie", "k=\(hostile)")], cache: PatternCache(budget: StepClock().budget))
        #expect(again.patternProblem == .patternTimedOut)
    }

    @Test func disabledRegexReportsPatternDisabled() {
        let cache = PatternCache(budget: StepClock().budget)
        let hostile = String(repeating: "a", count: 60) + "b"
        let edit = CookieEdit.regex(name: nil, pattern: "(a|aa)+c", replacement: "z", caseSensitive: true)
        for _ in 0..<3 { _ = request([edit], [f("Cookie", "k=\(hostile)")], cache: cache) }
        #expect(request([edit], [f("Cookie", "k=\(hostile)")], cache: cache).patternProblem == .patternDisabled)
    }

    @Test func emptyCookieHeaderValueHandled() {
        #expect(request([.remove(name: "a")], [f("Cookie", "")]).headers == [f("Cookie", "")])
        #expect(request([.set(name: "a", value: "1")], [f("Cookie", "")]).headers == [f("Cookie", "a=1")])
        #expect(request([.set(name: "a", value: "1")], []).headers == [f("Cookie", "a=1")])
    }

    @Test func namesAndChangesAreByteWise() {
        let nfc = "\u{e9}", nfd = "e\u{301}"
        #expect(request([.remove(name: "K")], [f("Cookie", "\u{212A}=1")]).headers == [f("Cookie", "\u{212A}=1")])
        #expect(request([.remove(name: nfd)], [f("Cookie", "\(nfc)=1")]).headers == [f("Cookie", "\(nfc)=1")])
        #expect(response([.remove(name: nfd)], [f("Set-Cookie", "\(nfc)=1")]).headers == [f("Set-Cookie", "\(nfc)=1")])
        #expect(request([.set(name: "a", value: nfd)], [f("Cookie", "a=\(nfc)")]).headers == [f("Cookie", "a=\(nfd)")])
        #expect(response([.set(name: "a", value: nfd)], [f("Set-Cookie", "a=\(nfc); Path=/")]).headers
            == [f("Set-Cookie", "a=\(nfd); Path=/")])
    }

    @Test func oversizeValueRegexIsSkippedSilently() {
        let big = String(repeating: "a", count: 9000)
        let edit = CookieEdit.regex(name: nil, pattern: "a", replacement: "b", caseSensitive: true)
        let headers = [f("Cookie", "k=\(big)")]
        let result = request([edit], headers)
        #expect(result.headers == headers)
        #expect(result.patternProblem == nil)
    }

    @Test func unreadableRegexIsSkippedSilently() {
        let edit = CookieEdit.regex(name: nil, pattern: "(", replacement: "b", caseSensitive: true)
        let result = request([edit], [f("Cookie", "k=v")])
        #expect(result.headers == [f("Cookie", "k=v")])
        #expect(result.patternProblem == nil)
    }

    @Test func separatorsFollowedByCombiningMarksStillSplit() {
        let result = request([.remove(name: "a")], [f("Cookie", "a=1;\u{301}b=2")])
        #expect(result.headers == [f("Cookie", "\u{301}b=2")])
        let set = request([.set(name: "a", value: "9")], [f("Cookie", "a=1;\u{301}b=2")])
        #expect(set.headers == [f("Cookie", "a=9; \u{301}b=2")])
        let attrs = response([.set(name: "a", value: "9")], [f("Set-Cookie", "a=1;\u{301}Path=/")])
        #expect(attrs.headers == [f("Set-Cookie", "a=9;\u{301}Path=/")])
    }

    @Test func headerNamesMatchAsciiCaseOnly() {
        let kelvin = [f("Coo\u{212A}ie", "a=1")]
        #expect(request([.remove(name: "a")], kelvin).headers == kelvin)
        #expect(request([.remove(name: "a")], [f("COOKIE", "a=1")]).headers == [])
    }
}
