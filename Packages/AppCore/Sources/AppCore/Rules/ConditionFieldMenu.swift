import Foundation
import Localization
import RulesEngine

/// The words of the condition editor that do not depend on a row: menu sections, direction, judgment point, how the
/// rows combine. Every key is written out in full.
public enum ConditionEditorPresentation {
    public static func title(_ group: ConditionFieldGroup, localizer: Localizer = L10n.localizer) -> String {
        switch group {
        case .common: localizer.string("rules.fieldGroup.common")
        case .request: localizer.string("rules.fieldGroup.request")
        case .response: localizer.string("rules.fieldGroup.response")
        case .connection: localizer.string("rules.fieldGroup.connection")
        case .afterCompletion: localizer.string("rules.fieldGroup.afterCompletion")
        case .other: localizer.string("rules.fieldGroup.other")
        }
    }

    public static func title(_ side: ConditionSide, localizer: Localizer = L10n.localizer) -> String {
        switch side {
        case .request: localizer.string("rules.side.request")
        case .response: localizer.string("rules.side.response")
        case .both: localizer.string("rules.side.both")
        case .neither: localizer.string("rules.side.neither")
        }
    }

    public static func afterCompletionTag(localizer: Localizer = L10n.localizer) -> String {
        localizer.string("rules.afterCompletion.tag")
    }

    public static func title(_ point: EvaluationPoint, localizer: Localizer = L10n.localizer) -> String {
        switch point {
        case .connect: localizer.string("rules.judgment.connect")
        case .request: localizer.string("rules.judgment.request")
        case .response: localizer.string("rules.judgment.response")
        case .completion: localizer.string("rules.judgment.completion")
        }
    }

    public static func title(_ mode: ConditionGroup.Mode, localizer: Localizer = L10n.localizer) -> String {
        switch mode {
        case .all: localizer.string("rules.editor2.mode.all")
        case .any: localizer.string("rules.editor2.mode.any")
        case .none: localizer.string("rules.editor2.mode.none")
        }
    }

    /// "Any number of times" / "A specific number of times" for the two-item occurrence choice.
    public static func title(specific: Bool, localizer: Localizer = L10n.localizer) -> String {
        localizer.string(specific ? "rules.editor2.occurrence.choice.specific" : "rules.editor2.occurrence.choice.any")
    }
}
