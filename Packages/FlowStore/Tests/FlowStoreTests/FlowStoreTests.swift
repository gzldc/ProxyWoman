import Foundation
import os
import Testing

@testable import FlowStore

private func makeFlow(_ id: Int) -> Flow {
    Flow(id: id, scheme: "https", method: "GET", host: "h", port: 443, path: "/\(id)")
}

/// Runs the interleaving on the caller while clear is parked on a separate queue.
/// Deadlines only bound a broken barrier; semaphores establish the execution order.
private func duringClearCleanup(of store: FlowStore, _ action: () throws -> Void) throws {
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    let completed = DispatchSemaphore(value: 0)
    DispatchQueue(label: "FlowStoreTests.clear-cleanup").async {
        store.clear {
            entered.signal()
            #expect(resume.wait(timeout: .now() + 10) == .success)
        }
        completed.signal()
    }
    defer {
        resume.signal()
        #expect(completed.wait(timeout: .now() + 10) == .success)
    }
    try #require(entered.wait(timeout: .now() + 10) == .success)
    try action()
}

@Suite struct FlowStoreTests {
    @Test func storeAssignsIncreasingIDs() {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let a = env.store.begin(makeFlow)
        let b = env.store.begin(makeFlow)
        #expect(a == 1)
        #expect(b == 2)
        #expect(env.store.allFlows().map(\.id) == [1, 2])
        #expect(env.store.flow(2)?.path == "/2")
        #expect(env.store.flow(99) == nil)
    }

    @Test func updateMutatesStoredFlowAndIgnoresUnknownIDs() {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let id = env.store.begin(makeFlow)
        env.store.update(id) { $0.statusCode = 204; $0.state = .completed }
        env.store.update(42) { $0.statusCode = 500 }
        #expect(env.store.flow(id)?.statusCode == 204)
        #expect(env.store.flow(id)?.state == .completed)
        #expect(env.store.flow(42) == nil)
    }

    @Test func changesAreBatchedAndCoalesced() async throws {
        let env = TestEnvironment(batchInterval: .milliseconds(50))
        defer { env.cleanUp() }
        let recorder = BatchRecorder(env.store.changes())
        defer { recorder.stop() }

        for _ in 0..<3 { env.store.begin(makeFlow) }
        env.store.update(1) { $0.statusCode = 200 }
        env.store.update(1) { $0.statusCode = 404 }

        let seen = await recorder.wait { batches in
            batches.flatMap(\.upserted).contains { $0.id == 1 && $0.statusCode == 404 }
        }
        #expect(seen)
        // 不断言批次数量：两次 update 之间恰好跨过一个 tick 时，id 1 可能分在两个批次里。
        let upserted = recorder.received.flatMap(\.upserted)
        #expect(Set(upserted.map(\.id)) == [1, 2, 3])
        #expect(upserted.last { $0.id == 1 }?.statusCode == 404)
        #expect(recorder.received.allSatisfy { !$0.cleared })
    }

    @Test func newSubscriberReceivesExistingFlowsAsBaseline() async throws {
        let env = TestEnvironment(batchInterval: .milliseconds(20))
        defer { env.cleanUp() }
        env.store.begin(makeFlow)
        env.store.begin(makeFlow)
        env.store.update(2) { $0.statusCode = 201 }

        let recorder = BatchRecorder(env.store.changes())
        defer { recorder.stop() }
        #expect(await recorder.wait { Set($0.flatMap(\.upserted).map(\.id)) == [1, 2] })
        var collection = FlowCollection()
        recorder.received.forEach { collection.apply($0) }
        #expect(collection.flow(id: 2)?.statusCode == 201)
    }

    @Test func resubscribingResyncsEvenAfterBatchWasConsumed() async throws {
        let env = TestEnvironment(batchInterval: .milliseconds(20))
        defer { env.cleanUp() }
        let first = BatchRecorder(env.store.changes())
        defer { first.stop() }
        env.store.begin(makeFlow)
        env.store.update(1) { $0.statusCode = 200 }
        // 旧订阅者已经取走了这批；新订阅者仍要拿到 id 1 的当前状态（否则界面行会过期）。
        #expect(await first.wait { $0.flatMap(\.upserted).contains { $0.id == 1 } })

        let second = BatchRecorder(env.store.changes())
        defer { second.stop() }
        env.store.update(1) { $0.statusCode = 301 }
        #expect(await second.wait { $0.flatMap(\.upserted).contains { $0.id == 1 && $0.statusCode == 301 } })

        var collection = FlowCollection()
        second.received.forEach { collection.apply($0) }
        #expect(collection.flow(id: 1)?.statusCode == 301)
    }

