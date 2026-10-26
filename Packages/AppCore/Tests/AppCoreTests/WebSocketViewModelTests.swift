import Foundation
import Testing
import Observation
@testable import AppCore
import FlowStore

@MainActor @Suite(.productionChinese) struct WebSocketViewModelTests {
    @Test func boundedFilteringAndSelectionChurn() async throws {
        var limits = WebSocketLimits(); limits.pageRows = 17
        let store = FlowStore(bodyDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), webSocketLimits: limits)
        let flowID = store.begin { Flow(id: $0, scheme: "http", method: "GET", host: "synthetic.test", port: 80, path: "/ws") }
        let token = try #require(store.beginWebSocket(flowID: flowID, handshake: .init()))
        for id in 1...420 { try publish(store, token, UInt64(id), kind: id == 419 ? .ping : .text) }
        let hub = WebSocketInvalidationHub(store: store); defer { hub.stop() }
        let model = WebSocketViewModel(store: store, hub: hub, token: token); defer { model.cancel() }
        model.autoFollow = false
        await model.load(after: nil)
        #expect(model.page.count == 200)
        model.select(eventID: 1); model.select(eventID: 2)
        await model.waitForPreparation()
        #expect(model.selectedID == 2 && model.prepared?.text == "2")
        model.setFilters(directions: [.clientToServer, .serverToClient], kinds: [.ping])
        await model.load(after: nil)
        #expect(model.page.map(\.id) == [419])
        #expect(model.prepared == nil)
        model.cancel()
    }
    @Test func twoViewsShareOneSourceAndClearIsUnavailable() async throws {
        let store = FlowStore(bodyDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let flowID = store.begin { Flow(id: $0, scheme: "http", method: "GET", host: "synthetic.test", port: 80, path: "/ws") }
        let token = try #require(store.beginWebSocket(flowID: flowID, handshake: .init()))
        try publish(store, token, 1, bytes: Data())
        let hub = WebSocketInvalidationHub(store: store); defer { hub.stop() }
        var first = hub.updates().makeAsyncIterator(); var second = hub.updates().makeAsyncIterator()
        let a = WebSocketViewModel(store: store, hub: hub, token: token)
        let b = WebSocketViewModel(store: store, hub: hub, token: token)
        defer { a.cancel(); b.cancel() }
        await a.load(after: nil); await b.load(after: nil)
        a.select(eventID: 1); await a.waitForPreparation()
        #expect(a.prepared?.bytes.isEmpty == true && !a.unavailable)
        let x = await first.next(), y = await second.next()
        #expect(x == y && hub.sourceSubscriptionCount == 1)
        store.clear()
        _ = await first.next(); _ = await second.next()
        await a.load(after: nil); await b.load(after: nil)
        #expect(a.page.isEmpty && b.page.isEmpty && a.prepared == nil && a.unavailable)
    }
    @Test func latestPageRespectsUserScrollAndPendingIsNotEmpty() async throws {
        let store = FlowStore(bodyDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let flowID = store.begin { Flow(id: $0, scheme: "http", method: "GET", host: "synthetic.test", port: 80, path: "/ws") }
        let token = try #require(store.beginWebSocket(flowID: flowID, handshake: .init()))
        for id in 1...230 { try publish(store, token, UInt64(id)) }
        let hub = WebSocketInvalidationHub(store: store); defer { hub.stop() }
        let model = WebSocketViewModel(store: store, hub: hub, token: token); defer { model.cancel() }
        await model.load(after: nil)
        #expect(model.page.count <= 200 && model.page.last?.id == 230)
        model.userDidScroll(); model.select(eventID: 40); await model.waitForPreparation()
        try publish(store, token, 231)
        await model.load(after: nil)
        #expect(!model.autoFollow && model.selectedID == 40)
        model.autoFollow = true; await model.load(after: nil)
        #expect(model.page.last?.id == 231)
    }
    @Test func tenThousandRowsAndSelectedPreviewStayBounded() async throws {
        let store = FlowStore(bodyDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let id = store.begin { Flow(id: $0, scheme: "http", method: "GET", host: "synthetic.test", port: 80, path: "/ws") }
        let token = try #require(store.beginWebSocket(flowID: id, handshake: .init()))
        for id in 1...10_000 { try publish(store, token, UInt64(id), bytes: id == 10_000 ? Data(repeating: 97, count: 300_000) : Data()) }
        let hub = WebSocketInvalidationHub(store: store); defer { hub.stop() }
        let model = WebSocketViewModel(store: store, hub: hub, token: token); defer { model.cancel() }
        await model.load(after: nil); model.select(eventID: 10_000); await model.waitForPreparation()
        #expect(model.page.count == 200 && model.page.first?.id == 9_801)
        #expect(model.prepared?.bytes.count == 262_144 && model.prepared?.json == nil)
        print("Task6 production bound: page=\(model.page.count), selectedBytes=\(model.prepared?.bytes.count ?? -1), hubSources=\(hub.sourceSubscriptionCount)")
    }
    @Test func actualTwoWindowAutomaticRefreshAndTermination() async throws {
        let store = FlowStore(bodyDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let id = store.begin { Flow(id: $0, scheme: "http", method: "GET", host: "synthetic.test", port: 80, path: "/ws") }
        let token = try #require(store.beginWebSocket(flowID: id, handshake: .init()))
        let hub = WebSocketInvalidationHub(store: store); defer { hub.stop() }
        let a = WebSocketViewModel(store: store, hub: hub, token: token), b = WebSocketViewModel(store: store, hub: hub, token: token)
        defer { a.cancel(); b.cancel() }
        try publish(store, token, 1)
        await waitUntil { a.page.count == 1 && b.page.count == 1 }
        for id in 2...9 { try publish(store, token, UInt64(id)) }
        await waitUntil { a.page.count == 9 && b.page.count == 9 }
        #expect(a.revision == b.revision && hub.sourceSubscriptionCount == 1)
        a.cancel()
        await waitUntil { hub.subscriberCount == 1 }
        store.clear()
        await waitUntil { b.unavailable && b.page.isEmpty }
    }
    @Test func stalePreparationCannotPublishAfterSelectionChanges() async throws {
        let store = FlowStore(bodyDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let id = store.begin { Flow(id: $0, scheme: "http", method: "GET", host: "synthetic.test", port: 80, path: "/ws") }
        let token = try #require(store.beginWebSocket(flowID: id, handshake: .init()))
        try publish(store, token, 1); try publish(store, token, 2)
        let hub = WebSocketInvalidationHub(store: store); defer { hub.stop() }
        let model = WebSocketViewModel(store: store, hub: hub, token: token); defer { model.cancel() }
        await model.load(after: nil)
        let started = AsyncStream<Void>.makeStream(), released = AsyncStream<Void>.makeStream()
        model.beforePreparation = {
            started.continuation.yield(())
            for await _ in released.stream { break }
        }
        model.select(eventID: 1)
        var arrived = started.stream.makeAsyncIterator(); _ = await arrived.next()
        model.beforePreparation = nil
        model.select(eventID: 2)
        released.continuation.yield(())
        await model.waitForPreparation()
        #expect(model.selectedID == 2 && model.prepared?.text == "2")
    }
    @Test func pendingCaptureAndPausedStoppedSummaryAreDistinct() async throws {
        let store = FlowStore(bodyDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let id = store.begin { Flow(id: $0, scheme: "http", method: "GET", host: "synthetic.test", port: 80, path: "/ws") }
        let token = try #require(store.beginWebSocket(flowID: id, handshake: .init(assessment: .opaqueExtension)))
        let stamp = try #require(store.webSocketCaptureStamp(token: token))
        var row = WebSocketEventMetadata(id: 1, order: .init(ingressSequence: stamp.ingressSequence, offset: 0), direction: .serverToClient, kind: .opaqueFrame)
        row.integrity = .incompleteTransport
        #expect(store.publishWebSocket(.init(metadata: row, stamp: stamp), token: token, captureEpoch: stamp.epoch) == .accepted)
        let hub = WebSocketInvalidationHub(store: store); defer { hub.stop() }
        let model = WebSocketViewModel(store: store, hub: hub, token: token); defer { model.cancel() }
        await model.load(after: nil); model.select(eventID: 1); await model.waitForPreparation()
        #expect(model.pending && !model.unavailable && model.prepared == nil)
        store.recordWebSocketState(.capture(direction: .clientToServer, state: .contentStoppedUntilReconnect, diagnostic: nil), token: token)
        await model.load(after: nil)
        #expect(model.summary?.clientToServer.capture == .contentStoppedUntilReconnect)
        #expect(model.summary?.lifecycle == .open && model.summary?.handshake.assessment == .opaqueExtension)
        store.setWebSocketRecording(enabled: false, revision: 1)
        await model.load(after: nil)
        #expect(model.unavailable && !model.pending && model.prepared == nil)
        #expect(model.summary?.serverToClient.capture == .paused || model.summary?.serverToClient.capture == .opaquePausedUntilReconnect)
    }
    @Test(arguments: [false, true])
    func disablingFollowPreservesSparseFilteredLateWindowAfterAutomaticUpdate(useToggle: Bool) async throws {
        var limits = WebSocketLimits(); limits.pageRows = 17
        let store = FlowStore(bodyDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), webSocketLimits: limits)
        let id = store.begin { Flow(id: $0, scheme: "http", method: "GET", host: "synthetic.test", port: 80, path: "/ws") }
        let token = try #require(store.beginWebSocket(flowID: id, handshake: .init()))
        for number in 1...650 { try publish(store, token, UInt64(number * 3), kind: number.isMultiple(of: 2) ? .text : .ping) }
        let hub = WebSocketInvalidationHub(store: store); defer { hub.stop() }
        let model = WebSocketViewModel(store: store, hub: hub, token: token); defer { model.cancel() }
        model.setFilters(directions: [.clientToServer], kinds: [.text])
        await model.load(after: nil)
        let shown = model.page.map(\.id)
        #expect(shown.count == 200 && shown.first == 756 && shown.last == 1950)
        model.select(eventID: 1800); await model.waitForPreparation()
        #expect(model.prepared?.text == "1800")
        if useToggle { model.autoFollow = false } else { model.userDidScroll() }
        let revision = model.revision
        try publish(store, token, 2100)
        await waitUntil { model.revision > revision }
        await model.waitForPreparation()
        #expect(model.page.map(\.id) == shown)
        #expect(model.selectedEvent?.id == 1800 && model.prepared?.text == "1800")
        #expect(!model.autoFollow && model.nextCursor == 1950)
        print("Task6 fix1 follow off toggle=\(useToggle), page=\(model.page.first?.id ?? 0)...\(model.page.last?.id ?? 0), selected=\(model.selectedEvent?.id ?? 0), payload=\(model.prepared?.text ?? "nil")")
        await model.load(after: model.nextCursor)
        #expect(model.page.map(\.id) == [2100])
        model.setFilters(directions: [.clientToServer], kinds: [.ping]); await model.load(after: nil)
        #expect(model.page.first?.id == 3 && model.page.count == 200)
    }
    private func waitUntil(_ condition: @escaping @MainActor @Sendable () -> Bool) async {
        while !condition() {
            await withCheckedContinuation { continuation in
                withObservationTracking { _ = condition() } onChange: { continuation.resume() }
            }
        }
    }
    private func publish(_ store: FlowStore, _ token: WebSocketSessionToken, _ id: UInt64, kind: WebSocketEventKind = .text, bytes: Data? = nil) throws {
        let stamp = try #require(store.webSocketCaptureStamp(token: token))
        var row = WebSocketEventMetadata(id: id, order: .init(ingressSequence: stamp.ingressSequence, offset: 0), direction: .clientToServer, kind: kind)
        row.completedAt = Date(); row.utf8 = .valid
        let data = bytes ?? Data(String(id).utf8); row.decodedBytes = UInt64(data.count)
        let cell = try #require(store.makeWebSocketAccumulator(token: token, eventID: id, epoch: stamp.epoch, kind: .application))
        #expect(cell.append(data, expectedEpoch: stamp.epoch))
        #expect(store.publishWebSocket(.init(metadata: row, stamp: stamp, application: cell.take(kind: .application, complete: true, truncated: false)), token: token, captureEpoch: stamp.epoch) == .accepted)
    }
}

/// Phase fix 2: latest-page follow, session-filtered wakeups and follow toggle during a scan.
@MainActor @Suite(.productionChinese) struct WebSocketViewModelPhaseFixTests {
    private func session(_ store: FlowStore) throws -> WebSocketSessionToken {
        let id = store.begin { Flow(id: $0, scheme: "http", method: "GET", host: "synthetic.test", port: 80, path: "/ws") }
        return try #require(store.beginWebSocket(flowID: id, handshake: .init()))
    }
    private func publish(_ store: FlowStore, _ token: WebSocketSessionToken, _ id: UInt64, kind: WebSocketEventKind = .text) throws {
        let stamp = try #require(store.webSocketCaptureStamp(token: token))
        var row = WebSocketEventMetadata(id: id, order: .init(ingressSequence: stamp.ingressSequence, offset: 0), direction: .clientToServer, kind: kind)
        row.completedAt = Date()
        #expect(store.publishWebSocket(.init(metadata: row, stamp: stamp), token: token, captureEpoch: stamp.epoch) == .accepted)
    }
    private func waitUntil(_ condition: @escaping @MainActor @Sendable () -> Bool) async {
        while !condition() {
            await withCheckedContinuation { continuation in
                withObservationTracking { _ = condition() } onChange: { continuation.resume() }
            }
        }
    }
    @Test func quietViewSkipsRescanWhenAnotherSessionChanges() async throws {
        let store = FlowStore(bodyDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let quiet = try session(store), busy = try session(store)
        try publish(store, quiet, 1)
        let hub = WebSocketInvalidationHub(store: store); defer { hub.stop() }
        let model = WebSocketViewModel(store: store, hub: hub, token: quiet); defer { model.cancel() }
        let watcher = WebSocketViewModel(store: store, hub: hub, token: busy); defer { watcher.cancel() }
        await model.load(after: nil)
        let loads = model.performedLoads
        for round in 1...5 {
            try publish(store, busy, UInt64(round))
            await waitUntil { watcher.page.count == round }
        }
        #expect(model.performedLoads == loads && model.page.map(\.id) == [1])
        try publish(store, quiet, 2)
        await waitUntil { model.page.count == 2 }
        #expect(model.performedLoads > loads)
    }
    @Test func followReadsTheLatestWindowWithSparseFilteredRows() async throws {
        var limits = WebSocketLimits(); limits.pageRows = 17
        let store = FlowStore(bodyDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), webSocketLimits: limits)
        let token = try session(store)
        for number in 1...700 { try publish(store, token, UInt64(number * 2), kind: number % 7 == 0 ? .ping : .text) }
        let hub = WebSocketInvalidationHub(store: store); defer { hub.stop() }
        let model = WebSocketViewModel(store: store, hub: hub, token: token); defer { model.cancel() }
        model.setFilters(directions: [.clientToServer], kinds: [.ping])
        await model.load(after: nil)
        // 100 pings exist (every 7th): the window reaches the start, so its anchor is nil.
        #expect(model.page.count == 100 && model.page.first?.id == 14 && model.page.last?.id == 1_400 && model.nextCursor == 1_400)
        model.setFilters(directions: [.clientToServer], kinds: [.text])
        await model.load(after: nil)
        #expect(model.page.count == 200 && model.page.last?.id == 1_398)
        model.autoFollow = false
        let shown = model.page.map(\.id)
        await model.load(after: shown.first.map { $0 - 1 })
        #expect(model.page.map(\.id) == shown)
    }
    @Test func togglingFollowOffDuringAnInFlightScanPublishesTheAnchoredPage() async throws {
        var limits = WebSocketLimits(); limits.pageRows = 5
        let store = FlowStore(bodyDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), webSocketLimits: limits)
        let token = try session(store)
        for id in 1...600 { try publish(store, token, UInt64(id), kind: id % 3 == 0 ? .ping : .text) }
        let hub = WebSocketInvalidationHub(store: store); defer { hub.stop() }
        let model = WebSocketViewModel(store: store, hub: hub, token: token); defer { model.cancel() }
        model.setFilters(directions: [.clientToServer], kinds: [.ping])
        // The hub's initial invalidation publishes the latest ping window; no Store change follows.
        await waitUntil { model.page.count == 200 }
        #expect(model.page.first?.id == 3 && model.page.allSatisfy { $0.kind == .ping })
        model.setFilters(directions: [.clientToServer], kinds: [.text])
        let paused = AsyncStream<Void>.makeStream(), resume = AsyncStream<Void>.makeStream()
        model.beforeFollowYield = {
            paused.continuation.yield(())
            for await _ in resume.stream { break }
        }
        let scan = Task { await model.load(after: nil) }
        var arrived = paused.stream.makeAsyncIterator(); _ = await arrived.next()
        model.beforeFollowYield = nil
        model.autoFollow = false
        resume.continuation.yield(())
        await scan.value
        await waitUntil { model.page.first?.kind == .text }
        // Not the stale ping window: the anchored first text window (filters reset the anchor).
        #expect(model.page.first?.id == 1 && model.page.count == 200 && model.page.allSatisfy { $0.kind == .text } && !model.autoFollow)
    }
}
