import FlowStore
import Foundation
import Testing

@testable import RulesEngine

@Suite("ExecuteRuleSet")
struct ExecuteRuleSetTests {
    private func rule(_ name: String, enabled: Bool = true, group: UUID? = nil, order: Int = 0) -> Rule {
        Rule(name: name, enabled: enabled, groupID: group, order: order, actions: [RuleAction(.hide)])
    }

    private func names(_ snapshot: RuleSnapshot) -> [String] { snapshot.evaluationOrder.map(\.name) }

    @Test func allEnabledKeepsDisabledRulesAndGroupsOff() {
        let off = RuleGroup(name: "off", enabled: false)
        let snap = RuleSnapshot(
            revision: 3, groups: [off],
            rules: [rule("on"), rule("disabled", enabled: false), rule("inOff", group: off.id)])
        let derived = ExecuteRuleSet.snapshot(from: snap, scope: .allEnabled)
        #expect(derived == snap)
        #expect(names(derived) == ["on"])
        #expect(ExecuteRuleSet.ruleCount(in: snap, scope: .allEnabled) == 1)
    }

    @Test func selectedRuleRunsWhenItIsDisabled() {
        let a = rule("a", enabled: false), b = rule("b")
        let derived = ExecuteRuleSet.snapshot(from: RuleSnapshot(revision: 1, rules: [a, b]), scope: .items([a.id]))
        #expect(names(derived) == ["a"])
    }

    @Test func selectedRuleRunsWhenItsGroupIsDisabled() {
        let off = RuleGroup(name: "off", enabled: false)
        let a = rule("a", group: off.id), b = rule("b", group: off.id)
        let derived = ExecuteRuleSet.snapshot(
            from: RuleSnapshot(revision: 1, groups: [off], rules: [a, b]), scope: .items([b.id]))
        #expect(names(derived) == ["b"])
        #expect(derived.groups.allSatisfy { $0.enabled })
    }

    @Test func selectedGroupRunsAllDescendantsInListOrder() {
        let top = RuleGroup(name: "top", enabled: false, order: 1)
        let child = RuleGroup(name: "child", enabled: false, parentID: top.id, order: 2)
        let outside = rule("outside", order: 0)
        let r1 = rule("r1", enabled: false, group: top.id, order: 1)
        let r2 = rule("r2", group: child.id, order: 0)
        let r3 = rule("r3", group: top.id, order: 3)
        let snap = RuleSnapshot(revision: 1, groups: [top, child], rules: [r3, outside, r2, r1])
        let derived = ExecuteRuleSet.snapshot(from: snap, scope: .items([top.id]))
        let all = ExecuteRuleSet.snapshot(
            from: snap, scope: .items([top.id, outside.id]))
        #expect(names(derived) == ["r1", "r2", "r3"])
        // The order is the subsequence of the full order.
        #expect(names(all) == ["outside", "r1", "r2", "r3"])
        #expect(ExecuteRuleSet.ruleCount(in: snap, scope: .items([top.id])) == 3)
    }

    @Test func unselectedRulesNeverRun() {
        let a = rule("a"), b = rule("b")
        let derived = ExecuteRuleSet.snapshot(from: RuleSnapshot(revision: 1, rules: [a, b]), scope: .items([]))
        #expect(names(derived).isEmpty)
        #expect(derived.rules.map(\.enabled) == [false, false])
        #expect(ExecuteRuleSet.ruleCount(in: RuleSnapshot(revision: 1, rules: [a, b]), scope: .items([UUID()])) == 0)
    }

    @Test func revisionAndRulesAreOtherwiseUntouched() {
        let g = RuleGroup(name: "g", enabled: false)
        let a = rule("a", enabled: false, group: g.id)
        let snap = RuleSnapshot(revision: 42, groups: [g], rules: [a], templatesInstalled: true)
        let derived = ExecuteRuleSet.snapshot(from: snap, scope: .items([a.id]))
        #expect(derived.revision == 42)
        #expect(derived.templatesInstalled)
        var restored = derived.rules[0]
        restored.enabled = false
        #expect(restored == a)
        #expect(derived.groups.map(\.id) == [g.id])
    }

    @Test func ruleCountMatchesTheEvaluationOrder() {
        let g = RuleGroup(name: "g")
        let snap = RuleSnapshot(revision: 1, groups: [g], rules: [rule("a", group: g.id), rule("b"), rule("c")])
        let scope = ExecuteRuleScope.items([g.id, snap.rules[2].id])
        #expect(ExecuteRuleSet.ruleCount(in: snap, scope: scope) == ExecuteRuleSet.snapshot(from: snap, scope: scope).evaluationOrder.count)
        #expect(ExecuteRuleSet.ruleCount(in: snap, scope: scope) == 2)
    }
}
