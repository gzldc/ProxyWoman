import Foundation
import RulesEngine

/// The rule list as a tree (rules 2.0 D5-D9): groups and rules share one number space per parent.
/// Pure value logic; the outline view only translates drag events into these calls.
public struct RuleTree: Equatable, Sendable {
    public var groups: [RuleGroup]
    public var rules: [Rule]

    public init(groups: [RuleGroup], rules: [Rule]) {
        self.groups = groups
        self.rules = rules
    }

    public enum MoveVerdict: Equatable, Sendable {
        case allowed
        /// A group would land inside itself or one of its own descendants.
        case intoSelf
        /// A moved subtree would go beyond `limits.groupDepth` levels.
        case tooDeep
        /// Reserved: the result would hold more than `limits.ruleCount` rules. A move never adds rules, so `canMove` does not return it today.
        case tooManyRules
        /// An id (or the target group) is not in the tree.
        case unknownTarget
    }

    /// A child of some parent: rules and groups side by side.
    private enum Child: Equatable {
        case rule(UUID)
        case group(UUID)

        var id: UUID {
            switch self {
            case .rule(let id), .group(let id): id
            }
        }
    }

    // MARK: Reading

    /// The children of `parent` in stored order: by `order`, a rule before a group on a tie, then array position.
    private func children(of parent: UUID?) -> [Child] {
        struct Entry {
            var order: Int
            var isGroup: Bool
            var position: Int
            var child: Child
        }
        var entries: [Entry] = []
        for (position, rule) in rules.enumerated() where rule.groupID == parent {
            entries.append(Entry(order: rule.order, isGroup: false, position: position, child: .rule(rule.id)))
        }
        for (position, group) in groups.enumerated() where group.parentID == parent {
            entries.append(Entry(order: group.order, isGroup: true, position: position, child: .group(group.id)))
        }
        entries.sort {
            if $0.order != $1.order { return $0.order < $1.order }
            if $0.isGroup != $1.isGroup { return !$0.isGroup }
            return $0.position < $1.position
        }
        return entries.map(\.child)
    }

    public func siblings(ofParent parent: UUID?) -> [UUID] {
        children(of: parent).map(\.id)
    }

    private func group(_ id: UUID) -> RuleGroup? { groups.first { $0.id == id } }

    /// The parent of a rule or group; `nil` inside `.some(nil)` is the root. The outer `nil` means the id is unknown.
    private func parent(of id: UUID) -> UUID?? {
        if let group = group(id) { return .some(group.parentID) }
        if let rule = rules.first(where: { $0.id == id }) { return .some(rule.groupID) }
        return nil
    }

    private func isGroup(_ id: UUID) -> Bool { groups.contains { $0.id == id } }

    /// Depth of a group, a root child being 1; 0 when unknown.
    public func depth(ofGroup id: UUID) -> Int {
        var depth = 0
        var next: UUID? = id
        var steps = 0
        while let current = next, let found = group(current) {
            depth += 1
            next = found.parentID
            steps += 1
            if steps > groups.count { break }   // a parent cycle in bad data
        }
        return depth
    }

    /// Whether `ancestor` is `id` itself or one of its ancestors.
    private func isSelfOrAncestor(_ ancestor: UUID, of id: UUID?) -> Bool {
        var next = id
        var steps = 0
        while let current = next {
            if current == ancestor { return true }
            next = group(current)?.parentID
            steps += 1
            if steps > groups.count { break }
        }
        return false
    }

    /// Levels in the subtree under (and including) a group: a group without subgroups is 1.
    private func height(ofGroup id: UUID, steps: Int = 0) -> Int {
        guard steps <= groups.count else { return 1 }
        let below = groups.filter { $0.parentID == id }.map { height(ofGroup: $0.id, steps: steps + 1) }
        return 1 + (below.max() ?? 0)
    }

    /// Every rule and group id at or under a group, the group included.
    private func subtree(ofGroup id: UUID) -> (rules: [UUID], groups: [UUID]) {
        var ruleIDs: [UUID] = []
        var groupIDs: [UUID] = []
        var queue = [id]
        var seen = Set<UUID>()
        while let current = queue.popLast() {
            guard seen.insert(current).inserted, group(current) != nil else { continue }
            groupIDs.append(current)
            ruleIDs += rules.filter { $0.groupID == current }.map(\.id)
            queue += groups.filter { $0.parentID == current }.map(\.id)
        }
        return (ruleIDs, groupIDs)
    }

    /// The ids of every rule in the group's subtree.
    public func ruleIDs(inGroup id: UUID) -> [UUID] { subtree(ofGroup: id).rules }