    @Test func resubscribingWithoutFurtherUpdatesStillDeliversSnapshot() async throws {
        let env = TestEnvironment(batchInterval: .milliseconds(20))
        defer { env.cleanUp() }
        let first = BatchRecorder(env.store.changes())
        defer { first.stop() }
        env.store.begin(makeFlow)
        env.store.update(1) { $0.statusCode = 200 }
        #expect(await first.wait { $0.flatMap(\.upserted).contains { $0.id == 1 } })

        let second = BatchRecorder(env.store.changes())
        defer { second.stop() }
        #expect(await second.wait { $0.flatMap(\.upserted).contains { $0.id == 1 && $0.statusCode == 200 } })
    }

    @Test func idleStoreEmitsNoBatches() async throws {
        let env = TestEnvironment(batchInterval: .milliseconds(20))
        defer { env.cleanUp() }
        let recorder = BatchRecorder(env.store.changes())
        defer { recorder.stop() }
        try await Task.sleep(for: .milliseconds(150))
        #expect(recorder.received.isEmpty)
    }

    @Test func secondSubscriptionReplacesFirst() async throws {
        let env = TestEnvironment(batchInterval: .milliseconds(20))
        defer { env.cleanUp() }
        let first = env.store.changes()
        let second = env.store.changes()

        // 旧流已被结束：直接迭代应当立刻返回。
        var firstCount = 0
        for await _ in first { firstCount += 1 }
        #expect(firstCount == 0)

        let recorder = BatchRecorder(second)
        defer { recorder.stop() }
        env.store.begin(makeFlow)
        #expect(await recorder.wait { $0.flatMap(\.upserted).count == 1 })
    }

    @Test func clearEmitsClearedAndDeletesSpilledFiles() async throws {
        let env = TestEnvironment(batchInterval: .milliseconds(50))
        defer { env.cleanUp() }
        let recorder = BatchRecorder(env.store.changes())
        defer { recorder.stop() }

        let cap = env.store.makeBodyCapture()
        cap.append([UInt8](repeating: 9, count: BodyCapture.spillThreshold + 1))
        let ref = try #require(cap.finish().body)
        guard let url = env.store.spillURL(of: ref) else {
            Issue.record("expected a managed spill")
            return
        }
        let id = env.store.begin(makeFlow)
        env.store.update(id) { $0.requestBody = ref }
        #expect(FileManager.default.fileExists(atPath: url.path))

        env.store.clear()
        #expect(env.store.allFlows().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))

        #expect(await recorder.wait { $0.contains { $0.cleared } })
        // clear 之前挂起的 upsert 被丢弃。
        #expect(recorder.received.flatMap(\.upserted).isEmpty)

        // 清空后 id 不回绕，旧 id 上的迟到更新不会误改新记录。
        let next = env.store.begin(makeFlow)
        #expect(next == id + 1)
        env.store.update(id) { $0.statusCode = 500 }
        #expect(env.store.flow(id) == nil)
    }

    @Test(arguments: [true, false])
    func clearPreservesPostBoundaryCaptureFiles(finishBeforeCleanup: Bool) throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let store = FlowStore(bodyDirectory: env.directory, maxSpilledBytes: 8, maxActiveBodyBytes: 0)
        let oldID = store.begin(makeFlow)
        let oldRequest = store.makeBodyCapture()
        let oldResponse = store.makeBodyCapture()
        oldRequest.append([1, 2, 3, 4])
        oldResponse.append([5, 6, 7, 8])
        let oldURLs = [try #require(oldRequest.file?.url), try #require(oldResponse.file?.url)]
        let request = try #require(oldRequest.finish().body)
        let response = try #require(oldResponse.finish().body)
        store.update(oldID) { $0.requestBody = request; $0.responseBody = response }

        var newID = 0
        var capture: BodyCapture?
        var newURL: URL?
        try duringClearCleanup(of: store) {
            #expect(store.allFlows().isEmpty)
            #expect(oldURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
            newID = store.begin(makeFlow)
            #expect(newID == oldID + 1)
            let fresh = store.makeBodyCapture()
            capture = fresh
            fresh.append([0, 1, 2, 3])
            newURL = try #require(fresh.file?.url)
            if finishBeforeCleanup {
                fresh.append([4, 5, 6, 255])
                let body = try #require(fresh.finish().body)
                store.update(newID) { $0.responseBody = body }
                #expect(try body.load() == Data([0, 1, 2, 3, 4, 5, 6, 255]))
            }
        }

        #expect(oldURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(store.flow(oldID) == nil)
        #expect(store.allFlows().map(\.id) == [newID])
        #expect(FileManager.default.fileExists(atPath: try #require(newURL).path))
        if !finishBeforeCleanup {
            let fresh = try #require(capture)
            fresh.append([4, 5, 6, 255])
            let result = fresh.finish()
            #expect(!result.truncated)
            store.update(newID) { $0.responseBody = result.body }
        }
        let saved = try #require(store.flow(newID)?.responseBody)
        #expect(saved.size == 8)
        #expect(try saved.load() == Data([0, 1, 2, 3, 4, 5, 6, 255]))
    }

