import Foundation
import FlowStore
import NIOCore
import NIOPosix
import Testing
import os
@testable import ProxyCore

@Suite(.productionChinese) struct WebSocketObservationTests {
    @Test func finalChunkPrecedesBothEOFAndRetiringWorkerKeepsSlot() async throws {
        var limits = WebSocketLimits(); limits.observingSessions = 1
        let store = observationStore(limits), take = WSBarrier(), cleanup = WSBarrier()
        let coordinator = WebSocketCaptureCoordinator(store: store, hooks: .init(afterTake: { await take.enter() }, beforeCleanup: { await cleanup.enter() }))
        let heads = observationHeads(), loop = MultiThreadedEventLoopGroup.singleton.next()
        let id = observationFlow(store)
        let handle = try #require(coordinator.begin(flowID: id, request: heads.0, response: heads.1, eventLoop: loop))
        let token = try #require(store.webSocketToken(flowID: id))
        handle.offer(ByteBuffer(bytes: [0x81, 0x02, 0x68, 0x69]), direction: .serverToClient)
        await take.wait()
        handle.transportEnded(direction: .serverToClient); handle.transportEnded(direction: .clientToServer)
        #expect(store.webSocketSummary(token: token)?.lifecycle == .open)
        await take.release(); await cleanup.wait()
        let second = observationFlow(store)
        let fallback = try #require(coordinator.begin(flowID: second, request: heads.0, response: heads.1, eventLoop: loop))
        #expect(store.webSocketSummary(token: try #require(store.webSocketToken(flowID: second)))?.clientToServer.capture == .metadataOnly)
        #expect(coordinator.activeWorkerCount == 1)
        await cleanup.release(); await coordinator.shutdown()
        let row = try #require(store.webSocketPage(token: token, after: nil, limit: 10)?.rows.first)
        #expect(row.completedAt != nil && row.integrity == .transportComplete)
        #expect(store.webSocketPayload(token: token, eventID: row.id, kind: .application, maxBytes: 10)?.bytes == Data("hi".utf8))
        #expect(store.webSocketSummary(token: token)?.serverToClient.wireBytes == 4)
        #expect(store.webSocketSummary(token: token)?.serverToClient.applicationBytes == 2)
        #expect(store.webSocketSummary(token: token)?.lifecycle == .transportEndedWithoutClose)
        #expect(store.webSocketBudget.usedBytes(category: .mailbox) == 0)
        #expect(store.webSocketBudget.usedBytes(category: .native) == 0)
        #expect(store.webSocketBudget.usedBytes(category: .working) == 0)
        withExtendedLifetime(fallback) {}
    }
}