    /// Enabled over total rules in the subtree; ancestor switches are not looked at (D8).
    public func subtreeCounts(of groupID: UUID) -> (enabled: Int, total: Int) {
        let ids = Set(subtree(ofGroup: groupID).rules)
        let found = rules.filter { ids.contains($0.id) }
        return (found.filter(\.enabled).count, found.count)
    }

    /// The tree with its rules array in sibling order: each parent's rules keep the array slots they already
    /// hold, filled in the order the parent shows them. Nothing else changes, so a tree whose array already
    /// follows the stored numbers comes back equal, and the old position-numbering of a save renumbers nothing.
    public func normalized() -> RuleTree {
        var copy = self
        var slots: [UUID?: [Int]] = [:]
        for (index, rule) in rules.enumerated() { slots[rule.groupID, default: []].append(index) }
        let byID = Dictionary(rules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (parent, indices) in slots {
            let sequence = children(of: parent).compactMap { child -> Rule? in
                if case .rule(let id) = child { return byID[id] }
                return nil
            }
            guard sequence.count == indices.count else { continue }
            for (index, rule) in zip(indices, sequence) { copy.rules[index] = rule }
        }
        return copy
    }

    /// Ids in display order (depth first), used to put a multi-selection down in tree order.
    private func displayOrder() -> [UUID] {
        var result: [UUID] = []
        var seen = Set<UUID>()
        func walk(_ parent: UUID?) {
            for child in children(of: parent) {
                guard seen.insert(child.id).inserted else { continue }
                result.append(child.id)
                if case .group(let id) = child { walk(id) }
            }
        }
        walk(nil)
        return result
    }

    /// The ids that actually move: known, once each, and not below another selected group, in tree order.
    private func effectiveSelection(_ ids: [UUID]) -> [UUID] {
        let selected = Set(ids)
        let position = Dictionary(displayOrder().enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return selected.filter { id in
            guard position[id] != nil, let parentID = parent(of: id) else { return false }
            return !isSelfOrAncestor(in: selected, startingAt: parentID)
        }.sorted { position[$0]! < position[$1]! }
    }

    private func isSelfOrAncestor(in selected: Set<UUID>, startingAt start: UUID?) -> Bool {
        var next = start
        var steps = 0
        while let current = next {
            if selected.contains(current) { return true }
            next = group(current)?.parentID
            steps += 1
            if steps > groups.count { break }
        }
        return false
    }

    // MARK: Moving

    public func canMove(_ ids: [UUID], toParent parent: UUID?, at index: Int, limits: RulesLimits) -> MoveVerdict {
        guard !ids.isEmpty, ids.allSatisfy({ self.parent(of: $0) != nil }) else { return .unknownTarget }
        if let parent, group(parent) == nil { return .unknownTarget }
        let moving = effectiveSelection(ids)
        let base = parent.map { depth(ofGroup: $0) } ?? 0
        for id in moving where isGroup(id) {
            if isSelfOrAncestor(id, of: parent) { return .intoSelf }
        }
        for id in moving where isGroup(id) {
            if base + height(ofGroup: id) > limits.groupDepth { return .tooDeep }
        }
        return .allowed
    }

    @discardableResult
    public mutating func move(_ ids: [UUID], toParent parent: UUID?, at index: Int, limits: RulesLimits) -> MoveVerdict {
        let verdict = canMove(ids, toParent: parent, at: index, limits: limits)
        guard verdict == .allowed else { return verdict }
        let moving = effectiveSelection(ids)
        let movingSet = Set(moving)
        var affected: [UUID?] = [parent]
        for id in moving { if let old = self.parent(of: id) { affected.append(old) } }

        var target = children(of: parent).filter { !movingSet.contains($0.id) }
        let at = min(max(index, 0), target.count)
        let moved: [Child] = moving.map { isGroup($0) ? .group($0) : .rule($0) }
        target.insert(contentsOf: moved, at: at)
        for child in moved {
            switch child {
            case .rule(let id): if let i = rules.firstIndex(where: { $0.id == id }) { rules[i].groupID = parent }
            case .group(let id): if let i = groups.firstIndex(where: { $0.id == id }) { groups[i].parentID = parent }
            }
        }
        var done = Set<UUID?>()
        for old in affected where done.insert(old).inserted {
            renumber(old, using: old == parent ? target : children(of: old))
        }
        return .allowed
    }

    /// Gives the given children of `parent` the order numbers `0..<n`.
    private mutating func renumber(_ parent: UUID?, using sequence: [Child]) {
        for (number, child) in sequence.enumerated() {
            switch child {
            case .rule(let id): if let i = rules.firstIndex(where: { $0.id == id }) { rules[i].order = number }
            case .group(let id): if let i = groups.firstIndex(where: { $0.id == id }) { groups[i].order = number }
            }
        }
    }

    private mutating func renumber(_ parent: UUID?) { renumber(parent, using: children(of: parent)) }

    @discardableResult
    public mutating func moveStep(_ id: UUID, by delta: Int) -> Bool {
        guard delta != 0, let outer = parent(of: id) else { return false }
        let parentID = outer
        var sequence = children(of: parentID)
        guard let index = sequence.firstIndex(where: { $0.id == id }) else { return false }
        let destination = index + delta
        guard sequence.indices.contains(destination) else { return false }
        let child = sequence.remove(at: index)
        sequence.insert(child, at: destination)
        renumber(parentID, using: sequence)
        return true
    }

    // MARK: Adding

    public mutating func insertRule(_ rule: Rule, inParent parent: UUID?, at index: Int) {
        var rule = rule
        rule.groupID = parent
        var sequence = children(of: parent)
        rules.append(rule)
        let at = min(max(index, 0), sequence.count)
        sequence.insert(.rule(rule.id), at: at)
        renumber(parent, using: sequence)
    }

    /// Adds an empty group; `nil` when the parent is unknown or the group would go beyond `limits.groupDepth`.
    /// The rule cap constrains rules only, so a group may be added to a tree that is at the cap.
    public mutating func addGroup(name: String, inParent parent: UUID?, at index: Int, limits: RulesLimits) -> UUID? {
        if let parent, group(parent) == nil { return nil }
        let base = parent.map { depth(ofGroup: $0) } ?? 0
        guard base + 1 <= limits.groupDepth else { return nil }
        let new = RuleGroup(name: name, enabled: true, parentID: parent, order: 0)
        var sequence = children(of: parent)
        groups.append(new)
        sequence.insert(.group(new.id), at: min(max(index, 0), sequence.count))
        renumber(parent, using: sequence)
        return new.id
    }

    // MARK: Duplicating

    /// A copy right after the original. A group is copied with its whole subtree under fresh ids. `nil`
    /// when the id is unknown or the copy would take the tree past `limits.ruleCount` rules.
    public func duplicating(_ id: UUID, limits: RulesLimits) -> (tree: RuleTree, newID: UUID)? {
        guard let outer = parent(of: id) else { return nil }
        var copy = self
        let parentID = outer
        let newID: UUID
        if let original = rules.first(where: { $0.id == id }) {
            guard rules.count + 1 <= limits.ruleCount else { return nil }
            var duplicate = original
            duplicate.id = UUID()
            newID = duplicate.id
            copy.rules.append(duplicate)
        } else if let original = group(id) {
            let inside = subtree(ofGroup: id)
            guard rules.count + inside.rules.count <= limits.ruleCount else { return nil }
            var mapping: [UUID: UUID] = [:]
            for old in inside.groups { mapping[old] = UUID() }
            for old in inside.groups {
                guard var duplicate = group(old) else { continue }
                duplicate.id = mapping[old]!
                if old != id, let parent = duplicate.parentID { duplicate.parentID = mapping[parent] }
                copy.groups.append(duplicate)
            }
            for ruleID in inside.rules {
                guard var duplicate = rules.first(where: { $0.id == ruleID }) else { continue }
                duplicate.id = UUID()
                duplicate.groupID = duplicate.groupID.flatMap { mapping[$0] }
                copy.rules.append(duplicate)
            }
            newID = mapping[original.id]!
        } else {
            return nil
        }
        var sequence = children(of: parentID)
        let at = (sequence.firstIndex { $0.id == id } ?? sequence.count - 1) + 1
        sequence.insert(isGroup(id) ? .group(newID) : .rule(newID), at: at)
        copy.renumber(parentID, using: sequence)
        return (copy, newID)
    }

    // MARK: Removing

    /// Removes the items; a group takes its subtree. Children of a removed ancestor are counted once.
    public func removing(_ ids: [UUID]) -> (tree: RuleTree, removedRules: Int, removedGroups: Int) {
        let roots = effectiveSelection(ids)
        var ruleIDs = Set<UUID>()
        var groupIDs = Set<UUID>()
        var affected: [UUID?] = []
        for id in roots {
            if let outer = parent(of: id) { affected.append(outer) }
            if isGroup(id) {
                let inside = subtree(ofGroup: id)
                ruleIDs.formUnion(inside.rules)
                groupIDs.formUnion(inside.groups)
            } else {
                ruleIDs.insert(id)
            }
        }
        var result = self
        result.rules.removeAll { ruleIDs.contains($0.id) }
        result.groups.removeAll { groupIDs.contains($0.id) }
        var done = Set<UUID?>()
        for parent in affected where done.insert(parent).inserted {
            if let parent, groupIDs.contains(parent) { continue }
            result.renumber(parent)
        }
        return (result, ruleIDs.count, groupIDs.count)
    }
}
