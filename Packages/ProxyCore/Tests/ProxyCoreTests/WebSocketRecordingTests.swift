import Foundation
import FlowStore
import Testing
import NIOPosix
@testable import ProxyCore

@Suite(.productionChinese) struct WebSocketRecordingTests {
    @Test func staleRevisionCannotReopenPausedAdmission() {
        let store = observationStore()
        let actual = WebSocketRecordingController(store: store)
        actual.setEnabled(false, revision: 7); actual.setEnabled(true, revision: 6)
        #expect(!store.webSocketRecordingState().enabled)
        actual.setEnabled(true, revision: 8)
        #expect(store.webSocketRecordingState().enabled)
        #expect(store.webSocketRecordingState().epoch == 2)
    }
}

extension WebSocketRecordingTests {
    @Test(arguments: [false, true])
    func rapidPauseResumeRejectsTakenOldEpoch(clear: Bool) async throws {
        let store = observationStore(), gate = WSBarrier(), progress = WSProgress()
        let controller = WebSocketRecordingController(store: store)
        let coordinator = WebSocketCaptureCoordinator(store: store, hooks: .init(afterTake: { await gate.enter() }, afterChunk: { await progress.advance() }), controller: controller)
        let heads = observationHeads(), id = observationFlow(store)
        let handle = try #require(coordinator.begin(flowID: id, request: heads.0, response: heads.1, eventLoop: MultiThreadedEventLoopGroup.singleton.next()))
        let token = try #require(store.webSocketToken(flowID: id))
        handle.offer(wsFrame(Array("private".utf8)), direction: .serverToClient)
        await gate.wait()
        if clear { store.clear() } else { controller.setEnabled(false, revision: 1); controller.setEnabled(true, revision: 2) }
        #expect(store.webSocketBudget.usedBytes(category: .retained) == 0)
        await gate.release(); await progress.wait(1)
        if clear { #expect(store.webSocketToken(flowID: id) == nil) }
        else {
            #expect(store.webSocketPage(token: token, after: nil, limit: 10)?.rows.isEmpty == true)
            handle.offer(wsFrame([78]), direction: .serverToClient); await progress.wait(2)
            let row = try #require(store.webSocketPage(token: token, after: nil, limit: 10)?.rows.first)
            #expect(store.webSocketPayload(token: token, eventID: row.id, kind: .application, maxBytes: 10)?.bytes == Data([78]))
        }
        await coordinator.shutdown()
        #expect(store.webSocketBudget.usedBytes(category: .working) == 0)
    }
    @Test func pauseRevokesWorkingPrefixWithoutNextReadAndResumeSkipsContinuation() async throws {
        let store = observationStore(), progress = WSProgress()
        let actual = WebSocketRecordingController(store: store)
        let coordinator = WebSocketCaptureCoordinator(store: store, hooks: .init(afterChunk: { await progress.advance() }), controller: actual)
        let heads = observationHeads(), id = observationFlow(store)
        let handle = try #require(coordinator.begin(flowID: id, request: heads.0, response: heads.1, eventLoop: MultiThreadedEventLoopGroup.singleton.next()))
        let token = try #require(store.webSocketToken(flowID: id))
        handle.offer(wsFrame([65], fin: false), direction: .serverToClient); await progress.wait(1)
        #expect(store.webSocketBudget.usedBytes(category: .working) == 32_770)
        actual.setEnabled(false, revision: 1)
        #expect(store.webSocketBudget.usedBytes(category: .working) == 32_768)
        actual.setEnabled(true, revision: 2)
        handle.offer(wsFrame([66], opcode: 0), direction: .serverToClient)
        handle.offer(wsFrame([], opcode: 2), direction: .serverToClient); await progress.wait(3)
        let rows = try #require(store.webSocketPage(token: token, after: nil, limit: 10)?.rows)
        #expect(rows.count == 2 && rows[0].integrity == .partialPaused)
        #expect(store.webSocketPayload(token: token, eventID: rows[0].id, kind: .application, maxBytes: 10) == nil)
        #expect(store.webSocketPayload(token: token, eventID: rows[1].id, kind: .application, maxBytes: 10)?.bytes == Data())
        await coordinator.shutdown(); 
    }
}

extension WebSocketRecordingTests {
    @Test func clearDoesNotWaitForStampedReadToPublish() async throws {
        let store = observationStore(), gate = WSSynchronousGate()
        let coordinator = WebSocketCaptureCoordinator(store: store, hooks: .init(beforePublish: { gate.enter() }))
        let heads = observationHeads(), id = observationFlow(store)
        let handle = try #require(coordinator.begin(flowID: id, request: heads.0, response: heads.1, eventLoop: MultiThreadedEventLoopGroup.singleton.next()))
        func exerciseRace() {
        let offered = DispatchSemaphore(value: 0), cleared = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { handle.offer(wsFrame([65]), direction: .serverToClient); offered.signal() }
        gate.wait()
        DispatchQueue.global().async { store.clear(); cleared.signal() }
        // A deadline only diagnoses a prohibited lock dependency; gate release always unwinds it.
        let completed = cleared.wait(timeout: .now() + 2) == .success
        #expect(completed)
        gate.release(); offered.wait()
        if !completed { cleared.wait() }
        }
        exerciseRace()
        await coordinator.shutdown()
        #expect(store.allFlows().isEmpty)
        for category in [WebSocketMemoryCategory.mailbox, .working, .native, .retained] {
            #expect(store.webSocketBudget.usedBytes(category: category) == 0)
        }
    }
}

extension WebSocketRecordingTests {
    @Test(arguments: [false, true])
    func stampedReadSerializesOppositeDirectionAndPauseBeforeCommit(pause: Bool) async throws {
        let store = observationStore(), gate = WSSynchronousGate(), progress = WSProgress()
        let controller = WebSocketRecordingController(store: store)
        let coordinator = WebSocketCaptureCoordinator(store: store, hooks: .init(afterChunk: { await progress.advance() }, beforePublish: { gate.enter() }), controller: controller)
        let heads = observationHeads(), id = observationFlow(store)
        let handle = try #require(coordinator.begin(flowID: id, request: heads.0, response: heads.1, eventLoop: MultiThreadedEventLoopGroup.singleton.next()))
        let token = try #require(store.webSocketToken(flowID: id))
        func race() {
            let first = DispatchSemaphore(value: 0), second = DispatchSemaphore(value: 0), started = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { handle.offer(wsFrame(Array(repeating: 65, count: 40_000)), direction: .serverToClient); first.signal() }
            gate.wait()
            DispatchQueue.global().async { started.signal(); handle.offer(wsFrame([66], masked: true), direction: .clientToServer); second.signal() }
            started.wait()
            #expect(store.webSocketPage(token: token, after: nil, limit: 10)?.rows.isEmpty == true)
            #expect(store.webSocketBudget.usedBytes(category: .mailbox) == 40_004)
            if pause { controller.setEnabled(false, revision: 1); controller.setEnabled(true, revision: 2) }
            gate.release(); first.wait(); second.wait()
        }
        race(); await progress.wait(3)
        let rows = try #require(store.webSocketPage(token: token, after: nil, limit: 10)?.rows)
        #expect(rows.count == (pause ? 1 : 2))
        if !pause {
            #expect(rows[0].direction == .serverToClient && rows[1].direction == .clientToServer)
            #expect(rows[0].order.ingressSequence < rows[1].order.ingressSequence)
            #expect(rows[0].decodedBytes == 40_000)
        }
        #expect(rows.last?.direction == .clientToServer)
        await coordinator.shutdown()
    }
    @Test func opaquePauseAndPausedControlsNeverSaveReasonOrPayload() async throws {
        let store = observationStore(), progress = WSProgress()
        let recording = WebSocketRecordingController(store: store)
        let coordinator = WebSocketCaptureCoordinator(store: store, hooks: .init(afterChunk: { await progress.advance() }), controller: recording)
        var heads = observationHeads()
        heads.0.headers.add(name: "Sec-WebSocket-Extensions", value: "x-synthetic")
        heads.1.headers.add(name: "Sec-WebSocket-Extensions", value: "x-synthetic")
        let id = observationFlow(store)
        let handle = try #require(coordinator.begin(flowID: id, request: heads.0, response: heads.1, eventLoop: MultiThreadedEventLoopGroup.singleton.next()))
        let token = try #require(store.webSocketToken(flowID: id))
        handle.offer(wsFrame([0xff, 0x00], opcode: 3, compressed: true), direction: .serverToClient); await progress.wait(1)
        let row = try #require(store.webSocketPage(token: token, after: nil, limit: 10)?.rows.first)
        #expect(row.kind == .opaqueFrame && row.integrity == .opaque)
        #expect(store.webSocketPayload(token: token, eventID: row.id, kind: .application, maxBytes: 10) == nil)
        #expect(store.webSocketPayload(token: token, eventID: row.id, kind: .wirePayload, maxBytes: 10)?.bytes == Data([0xff, 0x00]))
        recording.setEnabled(false, revision: 1); recording.setEnabled(true, revision: 2)
        handle.offer(wsFrame(Array("private reason".utf8), opcode: 8), direction: .serverToClient); await progress.wait(2)
        #expect(store.webSocketSummary(token: token)?.serverToClient.capture == .opaquePausedUntilReconnect)
        #expect(store.webSocketPage(token: token, after: nil, limit: 10)?.rows.count == 1)
        await coordinator.shutdown()
    }
}

extension WebSocketRecordingTests {
    @Test(arguments: [1, 3, 7])
    func splitHeaderMaskAndUTF8StayDiscardedAcrossEpoch(split: Int) async throws {
        let store = observationStore(), progress = WSProgress()
        let controller = WebSocketRecordingController(store: store)
        let owner = WebSocketCaptureCoordinator(store: store, hooks: .init(afterChunk: { await progress.advance() }), controller: controller)
        let heads = observationHeads(), id = observationFlow(store)
        let handle = try #require(owner.begin(flowID: id, request: heads.0, response: heads.1, eventLoop: MultiThreadedEventLoopGroup.singleton.next()))
        let token = try #require(store.webSocketToken(flowID: id))
        let wire = Array(wsFrame([0xe4, 0xb8, 0xad], masked: true).readableBytesView)
        handle.offer(.init(bytes: wire.prefix(split)), direction: .clientToServer); await progress.wait(1)
        controller.setEnabled(false, revision: 1); controller.setEnabled(true, revision: 2)
        handle.offer(.init(bytes: wire.dropFirst(split)), direction: .clientToServer)
        handle.offer(wsFrame([90], masked: true), direction: .clientToServer); await progress.wait(3)
        let rows = try #require(store.webSocketPage(token: token, after: nil, limit: 10)?.rows)
        #expect(rows.count == 2 && rows[0].integrity == .partialPaused)
        #expect(store.webSocketPayload(token: token, eventID: rows[0].id, kind: .application, maxBytes: 10) == nil)
        #expect(store.webSocketPayload(token: token, eventID: rows[1].id, kind: .application, maxBytes: 10)?.bytes == Data([90]))
        await owner.shutdown()
    }
    @Test func pausedMailboxLossCannotResumeCompressionOrCreatePayload() async throws {
        var limits = WebSocketLimits(); limits.sessionMailboxBytes = 16
        let store = observationStore(limits)
        let recording = WebSocketRecordingController(store: store)
        let owner = WebSocketCaptureCoordinator(store: store, hooks: .init(), controller: recording)
        var heads = observationHeads()
        heads.0.headers.add(name: "Sec-WebSocket-Extensions", value: "permessage-deflate")
        heads.1.headers.add(name: "Sec-WebSocket-Extensions", value: "permessage-deflate")
        let id = observationFlow(store)
        let handle = try #require(owner.begin(flowID: id, request: heads.0, response: heads.1, eventLoop: MultiThreadedEventLoopGroup.singleton.next()))
        let token = try #require(store.webSocketToken(flowID: id))
        recording.setEnabled(false, revision: 1)
        handle.offer(.init(repeating: 0, count: 17), direction: .serverToClient)
        recording.setEnabled(true, revision: 2)
        handle.offer(wsFrame(Array(WebSocketCompressionVectors.takeover), compressed: true), direction: .serverToClient)
        await owner.shutdown()
        #expect(store.webSocketPage(token: token, after: nil, limit: 10)?.rows.isEmpty == true)
        #expect(store.webSocketSummary(token: token)?.serverToClient.capture == .contentStoppedUntilReconnect)
        #expect(store.webSocketBudget.usedBytes(category: .retained) == 0)
        #expect(store.webSocketBudget.usedBytes(category: .native) == 0)
    }
}

extension WebSocketRecordingTests {
    @Test(arguments: [false, true])
    func overlappingProvisionalHeaderNeverRescuesRevokedPrefix(clear: Bool) async throws {
        let store = observationStore(), progress = WSProgress()
        let controller = WebSocketRecordingController(store: store)
        let owner = WebSocketCaptureCoordinator(store: store, hooks: .init(afterChunk: { await progress.advance() }), controller: controller)
        let heads = observationHeads(), id = observationFlow(store)
        let handle = try #require(owner.begin(flowID: id, request: heads.0, response: heads.1, eventLoop: MultiThreadedEventLoopGroup.singleton.next()))
        let token = try #require(store.webSocketToken(flowID: id))
        handle.offer(wsFrame([0x41], fin: false), direction: .serverToClient)
        handle.offer(.init(bytes: [0x81]), direction: .serverToClient)
        await progress.wait(2)
        #expect(store.webSocketBudget.usedBytes(category: .working) == 32_770)
        if clear { store.clear() }
        else { controller.setEnabled(false, revision: 1); controller.setEnabled(true, revision: 2) }
        #expect(store.webSocketBudget.usedBytes(category: .working) <= 32_768)
        handle.offer(.init(bytes: [0x00]), direction: .serverToClient)
        if !clear {
            await progress.wait(3)
            for eventID in [UInt64(1), 2] {
                for kind in [WebSocketPayloadKind.application, .wirePayload] {
                    #expect(store.webSocketPayload(token: token, eventID: eventID, kind: kind, maxBytes: 10) == nil)
                }
            }
            let rows = try #require(store.webSocketPage(token: token, after: nil, limit: 10)?.rows)
            #expect(rows.count == 2 && rows.allSatisfy { $0.completedAt == nil })
            #expect(store.webSocketSummary(token: token)?.serverToClient.capture == .contentStoppedUntilReconnect)
        }
        await owner.shutdown()
        if clear { #expect(store.webSocketToken(flowID: id) == nil && store.allFlows().isEmpty) }
        #expect(store.webSocketBudget.usedBytes(category: .working) == 0)
        #expect(store.webSocketBudget.usedBytes(category: .retained) == 0)
    }
}

extension WebSocketRecordingTests {
    /// Phase fix 6: a Store call stalled (e.g. Pause draining a held export gate) never holds the
    /// controller lock, and a newer revision still wins regardless of Store-call completion order.
    @Test func stalledStoreCallDoesNotBlockControllerAndNewestRevisionWins() throws {
        let store = observationStore()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), secondDone = DispatchSemaphore(value: 0)
        let controller = WebSocketRecordingController(store: store) { revision in
            if revision == 1 { entered.signal(); release.wait() }
        }
        let firstDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { controller.setEnabled(false, revision: 1); firstDone.signal() }
        #expect(entered.wait(timeout: .now() + 10) == .success)
        let token = try #require(store.beginWebSocket(flowID: observationFlow(store), handshake: .init()))
        DispatchQueue.global().async {
            controller.unregister(token)
            controller.setEnabled(true, revision: 2)
            secondDone.signal()
        }
        // Bounded: the second caller proceeds while the first is still inside its Store call.
        #expect(secondDone.wait(timeout: .now() + 10) == .success)
        release.signal()
        #expect(firstDone.wait(timeout: .now() + 10) == .success)
        // The stale revision 1 reached the Store last and was ignored there.
        let state = store.webSocketRecordingState()
        #expect(state.enabled && state.revision == 2)
    }
}
