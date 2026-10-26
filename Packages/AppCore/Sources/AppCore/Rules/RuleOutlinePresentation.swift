import Foundation
import Localization
import RulesEngine

/// The words of the outline table that need more than one rule field.
public enum RuleOutlinePresentation {
    /// The Action column: one action as the rule summary states it, several as the first plus a count.
    public static func actionText(
        of rule: Rule, assetName: (UUID) -> String?, localizer: Localizer = L10n.localizer
    ) -> String {
        guard rule.actions.count > 1, let first = rule.actions.first else {
            return RulePresentation.actionSummary(of: rule, assetName: assetName, localizer: localizer)
        }
        var head = rule
        head.actions = [first]
        let text = RulePresentation.actionSummary(of: head, assetName: assetName, localizer: localizer)
        return localizer.format("rules.outline.moreActions", arguments: [text, rule.actions.count])
    }

    /// "已启用 N / M" on a group row.
    public static func groupCountText(_ counts: (enabled: Int, total: Int), localizer: Localizer = L10n.localizer) -> String {
        localizer.format("rules.outline.groupCount", arguments: [counts.enabled, counts.total])
    }

    /// Why a drop is refused, for the accessibility description. Nil when it is allowed or the target is unknown.
    public static func dropMessage(_ verdict: RuleTree.MoveVerdict, localizer: Localizer = L10n.localizer) -> String? {
        switch verdict {
        case .allowed, .unknownTarget: nil
        case .intoSelf: localizer.string("rules.outline.drop.intoSelf")
        case .tooDeep: localizer.string("rules.outline.drop.tooDeep")
        case .tooManyRules: localizer.string("rules.outline.drop.limit")
        }
    }

    /// The confirmation before deleting the selection; nil when nothing in it exists.
    public static func deleteQuestion(for ids: [UUID], tree: RuleTree, localizer: Localizer = L10n.localizer) -> String? {
        let removal = tree.removing(ids)
        guard removal.removedRules + removal.removedGroups > 0 else { return nil }
        let present = Set(tree.rules.map(\.id)).union(tree.groups.map(\.id))
        let chosen = Array(Set(ids.filter(present.contains)))
        if chosen.count == 1, let id = chosen.first {
            if let rule = tree.rules.first(where: { $0.id == id }) {
                return localizer.format(
                    "rules.outline.delete.rule", arguments: [RulePresentation.displayName(rule.name, localizer: localizer)])
            }
            if let group = tree.groups.first(where: { $0.id == id }) {
                return localizer.format("rules.outline.delete.group", arguments: [group.name, removal.removedRules])
            }
        }
        return localizer.format("rules.outline.delete.multiple", arguments: [chosen.count, removal.removedRules])
    }
}
