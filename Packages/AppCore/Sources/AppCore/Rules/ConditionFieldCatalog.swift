import Foundation
import Localization
import RulesEngine

/// Which message a field reads, as the field menu's circle arrow shows it (spec 12.2). This is a map of its own, not the
/// engine's `ConditionSide`: several fields are shown with another direction than the one the engine judges them at.
public enum ConditionDirection: Equatable, Sendable {
    case request, response, both

    /// Three distinguishable SF Symbols.
    public var symbolName: String {
        switch self {
        case .request: "arrow.up.right.circle"
        case .response: "arrow.down.left.circle"
        case .both: "arrow.up.left.and.arrow.down.right.circle"
        }
    }

    /// Request blue, response orange, both green.
    public var token: ShellStyle.Token {
        switch self {
        case .request: .request
        case .response: .response
        case .both: .success
        }
    }

    public func title(localizer: Localizer = L10n.localizer) -> String {
        switch self {
        case .request: localizer.string("rules.side.request")
        case .response: localizer.string("rules.side.response")
        case .both: localizer.string("rules.side.both")
        }
    }
}

/// One entry of the field menu.
public struct ConditionMenuEntry: Equatable, Sendable {
    public var field: ConditionField
    public var direction: ConditionDirection
    /// Listed but greyed out: new rules cannot pick it, saved rows that use it still work and show the deprecation card.
    public var isDeprecated: Bool
}

/// The three headed sections of the field list.
public enum ConditionFieldSectionKind: Equatable, Sendable {
    case request, response, other

    public func title(localizer: Localizer = L10n.localizer) -> String {
        switch self {
        case .request: localizer.string("rules.fieldSection.request")
        case .response: localizer.string("rules.fieldSection.response")
        case .other: localizer.string("rules.fieldSection.other")
        }
    }
}

public struct ConditionMenuSection: Equatable, Sendable {
    public var kind: ConditionFieldSectionKind
    public var entries: [ConditionMenuEntry]
}

/// Which fields the menu offers and in what order, their directions, the deprecated and the old-style ones.
public enum ConditionFieldCatalog {
    private static func entry(_ field: ConditionField, _ direction: ConditionDirection) -> ConditionMenuEntry {
        ConditionMenuEntry(field: field, direction: direction, isDeprecated: deprecatedFields.contains(field))
    }

    /// Session state, cookie and TLS version: shown, not selectable (R8F2-2).
    public static let deprecatedFields: [ConditionField] = [.sessionState, .cookie, .tlsVersion]

    /// Every menu field with its direction and deprecation, in the order of the former single list (spec 12.2). The field
    /// list shows them through `menuSections` (R8F3-7); this is the data behind `direction(of:)` and `menuFields`.
    public static let menuGroups: [[ConditionMenuEntry]] = [
        [entry(.allSessions, .request)],
        [entry(.url, .request), entry(.host, .request), entry(.path, .request), entry(.scheme, .request)],
        [entry(.method, .request), entry(.appProtocol, .response), entry(.statusCode, .response), entry(.sessionState, .both)],
        [entry(.clientHTTPVersion, .request), entry(.upstreamHTTPVersion, .response)],
        [entry(.requestBody, .request), entry(.responseBody, .response)],
        [entry(.requestHeader, .request), entry(.responseHeader, .response)],
        [entry(.requestCookie, .request), entry(.responseCookie, .response), entry(.cookie, .both)],
        [entry(.requestBodySize, .request), entry(.responseBodySize, .response)],
        [entry(.requestDate, .request), entry(.requestTime, .request), entry(.durationMs, .response)],
        [entry(.clientIP, .request), entry(.remoteIP, .response)],
        [entry(.certificate, .response)],
        [entry(.clientTLSVersion, .request), entry(.upstreamTLSVersion, .response), entry(.tlsVersion, .both)],
        [entry(.clientApp, .request)],
        [entry(.comment, .both), entry(.rulesModified, .both)],
        [entry(.magicString, .both)],
    ]

    /// The menu as the three headed sections the field list shows (R8F3-7): request, response, and the rest. Every menu
    /// field is in exactly one; the entries keep their own direction icon.
    public static let menuSections: [ConditionMenuSection] = {
        let entries = Dictionary(uniqueKeysWithValues: menuGroups.flatMap { $0 }.map { ($0.field, $0) })
        func section(_ kind: ConditionFieldSectionKind, _ fields: [ConditionField]) -> ConditionMenuSection {
            ConditionMenuSection(kind: kind, entries: fields.compactMap { entries[$0] })
        }
        return [
            section(.request, [
                .url, .host, .path, .scheme, .method, .requestHeader, .requestCookie, .requestBody, .requestBodySize,
                .clientHTTPVersion, .clientTLSVersion, .clientIP, .requestDate, .requestTime, .clientApp,
            ]),
            section(.response, [
                .statusCode, .appProtocol, .responseHeader, .responseCookie, .responseBody, .responseBodySize,
                .upstreamHTTPVersion, .upstreamTLSVersion, .remoteIP, .durationMs, .certificate,
            ]),
            section(.other, [.allSessions, .comment, .magicString, .sessionState, .tlsVersion, .cookie, .rulesModified]),
        ]
    }()

