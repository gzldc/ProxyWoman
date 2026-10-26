import Foundation
import Localization
import RulesEngine

/// One entry of a row's comparison menu.
public struct ConditionOperatorItem: Equatable, Sendable {
    public var op: ConditionOperator
    public var title: String
    /// Only for a saved row that carries it: shown with an "old style" tag, never offered to a new row.
    public var isLegacy: Bool
    /// Set when picking the entry also sets the value (the certificate's validity: `valid` / `invalid`).
    public var value: String? = nil
}

/// What stands where the comparison menu is.
public enum ConditionOperatorControl: Equatable, Sendable {
    /// No comparison at all (all sessions, magic string).
    case none
    /// The fixed word "is" (scheme, protocol, session state, rules modified).
    case fixed(String)
    /// A dropdown; a line falls between two groups.
    case menu([[ConditionOperatorItem]])

    /// Every entry of the menu, flat; empty for the other two.
    public var items: [ConditionOperatorItem] {
        if case .menu(let groups) = self { return groups.flatMap { $0 } }
        return []
    }
}

/// The control the row's value is typed or picked in.
public enum ConditionValueControl: Equatable, Sendable {
    case none
    /// A text box; `suggestions` is whether typing offers the values recent traffic had.
    case text(suggestions: Bool)
    /// A dropdown with the options in this order.
    case dropdown([ConditionChoice])
    /// A dropdown whose options are told apart by lines (the protocol field).
    case groupedDropdown([[ConditionChoice]])
    /// A date picker.
    case date
}

/// The control of the row's key (the header, cookie or certificate item the row is about).
public enum ConditionKeyControl: Equatable, Sendable {
    case none
    /// A text box with the names recent traffic had; empty means any (`placeholder` says so). `showsCase` is the key's "Aa".
    case autocomplete(placeholder: String, showsCase: Bool)
    /// The certificate item dropdown, grouped; `legacy` is the old-style item a saved row carries, listed last.
    case certificate(groups: [[ConditionChoice]], legacy: ConditionChoice?)
    /// A dropdown over a fixed list of keys (the old application field).
    case choices([ConditionChoice])
    /// A plain text box (the old query parameter field).
    case text(placeholder: String)
}

/// Everything the row editor needs to draw one condition row (spec 12.3), decided by the field, the key and the
/// comparison. Pure values; every word is localized here.
public struct ConditionRowDescriptor: Equatable, Sendable {
    public var field: ConditionField
    public var operatorControl: ConditionOperatorControl
    /// The comparison a row starts with; nil for a field without one.
    public var defaultOperator: ConditionOperator?
    public var keyControl: ConditionKeyControl
    public var valueControl: ConditionValueControl
    /// Whether the value box has the "Aa" case switch.
    public var showsValueCase: Bool
    public var placeholder: String?
    /// The field is not in the menu any more but a saved row still has it.
    public var isLegacyField: Bool

    public var showsValue: Bool { valueControl != .none }
    public var showsKeyCase: Bool {
        if case .autocomplete(_, let showsCase) = keyControl { return showsCase }
        return false
    }

    /// - Parameters:
    ///   - name: the key as the row stores it (nil or empty: none).
    ///   - op: the row's comparison; one outside the field's current set is added to the menu as an old-style entry.
    ///   - value: the row's value; an old value is added to a dropdown the same way.
    public init(
        field: ConditionField, name: String? = nil, op: ConditionOperator? = nil, value: String = "",
        localizer: Localizer = L10n.localizer
    ) {
        self.field = field
        let name = (name?.isEmpty ?? true) ? nil : name
        isLegacyField = ConditionFieldCatalog.isLegacyOnly(field: field, name: name)
        defaultOperator = field == .allSessions ? nil : ConditionFieldCatalog.defaultOperator(field: field, name: name)
        operatorControl = Self.operatorControl(field: field, name: name, op: op, localizer: localizer)
        keyControl = Self.keyControl(field: field, name: name, localizer: localizer)
        let effectiveOp = op ?? ConditionFieldCatalog.defaultOperator(field: field, name: name)
        let shows = ConditionFieldCatalog.showsValue(field: field, name: name, op: effectiveOp)
        valueControl = shows ? Self.valueControl(field: field, name: name, op: effectiveOp, value: value, localizer: localizer) : .none
        showsValueCase = shows && Self.valueHasCase(field: field, name: name)
        placeholder = shows ? Self.placeholder(field: field, name: name, localizer: localizer) : nil
    }

    // MARK: comparison

    private static func item(
        _ op: ConditionOperator, legacy: Bool = false, localizer: Localizer
    ) -> ConditionOperatorItem {
        ConditionOperatorItem(op: op, title: ConditionPresentation.operatorTitle(op, localizer: localizer), isLegacy: legacy)
    }

    /// The certificate validity's two entries: each picks the same `equals` and its own value.
    private static func validityItems(localizer: Localizer) -> [ConditionOperatorItem] {
        CertificateValidity.choices.map {
            ConditionOperatorItem(
                op: $0.op, title: CertificateValidity.title(valid: $0.isValid, localizer: localizer), isLegacy: false, value: $0.value)
        }
    }

    private static func operatorControl(
        field: ConditionField, name: String?, op: ConditionOperator?, localizer: Localizer
    ) -> ConditionOperatorControl {
        let groups = ConditionFieldCatalog.operatorGroups(field: field, name: name)
        if groups.isEmpty { return .none }
        if Self.isFixedIs(field), op == nil || op == .equals {
            return .fixed(localizer.string("rules.editor3.operator.is"))
        }
        if field == .certificate, ConditionFieldCatalog.certificateField(name: name)?.valueKind == .validity {
            return .menu([validityItems(localizer: localizer)])
        }
        var menu = groups.map { $0.map { item($0, localizer: localizer) } }
        if let op, !groups.joined().contains(op) {
            menu.append([item(op, legacy: true, localizer: localizer)])
        }
        return .menu(menu)
    }

