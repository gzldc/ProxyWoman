import Foundation
import RulesEngine
import Testing

@testable import AppCore

@MainActor @Suite(.productionChinese) struct RulesTabStateTests {
    @Test func pruneDropsUnknownIdsOnly() {
        let g = RuleGroup(name: "G", order: 0)
        let r = Rule(name: "r", groupID: g.id, order: 0, actions: [RuleAction(.hide)])
        let tree = RuleTree(groups: [g], rules: [r])
        let gone = UUID()
        let state = RulesTabState()
        state.selection = [g.id, r.id, gone]
        state.collapsed = [g.id, gone]
        state.pendingDeletion = [r.id, gone]
        state.noteEditing = gone
        state.renaming = g.id
        state.prune(to: tree)
        #expect(state.selection == [g.id, r.id])
        #expect(state.collapsed == [g.id])
        #expect(state.pendingDeletion == [r.id])
        #expect(state.noteEditing == nil)
        #expect(state.renaming == g.id)
    }

    @Test func pendingDeletionOfOnlyUnknownIdsIsCleared() {
        let state = RulesTabState()
        state.pendingDeletion = [UUID()]
        state.prune(to: RuleTree(groups: [], rules: []))
        #expect(state.pendingDeletion == nil)
    }
}
