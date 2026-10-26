import Foundation
import Localization
import RulesEngine

/// One entry of the "group" menu in the editor's top bar. `id == nil` is the root ("no group").
public struct RuleGroupChoice: Equatable, Identifiable, Sendable {
    public var id: UUID?
    public var name: String
    /// 0 for the root, 1 for a group directly under it, and so on.
    public var depth: Int
}

/// The words and small decisions of the editor window's frame: title, group menu, judgment line, save button.
public enum RuleEditorWindowPresentation {
    /// The root first, then every group depth first, siblings by their order. A group whose parent is not in the list
    /// is shown under the root; a loop of groups (never stored) is left out instead of looping.
    public static func groupChoices(_ groups: [RuleGroup]) -> [RuleGroupChoice] {
        let known = Set(groups.map(\.id))
        var children: [UUID?: [RuleGroup]] = [:]
        for group in groups {
            let parent = group.parentID.flatMap { known.contains($0) ? $0 : nil }
            children[parent, default: []].append(group)
        }
        var result = [RuleGroupChoice(id: nil, name: "", depth: 0)]
        var visited = Set<UUID>()
        func walk(_ parent: UUID?, depth: Int) {
            for group in (children[parent] ?? []).sorted(by: { $0.order < $1.order }) where visited.insert(group.id).inserted {
                result.append(RuleGroupChoice(id: group.id, name: group.name, depth: depth))
                walk(group.id, depth: depth + 1)
            }
        }
        walk(nil, depth: 1)
        return result
    }

    /// The menu text: "no group" for the root, otherwise the name indented by its depth.
    public static func title(of choice: RuleGroupChoice, localizer: Localizer = L10n.localizer) -> String {
        guard choice.id != nil else { return localizer.string("rules.outline.ungrouped") }
        let indent = String(repeating: "\u{2003}", count: max(0, choice.depth - 1))
        return indent + RulePresentation.displayName(choice.name, localizer: localizer)
    }

    public static func windowTitle(isNew: Bool, localizer: Localizer = L10n.localizer) -> String {
        isNew ? localizer.string("rules.editor2.title.new") : localizer.string("rules.editor2.title.edit")
    }

    /// The name a rule saved without one gets.
    public static func autoName(localizer: Localizer = L10n.localizer) -> String {
        localizer.string("rules.builder.autoName")
    }

    /// The combine choice in the one-sentence header: "满足全部条件".
    public static func headerModeTitle(_ mode: ConditionGroup.Mode, localizer: Localizer = L10n.localizer) -> String {
        switch mode {
        case .all: localizer.string("rules.builder.header.mode.all")
        case .any: localizer.string("rules.builder.header.mode.any")
        case .none: localizer.string("rules.builder.header.mode.none")
        }
    }

    /// "Sessions will be matched on Request": in words, never with a point code.
    public static func matchedAtLine(_ point: EvaluationPoint, localizer: Localizer = L10n.localizer) -> String {
        switch point {
        case .connect: localizer.string("rules.builder.matchedAt.connect")
        case .request: localizer.string("rules.builder.matchedAt.request")
        case .response: localizer.string("rules.builder.matchedAt.response")
        case .completion: localizer.string("rules.builder.matchedAt.completion")
        }
    }

    /// The words of the question asked when the window is closed with unsaved changes; nil when it closes at once.
    public struct ClosePrompt: Equatable, Sendable {
        public var message: String
        public var detail: String
        /// False when the document cannot be saved as it is: the question then has no Save button.
        public var canSave: Bool
        public var saveTitle: String
        public var discardTitle: String
        public var cancelTitle: String
    }

    /// Names longer than this are shortened with an ellipsis in the question.
    static let closePromptNameLimit = 24

    public static func closePrompt(_ decision: RuleEditorSession.CloseDecision, localizer: Localizer = L10n.localizer) -> ClosePrompt? {
        let message: String
        let canSave: Bool
        switch decision {
        case .closeNow: return nil
        case .askSave(let name):
            let shown = name.count <= closePromptNameLimit ? name : String(name.prefix(closePromptNameLimit)) + "…"
            message = localizer.format("rules.editor2.close.saveMessage", arguments: [shown])
            canSave = true
        case .askDiscardOnly:
            message = localizer.string("rules.editor2.close.invalidMessage")
            canSave = false
        }
        return ClosePrompt(
            message: message, detail: localizer.string("rules.editor2.close.detail"), canSave: canSave,
            saveTitle: localizer.string("rules.editor2.pending.save"), discardTitle: localizer.string("rules.editor2.close.dontSave"),
            cancelTitle: localizer.string("rules.editor2.pending.cancel"))
    }

    /// Save works whenever nothing is writing or importing, changed or not.
    public static func canSave(hasDocument: Bool, isBusy: Bool, isImporting: Bool) -> Bool {
        hasDocument && !isBusy && !isImporting
    }

