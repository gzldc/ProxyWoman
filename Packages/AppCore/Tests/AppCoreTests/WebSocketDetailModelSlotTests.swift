import Foundation
import Testing
@testable import AppCore
import FlowStore

/// Phase fix 3: the detail view's model is created lazily, survives view-value churn and is
/// recreated after a disappear cancelled it.
@MainActor @Suite(.productionChinese) struct WebSocketDetailModelSlotTests {
    @Test func slotCreatesLazilyReusesAndRecreatesAfterCancel() async throws {
        let store = FlowStore(bodyDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let id = store.begin { Flow(id: $0, scheme: "http", method: "GET", host: "synthetic.test", port: 80, path: "/ws") }
        let token = try #require(store.beginWebSocket(flowID: id, handshake: .init()))
        let stamp = try #require(store.webSocketCaptureStamp(token: token))
        var row = WebSocketEventMetadata(id: 1, order: .init(ingressSequence: stamp.ingressSequence, offset: 0), direction: .clientToServer, kind: .text)
        row.completedAt = Date()
        #expect(store.publishWebSocket(.init(metadata: row, stamp: stamp), token: token, captureEpoch: stamp.epoch) == .accepted)
        let hub = WebSocketInvalidationHub(store: store); defer { hub.stop() }
        // Re-creating the slot (as SwiftUI re-evaluates @State initial values) subscribes nothing.
        let slot = WebSocketDetailModelSlot(); _ = WebSocketDetailModelSlot()
        #expect(slot.model == nil && hub.subscriberCount == 0)
        let first = slot.activate(store: store, hub: hub, token: token)
        #expect(slot.activate(store: store, hub: hub, token: token) === first && hub.subscriberCount == 1)
        await first.load(after: nil); #expect(first.page.map(\.id) == [1])
        slot.deactivate()
        #expect(slot.model == nil && first.isCancelled && first.page.isEmpty)
        let second = slot.activate(store: store, hub: hub, token: token)
        #expect(second !== first && !second.isCancelled)
        await second.load(after: nil); #expect(second.page.map(\.id) == [1])
        // A model cancelled elsewhere is never handed back.
        second.cancel()
        let third = slot.activate(store: store, hub: hub, token: token)
        #expect(third !== second && !third.isCancelled)
        slot.deactivate()
    }
    @Test func onlyWebSocketCandidateFlowsObserveInvalidations() {
        var plain = Flow(id: 1, scheme: "http", method: "GET", host: "a", port: 80, path: "/")
        #expect(!WebSocketDetailModelSlot.observesInvalidations(plain))
        plain.statusCode = 200
        #expect(!WebSocketDetailModelSlot.observesInvalidations(plain))
        var upgraded = plain; upgraded.statusCode = 101
        #expect(WebSocketDetailModelSlot.observesInvalidations(upgraded))
        var request = Flow(id: 2, scheme: "https", method: "GET", host: "a", port: 443, path: "/ws")
        request.requestHeaders = [.init(name: "Upgrade", value: "websocket"), .init(name: "Connection", value: "Upgrade")]
        #expect(WebSocketDetailModelSlot.observesInvalidations(request))
    }
}