extension WebSocketObservationTests {
    @Test func firstByteOrderAndPendingPrefixThenTerminalPublication() async throws {
        let store = observationStore(), progress = WSProgress()
        let coordinator = WebSocketCaptureCoordinator(store: store, hooks: .init(afterChunk: { await progress.advance() }))
        let heads = observationHeads(), id = observationFlow(store)
        let handle = try #require(coordinator.begin(flowID: id, request: heads.0, response: heads.1, eventLoop: MultiThreadedEventLoopGroup.singleton.next()))
        let token = try #require(store.webSocketToken(flowID: id))
        handle.offer(ByteBuffer(bytes: [0x81]), direction: .serverToClient)
        handle.offer(wsFrame([66], masked: true), direction: .clientToServer)
        handle.offer(ByteBuffer(bytes: [0x03, 65]), direction: .serverToClient)
        await progress.wait(3)
        let pending = try #require(store.webSocketPage(token: token, after: nil, limit: 10))
        #expect(pending.rows.map(\.id) == [1, 2])
        #expect(pending.rows[0].completedAt == nil && pending.rows[1].completedAt != nil)
        #expect(store.webSocketPayload(token: token, eventID: 1, kind: .application, maxBytes: 10) == nil)
        #expect(store.webSocketBudget.usedBytes(category: .working) == 32_770)
        handle.cancel(); await coordinator.shutdown()
        let row = try #require(store.webSocketPage(token: token, after: nil, limit: 10)?.rows.first)
        #expect(row.captureAbandoned && row.completedAt == nil)
        #expect(store.webSocketPayload(token: token, eventID: 1, kind: .application, maxBytes: 10)?.bytes == Data([65]))
        #expect(store.webSocketSummary(token: token)?.lifecycle == .open)
        #expect(store.webSocketBudget.usedBytes(category: .working) == 0)
        handle.transportEnded(direction: .serverToClient); handle.transportEnded(direction: .clientToServer)
        #expect(store.webSocketSummary(token: token)?.lifecycle == .transportEndedWithoutClose)
    }
    @Test(arguments: [[], [0], [3, 232], [3, 237], [3, 232, 0xff], [11, 184], [19, 135]])
    func closePayloadValidation(payload: [UInt8]) async throws {
        let store = observationStore(), progress = WSProgress()
        let coordinator = WebSocketCaptureCoordinator(store: store, hooks: .init(afterChunk: { await progress.advance() }))
        let heads = observationHeads(), id = observationFlow(store)
        let handle = try #require(coordinator.begin(flowID: id, request: heads.0, response: heads.1, eventLoop: MultiThreadedEventLoopGroup.singleton.next()))
        let token = try #require(store.webSocketToken(flowID: id))
        handle.offer(wsFrame(payload, opcode: 8), direction: .serverToClient)
        await progress.wait(1)
        let valid = payload.isEmpty || payload == [3, 232] || payload == [11, 184] || payload == [19, 135]
        #expect(store.webSocketSummary(token: token)?.serverToClient.completedClose == valid)
        #expect(store.webSocketSummary(token: token)?.lifecycle == .open)
        let row = try #require(store.webSocketPage(token: token, after: nil, limit: 10)?.rows.first)
        #expect(row.integrity == (valid ? .transportComplete : .invalid))
        await coordinator.shutdown()
    }
    @Test func fragmentedUTF8InterleavedControlsAndDescriptorOverflow() async throws {
        let store = observationStore(), progress = WSProgress()
        let coordinator = WebSocketCaptureCoordinator(store: store, hooks: .init(afterChunk: { await progress.advance() }))
        let heads = observationHeads(), id = observationFlow(store)
        let handle = try #require(coordinator.begin(flowID: id, request: heads.0, response: heads.1, eventLoop: MultiThreadedEventLoopGroup.singleton.next()))
        let token = try #require(store.webSocketToken(flowID: id))
        var wire = wsFrame([0xe4], fin: false)
        wire.writeImmutableBuffer(wsFrame([9], opcode: 9))
        wire.writeImmutableBuffer(wsFrame([9], opcode: 10))
        wire.writeImmutableBuffer(wsFrame([0xb8, 0xad], opcode: 0, fin: false))
        for index in 0..<63 { wire.writeImmutableBuffer(wsFrame([], opcode: 0, fin: index == 62)) }
        handle.offer(wire, direction: .serverToClient); await progress.wait(1)
        let rows = try #require(store.webSocketPage(token: token, after: nil, limit: 10)?.rows)
        #expect(rows.count == 3 && rows[0].fragmentCount == 65 && rows[0].fragments.count == 64)
        #expect(rows[0].descriptorTruncated && rows[0].utf8 == .valid)
        #expect(store.webSocketPayload(token: token, eventID: 1, kind: .application, maxBytes: 10)?.bytes == Data([0xe4, 0xb8, 0xad]))
        #expect(store.webSocketSummary(token: token)?.serverToClient.applicationBytes == 3)
        await coordinator.shutdown()
    }
}

extension WebSocketObservationTests {
    @Test func invalidDirectionStopsOnceWhileHealthyDirectionPublishes() async throws {
        let store = observationStore(), progress = WSProgress()
        let coordinator = WebSocketCaptureCoordinator(store: store, hooks: .init(afterChunk: { await progress.advance() }))
        let heads = observationHeads(), id = observationFlow(store)
        let handle = try #require(coordinator.begin(flowID: id, request: heads.0, response: heads.1, eventLoop: MultiThreadedEventLoopGroup.singleton.next()))
        let token = try #require(store.webSocketToken(flowID: id))
        handle.offer(wsFrame([65]), direction: .clientToServer) // invalid unmasked client frame
        handle.offer(wsFrame([66]), direction: .serverToClient); await progress.wait(2)
        let rows = try #require(store.webSocketPage(token: token, after: nil, limit: 10)?.rows)
        #expect(rows.count == 2 && rows[0].integrity == .invalid)
        #expect(rows[0].captureAbandoned && rows[0].completedAt == nil)
        #expect(store.webSocketPayload(token: token, eventID: rows[1].id, kind: .application, maxBytes: 10)?.bytes == Data([66]))
        handle.offer(wsFrame([67], masked: true), direction: .clientToServer); await progress.wait(3)
        #expect(store.webSocketPage(token: token, after: nil, limit: 10)?.rows.count == 2)
        #expect(store.webSocketSummary(token: token)?.clientToServer.wireBytes == 10)
        await coordinator.shutdown()
    }
}

