import Darwin
import Foundation
import os
import Testing
@testable import RulesEngine

// MARK: shared support (also used by RuleRepositoryTests)

/// A fresh temporary directory, removed by the caller with `removeTree`.
func makeTempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("pw-rules-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func removeTree(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

@discardableResult
func writeFile(_ url: URL, _ data: Data) -> URL {
    FileManager.default.createFile(atPath: url.path, contents: data)
    return url
}

func names(in directory: URL) -> Set<String> {
    Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
}

func mode(of url: URL) -> mode_t {
    var info = stat()
    lstat(url.path, &info)
    return info.st_mode & 0o777
}

func directoryBytes(_ directory: URL) -> Int64 {
    names(in: directory).reduce(0) { total, name in
        let size = (try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)[.size]) as? Int64
        return total + (size ?? 0)
    }
}

func ample(_ directory: URL) -> Int64? { Int64.max / 2 }

func randomData(_ count: Int) -> Data {
    Data((0..<count).map { _ in UInt8.random(in: 0...255) })
}

/// Reads the whole lease in bounded chunks.
func readAll(_ lease: OwnedFileLease) async throws -> Data {
    var data = Data()
    while true {
        let chunk = try await lease.read(offset: Int64(data.count), maxBytes: 65_536)
        if chunk.isEmpty { return data }
        data.append(chunk)
    }
}

func waitUntil(_ what: String, timeout: Duration = .seconds(5), _ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw OwnedFileError(.cancelled) }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// Free-disk probe for tests: the floor plus `headroom`.
struct DiskProbe {
    static func floorPlus(_ headroom: Int64, limits: RulesLimits) -> @Sendable (URL) -> Int64? {
        { _ in Int64(limits.minimumFreeDiskBytes) + headroom }
    }
}

// MARK: tests

@Suite struct ManagedAssetTests {
    @Test func importCopiesExactBytesIntoPrivateFilesAndNeverTouchesTheOriginal() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let assetsDir = root.appendingPathComponent("assets")
        let budgets = OwnedFileBudgets(limits: RulesLimits(), freeDiskBytes: ample)
        let store = ManagedAssetStore(directory: assetsDir, limits: RulesLimits(), budgets: budgets)
        let bytes = randomData(200_000)
        let original = writeFile(root.appendingPathComponent("user.bin"), bytes)

        let asset = try await store.importFile(original, displayName: "user.bin")
        #expect(asset.size == 200_000)
        #expect(asset.displayName == "user.bin")
        #expect(mode(of: assetsDir) == 0o700)
        #expect(mode(of: assetsDir.appendingPathComponent(asset.id.uuidString + ".asset")) == 0o600)
        #expect(names(in: assetsDir) == [asset.id.uuidString + ".asset"])
        #expect(budgets.snapshot().bytes[.asset] == 200_000)
        #expect((budgets.snapshot().peak[.io] ?? 0) <= 65_536)

        // Changing the original later never changes the imported copy.
        writeFile(original, Data("changed".utf8))
        let lease = try await store.lease(asset.id)
        #expect(lease.size == 200_000)
        #expect(try await readAll(lease) == bytes)
        lease.cancel()

