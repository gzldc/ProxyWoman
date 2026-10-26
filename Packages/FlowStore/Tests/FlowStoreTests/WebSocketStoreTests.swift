import Foundation
import Testing
import os
@testable import FlowStore

func wsStore(_ limits: WebSocketLimits = .init(), maxFlows: Int = 1000) -> FlowStore {
    FlowStore(bodyDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
              maxFlows: maxFlows, webSocketLimits: limits)
}
func wsSession(_ store: FlowStore, content: Bool = true) throws -> WebSocketSessionToken {
    let id = store.begin { Flow(id: $0, scheme: "https", method: "GET", host: "synthetic.test", port: 443, path: "/ws") }
    return try #require(store.beginWebSocket(flowID: id, handshake: WebSocketHandshake(), contentAllowed: content))
}
func wsPublish(_ store: FlowStore, _ token: WebSocketSessionToken, id: UInt64,
               bytes: Data = Data(), complete: Bool = true) throws -> StoreAcceptance {
    let stamp = try #require(store.webSocketCaptureStamp(token: token))
    let handle = try #require(store.makeWebSocketAccumulator(token: token, eventID: id, epoch: stamp.epoch, kind: .application))
    #expect(handle.append(bytes, expectedEpoch: stamp.epoch))
    var metadata = WebSocketEventMetadata(id: id, order: .init(ingressSequence: stamp.ingressSequence, offset: 0), direction: .clientToServer, kind: .text)
    metadata.completedAt = complete ? Date() : nil
    metadata.decodedBytes = UInt64(bytes.count)
    let batch = WebSocketEventBatch(metadata: metadata, stamp: stamp, application: handle.take(kind: .application, complete: complete, truncated: false))
    return store.publishWebSocket(batch, token: token, captureEpoch: stamp.epoch)
}