extension WebSocketObservationTests {
    @Test(arguments: [false, true])
    func compressedTakeoverSurvivesPausedDiscardAndRetentionEviction(paused: Bool) async throws {
        var limits = WebSocketLimits(); limits.sessionEvents = 1; limits.quantumBytes = 3; limits.quantumNativeOperations = 4
        let store = observationStore(limits), progress = WSProgress()
        let actual = WebSocketRecordingController(store: store)
        let coordinator = WebSocketCaptureCoordinator(store: store, hooks: .init(afterChunk: { await progress.advance() }), controller: actual)
        var heads = observationHeads()
        heads.0.headers.add(name: "Sec-WebSocket-Extensions", value: "permessage-deflate")
        heads.1.headers.add(name: "Sec-WebSocket-Extensions", value: "permessage-deflate")
        let id = observationFlow(store)
        let handle = try #require(coordinator.begin(flowID: id, request: heads.0, response: heads.1, eventLoop: MultiThreadedEventLoopGroup.singleton.next()))
        let token = try #require(store.webSocketToken(flowID: id))
        if paused { actual.setEnabled(false, revision: 1) }
        // RFC vectors: BFINAL Hello followed by a history-only Hello.
        handle.offer(wsFrame(Array(WebSocketCompressionVectors.bfinal), compressed: true), direction: .serverToClient)
        await progress.wait(1)
        if paused { actual.setEnabled(true, revision: 2) }
        handle.offer(wsFrame(Array(WebSocketCompressionVectors.takeover), compressed: true), direction: .serverToClient)
        await progress.wait(2)
        let rows = try #require(store.webSocketPage(token: token, after: nil, limit: 10)?.rows)
        #expect(rows.count == 1)
        #expect(rows[0].compressed && rows[0].utf8 == .valid && rows[0].decodedBytes == 5)
        #expect(store.webSocketPayload(token: token, eventID: rows[0].id, kind: .application, maxBytes: 10)?.bytes == Data("Hello".utf8))
        #expect(store.webSocketSummary(token: token)?.serverToClient.applicationBytes == 10)
        await coordinator.shutdown()
        #expect(store.webSocketBudget.usedBytes(category: .native) == 0)
        #expect(store.webSocketBudget.usedBytes(category: .working) == 0)
        
    }
    @Test func tinyOffersHitMetadataWhileInFlightChargeSurvivesCancel() async throws {
        var limits = WebSocketLimits(); limits.metadataBytes = 40_000
        let store = observationStore(limits), gate = WSBarrier()
        let coordinator = WebSocketCaptureCoordinator(store: store, hooks: .init(afterTake: { await gate.enter() }))
        let heads = observationHeads(), id = observationFlow(store)
        let handle = try #require(coordinator.begin(flowID: id, request: heads.0, response: heads.1, eventLoop: MultiThreadedEventLoopGroup.singleton.next()))
        handle.offer(ByteBuffer(bytes: [0x81]), direction: .serverToClient); await gate.wait()
        for _ in 0..<100 { handle.offer(ByteBuffer(bytes: [0]), direction: .serverToClient) }
        #expect(store.webSocketBudget.usedBytes(category: .mailbox) == 1)
        #expect(store.webSocketBudget.usedBytes(category: .metadata) <= 40_000)
        await gate.release(); await coordinator.shutdown()
        #expect(store.webSocketBudget.usedBytes(category: .mailbox) == 0)
        #expect(store.webSocketBudget.usedBytes(category: .working) == 0)
    }
    @Test func zeroPayloadControlFloodStopsSessionAtFrameRate() async throws {
        var limits = WebSocketLimits(); limits.sessionFramesPerSecond = 2
        let store = observationStore(limits), progress = WSProgress()
        let coordinator = WebSocketCaptureCoordinator(store: store, clock: .init(wallNow: { Date(timeIntervalSince1970: 0) }, monotonicNow: { 0 }), hooks: .init(afterChunk: { await progress.advance() }))
        let heads = observationHeads(), id = observationFlow(store)
        let handle = try #require(coordinator.begin(flowID: id, request: heads.0, response: heads.1, eventLoop: MultiThreadedEventLoopGroup.singleton.next()))
        let token = try #require(store.webSocketToken(flowID: id))
        handle.offer(ByteBuffer(bytes: Array(repeating: [UInt8(0x89), 0], count: 100).flatMap { $0 }), direction: .serverToClient)
        await progress.wait(1); await coordinator.shutdown()
        let rows = try #require(store.webSocketPage(token: token, after: nil, limit: 10)?.rows)
        #expect(rows.filter { $0.completedAt != nil }.count == 2)
        #expect(rows.count == 3)
        #expect(rows.last?.captureAbandoned == true)
        #expect(store.webSocketSummary(token: token)?.lifecycle == .open)
    }
}

