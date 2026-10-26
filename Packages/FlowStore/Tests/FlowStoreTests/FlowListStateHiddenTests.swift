import Foundation
import Testing

@testable import FlowStore

private func makeFlow(_ id: Int, host: String = "a.test", client: String? = nil, hidden: Bool = false) -> Flow {
    var f = Flow(id: id, scheme: "http", method: "GET", host: host, port: 80, path: "/\(id)")
    if let client { f.client = ClientApp(pid: 100, name: client) }
    f.isHidden = hidden
    return f
}

private func upsert(_ flows: Flow...) -> FlowChange {
    FlowChange(cleared: false, upserted: flows)
}

private func counts(_ groups: [GroupCount]) -> [String: Int] {
    Dictionary(uniqueKeysWithValues: groups.map { ($0.name, $0.count) })
}

@Suite struct FlowListStateHiddenTests {
    @Test func hiddenFlowIsNotVisibleEvenWithADefaultFilter() {
        var state = FlowListState()
        state.apply(upsert(makeFlow(1), makeFlow(2), makeFlow(3)))
        state.apply(upsert(makeFlow(2, hidden: true)))
        #expect(state.visible.map(\.id) == [1, 3])
        #expect(state.collection.flow(id: 2) != nil)
        #expect(state.hiddenCount == 1)
    }

    @Test func hidingAFlowMovesTheSidebarTallies() {
        var state = FlowListState()
        state.apply(upsert(
            makeFlow(1, host: "a.test", client: "curl"), makeFlow(2, host: "a.test", client: "curl"),
            makeFlow(3, host: "b.test", client: "curl")))
        state.apply(upsert(makeFlow(2, host: "a.test", client: "curl", hidden: true)))
        #expect(state.hostGroups == [GroupCount(name: "a.test", count: 1), GroupCount(name: "b.test", count: 1)])
        #expect(state.appGroups == [GroupCount(name: "curl", count: 2)])
        #expect(state.hostGroups(ofApp: "curl") == [GroupCount(name: "a.test", count: 1), GroupCount(name: "b.test", count: 1)])
    }

    @Test func evictingAHiddenFlowDoesNotChangeTheTallies() {
        var state = FlowListState()
        state.apply(upsert(makeFlow(1), makeFlow(2), makeFlow(3, host: "b.test")))
        state.apply(upsert(makeFlow(2, hidden: true)))
        let hosts = state.hostGroups
        let apps = state.appGroups
        state.apply(FlowChange(cleared: false, removed: [2], upserted: []))
        #expect(state.hostGroups == hosts)
        #expect(state.appGroups == apps)
        #expect(state.hiddenCount == 0)
        #expect(state.collection.flow(id: 2) == nil)
        state.apply(FlowChange(cleared: false, removed: [1], upserted: []))
        #expect(state.hostGroups == [GroupCount(name: "b.test", count: 1)])
    }

    @Test func hiddenFlowDoesNotCreateAGroup() {
        var state = FlowListState()
        state.apply(upsert(makeFlow(1), makeFlow(3, host: "c.test", hidden: true)))
        #expect(state.hostGroups == [GroupCount(name: "a.test", count: 1)])
        var filter = FlowFilter()
        filter.scope = .host("c.test")
        state.setFilter(filter)
        #expect(state.filter.scope == .host("c.test"))
        state.apply(upsert(makeFlow(4)))
        #expect(state.filter.scope == .all)
    }

    @Test func unhidingAFlowAddsItBackInIdOrder() {
        var state = FlowListState()
        state.apply(upsert(makeFlow(1), makeFlow(2), makeFlow(3)))
        state.apply(upsert(makeFlow(2, hidden: true)))
        state.apply(upsert(makeFlow(2)))
        #expect(state.visible.map(\.id) == [1, 2, 3])
        #expect(counts(state.hostGroups) == ["a.test": 3])
        #expect(state.hiddenCount == 0)
    }

    @Test func hidingTheLastFlowOfAHostResetsAHostScope() {
        var state = FlowListState()
        state.apply(upsert(makeFlow(1), makeFlow(2, host: "b.test")))
        var filter = FlowFilter()
        filter.scope = .host("b.test")
        state.setFilter(filter)
        #expect(state.visible.map(\.id) == [2])
        state.apply(upsert(makeFlow(2, host: "b.test", hidden: true)))
        #expect(state.filter.scope == .all)
        #expect(state.visible.map(\.id) == [1])
    }

    @Test func includeHiddenShowsHiddenFlowsButTalliesStillSkipThem() {
        var state = FlowListState()
        state.apply(upsert(makeFlow(1), makeFlow(2, hidden: true)))
        var filter = FlowFilter()
        filter.includeHidden = true
        state.setFilter(filter)
        #expect(state.visible.map(\.id) == [1, 2])
        #expect(counts(state.hostGroups) == ["a.test": 1])
        state.apply(upsert(makeFlow(3, hidden: true)))
        #expect(state.visible.map(\.id) == [1, 2, 3])
        #expect(state.hiddenCount == 2)
        filter.includeHidden = false
        state.setFilter(filter)
        #expect(state.visible.map(\.id) == [1])
    }

    @Test func clearedChangeResetsTheHiddenCount() {
        var state = FlowListState()
        state.apply(upsert(makeFlow(1), makeFlow(2, hidden: true)))
        #expect(state.hiddenCount == 1)
        state.apply(FlowChange(cleared: true, upserted: []))
        #expect(state.hiddenCount == 0)
        #expect(state.visible.isEmpty)
        state.apply(upsert(makeFlow(5)))
        #expect(state.visible.map(\.id) == [5])
    }

    @Test func firstHiddenFlowAmongManyKeepsVisibleConsistent() {
        var state = FlowListState()
        state.apply(FlowChange(cleared: false, upserted: (1...1000).map { makeFlow($0) }))
        state.apply(upsert(makeFlow(500, hidden: true)))
        let ids = state.visible.map(\.id)
        #expect(ids.count == 999)
        #expect(!ids.contains(500))
        #expect(zip(ids, ids.dropFirst()).allSatisfy { $0 < $1 })
        #expect(state.hiddenCount == 1)
    }

    @Test func filterChangeAfterHidingStillExcludesHidden() {
        var state = FlowListState()
        state.apply(upsert(makeFlow(1), makeFlow(2), makeFlow(3)))
        state.apply(upsert(makeFlow(2, hidden: true)))
        var filter = FlowFilter()
        filter.methods = ["GET"]
        state.setFilter(filter)
        #expect(state.visible.map(\.id) == [1, 3])
        state.apply(upsert(makeFlow(4)))
        #expect(state.visible.map(\.id) == [1, 3, 4])
    }
}
