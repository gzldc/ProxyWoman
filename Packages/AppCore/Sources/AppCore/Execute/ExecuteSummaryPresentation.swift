import FlowStore
import Foundation
import Localization
import RulesEngine

/// The words for the result of an Execute run and for one flow's Execute outcomes (D12, D17).
public enum ExecuteSummaryPresentation {
    /// One line per fact worth telling, in a fixed order; counts of 0 give no line. Every rule the run
    /// evaluated is listed, also those that matched nothing.
    public static func lines(
        _ summary: ExecuteSummary, ruleName: (UUID) -> String?, localizer: Localizer = L10n.localizer
    ) -> [String] {
        var lines: [String] = []
        if summary.wasCancelled { lines.append(localizer.string("rules.execute.summary.cancelled")) }
        for line in summary.rules {
            let name = ruleName(line.ruleID).map { RulePresentation.displayName($0, localizer: localizer) }
                ?? localizer.string("ruleOutcome.unknownRule")
            lines.append(localizer.format("rules.execute.summary.rule", arguments: [name, line.flows]))
        }
        if summary.modifiedFlows > 0 {
            lines.append(localizer.format("rules.execute.summary.modified", arguments: [summary.modifiedFlows]))
        }
        if summary.hiddenFlows > 0 {
            lines.append(localizer.format("rules.execute.summary.hidden", arguments: [summary.hiddenFlows]))
        }
        if summary.annotatedFlows > 0 {
            lines.append(localizer.format("rules.execute.summary.annotated", arguments: [summary.annotatedFlows]))
        }
        if summary.skippedInProgress > 0 {
            lines.append(localizer.format("rules.execute.summary.skippedInProgress", arguments: [summary.skippedInProgress]))
        }
        if summary.notApplicableActions > 0 {
            lines.append(localizer.format("rules.execute.summary.notApplicable", arguments: [summary.notApplicableActions]))
        }
        if summary.vanished > 0 {
            lines.append(localizer.format("rules.execute.summary.vanished", arguments: [summary.vanished]))
        }
        return lines
    }

    /// The outcomes of the flow's last Execute run, as the detail pane's rule results read them.
    public static func resultLines(
        of flow: Flow, ruleName: (UUID) -> String?, localizer: Localizer = L10n.localizer,
        cardIndex: OutcomeCardIndex? = nil
    ) -> [RuleResultLine] {
        guard let record = flow.execute else { return [] }
        return RulePresentation.resultLines(record.matches, ruleName: ruleName, localizer: localizer, cardIndex: cardIndex)
    }
}