extension WebSocketObservationTests {
    @Test(arguments: [false, true])
    func parserStagingAndProducerDescriptorsHaveIndependentPreallocation(refuse: Bool) async throws {
        var limits = WebSocketLimits(); limits.metadataBytes = 200_000
        let store = observationStore(limits), staged = WSBarrier(), progress = WSProgress()
        let coordinator = WebSocketCaptureCoordinator(store: store, hooks: .init(afterChunk: { await progress.advance() }, afterParserStage: { await staged.enter() }))
        let heads = observationHeads(), id = observationFlow(store)
        let handle = try #require(coordinator.begin(flowID: id, request: heads.0, response: heads.1, eventLoop: MultiThreadedEventLoopGroup.singleton.next()))
        let token = try #require(store.webSocketToken(flowID: id))
        let before = store.webSocketBudget.usedBytes(category: .metadata)
        handle.offer(wsFrame([65], fin: false), direction: .serverToClient); await staged.wait()
        #expect(store.webSocketBudget.usedBytes(category: .metadata) == before + 512 + 132_096)
        print("WS_RESOURCE parserStage refuse=\(refuse) metadata=\(store.webSocketBudget.usedBytes(category: .metadata)) working=\(store.webSocketBudget.usedBytes(category: .working))")
        #expect(store.webSocketBudget.usedBytes(category: .working) == 32_768 + 65_536)
        #expect(store.webSocketPage(token: token, after: nil, limit: 10)?.rows.isEmpty == true)
        var blocker: WebSocketReservation?
        if refuse {
            blocker = store.webSocketBudget.reserve(category: .metadata,
                bytes: limits.metadataBytes - store.webSocketBudget.usedBytes(category: .metadata) - (512 + 640 + 64 * 64 - 1))
        }
        await staged.release(); await progress.wait(1)
        if refuse {
            #expect(store.webSocketPage(token: token, after: nil, limit: 10)?.rows.isEmpty == true)
            #expect(store.webSocketSummary(token: token)?.serverToClient.capture == .contentStoppedUntilReconnect)
        } else {
            // Producer descriptors/diagnostic + Store's provisional copy + limiter entry + two registered accumulators.
            #expect(store.webSocketBudget.usedBytes(category: .metadata) == before + 512 + 640 + 64 * 64 + 512 + 512 + 1024)
            #expect(store.webSocketBudget.usedBytes(category: .working) == 32_770)
        }
        blocker = nil
        await coordinator.shutdown()
        #expect(store.webSocketBudget.usedBytes(category: .working) == 0)
        _ = consume blocker
    }
    @Test func nativeStagingRemainsChargedAcrossPauseAndDoesNotPublishOldOutput() async throws {
        let store = observationStore(), staged = WSBarrier(), progress = WSProgress()
        let controller = WebSocketRecordingController(store: store)
        let coordinator = WebSocketCaptureCoordinator(store: store, hooks: .init(afterChunk: { await progress.advance() }, afterNativeStage: { await staged.enter() }), controller: controller)
        var heads = observationHeads()
        heads.0.headers.add(name: "Sec-WebSocket-Extensions", value: "permessage-deflate")
        heads.1.headers.add(name: "Sec-WebSocket-Extensions", value: "permessage-deflate")
        let id = observationFlow(store)
        let handle = try #require(coordinator.begin(flowID: id, request: heads.0, response: heads.1, eventLoop: MultiThreadedEventLoopGroup.singleton.next()))
        let token = try #require(store.webSocketToken(flowID: id))
        handle.offer(wsFrame(Array(WebSocketCompressionVectors.bfinal), compressed: true), direction: .serverToClient)
        await staged.wait()
        #expect(store.webSocketBudget.usedBytes(category: .working) >= 32_768 + 65_536 * 2)
        #expect(store.webSocketBudget.usedBytes(category: .native) > 0)
        print("WS_RESOURCE nativeStage working=\(store.webSocketBudget.usedBytes(category: .working)) native=\(store.webSocketBudget.usedBytes(category: .native)) metadata=\(store.webSocketBudget.usedBytes(category: .metadata)) mailbox=\(store.webSocketBudget.usedBytes(category: .mailbox))")
        controller.setEnabled(false, revision: 1); controller.setEnabled(true, revision: 2)
        #expect(store.webSocketBudget.usedBytes(category: .working) == 32_768 + 65_536 * 2)
        await staged.release(); await progress.wait(1)
        #expect(store.webSocketPayload(token: token, eventID: 1, kind: .application, maxBytes: 10) == nil)
        await coordinator.shutdown()
        #expect(store.webSocketBudget.usedBytes(category: .native) == 0)
        #expect(store.webSocketBudget.usedBytes(category: .working) == 0)
    }
    @Test func fullReadFailureRollsBackAllSubchunksAndInertHandleOwnsOnly512() async throws {
        var limits = WebSocketLimits(); limits.mailboxBytes = 32_768
        let store = observationStore(limits)
        let coordinator = WebSocketCaptureCoordinator(store: store)
        let heads = observationHeads(), id = observationFlow(store)
        var handle = coordinator.begin(flowID: id, request: heads.0, response: heads.1, eventLoop: MultiThreadedEventLoopGroup.singleton.next())
        let token = try #require(store.webSocketToken(flowID: id))
        handle?.offer(ByteBuffer(repeating: 65, count: 32_769), direction: .serverToClient)
        await coordinator.shutdown()
        #expect(store.webSocketPage(token: token, after: nil, limit: 10)?.rows.isEmpty == true)
        #expect(store.webSocketSummary(token: token)?.serverToClient.wireBytes == 32_769)
        #expect(store.webSocketBudget.usedBytes(category: .mailbox) == 0)
        #expect(store.webSocketBudget.usedBytes(category: .working) == 0)
        #expect(coordinator.activeWorkerCount == 0)
        store.clear()
        #expect(store.webSocketBudget.usedBytes(category: .metadata) == 512)
        weak let released = handle
        handle = nil
        #expect(released == nil)
        #expect(store.webSocketBudget.usedBytes(category: .metadata) == 0)
    }
    @Test func abortedInFlightChunkHandsRealEOFToStoreOnlyAfterJoin() async throws {
        let store = observationStore(), take = WSBarrier(), cleanup = WSBarrier()
        let coordinator = WebSocketCaptureCoordinator(store: store, hooks: .init(afterTake: { await take.enter() }, beforeCleanup: { await cleanup.enter() }))
        let heads = observationHeads(), id = observationFlow(store)
        let handle = try #require(coordinator.begin(flowID: id, request: heads.0, response: heads.1, eventLoop: MultiThreadedEventLoopGroup.singleton.next()))
        let token = try #require(store.webSocketToken(flowID: id))
        handle.offer(wsFrame([65]), direction: .serverToClient); await take.wait()
        handle.cancel(); handle.transportEnded(direction: .clientToServer); handle.transportEnded(direction: .serverToClient)
        await take.release(); await cleanup.wait()
        #expect(store.webSocketSummary(token: token)?.lifecycle == .open)
        #expect(store.webSocketPage(token: token, after: nil, limit: 10)?.rows.isEmpty == true)
        #expect(store.webSocketBudget.usedBytes(category: .working) == 32_768)
        await cleanup.release(); await coordinator.shutdown()
        #expect(store.webSocketSummary(token: token)?.lifecycle == .transportEndedWithoutClose)
        #expect(store.webSocketBudget.usedBytes(category: .working) == 0)
    }
    @Test(arguments: [false, true])
    func partialEOFDoesNotInventFINAndOtherDirectionContinues(headerOnly: Bool) async throws {
        let store = observationStore(), progress = WSProgress()
        let coordinator = WebSocketCaptureCoordinator(store: store, hooks: .init(afterChunk: { await progress.advance() }))
        let heads = observationHeads(), id = observationFlow(store)
        let handle = try #require(coordinator.begin(flowID: id, request: heads.0, response: heads.1, eventLoop: MultiThreadedEventLoopGroup.singleton.next()))
        let token = try #require(store.webSocketToken(flowID: id))
        handle.offer(ByteBuffer(bytes: headerOnly ? [0x81] : [0x81, 2, 65]), direction: .serverToClient)
        handle.transportEnded(direction: .serverToClient)
        for _ in 0..<10 { handle.offer(wsFrame([66], masked: true), direction: .clientToServer) }
        await progress.wait(11)
        let rows = try #require(store.webSocketPage(token: token, after: nil, limit: 20)?.rows)
        #expect(rows.count == 11 && rows[0].completedAt == nil && rows[0].integrity == .incompleteTransport)
        #expect(rows.dropFirst().allSatisfy { $0.completedAt != nil })
        #expect(store.webSocketSummary(token: token)?.lifecycle == .open)
        handle.transportEnded(direction: .clientToServer); await coordinator.shutdown()
        #expect(store.webSocketSummary(token: token)?.lifecycle == .transportEndedWithoutClose)
    }
    @Test(arguments: ["wire", "expanded", "working", "native"])
    func resourceLimitStopsOnlyAffectedDirection(kind: String) async throws {
        var limits = WebSocketLimits()
        if kind == "wire" { limits.messageWireBytes = 2 }
        if kind == "expanded" { limits.messageExpandedBytes = 2 }
        let store = observationStore(limits), take = WSBarrier(), progress = WSProgress()
        let coordinator = WebSocketCaptureCoordinator(store: store, hooks: .init(afterTake: { await take.enter() }, afterChunk: { await progress.advance() }))
        var heads = observationHeads()
        if kind == "native" {
            heads.0.headers.add(name: "Sec-WebSocket-Extensions", value: "permessage-deflate")
            heads.1.headers.add(name: "Sec-WebSocket-Extensions", value: "permessage-deflate")
        }
        let id = observationFlow(store)
        let handle = try #require(coordinator.begin(flowID: id, request: heads.0, response: heads.1, eventLoop: MultiThreadedEventLoopGroup.singleton.next()))
        let token = try #require(store.webSocketToken(flowID: id))
        handle.offer(wsFrame(kind == "native" ? Array(WebSocketCompressionVectors.bfinal) : [65, 66, 67], compressed: kind == "native"), direction: .serverToClient)
        await take.wait()
        var blocker: WebSocketReservation?
        if kind == "working" || kind == "native" {
            let category: WebSocketMemoryCategory = kind == "working" ? .working : .native
            let cap = kind == "working" ? limits.workingBytes : limits.nativeBytes
            blocker = store.webSocketBudget.reserve(category: category, bytes: cap - store.webSocketBudget.usedBytes(category: category))
        }
        await take.release(); await progress.wait(1); blocker = nil
        handle.offer(wsFrame([90], masked: true), direction: .clientToServer); await progress.wait(2)
        #expect(store.webSocketSummary(token: token)?.serverToClient.capture == .contentStoppedUntilReconnect)
        let rows = try #require(store.webSocketPage(token: token, after: nil, limit: 10)?.rows)
        let healthy = try #require(rows.last { $0.direction == .clientToServer })
        #expect(store.webSocketPayload(token: token, eventID: healthy.id, kind: .application, maxBytes: 10)?.bytes == Data([90]))
        await coordinator.shutdown(); _ = consume blocker
    }
}

