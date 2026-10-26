import Foundation
import Testing
@testable import FlowStore

@Suite struct WebSocketBudgetTests {
    @Test func acceptedCellMetadataLivesWithPayloadAndReaderCopySurvivesClearIndependently() throws {
        let store = wsStore(); let token = try wsSession(store)
        let baseline = store.webSocketBudget.usedBytes(category: .metadata)
        #expect(try wsPublish(store, token, id: 1, bytes: Data([1, 2, 3])) == .accepted)
        // One event + one registered cell; the cell charge now lasts through storage.
        #expect(store.webSocketBudget.usedBytes(category: .metadata) == baseline + 512 + 512)
        let copy = try #require(store.webSocketPayload(token: token, eventID: 1, kind: .application, maxBytes: 3))
        store.setWebSocketRecording(enabled: false, revision: 1)
        #expect(store.webSocketBudget.usedBytes(category: .retained) == 3) // Accepted complete row survives Pause.
        store.clear()
        #expect(copy.bytes == Data([1, 2, 3])) // Bounded independent reader ownership is permitted.
        for category in WebSocketMemoryCategory.allCases { #expect(store.webSocketBudget.usedBytes(category: category) == 0) }
    }
    @Test func canonicalHandshakeChargesRepeatedFieldsAndRejectsDestinationWhilePendingLives() throws {
        // Default canonical: heads 1024 + scalars 192 + containers 384 + UTF8 38 = 1638 -> 1664.
        // Two repeated A:b fields: 256 + 8 text bytes, -> 1920; plus session/terminal 2560 = 4480.
        var limits = WebSocketLimits(); limits.metadataBytes = 4480
        let store = wsStore(limits)
        let id = store.begin { Flow(id: $0, scheme: "http", method: "GET", host: "synthetic.test", port: 80, path: "/") }
        let handshake = WebSocketHandshake(requestHeaders: [.init(name: "A", value: "b"), .init(name: "A", value: "b")])
        guard let pending = store.webSocketBudget.reserveHandshakeMetadata(headCount: 1, headerFieldCount: 0,
            scalarStringCount: 2, containerCount: 1, utf8Bytes: 4) else { Issue.record("pending refused"); return }
        #expect(pending.bytes == 768) // GET + / are retained original method and URI.
        #expect(store.beginWebSocket(flowID: id, handshake: handshake) == nil)
        #expect(store.webSocketBudget.usedBytes(category: .metadata) == 768)
        pending.release()
        let token = try #require(store.beginWebSocket(flowID: id, handshake: handshake))
        #expect(store.webSocketBudget.usedBytes(category: .metadata) == 4480)
        #expect(store.webSocketSummary(token: token)?.handshake.requestHeaders.count == 2)
        store.clear()
        #expect(store.webSocketBudget.usedBytes(category: .metadata) == 0)
    }
    @Test func failedRetainedTransferReleasesWorkingOnce() throws {
        var limits = WebSocketLimits(); limits.retainedBytes = 0
        let store = wsStore(limits); let token = try wsSession(store)
        let stamp = try #require(store.webSocketCaptureStamp(token: token))
        let handle = try #require(store.makeWebSocketAccumulator(token: token, eventID: 1, epoch: stamp.epoch, kind: .application))
        #expect(handle.append(Data([1]), expectedEpoch: stamp.epoch))
        guard let payload = handle.take(kind: .application, complete: true, truncated: false) else { Issue.record("take failed"); return }
        if let retained = store.webSocketBudget.transferToRetained(payload) { _ = consume retained; Issue.record("retained overflow") }
        #expect(store.webSocketBudget.usedBytes(category: .working) == 32_768)
        #expect(store.webSocketBudget.usedBytes(category: .retained) == 0)
        handle.revoke(); handle.revoke()
        #expect(store.webSocketBudget.usedBytes(category: .working) == 32_768)
    }

    @Test func everyHandshakeCountRejectsNegativeOverflowAndRoundingOverflow() {
        let budget = WebSocketMemoryBudget(limits: .init())
        for index in 0..<5 {
            for invalid in [-1, Int.max] {
                var counts = [0,0,0,0,0]; counts[index] = invalid
                if let value = budget.reserveHandshakeMetadata(headCount: counts[0], headerFieldCount: counts[1],
                    scalarStringCount: counts[2], containerCount: counts[3], utf8Bytes: counts[4]) {
                    value.release(); Issue.record("invalid metadata count admitted")
                }
            }
        }
        #expect(WebSocketMemoryBudget.handshakeCost(headCount: 0, headerFieldCount: 0, scalarStringCount: 0, containerCount: 0, utf8Bytes: Int.max / 2) == nil)
        #expect(budget.usedBytes(category: .metadata) == 0)
    }
    @Test func ordinaryReservationDeinitReturnsQuota() {
        let budget = WebSocketMemoryBudget(limits: .init())
        do {
            guard let owner = budget.reserve(category: .mailbox, bytes: 32) else { Issue.record("reserve failed"); return }
            #expect(owner.bytes == 32)
            #expect(budget.usedBytes(category: .mailbox) == 32)
        }
        #expect(budget.usedBytes(category: .mailbox) == 0)
    }

    @Test func budgetCategoriesDoNotBorrow() {
        let budget = WebSocketMemoryBudget(limits: .init())
        let caps = [33_554_432, 8_388_608, 8_388_608, 16_777_216, 16_777_216]
        #expect(caps.reduce(0,+) == 83_886_080)
        #expect(FlowStore.defaultMaxResidentBodyBytes == 134_217_728)
        #expect(FlowStore.defaultMaxActiveBodyBytes == 33_554_432)
        do {
            guard let retained = budget.reserve(category: .retained, bytes: 33_554_432),
                  let working = budget.reserve(category: .working, bytes: 8_388_608),
                  let mailbox = budget.reserve(category: .mailbox, bytes: 8_388_608),
                  let native = budget.reserve(category: .native, bytes: 16_777_216),
                  let metadata = budget.reserve(category: .metadata, bytes: 16_777_216) else {
                Issue.record("Independent categories cannot simultaneously own their caps"); return
            }
            #expect(WebSocketMemoryCategory.allCases.reduce(0) { $0 + budget.usedBytes(category: $1) } == 83_886_080)
            retained.release(); working.release(); mailbox.release(); native.release(); metadata.release()
        }
        for (category, cap) in zip(WebSocketMemoryCategory.allCases, caps) {
            guard let reservation = budget.reserve(category: category, bytes: cap) else { Issue.record("exact cap refused"); return }
            #expect(reservation.bytes == cap && reservation.category == category)
            if let extra = budget.reserve(category: category, bytes: 1) { extra.release(); Issue.record("borrowed budget") }
            reservation.release()
            #expect(budget.usedBytes(category: category) == 0)
        }
    }
    @Test func handshakeCostsRejectOverflowAndReserveDestinationFirst() {
        let budget = WebSocketMemoryBudget(limits: .init())
        // 512 + 128 + 64 + 64 + 2*3 = 774, round to 832.
        guard let pending = budget.reserveHandshakeMetadata(headCount: 1, headerFieldCount: 1, scalarStringCount: 1, containerCount: 1, utf8Bytes: 3) else { Issue.record("pending refused"); return }
        #expect(pending.bytes == 832)
        guard let destination = budget.reserveHandshakeMetadata(headCount: 2, headerFieldCount: 2, scalarStringCount: 2, containerCount: 2, utf8Bytes: 6) else { Issue.record("destination refused"); return }
        #expect(destination.bytes == 1600)
        #expect(budget.usedBytes(category: .metadata) == 2432)
        pending.release(); destination.release()
        for invalid in [-1, Int.max] {
            if let value = budget.reserveHandshakeMetadata(headCount: invalid, headerFieldCount: 0, scalarStringCount: 0, containerCount: 0, utf8Bytes: 0) { value.release(); Issue.record("invalid cost accepted") }
        }
        #expect(budget.usedBytes(category: .metadata) == 0)
    }
    @Test func scratchAdmissionTransfersOnceAndLateOwnerSurvivesClear() throws {
        let store = wsStore(); let token = try wsSession(store)
        #expect(store.webSocketBudget.usedBytes(category: .working) == 32_768)
        guard let scratch = store.takeWebSocketScratchReservation(token: token) else { Issue.record("missing scratch"); return }
        #expect(scratch.bytes == 32_768 && scratch.category == .working)
        if let second = store.takeWebSocketScratchReservation(token: token) { second.release(); Issue.record("duplicate scratch") }
        #expect(store.webSocketBudget.usedBytes(category: .native) == 0)
        store.clear()
        #expect(store.webSocketBudget.usedBytes(category: .working) == 32_768)
        scratch.release()
        #expect(store.webSocketBudget.usedBytes(category: .working) == 0)
    }
    @Test func workingTransferHasNoUnchargedGapAndSealedCellRemainsRevocable() throws {
        let store = wsStore(); let token = try wsSession(store)
        let stamp = try #require(store.webSocketCaptureStamp(token: token))
        let handle = try #require(store.makeWebSocketAccumulator(token: token, eventID: 1, epoch: stamp.epoch, kind: .application))
        #expect(handle.append(Data([1,2,3]), expectedEpoch: stamp.epoch))
        guard let payload = handle.take(kind: .application, complete: true, truncated: false),
              let retained = store.webSocketBudget.transferToRetained(payload) else { Issue.record("transfer failed"); return }
        #expect(store.webSocketBudget.usedBytes(category: .working) == 32_768)
        #expect(store.webSocketBudget.usedBytes(category: .retained) == 3)
        store.setWebSocketRecording(enabled: false, revision: 1)
        #expect(store.webSocketBudget.usedBytes(category: .retained) == 0)
        let metadata = WebSocketEventMetadata(id: 1, order: .init(ingressSequence: stamp.ingressSequence, offset: 0), direction: .clientToServer, kind: .text)
        let batch = WebSocketEventBatch(metadata: metadata, stamp: stamp, application: retained)
        #expect(store.publishWebSocket(batch, token: token, captureEpoch: stamp.epoch) == .recordingPausedOrEpochChanged)
    }
}
