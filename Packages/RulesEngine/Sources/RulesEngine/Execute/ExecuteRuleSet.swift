import Foundation

/// Which rules an Execute run applies (D4).
public enum ExecuteRuleScope: Sendable, Equatable {
    /// The published snapshot as it is: disabled rules and disabled groups stay off.
    case allEnabled
    /// The chosen rules and every rule below a chosen group, whether or not they or their groups are on.
    case items(Set<UUID>)
}

public enum ExecuteRuleSet {
    /// The snapshot Execute runs (D4). `.allEnabled` returns `snapshot` unchanged. For `.items` every
    /// group is on and a rule is on exactly when it was chosen or sits below a chosen group, so the
    /// evaluation order is the chosen rules in their usual list order. Revision and everything else stay.
    public static func snapshot(from snapshot: RuleSnapshot, scope: ExecuteRuleScope) -> RuleSnapshot {
        guard case .items(let chosen) = scope else { return snapshot }
        var derived = snapshot
        let parents = Dictionary(snapshot.groups.map { ($0.id, $0.parentID) }, uniquingKeysWith: { first, _ in first })
        derived.groups = snapshot.groups.map { group in
            var on = group
            on.enabled = true
            return on
        }
        derived.rules = snapshot.rules.map { rule in
            var selected = rule
            selected.enabled = chosen.contains(rule.id) || isBelowChosen(rule.groupID, chosen: chosen, parents: parents)
            return selected
        }
        return derived
    }

    /// How many rules the scope will run.
    public static func ruleCount(in snapshot: RuleSnapshot, scope: ExecuteRuleScope) -> Int {
        self.snapshot(from: snapshot, scope: scope).evaluationOrder.count
    }

    private static func isBelowChosen(_ start: UUID?, chosen: Set<UUID>, parents: [UUID: UUID?]) -> Bool {
        var current = start
        var seen = Set<UUID>()
        while let id = current, seen.insert(id).inserted {
            if chosen.contains(id) { return true }
            current = parents[id] ?? nil
        }
        return false
    }
}