extension WebSocketObservationTests {
    @Test func completeEmptyCloseHandshakeKeepsExactCountersThroughNaturalJoin() async throws {
        let store = observationStore(), cleanup = WSBarrier()
        let owner = WebSocketCaptureCoordinator(store: store, hooks: .init(beforeCleanup: { await cleanup.enter() }))
        let heads = observationHeads(), id = observationFlow(store)
        let handle = try #require(owner.begin(flowID: id, request: heads.0, response: heads.1, eventLoop: MultiThreadedEventLoopGroup.singleton.next()))
        let token = try #require(store.webSocketToken(flowID: id))
        handle.offer(wsFrame([], opcode: 8, masked: true), direction: .clientToServer)
        handle.offer(wsFrame([], opcode: 8), direction: .serverToClient)
        handle.transportEnded(direction: .clientToServer); handle.transportEnded(direction: .serverToClient)
        await cleanup.wait(); await cleanup.release(); await owner.shutdown()
        let summary = try #require(store.webSocketSummary(token: token))
        #expect(summary.lifecycle == .transportClosed)
        #expect(summary.clientToServer.closeCode == nil && summary.serverToClient.closeCode == nil)
        #expect(summary.clientToServer.wireBytes == 6 && summary.serverToClient.wireBytes == 2)
        #expect(summary.clientToServer.applicationBytes == 0 && summary.serverToClient.applicationBytes == 0)
        #expect(!summary.lowerBound)
        #expect(summary.clientToServer.diagnostic == nil && summary.serverToClient.diagnostic == nil)
    }
}

