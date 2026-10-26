import FlowStore

/// What the detail pane's Execute banner offers for a flow (D14).
public struct ExecuteDetailBanner: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A modification layer exists: switch, compare and undo.
        case modified
        /// Only a mark, comment or hide was written: undo only.
        case recordOnly
    }

    public var kind: Kind
    public var canCompare: Bool

    public init(kind: Kind, canCompare: Bool) {
        self.kind = kind
        self.canCompare = canCompare
    }

    /// Nil for a flow Execute never wrote to.
    public static func of(_ flow: Flow) -> ExecuteDetailBanner? {
        guard flow.execute != nil else { return nil }
        if let overlay = flow.executeOverlay, !overlay.isEmpty { return ExecuteDetailBanner(kind: .modified, canCompare: true) }
        return ExecuteDetailBanner(kind: .recordOnly, canCompare: false)
    }
}