    /// What to tell the user after a save that did not go through; nil when there is nothing to say (saved, a running
    /// operation, or a question the window asks itself).
    public static func failureMessage(_ result: RuleEditorSession.SaveResult, localizer: Localizer = L10n.localizer) -> String? {
        switch result {
        case .saved, .needsConfirmation: nil
        case .busy: localizer.string("rules.editor2.busy")
        case .invalid: localizer.string("rules.editor2.fixIssues")
        case .failed(.conflict): localizer.string("rules.editor2.conflictInRulesWindow")
        case .failed(let error): error.message(localizer: localizer)
        }
    }
}

/// One entry of a choice input: the value stored in the rule and the words shown for it.
public struct ConditionChoice: Equatable, Sendable {
    public var value: String
    public var title: String
    /// An old entry a saved row still carries: listed with an "old style" tag, never offered to a new row.
    public var isLegacy: Bool

    public init(value: String, title: String, isLegacy: Bool = false) {
        self.value = value
        self.title = title
        self.isLegacy = isLegacy
    }
}

/// Which input a condition row's value takes.
public enum ConditionValueInput: Equatable, Sendable {
    case none, text, number, date, bool
    case choice([ConditionChoice])
}

/// What the condition row view needs, decided here so it can be tested.
public enum ConditionRowPresentation {
    public static func valueInput(
        field: ConditionField, name: String?, op: ConditionOperator, localizer: Localizer = L10n.localizer
    ) -> ConditionValueInput {
        if field == .allSessions || op == .isEmpty || op == .isNotEmpty { return .none }
        switch field.valueKind(name: name) {
        case .none: return .none
        case .text: return .text
        case .number: return .number
        case .date: return .date
        case .bool: return .bool
        case .choice(let values):
            return .choice(
                values.map {
                    ConditionChoice(
                        value: $0, title: ConditionPresentation.valueTitle(field: field, name: name, value: $0, localizer: localizer))
                })
        }
    }

    /// A line of help under the value input for ranges and dates; nil when none is needed.
    public static func hint(
        field: ConditionField, name: String?, op: ConditionOperator, localizer: Localizer = L10n.localizer
    ) -> String? {
        let isDate = field.valueKind(name: name) == .date
        switch (op == .inRange, isDate) {
        case (true, true): return localizer.string("rules.editor2.hint.dateRange")
        case (true, false): return localizer.string("rules.editor2.hint.range")
        case (false, true): return localizer.string("rules.editor2.hint.date")
        case (false, false): return nil
        }
    }

    /// The names a field with a fixed set of them offers (certificate part, app part); nil when any text goes.
    public static func nameChoices(for field: ConditionField, localizer: Localizer = L10n.localizer) -> [ConditionChoice]? {
        if field == .certificate {
            return CertificateField.allCases.map {
                ConditionChoice(value: $0.rawValue, title: CertificateFieldPresentation.title($0, localizer: localizer))
            }
        }
        return ConditionField.allowedNames(for: field)?.map {
            ConditionChoice(value: $0, title: nameTitle(field: field, name: $0, localizer: localizer), isLegacy: true)
        }
    }

    public static func nameTitle(field: ConditionField, name: String, localizer: Localizer = L10n.localizer) -> String {
        if field == .certificate { return CertificateFieldPresentation.title(key: name, localizer: localizer) }
        return switch (field, name) {
        case (.certificate, "subject"): localizer.string("rules.condition.certificate.subject")
        case (.certificate, "issuer"): localizer.string("rules.condition.certificate.issuer")
        case (.certificate, "serialNumber"): localizer.string("rules.condition.certificate.serialNumber")
        case (.certificate, "sha256Fingerprint"): localizer.string("rules.condition.certificate.sha256Fingerprint")
        case (.certificate, "notBefore"): localizer.string("rules.condition.certificate.notBefore")
        case (.certificate, "notAfter"): localizer.string("rules.condition.certificate.notAfter")
        case (.clientApp, "name"): localizer.string("rules.condition.clientApp.name")
        case (.clientApp, "path"): localizer.string("rules.condition.clientApp.path")
        case (.clientApp, "pid"): localizer.string("rules.condition.clientApp.pid")
        default: name
        }
    }

    /// The comparisons the picker offers; the row's current one is kept even if the menu would not offer it, so the
    /// shown value is never silently different from the saved one.
    public static func operatorChoices(for row: ConditionRowDraft) -> [ConditionOperator] {
        let allowed = ConditionFieldCatalog.operatorGroups(field: row.field, name: row.name.isEmpty ? nil : row.name).flatMap { $0 }
        return allowed.contains(row.op) ? allowed : allowed + [row.op]
    }

    /// An old-style row is shown, not edited: the picker would have no entry for its comparison.
    public static func isReadOnly(_ row: ConditionRowDraft) -> Bool { row.isLegacyShape }
}
