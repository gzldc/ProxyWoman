import FlowStore
import Foundation
import RulesEngine
import Testing

@testable import AppCore

// Rules 2.0 R2, Task 10: the old rule editor creates, edits and shows mark, comment and hide rules.

private let limits = RulesLimits()

private func draft(_ kind: RuleKind, host: String = "a.test") -> RuleEditorDraft {
    var draft = RuleEditorDraft(kind: kind)
    draft.name = "r"
    draft.match.host = host
    return draft
}

@Suite(.productionChinese) struct RuleAnnotationDraftTests {
    @Test func markDraftBuildsAMarkRuleWithItsFixedFieldRows() throws {
        let validation = draft(.mark).validate(order: 3, limits: limits)
        let rule = try #require(validation.rule)
        #expect(validation.issues.isEmpty)
        #expect(rule.conditions.rows.map(\.field) == [.host])
        #expect(rule.conditions.rows.map(\.op) == [.hostPattern])
        #expect(rule.conditions.rows.map(\.value) == ["a.test"])
        #expect(rule.actions == [RuleAction(.mark(MarkAction(background: "#FF3B30")))])
        #expect(rule.simpleAnnotation != nil && rule.order == 3)
    }

    @Test func markTextAndForegroundAreKeptOnlyWhenGiven() throws {
        var d = draft(.mark)
        d.mark.background = "#007AFF"
        d.mark.foreground = "#ffffff"
        d.mark.text = "慢"
        var rule = try #require(d.validate(order: 0, limits: limits).rule)
        #expect(rule.actions == [RuleAction(.mark(MarkAction(background: "#007AFF", foreground: "#FFFFFF", text: "慢")))])
        d.mark.foreground = nil
        d.mark.text = ""
        rule = try #require(d.validate(order: 0, limits: limits).rule)
        #expect(rule.actions == [RuleAction(.mark(MarkAction(background: "#007AFF")))])
    }

    @Test func invalidMarkColourIsAFieldIssue() {
        var d = draft(.mark)
        d.mark.background = "red"
        #expect(d.validate(order: 0, limits: limits).issues == [.markColor: .invalidMarkColor])
        d.mark.background = "#FF3B30"
        d.mark.foreground = "#12"
        #expect(d.validate(order: 0, limits: limits).issues == [.markForeground: .invalidMarkColor])
    }

    @Test func markTextTooLongUsesTheLimit() {
        var small = RulesLimits()
        small.markTextBytes = 4
        var d = draft(.mark)
        d.mark.text = "12345"
        let issues = d.validate(order: 0, limits: small).issues
        #expect(issues == [.markText: .markTextTooLong])
        #expect(issues[.markText]?.message(limits: small).contains("4") == true)
        d.mark.text = "1234"
        #expect(d.validate(order: 0, limits: small).rule != nil)
    }

