import Foundation
import Testing
@testable import FlowStore

/// Phase fix 2. Opt-in micro-measurement (no threshold): `PW_WS_MEASURE=1 swift test -c release --filter WebSocketCapMeasurement`.
@Suite struct WebSocketCapMeasurement {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PW_WS_MEASURE"] == "1"))
    func publishAndReadCostAtCaps() throws {
        let store = wsStore(), clock = ContinuousClock()
        var tokens: [WebSocketSessionToken] = []
        for _ in 0..<11 { tokens.append(try wsSession(store)) }
        for token in tokens.prefix(10) { for id in 1...10_000 { _ = try wsPublish(store, token, id: UInt64(id)) } }
        // Session cap: each further publication evicts within its own 10,000-event session.
        var next: UInt64 = 10_001
        let session = clock.measure { for _ in 0..<2_000 { _ = try? wsPublish(store, tokens[0], id: next); next += 1 } }
        // Store cap: a fresh session competes with 100,000 retained events.
        var id: UInt64 = 1
        let global = clock.measure { for _ in 0..<2_000 { _ = try? wsPublish(store, tokens[10], id: id); id += 1 } }
        let retained = store.state.withLock { state in state.webSockets.sessions.values.reduce(0) { $0 + $1.events.count } }
        // Latest page of a separate full 10,000-event session.
        let single = wsStore(), full = try wsSession(single)
        for id in 1...10_000 { _ = try wsPublish(single, full, id: UInt64(id)) }
        var page: WebSocketPage?
        let read = clock.measure { for _ in 0..<50 { page = single.webSocketPage(token: full, after: 9_800, limit: 200) } }
        #expect(page?.rows.count == 200)
        print("WS_CAP_MEASURE retainedAtStoreCap=\(retained) perPublishSessionCap=\(session / 2_000) perPublishStoreCap=\(global / 2_000) perPage(after 9800)=\(read / 50)")
    }
}

private func retainedSum(_ store: FlowStore) -> (counter: Int, actual: Int) {
    store.state.withLock { state in (state.webSockets.retainedEventCount, state.webSockets.sessions.values.reduce(0) { $0 + $1.events.count }) }
}
private func examined(_ store: FlowStore) -> UInt64 { store.state.withLock { $0.webSockets.evictionExamined } }
/// Publishes with an explicit stamp so tests control ingress order independently of IDs.
private func publish(_ store: FlowStore, _ token: WebSocketSessionToken, id: UInt64, stamp: WebSocketCaptureStamp, complete: Bool = true) -> StoreAcceptance {
    var metadata = WebSocketEventMetadata(id: id, order: .init(ingressSequence: stamp.ingressSequence, offset: 0), direction: .clientToServer, kind: .text)
    metadata.completedAt = complete ? Date() : nil
    return store.publishWebSocket(.init(metadata: metadata, stamp: stamp), token: token, captureEpoch: stamp.epoch)
}