@Suite struct WebSocketStoreTests {
    @Test(arguments: [false, true])
    func consumedPayloadRejectsOldHandleRevocationWithoutPhantomCapacity(completed: Bool) throws {
        var limits = WebSocketLimits(); limits.sessionPayloadBytes = 3
        let store = wsStore(limits); let token = try wsSession(store)
        let stamp = try #require(store.webSocketCaptureStamp(token: token))
        let handle = try #require(store.makeWebSocketAccumulator(token: token, eventID: 1, epoch: stamp.epoch, kind: .application))
        #expect(handle.append(Data([1, 2, 3]), expectedEpoch: stamp.epoch))
        var row = WebSocketEventMetadata(id: 1, order: .init(ingressSequence: stamp.ingressSequence, offset: 0), direction: .clientToServer, kind: .text)
        row.completedAt = completed ? Date() : nil
        #expect(store.publishWebSocket(.init(metadata: row, stamp: stamp,
            application: handle.take(kind: .application, complete: completed, truncated: false)), token: token, captureEpoch: stamp.epoch) == .accepted)
        let before = try #require(store.webSocketPage(token: token, after: nil, limit: 10))
        handle.revoke(); handle.revoke() // Producer cleanup after its owned payload was consumed.
        let after = try #require(store.webSocketPage(token: token, after: nil, limit: 10))
        #expect(after.rows == before.rows && after.revision == before.revision)
        #expect(after.rows.first?.retainedBytes == 3)
        #expect(store.webSocketBudget.usedBytes(category: .retained) == 3)
        #expect(store.webSocketPayload(token: token, eventID: 1, kind: .application, maxBytes: 3)?.bytes == Data([1, 2, 3]))
        if !completed {
            // Valid active bytes really fill this cap; the new capture must still fail.
            #expect(try wsPublish(store, token, id: 2, bytes: Data([4, 5, 6])) == .captureBudgetExhausted)
            store.setWebSocketRecording(enabled: false, revision: 1)
            #expect(store.webSocketBudget.usedBytes(category: .retained) == 0)
            #expect(store.webSocketPayload(token: token, eventID: 1, kind: .application, maxBytes: 3) == nil)
            store.setWebSocketRecording(enabled: true, revision: 2)
        }
        // Pause already released active bytes; completed bytes require actual eviction.
        #expect(try wsPublish(store, token, id: 3, bytes: Data([4, 5, 6])) == .accepted)
        let final = try #require(store.webSocketPage(token: token, after: 0, limit: 10))
        #expect(final.rows.map(\.id) == (completed ? [3] : [1, 3]))
        #expect(final.missingBeforeCursor == completed)
        #expect(final.summary.clientToServer.droppedEvents == (completed ? 1 : 0))
        handle.revoke()
        #expect(store.webSocketPayload(token: token, eventID: 1, kind: .application, maxBytes: 3) == nil)
        #expect(store.webSocketPayload(token: token, eventID: 3, kind: .application, maxBytes: 3)?.bytes == Data([4, 5, 6]))
        #expect(store.webSocketBudget.usedBytes(category: .retained) == 3)
        store.clear()
        #expect(store.webSocketBudget.usedBytes(category: .retained) == 0)
    }
    @Test func captureTerminalPredicateDoesNotInventTransportCompletion() {
        var row = WebSocketEventMetadata(id: 1, order: .init(ingressSequence: 1, offset: 0), direction: .serverToClient, kind: .binary)
        row.integrity = .incompleteTransport
        #expect(!row.isCaptureTerminal)
        row.integrity = .partialPaused
        #expect(row.isCaptureTerminal)
        #expect(row.completedAt == nil)
        row.integrity = .incompleteTransport; row.completedAt = Date()
        #expect(row.isCaptureTerminal)
    }
    @Test func pausedCaptureIsEvictableWithoutInventingMessageCompletion() throws {
        var limits = WebSocketLimits(); limits.sessionEvents = 1
        let store = wsStore(limits); let token = try wsSession(store)
        for id in 1...4 {
            #expect(try wsPublish(store, token, id: UInt64(id), bytes: Data([1]), complete: false) == .accepted)
            store.setWebSocketRecording(enabled: false, revision: UInt64(id * 2 - 1))
            let page = try #require(store.webSocketPage(token: token, after: 0, limit: 10))
            #expect(page.rows.count == 1)
            #expect(page.rows.first?.integrity == .partialPaused)
            #expect(page.rows.first?.completedAt == nil)
            #expect(page.rows.first?.isCaptureTerminal == true)
            #expect(page.rows.first?.retainedBytes == 0)
            #expect(page.summary.clientToServer.droppedEvents == UInt64(id - 1))
            #expect(page.firstAvailableEventID == UInt64(id))
            #expect(page.missingBeforeCursor == (id > 1))
            #expect(store.webSocketSummary(token: token)?.lifecycle == .open)
            store.setWebSocketRecording(enabled: true, revision: UInt64(id * 2))
        }
        #expect(try wsPublish(store, token, id: 5, bytes: Data([2])) == .accepted)
        #expect(store.webSocketPage(token: token, after: 0, limit: 10)?.rows.map(\.id) == [5])
        #expect(store.webSocketSummary(token: token)?.clientToServer.droppedEvents == 4)
    }
    @Test func handshakeDiagnosticByteAndCountBoundariesReleaseRejectedAdmission() throws {
        let boundary = String(repeating: "é", count: 64) // 128 UTF-8 bytes, 64 characters.
        let valid = WebSocketDiagnostic(code: boundary, detail: boundary)
        let invalidLists = [Array(repeating: valid, count: 9),
            [.init(code: boundary + "a", detail: boundary)], [.init(code: boundary, detail: boundary + "a")]]
        for diagnostics in invalidLists {
            let store = wsStore()
            let id = store.begin { Flow(id: $0, scheme: "http", method: "GET", host: "synthetic.test", port: 80, path: "/") }
            #expect(store.beginWebSocket(flowID: id, handshake: .init(diagnostics: diagnostics)) == nil)
            #expect(store.webSocketToken(flowID: id) == nil)
            for category in WebSocketMemoryCategory.allCases { #expect(store.webSocketBudget.usedBytes(category: category) == 0) }
            let token = try #require(store.beginWebSocket(flowID: id, handshake: .init(diagnostics: Array(repeating: valid, count: 8))))
            #expect(store.webSocketSummary(token: token)?.handshake.diagnostics == Array(repeating: valid, count: 8))
            store.clear()
            for category in WebSocketMemoryCategory.allCases { #expect(store.webSocketBudget.usedBytes(category: category) == 0) }
        }
    }

    @Test func eventDiagnosticByteAndCountBoundariesReleaseRejectedPayload() throws {
        let boundary = String(repeating: "é", count: 64)
        let valid = WebSocketDiagnostic(code: boundary, detail: boundary)
        func publish(_ store: FlowStore, _ token: WebSocketSessionToken, id: UInt64,
                     diagnostics: [WebSocketDiagnostic]) throws -> StoreAcceptance {
            let stamp = try #require(store.webSocketCaptureStamp(token: token))
            let handle = try #require(store.makeWebSocketAccumulator(token: token, eventID: id, epoch: stamp.epoch, kind: .application))
            #expect(handle.append(Data([1, 2, 3]), expectedEpoch: stamp.epoch))
            var row = WebSocketEventMetadata(id: id, order: .init(ingressSequence: stamp.ingressSequence, offset: 0), direction: .clientToServer, kind: .text)
            row.diagnostics = diagnostics; row.completedAt = Date()
            return store.publishWebSocket(.init(metadata: row, stamp: stamp,
                application: handle.take(kind: .application, complete: true, truncated: false)), token: token, captureEpoch: stamp.epoch)
        }
        let invalidLists = [Array(repeating: valid, count: 9),
            [.init(code: boundary + "a", detail: boundary)], [.init(code: boundary, detail: boundary + "a")]]
        for diagnostics in invalidLists {
            let store = wsStore(); let token = try wsSession(store)
            #expect(try publish(store, token, id: 1, diagnostics: Array(repeating: valid, count: 8)) == .accepted)
            let baseline = WebSocketMemoryCategory.allCases.map { store.webSocketBudget.usedBytes(category: $0) }
            #expect(try publish(store, token, id: 2, diagnostics: diagnostics) == .captureBudgetExhausted)
            #expect(store.webSocketPage(token: token, after: nil, limit: 10)?.rows.map(\.id) == [1])
            #expect(WebSocketMemoryCategory.allCases.map { store.webSocketBudget.usedBytes(category: $0) } == baseline)
            #expect(store.webSocketPayload(token: token, eventID: 2, kind: .application, maxBytes: 10) == nil)
            store.clear()
            for category in WebSocketMemoryCategory.allCases { #expect(store.webSocketBudget.usedBytes(category: category) == 0) }
        }
    }

    @Test func captureDiagnosticUnicodeByteBoundaryRejectsWithoutChargeGrowth() throws {
        let boundary = String(repeating: "é", count: 64)
        let valid = WebSocketDiagnostic(code: boundary, detail: boundary)
        for invalid in [WebSocketDiagnostic(code: boundary + "a", detail: boundary),
                        WebSocketDiagnostic(code: boundary, detail: boundary + "a")] {
            let store = wsStore(); let token = try wsSession(store)
            store.recordWebSocketState(.capture(direction: .clientToServer, state: .observing, diagnostic: valid), token: token)
            let baseline = WebSocketMemoryCategory.allCases.map { store.webSocketBudget.usedBytes(category: $0) }
            #expect(store.webSocketSummary(token: token)?.clientToServer.diagnostic == valid)
            store.recordWebSocketState(.capture(direction: .clientToServer, state: .contentStoppedUntilReconnect, diagnostic: invalid), token: token)
            #expect(store.webSocketSummary(token: token)?.clientToServer.capture == .observing)
            #expect(store.webSocketSummary(token: token)?.clientToServer.diagnostic == valid)
            #expect(WebSocketMemoryCategory.allCases.map { store.webSocketBudget.usedBytes(category: $0) } == baseline)
            store.clear()
            for category in WebSocketMemoryCategory.allCases { #expect(store.webSocketBudget.usedBytes(category: category) == 0) }
        }
    }
    @Test func defaultContentAdmissionCapsAt128AndMetadataOnlyRemainsBounded() throws {
        let store = wsStore()
        for _ in 0..<128 {
            let token = try wsSession(store)
            #expect(store.webSocketSummary(token: token)?.clientToServer.capture == .observing)
        }
        let last = try wsSession(store)
        #expect(store.webSocketSummary(token: last)?.clientToServer.capture == .metadataOnly)
        #expect(store.webSocketBudget.usedBytes(category: .working) == 4_194_304)
        #expect(store.webSocketBudget.usedBytes(category: .native) == 0)
        store.clear()
        for category in WebSocketMemoryCategory.allCases { #expect(store.webSocketBudget.usedBytes(category: category) == 0) }
    }

    @Test func rejectedBatchReleasesAllOwnershipBeforeReturn() throws {
        var limits = WebSocketLimits(); limits.sessionEvents = 0
        let store = wsStore(limits); let token = try wsSession(store)
        let baseline = store.webSocketBudget.usedBytes(category: .metadata)
        #expect(try wsPublish(store, token, id: 1, bytes: Data([1,2,3])) == .captureBudgetExhausted)
        #expect(store.webSocketBudget.usedBytes(category: .metadata) == baseline)
        #expect(store.webSocketBudget.usedBytes(category: .working) == 32_768)
        #expect(store.webSocketBudget.usedBytes(category: .retained) == 0)
    }
    @Test func sessionPayloadPressureEvictsLocallyBeforeGlobalVictims() throws {
        var limits = WebSocketLimits(); limits.sessionPayloadBytes = 10
        let store = wsStore(limits); let other = try wsSession(store); let target = try wsSession(store)
        #expect(try wsPublish(store, other, id: 1, bytes: Data([9])) == .accepted)
        #expect(try wsPublish(store, target, id: 1, bytes: Data(repeating: 1, count: 6)) == .accepted)
        #expect(try wsPublish(store, target, id: 2, bytes: Data(repeating: 2, count: 6)) == .accepted)
        #expect(store.webSocketPayload(token: other, eventID: 1, kind: .application, maxBytes: 1)?.bytes == Data([9]))
        #expect(store.webSocketPage(token: target, after: 0, limit: 10)?.missingBeforeCursor == true)
    }
    @Test func wireAndDecodedPrefixesAreIndependentAndCloseReleasesScratch() throws {
        var limits = WebSocketLimits(); limits.decodedPrefixBytes = 3; limits.wirePrefixBytes = 2
        let store = wsStore(limits); let token = try wsSession(store)
        let stamp = try #require(store.webSocketCaptureStamp(token: token))
        let app = try #require(store.makeWebSocketAccumulator(token: token, eventID: 1, epoch: stamp.epoch, kind: .application))
        let wire = try #require(store.makeWebSocketAccumulator(token: token, eventID: 1, epoch: stamp.epoch, kind: .wirePayload))
        #expect(app.append(Data([1,2,3,4]), expectedEpoch: stamp.epoch))
        #expect(wire.append(Data([5,6,7]), expectedEpoch: stamp.epoch))
        var row = WebSocketEventMetadata(id: 1, order: .init(ingressSequence: stamp.ingressSequence, offset: 0), direction: .clientToServer, kind: .binary)
        row.completedAt = Date()
        let result = store.publishWebSocket(.init(metadata: row, stamp: stamp,
            application: app.take(kind: .application, complete: true, truncated: false),
            wirePayload: wire.take(kind: .wirePayload, complete: true, truncated: false)), token: token, captureEpoch: stamp.epoch)
        #expect(result == .accepted)
        #expect(store.webSocketBudget.usedBytes(category: .retained) == 5)
        #expect(store.webSocketPayload(token: token, eventID: 1, kind: .application, maxBytes: 10)?.bytes == Data([1,2,3]))
        #expect(store.webSocketPayload(token: token, eventID: 1, kind: .wirePayload, maxBytes: 10)?.truncated == true)
        store.endWebSocket(token: token, transport: .init(direction: .clientToServer, at: Date(), monotonic: 1))
        store.endWebSocket(token: token, transport: .init(direction: .serverToClient, at: Date(), monotonic: 2))
        #expect(store.webSocketBudget.usedBytes(category: .working) == 0)
        #expect(store.webSocketBudget.usedBytes(category: .retained) == 5)
        #expect(store.webSocketSummary(token: token)?.lifecycle == .transportEndedWithoutClose)
        #expect(store.webSocketCaptureStamp(token: token) == nil)
        store.clear()
        #expect(store.webSocketBudget.usedBytes(category: .retained) == 0)
    }
    @Test func stoppingWithExhaustedMetadataStillChangesCaptureState() throws {
        var limits = WebSocketLimits(); limits.metadataBytes = 4224 // canonical default handshake + session + terminal
        let store = wsStore(limits); let token = try wsSession(store)
        store.recordWebSocketState(.capture(direction: .clientToServer, state: .contentStoppedUntilReconnect,
            diagnostic: .init(code: "captureBudgetExhausted")), token: token)
        #expect(store.webSocketSummary(token: token)?.clientToServer.capture == .contentStoppedUntilReconnect)
    }

    @Test func boundedPagesAndEmptyPayload() throws {
        let store = wsStore(); let token = try wsSession(store)
        for id in 1...201 { #expect(try wsPublish(store, token, id: UInt64(id)) == .accepted) }
        let page = try #require(store.webSocketPage(token: token, after: nil, limit: 201))
        #expect(page.rows.count == 200)
        let emptySnapshot = try #require(store.webSocketPayload(token: token, eventID: 1, kind: .application, maxBytes: Int.max))
        #expect(emptySnapshot.bytes.isEmpty)
        #expect(try wsPublish(store, token, id: 202, bytes: Data(repeating: 65, count: 300_000)) == .accepted)
        let first = try #require(store.webSocketPayload(token: token, eventID: 202, kind: .application, maxBytes: Int.max))
        #expect(first.bytes.count == 262_144)
        #expect(first.totalRetainedBytes == 300_000)
        let last = try #require(store.webSocketPayloadChunk(token: token, eventID: 202, kind: .application,
            offset: 262_144, maxBytes: Int.max, expectedRevision: first.revision))
        #expect(last.bytes.count == 37_856)
        #expect(store.webSocketPayloadChunk(token: token, eventID: 202, kind: .application, offset: 0,
            maxBytes: 1, expectedRevision: first.revision + 1) == nil)
        store.clear()
        #expect(store.webSocketPayload(token: token, eventID: 1, kind: .application, maxBytes: 1) == nil)
        #expect(store.webSocketBudget.usedBytes(category: .retained) == 0)
    }
    @Test func completedEvictionKeepsActiveCharges() throws {
        var limits = WebSocketLimits(); limits.sessionEvents = 2; limits.sessionPayloadBytes = 6
        let store = wsStore(limits); let token = try wsSession(store)
        #expect(try wsPublish(store, token, id: 1, bytes: Data([1,2,3]), complete: false) == .accepted)
        #expect(try wsPublish(store, token, id: 2, bytes: Data([4,5,6])) == .accepted)
        #expect(try wsPublish(store, token, id: 3, bytes: Data([7,8,9])) == .accepted)
        let page = try #require(store.webSocketPage(token: token, after: nil, limit: 10))
        #expect(page.rows.map(\.id) == [1,3])
        #expect(page.summary.clientToServer.droppedEvents == 1)
        #expect(store.webSocketBudget.usedBytes(category: .retained) == 6)
        #expect(store.webSocketPayload(token: token, eventID: 2, kind: .application, maxBytes: 10) == nil)
    }
    @Test func globalEvictionAndActiveExhaustion() throws {
        var limits = WebSocketLimits(); limits.storeEvents = 2; limits.retainedBytes = 6
        let store = wsStore(limits); let a = try wsSession(store); let b = try wsSession(store)
        #expect(try wsPublish(store, a, id: 1, bytes: Data([1,2,3])) == .accepted)
        #expect(try wsPublish(store, b, id: 1, bytes: Data([4,5,6]), complete: false) == .accepted)
        #expect(try wsPublish(store, a, id: 2, bytes: Data([7,8,9]), complete: false) == .accepted)
        #expect(store.webSocketPayload(token: a, eventID: 1, kind: .application, maxBytes: 10) == nil)
        #expect(try wsPublish(store, a, id: 3, bytes: Data([1])) == .captureBudgetExhausted)
        #expect(store.webSocketBudget.usedBytes(category: .retained) == 6)
    }
    @Test func zeroPayloadMetadataFloodIsBounded() throws {
        var limits = WebSocketLimits(); limits.metadataBytes = 8192
        let store = wsStore(limits); let token = try wsSession(store)
        var accepted = 0
        for id in 1...100 {
            let stamp = try #require(store.webSocketCaptureStamp(token: token))
            let metadata = WebSocketEventMetadata(id: UInt64(id), order: .init(ingressSequence: stamp.ingressSequence, offset: 0), direction: .clientToServer, kind: .ping)
            if store.publishWebSocket(.init(metadata: metadata, stamp: stamp), token: token, captureEpoch: stamp.epoch) == .accepted { accepted += 1 }
        }
        #expect(accepted > 0 && accepted < 20)
        #expect(store.webSocketBudget.usedBytes(category: .metadata) <= 8192)
        store.clear()
        for category in WebSocketMemoryCategory.allCases { #expect(store.webSocketBudget.usedBytes(category: category) == 0) }
    }
    @Test func metadataOnlyAdmissionNeedsNoWorkerScratch() throws {
        var limits = WebSocketLimits(); limits.observingSessions = 1; limits.metadataBytes = 16_384
        let store = wsStore(limits); let a = try wsSession(store, content: false)
        #expect(store.webSocketSummary(token: a)?.clientToServer.capture == .metadataOnly)
        #expect(store.webSocketBudget.usedBytes(category: .working) == 0)
        let b = try wsSession(store)
        #expect(store.webSocketSummary(token: b)?.clientToServer.capture == .observing)
        let c = try wsSession(store)
        #expect(store.webSocketSummary(token: c)?.clientToServer.capture == .metadataOnly)
        #expect(store.webSocketBudget.usedBytes(category: .working) == 32_768)
        store.clear()
        #expect(store.webSocketBudget.usedBytes(category: .working) == 0)
    }
}

@Suite struct WebSocketObservationReleaseTests {
    @Test func stoppedPrefixIsTerminalWithoutFINAndRemainsPauseRevocable() throws {
        let store = wsStore(); let token = try wsSession(store)
        #expect(try wsPublish(store, token, id: 1, bytes: Data([1, 2]), complete: false) == .accepted)
        store.recordWebSocketState(.capture(direction: .clientToServer, state: .contentStoppedUntilReconnect,
            diagnostic: .init(code: "syntheticStop")), token: token)
        let row = try #require(store.webSocketPage(token: token, after: nil, limit: 1)?.rows.first)
        #expect(row.isCaptureTerminal)
        #expect(row.completedAt == nil)
        #expect(row.integrity == .observationStopped)
        #expect(store.webSocketPayload(token: token, eventID: 1, kind: .application, maxBytes: 10)?.bytes == Data([1, 2]))
        store.setWebSocketRecording(enabled: false, revision: 1)
        #expect(store.webSocketPayload(token: token, eventID: 1, kind: .application, maxBytes: 10) == nil)
    }
    @Test func admittedHandshakeWhilePausedStillReservesDiscardScratch() throws {
        let store = wsStore()
        store.setWebSocketRecording(enabled: false, revision: 1)
        let token = try wsSession(store)
        #expect(store.webSocketSummary(token: token)?.clientToServer.capture == .paused)
        #expect(store.webSocketBudget.usedBytes(category: .working) == 32_768)
    }
}

@Suite struct WebSocketJoinedReleaseTests {
    @Test func unstartedReleaseReturnsCapacityWithoutEOFAndIgnoresStaleToken() throws {
        var limits = WebSocketLimits(); limits.observingSessions = 1
        let store = wsStore(limits); let first = try wsSession(store)
        store.releaseWebSocketObservation(token: first)
        store.releaseWebSocketObservation(token: first)
        #expect(store.webSocketSummary(token: first)?.lifecycle == .open)
        #expect(store.webSocketSummary(token: first)?.closedAt == nil)
        #expect(store.webSocketBudget.usedBytes(category: .working) == 0)
        let second = try wsSession(store)
        #expect(store.webSocketSummary(token: second)?.clientToServer.capture == .observing)
        store.releaseWebSocketObservation(token: .init(flowID: second.flowID, sessionID: first.sessionID, generation: second.generation))
        #expect(store.webSocketBudget.usedBytes(category: .working) == 32_768)
        store.endWebSocket(token: first, transport: .init(direction: .clientToServer, at: Date(), monotonic: 1))
        store.endWebSocket(token: first, transport: .init(direction: .serverToClient, at: Date(), monotonic: 2))
        #expect(store.webSocketSummary(token: first)?.lifecycle == .transportEndedWithoutClose)
    }
    @Test func emptyValidatedCloseHasPresenceWithoutInventedCode() throws {
        let store = wsStore(); let token = try wsSession(store)
        for direction in [WebSocketDirection.clientToServer, .serverToClient] {
            store.recordWebSocketState(.closeFrame(direction: direction, code: nil), token: token)
            store.endWebSocket(token: token, transport: .init(direction: direction, at: Date(), monotonic: 1))
        }
        let summary = try #require(store.webSocketSummary(token: token))
        #expect(summary.clientToServer.completedClose && summary.serverToClient.completedClose)
        #expect(summary.clientToServer.closeCode == nil && summary.serverToClient.closeCode == nil)
        #expect(summary.lifecycle == .transportClosed)
    }
}

@Suite struct WebSocketCanonicalURITests {
    @Test func canonicalURIScalarAndUTF8AreReservedBeforeAdmission() throws {
        func usage(_ uri: String?) throws -> Int {
            let store = wsStore(), id = store.begin { Flow(id: $0, scheme: "http", method: "GET", host: "synthetic.test", port: 80, path: "/") }
            let token = try #require(store.beginWebSocket(flowID: id, handshake: .init(requestURI: uri), contentAllowed: false))
            #expect(store.webSocketSummary(token: token)?.handshake.requestURI == uri)
            return store.webSocketBudget.usedBytes(category: .metadata)
        }
        let historical = try usage(nil), empty = try usage("")
        #expect(empty == historical + 64)
        let uri = String(repeating: "中", count: 64)
        #expect(try usage(uri) == empty + uri.utf8.count * 2)
        var limits = WebSocketLimits(); limits.metadataBytes = empty + uri.utf8.count * 2 - 1
        let store = wsStore(limits), id = store.begin { Flow(id: $0, scheme: "http", method: "GET", host: "synthetic.test", port: 80, path: "/") }
        #expect(store.beginWebSocket(flowID: id, handshake: .init(requestURI: uri), contentAllowed: false) == nil)
        #expect(store.webSocketBudget.usedBytes(category: .metadata) == 0)
        #expect(store.webSocketBudget.usedBytes(category: .working) == 0)
    }
}


extension WebSocketJoinedReleaseTests {
    @Test func releaseDropsCallbackAndRejectsLateRegistrationOutsideOwnerLock() throws {
        let store = wsStore()
        let current = try wsSession(store), callbacks = OSAllocatedUnfairLock(initialState: 0)
        #expect(store.registerWebSocketCancellation(token: current) { callbacks.withLock { $0 += 1 } })
        store.releaseWebSocketObservation(token: current)
        #expect(callbacks.withLock { $0 } == 0)
        let accepted = store.registerWebSocketCancellation(token: current) {
            #expect(store.webSocketSummary(token: current)?.lifecycle == .open)
            store.releaseWebSocketObservation(token: current)
            callbacks.withLock { $0 += 1 }
        }
        #expect(!accepted && callbacks.withLock { $0 } == 1)
        store.clear()
        #expect(callbacks.withLock { $0 } == 1)
    }
}

extension WebSocketJoinedReleaseTests {
    @Test func releasingUnstartedPausedObserverCannotAdvertiseResumeCapability() throws {
        let store = wsStore()
        store.setWebSocketRecording(enabled: false, revision: 1)
        let token = try wsSession(store)
        store.releaseWebSocketObservation(token: token)
        store.setWebSocketRecording(enabled: true, revision: 2)
        #expect(store.webSocketSummary(token: token)?.clientToServer.capture == .contentStoppedUntilReconnect)
        #expect(store.webSocketSummary(token: token)?.serverToClient.capture == .contentStoppedUntilReconnect)
        #expect(store.webSocketSummary(token: token)?.lifecycle == .open)
        #expect(store.webSocketBudget.usedBytes(category: .working) == 0)
    }
}
