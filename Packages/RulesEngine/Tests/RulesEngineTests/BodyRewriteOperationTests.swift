import FlowStore
import Foundation
import Testing

@testable import RulesEngine

@Suite("BodyRewriteOperation")
struct BodyRewriteOperationTests {
    private let r1 = UUID(), r2 = UUID()

    private func step(_ id: UUID, _ action: BodyRewriteAction) -> BodyRewriteStep { BodyRewriteStep(ruleID: id, action: action) }
    private func set(_ text: String) -> BodyRewriteAction { BodyRewriteAction(find: "", replacement: text, operation: .setValue) }
    private var clear: BodyRewriteAction { BodyRewriteAction(find: "", replacement: "", operation: .clear) }
    private func replace(_ find: String, _ with: String) -> BodyRewriteAction { BodyRewriteAction(find: find, replacement: with) }

    private func apply(
        _ steps: [BodyRewriteStep], _ body: Data, type: String? = "text/plain", encoding: String? = nil,
        limits: RulesLimits = RulesLimits()
    ) async throws -> BodyRewriteResult {
        try await BodyRewriter.apply(
            steps: steps, to: body, contentType: type, contentEncoding: encoding, limits: limits, cache: PatternCache())
    }

    private func rewritten(_ result: BodyRewriteResult) -> (String, [RuleOutcome])? {
        guard case .rewritten(let data, let outcomes) = result else { return nil }
        return (String(decoding: data, as: UTF8.self), outcomes)
    }

    private func outcome(_ id: UUID, _ code: RuleOutcomeCode) -> RuleOutcome { RuleOutcome(ruleID: id, code: code) }

    @Test func defaultOperationIsNotEncoded() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(BodyRewriteAction(find: "a", replacement: "b")), as: UTF8.self)
        #expect(json == #"{"caseSensitive":true,"find":"a","replacement":"b","scope":"all","syntax":"text"}"#)
        let set = String(decoding: try encoder.encode(self.set("x")), as: UTF8.self)
        #expect(set.contains(#""operation":"setValue""#))
    }

    @Test func missingOperationDecodesAsFindReplace() throws {
        let json = #"{"caseSensitive":true,"find":"a","replacement":"b","scope":"all","syntax":"text"}"#
        let decoded = try JSONDecoder().decode(BodyRewriteAction.self, from: Data(json.utf8))
        #expect(decoded.operation == .findReplace)
        #expect(decoded == BodyRewriteAction(find: "a", replacement: "b"))
    }

    @Test func setValueReplacesWholeTextBody() async throws {
        let result = try await apply([step(r1, set("new"))], Data("old".utf8))
        let (text, outcomes) = try #require(rewritten(result))
        #expect(text == "new")
        #expect(outcomes == [outcome(r1, .applied)])
    }

    @Test func clearEmptiesTheBody() async throws {
        let result = try await apply([step(r1, clear)], Data("old".utf8))
        let (text, outcomes) = try #require(rewritten(result))
        #expect(text.isEmpty)
        #expect(outcomes == [outcome(r1, .applied)])
    }

    @Test func setValueToTheSameTextIsUnchanged() async throws {
        let result = try await apply([step(r1, set("same"))], Data("same".utf8))
        #expect(result == .unchanged([outcome(r1, .applied)]))
    }

    @Test func setValueOnEmptyBodyIsSkipped() async throws {
        let result = try await apply([step(r1, set("x")), step(r2, clear)], Data())
        #expect(result == .unchanged([outcome(r1, .bodySkippedNoBody), outcome(r2, .bodySkippedNoBody)]))
    }

    @Test func setValueSkipsNonTextAndOversize() async throws {
        let notText = try await apply([step(r1, set("x"))], Data("abc".utf8), type: "image/png")
        #expect(notText == .unchanged([outcome(r1, .bodySkippedNotText)]))
        let limits = RulesLimits(rewriteBodyBytes: 8)
        let big = try await apply([step(r1, set("x"))], Data("0123456789".utf8), limits: limits)
        #expect(big == .unchanged([outcome(r1, .bodySkippedTooLarge)]))
        let tooLong = try await apply([step(r1, set("0123456789"))], Data("abc".utf8), limits: limits)
        #expect(tooLong == .unchanged([outcome(r1, .bodySkippedTooLarge)]))
    }

    @Test func setValueWritesPlainTextForAnEncodedBody() async throws {
        let gzipped = try #require(Data(base64Encoded: "H4sIAAAAAAAC/8tIzcnJBwCGphA2BQAAAA=="))
        let result = try await apply([step(r1, set("plain"))], gzipped, encoding: "gzip")
        let (text, _) = try #require(rewritten(result))
        #expect(text == "plain")
    }

    @Test func stepsComposeInOrder() async throws {
        let first = try await apply([step(r1, replace("a", "b")), step(r2, set("z"))], Data("aaa".utf8))
        #expect(rewritten(first)?.0 == "z")
        let second = try await apply([step(r1, set("abc")), step(r2, replace("b", "-"))], Data("old".utf8))
        #expect(rewritten(second)?.0 == "a-c")
        let third = try await apply([step(r1, set("abc")), step(r2, clear)], Data("old".utf8))
        #expect(rewritten(third)?.0 == "")
    }

    @Test func setValueIgnoresFindAndScope() async throws {
        let action = BodyRewriteAction(
            find: "(", replacement: "v", syntax: .regex, caseSensitive: false, scope: .first, operation: .setValue)
        let result = try await apply([step(r1, action)], Data("old old".utf8))
        #expect(rewritten(result)?.0 == "v")
    }
}