    /// The fields the menu offers, flat and in order.
    public static var menuFields: [ConditionField] { menuGroups.flatMap { $0.map(\.field) } }

    /// The direction of any field; the old-style ones, which the menu does not list, read the request.
    public static func direction(of field: ConditionField) -> ConditionDirection {
        for group in menuGroups {
            if let found = group.first(where: { $0.field == field }) { return found.direction }
        }
        return .request
    }

    public static func isDeprecated(_ field: ConditionField) -> Bool { deprecatedFields.contains(field) }

    /// Fields the new menu does not offer but a saved rule may still carry (R8F2-3); a process row with a sub-key is the
    /// old application field.
    public static func isLegacyOnly(field: ConditionField, name: String?) -> Bool {
        switch field {
        case .port, .queryString, .queryParam, .pathAndQuery: return true
        case .clientApp: return !(name?.isEmpty ?? true)
        case .certificate:
            guard let name, !name.isEmpty else { return false }
            return CertificateField(conditionKey: name) == nil
        default: return false
        }
    }

    // MARK: comparisons

    private static func groups(of field: ConditionField) -> [[ConditionOperator]] {
        ConditionOperator.fiddlerOperators(for: field, name: nil)
    }

    /// The comparison groups of a row, in menu order. Certificate rows take the set of their sub-item (spec 12.4);
    /// the legacy sub-keys keep the text set. Empty for a field without a comparison.
    public static func operatorGroups(field: ConditionField, name: String?) -> [[ConditionOperator]] {
        guard field == .certificate else { return ConditionOperator.fiddlerOperators(for: field, name: name) }
        guard let sub = certificateField(name: name) else { return groups(of: .url) }
        switch sub.valueKind {
        case .validity: return [CertificateValidity.operators]
        case .number: return groups(of: .statusCode)
        case .date: return groups(of: .requestDate)
        case .text: return groups(of: .url)
        }
    }

    /// The comparison a row starts with after its field or sub-item was picked.
    public static func defaultOperator(field: ConditionField, name: String?) -> ConditionOperator {
        guard field == .certificate else { return ConditionOperator.defaultOperator(for: field, name: name) }
        guard let sub = certificateField(name: name) else { return .contains }
        switch sub.valueKind {
        case .validity: return CertificateValidity.valid.op
        case .number, .date: return .equals
        case .text: return .contains
        }
    }

    /// The sub-item of a certificate row; an empty key is the default one. Nil for a legacy-only key.
    public static func certificateField(name: String?) -> CertificateField? {
        guard let name, !name.isEmpty else { return CertificateField.default }
        return CertificateField(conditionKey: name)
    }

    /// True for a comparison that is none of the field's current ones.
    public static func isLegacyOperator(_ op: ConditionOperator, field: ConditionField, name: String?) -> Bool {
        let current = operatorGroups(field: field, name: name).flatMap { $0 }
        if current.isEmpty { return false }
        return !current.contains(op)
    }

    /// False for the comparisons that read no value.
    public static func takesValue(_ op: ConditionOperator) -> Bool {
        switch op {
        case .isEmpty, .isNotEmpty, .exists, .doesNotExist: false
        default: true
        }
    }

    /// Whether the row has a value box: not for all sessions, a comparison without a value, or the certificate's validity.
    public static func showsValue(field: ConditionField, name: String?, op: ConditionOperator) -> Bool {
        if field == .allSessions { return false }
        if field == .certificate, let sub = certificateField(name: name), sub.valueKind == .validity { return false }
        if field == .magicString { return true }
        return takesValue(op)
    }

    /// The deprecated fields among `rows`, each once, in the order they first appear.
    public static func deprecatedFields(in rows: [ConditionRow]) -> [ConditionField] {
        var found: [ConditionField] = []
        for row in rows where isDeprecated(row.field) && !found.contains(row.field) { found.append(row.field) }
        return found
    }
}

/// The certificate's validity is a choice without a value box: the two comparison entries read "valid" and "invalid".
/// It is stored the way the rule engine reads it: the sub-key `validity`, `equals`, and the value `valid` or `invalid`
/// (compared case-insensitively). How it is stored is decided here and nowhere else.
public enum CertificateValidity {
    public struct Choice: Equatable, Sendable {
        public var op: ConditionOperator
        public var value: String
        public var isValid: Bool
    }

    public static let valid = Choice(op: .equals, value: "valid", isValid: true)
    public static let invalid = Choice(op: .equals, value: "invalid", isValid: false)

    /// The comparisons the engine allows for the sub-key: `equals` only.
    public static var operators: [ConditionOperator] { [valid.op] }

    /// The two entries of the menu, in order.
    public static var choices: [Choice] { [valid, invalid] }

