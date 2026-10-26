import Foundation
import RulesEngine

/// Which commands the outline table offers for its current selection (D12). Pure: the view only asks.
public enum RuleOutlineCommands {
    /// What a command does to a selection of rules and groups. Ids that are not in the tree are ignored.
    public static func availability(
        selection: [UUID], tree: RuleTree, canMutate: Bool, liveBreakpoints: Bool
    ) -> (canDuplicate: Bool, canDelete: Bool, canToggle: Bool, canOpen: Bool, canMoveUp: Bool, canMoveDown: Bool) {
        let none = (canDuplicate: false, canDelete: false, canToggle: false, canOpen: false, canMoveUp: false, canMoveDown: false)
        let ids = known(selection, in: tree)
        guard canMutate, !ids.isEmpty else { return none }
        let single = ids.count == 1 ? ids[0] : nil
        let isRule = single.map { id in tree.rules.contains { $0.id == id } } ?? false
        var up = false
        var down = false
        if let single, let parent = parent(of: single, in: tree) {
            let siblings = tree.siblings(ofParent: parent)
            if let index = siblings.firstIndex(of: single) {
                up = index > 0
                down = index < siblings.count - 1
            }
        }
        // Enabling a rule with a breakpoint needs the breakpoint window; switching anything off never does.
        let enabling = toggleTarget(selection: ids, tree: tree)
        let blocked = enabling && !liveBreakpoints && ids.contains { id in
            tree.rules.first { $0.id == id }.map { !$0.enabled && $0.containsBreakpoint } ?? false
        }
        return (
            canDuplicate: single != nil, canDelete: true, canToggle: !blocked, canOpen: isRule,
            canMoveUp: up, canMoveDown: down
        )
    }

    /// ⌘N: a new rule needs no selection.
    public static func canCreate(canMutate: Bool) -> Bool { canMutate }

    /// The selected ids that are saved items of the tree, once each (an unsaved draft's id is not one).
    public static func knownSelection(_ selection: [UUID], tree: RuleTree) -> [UUID] { known(selection, in: tree) }

    /// The enabled state a toggle sets: on when any selected item is off, otherwise off.
    public static func toggleTarget(selection: [UUID], tree: RuleTree) -> Bool {
        known(selection, in: tree).contains { id in
            if let rule = tree.rules.first(where: { $0.id == id }) { return !rule.enabled }
            if let group = tree.groups.first(where: { $0.id == id }) { return !group.enabled }
            return false
        }
    }

    /// Where "new rule" and "new group" put their item: in the selected group, beside the selected rule,
    /// at the root otherwise (also for a mixed selection).
    public static func newItemParent(selection: [UUID], tree: RuleTree) -> UUID? {
        let ids = known(selection, in: tree)
        guard ids.count == 1 else { return nil }
        if tree.groups.contains(where: { $0.id == ids[0] }) { return ids[0] }
        return tree.rules.first { $0.id == ids[0] }?.groupID
    }

    private static func known(_ selection: [UUID], in tree: RuleTree) -> [UUID] {
        var seen = Set<UUID>()
        let present = Set(tree.rules.map(\.id)).union(tree.groups.map(\.id))
        return selection.filter { present.contains($0) && seen.insert($0).inserted }
    }

    /// The parent of a rule or group (`nil` inside `.some` = root); nil when unknown.
    private static func parent(of id: UUID, in tree: RuleTree) -> UUID?? {
        if let rule = tree.rules.first(where: { $0.id == id }) { return .some(rule.groupID) }
        if let group = tree.groups.first(where: { $0.id == id }) { return .some(group.parentID) }
        return nil
    }
}
