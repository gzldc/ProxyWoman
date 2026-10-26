import FlowStore
import Foundation
import RulesEngine
import Testing

@testable import AppCore

// Rules 2.0 R1, Task 10: the old editor's draft reads and writes the 2.0 rule. It adds the combination
// mode (all / any / none) and nothing else; what the draft cannot state is read-only (RuleReadOnlyTests).

private let fixedID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!

private func fullDraft() -> RuleEditorDraft {
    var draft = RuleEditorDraft(kind: .editHeaders, id: fixedID)
    draft.name = "Every field"
    draft.direction = .response
    draft.match.scheme = .https
    draft.match.host = "api.test"
    draft.match.port = "8443"
    draft.match.method = "POST"
    draft.match.pathMode = .prefix
    draft.match.path = "/v1/"
    draft.match.statusLower = "500"
    draft.match.statusUpper = "599"
    draft.headerOperations = [HeaderOperationRow(kind: .set, name: "X-A", value: "1")]
    return draft
}

private func encoded(_ rule: Rule) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(rule)
}

@Suite(.productionChinese) struct RuleEditorDraftModeTests {
    @Test func matchModeDefaultsToAll() {
        for kind in RuleKind.allCases {
            #expect(RuleEditorDraft(kind: kind).matchMode == .all, "\(kind)")
        }
        let flow = Flow(id: 1, scheme: "https", method: "GET", host: "a.test", port: 443, path: "/x")
        #expect(RuleEditorDraft.fromFlow(flow, kind: .mapRemote).matchMode == .all)
    }

    @Test func choosingMapLocalDirectoryPutsTheModeBackOnAll() {
        var draft = RuleEditorDraft(kind: .rewriteStatus)
        draft.matchMode = .none
        draft.kind = .mapLocalDirectory
        #expect(draft.matchMode == .all && draft.match.pathMode == .prefix)
        // The other kinds keep what the user chose.
        draft.matchMode = .any
        draft.kind = .mapRemote
        #expect(draft.matchMode == .any)
    }

    @Test func anyModeBuildsRuleWithAnyGroupAndFixedRowOrder() throws {
        var draft = fullDraft()
        draft.matchMode = .any
        let rule = try #require(draft.validate(order: 4, limits: RulesLimits()).rule)
        #expect(rule.conditions.mode == .any)
        #expect(rule.conditions.occurrence == .any)
        // Scheme, host, port, method, path, status, whatever order the form was filled in.
        #expect(rule.conditions.rows.map(\.field) == [.scheme, .host, .port, .method, .pathAndQuery, .statusCode])
        #expect(rule.id == fixedID && rule.order == 4 && rule.groupID == nil && rule.actions.count == 1)

        draft.matchMode = .none
        let negated = try #require(draft.validate(order: 4, limits: RulesLimits()).rule)
        #expect(negated.conditions.mode == .none)
        #expect(negated.conditions.rows == rule.conditions.rows)
        #expect(negated.actions == rule.actions)
    }

    @Test func loadingARuleRestoresItsMode() throws {
        for mode in ConditionGroup.Mode.allCases {
            var rule = Rule(
                id: fixedID, name: "m", enabled: true, order: 0, matcher: RuleMatcher(scheme: "https", hostPattern: "a.test"),
                action: .rewriteStatus(RewriteStatusAction(status: 404)))
            rule.conditions.mode = mode
            let draft = RuleEditorDraft(rule: rule, asset: nil)
            #expect(draft.matchMode == mode, "\(mode)")
            #expect(draft.readOnlyReason == nil)
            // Writing it back changes nothing.
            #expect(try #require(draft.validate(order: 0, limits: RulesLimits()).rule) == rule, "\(mode)")
        }
    }

    @Test func allModeRuleKeepsLegacyBytes() throws {
        let draft = fullDraft()
        let rule = try #require(draft.validate(order: 2, limits: RulesLimits()).rule)

        // What the old draft produced: one old matcher and one old action.
        let matcher = RuleMatcher(
            scheme: "https", hostPattern: "api.test", port: 8443, method: "POST", path: .prefix("/v1/"), statusRange: 500...599)
        let action = LegacyRuleAction.editHeaders(direction: .response, operations: [.set(name: "X-A", value: "1")])
        let simple = try #require(rule.simple)
        #expect(simple.matcher == matcher && simple.action == action && simple.mode == .all)

        // And stored it is exactly the migration of that old rule: rule files do not change for an unchanged rule.
        let legacy = LegacyRule(id: fixedID, name: "Every field", enabled: true, order: 2, matcher: matcher, action: action)
        #expect(rule == Rule(migrating: legacy))
        #expect(try encoded(rule) == encoded(Rule(migrating: legacy)))
    }

    @Test func statusRangeWithRequestActionStillReportsStatusRangeNotAllowed() {
        for mode in ConditionGroup.Mode.allCases {
            var draft = fullDraft()
            draft.direction = .request
            draft.matchMode = mode
            let result = draft.validate(order: 0, limits: RulesLimits())
            #expect(result.rule == nil && result.issues == [.statusRange: .statusRangeNotAllowed], "\(mode)")
        }
        // The engine's own code for the same situation is shown against the same field and sentence.
        let error = RuleValidationError(code: .actionNotAllowedAtJudgmentPoint, field: .action(index: 0))
        #expect(RuleDraftIssue(error) == .statusRangeNotAllowed)
    }

    @Test func mixedSyntaxStillBlocksSaving() throws {
        let matcher = RuleMatcher(hostPattern: "a.test", path: .wildcard("/a*"))
        for mode in ConditionGroup.Mode.allCases {
            var rule = Rule(
                id: fixedID, name: "mixed", enabled: true, order: 0, matcher: matcher,
                action: .breakpoint(direction: .request, mode: .headers))
            rule.conditions.mode = mode
            var draft = RuleEditorDraft(rule: rule, asset: nil)
            #expect(draft.match.hasMixedSyntax && draft.matchMode == mode)
            let result = draft.validate(order: 0, limits: RulesLimits())
            #expect(result.rule == nil && result.issues == [.path: .mixedSyntax], "\(mode)")

            // Choosing the syntax again is the user taking over the text.
            draft.match.chooseSyntax(.wildcard)
            #expect(draft.validate(order: 0, limits: RulesLimits()).rule != nil, "\(mode)")
        }
    }
}
