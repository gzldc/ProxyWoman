import FlowStore
import Foundation

extension RuleOutcomeCode {
    /// The action needs a live connection (close, connect tunnel, no decrypt, breakpoint, delay), so
    /// Execute did not perform it.
    public static let notApplicableOffline = RuleOutcomeCode(rawValue: "notApplicableOffline")!
}

public enum ExecuteOutcomes {
    /// D3: applied close / connect-tunnel / no-decrypt / breakpoint / delay become `notApplicableOffline`;
    /// `delayCapped` is dropped. Rejected and every other outcome stay as they are.
    public static func relabelOffline(
        _ summary: RuleMatchSummary, rules: [Rule]
    ) -> (summary: RuleMatchSummary, notApplicable: Int) {
        let rulesByID = Dictionary(rules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var relabelled = 0
        var outcomes: [RuleOutcome] = []
        for var outcome in summary.outcomes {
            if outcome.code == .delayCapped { continue }
            if outcome.code == .applied, let kind = action(of: outcome, rules: rulesByID), needsConnection(kind) {
                outcome.code = .notApplicableOffline
                relabelled += 1
            }
            outcomes.append(outcome)
        }
        var result = summary
        result.outcomes = outcomes
        return (result, relabelled)
    }

    /// P1 + P2 + P3, each rule listed once (where it first appeared), outcomes in the order they happened.
    /// Nil when no point left a record.
    public static func merge(_ summaries: [RuleMatchSummary?], revision: UInt64) -> RuleMatchSummary? {
        var merged: RuleMatchSummary?
        for case let next? in summaries where next.hasRecords {
            guard let first = merged else {
                merged = RuleMatchSummary(
                    revision: revision, ruleIDs: next.ruleIDs, total: next.total, omitted: next.omitted,
                    outcomes: next.outcomes)
                continue
            }
            let listed = Set(first.ruleIDs)
            let added = next.ruleIDs.filter { !listed.contains($0) }
            merged = RuleMatchSummary(
                revision: revision, ruleIDs: first.ruleIDs + added,
                total: first.total + next.total - (next.ruleIDs.count - added.count),
                omitted: first.omitted + next.omitted, outcomes: first.outcomes + next.outcomes)
        }
        return merged
    }

    private static func action(of outcome: RuleOutcome, rules: [UUID: Rule]) -> ActionKind? {
        guard let rule = rules[outcome.ruleID] else { return nil }
        let index = outcome.actionIndex ?? (rule.actions.count == 1 ? 0 : -1)
        return rule.actions.indices.contains(index) ? rule.actions[index].expandingMagicString().kind : nil
    }

    private static func needsConnection(_ kind: ActionKind) -> Bool {
        switch kind {
        case .closeConnection, .returnConnectTunnel, .noDecrypt, .breakpoint, .delay: true
        default: false
        }
    }
}