extension WebSocketObservationTests {
    @Test func offerOwnsIndependentBytesAndTruncationDoesNotInvalidateWholeText() async throws {
        var limits = WebSocketLimits(); limits.decodedPrefixBytes = 2; limits.wirePrefixBytes = 1
        let store = observationStore(limits), taken = WSBarrier(), progress = WSProgress()
        let owner = WebSocketCaptureCoordinator(store: store, hooks: .init(afterTake: { await taken.enter() }, afterChunk: { await progress.advance() }))
        let heads = observationHeads(), id = observationFlow(store)
        let handle = try #require(owner.begin(flowID: id, request: heads.0, response: heads.1, eventLoop: MultiThreadedEventLoopGroup.singleton.next()))
        let token = try #require(store.webSocketToken(flowID: id))
        var buffer = wsFrame([0xe4, 0xb8, 0xad])
        handle.offer(buffer, direction: .serverToClient); await taken.wait()
        buffer.setBytes([0xff, 0xff, 0xff], at: 2)
        await taken.release(); await progress.wait(1)
        let row = try #require(store.webSocketPage(token: token, after: nil, limit: 10)?.rows.first)
        #expect(row.integrity == .captureTruncated && row.utf8 == .valid && row.decodedBytes == 3)
        #expect(store.webSocketPayload(token: token, eventID: row.id, kind: .application, maxBytes: 10)?.bytes == Data([0xe4, 0xb8]))
        #expect(store.webSocketPayload(token: token, eventID: row.id, kind: .wirePayload, maxBytes: 10)?.bytes == Data([0xe4]))
        #expect(store.webSocketBudget.usedBytes(category: .retained) == 3)
        await owner.shutdown()
    }
    @Test func abandonedPrefixCanBeEvictedAndNewFlowAdmittedWhileOldRelayRemainsOpen() async throws {
        var limits = WebSocketLimits(); limits.observingSessions = 1; limits.storeEvents = 1
        let store = observationStore(limits), progress = WSProgress()
        let owner = WebSocketCaptureCoordinator(store: store, hooks: .init(afterChunk: { await progress.advance() }))
        let heads = observationHeads(), id = observationFlow(store)
        let handle = try #require(owner.begin(flowID: id, request: heads.0, response: heads.1, eventLoop: MultiThreadedEventLoopGroup.singleton.next()))
        let token = try #require(store.webSocketToken(flowID: id))
        handle.offer(ByteBuffer(bytes: [0x81, 2, 65]), direction: .serverToClient); await progress.wait(1)
        handle.cancel(); await owner.shutdown()
        let old = try #require(store.webSocketPage(token: token, after: nil, limit: 10)?.rows.first)
        #expect(old.captureAbandoned && old.completedAt == nil)
        #expect(store.webSocketSummary(token: token)?.lifecycle == .open)
        let next = WebSocketCaptureCoordinator(store: store, hooks: .init(afterChunk: { await progress.advance() }))
        let secondID = observationFlow(store)
        let second = try #require(next.begin(flowID: secondID, request: heads.0, response: heads.1, eventLoop: MultiThreadedEventLoopGroup.singleton.next()))
        second.offer(wsFrame([66]), direction: .serverToClient); await progress.wait(2)
        #expect(store.webSocketPage(token: token, after: nil, limit: 10)?.rows.isEmpty == true)
        #expect(store.webSocketPayload(token: token, eventID: old.id, kind: .application, maxBytes: 10) == nil)
        handle.offer(wsFrame([67]), direction: .serverToClient)
        #expect(store.webSocketSummary(token: token)?.serverToClient.wireBytes == 6)
        await next.shutdown()
    }
}