    @Test func commentModesValidate() throws {
        var d = draft(.comment)
        #expect(d.comment.mode == .append)
        #expect(d.validate(order: 0, limits: limits).issues == [.commentText: .commentRequired])
        d.comment.text = "slow"
        #expect(try #require(d.validate(order: 0, limits: limits).rule).actions
            == [RuleAction(.comment(CommentAction(mode: .append, text: "slow")))])
        d.comment.mode = .set
        #expect(try #require(d.validate(order: 0, limits: limits).rule).actions
            == [RuleAction(.comment(CommentAction(mode: .set, text: "slow")))])
        d.comment.mode = .findReplace
        d.comment.text = ""
        d.comment.replacement = "b"
        #expect(d.validate(order: 0, limits: limits).issues == [.commentFind: .commentFindRequired])
        d.comment.text = "a"
        #expect(try #require(d.validate(order: 0, limits: limits).rule).actions
            == [RuleAction(.comment(CommentAction(mode: .findReplace, text: "a", replacement: "b")))])
        d.comment.mode = .clear
        d.comment.text = ""
        d.comment.replacement = ""
        #expect(try #require(d.validate(order: 0, limits: limits).rule).actions
            == [RuleAction(.comment(CommentAction(mode: .clear)))])
    }

    @Test func commentLengthUsesTheLimitAndAReplacementOverflowIsOnTheReplacementField() {
        var small = RulesLimits()
        small.commentBytes = 3
        var d = draft(.comment)
        d.comment.text = "abcd"
        let issues = d.validate(order: 0, limits: small).issues
        #expect(issues == [.commentText: .commentTooLong])
        #expect(issues[.commentText]?.message(limits: small).contains("3") == true)
        d.comment.mode = .findReplace
        d.comment.text = "a"
        d.comment.replacement = "abcd"
        #expect(d.validate(order: 0, limits: small).issues == [.commentReplacement: .commentTooLong])
        d.comment.text = "abcd"
        d.comment.replacement = ""
        #expect(d.validate(order: 0, limits: small).issues == [.commentFind: .commentTooLong])
    }

    @Test func hideDraftBuildsAHideRule() throws {
        let rule = try #require(draft(.hide).validate(order: 0, limits: limits).rule)
        #expect(rule.actions == [RuleAction(.hide)])
        #expect(rule.simpleAnnotation != nil)
    }

    @Test func annotationRulesLoadBackIntoTheDraft() throws {
        var mark = draft(.mark)
        mark.matchMode = .any
        mark.match.method = "POST"
        mark.mark = MarkDraft(background: "#34C759", foreground: "#000000", text: "ok")
        var comment = draft(.comment)
        comment.comment = CommentDraft(mode: .findReplace, text: "a", replacement: "b")
        var hide = draft(.hide)
        hide.match.port = "8080"
        hide.match.statusLower = "500"
        hide.match.statusUpper = "599"
        for original in [mark, comment, hide] {
            let rule = try #require(original.validate(order: 2, limits: limits).rule)
            let loaded = RuleEditorDraft(rule: rule, asset: nil)
            #expect(loaded == { var d = original; d.id = rule.id; return d }())
            #expect(loaded.readOnlyReason == nil)
        }
    }

    @Test func annotationRulesAllowAStatusRange() throws {
        for kind in [RuleKind.mark, .comment, .hide] {
            var d = draft(kind)
            d.comment.text = "x"
            d.match.statusLower = "400"
            d.match.statusUpper = "499"
            let rule = try #require(d.validate(order: 0, limits: limits).rule, "\(kind)")
            #expect(rule.simpleAnnotation?.matcher.statusRange == 400...499)
        }
        var remote = draft(.mapRemote)
        remote.mapRemote.targetHost = "b.test"
        remote.match.statusLower = "400"
        remote.match.statusUpper = "499"
        #expect(remote.validate(order: 0, limits: limits).issues == [.statusRange: .statusRangeNotAllowed])
    }

    @Test func hideWithoutAnyMatchFieldWarns() {
        #expect(draft(.hide, host: "").warnings == [.hidesEverything])
        var d = draft(.hide, host: "")
        d.match.pathMode = .prefix
        d.match.path = "/a"
        #expect(d.warnings.isEmpty)
    }

    @Test func hideWithAHostDoesNotWarn() {
        #expect(draft(.hide).warnings.isEmpty)
        var d = draft(.hide, host: "")
        d.match.statusLower = "500"
        d.match.statusUpper = "599"
        #expect(d.warnings.isEmpty)
    }

    @Test func markWithoutFieldsDoesNotWarn() {
        #expect(draft(.mark, host: "").warnings.isEmpty)
        #expect(draft(.comment, host: "").warnings.isEmpty)
    }

    @Test func annotationRuleIsEditableButTwoActionsIsReadOnly() throws {
        let rule = try #require(draft(.mark).validate(order: 0, limits: limits).rule)
        #expect(RuleEditorDraft.readOnlyReason(of: rule) == nil)
        var two = rule
        two.actions.append(RuleAction(.hide))
        #expect(RuleEditorDraft.readOnlyReason(of: two) == .multipleActions)
        #expect(RuleEditorDraft(rule: two, asset: nil).validate(order: 0, limits: limits).rule == nil)
        var final = rule
        final.actions[0].isFinal = true
        #expect(RuleEditorDraft.readOnlyReason(of: final) == .userFinalFlag)
    }

    @Test func newMarkDraftDefaultsToTheFirstPresetAndAppendMode() {
        let d = RuleEditorDraft(kind: .mark)
        #expect(d.mark.background == "#FF3B30" && d.mark.foreground == nil && d.mark.text == "")
        #expect(d.comment.mode == .append && d.comment.text == "" && d.comment.replacement == "")
    }

    @Test func fromFlowPrefillsLikeTheOtherKinds() throws {
        let flow = Flow(id: 1, scheme: "https", method: "PUT", host: "x.test", port: 8443, path: "/p?q=1")
        for kind in [RuleKind.mark, .comment, .hide] {
            let d = RuleEditorDraft.fromFlow(flow, kind: kind)
            #expect(d.kind == kind && d.name == "x.test")
            #expect(d.match.scheme == .https && d.match.host == "x.test" && d.match.port == "8443")
            #expect(d.match.method == "PUT" && d.match.pathMode == .exact && d.match.path == "/p?q=1")
        }
    }
}
