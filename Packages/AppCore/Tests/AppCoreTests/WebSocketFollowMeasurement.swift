import Foundation
import Testing
@testable import AppCore
import FlowStore

/// Phase fix 2. Opt-in micro-measurement (no threshold): `PW_WS_MEASURE=1 swift test -c release --filter WebSocketFollowMeasurement`.
@MainActor @Suite(.productionChinese) struct WebSocketFollowMeasurement {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PW_WS_MEASURE"] == "1"))
    func followRefreshAtTenThousandEvents() async throws {
        let store = FlowStore(bodyDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let flowID = store.begin { Flow(id: $0, scheme: "http", method: "GET", host: "synthetic.test", port: 80, path: "/ws") }
        let token = try #require(store.beginWebSocket(flowID: flowID, handshake: .init()))
        for id in 1...10_000 {
            let stamp = try #require(store.webSocketCaptureStamp(token: token))
            var row = WebSocketEventMetadata(id: UInt64(id), order: .init(ingressSequence: stamp.ingressSequence, offset: 0), direction: .clientToServer, kind: .text)
            row.completedAt = Date()
            _ = store.publishWebSocket(.init(metadata: row, stamp: stamp), token: token, captureEpoch: stamp.epoch)
        }
        let hub = WebSocketInvalidationHub(store: store); defer { hub.stop() }
        let model = WebSocketViewModel(store: store, hub: hub, token: token); defer { model.cancel() }
        let clock = ContinuousClock()
        await model.load(after: nil)
        let elapsed = await clock.measure { for _ in 0..<20 { await model.load(after: nil) } }
        #expect(model.page.count == 200 && model.page.last?.id == 10_000)
        print("WS_FOLLOW_MEASURE perFollowRefresh(10k events)=\(elapsed / 20)")
    }
}