        await store.discardImports([asset.id])
        try await waitUntil("copy reclaimed") { names(in: assetsDir).isEmpty && budgets.snapshot().reservedBytes == 0 }
        #expect(FileManager.default.fileExists(atPath: original.path))
    }

    @Test func symlinkFIFODeviceAndDirectorySourcesAreRejected() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let assetsDir = root.appendingPathComponent("assets")
        let budgets = OwnedFileBudgets(limits: RulesLimits(), freeDiskBytes: ample)
        let store = ManagedAssetStore(directory: assetsDir, limits: RulesLimits(), budgets: budgets)
        let target = writeFile(root.appendingPathComponent("real.bin"), Data("x".utf8))
        let link = root.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let fifo = root.appendingPathComponent("pipe")
        #expect(mkfifo(fifo.path, 0o600) == 0)

        for source in [link, fifo, URL(fileURLWithPath: "/dev/null"), root] {
            await #expect(throws: OwnedFileError(.notRegularFile)) {
                _ = try await store.importFile(source, displayName: "x")
            }
        }
        #expect(names(in: assetsDir).isEmpty)
        #expect(budgets.snapshot().reservedBytes == 0)
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test func sourceChangedOrTruncatedDuringCopyFailsAndLeavesNothing() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let assetsDir = root.appendingPathComponent("assets")
        let source = writeFile(root.appendingPathComponent("grow.bin"), randomData(200_000))
        let shrink = writeFile(root.appendingPathComponent("shrink.bin"), randomData(200_000))
        let budgets = OwnedFileBudgets(limits: RulesLimits(), freeDiskBytes: ample)
        let growing = ManagedAssetStore(directory: assetsDir, limits: RulesLimits(), budgets: budgets, afterChunk: { copied in
            guard copied == 65_536, let handle = FileHandle(forWritingAtPath: source.path) else { return }
            handle.seekToEndOfFile(); handle.write(Data("more".utf8)); handle.closeFile()
        })
        let shrinking = ManagedAssetStore(directory: assetsDir, limits: RulesLimits(), budgets: budgets, afterChunk: { copied in
            if copied == 65_536 { truncate(shrink.path, 70_000) }
        })

        await #expect(throws: OwnedFileError(.sourceChanged)) { _ = try await growing.importFile(source, displayName: "g") }
        await #expect(throws: OwnedFileError(.shortRead)) { _ = try await shrinking.importFile(shrink, displayName: "s") }
        #expect(names(in: assetsDir).isEmpty)
        #expect(budgets.snapshot().reservedBytes == 0)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: shrink.path))
    }

    @Test func singleFileAndStoreBudgetsAreEnforcedBeforeCopying() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let assetsDir = root.appendingPathComponent("assets")
        let limits = RulesLimits(assetFileBytes: 100_000, assetStoreBytes: 150_000)
        let budgets = OwnedFileBudgets(limits: limits, freeDiskBytes: ample)
        let store = ManagedAssetStore(directory: assetsDir, limits: limits, budgets: budgets)
        let exact = writeFile(root.appendingPathComponent("exact.bin"), randomData(100_000))
        let over = writeFile(root.appendingPathComponent("over.bin"), randomData(100_001))

        await #expect(throws: OwnedFileError(.fileTooLarge)) { _ = try await store.importFile(over, displayName: "o") }
        let first = try await store.importFile(exact, displayName: "e")
        #expect(first.size == 100_000)
        await #expect(throws: OwnedFileError(.capacityExceeded)) { _ = try await store.importFile(exact, displayName: "e2") }
        #expect(names(in: assetsDir) == [first.id.uuidString + ".asset"])
        #expect(budgets.snapshot().bytes[.asset] == 100_000)
    }

    @Test func importOverDefaultFileLimitFailsWithoutCopying() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let assetsDir = root.appendingPathComponent("assets")
        let budgets = OwnedFileBudgets(limits: RulesLimits(), freeDiskBytes: ample)
        let store = ManagedAssetStore(directory: assetsDir, limits: RulesLimits(), budgets: budgets)
        // Sparse: 512 MiB + 1 byte without writing it.
        let huge = writeFile(root.appendingPathComponent("huge.bin"), Data())
        #expect(truncate(huge.path, off_t(RulesLimits().assetFileBytes) + 1) == 0)

        await #expect(throws: OwnedFileError(.fileTooLarge)) { _ = try await store.importFile(huge, displayName: "h") }
        #expect(names(in: assetsDir).isEmpty)
        #expect(budgets.snapshot().peak[.io] == nil)
    }

    @Test func freeDiskFloorIsCheckedPerChunk() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let assetsDir = root.appendingPathComponent("assets")
        let limits = RulesLimits()
        // The volume has 150,000 bytes above the floor, minus whatever the store has written.
        let budgets = OwnedFileBudgets(limits: limits, freeDiskBytes: { _ in
            Int64(limits.minimumFreeDiskBytes) + 150_000 - directoryBytes(assetsDir)
        })
        let store = ManagedAssetStore(directory: assetsDir, limits: limits, budgets: budgets)
        let fits = writeFile(root.appendingPathComponent("fits.bin"), randomData(65_536))
        let tooBig = writeFile(root.appendingPathComponent("big.bin"), randomData(100_000))

        let kept = try await store.importFile(fits, displayName: "f")
        // The first chunk of the second file still fits; the second chunk would cross the floor.
        await #expect(throws: OwnedFileError(.insufficientDiskSpace)) { _ = try await store.importFile(tooBig, displayName: "b") }
        #expect(names(in: assetsDir) == [kept.id.uuidString + ".asset"])
        #expect(budgets.snapshot().bytes[.asset] == 65_536)
    }

    @Test func cancellingTheImportTaskLeavesNoFileOrReservation() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let assetsDir = root.appendingPathComponent("assets")
        let gate = DispatchSemaphore(value: 0)
        let reached = DispatchSemaphore(value: 0)
        let budgets = OwnedFileBudgets(limits: RulesLimits(), freeDiskBytes: ample)
        let store = ManagedAssetStore(directory: assetsDir, limits: RulesLimits(), budgets: budgets, afterChunk: { copied in
            if copied == 65_536 { reached.signal(); gate.wait() }
        })
        let source = writeFile(root.appendingPathComponent("src.bin"), randomData(300_000))
        let task = Task { try await store.importFile(source, displayName: "s") }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { reached.wait(); continuation.resume() }
        }
        task.cancel()
        // The copy is still running: its reservations are still held.
        #expect(budgets.snapshot().bytes[.asset] == 300_000)
        gate.signal()
        await #expect(throws: OwnedFileError(.cancelled)) { _ = try await task.value }
        #expect(names(in: assetsDir).isEmpty)
        #expect(budgets.snapshot().reservedBytes == 0)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func aSlowImportDoesNotDelayLeaseReads() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let gate = DispatchSemaphore(value: 0)
        let reached = DispatchSemaphore(value: 0)
        let budgets = OwnedFileBudgets(limits: RulesLimits(), freeDiskBytes: ample)
        let store = ManagedAssetStore(directory: root.appendingPathComponent("assets"), limits: RulesLimits(), budgets: budgets,
                                      afterChunk: { copied in if copied == 65_536 { reached.signal(); gate.wait() } })
        // The first import is small (one chunk ends at 1,000 bytes, so the hook never blocks it).
        let bytes = randomData(1_000)
        let ready = try await store.importFile(writeFile(root.appendingPathComponent("ready"), bytes), displayName: "r")
        let slow = Task { try await store.importFile(writeFile(root.appendingPathComponent("slow"), randomData(200_000)), displayName: "s") }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { reached.wait(); continuation.resume() }
        }
        // The import job is parked mid-copy; a live read must still complete promptly.
        let read = Task { () throws -> Data in
            let lease = try await store.lease(ready.id)
            defer { lease.cancel() }
            return try await readAll(lease)
        }
        let deadline = ContinuousClock.now + .seconds(2)
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask { _ = try? await read.value; return true }
            group.addTask {
                try? await Task.sleep(until: deadline)
                gate.signal()  // on a regression the reader is stuck behind the import: unblock it
                return false
            }
            let first = await group.next()!
            group.cancelAll()
            return first
        }
        if finished { gate.signal() }
        #expect(finished)
        #expect(try await read.value == bytes)
        _ = try await slow.value
    }

    @Test func leaseSurvivesReferenceRemovalAndLastReleaseReclaimsOnlyTheOwnedCopy() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let assetsDir = root.appendingPathComponent("assets")
        let budgets = OwnedFileBudgets(limits: RulesLimits(), freeDiskBytes: ample)
        let store = ManagedAssetStore(directory: assetsDir, limits: RulesLimits(), budgets: budgets)
        let bytes = randomData(100_000)
        let original = writeFile(root.appendingPathComponent("user.bin"), bytes)
        let asset = try await store.importFile(original, displayName: "u")
        await store.commitReferences(try await store.prepareReferences([asset.id]))

        let lease = try await store.lease(asset.id)
        // The rule is deleted and saved: the copy must stay readable while leased.
        await store.commitReferences(try await store.prepareReferences([]))
        #expect(names(in: assetsDir) == [asset.id.uuidString + ".asset"])
        #expect(try await readAll(lease) == bytes)

        lease.cancel()
        lease.cancel()
        // The file goes first, then its reservation (after the unlink has settled).
        try await waitUntil("copy reclaimed") { names(in: assetsDir).isEmpty && budgets.snapshot().reservedBytes == 0 }
        #expect(FileManager.default.fileExists(atPath: original.path))
        await #expect(throws: OwnedFileError(.unknownAsset)) { _ = try await store.lease(asset.id) }
    }

    @Test func rollbackReleasesOnlyPendingPinsAndUnknownIDsPinNothing() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let assetsDir = root.appendingPathComponent("assets")
        let budgets = OwnedFileBudgets(limits: RulesLimits(), freeDiskBytes: ample)
        let store = ManagedAssetStore(directory: assetsDir, limits: RulesLimits(), budgets: budgets)
        let source = writeFile(root.appendingPathComponent("s.bin"), randomData(1_000))
        let a = try await store.importFile(source, displayName: "a")
        let b = try await store.importFile(source, displayName: "b")
        await store.commitReferences(try await store.prepareReferences([a.id]))

        await store.rollbackReferences(try await store.prepareReferences([a.id, b.id]))
        #expect(await store.asset(a.id) == a)
        #expect(await store.asset(b.id) == b)  // a fresh import stays available to the editor's draft
        await #expect(throws: OwnedFileError(.unknownAsset)) { _ = try await store.prepareReferences([a.id, UUID()]) }

        // Discarding a persisted asset is refused; discarding the draft reclaims it.
        await store.discardImports([a.id, b.id])
        try await waitUntil("draft reclaimed") {
            await store.asset(b.id) == nil && names(in: assetsDir) == [a.id.uuidString + ".asset"]
        }
        #expect(await store.asset(a.id) == a)
    }

    @Test func leaseReadsAreBoundedAndEndAfterCancel() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let budgets = OwnedFileBudgets(limits: RulesLimits(), freeDiskBytes: ample)
        let store = ManagedAssetStore(directory: root.appendingPathComponent("assets"), limits: RulesLimits(), budgets: budgets)
        let asset = try await store.importFile(writeFile(root.appendingPathComponent("s"), randomData(200_000)), displayName: "s")
        let lease = try await store.lease(asset.id)
        #expect(try await lease.read(offset: 0, maxBytes: 1_000_000).count == 65_536)
        #expect(try await lease.read(offset: 200_000, maxBytes: 10).isEmpty)
        lease.cancel()
        await #expect(throws: OwnedFileError(.cancelled)) { _ = try await lease.read(offset: 0, maxBytes: 1) }
    }
}

