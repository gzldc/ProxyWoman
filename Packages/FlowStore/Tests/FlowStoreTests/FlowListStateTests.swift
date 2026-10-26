import Foundation
import Testing

@testable import FlowStore

private func makeFlow(
    _ id: Int, host: String = "a.com", method: String = "GET", status: Int? = nil, client: String? = nil
) -> Flow {
    var f = Flow(id: id, scheme: "http", method: method, host: host, port: 80, path: "/\(id)")
    f.statusCode = status
    if let client { f.client = ClientApp(pid: 100, name: client) }
    return f
}

private func upsert(_ flows: Flow..., cleared: Bool = false) -> FlowChange {
    FlowChange(cleared: cleared, upserted: flows)
}

/// The incremental results must equal a from-scratch computation over the collection.
private func expectConsistent(_ state: FlowListState, sourceLocation: SourceLocation = #_sourceLocation) {
    let flows = state.collection.flows
    #expect(state.visible == flows.filter(state.filter.matches), sourceLocation: sourceLocation)
    #expect(state.hostGroups == FlowGrouping.hosts(flows), sourceLocation: sourceLocation)
    #expect(state.appGroups == FlowGrouping.apps(flows), sourceLocation: sourceLocation)
    for app in state.appGroups.map(\.name) {
        #expect(state.hostGroups(ofApp: app) == FlowGrouping.hosts(flows, ofApp: app), sourceLocation: sourceLocation)
    }
}

@Suite struct FlowListStateTests {
    @Test func unfilteredVisibleIsTheCollection() {
        var state = FlowListState()
        state.apply(upsert(makeFlow(2), makeFlow(1)))
        #expect(state.visible.map(\.id) == [1, 2])
        expectConsistent(state)
    }

    @Test func activeFilterIsUpdatedIncrementally() {
        var state = FlowListState()
        var filter = FlowFilter()
        filter.statusClasses = [.clientError]
        state.setFilter(filter)

        state.apply(upsert(makeFlow(1), makeFlow(2, status: 404), makeFlow(3)))
        #expect(state.visible.map(\.id) == [2])
        expectConsistent(state)

        // 1 starts matching (inserted before 2), 2 stops matching (removed), 4 is new and matches.
        state.apply(upsert(makeFlow(1, status: 404), makeFlow(2, status: 200), makeFlow(4, status: 410)))
        #expect(state.visible.map(\.id) == [1, 4])
        expectConsistent(state)

        // An update that still matches replaces the stored flow.
        state.apply(upsert(makeFlow(4, method: "POST", status: 410)))
        #expect(state.visible.map(\.method) == ["GET", "POST"])
        expectConsistent(state)
    }

    @Test func changingTheFilterRefiltersEverything() {
        var state = FlowListState()
        state.apply(upsert(makeFlow(1, method: "GET"), makeFlow(2, method: "POST"), makeFlow(3, method: "POST")))
        var filter = FlowFilter()
        filter.methods = ["POST"]
        state.setFilter(filter)
        #expect(state.visible.map(\.id) == [2, 3])
        expectConsistent(state)

        state.setFilter(FlowFilter())
        #expect(state.visible.map(\.id) == [1, 2, 3])
        expectConsistent(state)
    }

    @Test func groupsFollowInsertsUpdatesAndBackfilledClients() {
        var state = FlowListState()
        state.apply(upsert(makeFlow(1, host: "b.com"), makeFlow(2, host: "a.com", client: "curl")))
        #expect(state.hostGroups == [GroupCount(name: "a.com", count: 1), GroupCount(name: "b.com", count: 1)])
        #expect(state.appGroups == [GroupCount(name: "curl", count: 1), GroupCount(name: "未知", count: 1)])

        // The client is looked up after the flow was created: "未知" disappears.
        state.apply(upsert(makeFlow(1, host: "b.com", client: "curl")))
        #expect(state.appGroups == [GroupCount(name: "curl", count: 2)])
        expectConsistent(state)

        state.apply(upsert(makeFlow(3, host: "a.com", client: "Safari")))
        #expect(state.hostGroups == [GroupCount(name: "a.com", count: 2), GroupCount(name: "b.com", count: 1)])
        expectConsistent(state)
    }

