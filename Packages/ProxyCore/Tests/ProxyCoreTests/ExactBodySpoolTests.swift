import Darwin
import FlowStore
import Foundation
import NIOCore
import NIOPosix
import RulesEngine
import Testing
@testable import ProxyCore

/// One event loop, one file pool and a temp directory; everything is shut down by `close()`.
private final class SpoolFixture: Sendable {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let pool = NIOThreadPool(numberOfThreads: 2)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pw-spool-\(UUID().uuidString)")
    let limits: RulesLimits
    let budgets: OwnedFileBudgets
    let io: BodyFileIO
    var loop: EventLoop { io.eventLoop }
    var directory: URL { root.appendingPathComponent("spool") }

    init(limits: RulesLimits = RulesLimits(), freeDisk: @escaping @Sendable (URL) -> Int64? = { _ in Int64.max / 2 },
         beforeWrite: (@Sendable () -> Void)? = nil, afterImportChunk: (@Sendable (Int64) -> Void)? = nil) {
        pool.start()
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.limits = limits
        budgets = OwnedFileBudgets(limits: limits, freeDiskBytes: freeDisk)
        io = BodyFileIO(directory: root.appendingPathComponent("spool"), eventLoop: group.next(), budgets: budgets,
                        limits: limits, threadPool: pool, hooks: BodyFileIOHooks(beforeWrite: beforeWrite, afterImportChunk: afterImportChunk))
    }

    func close() async throws {
        try? await pool.shutdownGracefully()  // some tests already stopped it
        try await group.shutdownGracefully()
        try? FileManager.default.removeItem(at: root)
    }

    var files: Set<String> { Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []) }

    func spool(_ category: ExactBodyCategory = .breakpoint, expected: Int64?) async throws -> ExactBodySpool {
        try await loop.submit { try ExactBodySpool(category: category, expectedLength: expected, limits: self.limits, io: self.io) }.get()
    }

    func append(_ spool: ExactBodySpool, _ bytes: [UInt8]) async throws {
        try await loop.flatSubmit { spool.append(ByteBuffer(bytes: bytes)) }.get()
    }

    func appendFuture(_ spool: ExactBodySpool, _ bytes: [UInt8]) async throws -> EventLoopFuture<Void> {
        try await loop.submit { spool.append(ByteBuffer(bytes: bytes)) }.get()
    }

    func finish(_ spool: ExactBodySpool, trailers: [HeaderField] = []) async throws -> ExactBodySource {
        try await loop.flatSubmit { spool.finish(trailers: trailers) }.get()
    }

    func waitUntilReleased() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        // Reservations and files are released together, after the file work has settled.
        while budgets.snapshot().reservedBytes != 0 || !files.isEmpty {
            guard ContinuousClock.now < deadline else {
                throw WaitTimeout(description: "reservations \(budgets.snapshot()), files \(files)")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private func bytes(_ count: Int, seed: UInt8 = 1) -> [UInt8] {
    (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) }
}

private func readAll(_ source: ExactBodySource) async throws -> [UInt8] {
    var data = [UInt8]()
    while true {
        let chunk = try await source.read(offset: Int64(data.count), maxBytes: 1 << 20)
        #expect(chunk.count <= 65_536)
        if chunk.isEmpty { return data }
        data.append(contentsOf: chunk)
    }
}

/// A gate the file pool blocks on, released by the test.
private final class WriteGate: Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    var hook: @Sendable () -> Void { { self.entered.signal(); self.release.wait() } }
    func waitEntered() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { self.entered.wait(); continuation.resume() }
        }
    }
}

@Suite(.productionChinese) struct ExactBodySpoolTests {
    @Test func exactBodyRoundTripsThroughAPrivateFileAndIsReclaimedOnCancel() async throws {
        let fixture = SpoolFixture()
        let body = bytes(200_000)
        let spool = try await fixture.spool(expected: Int64(body.count))
        for start in stride(from: 0, to: body.count, by: 65_536) {
            try await fixture.append(spool, Array(body[start..<min(start + 65_536, body.count)]))
        }
        let trailers = [HeaderField(name: "x-checksum", value: "1")]
        let source = try await fixture.finish(spool, trailers: trailers)
        #expect(source.size == 200_000)
        #expect(source.trailers == trailers)
        #expect(try await readAll(source) == body)
        let file = try #require(fixture.files.first)
        #expect(fixture.files.count == 1)
        #expect(file.hasSuffix(".body"))
        var info = stat()
        lstat(fixture.directory.appendingPathComponent(file).path, &info)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(fixture.budgets.snapshot().bytes[.breakpoint] == 200_000)
        #expect((fixture.budgets.snapshot().peak[.io] ?? 0) <= 65_536)

        source.cancel()
        try await fixture.waitUntilReleased()
        #expect(fixture.files.isEmpty)
        try await fixture.close()
    }

