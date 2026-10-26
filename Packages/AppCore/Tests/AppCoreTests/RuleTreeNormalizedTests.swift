import Foundation
import RulesEngine
import Testing

@testable import AppCore

@Suite(.productionChinese) struct RuleTreeNormalizedTests {
    private func rule(_ name: String, group: UUID? = nil, order: Int, id: UUID = UUID()) -> Rule {
        Rule(id: id, name: name, groupID: group, order: order, actions: [RuleAction(.hide)])
    }

    @Test func normalizedKeepsRuleBeforeGroupOnATie() {
        let group = RuleGroup(name: "g", order: 1)
        let a = rule("a", order: 1), b = rule("b", order: 0)
        // Stored out of order: b (0) shows first, then rule a before group g, both numbered 1.
        let tree = RuleTree(groups: [group], rules: [a, b]).normalized()
        #expect(tree.rules.map(\.name) == ["b", "a"])
        // The tie keeps the rule ahead of the group: the group's own rule is untouched and the order is stable.
        #expect(tree.normalized() == tree)
    }

    @Test func normalizedMovesOrphanRulesToTheRoot() {
        let missing = UUID()
        let orphan = rule("orphan", group: missing, order: 0)
        let root = rule("root", order: 1)
        let tree = RuleTree(groups: [], rules: [root, orphan]).normalized()
        // An orphan is not a child of the root or of any group: it is left as stored, and nothing is lost or duplicated.
        #expect(Set(tree.rules.map(\.id)) == [root.id, orphan.id])
        #expect(tree.rules.count == 2)
        #expect(tree.rules.first { $0.id == root.id }?.groupID == nil)
    }

    @Test func normalizedHandlesDuplicateIDsAndCycles() {
        let id = UUID()
        let one = rule("one", order: 0, id: id), two = rule("two", order: 1, id: id)
        let duplicates = RuleTree(groups: [], rules: [one, two]).normalized()
        #expect(duplicates.rules.count == 2)

        let a = UUID(), b = UUID()
        let cyclic = RuleTree(
            groups: [RuleGroup(id: a, name: "a", parentID: b, order: 0), RuleGroup(id: b, name: "b", parentID: a, order: 0)],
            rules: [rule("in a", group: a, order: 0), rule("in b", group: b, order: 0)])
        let result = cyclic.normalized()
        #expect(result.rules.count == 2)
        #expect(result.groups == cyclic.groups)
    }
}
