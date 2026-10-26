import Foundation
import Testing
import os
@testable import FlowStore

@Suite struct WebSocketEpochTests {
    @Test func preparedHandoffEndsProducerRevokeAuthorityForBothPayloads() throws {
        let store = wsStore(); let token = try wsSession(store)
        let stamp = try #require(store.webSocketCaptureStamp(token: token))
        let app = try #require(store.makeWebSocketAccumulator(token: token, eventID: 1, epoch: stamp.epoch, kind: .application))
        let wire = try #require(store.makeWebSocketAccumulator(token: token, eventID: 1, epoch: stamp.epoch, kind: .wirePayload))
        #expect(app.append(Data([1, 2, 3]), expectedEpoch: stamp.epoch))
        #expect(wire.append(Data([4, 5]), expectedEpoch: stamp.epoch))
        let row = WebSocketEventMetadata(id: 1, order: .init(ingressSequence: stamp.ingressSequence, offset: 0), direction: .clientToServer, kind: .binary)
        let result = store.publishWebSocket(.init(metadata: row, stamp: stamp,
            application: app.take(kind: .application, complete: false, truncated: false),
            wirePayload: wire.take(kind: .wirePayload, complete: false, truncated: false)), token: token, captureEpoch: stamp.epoch) { stage in
            if stage == .prepared {
                app.revoke(); wire.revoke()
                #expect(store.webSocketBudget.usedBytes(category: .retained) == 5)
                #expect(store.webSocketPage(token: token, after: nil, limit: 10)?.rows.isEmpty == true)
            }
        }
        #expect(result == .accepted)
        #expect(store.webSocketPage(token: token, after: nil, limit: 10)?.rows.first?.retainedBytes == 5)
        #expect(store.webSocketPayload(token: token, eventID: 1, kind: .application, maxBytes: 3)?.bytes == Data([1, 2, 3]))
        #expect(store.webSocketPayload(token: token, eventID: 1, kind: .wirePayload, maxBytes: 2)?.bytes == Data([4, 5]))
        #expect(store.webSocketBudget.usedBytes(category: .retained) == 5)
        store.clear()
        #expect(store.webSocketBudget.usedBytes(category: .retained) == 0)
    }