    @Test func clearPreservesReferencedFilesOutsideOwnedBodyBoundary() throws {
        let env = TestEnvironment()
        let external = TestEnvironment()
        defer { env.cleanUp(); external.cleanUp() }
        let nested = env.directory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external.directory, withIntermediateDirectories: true)
        let urls = [
            external.directory.appendingPathComponent("external.body"),
            env.directory.appendingPathComponent("local.txt"),
            nested.appendingPathComponent("nested.body"),
        ]
        for url in urls {
            try Data([1, 2, 3]).write(to: url)
            env.store.begin { id in
                var flow = makeFlow(id)
                flow.requestBody = .file(url, size: 3)
                return flow
            }
        }
        env.store.clear()
        #expect(env.store.allFlows().isEmpty)
        for url in urls {
            #expect(try Data(contentsOf: url) == Data([1, 2, 3]))
        }
    }

    @Test func clearPreservesReservationsAndDeletesLateOldIDBody() throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let store = FlowStore(bodyDirectory: env.directory, maxActiveBodyBytes: 10)
        let oldID = store.begin(makeFlow)
        let late = store.makeBodyCapture()
        late.append([1, 2, 3, 4, 5, 6])
        store.clear()

        // Clear must not release the six bytes still owned by the old capture.
        var probe: BodyCapture? = store.makeBodyCapture()
        probe?.append([7, 8, 9, 10, 11, 12])
        let abandonedURL = try #require(probe?.file?.url)
        probe = nil
        #expect(!FileManager.default.fileExists(atPath: abandonedURL.path))

        // A late finish transfers file ownership to update, which discards old IDs.
        late.append([7, 8, 9, 10, 11, 12])
        let orphanURL = try #require(late.file?.url)
        let body = try #require(late.finish().body)
        #expect(FileManager.default.fileExists(atPath: orphanURL.path))
        store.update(oldID) { $0.requestBody = body }
        #expect(!FileManager.default.fileExists(atPath: orphanURL.path))
        #expect(store.flow(oldID) == nil)
        #expect(store.begin(makeFlow) == oldID + 1)

        // Spill/finish/deinit returned the entire active budget exactly once.
        let fullBudget = store.makeBodyCapture()
        fullBudget.append(Data(repeating: 42, count: 10))
        #expect((try? fullBudget.finish().body?.load()) == Data(repeating: 42, count: 10))
    }

    @Test func upsertsAfterClearInSameBatchSurvive() async throws {
        let env = TestEnvironment(batchInterval: .milliseconds(50))
        defer { env.cleanUp() }
        let recorder = BatchRecorder(env.store.changes())
        defer { recorder.stop() }

        env.store.begin(makeFlow)
        env.store.clear()
        let id = env.store.begin(makeFlow)

        #expect(await recorder.wait { $0.flatMap(\.upserted).contains { $0.id == id } })
        let batches = recorder.received
        #expect(batches.contains { $0.cleared })
        #expect(batches.flatMap(\.upserted).map(\.id) == [id])
    }

    @Test func concurrentWritersAreSafe() async {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let store = env.store
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<100 {
                        let id = store.begin(makeFlow)
                        store.update(id) { $0.statusCode = 200 }
                    }
                }
            }
        }
        let flows = store.allFlows()
        #expect(flows.count == 800)
        #expect(flows.map(\.id) == Array(1...800))
        #expect(flows.allSatisfy { $0.statusCode == 200 })
    }

    @Test func flowURLOmitsDefaultPort() {
        let a = Flow(id: 1, scheme: "https", method: "GET", host: "h", port: 443, path: "/a?b=1")
        #expect(a.url == "https://h/a?b=1")
        let b = Flow(id: 2, scheme: "http", method: "GET", host: "h", port: 8080, path: "/")
        #expect(b.url == "http://h:8080/")
        let c = Flow(id: 3, scheme: "http", method: "GET", host: "h", port: 80, path: "/x")
        #expect(c.url == "http://h/x")
    }

    @Test func connectFlowURLIsHostAndPort() {
        let f = Flow(id: 1, scheme: "https", method: "CONNECT", host: "h", port: 443, path: "")
        #expect(f.url == "h:443")
    }

    @Test func durationIsCompletionMinusStart() {
        var f = makeFlow(1)
        #expect(f.duration == nil)
        f.completedAt = f.startedAt.addingTimeInterval(1.5)
        #expect(f.duration == 1.5)
    }

    @Test func headerLookupIsCaseInsensitive() {
        let headers = [
            HeaderField(name: "Content-Type", value: "text/plain"),
            HeaderField(name: "set-cookie", value: "a=1"),
            HeaderField(name: "Set-Cookie", value: "b=2"),
        ]
        #expect(headers.value(for: "content-type") == "text/plain")
        #expect(headers.value(for: "X-Missing") == nil)
        #expect(headers.value(for: "SET-COOKIE") == "a=1")
        #expect(headers.values(for: "set-cookie") == ["a=1", "b=2"])
    }
}


