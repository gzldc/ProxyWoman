import FlowStore
import Foundation
import Testing

@testable import RulesEngine

@Suite("BodyRewriter")
struct BodyRewriterTests {
    private let r1 = UUID(), r2 = UUID()

    private func step(
        _ id: UUID, _ find: String, _ replacement: String, syntax: BodyFindSyntax = .text, caseSensitive: Bool = true,
        scope: BodyReplaceScope = .all
    ) -> BodyRewriteStep {
        BodyRewriteStep(ruleID: id, action: BodyRewriteAction(
            find: find, replacement: replacement, syntax: syntax, caseSensitive: caseSensitive, scope: scope))
    }

    private func apply(
        _ steps: [BodyRewriteStep], _ body: Data, type: String? = "text/plain", encoding: String? = nil,
        limits: RulesLimits = RulesLimits(), cache: PatternCache = PatternCache()
    ) async throws -> BodyRewriteResult {
        try await BodyRewriter.apply(
            steps: steps, to: body, contentType: type, contentEncoding: encoding, limits: limits, cache: cache)
    }

    private func outcome(_ id: UUID, _ code: RuleOutcomeCode) -> RuleOutcome { RuleOutcome(ruleID: id, code: code) }

    private func rewritten(_ result: BodyRewriteResult) -> (String, [RuleOutcome])? {
        guard case .rewritten(let data, let outcomes) = result else { return nil }
        return (String(decoding: data, as: UTF8.self), outcomes)
    }

    @Test func replacesAllCaseSensitive() async throws {
        let result = try await apply([step(r1, "cat", "dog")], Data("cat Cat cat".utf8))
        let (text, outcomes) = try #require(rewritten(result))
        #expect(text == "dog Cat dog")
        #expect(outcomes == [outcome(r1, .applied)])
    }

    @Test func caseInsensitiveText() async throws {
        let result = try await apply([step(r1, "cat", "dog", caseSensitive: false)], Data("cat Cat CAT".utf8))
        #expect(rewritten(result)?.0 == "dog dog dog")
    }

    @Test func firstOnly() async throws {
        let result = try await apply([step(r1, "a", "o", scope: .first)], Data("banana".utf8))
        #expect(rewritten(result)?.0 == "bonana")
    }

