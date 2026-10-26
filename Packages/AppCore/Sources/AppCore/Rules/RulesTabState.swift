import Foundation
import Observation
import RulesEngine

/// What the rules tab remembers while its view is rebuilt (switching tabs, closing the right-hand area): the
/// selection, a delete waiting for its confirmation, the note being edited, a group being renamed and the groups
/// the user folded. It lives on the app model, not on the view.
@MainActor @Observable public final class RulesTabState {
    public var selection = Set<UUID>()
    /// Items waiting for the delete confirmation.
    public var pendingDeletion: [UUID]?
    /// The rule whose note sheet is open.
    public var noteEditing: UUID?
    /// A group to put into name editing (just created, or chosen in its menu).
    public var renaming: UUID?
    /// Groups the user folded (the outline keeps its own expanded state otherwise).
    public var collapsed = Set<UUID>()

    /// The list's search text and "only enabled" switch.
    public var filter = ToolListFilter()

    public init() {}

    /// Forgets ids that are no longer in the tree, so nothing stale is deleted, selected or edited later.
    public func prune(to tree: RuleTree) {
        let known = Set(tree.rules.map(\.id)).union(tree.groups.map(\.id))
        selection.formIntersection(known)
        collapsed.formIntersection(known)
        if let ids = pendingDeletion {
            let kept = ids.filter(known.contains)
            pendingDeletion = kept.isEmpty ? nil : kept
        }
        if let id = noteEditing, !tree.rules.contains(where: { $0.id == id }) { noteEditing = nil }
        if let id = renaming, !known.contains(id) { renaming = nil }
    }
}