extension FlowStoreTests {
    @Test func flowRemovalCallbacksAreOnceOutsideLockAndMissingRegistrationFails() {
        let env = TestEnvironment(maxFlows: 1)
        defer { env.cleanUp() }
        let first = env.store.begin(makeFlow)
        let count = OSAllocatedUnfairLock(initialState: 0)
        let registeredFirst = env.store.registerFlowRemoval(flowID: first) {
            #expect(env.store.flow(first) == nil)
            count.withLock { $0 += 1 }
        }
        #expect(registeredFirst)
        let second = env.store.begin(makeFlow)
        #expect(count.withLock { $0 } == 1)
        #expect(!env.store.registerFlowRemoval(flowID: first) { Issue.record("missing flow callback") })
        let registeredSecond = env.store.registerFlowRemoval(flowID: second) {
            #expect(env.store.allFlows().isEmpty)
            count.withLock { $0 += 1 }
        }
        #expect(registeredSecond)
        env.store.clear()
        env.store.clear()
        #expect(count.withLock { $0 } == 2)
    }
}

extension FlowStoreTests {
    @Test func flowCountTracksBeginEvictionAndClearAndAllFlowsStaysAscending() {
        let env = TestEnvironment(maxFlows: 3)
        defer { env.cleanUp() }
        #expect(env.store.flowCount == 0)
        #expect(env.store.allFlows().isEmpty)
        var ids: [Int] = []
        for expected in [1, 2, 3, 3, 3] {
            ids.append(env.store.begin(makeFlow))
            #expect(env.store.flowCount == expected)
            #expect(env.store.flowCount == env.store.allFlows().count)
        }
        // Updates to a surviving flow do not change the count.
        env.store.update(ids[4]) { $0.statusCode = 200 }
        #expect(env.store.flowCount == 3)
        // Eviction dropped the two oldest; what remains is ascending by id.
        let remaining = env.store.allFlows().map(\.id)
        #expect(remaining == Array(ids.suffix(3)))
        #expect(remaining == remaining.sorted())
        env.store.clear()
        #expect(env.store.flowCount == 0)
        #expect(env.store.allFlows().isEmpty)
        let afterClear = env.store.begin(makeFlow)
        #expect(afterClear > ids[4])
        #expect(env.store.flowCount == 1)
    }

    @Test func allFlowsIsAscendingAfterManyInterleavedUpdates() {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let ids = (0..<200).map { _ in env.store.begin(makeFlow) }
        for id in ids.reversed() { env.store.update(id) { $0.statusCode = 204 } }
        #expect(env.store.allFlows().map(\.id) == ids)
    }
}
