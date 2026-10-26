import Foundation
import Testing
@testable import FlowStore

/// What a live count polls: a cheap stamp that moves when it could have a new answer, and the open sessions.
@Suite struct FlowChangeStampTests {
    @Test func stampMovesOnBeginUpdateAndClearOnly() {
        let store = wsStore()
        let start = store.changeStamp
        #expect(store.changeStamp == start)
        let id = store.begin { Flow(id: $0, scheme: "https", method: "GET", host: "a.test", port: 443, path: "/") }
        let afterBegin = store.changeStamp
        #expect(afterBegin != start)
        _ = store.flow(id)
        _ = store.recentFlows(limit: 10)
        #expect(store.changeStamp == afterBegin)
        store.update(id) { $0.isPausedAtBreakpoint = true }
        let afterUpdate = store.changeStamp
        #expect(afterUpdate != afterBegin)
        store.update(id + 99) { $0.isPausedAtBreakpoint = true }  // unknown id: nothing changed
        #expect(store.changeStamp == afterUpdate)
        store.clear()
        #expect(store.changeStamp != afterUpdate)
    }

    @Test func stampMovesWhenAWebSocketSessionOpensAndCloses() throws {
        let store = wsStore()
        let token = try wsSession(store)
        let opened = store.changeStamp
        #expect(store.openWebSocketFlowIDs() == [token.flowID])
        // A message does not move the stamp; only the lifecycle does.
        _ = try wsPublish(store, token, id: 1, bytes: Data("x".utf8))
        #expect(store.changeStamp == opened)
        store.endWebSocket(token: token, transport: .init(direction: .clientToServer, at: Date(), monotonic: 1))
        #expect(store.changeStamp == opened)
        store.endWebSocket(token: token, transport: .init(direction: .serverToClient, at: Date(), monotonic: 2))
        #expect(store.changeStamp != opened)
        #expect(store.openWebSocketFlowIDs().isEmpty)
    }
}
