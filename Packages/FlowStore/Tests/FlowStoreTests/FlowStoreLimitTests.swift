import Foundation
import Testing

@testable import FlowStore

private func makeFlow(_ id: Int) -> Flow {
    Flow(id: id, scheme: "https", method: "GET", host: "h", port: 443, path: "/\(id)")
}

/// A spilled body of `size` bytes (must exceed the spill threshold).
private func spilledBody(_ store: FlowStore, size: Int) throws -> (BodyRef, URL) {
    let capture = store.makeBodyCapture()
    capture.append([UInt8](repeating: 1, count: size))
    let ref = try #require(capture.finish().body)
    guard let url = store.spillURL(of: ref) else {
        throw NotSpilled()
    }
    return (ref, url)
}

private struct NotSpilled: Error {}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

@Suite struct FlowStoreLimitTests {
    @Test func oldestFlowsAreEvictedBeyondMaxFlows() {
        let env = TestEnvironment(maxFlows: 3)
        defer { env.cleanUp() }
        for _ in 0..<5 { env.store.begin(makeFlow) }
        #expect(env.store.allFlows().map(\.id) == [3, 4, 5])
        #expect(env.store.flow(1) == nil)
        // Later updates of an evicted flow are ignored.
        env.store.update(1) { $0.statusCode = 200 }
        #expect(env.store.flow(1) == nil)
    }

    @Test func oldestFlowsAreEvictedWhenSpilledBytesExceedTheLimit() throws {
        let size = BodyCapture.spillThreshold + 1
        let env = TestEnvironment(maxSpilledBytes: 2 * size + size / 2)
        defer { env.cleanUp() }
        var urls: [URL] = []
        for _ in 0..<3 {
            let (ref, url) = try spilledBody(env.store, size: size)
            urls.append(url)
            let id = env.store.begin(makeFlow)
            env.store.update(id) { $0.responseBody = ref }
        }
        #expect(env.store.allFlows().map(\.id) == [2, 3])
        #expect(!exists(urls[0]))
        #expect(exists(urls[1]))
        #expect(exists(urls[2]))
    }

    @Test func spilledBytesOfBothSidesCount() throws {
        let size = BodyCapture.spillThreshold + 1
        let env = TestEnvironment(maxSpilledBytes: 3 * size)
        defer { env.cleanUp() }
        let (request, requestURL) = try spilledBody(env.store, size: size)
        let (response, responseURL) = try spilledBody(env.store, size: size)
        let first = env.store.begin(makeFlow)
        env.store.update(first) {
            $0.requestBody = request
            $0.responseBody = response
        }
        let (other, otherURL) = try spilledBody(env.store, size: size)
        let second = env.store.begin(makeFlow)
        env.store.update(second) { $0.responseBody = other }
        // 2 + 1 bodies fit exactly; one more pushes the first flow (both of its files) out.
        #expect(env.store.allFlows().map(\.id) == [first, second])
        let (last, _) = try spilledBody(env.store, size: size)
        let third = env.store.begin(makeFlow)
        env.store.update(third) { $0.responseBody = last }
        #expect(env.store.allFlows().map(\.id) == [second, third])
        #expect(!exists(requestURL))
        #expect(!exists(responseURL))
        #expect(exists(otherURL))
    }

    @Test func bodyArrivingForAnEvictedFlowIsDeleted() throws {
        let env = TestEnvironment(maxFlows: 1)
        defer { env.cleanUp() }
        let old = env.store.begin(makeFlow)
        env.store.begin(makeFlow)
        let (ref, url) = try spilledBody(env.store, size: BodyCapture.spillThreshold + 1)
        env.store.update(old) { $0.responseBody = ref }
        #expect(env.store.flow(old) == nil)
        #expect(!exists(url))
    }

    @Test func evictionsReachSubscribers() async throws {
        let env = TestEnvironment(batchInterval: .milliseconds(20), maxFlows: 2)
        defer { env.cleanUp() }
        let recorder = BatchRecorder(env.store.changes())
        defer { recorder.stop() }
        env.store.begin(makeFlow)
        env.store.begin(makeFlow)
        #expect(await recorder.wait { Set($0.flatMap(\.upserted).map(\.id)) == [1, 2] })
        env.store.begin(makeFlow)
        #expect(await recorder.wait { $0.flatMap(\.removed).contains(1) })

        var list = FlowListState()
        recorder.received.forEach { list.apply($0) }
        #expect(list.collection.flows.map(\.id) == [2, 3])
        #expect(list.visible.map(\.id) == [2, 3])
        #expect(list.hostGroups == [GroupCount(name: "h", count: 2)])
    }

    @Test func clearDropsPendingRemovals() async throws {
        let env = TestEnvironment(batchInterval: .milliseconds(20), maxFlows: 1)
        defer { env.cleanUp() }
        let recorder = BatchRecorder(env.store.changes())
        defer { recorder.stop() }
        env.store.begin(makeFlow)
        env.store.begin(makeFlow)
        env.store.clear()
        #expect(await recorder.wait { $0.contains { $0.cleared } })
        #expect(recorder.received.allSatisfy { $0.removed.isEmpty })
    }
}

@Suite struct FlowStoreMemoryLimitTests {
    @Test func residentLimitEvictsOldestAndNotifiesSubscribers() async {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let store = FlowStore(bodyDirectory: env.directory, batchInterval: .milliseconds(20), maxResidentBodyBytes: 10)
        let recorder = BatchRecorder(store.changes())
        defer { recorder.stop() }
        let first = store.begin { id in
            var flow = makeFlow(id)
            flow.requestBody = .memory(Data(repeating: 1, count: 6))
            return flow
        }
        #expect(await recorder.wait { $0.flatMap(\.upserted).map(\.id).contains(first) })
        let second = store.begin { id in
            var flow = makeFlow(id)
            flow.responseBody = .memory(Data(repeating: 2, count: 6))
            return flow
        }
        #expect(store.allFlows().map(\.id) == [second])
        #expect(await recorder.wait { $0.flatMap(\.removed).contains(first) })
        #expect(await recorder.wait { $0.flatMap(\.upserted).map(\.id).contains(second) })
    }

