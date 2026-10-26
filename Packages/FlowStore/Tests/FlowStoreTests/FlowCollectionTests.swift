import Foundation
import Testing

@testable import FlowStore

private func makeFlow(_ id: Int, status: Int? = nil) -> Flow {
    var f = Flow(id: id, scheme: "http", method: "GET", host: "h", port: 80, path: "/\(id)")
    f.statusCode = status
    return f
}

@Suite struct FlowCollectionTests {
    @Test func flowCollectionAppliesChanges() {
        var c = FlowCollection()
        c.apply(FlowChange(cleared: false, upserted: [makeFlow(3), makeFlow(1), makeFlow(2)]))
        #expect(c.flows.map(\.id) == [1, 2, 3])

        c.apply(FlowChange(cleared: false, upserted: [makeFlow(2, status: 200)]))
        #expect(c.flows.map(\.id) == [1, 2, 3])
        #expect(c.flow(id: 2)?.statusCode == 200)
        #expect(c.flow(id: 9) == nil)

        c.apply(FlowChange(cleared: true, upserted: [makeFlow(7)]))
        #expect(c.flows.map(\.id) == [7])
        #expect(c.flow(id: 1) == nil)
    }

    @Test func laterInsertsKeepAscendingOrder() {
        var c = FlowCollection()
        c.apply(FlowChange(cleared: false, upserted: [makeFlow(5)]))
        c.apply(FlowChange(cleared: false, upserted: [makeFlow(9), makeFlow(2)]))
        #expect(c.flows.map(\.id) == [2, 5, 9])
    }
}

@Suite struct FlowCollectionRemovalTests {
    @Test func removedIDsAreDroppedBeforeUpserts() {
        var c = FlowCollection()
        c.apply(FlowChange(cleared: false, upserted: [makeFlow(1), makeFlow(2), makeFlow(3), makeFlow(4)]))
        // 2 is gone; 9 was never delivered (evicted before its first batch) and is ignored.
        c.apply(FlowChange(cleared: false, removed: [1, 2, 9], upserted: [makeFlow(5)]))
        #expect(c.flows.map(\.id) == [3, 4, 5])
        #expect(c.flow(id: 1) == nil)
    }

    @Test func removingFromTheMiddleKeepsTheRest() {
        var c = FlowCollection()
        c.apply(FlowChange(cleared: false, upserted: (1...6).map { makeFlow($0) }))
        c.apply(FlowChange(cleared: false, removed: [2, 4], upserted: []))
        #expect(c.flows.map(\.id) == [1, 3, 5, 6])
    }
}