extension ManagedAssetTests {
    @Test func editorReservationsUseIndependentSharedMemoryCap() throws {
        var limits = RulesLimits(); limits.editorMemoryBytes = 12; limits.ioBufferBytes = 4
        let budgets = OwnedFileBudgets(limits: limits)
        let first = try budgets.reserve(category: .editor, bytes: 8)
        let second = try budgets.reserve(category: .editor, bytes: 4)
        #expect(throws: OwnedFileError(.capacityExceeded)) { _ = try budgets.reserve(category: .editor, bytes: 1) }
        let io = try budgets.reserve(category: .io, bytes: 4)
        #expect(budgets.snapshot().bytes[.editor] == 12 && budgets.snapshot().bytes[.io] == 4)
        first.release(); first.release(); second.release(); io.release()
        #expect(budgets.snapshot().reservedBytes == 0)
    }
}

// MARK: importStream

/// Serves `data` like a lease: at most `maxBytes` from `offset`, empty at the end. Records every request.
private final class StreamSource: Sendable {
    private let data: Data
    private let requests = OSAllocatedUnfairLock(initialState: [(offset: Int64, maxBytes: Int)]())

    init(_ data: Data) { self.data = data }

    var calls: [(offset: Int64, maxBytes: Int)] { requests.withLock { $0 } }

