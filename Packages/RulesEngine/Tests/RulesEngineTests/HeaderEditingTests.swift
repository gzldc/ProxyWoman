import FlowStore
import Foundation
import Testing

@testable import RulesEngine

@Suite("HeaderEditing")
struct HeaderEditingTests {
    private func f(_ name: String, _ value: String) -> HeaderField { HeaderField(name: name, value: value) }
    private func run(_ edits: [HeaderEdit], _ headers: [HeaderField], cache: PatternCache = PatternCache()) -> HeaderEditResult {
        headers.applying(edits, allowance: RegexAllowance(), cache: cache)
    }

    @Test func addIfMissingAddsOnlyWhenAbsent() {
        let present = [f("x-a", "1")]
        let kept = run([.addIfMissing(name: "X-A", value: "2")], present)
        #expect(kept.headers == present)
        #expect(!kept.changed && !kept.matchedNothing)
        let added = run([.addIfMissing(name: "X-A", value: "2")], [f("Host", "h")])
        #expect(added.headers == [f("Host", "h"), f("X-A", "2")])
        #expect(added.changed && !added.matchedNothing)
    }

    @Test func appendToValueTouchesEveryFieldOfThatName() {
        let headers = [f("Accept", "a"), f("X", "y"), f("accept", "b")]
        let result = run([.appendToValue(name: "ACCEPT", text: ",c")], headers)
        #expect(result.headers == [f("Accept", "a,c"), f("X", "y"), f("accept", "b,c")])
        #expect(result.changed && !result.matchedNothing && result.patternProblem == nil)
        let none = run([.appendToValue(name: "Accept", text: ",c")], [f("X", "y")])
        #expect(none.headers == [f("X", "y")])
        #expect(none.matchedNothing && !none.changed)
    }

    @Test func findReplaceWorksPerFieldValue() {
        let headers = [f("Set-Cookie", "a=foo"), f("Other", "foo"), f("set-cookie", "b=foo; x=foo")]
        let sensitive = run([.findReplace(name: "Set-Cookie", find: "foo", replacement: "bar", caseSensitive: true)], headers)
        #expect(sensitive.headers == [f("Set-Cookie", "a=bar"), f("Other", "foo"), f("set-cookie", "b=bar; x=bar")])
        #expect(sensitive.changed)
        let upper = run([.findReplace(name: "Other", find: "FOO", replacement: "z", caseSensitive: false)], headers)
        #expect(upper.headers[1] == f("Other", "z"))
        #expect(upper.headers[0] == headers[0])
        let exact = run([.findReplace(name: "Other", find: "FOO", replacement: "z", caseSensitive: true)], headers)
        #expect(exact.headers == headers)
        #expect(exact.matchedNothing && !exact.changed)
    }

    @Test func regexReplacesWithTemplate() {
        let result = run(
            [.regex(name: "X-Id", pattern: #"(\d+)"#, replacement: "n$1", caseSensitive: true)],
            [f("x-id", "a12b3"), f("Y", "9")])
        #expect(result.headers == [f("x-id", "an12bn3"), f("Y", "9")])
        #expect(result.changed && !result.matchedNothing && result.patternProblem == nil)
        let miss = run([.regex(name: "X-Id", pattern: "zzz", replacement: "q", caseSensitive: true)], [f("x-id", "a")])
        #expect(miss.matchedNothing && !miss.changed)
    }

    @Test func regexTimeoutIsRecordedAndSkipped() {
        let cache = PatternCache(budget: StepClock().budget)
        let hostile = String(repeating: "a", count: 60) + "b"
        let headers = [f("X", hostile)]
        let result = run([.regex(name: "X", pattern: "(a|aa)+c", replacement: "z", caseSensitive: true)], headers, cache: cache)
        #expect(result.headers == headers)
        #expect(result.patternProblem == .patternTimedOut)
        #expect(!result.changed)
    }

    @Test func disabledRegexReportsPatternDisabled() {
        let cache = PatternCache(budget: StepClock().budget)
        let hostile = String(repeating: "a", count: 60) + "b"
        let edit = HeaderEdit.regex(name: "X", pattern: "(a|aa)+c", replacement: "z", caseSensitive: true)
        for _ in 0..<3 { _ = run([edit], [f("X", hostile)], cache: cache) }
        #expect(run([edit], [f("X", hostile)], cache: cache).patternProblem == .patternDisabled)
    }

    @Test func unreadablePatternNeverApplies() {
        let headers = [f("X", "a")]
        let result = run([.regex(name: "X", pattern: "(", replacement: "z", caseSensitive: true)], headers)
        #expect(result.headers == headers && result.patternProblem == nil)
    }

    @Test func newMethodsComposeInOrder() {
        let result = run(
            [
                .addIfMissing(name: "X-T", value: "a"), .appendToValue(name: "X-T", text: "b"),
                .findReplace(name: "X-T", find: "ab", replacement: "Z", caseSensitive: true),
            ], [])
        #expect(result.headers == [f("X-T", "Z")])
        #expect(result.changed && !result.matchedNothing)
    }

    @Test func legacyOperationsMatchTheOldAppliedResult() {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(bound))
        }
        let names = ["X-A", "x-a", "X-B", "Accept", "accept", "Y"]
        for _ in 0..<200 {
            let headers = (0..<next(6)).map { _ in f(names[next(names.count)], "v\(next(9))") }
            let operations: [HeaderEdit] = (0..<(1 + next(5))).map { _ in
                let name = names[next(names.count)]
                switch next(3) {
                case 0: return .set(name: name, value: "s\(next(9))")
                case 1: return .append(name: name, value: "p\(next(9))")
                default: return .remove(name: name)
                }
            }
            let result = headers.applying(operations, allowance: RegexAllowance(), cache: PatternCache())
            #expect(result.headers == headers.applying(operations))
            #expect(!result.matchedNothing && result.patternProblem == nil)
        }
    }
}