extension WebSocketObservationTests {
    @Test(arguments: [false, true])
    func overlappingDataHeaderPreservesOriginalIncompletePrefix(split: Bool) async throws {
        let store = observationStore(), progress = WSProgress()
        let owner = WebSocketCaptureCoordinator(store: store, hooks: .init(afterChunk: { await progress.advance() }))
        let heads = observationHeads(), id = observationFlow(store)
        let handle = try #require(owner.begin(flowID: id, request: heads.0, response: heads.1, eventLoop: MultiThreadedEventLoopGroup.singleton.next()))
        let token = try #require(store.webSocketToken(flowID: id))
        handle.offer(ByteBuffer(bytes: [0x01, 0x01, 0x41]), direction: .serverToClient)
        await progress.wait(1)
        if split {
            handle.offer(ByteBuffer(bytes: [0x81]), direction: .serverToClient)
            await progress.wait(2)
            #expect(store.webSocketPage(token: token, after: nil, limit: 10)?.rows.count == 2)
            #expect(store.webSocketPayload(token: token, eventID: 1, kind: .application, maxBytes: 10) == nil)
            handle.offer(ByteBuffer(bytes: [0x00]), direction: .serverToClient)
        } else { handle.offer(ByteBuffer(bytes: [0x81, 0x00]), direction: .serverToClient) }
        await progress.wait(split ? 3 : 2)
        let rows = try #require(store.webSocketPage(token: token, after: nil, limit: 10)?.rows)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.captureAbandoned && $0.completedAt == nil && $0.integrity == .invalid })
        #expect(rows.allSatisfy { $0.diagnostics.contains { $0.code == "overlappingDataMessage" } })
        for kind in [WebSocketPayloadKind.application, .wirePayload] {
            #expect(store.webSocketPayload(token: token, eventID: 1, kind: kind, maxBytes: 10)?.bytes == Data([0x41]))
        }
        #expect(store.webSocketBudget.usedBytes(category: .working) == 32_768)
        handle.offer(wsFrame([0x42], masked: true), direction: .clientToServer)
        await progress.wait(split ? 4 : 3)
        #expect(store.webSocketPayload(token: token, eventID: 3, kind: .application, maxBytes: 10)?.bytes == Data([0x42]))
        #expect(owner.activeWorkerCount == 1)
        await owner.shutdown()
        #expect(store.webSocketBudget.usedBytes(category: .working) == 0)
    }

    @Test(arguments: [false, true])
    func splitInputTimesExcludeDelayedWorkerClock(splitHeader: Bool) async throws {
        let store = observationStore(), take = WSBarrier(), progress = WSProgress()
        let time = OSAllocatedUnfairLock(initialState: (wall: Date(timeIntervalSince1970: 100), monotonic: UInt64(1000)))
        let clock = WebSocketObservationClock(wallNow: { time.withLock { $0.wall } }, monotonicNow: { time.withLock { $0.monotonic } })
        let owner = WebSocketCaptureCoordinator(store: store, clock: clock, hooks: .init(afterTake: { await take.enter() }, afterChunk: { await progress.advance() }))
        let heads = observationHeads(), id = observationFlow(store)
        let handle = try #require(owner.begin(flowID: id, request: heads.0, response: heads.1, eventLoop: MultiThreadedEventLoopGroup.singleton.next()))
        let token = try #require(store.webSocketToken(flowID: id))
        handle.offer(ByteBuffer(bytes: splitHeader ? [0x81] : [0x81, 0x02, 0x41]), direction: .serverToClient)
        await take.wait()
        time.withLock { $0 = (Date(timeIntervalSince1970: 200), 2000) }
        handle.offer(ByteBuffer(bytes: splitHeader ? [0x02, 0x41, 0x42] : [0x42]), direction: .serverToClient)
        time.withLock { $0 = (Date(timeIntervalSince1970: 900), 9000) }
        await take.release(); await progress.wait(2)
        let row = try #require(store.webSocketPage(token: token, after: nil, limit: 10)?.rows.first)
        #expect(row.firstObservedAt == Date(timeIntervalSince1970: 100))
        #expect(row.monotonicStart == 1000)
        #expect(row.lastObservedAt == Date(timeIntervalSince1970: 200))
        #expect(row.monotonicEnd == 2000)
        #expect(row.completedAt == Date(timeIntervalSince1970: 200))
        #expect(store.webSocketPayload(token: token, eventID: row.id, kind: .application, maxBytes: 10)?.bytes == Data([0x41, 0x42]))
        await owner.shutdown()
    }
}

