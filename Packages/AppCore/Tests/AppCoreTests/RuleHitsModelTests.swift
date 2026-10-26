import Foundation
import os
import RulesEngine
import Testing

@testable import AppCore

private final class Store: Sendable {
    let state = OSAllocatedUnfairLock<[UUID: Int]>(initialState: [:])
}

@MainActor @Suite(.productionChinese) struct RuleHitsModelTests {
    private func make(_ store: Store) -> RuleHitsModel {
        RuleHitsModel(count: { id in store.state.withLock { $0[id] ?? 0 } }, reset: { id in store.state.withLock { $0[id] = 0 } })
    }

    @Test func refreshReadsCounts() {
        let store = Store(), a = UUID(), b = UUID()
        store.state.withLock { $0[a] = 3 }
        let model = make(store)
        model.refresh(ids: [a, b])
        #expect(model.counts == [a: 3, b: 0])
    }

    @Test func groupTotalSumsTheSubtree() {
        let store = Store()
        let g = RuleGroup(name: "G"), sub = RuleGroup(name: "S", parentID: g.id)
        let inG = Rule(name: "a", groupID: g.id, actions: [RuleAction(.hide)])
        let inSub = Rule(name: "b", groupID: sub.id, actions: [RuleAction(.hide)])
        let outside = Rule(name: "c", actions: [RuleAction(.hide)])
        store.state.withLock { $0[inG.id] = 2; $0[inSub.id] = 5; $0[outside.id] = 100 }
        let model = make(store)
        let tree = RuleTree(groups: [g, sub], rules: [inG, inSub, outside])
        model.refresh(ids: tree.rules.map(\.id))
        #expect(model.total(for: g.id, in: tree) == 7)
        #expect(model.total(for: sub.id, in: tree) == 5)
    }

    @Test func clearAllResetsEveryID() {
        let store = Store(), a = UUID(), b = UUID()
        store.state.withLock { $0[a] = 1; $0[b] = 2 }
        let model = make(store)
        model.refresh(ids: [a, b])
        model.clearAll(ids: [a, b])
        #expect(store.state.withLock { $0 } == [a: 0, b: 0])
        #expect(model.counts == [a: 0, b: 0])
    }

    @Test func unknownIDsCountAsZero() {
        let store = Store()
        let model = make(store)
        let g = RuleGroup(name: "G")
        #expect(model.total(for: g.id, in: RuleTree(groups: [g], rules: [])) == 0)
        #expect(model.total(for: UUID(), in: RuleTree(groups: [], rules: [])) == 0)
    }
}