    /// Scheme, protocol, session state and rules modified read "is" instead of a menu.
    static func isFixedIs(_ field: ConditionField) -> Bool {
        switch field {
        case .scheme, .appProtocol, .sessionState, .rulesModified: true
        default: false
        }
    }

    // MARK: key

    private static func keyControl(field: ConditionField, name: String?, localizer: Localizer) -> ConditionKeyControl {
        switch field {
        case .requestHeader, .responseHeader:
            return .autocomplete(placeholder: localizer.string("rules.editor3.key.anyHeader"), showsCase: true)
        case .requestCookie, .responseCookie, .cookie:
            return .autocomplete(placeholder: localizer.string("rules.editor3.key.anyCookie"), showsCase: true)
        case .certificate:
            let groups = CertificateFieldPresentation.menuGroups.map { group in
                group.map { ConditionChoice(value: $0.rawValue, title: CertificateFieldPresentation.title($0, localizer: localizer)) }
            }
            var legacy: ConditionChoice?
            if let name, CertificateField(conditionKey: name) == nil {
                legacy = ConditionChoice(
                    value: name, title: CertificateFieldPresentation.title(key: name, localizer: localizer), isLegacy: true)
            }
            return .certificate(groups: groups, legacy: legacy)
        case .clientApp:
            guard name != nil else { return .none }
            return .choices(
                (ConditionField.allowedNames(for: .clientApp) ?? []).map {
                    ConditionChoice(
                        value: $0, title: ConditionRowPresentation.nameTitle(field: .clientApp, name: $0, localizer: localizer),
                        isLegacy: true)
                })
        case .queryParam:
            return .text(placeholder: localizer.string("rules.editor2.row.name"))
        default:
            return .none
        }
    }

    // MARK: value

    private static func choice(_ value: String, _ title: String, legacy: Bool = false) -> ConditionChoice {
        ConditionChoice(value: value, title: title, isLegacy: legacy)
    }

    private static func valueControl(
        field: ConditionField, name: String?, op: ConditionOperator, value: String, localizer: Localizer
    ) -> ConditionValueControl {
        let suggests = op != .regex
        switch field {
        case .allSessions:
            return .none
        case .scheme:
            return .dropdown([
                choice("https", localizer.string("rules.editor3.scheme.https")),
                choice("http", localizer.string("rules.editor3.scheme.http")),
            ])
        case .appProtocol:
            func title(_ value: String) -> String { ConditionPresentation.valueTitle(field: .appProtocol, name: nil, value: value, localizer: localizer) }
            return .groupedDropdown([
                [choice("http", title("http"))],
                ["websocket", "rpc", "grpc", "sse", "socketio"].map { choice($0, title($0)) },
            ])
        case .sessionState:
            var options = ["opened", "closed", "paused"].map {
                choice($0, ConditionPresentation.valueTitle(field: .sessionState, name: nil, value: $0, localizer: localizer))
            }
            let lowered = value.lowercased()
            if ConditionField.legacySessionStates.contains(lowered) {
                options.append(
                    choice(
                        lowered, ConditionPresentation.valueTitle(field: .sessionState, name: nil, value: lowered, localizer: localizer),
                        legacy: true))
            }
            return .dropdown(options)
        case .rulesModified:
            return .dropdown([
                choice("true", localizer.string("rules.condition.bool.true")),
                choice("false", localizer.string("rules.condition.bool.false")),
            ])
        case .requestDate:
            return .date
        case .certificate:
            guard let sub = ConditionFieldCatalog.certificateField(name: name) else { return .text(suggestions: false) }
            switch sub.valueKind {
            case .validity: return .none
            case .date: return .date
            case .number, .text: return .text(suggestions: false)
            }
        case .requestBody, .responseBody, .magicString:
            return .text(suggestions: false)
        default:
            return .text(suggestions: suggests)
        }
    }

    /// The value's "Aa" switch (spec 12.3 table).
    private static func valueHasCase(field: ConditionField, name: String?) -> Bool {
        switch field {
        case .url, .host, .path, .method, .clientHTTPVersion, .upstreamHTTPVersion, .requestBody, .responseBody,
            .requestHeader, .responseHeader, .requestCookie, .responseCookie, .cookie, .clientTLSVersion,
            .upstreamTLSVersion, .clientApp, .comment:
            return true
        case .certificate:
            guard let sub = ConditionFieldCatalog.certificateField(name: name) else { return true }
            return sub.valueKind == .text
        default:
            return false
        }
    }

    private static func placeholder(field: ConditionField, name: String?, localizer: Localizer) -> String? {
        switch field {
        case .allSessions, .scheme, .appProtocol, .sessionState, .rulesModified: nil
        case .url: localizer.string("rules.editor3.placeholder.url")
        case .requestHeader, .responseHeader: localizer.string("rules.editor3.placeholder.headerValue")
        case .requestDate: localizer.string("rules.editor3.placeholder.date")
        case .certificate:
            ConditionFieldCatalog.certificateField(name: name)?.valueKind == .date
                ? localizer.string("rules.editor3.placeholder.date") : localizer.string("rules.editor3.placeholder.value")
        default: localizer.string("rules.editor3.placeholder.value")
        }
    }
}
