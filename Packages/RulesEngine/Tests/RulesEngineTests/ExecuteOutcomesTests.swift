import FlowStore
import Foundation
import Testing

@testable import RulesEngine

@Suite("ExecuteOutcomes")
struct ExecuteOutcomesTests {
    private func rule(_ actions: RuleAction...) -> Rule { Rule(name: "r", actions: actions) }
    private func outcome(_ rule: Rule, _ code: RuleOutcomeCode, _ index: Int? = nil) -> RuleOutcome {
        RuleOutcome(ruleID: rule.id, code: code, actionIndex: index)
    }
    private func summary(_ rules: [Rule], _ outcomes: [RuleOutcome], total: Int? = nil, omitted: Int = 0) -> RuleMatchSummary {
        RuleMatchSummary(
            revision: 5, ruleIDs: rules.map(\.id), total: total ?? rules.count, omitted: omitted, outcomes: outcomes)
    }

    @Test func relabelsTheFiveKindsOnlyWhenApplied() {
        let kinds: [ActionKind] = [
            .closeConnection(.reset), .returnConnectTunnel, .noDecrypt,
            .breakpoint(direction: .request, mode: .headers), .delay(milliseconds: 10),
        ]
        let single = kinds.map { Rule(name: "s", actions: [RuleAction($0)]) }
        let multi = Rule(name: "m", actions: [RuleAction(.hide)] + kinds.map { RuleAction($0) })
        let rules = single + [multi]
        let outcomes =
            single.map { outcome($0, .applied) } + kinds.indices.map { outcome(multi, .applied, $0 + 1) }
            + [outcome(multi, .applied, 0)]
        let result = ExecuteOutcomes.relabelOffline(summary(rules, outcomes), rules: rules)
        #expect(result.notApplicable == 10)
        #expect(result.summary.outcomes.prefix(10).allSatisfy { $0.code == .notApplicableOffline })
        #expect(result.summary.outcomes.last == outcome(multi, .applied, 0))
        #expect(result.summary.outcomes.map(\.actionIndex) == outcomes.map(\.actionIndex))
        // The same kinds that did not apply are not relabelled.
        let notApplied = single.map { outcome($0, .skippedByTool) }
        let kept = ExecuteOutcomes.relabelOffline(summary(single, notApplied), rules: rules)
        #expect(kept.summary.outcomes == notApplied)
        #expect(kept.notApplicable == 0)
    }

    @Test func rejectedAndFinalStopOutcomesAreKept() {
        let r = rule(RuleAction(.closeConnection(.reset), isFinal: true))
        let other = rule(RuleAction(.hide))
        let outcomes = [outcome(r, .rejected), outcome(other, .applied), outcome(r, .unsupportedUpgradeAction)]
        let result = ExecuteOutcomes.relabelOffline(summary([r, other], outcomes), rules: [r, other])
        #expect(result.summary.outcomes == outcomes)
        #expect(result.notApplicable == 0)
        // A final close that applied is still one outcome, now not applicable.
        let applied = ExecuteOutcomes.relabelOffline(summary([r], [outcome(r, .applied)]), rules: [r])
        #expect(applied.summary.outcomes == [outcome(r, .notApplicableOffline)])
    }

    @Test func delayCappedIsDropped() {
        let r = rule(RuleAction(.delay(milliseconds: 99_999)))
        let result = ExecuteOutcomes.relabelOffline(
            summary([r], [outcome(r, .applied), outcome(r, .delayCapped)]), rules: [r])
        #expect(result.summary.outcomes == [outcome(r, .notApplicableOffline)])
        #expect(result.notApplicable == 1)
        #expect(result.summary.ruleIDs == [r.id])
        #expect(result.summary.total == 1)
    }

    @Test func notApplicableCountIsReturned() {
        let a = rule(RuleAction(.noDecrypt)), b = rule(RuleAction(.hide))
        let result = ExecuteOutcomes.relabelOffline(
            summary([a, b], [outcome(a, .applied), outcome(b, .applied)], total: 2, omitted: 3), rules: [a, b])
        #expect(result.notApplicable == 1)
        #expect(result.summary.revision == 5)
        #expect(result.summary.omitted == 3)
        #expect(result.summary.total == 2)
    }

    @Test func mergeListsEachRuleOnceInFirstSeenOrder() {
        let a = rule(RuleAction(.hide)), b = rule(RuleAction(.hide)), c = rule(RuleAction(.hide))
        let p1 = summary([a, b], [outcome(a, .applied), outcome(b, .applied)])
        let p2 = summary([b, c], [outcome(b, .editNoMatch), outcome(c, .applied)])
        let p3 = summary([a], [outcome(a, .applied, 1)])
        let merged = ExecuteOutcomes.merge([p1, nil, p2, p3], revision: 9)
        #expect(merged?.revision == 9)
        #expect(merged?.ruleIDs == [a.id, b.id, c.id])
        #expect(merged?.total == 3)
        #expect(
            merged?.outcomes == [
                outcome(a, .applied), outcome(b, .applied), outcome(b, .editNoMatch), outcome(c, .applied),
                outcome(a, .applied, 1),
            ])
    }

    @Test func mergeOfNothingIsNil() {
        #expect(ExecuteOutcomes.merge([], revision: 1) == nil)
        #expect(ExecuteOutcomes.merge([nil, nil, nil], revision: 1) == nil)
        #expect(ExecuteOutcomes.merge([RuleMatchSummary(revision: 1, ruleIDs: [], total: 0)], revision: 1) == nil)
    }

    @Test func notApplicableOfflineCodeIsAValidOutcomeCode() {
        let raw = RuleOutcomeCode.notApplicableOffline.rawValue
        #expect(raw == "notApplicableOffline")
        #expect(raw.allSatisfy { $0.isASCII })
        #expect(raw.unicodeScalars.count <= 64)
        #expect(RuleOutcomeCode(rawValue: raw) == .notApplicableOffline)
    }
}
