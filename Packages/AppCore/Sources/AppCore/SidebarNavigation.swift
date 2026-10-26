/// A snapshot of visible sidebar rows in display order, derived from the existing model.
/// This carries no selection or expansion state of its own.
public struct SidebarNavigationRow<ID: Hashable> {
    public let id: ID
    public let parent: ID?
    public let canExpand: Bool
    public let isExpanded: Bool
    public let isEnabled: Bool

    public init(id: ID, parent: ID? = nil, canExpand: Bool = false, isExpanded: Bool = false, isEnabled: Bool = true) {
        self.id = id
        self.parent = parent
        self.canExpand = canExpand
        self.isExpanded = isExpanded
        self.isEnabled = isEnabled
    }
}

public enum SidebarNavigation {
    public enum Direction { case up, down, left, right, activate }
    public enum Action<ID: Hashable>: Equatable {
        case select(ID)
        case expand(ID, Bool)
    }

    public static func action<ID>(
        _ direction: Direction, selected: ID?, rows: [SidebarNavigationRow<ID>]
    ) -> Action<ID>? {
        let index = rows.firstIndex { $0.id == selected }
        switch direction {
        case .up, .down:
            let candidates: [SidebarNavigationRow<ID>]
            if direction == .down {
                candidates = Array(rows.dropFirst(index.map { $0 + 1 } ?? 0))
            } else {
                candidates = Array(rows.prefix(index ?? rows.count).reversed())
            }
            return candidates.first(where: \.isEnabled).map { .select($0.id) }
        case .left, .right, .activate:
            guard let index, rows[index].isEnabled else { return nil }
            let row = rows[index]
            switch direction {
            case .activate: return .select(row.id)
            case .left:
                if row.canExpand && row.isExpanded { return .expand(row.id, false) }
                return rows.first { $0.id == row.parent && $0.isEnabled }.map { .select($0.id) }
            case .right:
                guard row.canExpand else { return nil }
                if !row.isExpanded { return .expand(row.id, true) }
                return rows.dropFirst(index + 1).first { $0.parent == row.id && $0.isEnabled }.map { .select($0.id) }
            case .up, .down: return nil
            }
        }
    }
}
