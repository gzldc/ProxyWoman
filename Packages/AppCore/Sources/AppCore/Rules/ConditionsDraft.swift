import Foundation
import Localization
import RulesEngine

/// One condition row as the editor holds it: the texts the user types, with the field and the comparison kept
/// consistent (changing the field resets the row the way the reference does). `row` is what gets saved.
public struct ConditionRowDraft: Identifiable, Equatable, Sendable {
    public var id: UUID
    public private(set) var field: ConditionField
    public var name: String
    public private(set) var op: ConditionOperator
    public var value: String
    public var caseSensitive: Bool
    /// What the row stores for the key's case setting. Nil is a row saved before the setting existed (it keeps what its
    /// field did then, `ConditionRow.effectiveNameCaseSensitive`); a row the editor writes stores an explicit value.
    public private(set) var storedNameCaseSensitive: Bool?

    /// Whether the key (a header or cookie name) is compared with case: the setting, else the field's old behaviour.
    /// Toggling it stores an explicit value; an untouched saved row keeps nil and saves as it was.
    public var nameCaseSensitive: Bool {
        get { storedNameCaseSensitive ?? field.legacyNameCaseSensitive }
        set { storedNameCaseSensitive = newValue }
    }

    /// Opening a saved row: the old `h2` HTTP version becomes `HTTP/2`, and `h1` (HTTP/1.0 and HTTP/1.1) becomes "starts
    /// with `HTTP/1.`" (not equals `HTTP/1.1`, which would drop HTTP/1.0), and with contains, starts with and does-not-contain the
    /// value `HTTP/1.` (a regular expression `^HTTP/1\.`); every other old value, field or comparison is
    /// kept as it is and only flagged (`isLegacy`).
    public init(row: ConditionRow) {
        id = UUID()
        field = row.field
        name = row.name ?? ""
        let migrated = Self.migrated(row)
        op = migrated.op
        value = migrated.value
        caseSensitive = row.caseSensitive
        storedNameCaseSensitive = row.nameCaseSensitive
    }