    @Test(arguments: [false, true])
    func producerRevokeBeforeHandoffRejectsWithoutFalseEmptyRow(retainedFirst: Bool) throws {
        let store = wsStore(); let token = try wsSession(store)
        let baseline = store.webSocketBudget.usedBytes(category: .metadata)
        func attempt() throws -> StoreAcceptance {
            let stamp = try #require(store.webSocketCaptureStamp(token: token))
            let cell = try #require(store.makeWebSocketAccumulator(token: token, eventID: 1, epoch: stamp.epoch, kind: .application))
            #expect(cell.append(Data([1, 2, 3]), expectedEpoch: stamp.epoch))
            guard let payload = cell.take(kind: .application, complete: true, truncated: false) else { Issue.record("missing payload"); return .revoked }
            func cancelAndPublish(_ value: consuming WebSocketOwnedPayload) -> StoreAcceptance {
                cell.revoke()
                let row = WebSocketEventMetadata(id: 1, order: .init(ingressSequence: stamp.ingressSequence, offset: 0), direction: .clientToServer, kind: .text)
                return store.publishWebSocket(.init(metadata: row, stamp: stamp, application: value), token: token, captureEpoch: stamp.epoch)
            }
            if retainedFirst {
                guard let retained = store.webSocketBudget.transferToRetained(payload) else { Issue.record("missing retained transfer"); return .revoked }
                return cancelAndPublish(retained)
            }
            return cancelAndPublish(payload)
        }
        #expect(try attempt() == .captureBudgetExhausted)
        #expect(store.webSocketPage(token: token, after: nil, limit: 10)?.rows.isEmpty == true)
        #expect(store.webSocketPayload(token: token, eventID: 1, kind: .application, maxBytes: 3) == nil)
        #expect(store.webSocketBudget.usedBytes(category: .retained) == 0)
        #expect(store.webSocketBudget.usedBytes(category: .working) == 32_768)
        #expect(store.webSocketBudget.usedBytes(category: .metadata) == baseline)
        #expect(try wsPublish(store, token, id: 2) == .accepted)
        #expect(store.webSocketPayload(token: token, eventID: 2, kind: .application, maxBytes: 3)?.bytes == Data())
    }
    @Test(arguments: [false, true], [false, true])
    func publicationHandoffRemainsRevocable(clear: Bool, replacement: Bool) throws {
        let store = wsStore(); let token = try wsSession(store)
        let stamp = try #require(store.webSocketCaptureStamp(token: token))
        func batch(_ appCount: Int, _ wireCount: Int) throws -> WebSocketEventBatch {
            let app = try #require(store.makeWebSocketAccumulator(token: token, eventID: 1, epoch: stamp.epoch, kind: .application))
            let wire = try #require(store.makeWebSocketAccumulator(token: token, eventID: 1, epoch: stamp.epoch, kind: .wirePayload))
            #expect(app.append(Data(repeating: 65, count: appCount), expectedEpoch: stamp.epoch))
            #expect(wire.append(Data(repeating: 66, count: wireCount), expectedEpoch: stamp.epoch))
            let metadata = WebSocketEventMetadata(id: 1, order: .init(ingressSequence: stamp.ingressSequence, offset: 0), direction: .clientToServer, kind: .text)
            return .init(metadata: metadata, stamp: stamp, application: app.take(kind: .application, complete: false, truncated: false),
                wirePayload: wire.take(kind: .wirePayload, complete: false, truncated: false))
        }
        if replacement { #expect(store.publishWebSocket(try batch(3, 2), token: token, captureEpoch: stamp.epoch) == .accepted) }
        let ready = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        let result = OSAllocatedUnfairLock(initialState: StoreAcceptance?.none)
        // Build in this closure: noncopyable batch ownership moves directly into real publish.
        DispatchQueue(label: "ws.actual.publication").async {
            defer { done.signal() }
            do {
                let app = try #require(store.makeWebSocketAccumulator(token: token, eventID: 1, epoch: stamp.epoch, kind: .application))
                let wire = try #require(store.makeWebSocketAccumulator(token: token, eventID: 1, epoch: stamp.epoch, kind: .wirePayload))
                #expect(app.append(Data(repeating: 67, count: 7), expectedEpoch: stamp.epoch))
                #expect(wire.append(Data(repeating: 68, count: 11), expectedEpoch: stamp.epoch))
                var row = WebSocketEventMetadata(id: 1, order: .init(ingressSequence: stamp.ingressSequence, offset: 0), direction: .clientToServer, kind: .text)
                if !replacement { row.completedAt = Date() } // Still pending until actual acceptance.
                let batch = WebSocketEventBatch(metadata: row, stamp: stamp,
                    application: app.take(kind: .application, complete: false, truncated: false),
                    wirePayload: wire.take(kind: .wirePayload, complete: false, truncated: false))
                let acceptance = store.publishWebSocket(batch, token: token, captureEpoch: stamp.epoch) { stage in
                    if stage == (replacement ? .accepted : .prepared) {
                        // Reentry proves the barrier runs outside the owner lock.
                        _ = store.webSocketSummary(token: token)
                        ready.signal(); #expect(resume.wait(timeout: .now() + 10) == .success)
                    }
                }
                result.withLock { $0 = acceptance }
            } catch { Issue.record(error); ready.signal() }
        }
        defer { resume.signal() }
        try #require(ready.wait(timeout: .now() + 10) == .success)
        #expect(store.webSocketBudget.usedBytes(category: .retained) == (replacement ? 23 : 18))
        if clear { store.clear() } else { store.setWebSocketRecording(enabled: false, revision: 1) }
        // Check actual charge release while the real publisher is STILL held.
        #expect(store.webSocketBudget.usedBytes(category: .retained) == 0)
        #expect(store.webSocketBudget.usedBytes(category: .working) == (clear ? 0 : 32_768))
        #expect(store.webSocketPayload(token: token, eventID: 1, kind: .application, maxBytes: 20) == nil)
        #expect(store.webSocketPayload(token: token, eventID: 1, kind: .wirePayload, maxBytes: 20) == nil)
        resume.signal(); #expect(done.wait(timeout: .now() + 10) == .success)
        #expect(result.withLock { $0 } == (replacement ? .accepted : (clear ? .revoked : .recordingPausedOrEpochChanged)))
        store.clear()
    }

    @Test func pausedServerDropsDoNotChangeClientCountOrInterval() throws {
        let store = wsStore(); let token = try wsSession(store)
        store.setWebSocketRecording(enabled: false, revision: 1)
        let before = try #require(store.webSocketSummary(token: token))
        let baseline = WebSocketMemoryCategory.allCases.map { store.webSocketBudget.usedBytes(category: $0) }
        store.recordWebSocketState(.droppedEvents(direction: .serverToClient, count: 1), token: token)
        let after = try #require(store.webSocketSummary(token: token))
        #expect(after.serverToClient.droppedEvents == 1)
        #expect(after.clientToServer.droppedEvents == 0)
        #expect(after.pausedIntervals == before.pausedIntervals)
        #expect(store.webSocketPage(token: token, after: nil, limit: 10)?.rows.isEmpty == true)
        #expect(WebSocketMemoryCategory.allCases.map { store.webSocketBudget.usedBytes(category: $0) } == baseline)
    }
    @Test(arguments: [0, 1, 2])
    func producerHeldBeforePublishCannotCrossPauseClearOrEviction(boundary: Int) throws {
        let store = wsStore(maxFlows: 1); let token = try wsSession(store)
        let ready = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        let result = OSAllocatedUnfairLock(initialState: StoreAcceptance?.none)
        DispatchQueue(label: "ws.sealed.producer").async {
            defer { done.signal() }
            guard let stamp = store.webSocketCaptureStamp(token: token),
                  let cell = store.makeWebSocketAccumulator(token: token, eventID: 1, epoch: stamp.epoch, kind: .application) else { ready.signal(); return }
            #expect(cell.append(Data([1,2,3]), expectedEpoch: stamp.epoch))
            guard let payload = cell.take(kind: .application, complete: true, truncated: false),
                  let retained = store.webSocketBudget.transferToRetained(payload) else { ready.signal(); return }
            let batch = WebSocketEventBatch(metadata: .init(id: 1, order: .init(ingressSequence: stamp.ingressSequence, offset: 0), direction: .clientToServer, kind: .text), stamp: stamp, application: retained)
            ready.signal()
            #expect(resume.wait(timeout: .now() + 10) == .success)
            let acceptance = store.publishWebSocket(batch, token: token, captureEpoch: stamp.epoch)
            result.withLock { $0 = acceptance }
        }
        let entered = ready.wait(timeout: .now() + 10)
        defer { resume.signal() }
        try #require(entered == .success)
        #expect(store.webSocketBudget.usedBytes(category: .retained) == 3)
        if boundary == 1 { store.clear() }
        else if boundary == 2 { _ = try wsSession(store) }
        else { store.setWebSocketRecording(enabled: false, revision: 1); store.setWebSocketRecording(enabled: true, revision: 2) }
        #expect(store.webSocketBudget.usedBytes(category: .retained) == 0)
        resume.signal()
        #expect(done.wait(timeout: .now() + 10) == .success)
        #expect(result.withLock { $0 } == (boundary == 0 ? .recordingPausedOrEpochChanged : .revoked))
        #expect(store.webSocketPayload(token: token, eventID: 1, kind: .application, maxBytes: 1) == nil)
    }
    @Test(arguments: [WebSocketDirection.clientToServer, .serverToClient])
    func directionalDroppedCountsSaturateWithoutRowsOrDuplicateIntervals(direction: WebSocketDirection) throws {
        let store = wsStore(); let token = try wsSession(store)
        store.setWebSocketRecording(enabled: false, revision: 1)
        let before = try #require(store.webSocketSummary(token: token))
        let baseline = WebSocketMemoryCategory.allCases.map { store.webSocketBudget.usedBytes(category: $0) }
        let other: WebSocketDirection = direction == .clientToServer ? .serverToClient : .clientToServer
        store.recordWebSocketState(.droppedEvents(direction: direction, count: .max), token: token)
        #expect(store.webSocketSummary(token: token)?.lowerBound == false)
        store.recordWebSocketState(.droppedEvents(direction: direction, count: 1), token: token)
        var summary = try #require(store.webSocketSummary(token: token))
        #expect(summary[direction].droppedEvents == .max)
        #expect(summary[other].droppedEvents == 0)
        #expect(summary.lowerBound)
        store.recordWebSocketState(.droppedEvents(direction: other, count: 2), token: token)
        summary = try #require(store.webSocketSummary(token: token))
        #expect(summary[direction].droppedEvents == .max)
        #expect(summary[other].droppedEvents == 2)
        #expect(summary.pausedIntervals == before.pausedIntervals)
        let end = Date()
        store.recordWebSocketState(.pausedInterval(start: before.pausedIntervals.firstStartedAt!, end: end), token: token)
        summary = try #require(store.webSocketSummary(token: token))
        #expect(summary.pausedIntervals.totalCount == 1)
        #expect(summary.pausedIntervals.currentStartedAt == nil)
        #expect(summary.pausedIntervals.lastEndedAt == end)
        #expect(summary[direction].droppedEvents == .max && summary[other].droppedEvents == 2)
        #expect(store.webSocketPage(token: token, after: nil, limit: 10)?.rows.isEmpty == true)
        #expect(WebSocketMemoryCategory.allCases.map { store.webSocketBudget.usedBytes(category: $0) } == baseline)
    }

    @Test func opaquePauseCannotReopenThroughMetadataPath() throws {
        let store = wsStore()
        let flow = store.begin { Flow(id: $0, scheme: "http", method: "GET", host: "synthetic.test", port: 80, path: "/") }
        let token = try #require(store.beginWebSocket(flowID: flow, handshake: .init(assessment: .opaqueExtension)))
        store.setWebSocketRecording(enabled: false, revision: 1)
        store.setWebSocketRecording(enabled: true, revision: 2)
        store.recordWebSocketState(.capture(direction: .clientToServer, state: .observing, diagnostic: nil), token: token)
        #expect(store.webSocketSummary(token: token)?.clientToServer.capture == .opaquePausedUntilReconnect)
        #expect(try wsPublish(store, token, id: 1) == .captureBudgetExhausted)
    }
    @Test func eventOrderMustMatchItsMessageAdmissionStamp() throws {
        let store = wsStore(); let token = try wsSession(store)
        let stamp = try #require(store.webSocketCaptureStamp(token: token))
        let batch = WebSocketEventBatch(metadata: .init(id: 1, order: .init(ingressSequence: stamp.ingressSequence + 1, offset: 0), direction: .clientToServer, kind: .text), stamp: stamp)
        #expect(store.publishWebSocket(batch, token: token, captureEpoch: stamp.epoch) == .recordingPausedOrEpochChanged)
        #expect(store.webSocketPage(token: token, after: nil, limit: 1)?.rows.isEmpty == true)
    }

    @Test func pauseRevokesActiveWithoutNextReadAndQuickResumeRejectsOldEpoch() throws {
        let store = wsStore(); let token = try wsSession(store)
        #expect(try wsPublish(store, token, id: 1, bytes: Data([1]), complete: true) == .accepted)
        #expect(try wsPublish(store, token, id: 2, bytes: Data([2]), complete: false) == .accepted)
        let old = try #require(store.webSocketCaptureStamp(token: token))
        let handle = try #require(store.makeWebSocketAccumulator(token: token, eventID: 3, epoch: old.epoch, kind: .application))
        #expect(handle.append(Data([3]), expectedEpoch: old.epoch))
        let oldBatch = WebSocketEventBatch(metadata: .init(id: 3, order: .init(ingressSequence: old.ingressSequence, offset: 0), direction: .clientToServer, kind: .text), stamp: old, application: handle.take(kind: .application, complete: true, truncated: false))
        store.setWebSocketRecording(enabled: false, revision: 1)
        #expect(store.webSocketPayload(token: token, eventID: 2, kind: .application, maxBytes: 1) == nil)
        #expect(store.webSocketPage(token: token, after: nil, limit: 10)?.rows.last?.integrity == .partialPaused)
        #expect(store.webSocketBudget.usedBytes(category: .retained) == 1)
        #expect(store.webSocketBudget.usedBytes(category: .working) == 32_768)
        #expect(!handle.append(Data([4]), expectedEpoch: old.epoch))
        store.setWebSocketRecording(enabled: true, revision: 2)
        #expect(store.publishWebSocket(oldBatch, token: token, captureEpoch: old.epoch) == .recordingPausedOrEpochChanged)
        #expect(store.webSocketSummary(token: token)?.clientToServer.capture == .resumePendingBoundary)
        #expect(try wsPublish(store, token, id: 4, bytes: Data([4])) == .accepted)
        store.setWebSocketRecording(enabled: false, revision: 1)
        #expect(store.webSocketRecordingState().enabled)
    }
    @Test func clearAndFlowEvictionRevokeAtomicallyAndCallbacksReenter() throws {
        let store = wsStore(maxFlows: 1); let token = try wsSession(store)
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let registered = store.registerWebSocketCancellation(token: token) {
            #expect(store.webSocketToken(flowID: token.flowID) == nil)
            _ = store.allFlows()
            cancelled.withLock { $0 = true }
        }
        #expect(registered)
        let stamp = try #require(store.webSocketCaptureStamp(token: token))
        let batch = WebSocketEventBatch(metadata: .init(id: 1, order: .init(ingressSequence: 1, offset: 0), direction: .clientToServer, kind: .text), stamp: stamp)
        let next = try wsSession(store)
        #expect(cancelled.withLock { $0 })
        #expect(next.generation == token.generation)
        #expect(store.publishWebSocket(batch, token: token, captureEpoch: stamp.epoch) == .revoked)
        store.clear()
        let third = try wsSession(store)
        #expect(third.generation > token.generation)
        #expect(store.flow(token.flowID) == nil)
    }
    @Test func saturatingCountsAndStoppedCaptureSurviveResume() throws {
        let store = wsStore(); let token = try wsSession(store)
        store.recordWebSocketState(.observedBytes(direction: .clientToServer, wire: .max, application: .max, lowerBound: false), token: token)
        store.recordWebSocketState(.observedBytes(direction: .clientToServer, wire: 1, application: 1, lowerBound: false), token: token)
        store.recordWebSocketState(.capture(direction: .clientToServer, state: .contentStoppedUntilReconnect, diagnostic: nil), token: token)
        store.setWebSocketRecording(enabled: false, revision: 1); store.setWebSocketRecording(enabled: true, revision: 2)
        let summary = try #require(store.webSocketSummary(token: token))
        #expect(summary.clientToServer.wireBytes == .max && summary.lowerBound)
        #expect(summary.clientToServer.capture == .contentStoppedUntilReconnect)
    }
    @Test func appendRacingPauseCannotRetainOldBytes() throws {
        let store = wsStore(); let token = try wsSession(store)
        let stamp = try #require(store.webSocketCaptureStamp(token: token))
        let handle = try #require(store.makeWebSocketAccumulator(token: token, eventID: 1, epoch: stamp.epoch, kind: .application))
        DispatchQueue.concurrentPerform(iterations: 32) { index in
            if index == 16 { store.setWebSocketRecording(enabled: false, revision: 1) }
            else { _ = handle.append(Data(repeating: 1, count: 1024), expectedEpoch: stamp.epoch) }
        }
        #expect(store.webSocketBudget.usedBytes(category: .working) == 32_768)
        #expect(!handle.append(Data([1]), expectedEpoch: stamp.epoch))
    }
    @Test func invalidationsBoundedAndGapResync() async throws {
        let store = wsStore(); let stream = store.webSocketChanges(); var iterator = stream.makeAsyncIterator()
        let token = try wsSession(store)
        for revision in 1...100 {
            store.setWebSocketRecording(enabled: revision.isMultiple(of: 2), revision: UInt64(revision))
            store.flushWebSocketChanges()
        }
        let latest = try #require(await iterator.next())
        let page = try #require(store.webSocketPage(token: token, after: nil, limit: 1))
        #expect(latest.revision == page.revision)
        #expect(latest.revision > 100)
        #expect(store.webSocketIsCurrent(token: token, revision: page.revision))
    }
}
