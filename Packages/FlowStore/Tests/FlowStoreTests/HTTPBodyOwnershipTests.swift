import Foundation
import Testing
import os

@testable import FlowStore

private func makeFlow(_ id: Int) -> Flow {
    Flow(id: id, scheme: "https", method: "GET", host: "h", port: 443, path: "/\(id)")
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

private func charges(_ store: FlowStore) -> (spilled: Int, resident: Int) {
    store.state.withLock { ($0.spilledBytes, $0.residentBodyBytes) }
}

/// A store-registered spilled body (`size` must exceed what the active budget allows).
private func spill(_ store: FlowStore, size: Int, byte: UInt8 = 1) throws -> (BodyRef, URL) {
    let capture = store.makeBodyCapture()
    capture.append([UInt8](repeating: byte, count: size))
    let ref = try #require(capture.finish().body)
    return (ref, try #require(store.spillURL(of: ref)))
}

private func managedMemory(_ store: FlowStore, _ data: Data) -> BodyRef {
    .managed(store.bodies.registerMemory(data))
}

private func fakeBodyFile(in directory: URL, name: String = "\(UUID().uuidString).body") throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    try Data([9, 9, 9]).write(to: url)
    return url
}

@Suite struct HTTPBodyOwnershipTests {
    // MARK: Shared retention

    @Test func aliasRetainedOnce() async throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let store = env.store
        let data = Data([1, 2, 3, 4]) + Data(repeating: 7, count: 4092)
        let body = managedMemory(store, data)
        let a = store.begin(makeFlow)
        let b = store.begin(makeFlow)
        store.update(a) { $0.requestBody = body; $0.responseBody = body }
        store.update(b) { $0.requestBody = body }
        #expect(charges(store).resident == 4096)
        #expect(store.bodyOwnershipSnapshot().retainedBodies == 1)

        let lease = try store.acquireBody(body)
        store.update(a) { $0.requestBody = nil }
        store.update(a) { $0.responseBody = nil }
        #expect(charges(store).resident == 4096)
        #expect(try await lease.read(offset: 0, maxBytes: 4) == Data([1, 2, 3, 4]))

        store.update(b) { $0.requestBody = nil }
        #expect(charges(store).resident == 0)
        await #expect(throws: HTTPBodyError.revoked) { _ = try await lease.read(offset: 0, maxBytes: 4) }
        #expect(throws: HTTPBodyError.revoked) { _ = try store.acquireBody(body) }
        lease.cancel()
        #expect(store.bodyOwnershipSnapshot() == .init())
    }

    @Test func distinctEqualContentBodiesAreNotCoalesced() {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let store = env.store
        let id = store.begin(makeFlow)
        let data = Data(repeating: 5, count: 100)
        store.update(id) {
            $0.requestBody = managedMemory(store, data)
            $0.responseBody = managedMemory(store, data)
        }
        #expect(charges(store).resident == 200)
        #expect(store.bodyOwnershipSnapshot().retainedBodies == 2)
    }

    @Test func sharedDiskBodyIsChargedAndEvictedAsOneUnit() throws {
        let size = BodyCapture.spillThreshold + 1
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let store = FlowStore(bodyDirectory: env.directory, maxSpilledBytes: size + size / 2)
        let (shared, url) = try spill(store, size: size)
        let a = store.begin(makeFlow)
        let b = store.begin(makeFlow)
        store.update(a) { $0.requestBody = shared; $0.responseBody = shared }
        store.update(b) { $0.responseBody = shared }
        #expect(charges(store).spilled == size)
        #expect(store.allFlows().count == 2)

        // A different body pushes both older flows out; the shared file is reclaimed once, as one unit.
        let (other, otherURL) = try spill(store, size: size, byte: 2)
        let c = store.begin(makeFlow)
        store.update(c) { $0.responseBody = other }
        #expect(store.allFlows().map(\.id) == [c])
        #expect(!exists(url))
        #expect(exists(otherURL))
    }

    @Test func staleHandleCannotReinstallOwnership() async throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let store = env.store
        let body = managedMemory(store, Data([1, 2, 3]))
        let old = store.begin(makeFlow)
        store.update(old) { $0.requestBody = body }
        store.clear()
        let fresh = store.begin(makeFlow)
        store.update(fresh) { $0.responseBody = body }
        #expect(charges(store) == (0, 0))
        #expect(store.bodyOwnershipSnapshot() == .init())
        #expect(throws: HTTPBodyError.revoked) { _ = try store.acquireBody(body) }
        store.update(fresh) { $0.responseBody = nil }
        #expect(charges(store) == (0, 0))
    }

    // MARK: Safe deletion

    @Test func externalPathsSurviveAllRemovalPaths() throws {
        let env = TestEnvironment(maxFlows: 2)
        let outside = TestEnvironment()
        defer { env.cleanUp(); outside.cleanUp() }
        let store = env.store
        let external = try fakeBodyFile(in: outside.directory)
        let lookAlike = try fakeBodyFile(in: env.directory)
        let plain = try fakeBodyFile(in: env.directory, name: "notes.txt")
        let rejected = try fakeBodyFile(in: env.directory)
        let all = [external, lookAlike, plain, rejected]

        // Rejected update: the flow does not exist.
        store.update(999) { $0.requestBody = .file(rejected, size: 3) }
        // Eviction: three flows with maxFlows == 2 evict the first.
        for url in [external, lookAlike, plain] {
            store.begin { id in
                var flow = makeFlow(id)
                flow.requestBody = .file(url, size: 3)
                return flow
            }
        }
        #expect(store.allFlows().count == 2)
        #expect(all.allSatisfy(exists))
        // Replaced body on a live flow, then clear.
        let live = store.allFlows()[0].id
        store.update(live) { $0.requestBody = .memory(Data([1])) }
        #expect(all.allSatisfy(exists))
        store.clear()
        #expect(all.allSatisfy(exists))
        for url in all { #expect(try Data(contentsOf: url) == Data([9, 9, 9])) }
    }

    @Test func borrowedFilesAreReadOnlyThroughALease() async throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let url = try fakeBodyFile(in: env.directory)
        let lease = try env.store.acquireBody(.file(url, size: 3))
        #expect(try await lease.read(offset: 1, maxBytes: 10) == Data([9, 9]))
        lease.cancel()
        env.store.clear()
        #expect(exists(url))
    }

    @Test func registeredFileIsDeletedOnlyAfterReadersRelease() async throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let store = env.store
        let (body, url) = try spill(store, size: BodyCapture.spillThreshold + 1)
        let id = store.begin(makeFlow)
        store.update(id) { $0.requestBody = body }
        let lease = try store.acquireBody(body)
        #expect(store.bodyOwnershipSnapshot().readers == 1)

        store.clear()
        #expect(exists(url), "an active reader keeps the file until it releases")
        await #expect(throws: HTTPBodyError.revoked) { _ = try await lease.read(offset: 0, maxBytes: 1) }
        #expect(throws: HTTPBodyError.revoked) { _ = try store.acquireBody(body) }
        lease.cancel()
        lease.cancel()
        #expect(!exists(url))
        #expect(store.bodyOwnershipSnapshot() == .init())
    }

    @Test func lateUpdateForARemovedFlowDeletesOnlyTheOwnedBody() throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let store = env.store
        let borrowed = try fakeBodyFile(in: env.directory)
        let old = store.begin(makeFlow)
        let (body, url) = try spill(store, size: BodyCapture.spillThreshold + 1)
        store.clear()
        store.update(old) {
            $0.requestBody = body
            $0.responseBody = .file(borrowed, size: 3)
        }
        #expect(store.flow(old) == nil)
        #expect(!exists(url))
        #expect(exists(borrowed))
        #expect(store.bodyOwnershipSnapshot() == .init())
    }

    // MARK: Producer lifecycle

    @Test func spillFilesAreExclusiveOwnerOnlyDirectChildren() throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let (first, url) = try spill(env.store, size: BodyCapture.spillThreshold + 1)
        #expect(url.deletingLastPathComponent().standardizedFileURL == env.directory.standardizedFileURL)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        let (second, secondURL) = try spill(env.store, size: BodyCapture.spillThreshold + 1)
        #expect(secondURL != url)
        withExtendedLifetime((first, second)) {}
    }

    @Test func finishedButUnacceptedBodyIsReclaimedWhenDropped() throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let store = env.store
        func produce() throws -> URL {
            let (body, url) = try spill(store, size: BodyCapture.spillThreshold + 1)
            #expect(exists(url))
            #expect(store.bodyOwnershipSnapshot().producerClaims == 1)
            withExtendedLifetime(body) {}
            return url
        }
        let url = try produce()
        #expect(!exists(url))
        #expect(store.bodyOwnershipSnapshot() == .init())
    }

    @Test func repeatedFinishAndAbandonedCaptureLeaveNothing() throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let store = env.store
        let capture = store.makeBodyCapture()
        capture.append([UInt8](repeating: 1, count: BodyCapture.spillThreshold + 1))
        let url = try #require(capture.file?.url)
        let first = capture.finish()
        #expect(first.body != nil)
        #expect(capture.finish().body == nil)
        let id = store.begin(makeFlow)
        store.update(id) { $0.requestBody = first.body }
        #expect(store.bodyOwnershipSnapshot().producerClaims == 0)
        #expect(exists(url))

        var abandoned: BodyCapture? = store.makeBodyCapture()
        abandoned?.append([UInt8](repeating: 2, count: BodyCapture.spillThreshold + 1))
        let abandonedURL = try #require(abandoned?.file?.url)
        #expect(store.bodyOwnershipSnapshot().producerClaims == 1)
        abandoned = nil
        #expect(!exists(abandonedURL))
        #expect(store.bodyOwnershipSnapshot().producerClaims == 0)
    }

    @Test func handoffConsumesTheProducerClaimOnce() throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let store = env.store
        let (body, url) = try spill(store, size: BodyCapture.spillThreshold + 1)
        let a = store.begin(makeFlow)
        let b = store.begin(makeFlow)
        store.update(a) { $0.requestBody = body }
        store.update(b) { $0.requestBody = body }
        #expect(store.bodyOwnershipSnapshot().producerClaims == 0)
        store.update(a) { $0.requestBody = nil }
        #expect(exists(url))
        store.update(b) { $0.requestBody = nil }
        #expect(!exists(url))
    }

    @Test func managedAliasesCountOnceAgainstTheRetainedMemoryLimit() {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let store = FlowStore(bodyDirectory: env.directory, maxResidentBodyBytes: 10)
        let shared = store.makeManagedBody(Data(repeating: 1, count: 8))
        let slice = HTTPBodySlice(ref: shared, offset: 0, count: 8)
        let first = store.begin(makeFlow)
        // Three references to one 8-byte body stay under the 10-byte limit.
        store.update(first) { flow in
            flow.requestBody = shared
            flow.responseBody = shared
            flow.messages[.downstreamRequest] = HTTPMessageSnapshot(
                boundary: .downstreamRequest, head: .response(status: 200, reason: nil, headers: []), body: slice,
                bodyState: .complete, observedBytes: 8, transferState: .finished)
        }
        #expect(store.allFlows().map(\.id) == [first])
        #expect(charges(store).resident == 8)

        // A distinct body is a second charge: the oldest flow goes, with its alias.
        let second = store.begin(makeFlow)
        store.update(second) { $0.requestBody = store.makeManagedBody(Data(repeating: 2, count: 8)) }
        #expect(store.allFlows().map(\.id) == [second])
        #expect(charges(store).resident == 8)
        #expect(store.bodyOwnershipSnapshot().retainedBodies == 1)
        #expect(throws: HTTPBodyError.revoked) { _ = try shared.load() }
    }

    @Test func reclaimUnlinksTheRegisteredPathAndNeverRecursesIntoASwappedInDirectory() throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let store = env.store
        let (body, url) = try spill(store, size: BodyCapture.spillThreshold + 1)
        let id = store.begin(makeFlow)
        store.update(id) { $0.requestBody = body }
        // Someone swaps the registered file for a directory holding user data.
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let precious = url.appendingPathComponent("precious.txt")
        try Data([1, 2, 3]).write(to: precious)
        store.clear()
        #expect(exists(precious), "unlink(2) cannot remove a directory, so nothing inside it is touched")
        try? FileManager.default.removeItem(at: url)
    }

    @Test func failedSpillLeavesNoFileAndNoOwnershipCell() throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        // The "body directory" is a regular file, so creating the spill file must fail.
        let blocker = env.directory.deletingLastPathComponent().appendingPathComponent("blocker-\(UUID().uuidString)")
        try Data([1]).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let store = FlowStore(bodyDirectory: blocker)
        let capture = store.makeBodyCapture()
        capture.append([UInt8](repeating: 1, count: BodyCapture.spillThreshold + 1))
        #expect(capture.isTruncated)
        let result = capture.finish()
        #expect(result.body == nil)
        #expect(result.truncated)
        #expect(store.bodyOwnershipSnapshot() == .init())
        // A sealed zero-length created file is reclaimed when its producer lets go.
        let url = env.directory.appendingPathComponent("\(UUID().uuidString).body")
        try FileManager.default.createDirectory(at: env.directory, withIntermediateDirectories: true)
        try Data().write(to: url)
        let id = store.bodies.registerCreatedFile(url)
        let handle = try #require(store.bodies.seal(id, size: 0))
        #expect(exists(url))
        withExtendedLifetime(handle) {}
        HTTPBodyRegistry.discard(store.bodies.abandonProducer(id))
        #expect(!exists(url))
        #expect(store.bodyOwnershipSnapshot() == .init())
    }

    // MARK: Races

    @Test func clearBarrierReclaimsOnlyOldBodiesWhileNewCapturesProgress() throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let store = env.store
        let (oldBody, oldURL) = try spill(store, size: BodyCapture.spillThreshold + 1)
        let oldID = store.begin(makeFlow)
        store.update(oldID) { $0.requestBody = oldBody }

        let late = store.makeBodyCapture()
        late.append([UInt8](repeating: 3, count: BodyCapture.spillThreshold + 1))
        let lateURL = try #require(late.file?.url)

        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue(label: "ownership.clear").async {
            store.clear {
                entered.signal()
                _ = resume.wait(timeout: .now() + 10)
            }
            done.signal()
        }
        try #require(entered.wait(timeout: .now() + 10) == .success)
        // State is reset, cleanup not started: a new generation keeps writing.
        let fresh = store.makeBodyCapture()
        fresh.append([UInt8](repeating: 4, count: BodyCapture.spillThreshold + 1))
        let freshURL = try #require(fresh.file?.url)
        #expect(exists(oldURL))
        resume.signal()
        try #require(done.wait(timeout: .now() + 10) == .success)

        #expect(!exists(oldURL))
        #expect(exists(lateURL))
        #expect(exists(freshURL))
        // The late result of the cleared generation cannot revive the old flow.
        store.update(oldID) { $0.responseBody = late.finish().body }
        #expect(store.flow(oldID) == nil)
        #expect(!exists(lateURL))
        // The new generation is unaffected.
        let newID = store.begin(makeFlow)
        store.update(newID) { $0.responseBody = fresh.finish().body }
        #expect(exists(freshURL))
        #expect(try #require(store.flow(newID)?.responseBody).load().count == BodyCapture.spillThreshold + 1)
        #expect(store.bodyOwnershipSnapshot().producerClaims == 0)
    }

    @Test func readerBlockedMidReadSettlesAfterClear() async throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let store = env.store
        let size = BodyCapture.spillThreshold + 1
        let (body, url) = try spill(store, size: size, byte: 6)
        let id = store.begin(makeFlow)
        store.update(id) { $0.responseBody = body }
        let lease = try store.acquireBody(body)

        let entered = OSAllocatedUnfairLock(initialState: false)
        let resumed = OSAllocatedUnfairLock(initialState: false)
        let resume = DispatchSemaphore(value: 0)
        store.bodies.readHook.withLock {
            $0 = {
                entered.withLock { $0 = true }
                let result = resume.wait(timeout: .now() + 10)
                resumed.withLock { $0 = result == .success }
            }
        }
        let inFlight = Task { try await lease.read(offset: 0, maxBytes: 8) }
        let deadline = ContinuousClock.now + .seconds(10)
        while !entered.withLock({ $0 }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(entered.withLock { $0 })
        store.bodies.readHook.withLock { $0 = nil }

        store.clear()
        store.clear()
        #expect(exists(url))
        #expect(throws: HTTPBodyError.revoked) { _ = try store.acquireBody(body) }
        await #expect(throws: HTTPBodyError.revoked) { _ = try await lease.read(offset: 0, maxBytes: 1) }

        resume.signal()
        #expect(try await inFlight.value == Data(repeating: 6, count: 8))
        #expect(resumed.withLock { $0 }, "the blocked read was released by the test, not by its timeout")
        #expect(exists(url), "the lease still holds its reader slot")
        lease.cancel()
        #expect(!exists(url))
        #expect(store.bodyOwnershipSnapshot() == .init())
    }

    // MARK: Reads

    @Test func leaseReadsAreClampedBoundedAndChecked() async throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let store = env.store
        let size = BodyCapture.spillThreshold + 1
        let (body, _) = try spill(store, size: size)
        let lease = try store.acquireBody(body)
        defer { lease.cancel() }
        #expect(lease.size == size)
        #expect(try await lease.read(offset: 0, maxBytes: 1_000_000).count == HTTPBodyReadLease.maxReadBytes)
        #expect(try await lease.read(offset: size - 3, maxBytes: 100).count == 3)
        #expect(try await lease.read(offset: size, maxBytes: 100).isEmpty)
        await #expect(throws: HTTPBodyError.invalidRange) { _ = try await lease.read(offset: size + 1, maxBytes: 1) }
        await #expect(throws: HTTPBodyError.invalidRange) { _ = try await lease.read(offset: -1, maxBytes: 1) }
        lease.cancel()
        await #expect(throws: HTTPBodyError.cancelled) { _ = try await lease.read(offset: 0, maxBytes: 1) }
    }

    @Test func legacySynchronousLoadsReadManagedBodiesInChunks() throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let size = BodyCapture.spillThreshold + 1
        let (body, _) = try spill(env.store, size: size, byte: 8)
        #expect(try body.load() == Data(repeating: 8, count: size))
        let prefix = try body.load(maxBytes: 70_000)
        #expect(prefix.data == Data(repeating: 8, count: 70_000))
        #expect(prefix.isTruncated)
        let whole = try body.load(maxBytes: size)
        #expect(!whole.isTruncated)
        #expect(try managedMemory(env.store, Data([1, 2])).load(maxBytes: 1) == (Data([1]), true))
    }

    @Test func disjointStoresDoNotShareOwnership() throws {
        let first = TestEnvironment()
        let second = TestEnvironment()
        defer { first.cleanUp(); second.cleanUp() }
        let body = managedMemory(first.store, Data([1, 2, 3]))
        let id = second.store.begin(makeFlow)
        second.store.update(id) { $0.requestBody = body }
        #expect(charges(second.store) == (0, 0))
        #expect(first.store.bodyOwnershipSnapshot().retainedBodies == 0)
    }
}
