import FlowStore
import Foundation
import Testing
import RulesEngine

@testable import AppCore

private let fixedID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!

private func validate(_ draft: RuleEditorDraft) -> RuleDraftValidation {
    draft.validate(order: 2, limits: RulesLimits())
}

private func bodyDraft(find: String = "foo", replacement: String = "bar") -> RuleEditorDraft {
    var draft = RuleEditorDraft(kind: .rewriteBody, id: fixedID)
    draft.name = "Rewrite"
    draft.bodyRewrite.find = find
    draft.bodyRewrite.replacement = replacement
    return draft
}

private func statusDraft(_ status: String) -> RuleEditorDraft {
    var draft = RuleEditorDraft(kind: .rewriteStatus, id: fixedID)
    draft.name = "Status"
    draft.rewriteStatus.status = status
    return draft
}

@Suite(.productionChinese) struct RuleEditorRewriteTests {
    // MARK: body rewrite

    @Test func bodyDraftBuildsRewriteBodyRule() throws {
        var draft = bodyDraft(find: "a.b", replacement: "$1")
        draft.direction = .request
        draft.match.host = "api.test"
        draft.bodyRewrite.syntax = .regex
        draft.bodyRewrite.caseSensitive = false
        draft.bodyRewrite.scope = .first
        let rule = try #require(validate(draft).rule)
        #expect(rule == Rule(
            id: fixedID, name: "Rewrite", enabled: true, order: 2, matcher: RuleMatcher(hostPattern: "api.test"),
            action: .rewriteBody(direction: .request, BodyRewriteAction(
                find: "a.b", replacement: "$1", syntax: .regex, caseSensitive: false, scope: .first))))

        draft.direction = .response
        draft.bodyRewrite = BodyRewriteDraft()
        draft.bodyRewrite.find = "x"
        let response = try #require(validate(draft).rule)
        #expect(response.action == .rewriteBody(direction: .response, BodyRewriteAction(find: "x", replacement: "")))
    }

    @Test func bodyDraftLoadsFromRule() throws {
        var draft = bodyDraft(find: "(a|b)+", replacement: "<$1>")
        draft.direction = .response
        draft.bodyRewrite.syntax = .regex
        draft.bodyRewrite.caseSensitive = false
        draft.bodyRewrite.scope = .first
        draft.match.statusLower = "500"
        draft.match.statusUpper = "599"
        let rule = try #require(validate(draft).rule)
        let loaded = RuleEditorDraft(rule: rule, asset: nil)
        #expect(loaded.kind == .rewriteBody)
        #expect(loaded.direction == .response)
        #expect(loaded.bodyRewrite == draft.bodyRewrite)
        #expect(try #require(validate(loaded).rule) == rule)
    }

    @Test func emptyFindIsFieldError() {
        let result = validate(bodyDraft(find: ""))
        #expect(result.rule == nil)
        #expect(result.issues == [.bodyFind: .emptyFind])
    }

    @Test func tooLongFindIsFieldError() {
        let result = validate(bodyDraft(find: String(repeating: "a", count: BodyRewriteAction.maxFindBytes + 1)))
        #expect(result.issues == [.bodyFind: .findTooLong])
    }

    @Test func tooLongReplacementIsFieldError() {
        let limits = RulesLimits()
        let result = validate(bodyDraft(replacement: String(repeating: "a", count: limits.fieldBytes + 1)))
        #expect(result.issues == [.bodyReplacement: .fieldTooLong])
    }

    @Test func regexSyntaxInvalidPatternIsFieldError() {
        var draft = bodyDraft(find: "(")
        draft.bodyRewrite.syntax = .regex
        #expect(validate(draft).issues == [.bodyFind: .invalidRegex])
    }

    @Test func riskyRegexIsFieldError() {
        var draft = bodyDraft(find: "(a+)+")
        draft.bodyRewrite.syntax = .regex
        #expect(validate(draft).issues == [.bodyFind: .regexTooComplex])
    }

    @Test func textSyntaxAcceptsRegexSpecialCharacters() throws {
        let rule = try #require(validate(bodyDraft(find: "(a+)+[", replacement: "$1")).rule)
        guard case .rewriteBody(_, let rewrite) = rule.action else { Issue.record("not a body rule"); return }
        #expect(rewrite.find == "(a+)+[" && rewrite.syntax == .text)
    }

    @Test func requestBodyRuleWithStatusRangeIsFieldError() {
        var draft = bodyDraft()
        draft.direction = .request
        draft.match.statusLower = "200"
        draft.match.statusUpper = "299"
        #expect(validate(draft).issues == [.statusRange: .statusRangeNotAllowed])
        draft.direction = .response
        #expect(validate(draft).rule != nil)
    }

    // MARK: status rewrite

    @Test func statusDraftBuildsRule() throws {
        var draft = statusDraft(" 404 ")
        draft.rewriteStatus.includeLocalResponses = true
        draft.match.host = "api.test"
        let rule = try #require(validate(draft).rule)
        #expect(rule == Rule(
            id: fixedID, name: "Status", enabled: true, order: 2, matcher: RuleMatcher(hostPattern: "api.test"),
            action: .rewriteStatus(RewriteStatusAction(status: 404, includeLocalResponses: true))))
        let loaded = RuleEditorDraft(rule: rule, asset: nil)
        #expect(loaded.kind == .rewriteStatus)
        #expect(loaded.rewriteStatus == RewriteStatusDraft(status: "404", includeLocalResponses: true))
    }

    @Test func statusNotANumberIsFieldError() {
        #expect(validate(statusDraft("abc")).issues == [.rewriteStatus: .notANumber])
        #expect(validate(statusDraft("")).issues == [.rewriteStatus: .required])
    }

    @Test func status100And600AreFieldErrors() {
        #expect(validate(statusDraft("100")).issues == [.rewriteStatus: .invalidStatus])
        #expect(validate(statusDraft("199")).issues == [.rewriteStatus: .invalidStatus])
        #expect(validate(statusDraft("600")).issues == [.rewriteStatus: .invalidStatus])
    }

    @Test func status200And599Valid() {
        #expect(validate(statusDraft("200")).rule != nil)
        #expect(validate(statusDraft("599")).rule != nil)
    }

    @Test func statusRulePinsDirectionToResponse() throws {
        var draft = statusDraft("503")
        draft.direction = .request
        #expect(draft.effectiveDirection == .response)
        draft.match.statusLower = "200"
        draft.match.statusUpper = "200"
        let rule = try #require(validate(draft).rule)
        #expect(rule.action.direction == .response)
        #expect(rule.matcher.statusRange == 200...200)
        #expect(bodyDraft().effectiveDirection == .request)
    }

    // MARK: from a captured flow

    private func flow(status: Int?) -> Flow {
        var flow = Flow(id: 3, scheme: "https", method: "POST", host: "api.test", port: 8443, path: "/v1/items?x=1")
        flow.statusCode = status
        return flow
    }

    @Test func fromFlowPrefillsMatcherAndStatus() throws {
        let body = RuleEditorDraft.fromFlow(flow(status: 418), kind: .rewriteBody)
        #expect(body.kind == .rewriteBody && body.direction == .response && body.effectiveDirection == .response)
        #expect(body.name == "api.test")
        var filled = body
        filled.bodyRewrite.find = "x"
        let bodyRule = try #require(validate(filled).rule)
        #expect(bodyRule.matcher == RuleMatcher(
            scheme: "https", hostPattern: "api.test", port: 8443, method: "POST", path: .exact("/v1/items?x=1")))
        #expect(bodyRule.action.direction == .response)

        let status = RuleEditorDraft.fromFlow(flow(status: 418), kind: .rewriteStatus)
        #expect(status.rewriteStatus.status == "418")
        let statusRule = try #require(validate(status).rule)
        #expect(statusRule.matcher == bodyRule.matcher)
        #expect(statusRule.action == .rewriteStatus(RewriteStatusAction(status: 418)))
    }

    @Test func fromFlowOfFlowWithoutResponseLeavesStatusEmpty() {
        let draft = RuleEditorDraft.fromFlow(flow(status: nil), kind: .rewriteStatus)
        #expect(draft.rewriteStatus.status.isEmpty)
        #expect(validate(draft).issues == [.rewriteStatus: .required])
    }

    @Test func switchingKindKeepsOtherFormsData() throws {
        var draft = bodyDraft(find: "keep", replacement: "me")
        draft.rewriteStatus.status = "301"
        draft.kind = .rewriteStatus
        #expect(draft.bodyRewrite.find == "keep" && draft.bodyRewrite.replacement == "me")
        #expect(try #require(validate(draft).rule).action == .rewriteStatus(RewriteStatusAction(status: 301)))
        draft.kind = .breakpoint
        draft.kind = .rewriteBody
        #expect(draft.rewriteStatus.status == "301")
        guard case .rewriteBody(_, let rewrite) = try #require(validate(draft).rule).action else { Issue.record("not a body rule"); return }
        #expect(rewrite.find == "keep")
    }

    @MainActor @Test func beginDraftFromFlowWorksForNewKinds() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let model = RulesEditorModel(client: fixture.client(), limits: RulesLimits())
        await model.load()
        model.beginDraft(from: flow(status: 502), kind: .rewriteStatus)
        #expect(model.draft?.kind == .rewriteStatus && model.draft?.rewriteStatus.status == "502")
        #expect(model.isDraftNew && model.draft?.match.host == "api.test")
        // An unsaved draft is not replaced silently: the new one waits for the user's confirmation.
        model.beginDraft(from: flow(status: 502), kind: .rewriteBody)
        #expect(model.draft?.kind == .rewriteStatus)
        guard case .draft(let pending) = model.pendingNavigation else { Issue.record("no pending draft"); return }
        #expect(pending.kind == .rewriteBody && pending.direction == .response)
        model.confirmPendingNavigation()
        #expect(model.draft?.kind == .rewriteBody && model.draft?.direction == .response)
        #expect(model.draft?.match.path == "/v1/items?x=1")
        #expect(fixture.repository.provider.current().rules.isEmpty)
    }
}
