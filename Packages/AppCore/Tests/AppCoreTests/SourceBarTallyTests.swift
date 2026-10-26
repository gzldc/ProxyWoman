import FlowStore
import Testing

@testable import AppCore

@Suite(.productionChinese) struct SourceBarTallyTests {
    private func flow(_ id: Int, host: String = "a.com", method: String = "GET", hidden: Bool = false, mark: Bool = false) -> Flow {
        var flow = Flow(id: id, scheme: "https", method: method, host: host, port: 443, path: "/\(id)")
        flow.isHidden = hidden
        if mark { flow.manualMark = FlowMark(background: "#FF0000", source: .manual) }
        return flow
    }

    private struct Mirror {
        var flows: [Int: Flow] = [:]
        var tally = SourceBarTally()
        mutating func apply(_ change: FlowChange) {
            let before = flows
            tally.apply(change, previous: { before[$0] })
            if change.cleared { flows = [:] }
            for id in change.removed { flows[id] = nil }
            for flow in change.upserted { flows[flow.id] = flow }
        }
    }

    @Test func insertCountsEachBucket() {
        var m = Mirror()
        m.apply(FlowChange(cleared: false, upserted: [
            flow(1), flow(2, mark: true), flow(3, method: "CONNECT"), flow(4, hidden: true),
        ]))
        #expect(m.tally.allCount == 3)
        #expect(m.tally.markedCount == 1)
        #expect(m.tally.hiddenCount == 1)
        #expect(m.tally.undecryptedCount == 1)
    }

    @Test func updateMovesBetweenBuckets() {
        var m = Mirror()
        m.apply(FlowChange(cleared: false, upserted: [flow(1), flow(2)]))
        m.apply(FlowChange(cleared: false, upserted: [flow(1, mark: true)]))
        #expect(m.tally.markedCount == 1)
        m.apply(FlowChange(cleared: false, upserted: [flow(1, hidden: true, mark: true)]))
        #expect(m.tally.allCount == 1)
        #expect(m.tally.markedCount == 0)
        #expect(m.tally.hiddenCount == 1)
        m.apply(FlowChange(cleared: false, upserted: [flow(1, mark: true)]))
        #expect(m.tally.allCount == 2)
        #expect(m.tally.markedCount == 1)
        #expect(m.tally.hiddenCount == 0)
    }

    @Test func removeAndClearReset() {
        var m = Mirror()
        m.apply(FlowChange(cleared: false, upserted: [flow(1, mark: true), flow(2, method: "CONNECT"), flow(3, hidden: true)]))
        m.apply(FlowChange(cleared: false, removed: [1, 2, 3], upserted: []))
        #expect(m.tally == SourceBarTally())
        m.apply(FlowChange(cleared: false, upserted: [flow(4, mark: true)]))
        m.apply(FlowChange(cleared: true, upserted: []))
        #expect(m.tally == SourceBarTally())
    }

    @Test func undecryptedHostsGroupedAscending() {
        var m = Mirror()
        m.apply(FlowChange(cleared: false, upserted: [
            flow(1, host: "b.com", method: "CONNECT"), flow(2, host: "a.com", method: "CONNECT"),
            flow(3, host: "b.com", method: "CONNECT"),
        ]))
        #expect(m.tally.undecryptedHosts == [GroupCount(name: "a.com", count: 1), GroupCount(name: "b.com", count: 2)])
    }

    @Test func hiddenConnectNotCountedAsUndecrypted() {
        var m = Mirror()
        m.apply(FlowChange(cleared: false, upserted: [flow(1, method: "CONNECT", hidden: true)]))
        #expect(m.tally.undecryptedCount == 0)
        #expect(m.tally.undecryptedHosts.isEmpty)
        #expect(m.tally.hiddenCount == 1)
    }

    @Test func matchesFullRecountAfterRandomChanges() {
        var seed: UInt64 = 0x2545F4914F6CDD1D
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        var m = Mirror()
        let hosts = ["a.com", "b.com", "c.com"]
        for _ in 0..<200 {
            let change: FlowChange
            switch next(10) {
            case 0:
                change = FlowChange(cleared: true, upserted: [])
            case 1, 2:
                change = FlowChange(cleared: false, removed: [next(12), next(12)], upserted: [])
            default:
                let batch = (0...next(3)).map { _ in
                    flow(next(12), host: hosts[next(3)], method: next(3) == 0 ? "CONNECT" : "GET", hidden: next(4) == 0, mark: next(3) == 0)
                }
                change = FlowChange(cleared: false, upserted: batch)
            }
            m.apply(change)
            #expect(m.tally == SourceBarTally.recount(Array(m.flows.values)))
        }
    }
}
