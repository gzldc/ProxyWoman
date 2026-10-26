import Foundation

/// Builds the rule for each template. Pure and Foundation-only: the caller supplies the localized
/// name and note. Every template is disabled and uses placeholder `example.com` hosts, so inserting
/// one cannot change traffic until the user edits and enables it.
public enum RuleTemplateCatalog {
    private static let markBlue = "#0A84FF"

    public static func rule(
        _ template: RuleTemplate, name: String, note: String, id: UUID = UUID(), order: Int = 0,
        groupID: UUID? = nil
    ) -> Rule {
        Rule(
            id: id, name: name, enabled: false, groupID: groupID, order: order,
            conditions: conditions(for: template), actions: actions(for: template), note: note)
    }

    private static func row(_ field: ConditionField, _ op: ConditionOperator, _ value: String) -> ConditionRow {
        ConditionRow(field: field, op: op, value: value)
    }

    private static func conditions(for template: RuleTemplate) -> ConditionGroup {
        let rows: [ConditionRow]
        switch template {
        case .simulate404, .simulate500, .simulate429: rows = [row(.url, .contains, "/example")]
        case .addCORSHeaders, .delay2Seconds, .markDomain, .stripAuthorization:
            rows = [row(.host, .contains, "example.com")]
        case .disableCaching: rows = []
        case .httpToHttps: rows = [row(.scheme, .equals, "http")]
        case .recordAllPOST: rows = [row(.method, .equals, "POST")]
        case .blockAnalytics: rows = [row(.host, .contains, "analytics.example.com")]
        case .breakpointPUT: rows = [row(.method, .equals, "PUT")]
        case .forceStatus200: rows = [row(.statusCode, .inRange, "400-499")]
        case .hideNoise: rows = [row(.host, .contains, "telemetry.example.com")]
        case .closeConnection: rows = [row(.host, .contains, "closed.example.com")]
        }
        return ConditionGroup(rows: rows)
    }

    private static func actions(for template: RuleTemplate) -> [RuleAction] {
        switch template {
        case .simulate404: [RuleAction(.returnPreset(PresetResponse(preset: .notFound404)))]
        case .simulate500: [RuleAction(.returnPreset(PresetResponse(preset: .internalError500)))]
        case .simulate429: [RuleAction(.returnPreset(PresetResponse(preset: .tooManyRequests429)))]
        case .blockAnalytics: [RuleAction(.returnPreset(PresetResponse(preset: .forbidden403)))]
        case .addCORSHeaders:
            [RuleAction(.editHeaders(direction: .response, operations: [
                .set(name: "Access-Control-Allow-Origin", value: "*"),
                .set(name: "Access-Control-Allow-Methods", value: "GET, POST, PUT, DELETE, OPTIONS"),
                .set(name: "Access-Control-Allow-Headers", value: "*"),
            ]))]
        case .disableCaching:
            [
                RuleAction(.editHeaders(direction: .request, operations: NoCaching.requestEdits)),
                RuleAction(.editHeaders(direction: .response, operations: NoCaching.responseEdits)),
            ]
        case .delay2Seconds: [RuleAction(.delay(milliseconds: 2000))]
        case .markDomain: [RuleAction(.mark(MarkAction(background: markBlue)))]
        case .httpToHttps:
            [RuleAction(.modifyURL(URLEditAction(mode: .findReplace, find: "http://", replacement: "https://")))]
        case .recordAllPOST:
            [
                RuleAction(.mark(MarkAction(background: markBlue))),
                RuleAction(.comment(CommentAction(mode: .append, text: "POST"))),
            ]
        case .breakpointPUT: [RuleAction(.breakpoint(direction: .request, mode: .headers))]
        case .stripAuthorization:
            [RuleAction(.editHeaders(direction: .request, operations: [.remove(name: "Authorization")]))]
        case .forceStatus200:
            [RuleAction(.rewriteStatus(RewriteStatusAction(status: 200, includeLocalResponses: false)))]
        case .hideNoise: [RuleAction(.hide)]
        case .closeConnection: [RuleAction(.closeConnection(.graceful))]
        }
    }
}
