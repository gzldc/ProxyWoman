import Foundation

/// Keeps the last built `RuleOutline` for the view that shows it, so a redraw with nothing new to show
/// (the hit counts refresh twice a second) does not walk a tree of up to 500 rules again. The outline
/// depends on the tree (its committed `revision`), which groups are open and the filter, and on nothing else.
@MainActor
public final class RuleOutlineCache {
    public struct Key: Equatable, Sendable {
        public var revision: UInt64
        public var expanded: Set<UUID>
        public var onlyEnabled: Bool
        public var query: String

        public init(revision: UInt64, expanded: Set<UUID>, onlyEnabled: Bool, query: String) {
            self.revision = revision
            self.expanded = expanded
            self.onlyEnabled = onlyEnabled
            self.query = query
        }
    }

    private var last: (key: Key, outline: RuleOutline)?

    public init() {}

    /// The outline for `key`: the one built last time when the key is unchanged, otherwise `build()`'s.
    public func outline(for key: Key, build: () -> RuleOutline) -> RuleOutline {
        if let last, last.key == key { return last.outline }
        let outline = build()
        last = (key, outline)
        return outline
    }
}