    private static func migrated(_ row: ConditionRow) -> (op: ConditionOperator, value: String) {
        guard row.field == .clientHTTPVersion || row.field == .upstreamHTTPVersion else { return (row.op, row.value) }
        switch (row.value.lowercased(), row.op) {
        case ("h1", .equals): return (.startsWith, "HTTP/1.")
        case ("h1", .notEquals): return (.notContains, "HTTP/1.")
        // Every comparison that read a part of the text keeps meaning "either HTTP/1.x" by naming the shared prefix.
        case ("h1", .contains), ("h1", .startsWith), ("h1", .notContains): return (row.op, "HTTP/1.")
        // A regular expression: the prefix, with the dot escaped (a ruling; the old value `h1` matched no version text).
        case ("h1", .regex): return (.regex, #"^HTTP/1\."#)
        case ("h1", _): return (row.op, "HTTP/1.1")
        case ("h2", _): return (row.op, "HTTP/2")
        default: return (row.op, row.value)
        }
    }

    public var row: ConditionRow {
        ConditionRow(
            field: field, name: name.isEmpty ? nil : name, op: op, value: value, caseSensitive: caseSensitive,
            nameCaseSensitive: storedNameCaseSensitive)
    }

    private var keyName: String? { name.isEmpty ? nil : name }

    /// Everything the row editor draws for this row.
    public func descriptor(localizer: Localizer = L10n.localizer) -> ConditionRowDescriptor {
        ConditionRowDescriptor(field: field, name: keyName, op: op, value: value, localizer: localizer)
    }

    /// An old-style comparison (`hostPattern`, `wildcard`, `regexWhole`) on an old field: shown read-only and saved as it was.
    public var isLegacyShape: Bool { field.isLegacyField && op.isLegacyOnly }

    /// The field is not in the menu any more (spec R8F2-3).
    public var isLegacyField: Bool { ConditionFieldCatalog.isLegacyOnly(field: field, name: keyName) }
    /// The comparison is not one of the field's current ones.
    public var isLegacyOperator: Bool { ConditionFieldCatalog.isLegacyOperator(op, field: field, name: keyName) }
    /// The value is an old one: the session states `completed`, `failed`, `tunnel`.
    public var isLegacyValue: Bool {
        field == .sessionState && ConditionField.legacySessionStates.contains(value.lowercased())
    }
    /// Any of the three: the row shows a grey "old style" mark.
    public var isLegacy: Bool { isLegacyField || isLegacyOperator || isLegacyValue }

    /// False for the comparisons that take no value, for all sessions and for the certificate's validity.
    public var showsValue: Bool { ConditionFieldCatalog.showsValue(field: field, name: keyName, op: op) }

    /// The value of a date row as a day (local calendar); nil while the text is not a stored `yyyy-MM-dd` day.
    public func date(timeZone: TimeZone = .current) -> Date? { ConditionDate.date(from: value, timeZone: timeZone) }

    /// Stores the day `date` falls on as `yyyy-MM-dd`.
    public mutating func setDate(_ date: Date, timeZone: TimeZone = .current) {
        value = ConditionDate.string(from: date, timeZone: timeZone)
    }

    /// Picking a field resets the row as the reference does: the field's default comparison, no key (a certificate row
    /// starts on its friendly name), no value (a dropdown field starts on its first option so the row stays valid), no case
    /// switches.
    public mutating func setField(_ newField: ConditionField) {
        field = newField
        name = newField == .certificate ? CertificateField.default.rawValue : ""
        op = ConditionFieldCatalog.defaultOperator(field: newField, name: keyName)
        value = Self.initialValue(field: newField)
        caseSensitive = false
        // A row the editor writes states its key comparison (without case, as the reference starts it) when the field has one.
        storedNameCaseSensitive = newField.hasKeyCaseOption ? false : nil
    }

    private static func initialValue(field: ConditionField) -> String {
        switch field {
        case .scheme: "https"
        case .appProtocol: "http"
        case .sessionState: "opened"
        case .rulesModified: "true"
        default: ""
        }
    }

    /// Sets the key. A certificate row switches sub-item: when the kind of value changes (text, number, date, validity) the
    /// comparison goes back to the new item's default and the value, which no longer fits, is cleared. For the other
    /// fields, when the key changes what kind of value the row takes (the application's process id is a number, its path a
    /// text) the comparison is fixed up and the value is cleared.
    public mutating func setName(_ newName: String) {
        let before = field.valueKind(name: keyName)
        let beforeCertificate = ConditionFieldCatalog.certificateField(name: keyName)?.valueKind
        name = newName
        if field == .certificate {
            let after = ConditionFieldCatalog.certificateField(name: keyName)?.valueKind
            guard after != beforeCertificate || !ConditionFieldCatalog.operatorGroups(field: field, name: keyName).joined().contains(op)
            else { return }
            op = ConditionFieldCatalog.defaultOperator(field: field, name: keyName)
            if after != beforeCertificate { value = after == .validity ? CertificateValidity.valid.value : "" }
            return
        }
        guard field.valueKind(name: keyName) != before else { return }
        let operators = ConditionOperator.allowed(for: field, name: keyName)
        if !operators.contains(op), let first = operators.first { op = first }
        value = ""
    }

    /// Picks the certificate validity entry: `equals` with `valid` or `invalid`.
    public mutating func setCertificateValidity(valid: Bool) {
        let encoded = CertificateValidity.encode(valid: valid)
        op = encoded.op
        value = encoded.value
    }

    /// Picks a comparison; one that takes no value clears the value.
    public mutating func setOperator(_ newOperator: ConditionOperator) {
        op = newOperator
        if !ConditionFieldCatalog.takesValue(newOperator) { value = "" }
    }
}

/// The left column of the rule editor: the rows, how they combine and which of the matching exchanges count.
public struct ConditionsDraft: Equatable, Sendable {
    /// The key under which `validate` reports a problem with the rows as a whole (too many).
    public static let groupIssueID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    public var mode: ConditionGroup.Mode
    public var occurrence: OccurrenceDraft
    public var rows: [ConditionRowDraft]