    @Test func regexCaptureTemplate() async throws {
        let result = try await apply(
            [step(r1, #"(\d+)-(\d+)"#, "$2-$1", syntax: .regex)], Data("10-20 and 3-4".utf8), type: "application/json")
        #expect(rewritten(result)?.0 == "20-10 and 4-3")
    }

    @Test func stepsApplyInOrderOnTheSameBuffer() async throws {
        let result = try await apply([step(r1, "a", "b"), step(r2, "b", "c")], Data("aab".utf8))
        let (text, outcomes) = try #require(rewritten(result))
        #expect(text == "ccc")
        #expect(outcomes == [outcome(r1, .applied), outcome(r2, .applied)])
    }

    @Test func outcomesPerStepAppliedAndNoMatch() async throws {
        let result = try await apply([step(r1, "zzz", "x"), step(r2, "a", "b")], Data("aaa".utf8))
        let (text, outcomes) = try #require(rewritten(result))
        #expect(text == "bbb")
        #expect(outcomes == [outcome(r1, .bodyNoMatch), outcome(r2, .applied)])
    }

    @Test func actionIndexIsKeptOnEveryOutcome() async throws {
        let labelled = BodyRewriteStep(
            ruleID: r1, actionIndex: 1, action: BodyRewriteAction(find: "cat", replacement: "dog"))
        let plain = step(r2, "zzz", "x")
        let result = try await apply([labelled, plain], Data("cat".utf8))
        let (text, outcomes) = try #require(rewritten(result))
        #expect(text == "dog")
        #expect(
            outcomes == [
                RuleOutcome(ruleID: r1, code: .applied, actionIndex: 1), RuleOutcome(ruleID: r2, code: .bodyNoMatch),
            ])

        // A whole-message skip names the same action.
        let skipped = try await apply([labelled, plain], Data("cat".utf8), type: "image/png")
        #expect(
            skipped
                == .unchanged([
                    RuleOutcome(ruleID: r1, code: .bodySkippedNotText, actionIndex: 1),
                    RuleOutcome(ruleID: r2, code: .bodySkippedNotText),
                ]))
    }

    @Test func noMatchReturnsUnchangedWithOriginalBytesUntouched() async throws {
        let body = TestCompression.gzip(Data("nothing here".utf8))
        let result = try await apply([step(r1, "zzz", "x")], body, encoding: "gzip")
        #expect(result == .unchanged([outcome(r1, .bodyNoMatch)]))
    }

    @Test func gzipBodyIsRewrittenToPlainText() async throws {
        let body = TestCompression.gzip(Data("hello world".utf8))
        let result = try await apply([step(r1, "world", "there")], body, encoding: "gzip")
        let (text, outcomes) = try #require(rewritten(result))
        #expect(text == "hello there")
        #expect(outcomes == [outcome(r1, .applied)])
    }

    @Test func gzipNoMatchReturnsUnchanged() async throws {
        let body = TestCompression.gzip(Data("hello world".utf8))
        let result = try await apply([step(r1, "absent", "x")], body, encoding: "gzip")
        #expect(result == .unchanged([outcome(r1, .bodyNoMatch)]))
    }

    @Test func appliedButIdenticalBytesStayUnchanged() async throws {
        let body = TestCompression.gzip(Data("same".utf8))
        let result = try await apply([step(r1, "same", "same")], body, encoding: "gzip")
        #expect(result == .unchanged([outcome(r1, .applied)]))
    }

    @Test func notTextSkipsAllSteps() async throws {
        let steps = [step(r1, "a", "b"), step(r2, "c", "d")]
        let expected = BodyRewriteResult.unchanged([outcome(r1, .bodySkippedNotText), outcome(r2, .bodySkippedNotText)])
        #expect(try await apply(steps, Data("abc".utf8), type: "image/png") == expected)
        #expect(try await apply(steps, Data("abc".utf8), type: nil) == expected)
        #expect(try await apply(steps, Data("abc".utf8), type: "text/event-stream") == expected)
    }

    @Test func unknownEncodingSkips() async throws {
        let steps = [step(r1, "a", "b"), step(r2, "c", "d")]
        let result = try await apply(steps, Data("abc".utf8), encoding: "zstd")
        #expect(result == .unchanged([outcome(r1, .bodySkippedUndecodable), outcome(r2, .bodySkippedUndecodable)]))
        let corrupt = try await apply(steps, Data("not gzip at all, really not".utf8), encoding: "gzip")
        #expect(corrupt == .unchanged([outcome(r1, .bodySkippedUndecodable), outcome(r2, .bodySkippedUndecodable)]))
    }

    @Test func multiMemberGzipIsSkippedUndecodableAndUnchanged() async throws {
        let body = TestCompression.gzip(Data("hello ".utf8)) + TestCompression.gzip(Data("world".utf8))
        let result = try await apply([step(r1, "hello", "bye")], body, encoding: "gzip")
        #expect(result == .unchanged([outcome(r1, .bodySkippedUndecodable)]))
    }

    /// A page whose compressed form spans many 4 KiB decoder slices.
    private func largePage() -> (text: String, marker: String) {
        let marker = "NEEDLE-\(UUID().uuidString)"
        let noise = String(decoding: noisyText(bytes: 120 * 1024), as: UTF8.self)
        return ("<html><body>\(noise)<p>\(marker)</p>\(noise.prefix(512))</body></html>", marker)
    }

    @Test func largeCompressedPageIsRewrittenForEveryCoding() async throws {
        let (text, marker) = largePage()
        let plain = Data(text.utf8)
        let encoded: [(String, Data)] = [
            ("gzip", TestCompression.gzip(plain)), ("deflate", TestCompression.zlibWrapped(plain)),
            ("deflate", TestCompression.rawDeflate(plain)), ("br", TestCompression.brotli(plain)),
        ]
        for (coding, body) in encoded {
            #expect(body.count > 64 * 1024, "\(coding) fixture spans many slices")
            let result = try await apply(
                [step(r1, marker, "REPLACED")], body, type: "text/html", encoding: coding, limits: RulesLimits(rewriteBodyBytes: 1 << 20))
            let (rewrittenText, outcomes) = try #require(rewritten(result), "\(coding)")
            #expect(rewrittenText == text.replacingOccurrences(of: marker, with: "REPLACED"), "\(coding)")
            #expect(outcomes == [outcome(r1, .applied)], "\(coding)")
        }
    }

    @Test func largeCompressedPageWithoutAMatchIsUnchanged() async throws {
        let (text, _) = largePage()
        let body = TestCompression.gzip(Data(text.utf8))
        let result = try await apply(
            [step(r1, "absent-\(UUID().uuidString)", "x")], body, type: "text/html", encoding: "gzip",
            limits: RulesLimits(rewriteBodyBytes: 1 << 20))
        #expect(result == .unchanged([outcome(r1, .bodyNoMatch)]))
    }

    @Test func largeMultiMemberAndTrailingDataAreSkippedUndecodable() async throws {
        let (text, marker) = largePage()
        let plain = Data(text.utf8)
        let limits = RulesLimits(rewriteBodyBytes: 1 << 20)
        let skipped = RuleOutcome(ruleID: r1, code: .bodySkippedUndecodable)
        let multi = TestCompression.gzip(plain) + TestCompression.gzip(Data("tail".utf8))
        #expect(try await apply([step(r1, marker, "X")], multi, type: "text/html", encoding: "gzip", limits: limits) == .unchanged([skipped]))
        let trailing = TestCompression.zlibWrapped(plain) + Data(repeating: 0, count: 9000)
        #expect(try await apply([step(r1, marker, "X")], trailing, type: "text/html", encoding: "deflate", limits: limits) == .unchanged([skipped]))
        let brotliTrailing = TestCompression.brotli(plain) + Data([1, 2, 3])
        #expect(try await apply([step(r1, marker, "X")], brotliTrailing, type: "text/html", encoding: "br", limits: limits) == .unchanged([skipped]))
    }

    @Test func decodedOverLimitSkips() async throws {
        let bomb = TestCompression.gzip(Data(count: 1 << 20))
        let result = try await apply(
            [step(r1, "a", "b")], bomb, encoding: "gzip", limits: RulesLimits(rewriteBodyBytes: 1024))
        #expect(result == .unchanged([outcome(r1, .bodySkippedTooLarge)]))
        // A wire body above the limit is skipped too.
        let big = try await apply([step(r1, "a", "b")], Data(count: 2048), limits: RulesLimits(rewriteBodyBytes: 1024))
        #expect(big == .unchanged([outcome(r1, .bodySkippedTooLarge)]))
    }

    @Test func replacementGrowthPastTheLimitSkipsTheWholeMessage() async throws {
        let limits = RulesLimits(rewriteBodyBytes: 1024)
        let result = try await apply(
            [step(r1, "a", "b"), step(r2, "b", String(repeating: "x", count: 600))], Data("abc".utf8), limits: limits)
        #expect(result == .unchanged([outcome(r1, .bodySkippedTooLarge), outcome(r2, .bodySkippedTooLarge)]))
        let ok = try await apply([step(r1, "b", String(repeating: "x", count: 600))], Data("abc".utf8), limits: limits)
        #expect(rewritten(ok)?.0.count == 602)
    }

    @Test func invalidUTF8Skips() async throws {
        let result = try await apply([step(r1, "a", "b")], Data([0x61, 0xff, 0x61]))
        #expect(result == .unchanged([outcome(r1, .bodySkippedUndecodable)]))
        let charset = try await apply([step(r1, "a", "b")], Data("a".utf8), type: "text/html; charset=shift_jis")
        #expect(charset == .unchanged([outcome(r1, .bodySkippedUndecodable)]))
    }

    @Test func unencodableReplacementSkipsWholeMessage() async throws {
        let steps = [step(r1, "x", "y"), step(r2, "a", "\u{e9}")]
        let result = try await apply(steps, Data("xa".utf8), type: "text/plain; charset=us-ascii")
        #expect(result == .unchanged([outcome(r1, .bodySkippedUndecodable), outcome(r2, .bodySkippedUndecodable)]))
        // Latin-1 can hold it.
        let latin = try await apply([step(r2, "a", "\u{e9}")], Data("xa".utf8), type: "text/plain; charset=iso-8859-1")
        guard case .rewritten(let data, _) = latin else { Issue.record("expected rewritten"); return }
        #expect(data == Data([0x78, 0xe9]))
    }

    @Test func utf16ByteOrderAndBOMSurviveARewrite() async throws {
        let be = Data([0xfe, 0xff, 0x00, 0x61, 0x00, 0x62])
        let result = try await apply([step(r1, "a", "c")], be, type: "text/plain; charset=utf-16")
        guard case .rewritten(let data, _) = result else { Issue.record("expected rewritten"); return }
        #expect(data == Data([0xfe, 0xff, 0x00, 0x63, 0x00, 0x62]))
        let bom = Data([0xef, 0xbb, 0xbf]) + Data("abc".utf8)
        let utf8 = try await apply([step(r1, "a", "z")], bom)
        guard case .rewritten(let data8, _) = utf8 else { Issue.record("expected rewritten"); return }
        #expect(data8 == Data([0xef, 0xbb, 0xbf]) + Data("zbc".utf8))
    }

    @Test func regexTimeoutSkipsOnlyThatStep() async throws {
        // The cheap literal step reads the clock about once per start position (61 here), far less
        // than the catastrophic one, so a 200-read budget separates them.
        let clock = BodyTestClock()
        let cache = PatternCache(bodyBudget: clock.budget(maxDuration: .milliseconds(200)))
        let body = Data(catastrophicInput.utf8)
        let result = try await apply(
            [step(r1, catastrophicFind, "x", syntax: .regex), step(r2, "b", "B")], body, cache: cache)
        let (text, outcomes) = try #require(rewritten(result))
        #expect(text == String(repeating: "a", count: 60) + "B")
        #expect(outcomes == [outcome(r1, .patternTimedOut), outcome(r2, .applied)])
    }

    @Test func disabledPatternLeavesPatternDisabled() async throws {
        let clock = BodyTestClock()
        let cache = PatternCache(bodyBudget: clock.budget())
        let slow = step(r1, catastrophicFind, "x", syntax: .regex)
        let body = Data(catastrophicInput.utf8)
        for _ in 0..<3 {
            #expect(try await apply([slow], body, cache: cache) == .unchanged([outcome(r1, .patternTimedOut)]))
        }
        #expect(try await apply([slow], body, cache: cache) == .unchanged([outcome(r1, .patternDisabled)]))
    }

    @Test func aPatternThatDoesNotCompileIsReportedAsDisabled() async throws {
        let result = try await apply([step(r1, "(", "x", syntax: .regex), step(r2, "a", "b")], Data("a".utf8))
        let (text, outcomes) = try #require(rewritten(result))
        #expect(text == "b")
        #expect(outcomes == [outcome(r1, .patternDisabled), outcome(r2, .applied)])
    }

    @Test func cancellationThrows() async {
        let task = Task { () async throws -> BodyRewriteResult in
            while !Task.isCancelled { await Task.yield() }
            return try await BodyRewriter.apply(
                steps: [step(r1, "a", "b")], to: Data("aaa".utf8), contentType: "text/plain", contentEncoding: nil,
                limits: RulesLimits(), cache: PatternCache())
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func emptyBodyIsUnchanged() async throws {
        #expect(try await apply([step(r1, "a", "b")], Data()) == .unchanged([outcome(r1, .bodySkippedNoBody)]))
        #expect(try await apply([], Data("abc".utf8)) == .unchanged([]))
    }

    @Test func rulesLimitsDefaults() {
        let limits = RulesLimits()
        #expect(limits.rewriteBodyBytes == 8_388_608)
        #expect(limits.rewriteSeconds == 30)
        #expect(RulesLimits(rewriteBodyBytes: 5, rewriteSeconds: 7).rewriteBodyBytes == 5)
    }

    @Test func outcomeCodesAreValidAndDistinct() {
        let codes: [RuleOutcomeCode] = [
            .bodyNoMatch, .bodySkippedTooLarge, .bodySkippedNotText, .bodySkippedUndecodable, .bodySkippedBreakpoint,
            .bodySkippedLocalRoute, .bodySkippedNoBody, .bodySkippedUnavailable, .bodySkippedBusy, .bodySkippedAborted, .statusSkippedLocal,
        ]
        #expect(Set(codes).count == codes.count)
        #expect(RuleOutcomeCode.bodyNoMatch.rawValue == "bodyNoMatch")
        #expect(RuleOutcomeCode.statusSkippedLocal.rawValue == "statusSkippedLocal")
    }
}
