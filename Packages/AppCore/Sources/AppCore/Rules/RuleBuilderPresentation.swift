import Foundation
import Localization
import RulesEngine

extension ActionType {
    /// The action list of the rule builder, in sections: `ActionCatalog.menuGroups` without the directions.
    public static var builderSections: [[ActionType]] { ActionCatalog.menuGroups.map { $0.map(\.type) } }
}

public enum RuleBuilderPresentation {
    public struct StopProcessing: Equatable, Sendable {
        public var isOn: Bool
        public var isLocked: Bool
        public var reasonKey: String?

        public init(isOn: Bool, isLocked: Bool, reasonKey: String?) {
            self.isOn = isOn
            self.isLocked = isLocked
            self.reasonKey = reasonKey
        }
    }

    /// The "stop processing" checkbox of an action: locked on for actions that always end the pass.
    public static func stopProcessing(for action: ActionDraft) -> StopProcessing {
        if action.isIntrinsicallyFinal {
            return StopProcessing(isOn: true, isLocked: true, reasonKey: "rules.builder.stop.lockedReason")
        }
        return StopProcessing(isOn: action.isFinal, isLocked: false, reasonKey: nil)
    }

    /// The ⓘ beside "stop processing": a final type says it ends the rules after it; any other says what ticking does.
    public static func stopProcessingHintKey(for action: ActionDraft) -> String {
        stopProcessing(for: action).isLocked ? "rules.builder.stop.lockedReason" : "rules.builder.stop.help"
    }

    /// The delete button of a card: off while it is the only one.
    public static func canDeleteAction(cardCount: Int) -> Bool { cardCount > 1 }

    /// "N matches in the current list"; red at zero, green above, nothing while the count is unknown.
    public static func matchCountLine(_ count: Int?, localizer: Localizer = L10n.localizer) -> (text: String, tone: BadgeTone)? {
        guard let count else { return nil }
        return (localizer.format("rules.builder.matchCount", arguments: [count]), count == 0 ? .failure : .success)
    }

    /// The line under one condition row. A row that is not valid yet matches nothing (red zero), so the line is always
    /// there; a valid row still being counted has no line until its count is known.
    public static func rowMatchLine(
        count: Int?, rowIsValid: Bool, localizer: Localizer = L10n.localizer
    ) -> (text: String, tone: BadgeTone)? {
        matchCountLine(rowIsValid ? count : 0, localizer: localizer)
    }

    public static func dot(for side: ActionType.Side) -> ShellStyle.Token {
        switch side {
        case .request: .request
        case .response: .response
        case .both, .none: .success
        }
    }

    public static func dot(for side: ConditionSide) -> ShellStyle.Token {
        switch side {
        case .request: .request
        case .response: .response
        case .both, .neither: .success
        }
    }

    /// The name is no longer required (an empty one is auto-named on save), so this is the window's own rule.
    public static func canSave(hasDocument: Bool, isBusy: Bool, isImporting: Bool) -> Bool {
        RuleEditorWindowPresentation.canSave(hasDocument: hasDocument, isBusy: isBusy, isImporting: isImporting)
    }

    /// Whether the "Aa" case switch means anything for a row: only text comparisons read it (numbers, dates, choices,
    /// presence checks and ranges ignore it).
    public static func supportsCaseSensitivity(input: ConditionValueInput, op: ConditionOperator) -> Bool {
        guard input == .text else { return false }
        switch op {
        case .equals, .notEquals, .contains, .notContains, .startsWith, .endsWith, .regex: return true
        default: return false
        }
    }
}