    public init(group: ConditionGroup = ConditionGroup()) {
        mode = group.mode
        occurrence = OccurrenceDraft(group.occurrence)
        rows = group.rows.map { ConditionRowDraft(row: $0) }
    }

    private static func newRow() -> ConditionRowDraft {
        ConditionRowDraft(row: ConditionRow(field: .url, op: .contains))
    }

    /// A new "URL contains" row after the row `id`, or at the end.
    public mutating func addRow(after id: UUID? = nil) {
        rows.insert(Self.newRow(), at: id.flatMap { id in rows.firstIndex { $0.id == id }.map { $0 + 1 } } ?? rows.endIndex)
    }

    /// Removes the row; the last remaining row is never removed.
    public mutating func removeRow(_ id: UUID) {
        guard rows.count > 1 else { return }
        rows.removeAll { $0.id == id }
    }

    public mutating func duplicateRow(_ id: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        var copy = rows[index]
        copy.id = UUID()
        rows.insert(copy, at: index + 1)
    }

    /// The rule's conditions when every row and the occurrence are valid; nil otherwise (the live count needs a whole group).
    public func conditionGroup(limits: RulesLimits = RulesLimits()) -> ConditionGroup? {
        guard rows.count <= limits.ruleConditionRows, let parsed = occurrence.occurrence else { return nil }
        for (index, row) in rows.enumerated() where row.row.validationIssue(limits: limits, index: index) != nil {
            return nil
        }
        return ConditionGroup(mode: mode, occurrence: parsed, rows: rows.map(\.row))
    }

    /// The latest point at which any row has its value (no rows: the connection).
    public var judgmentPoint: EvaluationPoint {
        ConditionGroup(mode: mode, rows: rows.map(\.row)).judgmentPoint
    }

    /// Judged once the exchange finished: such a rule can only mark, comment and hide.
    public var isCompletionJudged: Bool { judgmentPoint == .completion }

    /// The problem of each invalid row by row id; too many rows are reported under `groupIssueID`.
    public func validate(limits: RulesLimits) -> [UUID: RuleDraftIssue] {
        var issues: [UUID: RuleDraftIssue] = [:]
        if rows.count > limits.ruleConditionRows { issues[Self.groupIssueID] = .tooManyConditions }
        for (index, row) in rows.enumerated() {
            if let error = row.row.validationIssue(limits: limits, index: index) {
                issues[row.id] = RuleDraftIssue(documentError: error)
            }
        }
        return issues
    }

    /// A problem with "specific count N": not a number, or outside 1...9999.
    public func occurrenceIssue() -> RuleDraftIssue? { occurrence.issue }
}

extension RuleDraftIssue {
    /// The issue for an engine error of the document editor: the rows, counts and judgment point keep their own
    /// issue (the old initializer folds them into `unsupportedStructure`, which a single-action form needs).
    public init(documentError error: RuleValidationError) {
        switch error.code {
        case .invalidOperator: self = .invalidOperator
        case .tooManyConditions: self = .tooManyConditions
        case .tooManyActions: self = .tooManyActions
        case .noActions: self = .noActions
        case .actionNotAllowedAtJudgmentPoint: self = .actionNotAllowedAtResponsePoint
        case .actionNotAllowedAtCompletion: self = .actionNotAllowedAtCompletionPoint
        case .conditionNameRequired: self = .conditionNameRequired
        case .unexpectedConditionName: self = .unexpectedConditionName
        case .invalidConditionName: self = .invalidConditionName
        case .invalidConditionValue: self = .invalidConditionValue
        default: self.init(error)
        }
    }
}
