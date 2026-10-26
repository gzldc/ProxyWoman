import Foundation
import RulesEngine

/// One line of the outline table.
public struct RuleOutlineRow: Identifiable, Equatable, Sendable {
    public enum Item: Equatable, Sendable {
        case group(RuleGroup)
        case rule(Rule)
    }

    public var item: Item
    /// 0 = root level (D6: no synthetic "ungrouped" row).
    public var depth: Int
    public var parentID: UUID?
    /// Groups only.
    public var isExpandable: Bool
    /// Enabled over total rules in the group's subtree; groups only.
    public var counts: (enabled: Int, total: Int)?

    public var id: UUID {
        switch item {
        case .group(let group): group.id
        case .rule(let rule): rule.id
        }
    }

    public init(item: Item, depth: Int, parentID: UUID?, isExpandable: Bool, counts: (enabled: Int, total: Int)?) {
        self.item = item
        self.depth = depth
        self.parentID = parentID
        self.isExpandable = isExpandable
        self.counts = counts
    }

    public static func == (lhs: RuleOutlineRow, rhs: RuleOutlineRow) -> Bool {
        lhs.item == rhs.item && lhs.depth == rhs.depth && lhs.parentID == rhs.parentID
            && lhs.isExpandable == rhs.isExpandable && lhs.counts?.enabled == rhs.counts?.enabled
            && lhs.counts?.total == rhs.counts?.total
    }
}

/// The visible rows of the rule tree for a given expansion and filter. With a filter on, matches are
/// shown with every group above them opened, and dragging is off (`isFiltered`).
public struct RuleOutline: Equatable, Sendable {
    public var rows: [RuleOutlineRow]
    /// `onlyEnabled || !query.isEmpty`: the table does not accept drags then.
    public var isFiltered: Bool

    public init(tree: RuleTree, expanded: Set<UUID>, onlyEnabled: Bool, query: String, searchFields: (Rule) -> [String]) {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = onlyEnabled || !needle.isEmpty
        isFiltered = filtered

        func ruleShown(_ rule: Rule) -> Bool {
            if onlyEnabled, !rule.enabled { return false }
            if needle.isEmpty { return true }
            return searchFields(rule).contains { $0.localizedCaseInsensitiveContains(needle) }
        }
        let groupsByID = Dictionary(tree.groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // A group is shown when something under it is, or (query only) its own name matches.
        var shown: [UUID: Bool] = [:]
        func groupShown(_ id: UUID, steps: Int = 0) -> Bool {
            if let known = shown[id] { return known }
            guard steps <= tree.groups.count, let group = groupsByID[id] else { return false }
            var result = false
            if !filtered {
                result = true
            } else {
                if !needle.isEmpty, group.name.localizedCaseInsensitiveContains(needle), !onlyEnabled || group.enabled {
                    result = true
                }
                if tree.rules.contains(where: { $0.groupID == id && ruleShown($0) }) { result = true }
                if tree.groups.contains(where: { $0.parentID == id && groupShown($0.id, steps: steps + 1) }) { result = true }
            }
            shown[id] = result
            return result
        }

        var rows: [RuleOutlineRow] = []
        var visited = Set<UUID>()
        func walk(_ parent: UUID?, depth: Int) {
            for id in tree.siblings(ofParent: parent) {
                guard visited.insert(id).inserted else { continue }
                if let group = groupsByID[id] {
                    guard groupShown(id) else { continue }
                    let counts = tree.subtreeCounts(of: id)
                    rows.append(RuleOutlineRow(item: .group(group), depth: depth, parentID: parent, isExpandable: true, counts: counts))
                    if filtered || expanded.contains(id) { walk(id, depth: depth + 1) }
                } else if let rule = tree.rules.first(where: { $0.id == id }), ruleShown(rule) {
                    rows.append(RuleOutlineRow(item: .rule(rule), depth: depth, parentID: parent, isExpandable: false, counts: nil))
                }
            }
        }
        walk(nil, depth: 0)
        self.rows = rows
    }

    public static func == (lhs: RuleOutline, rhs: RuleOutline) -> Bool {
        lhs.rows == rhs.rows && lhs.isFiltered == rhs.isFiltered
    }
}
