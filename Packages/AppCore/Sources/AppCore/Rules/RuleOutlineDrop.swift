import Foundation
import RulesEngine

/// Turns the table's drop proposal (a row and a slot) into the tree's (parent, index). Pure.
public enum RuleOutlineDrop {
    public static let pasteboardType = "com.proxywoman.rules.items"

    public struct Target: Equatable, Sendable {
        public var parent: UUID?
        /// The slot as the table counts it, moving rows included: what the table is told to highlight.
        public var tableIndex: Int
        /// The index `RuleTree.move` takes: the slot among the parent's children without the moving rows.
        public var insertionIndex: Int
    }

    public static func pasteboardString(_ id: UUID) -> String { id.uuidString }

    public static func ids(fromPasteboardStrings strings: [String]) -> [UUID] {
        strings.compactMap { UUID(uuidString: $0) }
    }

    /// `proposedItem` is the row under the pointer (`nil` = the table itself) and `childIndex` the slot
    /// between its children, or -1 for "on the row". A drop on a group goes into it at the end; a drop on
    /// a rule lands right after it, in the rule's parent.
    public static func target(proposedItem: UUID?, childIndex: Int, moving: [UUID], tree: RuleTree) -> Target? {
        guard !moving.isEmpty else { return nil }
        let parent: UUID?
        var slot = childIndex
        if let proposedItem {
            if tree.groups.contains(where: { $0.id == proposedItem }) {
                parent = proposedItem
                if slot < 0 { slot = tree.siblings(ofParent: proposedItem).count }
            } else if let rule = tree.rules.first(where: { $0.id == proposedItem }) {
                parent = rule.groupID
                slot = (tree.siblings(ofParent: parent).firstIndex(of: proposedItem) ?? -1) + 1
            } else {
                return nil
            }
        } else {
            parent = nil
            if slot < 0 { slot = tree.siblings(ofParent: nil).count }
        }
        let siblings = tree.siblings(ofParent: parent)
        slot = min(max(slot, 0), siblings.count)
        let movingSet = Set(moving)
        let before = siblings.prefix(slot).filter(movingSet.contains).count
        return Target(parent: parent, tableIndex: slot, insertionIndex: slot - before)
    }

    /// Whether the drop would be accepted; `.unknownTarget` when the proposal does not make sense.
    public static func verdict(
        proposedItem: UUID?, childIndex: Int, moving: [UUID], tree: RuleTree, limits: RulesLimits
    ) -> RuleTree.MoveVerdict {
        guard let target = target(proposedItem: proposedItem, childIndex: childIndex, moving: moving, tree: tree) else {
            return .unknownTarget
        }
        return tree.canMove(moving, toParent: target.parent, at: target.insertionIndex, limits: limits)
    }
}
