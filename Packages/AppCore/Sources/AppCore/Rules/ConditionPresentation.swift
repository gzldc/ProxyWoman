import Foundation
import Localization
import RulesEngine

/// The words for condition rows: a row as one sentence, a group as one line. Every key is written out in
/// full (no key is built from a case name).
public enum ConditionPresentation {
    public static func fieldTitle(_ field: ConditionField, localizer: Localizer = L10n.localizer) -> String {
        localizer.string(fieldKey(field))
    }

    public static func operatorTitle(_ op: ConditionOperator, localizer: Localizer = L10n.localizer) -> String {
        localizer.string(operatorKey(op))
    }

    /// `请求 Header（X-Test）等于 1`: the field, its key when it has one, the comparison and the value. The key of a header
    /// or cookie row left empty reads "任意 Header" / "任意 Cookie"; a certificate row names its sub-item. The value is left
    /// out for a comparison that takes none (is empty, exists, the certificate's validity) and for a field without one; a
    /// field without a comparison (magic string) is the field and its value; a fixed "is" field says "是".
    public static func rowSummary(_ row: ConditionRow, localizer: Localizer = L10n.localizer) -> String {
        let field = fieldTitle(row.field, localizer: localizer)
        let key = (row.name?.isEmpty ?? true) ? nil : row.name
        if row.field == .allSessions { return field }
        if row.field == .rulesModified, row.op == .equals {
            return localizer.format(
                "rules.conditionSummary.rowYesNo",
                arguments: [field, valueText(row, name: nil, localizer: localizer)])
        }
        let value = valueText(row, name: key, localizer: localizer)
        if row.field == .magicString { return localizer.format("rules.conditionSummary.rowNoValue", arguments: [field, value]) }
        let name = keyText(row, key: key, localizer: localizer)
        let op = comparisonText(row, key: key, localizer: localizer)
        let valueless = !ConditionFieldCatalog.showsValue(field: row.field, name: key, op: row.op)
        switch (name, valueless) {
        case (let name?, true):
            return localizer.format("rules.conditionSummary.rowNamedNoValue", arguments: [field, name, op])
        case (let name?, false):
            return localizer.format("rules.conditionSummary.rowNamed", arguments: [field, name, op, value])
        case (nil, true):
            return localizer.format("rules.conditionSummary.rowNoValue", arguments: [field, op])
        case (nil, false):
            return localizer.format("rules.conditionSummary.row", arguments: [field, op, value])
        }
    }

    /// The text in the key's place: the key, "任意 Header" / "任意 Cookie" for an empty one, the sub-item of a certificate.
    private static func keyText(_ row: ConditionRow, key: String?, localizer: Localizer) -> String? {
        switch row.field {
        case .requestHeader, .responseHeader: key ?? localizer.string("rules.editor3.key.anyHeader")
        case .requestCookie, .responseCookie, .cookie: key ?? localizer.string("rules.editor3.key.anyCookie")
        case .certificate: CertificateFieldPresentation.title(key: key, localizer: localizer)
        case .clientApp: key.map { ConditionRowPresentation.nameTitle(field: .clientApp, name: $0, localizer: localizer) }
        default: key
        }
    }

    private static func comparisonText(_ row: ConditionRow, key: String?, localizer: Localizer) -> String {
        if row.field == .certificate, ConditionFieldCatalog.certificateField(name: key)?.valueKind == .validity,
            let title = CertificateValidity.title(op: row.op, value: row.value, localizer: localizer)
        {
            return title
        }
        // "是" reads for the fields that have a fixed one, except the yes/no one, whose value already says it.
        if row.op == .equals, ConditionRowDescriptor.isFixedIs(row.field) {
            return localizer.string("rules.editor3.operator.is")
        }
        return operatorTitle(row.op, localizer: localizer)
    }

    /// The rows one after another under the group's mode. Without rows every session matches; one row needs
    /// no "all of" (or "any of"), while "none of" always says what it means.
    public static func summary(_ group: ConditionGroup, localizer: Localizer = L10n.localizer) -> String {
        guard !group.rows.isEmpty else { return fieldTitle(.allSessions, localizer: localizer) }
        let separator = localizer.string("rules.conditionSummary.separator")
        let rows = group.rows.map { rowSummary($0, localizer: localizer) }.joined(separator: separator)
        switch group.mode {
        case .all: return group.rows.count == 1 ? rows : localizer.format("rules.conditionSummary.mode.all", arguments: [rows])
        case .any: return group.rows.count == 1 ? rows : localizer.format("rules.conditionSummary.mode.any", arguments: [rows])
        case .none: return localizer.format("rules.conditionSummary.mode.none", arguments: [rows])
        }
    }

    /// A choice or yes/no value in words, for the editor's pickers.
    public static func valueTitle(field: ConditionField, name: String?, value: String, localizer: Localizer = L10n.localizer) -> String {
        valueText(ConditionRow(field: field, name: name, op: .equals, value: value), name: name, localizer: localizer)
    }

