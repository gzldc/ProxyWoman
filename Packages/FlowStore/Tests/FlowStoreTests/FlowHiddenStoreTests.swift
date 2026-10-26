import Foundation
import Testing

@testable import FlowStore

private func makeFlow(_ id: Int) -> Flow {
    Flow(id: id, scheme: "https", method: "GET", host: "h", port: 443, path: "/\(id)")
}

@Suite struct FlowHiddenStoreTests {
    @Test func hiddenFlowsStayInTheStoreButNotInVisibleReads() {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        for _ in 0..<3 { env.store.begin(makeFlow) }
        env.store.update(2) { $0.isHidden = true }
        #expect(env.store.allFlows().map(\.id) == [1, 2, 3])
        #expect(env.store.visibleFlows().map(\.id) == [1, 3])
        #expect(env.store.visibleFlow(2) == nil)
        #expect(env.store.flow(2) != nil)
        #expect(env.store.visibleFlow(1) != nil)
        #expect(env.store.visibleFlowCount == 2)
        #expect(env.store.flowCount == 3)
    }

    @Test func hiddenCountFollowsUpdatesEvictionAndClear() {
        let env = TestEnvironment(maxFlows: 3)
        defer { env.cleanUp() }
        for _ in 0..<3 { env.store.begin(makeFlow) }
        env.store.update(1) { $0.isHidden = true }
        #expect(env.store.visibleFlowCount == 2)
        env.store.begin(makeFlow)
        #expect(env.store.visibleFlows().map(\.id) == [2, 3, 4])
        #expect(env.store.visibleFlowCount == 3)
        env.store.update(4) { $0.isHidden = true }
        #expect(env.store.visibleFlowCount == 2)
        env.store.clear()
        #expect(env.store.visibleFlowCount == 0)
        env.store.begin(makeFlow)
        #expect(env.store.visibleFlowCount == 1)
    }

    @Test func unhidingRestoresVisibility() {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        env.store.begin(makeFlow)
        env.store.update(1) { $0.isHidden = true }
        #expect(env.store.visibleFlowCount == 0)
        env.store.update(1) { $0.isHidden = false }
        #expect(env.store.visibleFlowCount == 1)
        #expect(env.store.visibleFlow(1) != nil)
    }

    @Test func setManualMarkStoresAManualSourceAndClears() throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        env.store.begin(makeFlow)
        let ruleMark = try #require(FlowMark(background: "#123456", source: .rule(id: UUID(), name: "n")))
        env.store.setManualMark(ruleMark, for: 1)
        #expect(env.store.flow(1)?.manualMark?.source == .manual)
        #expect(env.store.flow(1)?.manualMark?.background == "#123456")
        env.store.setManualMark(nil, for: 1)
        #expect(env.store.flow(1)?.manualMark == nil)
        env.store.setManualMark(ruleMark, for: 99)
        #expect(env.store.flow(99) == nil)
    }

    @Test func setCommentLimitsAndClears() {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        env.store.begin(makeFlow)
        env.store.setComment("  ", for: 1)
        #expect(env.store.flow(1)?.comment == nil)
        env.store.setComment("hello", for: 1)
        #expect(env.store.flow(1)?.comment == "hello")
        env.store.setComment(nil, for: 1)
        #expect(env.store.flow(1)?.comment == nil)
        env.store.setComment("x", for: 99)
        #expect(env.store.flow(99) == nil)
    }

    @Test func provenanceUpdatesLeaveTheUserFields() throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        env.store.begin(makeFlow)
        let mark = try #require(FlowMark(background: "#ABCDEF", source: .manual))
        env.store.setManualMark(mark, for: 1)
        env.store.setComment("note", for: 1)
        env.store.update(1) { $0.isHidden = true }
        env.store.update(1) { $0.provenance = FlowProvenance(rulesModified: true) }
        let flow = env.store.flow(1)
        #expect(flow?.manualMark == mark)
        #expect(flow?.comment == "note")
        #expect(flow?.isHidden == true)
        #expect(flow?.provenance.rulesModified == true)
    }
}