    @Test func knownOversizedBodyIsRejectedBeforeAnyReservation() async throws {
        let fixture = SpoolFixture()
        await #expect(throws: OwnedFileError(.fileTooLarge)) {
            _ = try await fixture.spool(expected: Int64(RulesLimits().breakpointBodyBytes) + 1)
        }
        await #expect(throws: OwnedFileError(.fileTooLarge)) {
            _ = try await fixture.spool(.compose, expected: Int64(RulesLimits().composeBodyBytes) + 1)
        }
        #expect(fixture.budgets.snapshot().reservedBytes == 0)
        #expect(fixture.files.isEmpty)
        try await fixture.close()
    }

    @Test func unknownLengthOverTheLimitFailsInsteadOfYieldingAPrefix() async throws {
        let fixture = SpoolFixture(limits: RulesLimits(breakpointBodyBytes: 3 * 65_536))
        let spool = try await fixture.spool(expected: nil)
        for _ in 0..<3 { try await fixture.append(spool, bytes(65_536)) }
        await #expect(throws: OwnedFileError(.fileTooLarge)) { try await fixture.append(spool, [0]) }
        await #expect(throws: OwnedFileError(.fileTooLarge)) { _ = try await fixture.finish(spool) }
        try await fixture.waitUntilReleased()
        #expect(fixture.files.isEmpty)
        try await fixture.close()
    }

    @Test func shortOrOverlongBodiesNeverSucceed() async throws {
        let fixture = SpoolFixture()
        let short = try await fixture.spool(expected: 10)
        try await fixture.append(short, bytes(5))
        await #expect(throws: OwnedFileError(.lengthMismatch)) { _ = try await fixture.finish(short) }

        let long = try await fixture.spool(expected: 10)
        await #expect(throws: OwnedFileError(.lengthMismatch)) { try await fixture.append(long, bytes(11)) }

        let missing = try await fixture.spool(expected: 10)
        await #expect(throws: OwnedFileError(.lengthMismatch)) { _ = try await fixture.finish(missing) }

        // An empty body announced as empty is complete.
        let empty = try await fixture.finish(try await fixture.spool(expected: 0))
        #expect(empty.size == 0)
        empty.cancel()
        try await fixture.waitUntilReleased()
        #expect(fixture.files.isEmpty)
        try await fixture.close()
    }

    @Test func chunksAreBoundedAndOnlyOneAppendIsInFlight() async throws {
        let gate = WriteGate()
        let fixture = SpoolFixture(beforeWrite: gate.hook)
        let tooBig = try await fixture.spool(expected: nil)
        await #expect(throws: OwnedFileError(.chunkTooLarge)) { try await fixture.append(tooBig, bytes(65_537)) }

        let spool = try await fixture.spool(expected: nil)
        let pending = try await fixture.appendFuture(spool, bytes(100))
        await gate.waitEntered()
        await #expect(throws: OwnedFileError(.operationInFlight)) { try await fixture.append(spool, bytes(1)) }
        gate.release.signal()
        try await pending.get()
        try await fixture.loop.submit { #expect(spool.bytesWritten == 100) }.get()
        try await loopCancel(fixture, spool)
        try await fixture.waitUntilReleased()
        try await fixture.close()
    }

    @Test func inFlightBuffersShareOneGlobalBudget() async throws {
        let gate = WriteGate()
        let fixture = SpoolFixture(limits: RulesLimits(ioBufferBytes: 2 * 65_536), beforeWrite: gate.hook)
        let spools = [try await fixture.spool(expected: nil), try await fixture.spool(expected: nil), try await fixture.spool(expected: nil)]
        let first = try await fixture.appendFuture(spools[0], bytes(65_536))
        await gate.waitEntered()
        let second = try await fixture.appendFuture(spools[1], bytes(65_536))
        await #expect(throws: OwnedFileError(.capacityExceeded)) { try await fixture.append(spools[2], bytes(1)) }
        #expect(fixture.budgets.snapshot().bytes[.io] == 131_072)
        gate.release.signal()
        await gate.waitEntered()
        gate.release.signal()
        try await first.get()
        try await second.get()
        #expect(fixture.budgets.snapshot().bytes[.io] == nil)
        #expect(fixture.budgets.snapshot().peak[.io] == 131_072)
        for spool in spools { try await loopCancel(fixture, spool) }
        try await fixture.waitUntilReleased()
        #expect(fixture.files.isEmpty)
        try await fixture.close()
    }

    @Test func cancelDuringAPendingWriteKeepsCapacityUntilTheWriteSettles() async throws {
        let gate = WriteGate()
        let fixture = SpoolFixture(beforeWrite: gate.hook)
        let spool = try await fixture.spool(expected: 1_000)
        let pending = try await fixture.appendFuture(spool, bytes(500))
        await gate.waitEntered()
        spool.cancel()
        try await fixture.loop.submit {}.get()
        // The write is still running on the pool: nothing may be handed back yet.
        #expect(fixture.budgets.snapshot().bytes[.breakpoint] == 1_000)
        #expect(fixture.budgets.snapshot().bytes[.io] == 500)
        gate.release.signal()
        await #expect(throws: OwnedFileError(.cancelled)) { try await pending.get() }
        try await fixture.waitUntilReleased()
        #expect(fixture.budgets.snapshot().reservedBytes == 0)
        #expect(fixture.files.isEmpty)
        await #expect(throws: OwnedFileError(.cancelled)) { _ = try await fixture.finish(spool) }
        try await fixture.close()
    }

    @Test func aggregateSpoolBudgetAndFreeDiskFloorAreEnforced() async throws {
        let limits = RulesLimits(breakpointSpoolBytes: 100_000)
        let fixture = SpoolFixture(limits: limits, freeDisk: { _ in Int64(limits.minimumFreeDiskBytes) + 1_000 })
        let first = try await fixture.spool(expected: 60_000)
        await #expect(throws: OwnedFileError(.capacityExceeded)) { _ = try await fixture.spool(expected: 60_000) }
        // Only 1,000 bytes above the free-disk floor.
        try await fixture.append(first, bytes(1_000))
        await #expect(throws: OwnedFileError(.insufficientDiskSpace)) { try await fixture.append(first, bytes(1_001)) }
        try await fixture.waitUntilReleased()
        #expect(fixture.files.isEmpty)
        try await fixture.close()
    }

    @Test func importRegularFileCopiesExactlyAndRejectsUnsafeOrOversizedSources() async throws {
        let fixture = SpoolFixture(limits: RulesLimits(composeBodyBytes: 300_000))
        let body = Data(bytes(300_000))
        let source = fixture.root.appendingPathComponent("user.bin")
        FileManager.default.createFile(atPath: source.path, contents: body)

        let imported = try await fixture.io.importRegularFile(source: source, limit: 1 << 40, category: .compose)
        #expect(imported.size == 300_000)
        #expect(Data(try await readAll(imported)) == body)
        #expect((fixture.budgets.snapshot().peak[.io] ?? 0) <= 65_536)
        #expect(fixture.budgets.snapshot().bytes[.compose] == 300_000)

        let over = fixture.root.appendingPathComponent("over.bin")
        FileManager.default.createFile(atPath: over.path, contents: Data(bytes(300_001)))
        await #expect(throws: OwnedFileError(.fileTooLarge)) {
            _ = try await fixture.io.importRegularFile(source: over, limit: 1 << 40, category: .compose)
        }
        await #expect(throws: OwnedFileError(.fileTooLarge)) {
            _ = try await fixture.io.importRegularFile(source: source, limit: 299_999, category: .compose)
        }
        let link = fixture.root.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        await #expect(throws: OwnedFileError(.notRegularFile)) {
            _ = try await fixture.io.importRegularFile(source: link, limit: 1 << 40, category: .compose)
        }

        imported.cancel()
        try await fixture.waitUntilReleased()
        #expect(fixture.files.isEmpty)
        #expect(FileManager.default.fileExists(atPath: source.path))
        try await fixture.close()
    }

    @Test func importOverTheDefaultComposeLimitFailsBeforeCopying() async throws {
        let fixture = SpoolFixture()
        let huge = fixture.root.appendingPathComponent("huge.bin")
        FileManager.default.createFile(atPath: huge.path, contents: Data())
        #expect(truncate(huge.path, off_t(RulesLimits().composeBodyBytes) + 1) == 0)  // sparse
        await #expect(throws: OwnedFileError(.fileTooLarge)) {
            _ = try await fixture.io.importRegularFile(source: huge, limit: Int64(RulesLimits().composeBodyBytes), category: .compose)
        }
        #expect(fixture.budgets.snapshot().peak.isEmpty)
        #expect(fixture.files.isEmpty)
        try await fixture.close()
    }

    @Test func aSlowImportDoesNotOccupyThePoolThatSpoolsAndReadsUse() async throws {
        let reached = DispatchSemaphore(value: 0), gate = DispatchSemaphore(value: 0)
        let fixture = SpoolFixture(limits: RulesLimits(), afterImportChunk: { copied in
            if copied == 65_536 { reached.signal(); gate.wait() }
        })
        let source = fixture.root.appendingPathComponent("big.bin")
        FileManager.default.createFile(atPath: source.path, contents: Data(bytes(200_000)))
        // Two imports: if imports ran on the file pool they would park both of its threads.
        let slow = [
            Task { try await fixture.io.importRegularFile(source: source, limit: 1 << 30, category: .compose) },
            Task { try await fixture.io.importRegularFile(source: source, limit: 1 << 30, category: .compose) },
        ]
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { reached.wait(); continuation.resume() }
        }
        // Spool writes and reads must still run while an import is parked.
        let deadline = ContinuousClock.now + .seconds(2)
        let work = Task { () throws -> [UInt8] in
            let a = try await fixture.spool(expected: 3), b = try await fixture.spool(expected: 3)
            try await fixture.append(a, [1, 2, 3])
            try await fixture.append(b, [4, 5, 6])
            let source = try await fixture.finish(a)
            defer { source.cancel() }
            try await loopCancel(fixture, b)
            return try await readAll(source)
        }
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask { _ = try? await work.value; return true }
            group.addTask {
                try? await Task.sleep(until: deadline)
                gate.signal(); gate.signal()  // on a regression the work is stuck behind the imports: unblock them
                return false
            }
            let first = await group.next()!
            group.cancelAll()
            return first
        }
        if finished { gate.signal(); gate.signal() }
        #expect(finished)
        #expect(try await work.value == [1, 2, 3])
        for task in slow {
            let imported = try await task.value
            #expect(imported.size == 200_000)
            imported.cancel()
        }
        try await fixture.waitUntilReleased()
        try await fixture.close()
    }

    @Test func startupSweepRemovesOnlyOwnedLeftoversInAPrivateDirectory() async throws {
        let fixture = SpoolFixture()
        let manager = FileManager.default
        try manager.createDirectory(at: fixture.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let owned = [".spool-\(UUID().uuidString)", "\(UUID().uuidString).body"]
        let kept = ["notes.txt", ".spool-not-a-uuid", "\(UUID().uuidString.lowercased()).body", "\(UUID().uuidString).body.bak"]
        for name in owned + kept {
            manager.createFile(atPath: fixture.directory.appendingPathComponent(name).path, contents: Data("x".utf8))
        }
        let outside = fixture.root.appendingPathComponent("\(UUID().uuidString).body")
        manager.createFile(atPath: outside.path, contents: Data("user".utf8))
        let link = "\(UUID().uuidString).body"
        try manager.createSymbolicLink(at: fixture.directory.appendingPathComponent(link), withDestinationURL: outside)

        await fixture.io.sweepOrphans()
        #expect(fixture.files == Set(kept + [link, SpoolDirectoryOwner.markerName]))
        #expect(manager.fileExists(atPath: outside.path))

        // A directory that is not private (0755) is never swept.
        let leftover = "\(UUID().uuidString).body"
        manager.createFile(atPath: fixture.directory.appendingPathComponent(leftover).path, contents: Data())
        #expect(chmod(fixture.directory.path, 0o755) == 0)
        await fixture.io.sweepOrphans()
        #expect(fixture.files.contains(leftover))
        try await fixture.close()
    }

    @Test func cancelAfterAFailureKeepsTheFailure() async throws {
        let fixture = SpoolFixture()
        let spool = try await fixture.spool(expected: 4)
        await #expect(throws: OwnedFileError(.lengthMismatch)) { try await fixture.append(spool, bytes(5)) }
        try await loopCancel(fixture, spool)
        await #expect(throws: OwnedFileError(.lengthMismatch)) { _ = try await fixture.finish(spool) }
        try await fixture.waitUntilReleased()
        try await fixture.close()
    }

    @Test func finishAfterThePoolStoppedClosesAndUnlinksBeforeReleasing() async throws {
        let fixture = SpoolFixture()
        let spool = try await fixture.spool(expected: 3)
        try await fixture.append(spool, [1, 2, 3])
        #expect(fixture.files.count == 1)
        try await fixture.pool.shutdownGracefully()
        await #expect(throws: OwnedFileError(.cancelled)) { _ = try await fixture.finish(spool) }
        try await fixture.waitUntilReleased()
        #expect(fixture.files.isEmpty)
        try await fixture.close()
    }
}

private func loopCancel(_ fixture: SpoolFixture, _ spool: ExactBodySpool) async throws {
    try await fixture.loop.submit { spool.cancel() }.get()
}