    func read(_ offset: Int64, _ maxBytes: Int) async throws -> Data {
        requests.withLock { $0.append((offset, maxBytes)) }
        let start = Int(offset)
        guard start < data.count else { return Data() }
        return data.subdata(in: start..<min(data.count, start + maxBytes))
    }
}

extension ManagedAssetTests {
    @Test func importStreamCopiesAllBytesInChunks() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let assetsDir = root.appendingPathComponent("assets")
        let budgets = OwnedFileBudgets(limits: RulesLimits(), freeDiskBytes: ample)
        let chunks = OSAllocatedUnfairLock(initialState: [Int64]())
        let store = ManagedAssetStore(directory: assetsDir, limits: RulesLimits(), budgets: budgets,
                                      afterChunk: { copied in chunks.withLock { $0.append(copied) } })
        let bytes = randomData(200_000)
        let source = StreamSource(bytes)

        let asset = try await store.importStream(expectedSize: 200_000, displayName: "captured") { try await source.read($0, $1) }
        #expect(asset.size == 200_000 && asset.displayName == "captured")
        #expect(source.calls.allSatisfy { $0.maxBytes <= RulesLimits().ioChunkBytes })
        #expect(source.calls.map(\.offset) == [0, 65_536, 131_072, 196_608])
        let copied = chunks.withLock { $0 }
        #expect(copied == [65_536, 131_072, 196_608, 200_000])
        #expect(zip([0] + copied, copied).allSatisfy { $1 - $0 <= Int64(RulesLimits().ioChunkBytes) })
        #expect(names(in: assetsDir) == [asset.id.uuidString + ".asset"])
        #expect(mode(of: assetsDir.appendingPathComponent(asset.id.uuidString + ".asset")) == 0o600)
        #expect(budgets.snapshot().bytes[.asset] == 200_000)
        #expect((budgets.snapshot().peak[.io] ?? 0) <= 65_536)
        let lease = try await store.lease(asset.id)
        #expect(try await readAll(lease) == bytes)
        lease.cancel()

