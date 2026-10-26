import Foundation
import Testing

@testable import RulesEngine

@Suite struct RuleTemplateCatalogTests {
    private func build(_ t: RuleTemplate) -> Rule { RuleTemplateCatalog.rule(t, name: "N", note: "M") }

    @Test func fifteenTemplatesInTheDocumentedOrder() {
        #expect(RuleTemplate.allCases.map(\.rawValue) == [
            "simulate404", "simulate500", "simulate429", "addCORSHeaders", "disableCaching", "delay2Seconds",
            "markDomain", "httpToHttps", "recordAllPOST", "blockAnalytics", "breakpointPUT", "stripAuthorization",
            "forceStatus200", "hideNoise", "closeConnection",
        ])
    }

    @Test(arguments: RuleTemplate.allCases) func everyTemplateValidates(_ t: RuleTemplate) throws {
        let rule = build(t)
        try rule.validate(limits: RulesLimits())
        #expect(rule.name == "N")
        #expect(rule.note == "M")
        #expect(!rule.actions.isEmpty)
    }

    @Test func allTemplatesTogetherPassStructureValidation() throws {
        let rules = RuleTemplate.allCases.enumerated().map {
            RuleTemplateCatalog.rule($1, name: "N", note: "M", order: $0)
        }
        try RuleSnapshot(revision: 1, rules: rules).validateStructure(limits: RulesLimits())
    }

    @Test(arguments: RuleTemplate.allCases) func everyTemplateIsDisabled(_ t: RuleTemplate) {
        #expect(build(t).enabled == false)
    }

    @Test(arguments: RuleTemplate.allCases) func everyTemplateUsesPlaceholderDomainsOnly(_ t: RuleTemplate) {
        for row in build(t).conditions.rows {
            switch row.field {
            case .host: #expect(row.value.hasSuffix("example.com"))
            case .url, .path, .method, .scheme, .statusCode: break
            default: Issue.record("unexpected field \(row.field)")
            }
            if row.field == .url || row.field == .path { #expect(!row.value.contains("://")) }
        }
    }

    @Test func actionKindsMatchTheDocumentedTable() throws {
        func kinds(_ t: RuleTemplate) -> [ActionKind] { build(t).actions.map(\.kind) }
        #expect(kinds(.simulate404) == [.returnPreset(PresetResponse(preset: .notFound404))])
        #expect(kinds(.simulate500) == [.returnPreset(PresetResponse(preset: .internalError500))])
        #expect(kinds(.simulate429) == [.returnPreset(PresetResponse(preset: .tooManyRequests429))])
        #expect(kinds(.blockAnalytics) == [.returnPreset(PresetResponse(preset: .forbidden403))])
        #expect(kinds(.delay2Seconds) == [.delay(milliseconds: 2000)])
        #expect(kinds(.addCORSHeaders) == [.editHeaders(direction: .response, operations: [
            .set(name: "Access-Control-Allow-Origin", value: "*"),
            .set(name: "Access-Control-Allow-Methods", value: "GET, POST, PUT, DELETE, OPTIONS"),
            .set(name: "Access-Control-Allow-Headers", value: "*"),
        ])])
        #expect(kinds(.disableCaching) == [
            .editHeaders(direction: .request, operations: NoCaching.requestEdits),
            .editHeaders(direction: .response, operations: NoCaching.responseEdits),
        ])
        #expect(kinds(.markDomain) == [.mark(MarkAction(background: "#0A84FF"))])
        #expect(kinds(.httpToHttps) == [.modifyURL(URLEditAction(mode: .findReplace, find: "http://", replacement: "https://"))])
        #expect(kinds(.recordAllPOST) == [
            .mark(MarkAction(background: "#0A84FF")),
            .comment(CommentAction(mode: .append, text: "POST")),
        ])
        #expect(kinds(.stripAuthorization) == [.editHeaders(direction: .request, operations: [.remove(name: "Authorization")])])
        #expect(kinds(.hideNoise) == [.hide])
        #expect(kinds(.closeConnection) == [.closeConnection(.graceful)])
        #expect(kinds(.forceStatus200) == [.rewriteStatus(RewriteStatusAction(status: 200, includeLocalResponses: false))])
    }

    @Test func conditionsMatchTheDocumentedTable() {
        func rows(_ t: RuleTemplate) -> [ConditionRow] { build(t).conditions.rows }
        #expect(rows(.simulate404) == [ConditionRow(field: .url, op: .contains, value: "/example")])
        #expect(rows(.recordAllPOST) == [ConditionRow(field: .method, op: .equals, value: "POST")])
        #expect(rows(.breakpointPUT) == [ConditionRow(field: .method, op: .equals, value: "PUT")])
        #expect(rows(.httpToHttps) == [ConditionRow(field: .scheme, op: .equals, value: "http")])
        #expect(rows(.forceStatus200) == [ConditionRow(field: .statusCode, op: .inRange, value: "400-499")])
        #expect(rows(.blockAnalytics).map(\.value) == ["analytics.example.com"])
        #expect(rows(.hideNoise).map(\.value) == ["telemetry.example.com"])
        #expect(rows(.closeConnection).map(\.value) == ["closed.example.com"])
        #expect(rows(.delay2Seconds) == [ConditionRow(field: .host, op: .contains, value: "example.com")])
        #expect(rows(.disableCaching).isEmpty)
    }

    @Test func breakpointTemplateIsRequestSideHeadersOnly() {
        let rule = build(.breakpointPUT)
        #expect(rule.actions.map(\.kind) == [.breakpoint(direction: .request, mode: .headers)])
        #expect(rule.conditions.judgmentPoint < .response)
    }

    @Test func statusTemplateDoesNotTouchLocalResponses() {
        guard case .rewriteStatus(let action) = build(.forceStatus200).actions[0].kind else {
            Issue.record("not a status rewrite")
            return
        }
        #expect(action.status == 200)
        #expect(action.includeLocalResponses == false)
    }

    @Test func idsAndOrderAreAppliedFromArguments() {
        let id = UUID()
        let group = UUID()
        let rule = RuleTemplateCatalog.rule(.hideNoise, name: "n", note: "m", id: id, order: 7, groupID: group)
        #expect(rule.id == id)
        #expect(rule.order == 7)
        #expect(rule.groupID == group)
        #expect(build(.hideNoise).id != build(.hideNoise).id)
        #expect(build(.hideNoise).groupID == nil)
        #expect(build(.hideNoise).order == 0)
    }

    @Test func templatesSurviveACodableRoundTrip() throws {
        for t in RuleTemplate.allCases {
            let rule = build(t)
            let back = try JSONDecoder().decode(Rule.self, from: JSONEncoder().encode(rule))
            #expect(back == rule)
        }
    }
}