extension WebSocketObservationTests {
    @Test(.timeLimit(.minutes(1)))
    func admittedBeginRemainsOwnedAcrossShutdownSnapshot() async throws {
        var limits = WebSocketLimits(); limits.observingSessions = 1
        let store = observationStore(limits), publication = WSSynchronousGate(), scanned = WSBarrier(), snapshot = WSBarrier()
        let owner = WebSocketCaptureCoordinator(store: store, hooks: .init(beforeJobPublication: { publication.enter() }, coordinator: { stage in
            if stage == .afterShutdownSnapshot { await snapshot.enter() }
            if stage == .afterSupervisorPass { await scanned.enter() }
        }))
        let heads = observationHeads(), id = observationFlow(store), loop = MultiThreadedEventLoopGroup.singleton.next()
        let result = loop.makePromise(of: ObservationHandle?.self)
        DispatchQueue.global().async {
            result.succeed(owner.begin(flowID: id, request: heads.0, response: heads.1, eventLoop: loop))
        }
        let reached = publication.wait(timeout: 2)
        #expect(reached)
        let done = OSAllocatedUnfairLock(initialState: false)
        let shutdown = Task { await owner.shutdown(); done.withLock { $0 = true } }
        await snapshot.wait(); await snapshot.release(); await scanned.wait()
        #expect(owner.activeWorkerCount == 1)
        #expect(!done.withLock { $0 })
        #expect(store.webSocketBudget.usedBytes(category: .working) == 32_768)
        #expect(owner.begin(flowID: observationFlow(store), request: heads.0, response: heads.1, eventLoop: loop) == nil)
        await scanned.release(); publication.release()
        let handle = try #require(try await result.futureResult.get())
        await shutdown.value
        #expect(done.withLock { $0 } && owner.activeWorkerCount == 0)
        for category in [WebSocketMemoryCategory.working, .native, .mailbox] {
            #expect(store.webSocketBudget.usedBytes(category: category) == 0)
        }
        store.clear()
        #expect(store.webSocketBudget.usedBytes(category: .metadata) == 512)
        withExtendedLifetime(handle) {}
    }

    @Test(.timeLimit(.minutes(1)))
    func completionSignalBeforeTaskPublicationStillRequiresActualTaskReturn() async throws {
        var limits = WebSocketLimits(); limits.observingSessions = 1
        let store = observationStore(limits), publication = WSBarrier(), signalled = WSBarrier(), joining = WSBarrier(), snapshot = WSBarrier()
        let owner = WebSocketCaptureCoordinator(store: store, hooks: .init(coordinator: { stage in
            switch stage {
            case .beforeTaskPublication: await signalled.wait(); await publication.enter()
            case .afterCompletionSignal: await signalled.enter()
            case .beforeWorkerJoin: await joining.enter()
            case .afterShutdownSnapshot: await snapshot.enter()
            default: break
            }
        }))
        let heads = observationHeads(), id = observationFlow(store), loop = MultiThreadedEventLoopGroup.singleton.next()
        let handle = try #require(owner.begin(flowID: id, request: heads.0, response: heads.1, eventLoop: loop))
        handle.cancel()
        await publication.wait() // Real worker signalled completion, but its Task is still a local owner.
        #expect(owner.activeWorkerCount == 1)
        #expect(store.webSocketBudget.usedBytes(category: .working) == 0)
        let second = observationFlow(store)
        let fallback = try #require(owner.begin(flowID: second, request: heads.0, response: heads.1, eventLoop: loop))
        let token = try #require(store.webSocketToken(flowID: second))
        #expect(store.webSocketSummary(token: token)?.clientToServer.capture == .metadataOnly)
        await publication.release(); await joining.wait()
        let done = OSAllocatedUnfairLock(initialState: false)
        let shutdown = Task { await owner.shutdown(); done.withLock { $0 = true } }
        await snapshot.wait(); await snapshot.release()
        #expect(owner.activeWorkerCount == 1 && !done.withLock { $0 })
        #expect(store.webSocketBudget.usedBytes(category: .metadata) >= 2048 + 512 * 2)
        await joining.release() // Supervisor now awaits the still-held actual worker Task.value.
        await signalled.release(); await shutdown.value
        #expect(owner.activeWorkerCount == 0 && done.withLock { $0 })
        for category in [WebSocketMemoryCategory.working, .native, .mailbox] {
            #expect(store.webSocketBudget.usedBytes(category: category) == 0)
        }
        store.clear()
        #expect(store.webSocketBudget.usedBytes(category: .metadata) == 1024)
        withExtendedLifetime((handle, fallback)) {}
    }
}
