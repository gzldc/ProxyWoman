import Foundation
import RulesEngine

public enum RuleRowMenuItem: CaseIterable, Sendable {
    case moveUp, moveDown, addGroup, addRule, duplicate, rename, editNote, delete

    public var titleKey: String {
        switch self {
        case .moveUp: "rules.row.moveUp"
        case .moveDown: "rules.row.moveDown"
        case .addGroup: "rules.row.addGroup"
        case .addRule: "rules.row.addRule"
        case .duplicate: "rules.row.duplicate"
        case .rename: "rules.row.rename"
        case .editNote: "rules.row.editNote"
        case .delete: "rules.row.delete"
        }
    }
}

public struct RuleRowMenuEntry: Equatable, Sendable {
    public var item: RuleRowMenuItem
    public var isEnabled: Bool
}

/// The right-click menu of a rule or group row in the rules tab.
public enum RuleRowMenu {
    public static func entries(for id: UUID, tree: RuleTree, canMutate: Bool, isReadOnly: Bool) -> [RuleRowMenuEntry] {
        let rule = tree.rules.first { $0.id == id }
        let group = rule == nil ? tree.groups.first { $0.id == id } : nil
        guard rule != nil || group != nil else { return [] }
        let siblings = tree.siblings(ofParent: rule?.groupID ?? group?.parentID)
        let index = siblings.firstIndex(of: id)
        let items: [RuleRowMenuItem] =
            rule != nil
            ? [.moveUp, .moveDown, .addGroup, .addRule, .duplicate, .editNote, .delete]
            : [.moveUp, .moveDown, .addGroup, .addRule, .duplicate, .rename, .delete]
        return items.map { item in
            let enabled: Bool
            switch item {
            case .duplicate: enabled = canMutate
            case .moveUp: enabled = canMutate && !isReadOnly && (index ?? 0) > 0
            case .moveDown: enabled = canMutate && !isReadOnly && index.map { $0 < siblings.count - 1 } == true
            default: enabled = canMutate && !isReadOnly
            }
            return RuleRowMenuEntry(item: item, isEnabled: enabled)
        }
    }

    /// Where "add group / add rule" from this row's menu puts the new item: a rule's group, or the group itself.
    public static func newItemParent(for id: UUID, tree: RuleTree) -> UUID? {
        if let rule = tree.rules.first(where: { $0.id == id }) { return rule.groupID }
        return tree.groups.contains { $0.id == id } ? id : nil
    }
}