    /// What a row stores for the choice.
    public static func encode(valid isValid: Bool) -> (op: ConditionOperator, value: String) {
        let choice = isValid ? valid : invalid
        return (choice.op, choice.value)
    }

    /// The choice a stored comparison and value mean; nil for one that is neither.
    public static func decode(op: ConditionOperator, value: String) -> Bool? {
        guard op == .equals else { return nil }
        switch value.lowercased() {
        case valid.value: return true
        case invalid.value: return false
        default: return nil
        }
    }

    public static func title(valid isValid: Bool, localizer: Localizer = L10n.localizer) -> String {
        localizer.string(isValid ? "rules.editor3.cert.valid" : "rules.editor3.cert.invalid")
    }

    public static func title(op: ConditionOperator, value: String, localizer: Localizer = L10n.localizer) -> String? {
        decode(op: op, value: value).map { title(valid: $0, localizer: localizer) }
    }
}

/// The words of the certificate sub-items.
public enum CertificateFieldPresentation {
    /// The dropdown's sub-items, grouped by `CertificateField.group` (a line between groups).
    public static let menuGroups: [[CertificateField]] = {
        let groups = Dictionary(grouping: CertificateField.allCases, by: \.group)
        return groups.keys.sorted().map { groups[$0] ?? [] }
    }()

    public static func title(_ field: CertificateField, localizer: Localizer = L10n.localizer) -> String {
        switch field {
        case .friendlyName: localizer.string("rules.condition.certField.friendlyName")
        case .version: localizer.string("rules.condition.certField.version")
        case .serialNumber: localizer.string("rules.condition.certField.serialNumber")
        case .expirationDate: localizer.string("rules.condition.certField.expirationDate")
        case .validity: localizer.string("rules.condition.certField.validity")
        case .issueDate: localizer.string("rules.condition.certField.issueDate")
        case .signature: localizer.string("rules.condition.certField.signature")
        case .publicKey: localizer.string("rules.condition.certField.publicKey")
        case .sha1Fingerprint: localizer.string("rules.condition.certField.sha1Fingerprint")
        case .sha256Fingerprint: localizer.string("rules.condition.certField.sha256Fingerprint")
        case .issuerCommonName: localizer.string("rules.condition.certField.issuerCommonName")
        case .issuerCountry: localizer.string("rules.condition.certField.issuerCountry")
        case .issuerOrganization: localizer.string("rules.condition.certField.issuerOrganization")
        case .subjectCommonName: localizer.string("rules.condition.certField.subjectCommonName")
        case .subjectAlternativeName: localizer.string("rules.condition.certField.subjectAlternativeName")
        case .subjectCountry: localizer.string("rules.condition.certField.subjectCountry")
        case .subjectOrganization: localizer.string("rules.condition.certField.subjectOrganization")
        }
    }

    public static func legacyTitle(_ key: LegacyCertificateKey, localizer: Localizer = L10n.localizer) -> String {
        switch key {
        case .subject: localizer.string("rules.condition.certificate.subject")
        case .issuer: localizer.string("rules.condition.certificate.issuer")
        case .serialNumber: localizer.string("rules.condition.certificate.serialNumber")
        case .sha256Fingerprint: localizer.string("rules.condition.certificate.sha256Fingerprint")
        case .notBefore: localizer.string("rules.condition.certificate.notBefore")
        case .notAfter: localizer.string("rules.condition.certificate.notAfter")
        }
    }

    /// The title of the key a certificate row stores; the key as written when it is none of the known ones.
    public static func title(key: String?, localizer: Localizer = L10n.localizer) -> String {
        guard let key, !key.isEmpty else { return title(.default, localizer: localizer) }
        if let field = CertificateField(conditionKey: key) { return title(field, localizer: localizer) }
        if let legacy = LegacyCertificateKey(conditionKey: key) { return legacyTitle(legacy, localizer: localizer) }
        return key
    }
}

/// A date value is stored as `yyyy-MM-dd` (a local calendar day) and shown as `MM/DD/YYYY`.
public enum ConditionDate {
    private static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// The stored text of the day `date` falls on.
    public static func string(from date: Date, timeZone: TimeZone = .current) -> String {
        let parts = calendar(timeZone).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The start of the stored day; nil for text that is not a real `yyyy-MM-dd` day.
    public static func date(from stored: String, timeZone: TimeZone = .current) -> Date? {
        let pieces = stored.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2,
            let year = Int(pieces[0]), let month = Int(pieces[1]), let day = Int(pieces[2])
        else { return nil }
        let calendar = calendar(timeZone)
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        return back.year == year && back.month == month && back.day == day ? date : nil
    }

    /// `MM/DD/YYYY` for a stored day; nil when the text is not one.
    public static func display(_ stored: String) -> String? {
        let pieces = stored.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3, date(from: stored) != nil else { return nil }
        return "\(pieces[1])/\(pieces[2])/\(pieces[0])"
    }
}