    @Test func clearResetsEverythingBeforeApplyingTheBatch() {
        var state = FlowListState()
        var filter = FlowFilter()
        filter.methods = ["GET"]
        state.setFilter(filter)
        state.apply(upsert(makeFlow(1, host: "a.com"), makeFlow(2, host: "b.com")))
        state.apply(upsert(makeFlow(5, host: "c.com"), cleared: true))
        #expect(state.collection.flows.map(\.id) == [5])
        #expect(state.visible.map(\.id) == [5])
        #expect(state.hostGroups == [GroupCount(name: "c.com", count: 1)])
        expectConsistent(state)
    }

    @Test func scopeFallsBackToAllWhenItsGroupDisappears() {
        var state = FlowListState()
        state.apply(upsert(makeFlow(1, host: "a.com"), makeFlow(2, host: "b.com", client: "curl")))

        var filter = FlowFilter()
        filter.scope = .app(FlowGrouping.unknownApp)
        state.setFilter(filter)
        #expect(state.visible.map(\.id) == [1])

        // The only unknown-app flow gets its client back-filled.
        state.apply(upsert(makeFlow(1, host: "a.com", client: "curl")))
        #expect(state.filter.scope == .all)
        #expect(state.visible.map(\.id) == [1, 2])
        expectConsistent(state)

        filter.scope = .host("a.com")
        state.setFilter(filter)
        state.apply(upsert(makeFlow(3, host: "c.com"), cleared: true))
        #expect(state.filter.scope == .all)
        #expect(state.visible.map(\.id) == [3])
        expectConsistent(state)
    }

    @Test func scopeIsKeptWhileItsGroupExists() {
        var state = FlowListState()
        state.apply(upsert(makeFlow(1, host: "a.com"), makeFlow(2, host: "b.com")))
        var filter = FlowFilter()
        filter.scope = .host("a.com")
        state.setFilter(filter)
        state.apply(upsert(makeFlow(3, host: "b.com"), makeFlow(4, host: "a.com")))
        #expect(state.filter.scope == .host("a.com"))
        #expect(state.visible.map(\.id) == [1, 4])
    }

    @Test func hostsPerAppFollowInsertsUpdatesRemovalsAndClear() {
        var state = FlowListState()
        state.apply(upsert(makeFlow(1, host: "b.com"), makeFlow(2, host: "a.com", client: "curl")))
        #expect(state.hostGroups(ofApp: "curl") == [GroupCount(name: "a.com", count: 1)])
        #expect(state.hostGroups(ofApp: FlowGrouping.unknownApp) == [GroupCount(name: "b.com", count: 1)])
        expectConsistent(state)

        // Back-filled client: the pair moves from "未知" to curl.
        state.apply(upsert(makeFlow(1, host: "b.com", client: "curl")))
        #expect(
            state.hostGroups(ofApp: "curl")
                == [GroupCount(name: "a.com", count: 1), GroupCount(name: "b.com", count: 1)])
        #expect(state.hostGroups(ofApp: FlowGrouping.unknownApp).isEmpty)
        expectConsistent(state)

        // An update that keeps app and host does not count twice.
        state.apply(upsert(makeFlow(2, host: "a.com", status: 200, client: "curl")))
        #expect(state.hostGroups(ofApp: "curl").first == GroupCount(name: "a.com", count: 1))

        state.apply(FlowChange(cleared: false, removed: [2], upserted: []))
        #expect(state.hostGroups(ofApp: "curl") == [GroupCount(name: "b.com", count: 1)])
        expectConsistent(state)

