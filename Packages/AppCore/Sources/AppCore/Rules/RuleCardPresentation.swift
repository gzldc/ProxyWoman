import Foundation
import Localization
import RulesEngine

/// What one rule row shows: a title, "match → action", and the hit text (hover help only, never in the row).
public struct RuleCard: Equatable, Sendable {
    public var title: String
    public var summary: String
    public var hitBadge: String?
    public var isEnabled: Bool
    public var isReadOnly: Bool

    /// The hover help of a one-line row: the whole summary (the row cuts it off) and, when the rule matched, its hits.
    public var helpText: String { [summary, hitBadge].compactMap { $0 }.joined(separator: "\n") }
}

/// What one group card shows.
public struct GroupCard: Equatable, Sendable {
    public var title: String
    public var countText: String
    public var isEnabled: Bool
}

public enum RuleCardPresentation {
    public static func card(
        for rule: Rule, hits: Int, isReadOnly: Bool, assetName: (UUID) -> String?, localizer: Localizer = L10n.localizer
    ) -> RuleCard {
        let match = RulePresentation.matchSummary(of: rule, localizer: localizer)
        let action = RuleOutlinePresentation.actionText(of: rule, assetName: assetName, localizer: localizer)
        return RuleCard(
            title: RulePresentation.displayName(rule.name, localizer: localizer),
            summary: localizer.format("rules.card.summary", arguments: [match, action]),
            hitBadge: hits > 0 ? localizer.format("rules.card.hits", arguments: [hits]) : nil,
            isEnabled: rule.enabled, isReadOnly: isReadOnly)
    }

    public static func group(_ group: RuleGroup, counts: (enabled: Int, total: Int), localizer: Localizer = L10n.localizer) -> GroupCard {
        GroupCard(
            title: RulePresentation.displayName(group.name, localizer: localizer), countText: localizer.format("rules.card.groupCount", arguments: [counts.enabled, counts.total]),
            isEnabled: group.enabled)
    }
}