    @Test func bothSidesCountAndExactResidentLimitIsRetained() {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let store = FlowStore(bodyDirectory: env.directory, maxResidentBodyBytes: 10)
        let first = store.begin(makeFlow)
        store.update(first) {
            $0.requestBody = .memory(Data(repeating: 1, count: 6))
            $0.responseBody = .memory(Data(repeating: 2, count: 4))
        }
        #expect(store.flow(first)?.responseBody?.size == 4)
        let second = store.begin(makeFlow)
        store.update(second) { $0.requestBody = .memory(Data([3])) }
        #expect(store.allFlows().map(\.id) == [second])
    }

    @Test func replacingAndRemovingBodiesSubtractPreviousResidentBytes() {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let store = FlowStore(bodyDirectory: env.directory, maxResidentBodyBytes: 10)
        let first = store.begin(makeFlow)
        store.update(first) { $0.requestBody = .memory(Data(repeating: 1, count: 6)) }
        store.update(first) { $0.requestBody = .memory(Data(repeating: 2, count: 2)) }
        let second = store.begin(makeFlow)
        store.update(second) { $0.responseBody = .memory(Data(repeating: 3, count: 8)) }
        #expect(store.allFlows().map(\.id) == [first, second])
        store.update(second) { $0.responseBody = nil }
        store.update(first) { $0.requestBody = .memory(Data(repeating: 4, count: 10)) }
        #expect(store.allFlows().map(\.id) == [first, second])
    }

    @Test func clearResetsRetainedBytesAndIgnoresLateMemoryUpdates() {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let store = FlowStore(bodyDirectory: env.directory, maxResidentBodyBytes: 10)
        let first = store.begin(makeFlow)
        store.update(first) { $0.requestBody = .memory(Data(repeating: 1, count: 10)) }
        store.clear()
        store.update(first) { $0.responseBody = .memory(Data(repeating: 2, count: 10)) }
        let second = store.begin(makeFlow)
        store.update(second) { $0.responseBody = .memory(Data(repeating: 3, count: 10)) }
        #expect(store.allFlows().map(\.id) == [second])
    }

    @Test(arguments: [0, -10]) func nonpositiveResidentLimitEvictsNonemptyBodies(limit: Int) {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let store = FlowStore(bodyDirectory: env.directory, maxResidentBodyBytes: limit)
        let empty = store.begin(makeFlow)
        store.update(empty) { $0.requestBody = .memory(Data()) }
        #expect(store.flow(empty) != nil)
        store.update(empty) { $0.responseBody = .memory(Data([1])) }
        #expect(store.allFlows().isEmpty)
    }

    @Test func residentEvictionAlsoRemovesSpilledBodies() throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let store = FlowStore(bodyDirectory: env.directory, maxResidentBodyBytes: 10)
        let (spilled, url) = try spilledBody(store, size: BodyCapture.spillThreshold + 1)
        let first = store.begin(makeFlow)
        store.update(first) {
            $0.requestBody = .memory(Data(repeating: 1, count: 6))
            $0.responseBody = spilled
        }
        let second = store.begin(makeFlow)
        store.update(second) { $0.requestBody = .memory(Data(repeating: 2, count: 6)) }
        #expect(store.allFlows().map(\.id) == [second])
        #expect(!exists(url))
    }

    @Test func storeSharesActiveBudgetAndClearPreservesLiveReservations() throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let store = FlowStore(bodyDirectory: env.directory, maxActiveBodyBytes: 10)
        let first = store.makeBodyCapture()
        first.append(Array("abcdef".utf8))
        store.clear()
        let second = store.makeBodyCapture()
        second.append(Array("ghijkl".utf8))
        let body = try #require(second.finish().body)
        guard case .managed = body else { Issue.record("expected shared-budget spill after clear"); return }
        #expect(try body.load() == Data("ghijkl".utf8))
        #expect((try? first.finish().body?.load()) == Data("abcdef".utf8))
        let third = store.makeBodyCapture()
        third.append(Data(repeating: 3, count: 10))
        #expect((try? third.finish().body?.load()) == Data(repeating: 3, count: 10))
    }

    @Test func activeBudgetsBelongToEachStore() {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let first = FlowStore(bodyDirectory: env.directory, maxActiveBodyBytes: 10).makeBodyCapture()
        let second = FlowStore(bodyDirectory: env.directory, maxActiveBodyBytes: 10).makeBodyCapture()
        first.append(Data(repeating: 1, count: 6))
        second.append(Data(repeating: 2, count: 6))
        #expect((try? first.finish().body?.load()) == Data(repeating: 1, count: 6))
        #expect((try? second.finish().body?.load()) == Data(repeating: 2, count: 6))
    }

    @Test(arguments: [0, -10]) func nonpositiveActiveLimitSpillsImmediately(limit: Int) throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let store = FlowStore(bodyDirectory: env.directory, maxActiveBodyBytes: limit)
        let capture = store.makeBodyCapture()
        capture.append([1, 2, 3])
        let body = try #require(capture.finish().body)
        guard case .managed = body else { Issue.record("expected immediate spill"); return }
        #expect(try body.load() == Data([1, 2, 3]))
    }
}
