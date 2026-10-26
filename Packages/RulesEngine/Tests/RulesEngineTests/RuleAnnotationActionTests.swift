import FlowStore
import Foundation
import Testing

@testable import RulesEngine

@Suite("RuleAnnotationAction")
struct RuleAnnotationActionTests {
    private func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }

    @Test func commentModesApply() {
        #expect(CommentAction(mode: .append, text: "x").applying(to: nil) == "x")
        #expect(CommentAction(mode: .append, text: "x").applying(to: "a") == "a x")
        #expect(CommentAction(mode: .set, text: "b").applying(to: "a") == "b")
        #expect(CommentAction(mode: .set, text: "b").applying(to: nil) == "b")
        let signin = CommentAction(mode: .findReplace, text: "login", replacement: "signin")
        #expect(signin.applying(to: "slow login") == "slow signin")
        #expect(CommentAction(mode: .findReplace, text: "a", replacement: "b").applying(to: "a a") == "b b")
        #expect(signin.applying(to: nil) == nil)
        #expect(signin.applying(to: "keep") == "keep")
        #expect(CommentAction(mode: .findReplace, text: "A", replacement: "b").applying(to: "a") == "a")
        #expect(CommentAction(mode: .clear).applying(to: "anything") == nil)
        #expect(CommentAction(mode: .append, text: "x").applying(to: "") == "x")
    }

    @Test func findReplaceMatchesLiterallyNotByCanonicalEquivalence() {
        let composed = "caf\u{E9}"
        let decomposed = "cafe\u{301}"
        let findDecomposed = CommentAction(mode: .findReplace, text: "e\u{301}", replacement: "E")
        #expect(findDecomposed.applying(to: composed).map { Array($0.unicodeScalars) } == Array(composed.unicodeScalars))
        #expect(findDecomposed.applying(to: decomposed) == "cafE")
        let findComposed = CommentAction(mode: .findReplace, text: "\u{E9}", replacement: "E")
        #expect(
            findComposed.applying(to: decomposed).map { Array($0.unicodeScalars) } == Array(decomposed.unicodeScalars))
        #expect(findComposed.applying(to: composed) == "cafE")
    }

    @Test func appendNeverGrowsPastTheCap() throws {
        let existing = String(repeating: "a", count: 4090)
        let result = try #require(CommentAction(mode: .append, text: String(repeating: "b", count: 10)).applying(to: existing))
        #expect(result.utf8.count <= 4096)
        #expect(result.hasPrefix(existing))
        let again = try #require(CommentAction(mode: .append, text: "zzzzzzzzzz").applying(to: result))
        #expect(again.utf8.count <= 4096)
        #expect(again.hasPrefix(existing))
    }

    @Test func markActionBuildsAFlowMarkNamingTheRule() {
        let action = MarkAction(background: "#ff3b30", foreground: "#ffffff", text: "slow")
        let expected = FlowMark(
            background: "#FF3B30", foreground: "#FFFFFF", text: "slow", source: .rule(id: id(1), name: "R"))
        #expect(action.flowMark(ruleID: id(1), ruleName: "R") == expected)
    }

    @Test func invalidColourGivesNoMark() {
        #expect(MarkAction(background: "red").flowMark(ruleID: id(1), ruleName: "R") == nil)
        #expect(MarkAction(background: "#FF3B30", foreground: "#12").flowMark(ruleID: id(1), ruleName: "R") == nil)
    }
}