        // A fresh import is a draft: the window can discard it.
        await store.discardImports([asset.id])
        try await waitUntil("copy reclaimed") { names(in: assetsDir).isEmpty && budgets.snapshot().reservedBytes == 0 }
    }

    @Test func importStreamOfEmptyBodyMakesAnEmptyAsset() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let budgets = OwnedFileBudgets(limits: RulesLimits(), freeDiskBytes: ample)
        let store = ManagedAssetStore(directory: root.appendingPathComponent("assets"), limits: RulesLimits(), budgets: budgets)
        let asset = try await store.importStream(expectedSize: 0, displayName: "e") { _, _ in
            Issue.record("nothing to read")
            return Data()
        }
        #expect(asset.size == 0)
    }

    @Test func importStreamShortReadFailsAndLeavesNoFileOrReservation() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let assetsDir = root.appendingPathComponent("assets")
        let budgets = OwnedFileBudgets(limits: RulesLimits(), freeDiskBytes: ample)
        let store = ManagedAssetStore(directory: assetsDir, limits: RulesLimits(), budgets: budgets)
        // The source ends after 100,000 of the announced 200,000 bytes.
        let source = StreamSource(randomData(100_000))
        await #expect(throws: OwnedFileError(.shortRead)) {
            _ = try await store.importStream(expectedSize: 200_000, displayName: "s") { try await source.read($0, $1) }
        }
        #expect(names(in: assetsDir).isEmpty)
        #expect(budgets.snapshot().reservedBytes == 0)
    }

    @Test func importStreamLongerThanExpectedFails() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let assetsDir = root.appendingPathComponent("assets")
        let budgets = OwnedFileBudgets(limits: RulesLimits(), freeDiskBytes: ample)
        let store = ManagedAssetStore(directory: assetsDir, limits: RulesLimits(), budgets: budgets)
        // A reader that ignores the bound it was given.
        await #expect(throws: OwnedFileError(.lengthMismatch)) {
            _ = try await store.importStream(expectedSize: 1_000, displayName: "l") { _, _ in randomData(2_000) }
        }
        // And one that overshoots the announced total on its last chunk.
        await #expect(throws: OwnedFileError(.lengthMismatch)) {
            _ = try await store.importStream(expectedSize: 70_000, displayName: "l") { offset, _ in
                randomData(offset == 0 ? 65_536 : 65_536)
            }
        }
        #expect(names(in: assetsDir).isEmpty)
        #expect(budgets.snapshot().reservedBytes == 0)
    }

    @Test func importStreamReaderErrorCleansUp() async throws {
        struct Boom: Error {}
        let root = makeTempDirectory(); defer { removeTree(root) }
        let assetsDir = root.appendingPathComponent("assets")
        let budgets = OwnedFileBudgets(limits: RulesLimits(), freeDiskBytes: ample)
        let store = ManagedAssetStore(directory: assetsDir, limits: RulesLimits(), budgets: budgets)
        let source = StreamSource(randomData(300_000))
        await #expect(throws: Boom.self) {
            _ = try await store.importStream(expectedSize: 300_000, displayName: "b") { offset, max in
                if offset >= 65_536 { throw Boom() }
                return try await source.read(offset, max)
            }
        }
        #expect(names(in: assetsDir).isEmpty)
        #expect(budgets.snapshot().reservedBytes == 0)
    }

    @Test func cancelledImportStreamLeavesNoFileOrReservation() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let assetsDir = root.appendingPathComponent("assets")
        let budgets = OwnedFileBudgets(limits: RulesLimits(), freeDiskBytes: ample)
        let store = ManagedAssetStore(directory: assetsDir, limits: RulesLimits(), budgets: budgets)
        let source = StreamSource(randomData(300_000))
        let reached = AsyncStream<Void>.makeStream()
        let gate = AsyncStream<Void>.makeStream()
        let task = Task {
            try await store.importStream(expectedSize: 300_000, displayName: "c") { offset, max in
                if offset == 65_536 {
                    reached.continuation.yield()
                    var iterator = gate.stream.makeAsyncIterator()
                    await iterator.next()
                }
                return try await source.read(offset, max)
            }
        }
        var arrivals = reached.stream.makeAsyncIterator()
        await arrivals.next()
        // Parked in the second chunk: the asset budget is held.
        #expect(budgets.snapshot().bytes[.asset] == 300_000)
        task.cancel()
        gate.continuation.yield()
        await #expect(throws: OwnedFileError(.cancelled)) { _ = try await task.value }
        #expect(names(in: assetsDir).isEmpty)
        #expect(budgets.snapshot().reservedBytes == 0)
    }

    @Test func importStreamTooLargeRejectedBeforeAnyRead() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let assetsDir = root.appendingPathComponent("assets")
        let limits = RulesLimits(assetFileBytes: 100_000)
        let budgets = OwnedFileBudgets(limits: limits, freeDiskBytes: ample)
        let store = ManagedAssetStore(directory: assetsDir, limits: limits, budgets: budgets)
        let source = StreamSource(randomData(10))
        await #expect(throws: OwnedFileError(.fileTooLarge)) {
            _ = try await store.importStream(expectedSize: 100_001, displayName: "t") { try await source.read($0, $1) }
        }
        #expect(source.calls.isEmpty)
        #expect(names(in: assetsDir).isEmpty)
        #expect(budgets.snapshot().reservedBytes == 0)
        // An over-long name is refused too, also before reading.
        await #expect(throws: OwnedFileError(.invalidName)) {
            _ = try await store.importStream(expectedSize: 1, displayName: String(repeating: "n", count: limits.fieldBytes + 1)) {
                try await source.read($0, $1)
            }
        }
        #expect(source.calls.isEmpty)
    }

    @Test func importStreamCapacityExceededRejected() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let assetsDir = root.appendingPathComponent("assets")
        let limits = RulesLimits(assetFileBytes: 100_000, assetStoreBytes: 150_000)
        let budgets = OwnedFileBudgets(limits: limits, freeDiskBytes: ample)
        let store = ManagedAssetStore(directory: assetsDir, limits: limits, budgets: budgets)
        let first = try await store.importStream(expectedSize: 100_000, displayName: "a") { offset, max in
            Data(repeating: 1, count: min(max, 100_000 - Int(offset)))
        }
        let source = StreamSource(randomData(100_000))
        await #expect(throws: OwnedFileError(.capacityExceeded)) {
            _ = try await store.importStream(expectedSize: 100_000, displayName: "b") { try await source.read($0, $1) }
        }
        #expect(source.calls.isEmpty)
        #expect(names(in: assetsDir) == [first.id.uuidString + ".asset"])
        #expect(budgets.snapshot().bytes[.asset] == 100_000)
    }

    @Test func importStreamRespectsFreeDiskFloor() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let assetsDir = root.appendingPathComponent("assets")
        let limits = RulesLimits()
        let budgets = OwnedFileBudgets(limits: limits, freeDiskBytes: { _ in
            Int64(limits.minimumFreeDiskBytes) + 100_000 - directoryBytes(assetsDir)
        })
        let store = ManagedAssetStore(directory: assetsDir, limits: limits, budgets: budgets)
        let source = StreamSource(randomData(200_000))
        // The first chunk fits above the floor; the second would cross it.
        await #expect(throws: OwnedFileError(.insufficientDiskSpace)) {
            _ = try await store.importStream(expectedSize: 200_000, displayName: "d") { try await source.read($0, $1) }
        }
        #expect(names(in: assetsDir).isEmpty)
        #expect(budgets.snapshot().reservedBytes == 0)
    }
}