    /// A choice or yes/no value in words; any other value (and a choice that is none of the known ones) as written.
    private static func valueText(_ row: ConditionRow, name: String?, localizer: Localizer) -> String {
        switch row.field.valueKind(name: name) {
        case .bool:
            switch row.value {
            case "true": return localizer.string("rules.condition.bool.true")
            case "false": return localizer.string("rules.condition.bool.false")
            default: return row.value
            }
        case .date:
            return ConditionDate.display(row.value) ?? row.value
        case .choice:
            switch (row.field, row.value.lowercased()) {
            case (.scheme, "https"): return localizer.string("rules.editor3.scheme.https")
            case (.scheme, "http"): return localizer.string("rules.editor3.scheme.http")
            case (.sessionState, "completed"): return localizer.string("rules.condition.state.completed")
            case (.sessionState, "failed"): return localizer.string("rules.condition.state.failed")
            case (.sessionState, "tunnel"): return localizer.string("rules.condition.state.tunnel")
            case (.sessionState, "opened"): return localizer.string("rules.condition.state.opened")
            case (.sessionState, "closed"): return localizer.string("rules.condition.state.closed")
            case (.sessionState, "paused"): return localizer.string("rules.condition.state.paused")
            case (.appProtocol, "rpc"): return localizer.string("rules.condition.appProtocol.rpc")
            case (.appProtocol, "http"): return localizer.string("rules.condition.appProtocol.http")
            case (.appProtocol, "websocket"): return localizer.string("rules.condition.appProtocol.websocket")
            case (.appProtocol, "grpc"): return localizer.string("rules.condition.appProtocol.grpc")
            case (.appProtocol, "socketio"): return localizer.string("rules.condition.appProtocol.socketio")
            case (.appProtocol, "sse"): return localizer.string("rules.condition.appProtocol.sse")
            default: return row.value
            }
        default:
            if row.field == .certificate, ConditionFieldCatalog.certificateField(name: name)?.valueKind == .date {
                return ConditionDate.display(row.value) ?? row.value
            }
            return row.value
        }
    }

    private static func fieldKey(_ field: ConditionField) -> String {
        switch field {
        case .allSessions: "rules.condition.field.allSessions"
        case .url: "rules.condition.field.url"
        case .scheme: "rules.condition.field.scheme"
        case .host: "rules.condition.field.host"
        case .port: "rules.condition.field.port"
        case .method: "rules.condition.field.method"
        case .path: "rules.condition.field.path"
        case .queryString: "rules.condition.field.queryString"
        case .pathAndQuery: "rules.condition.field.pathAndQuery"
        case .queryParam: "rules.condition.field.queryParam"
        case .requestHeader: "rules.condition.field.requestHeader"
        case .responseHeader: "rules.condition.field.responseHeader"
        case .requestCookie: "rules.condition.field.requestCookie"
        case .responseCookie: "rules.condition.field.responseCookie"
        case .requestBody: "rules.condition.field.requestBody"
        case .responseBody: "rules.condition.field.responseBody"
        case .requestBodySize: "rules.condition.field.requestBodySize"
        case .responseBodySize: "rules.condition.field.responseBodySize"
        case .statusCode: "rules.condition.field.statusCode"
        case .sessionState: "rules.condition.field.sessionState"
        case .durationMs: "rules.condition.field.durationMs"
        case .requestTime: "rules.condition.field.requestTime"
        case .requestDate: "rules.condition.field.requestDate"
        case .clientHTTPVersion: "rules.condition.field.clientHTTPVersion"
        case .upstreamHTTPVersion: "rules.condition.field.upstreamHTTPVersion"
        case .clientTLSVersion: "rules.condition.field.clientTLSVersion"
        case .upstreamTLSVersion: "rules.condition.field.upstreamTLSVersion"
        case .certificate: "rules.condition.field.certificate"
        case .clientIP: "rules.condition.field.clientIP"
        case .remoteIP: "rules.condition.field.remoteIP"
        case .clientApp: "rules.condition.field.clientApp"
        case .appProtocol: "rules.condition.field.appProtocol"
        case .rulesModified: "rules.condition.field.rulesModified"
        case .comment: "rules.condition.field.comment"
        case .cookie: "rules.condition.field.cookie"
        case .tlsVersion: "rules.condition.field.tlsVersion"
        case .magicString: "rules.condition.field.magicString"
        }
    }

    private static func operatorKey(_ op: ConditionOperator) -> String {
        switch op {
        case .equals: "rules.condition.op.equals"
        case .notEquals: "rules.condition.op.notEquals"
        case .contains: "rules.condition.op.contains"
        case .notContains: "rules.condition.op.notContains"
        case .startsWith: "rules.condition.op.startsWith"
        case .endsWith: "rules.condition.op.endsWith"
        case .isEmpty: "rules.condition.op.isEmpty"
        case .isNotEmpty: "rules.condition.op.isNotEmpty"
        case .regex: "rules.condition.op.regex"
        case .greaterThan: "rules.condition.op.greaterThan"
        case .greaterOrEqual: "rules.condition.op.greaterOrEqual"
        case .lessThan: "rules.condition.op.lessThan"
        case .lessOrEqual: "rules.condition.op.lessOrEqual"
        case .inRange: "rules.condition.op.inRange"
        case .before: "rules.condition.op.before"
        case .after: "rules.condition.op.after"
        case .hostPattern: "rules.condition.op.hostPattern"
        case .wildcard: "rules.condition.op.wildcard"
        case .regexWhole: "rules.condition.op.regexWhole"
        case .exists: "rules.condition.op.exists"
        case .doesNotExist: "rules.condition.op.doesNotExist"
        case .afterOrEqual: "rules.condition.op.afterOrEqual"
        case .beforeOrEqual: "rules.condition.op.beforeOrEqual"
        }
    }
}
