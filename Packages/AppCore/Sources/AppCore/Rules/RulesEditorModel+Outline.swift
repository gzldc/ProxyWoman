import Foundation
import RulesEngine

/// The group tree operations of the rules window (R5). Each one builds the next tree from the committed
/// `groups` / `rules`, checks its shape and saves both together through `commit`. A refused or failed save
/// leaves the local `rules` / `groups` as they were. Callers confirm destructive actions first.
extension RulesEditorModel {
    public var tree: RuleTree { RuleTree(groups: groups, rules: rules) }

    /// Saves `tree`'s groups and rules together (the same revision and conflict handling as every other save).
    @discardableResult public func apply(_ tree: RuleTree) async -> Bool {
        guard canMutate else { return false }
        let tree = tree.normalized()
        let snapshot = RuleSnapshot(revision: revision, groups: tree.groups, rules: tree.rules)
        do {
            try snapshot.validateStructure(limits: limits, enforcingRuleCount: tree.rules.count > max(limits.ruleCount, rules.count))
        } catch let failure as RuleValidationError {
            error = failure.code == .tooManyRules ? .configurationTooLarge : .invalidRule
            return false
        } catch {
            self.error = .invalidRule
            return false
        }
        return await commit(tree.rules, groups: tree.groups)
    }

    /// Adds an empty group at the top of `parent` (`nil` = root); the new id, or nil when refused (unknown parent,
    /// too deep, busy).
    @discardableResult public func addGroup(name: String, inParent parent: UUID?) async -> UUID? {
        guard canMutate else { return nil }
        var next = tree
        guard let id = next.addGroup(name: name, inParent: parent, at: 0, limits: limits) else {
            error = .invalidRule
            return nil
        }
        return await apply(next) ? id : nil
    }

    @discardableResult public func renameGroup(id: UUID, name: String) async -> Bool {
        var next = tree
        guard canMutate, let index = next.groups.firstIndex(where: { $0.id == id }) else { return false }
        next.groups[index].name = name
        return await apply(next)
    }

    @discardableResult public func setGroupEnabled(id: UUID, enabled: Bool) async -> Bool {
        var next = tree
        guard canMutate, let index = next.groups.firstIndex(where: { $0.id == id }) else { return false }
        next.groups[index].enabled = enabled
        return await apply(next)
    }

    @discardableResult public func moveItems(_ ids: [UUID], toParent: UUID?, at index: Int) async -> Bool {
        guard canMutate else { return false }
        var next = tree
        guard next.move(ids, toParent: toParent, at: index, limits: limits) == .allowed else { return false }
        return await apply(next)
    }

    @discardableResult public func moveItem(_ id: UUID, by delta: Int) async -> Bool {
        guard canMutate else { return false }
        var next = tree
        guard next.moveStep(id, by: delta) else { return false }
        return await apply(next)
    }

    /// A copy right after the original: a rule (all its actions) or a group with its whole subtree.
    @discardableResult public func duplicateItem(_ id: UUID) async -> Bool {
        guard canMutate else { return false }
        guard let copy = tree.duplicating(id, limits: limits) else {
            error = .configurationTooLarge
            return false
        }
        return await apply(copy.tree)
    }

    @discardableResult public func deleteItems(_ ids: [UUID]) async -> Bool {
        guard canMutate else { return false }
        let removal = tree.removing(ids)
        guard removal.removedRules + removal.removedGroups > 0 else { return false }
        return await apply(removal.tree)
    }

    /// Saves a new rule at the top of `parent` (D7). An id that already exists or an unknown parent is refused.
    @discardableResult public func commitNewRule(_ rule: Rule, inParent parent: UUID?) async -> Bool {
        guard canMutate, !refusesBreakpoint(rule) else { return false }
        guard !rules.contains(where: { $0.id == rule.id }), !groups.contains(where: { $0.id == rule.id }),
              parent == nil || groups.contains(where: { $0.id == parent })
        else {
            error = .invalidRule
            return false
        }
        var next = tree
        next.insertRule(rule, inParent: parent, at: 0)
        return await apply(next)
    }

    /// Saves an edited rule in place; when its group changed it goes to the top of the new group.
    @discardableResult public func commitEditedRule(_ rule: Rule) async -> Bool {
        guard canMutate, let old = rules.first(where: { $0.id == rule.id }), !refusesBreakpoint(rule) else { return false }
        guard rule.groupID == nil || groups.contains(where: { $0.id == rule.groupID }) else {
            error = .invalidRule
            return false
        }
        var next = tree
        if old.groupID == rule.groupID {
            var kept = rule
            kept.order = old.order
            guard let index = next.rules.firstIndex(where: { $0.id == rule.id }) else { return false }
            next.rules[index] = kept
        } else {
            next = next.removing([rule.id]).tree
            next.insertRule(rule, inParent: rule.groupID, at: 0)
        }
        return await apply(next)
    }

    /// Sets (trimmed; empty clears) the note of a rule through the normal edit save; false for an unknown or read-only rule.
    @discardableResult public func setNote(ruleID: UUID, note: String) async -> Bool {
        guard var rule = rules.first(where: { $0.id == ruleID }), !isReadOnly(ruleID) else { return false }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        rule.note = trimmed.isEmpty ? nil : trimmed
        return await commitEditedRule(rule)
    }

    /// A rule that would be saved enabled with a breakpoint while no breakpoint window exists.
    private func refusesBreakpoint(_ rule: Rule) -> Bool {
        guard rule.enabled, rule.containsBreakpoint, !liveBreakpoints else { return false }
        error = .breakpointsUnavailable
        return true
    }

    // MARK: managed files (D17)

    /// Copies `source` into the managed asset store inside its security scope. The old draft is not touched; the
    /// caller owns the result and gives it back through `discardManagedAssets` if it is not saved.
    public func importManagedFile(from source: URL) async throws -> ManagedAsset {
        let client = self.client
        let name = source.lastPathComponent
        return try await fileAccess.withAccess(to: source) { try await client.importFile(source, name) }
    }

    /// The bookmark of a Map Local directory, made inside the directory's security scope.
    public func makeDirectoryBookmark(for url: URL) async throws -> Data {
        let bookmarking = directoryBookmarking
        return try await fileAccess.withAccess(to: url) { try bookmarking.make(url) }
    }

    public func discardManagedAssets(_ ids: Set<UUID>) async {
        guard !ids.isEmpty else { return }
        await client.discardImports(ids)
    }
}
