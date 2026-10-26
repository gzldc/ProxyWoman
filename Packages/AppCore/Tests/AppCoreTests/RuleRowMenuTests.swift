import Foundation
import RulesEngine
import Testing

@testable import AppCore

@Suite(.productionChinese) struct RuleRowMenuTests {
    private func rule(_ name: String, group: UUID? = nil, order: Int) -> Rule {
        Rule(name: name, groupID: group, order: order, actions: [RuleAction(.hide)])
    }

    private func items(_ entries: [RuleRowMenuEntry]) -> [RuleRowMenuItem] { entries.map(\.item) }

    private func enabled(_ entries: [RuleRowMenuEntry]) -> [RuleRowMenuItem] { entries.filter(\.isEnabled).map(\.item) }

    @Test func ruleMenuOrder() {
        let a = rule("a", order: 0), b = rule("b", order: 1)
        let tree = RuleTree(groups: [], rules: [a, b])
        #expect(
            items(RuleRowMenu.entries(for: a.id, tree: tree, canMutate: true, isReadOnly: false))
                == [.moveUp, .moveDown, .addGroup, .addRule, .duplicate, .editNote, .delete])
    }

    @Test func groupMenuHasRenameNotNote() {
        let g = RuleGroup(name: "G", order: 0)
        let list = items(RuleRowMenu.entries(for: g.id, tree: RuleTree(groups: [g], rules: []), canMutate: true, isReadOnly: false))
        #expect(list == [.moveUp, .moveDown, .addGroup, .addRule, .duplicate, .rename, .delete])
    }

    @Test func firstItemCannotMoveUp() {
        let a = rule("a", order: 0), b = rule("b", order: 1)
        let on = enabled(RuleRowMenu.entries(for: a.id, tree: RuleTree(groups: [], rules: [a, b]), canMutate: true, isReadOnly: false))
        #expect(!on.contains(.moveUp) && on.contains(.moveDown))
    }

    @Test func lastItemCannotMoveDown() {
        let a = rule("a", order: 0), b = rule("b", order: 1)
        let on = enabled(RuleRowMenu.entries(for: b.id, tree: RuleTree(groups: [], rules: [a, b]), canMutate: true, isReadOnly: false))
        #expect(on.contains(.moveUp) && !on.contains(.moveDown))
    }

    @Test func cannotMutateDisablesEverything() {
        let a = rule("a", order: 0), b = rule("b", order: 1)
        #expect(enabled(RuleRowMenu.entries(for: a.id, tree: RuleTree(groups: [], rules: [a, b]), canMutate: false, isReadOnly: false)).isEmpty)
    }

    @Test func readOnlyRuleAllowsOnlyDuplicate() {
        let a = rule("a", order: 0), b = rule("b", order: 1)
        let on = enabled(RuleRowMenu.entries(for: a.id, tree: RuleTree(groups: [], rules: [a, b]), canMutate: true, isReadOnly: true))
        #expect(on == [.duplicate])
    }

    @Test func newItemParentOfRuleIsItsGroup() {
        let g = RuleGroup(name: "G", order: 0)
        let inside = rule("in", group: g.id, order: 0), outside = rule("out", order: 1)
        let tree = RuleTree(groups: [g], rules: [inside, outside])
        #expect(RuleRowMenu.newItemParent(for: inside.id, tree: tree) == g.id)
        #expect(RuleRowMenu.newItemParent(for: g.id, tree: tree) == g.id)
        #expect(RuleRowMenu.newItemParent(for: outside.id, tree: tree) == nil)
    }

    @Test func unknownIDHasNoEntriesAndNoParent() {
        let tree = RuleTree(groups: [], rules: [rule("a", order: 0)])
        #expect(RuleRowMenu.entries(for: UUID(), tree: tree, canMutate: true, isReadOnly: false) == [])
        #expect(RuleRowMenu.newItemParent(for: UUID(), tree: tree) == nil)
    }
}
