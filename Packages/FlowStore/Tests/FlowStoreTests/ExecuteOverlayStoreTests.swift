import Foundation
import Testing

@testable import FlowStore

private func makeFlow(_ id: Int) -> Flow {
    Flow(id: id, scheme: "https", method: "GET", host: "example.com", port: 443, path: "/\(id)")
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

private func charges(_ store: FlowStore) -> (spilled: Int, resident: Int) {
    store.state.withLock { ($0.spilledBytes, $0.residentBodyBytes) }
}

private func responseSnapshot(
    _ boundary: HTTPMessageBoundary, body: BodyRef?, count: Int
) -> HTTPMessageSnapshot {
    HTTPMessageSnapshot(
        boundary: boundary, head: .response(status: 200, reason: "OK", headers: []),
        body: body.map { HTTPBodySlice(ref: $0, offset: 0, count: count) },
        bodyState: body == nil ? .unavailable : .complete, observedBytes: UInt64(count), transferState: .finished)
}

private func spill(_ store: FlowStore, size: Int) throws -> (BodyRef, URL) {
    let capture = store.makeBodyCapture()
    capture.append([UInt8](repeating: 1, count: size))
    let ref = try #require(capture.finish().body)
    return (ref, try #require(store.spillURL(of: ref)))
}

@Suite struct ExecuteOverlayStoreTests {
    @Test func newFieldsDefaultToNil() {
        let flow = makeFlow(1)
        #expect(flow.executeOverlay == nil)
        #expect(flow.execute == nil)
    }

    @Test func flowEqualityCoversTheOverlay() {
        let plain = makeFlow(1)
        var changed = plain
        changed.executeOverlay = ExecuteOverlay(response: responseSnapshot(.downstreamResponse, body: nil, count: 0))
        #expect(changed != plain)
        #expect(ExecuteOverlay().isEmpty)
        #expect(!(changed.executeOverlay?.isEmpty ?? true))
        var recorded = plain
        recorded.execute = ExecuteRecord(
            runID: UUID(), executedAt: Date(timeIntervalSince1970: 1),
            matches: RuleMatchSummary(revision: 1, ruleIDs: [], total: 0),
            baseline: ExecuteFieldValues(), written: ExecuteFieldValues(comment: "x"))
        #expect(recorded != plain)
    }

    @Test func overlayBodiesAreChargedAndReleasedWithTheFlow() {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let store = env.store
        let body = store.makeManagedBody(Data(repeating: 3, count: 64))
        let id = store.begin(makeFlow)
        store.update(id) {
            $0.executeOverlay = ExecuteOverlay(response: responseSnapshot(.downstreamResponse, body: body, count: 64))
        }
        #expect(store.bodyOwnershipSnapshot().retainedBodies == 1)
        #expect(charges(store).resident == 64)
        store.update(id) { $0.executeOverlay = nil }
        #expect(store.bodyOwnershipSnapshot() == .init())
        #expect(charges(store) == (0, 0))
    }

    @Test func aliasedOverlayBodyIsNotChargedTwice() {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let store = env.store
        let shared = store.makeManagedBody(Data(repeating: 4, count: 100))
        let id = store.begin(makeFlow)
        store.update(id) {
            $0.messages[.upstreamResponse] = responseSnapshot(.upstreamResponse, body: shared, count: 100)
            $0.executeOverlay = ExecuteOverlay(response: responseSnapshot(.downstreamResponse, body: shared, count: 100))
        }
        #expect(charges(store).resident == 100)
        #expect(store.bodyOwnershipSnapshot().retainedBodies == 1)
        store.update(id) { $0.executeOverlay = nil }
        #expect(charges(store).resident == 100)
        #expect(store.bodyOwnershipSnapshot().retainedBodies == 1)
        store.update(id) { $0.messages[.upstreamResponse] = nil }
        #expect(charges(store).resident == 0)
        #expect(store.bodyOwnershipSnapshot() == .init())
    }

    @Test func evictingTheFlowReclaimsTheOverlayBody() throws {
        let env = TestEnvironment(maxFlows: 1)
        defer { env.cleanUp() }
        let store = env.store
        let (body, url) = try spill(store, size: BodyCapture.spillThreshold + 1)
        let first = store.begin(makeFlow)
        store.update(first) {
            $0.executeOverlay = ExecuteOverlay(
                request: HTTPMessageSnapshot(
                    boundary: .upstreamRequest,
                    head: .request(
                        HTTPMessageTarget(scheme: "https", host: "h", port: 443, method: "POST", pathAndQuery: "/"),
                        headers: []),
                    body: HTTPBodySlice(ref: body, offset: 0, count: BodyCapture.spillThreshold + 1),
                    bodyState: .complete))
        }
        #expect(exists(url))
        _ = store.begin(makeFlow)
        #expect(store.flow(first) == nil)
        #expect(!exists(url))
        #expect(store.bodyOwnershipSnapshot() == .init())
    }

    @Test func foreignManagedOverlayBodyIsDropped() throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let other = TestEnvironment()
        defer { other.cleanUp() }
        let foreign = other.store.makeManagedBody(Data("foreign".utf8))
        let id = env.store.begin(makeFlow)
        env.store.update(id) {
            $0.executeOverlay = ExecuteOverlay(response: responseSnapshot(.downstreamResponse, body: foreign, count: 7))
        }
        let flow = try #require(env.store.flow(id))
        let response = try #require(flow.executeOverlay?.response)
        #expect(response.body == nil)
        #expect(response.bodyState == .unavailable)
        #expect(charges(env.store) == (0, 0))
    }

    @Test func visibleFlowIDsAreAscendingAndSkipHidden() {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let store = env.store
        let ids = (0..<5).map { _ in store.begin(makeFlow) }
        store.update(ids[1]) { $0.isHidden = true }
        store.update(ids[3]) { $0.isHidden = true }
        #expect(store.visibleFlowIDs() == [ids[0], ids[2], ids[4]])
        store.update(ids[1]) { $0.isHidden = false }
        #expect(store.visibleFlowIDs() == [ids[0], ids[1], ids[2], ids[4]])
    }

    @Test func visibleFlowIDsDoesNotCopyFlows() {
        let env = TestEnvironment(maxFlows: 20_000)
        defer { env.cleanUp() }
        let store = env.store
        let ids = (0..<10_000).map { _ in store.begin(makeFlow) }
        store.update(ids[5_000]) { $0.isHidden = true }
        let visible = store.visibleFlowIDs()
        #expect(visible.count == 9_999)
        #expect(visible.first == ids.first)
        #expect(visible.last == ids.last)
        #expect(!visible.contains(ids[5_000]))
        #expect(visible == visible.sorted())
    }
}