/// Phase fix 2: release-independent complexity guards (operation counts, not wall clock).
@Suite struct WebSocketComplexityGuardTests {
    @Test func sessionCapEvictionExaminesConstantEntriesPerPublish() throws {
        var limits = WebSocketLimits(); limits.sessionEvents = 4_000
        let store = wsStore(limits), token = try wsSession(store)
        for id in 1...4_000 { #expect(try wsPublish(store, token, id: UInt64(id)) == .accepted) }
        let before = examined(store)
        for id in 4_001...5_000 { #expect(try wsPublish(store, token, id: UInt64(id)) == .accepted) }
        let perPublish = Double(examined(store) - before) / 1_000
        // O(1): the target session plus its heap top; a scan would examine ~4,000 per publish.
        #expect(perPublish <= 3)
        let page = try #require(store.webSocketPage(token: token, before: nil, limit: 200))
        #expect(page.summary.firstAvailableEventID == 1_001 && page.rows.first?.id == 4_801 && page.rows.last?.id == 5_000)
        #expect(retainedSum(store) == (4_000, 4_000))
    }
    @Test func storeCapEvictionExaminesSessionsNotEvents() throws {
        var limits = WebSocketLimits(); limits.storeEvents = 3_000
        let store = wsStore(limits)
        let tokens = try (0..<4).map { _ in try wsSession(store) }
        for token in tokens.prefix(3) { for id in 1...1_000 { #expect(try wsPublish(store, token, id: UInt64(id)) == .accepted) } }
        let before = examined(store)
        for id in 1...600 { #expect(try wsPublish(store, tokens[3], id: UInt64(id)) == .accepted) }
        let perPublish = Double(examined(store) - before) / 600
        // Four sessions each contribute one candidate (plus a heap top); never the 3,000 retained rows.
        #expect(perPublish <= 2 * 4 + 1)
        #expect(retainedSum(store) == (3_000, 3_000))
        // Global order: the 600 oldest rows (the first session's) went first.
        #expect(store.webSocketSummary(token: tokens[0])?.firstAvailableEventID == 601)
        #expect(store.webSocketSummary(token: tokens[1])?.firstAvailableEventID == 1)
    }
    @Test func evictionFollowsIngressOrderNotIDAndSkipsActiveRows() throws {
        var limits = WebSocketLimits(); limits.sessionEvents = 3
        let store = wsStore(limits), token = try wsSession(store)
        let early = try #require(store.webSocketCaptureStamp(token: token)), late = try #require(store.webSocketCaptureStamp(token: token))
        let active = try #require(store.webSocketCaptureStamp(token: token))
        // ID 1 has the later ingress order; ID 3 is still active (not capture-terminal).
        #expect(publish(store, token, id: 1, stamp: late) == .accepted)
        #expect(publish(store, token, id: 2, stamp: early) == .accepted)
        #expect(publish(store, token, id: 3, stamp: active, complete: false) == .accepted)
        #expect(publish(store, token, id: 4, stamp: try #require(store.webSocketCaptureStamp(token: token))) == .accepted)
        #expect(try #require(store.webSocketPage(token: token, after: nil, limit: 10)).rows.map(\.id) == [1, 3, 4])
        #expect(publish(store, token, id: 5, stamp: try #require(store.webSocketCaptureStamp(token: token))) == .accepted)
        let page = try #require(store.webSocketPage(token: token, after: nil, limit: 10))
        #expect(page.rows.map(\.id) == [3, 4, 5] && page.summary.firstAvailableEventID == 3 && page.missingBeforeCursor)
        #expect(retainedSum(store) == (3, 3))
    }
    @Test func runningCountersStayExactAcrossFlowEvictionAndClear() throws {
        var limits = WebSocketLimits(); limits.storeEvents = 50
        let store = wsStore(limits, maxFlows: 3)
        let a = try wsSession(store), b = try wsSession(store)
        for id in 1...30 { _ = try wsPublish(store, a, id: UInt64(id)); _ = try wsPublish(store, b, id: UInt64(id)) }
        #expect(retainedSum(store) == (50, 50))
        // Two more flows evict session a's flow (and its rows) by maxFlows.
        _ = store.begin { Flow(id: $0, scheme: "http", method: "GET", host: "x", port: 80, path: "/") }
        _ = store.begin { Flow(id: $0, scheme: "http", method: "GET", host: "x", port: 80, path: "/") }
        #expect(store.webSocketSummary(token: a) == nil)
        let remaining = retainedSum(store); #expect(remaining.counter == remaining.actual && remaining.actual > 0)
        store.clear()
        #expect(retainedSum(store) == (0, 0))
    }
    @Test func randomizedOrderedStorageMatchesReferenceModel() throws {
        var limits = WebSocketLimits(); limits.sessionEvents = 40
        let store = wsStore(limits), token = try wsSession(store)
        var generator = SystemRandomNumberGenerator()
        var nextID: UInt64 = 0
        for _ in 0..<600 {
            var stamps = try (0..<3).map { _ in try #require(store.webSocketCaptureStamp(token: token)) }
            stamps.shuffle(using: &generator)
            for stamp in stamps {
                nextID += UInt64.random(in: 1...3, using: &generator)
                _ = publish(store, token, id: nextID, stamp: stamp, complete: Bool.random(using: &generator) || nextID % 5 != 0)
            }
            let all = try #require(store.webSocketPage(token: token, after: nil, limit: 200)).rows.map(\.id)
            #expect(all == all.sorted() && all.count <= 40)
            #expect(store.webSocketSummary(token: token)?.firstAvailableEventID == all.first)
            // Forward and backward paging with a short page agree with the ascending set.
            var forward: [UInt64] = [], cursor: UInt64?
            while let page = store.webSocketPage(token: token, after: cursor, limit: 7), !page.rows.isEmpty { forward += page.rows.map(\.id); cursor = page.nextCursor }
            var backward: [UInt64] = [], before: UInt64?
            while let page = store.webSocketPage(token: token, before: before, limit: 7), !page.rows.isEmpty { backward = page.rows.map(\.id) + backward; before = page.nextCursor }
            #expect(forward == all && backward == all)
        }
        #expect(retainedSum(store).counter == retainedSum(store).actual)
    }
    @Test func latestPageHonoursConfiguredShortPagesSparseIDsAndEviction() throws {
        var limits = WebSocketLimits(); limits.pageRows = 3; limits.sessionEvents = 5
        let store = wsStore(limits), token = try wsSession(store)
        for id in [2, 5, 9, 14, 20, 27] { #expect(try wsPublish(store, token, id: UInt64(id)) == .accepted) }
        let latest = try #require(store.webSocketPage(token: token, before: nil, limit: 200))
        #expect(latest.rows.map(\.id) == [14, 20, 27] && latest.nextCursor == 14 && latest.missingBeforeCursor)
        let earlier = try #require(store.webSocketPage(token: token, before: 14, limit: 200))
        #expect(earlier.rows.map(\.id) == [5, 9] && earlier.nextCursor == 5 && earlier.missingBeforeCursor)
        #expect(earlier.firstAvailableEventID == 5)
        let none = try #require(store.webSocketPage(token: token, before: 5, limit: 200))
        #expect(none.rows.isEmpty && none.nextCursor == nil)
        #expect(try #require(store.webSocketPage(token: token, before: 10, limit: 1)).rows.map(\.id) == [9])
    }
}