        state.apply(upsert(makeFlow(5, host: "c.com", client: "Safari"), cleared: true))
        #expect(state.hostGroups(ofApp: "curl").isEmpty)
        #expect(state.hostGroups(ofApp: "Safari") == [GroupCount(name: "c.com", count: 1)])
        expectConsistent(state)
    }

    @Test func appHostScopeIsKeptWhileThePairExistsAndFallsBackAfterwards() {
        var state = FlowListState()
        state.apply(upsert(makeFlow(1, host: "a.com", client: "curl"), makeFlow(2, host: "a.com", client: "Safari")))
        var filter = FlowFilter()
        filter.scope = .appHost(app: "curl", host: "a.com")
        state.setFilter(filter)
        #expect(state.visible.map(\.id) == [1])

        state.apply(upsert(makeFlow(3, host: "b.com", client: "curl")))
        #expect(state.filter.scope == .appHost(app: "curl", host: "a.com"))
        #expect(state.visible.map(\.id) == [1])

        // The app and the host both still exist, but no longer together.
        state.apply(FlowChange(cleared: false, removed: [1], upserted: []))
        #expect(state.filter.scope == .all)
        #expect(state.visible.map(\.id) == [2, 3])
        expectConsistent(state)
    }

    @Test func binarySearchByID() {
        let flows = [makeFlow(2), makeFlow(5), makeFlow(9)]
        #expect(flows.index(ofID: 5) == 1)
        #expect(flows.index(ofID: 9) == 2)
        #expect(flows.index(ofID: 1) == nil)
        #expect(flows.index(ofID: 6) == nil)
        #expect(flows.index(ofID: 10) == nil)
        #expect([Flow]().index(ofID: 1) == nil)
        #expect(flows.insertionIndex(forID: 6) == 2)
    }
}

@Suite struct FlowListStateRemovalTests {
    private func removal(_ ids: Int...) -> FlowChange {
        FlowChange(cleared: false, removed: ids, upserted: [])
    }

    @Test func removalUpdatesCollectionAndGroups() {
        var state = FlowListState()
        state.apply(upsert(makeFlow(1, host: "a.com", client: "curl"), makeFlow(2, host: "b.com"), makeFlow(3, host: "a.com")))
        state.apply(removal(1))
        #expect(state.visible.map(\.id) == [2, 3])
        #expect(state.hostGroups == [GroupCount(name: "a.com", count: 1), GroupCount(name: "b.com", count: 1)])
        #expect(state.appGroups == [GroupCount(name: "未知", count: 2)])
        expectConsistent(state)
    }

    @Test func removalUpdatesTheFilteredList() {
        var state = FlowListState()
        var filter = FlowFilter()
        filter.methods = ["POST"]
        state.setFilter(filter)
        state.apply(upsert(makeFlow(1, method: "POST"), makeFlow(2), makeFlow(3, method: "POST")))
        #expect(state.visible.map(\.id) == [1, 3])
        // 2 never matched; removing it alongside 1 must not disturb 3.
        state.apply(FlowChange(cleared: false, removed: [1, 2], upserted: [makeFlow(4, method: "POST")]))
        #expect(state.visible.map(\.id) == [3, 4])
        expectConsistent(state)
    }

    @Test func scopeFallsBackWhenItsLastFlowIsRemoved() {
        var state = FlowListState()
        state.apply(upsert(makeFlow(1, host: "a.com"), makeFlow(2, host: "b.com")))
        var filter = FlowFilter()
        filter.scope = .host("a.com")
        state.setFilter(filter)
        #expect(state.visible.map(\.id) == [1])
        state.apply(removal(1))
        #expect(state.filter.scope == .all)
        #expect(state.visible.map(\.id) == [2])
        expectConsistent(state)
    }

    @Test func unknownRemovedIDsAreIgnored() {
        var state = FlowListState()
        state.apply(upsert(makeFlow(5)))
        state.apply(removal(1, 2))
        #expect(state.visible.map(\.id) == [5])
        expectConsistent(state)
    }
}
