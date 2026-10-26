import Foundation
import Testing

@testable import FlowStore

@Suite struct BodyCaptureTests {
    @Test func bodyCaptureStaysInMemoryUnderThreshold() throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let cap = env.store.makeBodyCapture()
        cap.append([UInt8](repeating: 1, count: 1000))
        let body = try #require(cap.finish().body)
        guard case .managed = body, body.size == 1000 else {
            Issue.record("expected a managed in-memory body")
            return
        }
        #expect(try body.load() == Data(repeating: 1, count: 1000))
    }

    @Test func bodyCaptureSpillsToFileOverThreshold() throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let cap = env.store.makeBodyCapture()
        cap.append([UInt8](repeating: 0x61, count: 600_000))
        cap.append([UInt8](repeating: 0x62, count: 600_000))
        let ref = try #require(cap.finish().body)
        guard case .managed(let handle) = ref, let url = env.store.spillURL(of: ref) else {
            Issue.record("expected a managed spill")
            return
        }
        #expect(handle.size == 1_200_000)
        #expect(ref.size == 1_200_000)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(url.deletingLastPathComponent().standardizedFileURL == env.directory.standardizedFileURL)
        #expect(try ref.load() == Data(repeating: 0x61, count: 600_000) + Data(repeating: 0x62, count: 600_000))
    }

    @Test func exactlyThresholdStaysInMemory() throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let cap = env.store.makeBodyCapture()
        cap.append([UInt8](repeating: 7, count: BodyCapture.spillThreshold))
        let body = try #require(cap.finish().body)
        guard case .managed = body, body.size == BodyCapture.spillThreshold else {
            Issue.record("expected a managed in-memory body")
            return
        }
        #expect(try body.load() == Data(repeating: 7, count: BodyCapture.spillThreshold))
    }

    @Test func emptyCaptureReturnsNil() {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let cap = env.store.makeBodyCapture()
        cap.append([UInt8]())
        #expect(cap.finish().body == nil)
    }

    @Test func memoryRefLoadsAndReportsSize() throws {
        let ref = BodyRef.memory(Data([1, 2, 3]))
        #expect(ref.size == 3)
        #expect(try ref.load() == Data([1, 2, 3]))
    }

    @Test func cappedLoadOfMemoryRef() throws {
        let ref = BodyRef.memory(Data([1, 2, 3, 4]))
        let capped = try ref.load(maxBytes: 3)
        #expect(capped.data == Data([1, 2, 3]))
        #expect(capped.isTruncated)
        let whole = try ref.load(maxBytes: 4)
        #expect(whole.data == Data([1, 2, 3, 4]))
        #expect(!whole.isTruncated)
    }

    @Test func cappedLoadOfFileRefReadsOnlyThePrefix() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).body")
        try Data("0123456789".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let ref = BodyRef.file(url, size: 10)

        let capped = try ref.load(maxBytes: 4)
        #expect(capped.data == Data("0123".utf8))
        #expect(capped.isTruncated)
        for limit in [10, 20] {
            let whole = try ref.load(maxBytes: limit)
            #expect(whole.data == Data("0123456789".utf8))
            #expect(!whole.isTruncated)
        }
    }

    @Test func cappedLoadOfMissingFileThrows() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).body")
        #expect(throws: (any Error).self) { try BodyRef.file(url, size: 10).load(maxBytes: 4) }
    }
}

@Suite struct BodyCaptureWriteFailureTests {
    @Test func midStreamWriteFailureYieldsTruncatedPrefixNotSplice() throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let cap = env.store.makeBodyCapture()
        cap.append([UInt8](repeating: 0x61, count: 600_000))
        cap.append([UInt8](repeating: 0x62, count: 600_000))  // 触发落盘
        #expect(cap.isTruncated == false)

        // 关掉底层句柄，让之后的 write 失败。
        try #require(cap.file).handle.close()
        cap.append([UInt8](repeating: 0x63, count: 10))
        #expect(cap.isTruncated)
        cap.append([UInt8](repeating: 0x64, count: 10))

        let result = cap.finish()
        #expect(result.truncated)
        let ref = try #require(result.body)
        guard case .managed(let handle) = ref else {
            Issue.record("expected a managed spill")
            return
        }
        #expect(handle.size == 1_200_000)
        #expect(try ref.load() == Data(repeating: 0x61, count: 600_000) + Data(repeating: 0x62, count: 600_000))
    }
}

@Suite struct BodyCaptureLimitTests {
    private func makeCapture(maxCapturedBytes: Int, directory: URL? = nil) -> (BodyCapture, TestEnvironment) {
        let env = TestEnvironment(maxCapturedBodyBytes: maxCapturedBytes)
        return (BodyCapture(directory: directory ?? env.directory, maxCapturedBytes: maxCapturedBytes), env)
    }

    @Test func storeHandsOutCapturesWithItsCap() throws {
        let env = TestEnvironment(maxCapturedBodyBytes: 4)
        defer { env.cleanUp() }
        let cap = env.store.makeBodyCapture()
        cap.append([UInt8]("abcdef".utf8))
        let result = cap.finish()
        #expect((try? result.body?.load()) == Data("abcd".utf8))
        #expect(result.truncated)
    }

    @Test func inMemoryBodyIsCutAtTheCap() throws {
        let (cap, env) = makeCapture(maxCapturedBytes: 10)
        defer { env.cleanUp() }
        cap.append([UInt8](repeating: 1, count: 6))
        cap.append([UInt8](repeating: 2, count: 6))
        cap.append([UInt8](repeating: 3, count: 6))
        let result = cap.finish()
        #expect((try? result.body?.load()) == Data(repeating: 1, count: 6) + Data(repeating: 2, count: 4))
        #expect(result.truncated)
    }

    @Test func bodyOfExactlyTheCapIsNotTruncated() throws {
        let (cap, env) = makeCapture(maxCapturedBytes: 10)
        defer { env.cleanUp() }
        cap.append([UInt8](repeating: 1, count: 10))
        cap.append([UInt8]())
        let result = cap.finish()
        #expect(result.body?.size == 10)
        #expect(!result.truncated)
    }

    @Test func spilledBodyIsCutAtTheCap() throws {
        let cap = 1_500_000
        let (capture, env) = makeCapture(maxCapturedBytes: cap)
        defer { env.cleanUp() }
        for byte: UInt8 in [0x61, 0x62, 0x63] {
            capture.append([UInt8](repeating: byte, count: 600_000))
        }
        let result = capture.finish()
        #expect(result.truncated)
        let ref = try #require(result.body)
        guard case .managed(let handle) = ref else {
            Issue.record("expected a managed spill")
            return
        }
        #expect(handle.size == cap)
        #expect(
            try ref.load()
                == Data(repeating: 0x61, count: 600_000) + Data(repeating: 0x62, count: 600_000)
                + Data(repeating: 0x63, count: 300_000))
    }

    @Test func spillFailureKeepsTheInMemoryPrefixAndStops() throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        // A regular file where the body directory's parent should be: the directory cannot be created.
        try FileManager.default.createDirectory(at: env.directory, withIntermediateDirectories: true)
        let blocker = env.directory.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        let cap = BodyCapture(
            directory: blocker.appendingPathComponent("Bodies", isDirectory: true),
            maxCapturedBytes: BodyCapture.defaultMaxCapturedBytes)

        cap.append([UInt8](repeating: 0x61, count: 600_000))
        cap.append([UInt8](repeating: 0x62, count: 600_000))  // the spill fails here
        cap.append([UInt8](repeating: 0x63, count: 600_000))
        #expect(cap.file == nil)

        let result = cap.finish()
        #expect(result.truncated)
        #expect((try? result.body?.load()) == Data(repeating: 0x61, count: 600_000))
    }
}

@Suite struct BodyCaptureConsumptionTests {
    @Test func finishConsumesMemoryAndPreservesTruncationOnRepeatedCalls() {
        let env = TestEnvironment(maxCapturedBodyBytes: 4)
        defer { env.cleanUp() }
        let capture = env.store.makeBodyCapture()
        capture.append(Array("abcdef".utf8))
        let first = capture.finish()
        #expect((try? first.body?.load()) == Data("abcd".utf8))
        #expect(first.truncated)
        capture.append([9])
        let second = capture.finish()
        #expect(second.body == nil)
        #expect(second.truncated)
    }

    @Test func finishConsumesFileWithoutDeletingReturnedBody() throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        var capture: BodyCapture? = env.store.makeBodyCapture()
        capture?.append(Data(repeating: 7, count: BodyCapture.spillThreshold + 1))
        let body = try #require(capture?.finish().body)
        #expect(capture?.finish().body == nil)
        capture = nil
        #expect(try body.load() == Data(repeating: 7, count: BodyCapture.spillThreshold + 1))
    }
}

@Suite struct BodyMemoryBudgetTests {
    @Test func reservationsRespectExactLimitAndReturnReleasedCapacity() {
        let budget = BodyMemoryBudget(limit: 10)
        #expect(budget.reserve(6))
        #expect(budget.reserve(4))
        #expect(!budget.reserve(1))
        #expect(!budget.reserve(Int.max))
        #expect(budget.usedBytes == 10)
        budget.release(6)
        #expect(budget.usedBytes == 4)
        #expect(!budget.reserve(7))
        #expect(budget.reserve(6))
        budget.release(10)
        #expect(budget.usedBytes == 0)
    }

    @Test(arguments: [0, -10]) func nonpositiveBudgetAllowsOnlyEmptyReservations(limit: Int) {
        let budget = BodyMemoryBudget(limit: limit)
        #expect(budget.reserve(0))
        #expect(!budget.reserve(1))
        #expect(!budget.reserve(-1))
        budget.release(0)
        #expect(budget.usedBytes == 0)
    }

    @Test func concurrentReservationsNeverOvercommit() async {
        let budget = BodyMemoryBudget(limit: 10)
        let accepted = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<1000 { group.addTask { budget.reserve(1) } }
            var count = 0
            for await reserved in group where reserved { count += 1 }
            return count
        }
        #expect(accepted == 10)
        #expect(budget.usedBytes == 10)
        budget.release(10)
        #expect(budget.usedBytes == 0)
    }
}

@Suite struct BodyCaptureBudgetTests {
    @Test func sharedBudgetSpillsSecondCaptureBelowNormalThreshold() throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let budget = BodyMemoryBudget(limit: 10)
        let first = BodyCapture(directory: env.directory, budget: budget)
        let second = BodyCapture(directory: env.directory, budget: budget)
        first.append(Array("abcdef".utf8))
        second.append(Array("ghijkl".utf8))
        #expect(budget.usedBytes == 6)
        let spilled = try #require(second.finish().body)
        guard case .managed = spilled else { Issue.record("expected early spill"); return }
        #expect(try spilled.load() == Data("ghijkl".utf8))
        #expect(!second.isTruncated)
        #expect((try? first.finish().body?.load()) == Data("abcdef".utf8))
        #expect(budget.usedBytes == 0)
    }

    @Test func successfulSpillReleasesBufferedReservation() throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let budget = BodyMemoryBudget(limit: 10)
        let capture = BodyCapture(directory: env.directory, budget: budget)
        capture.append(Array("abcdef".utf8))
        #expect(budget.usedBytes == 6)
        capture.append(Array("ghijkl".utf8))
        #expect(budget.usedBytes == 0)
        let body = try #require(capture.finish().body)
        #expect(try body.load() == Data("abcdefghijkl".utf8))
        #expect(!capture.isTruncated)
    }

    @Test func thresholdSpillAlsoReleasesItsReservation() throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let budget = BodyMemoryBudget(limit: 2_000_000)
        let capture = BodyCapture(directory: env.directory, budget: budget)
        capture.append(Data(repeating: 1, count: 600_000))
        #expect(budget.usedBytes == 600_000)
        capture.append(Data(repeating: 2, count: 600_000))
        #expect(budget.usedBytes == 0)
        #expect(capture.finish().body?.size == 1_200_000)
    }

    @Test func heldFinishedCaptureRepeatedFinishAndDeinitReleaseOnlyOnce() {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let budget = BodyMemoryBudget(limit: 10)
        var capture: BodyCapture? = BodyCapture(directory: env.directory, budget: budget)
        capture?.append([1, 2, 3, 4, 5, 6])
        let handoff = capture?.finish().body
        #expect((try? handoff?.load()) == Data([1, 2, 3, 4, 5, 6]))
        #expect(budget.usedBytes == 0)
        #expect(budget.reserve(10))
        #expect(capture?.finish().body == nil)
        #expect(budget.usedBytes == 10)
        capture = nil
        #expect(budget.usedBytes == 10)
        budget.release(10)
    }

    @Test func unfinishedCaptureDeinitReleasesMemory() {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let budget = BodyMemoryBudget(limit: 10)
        var capture: BodyCapture? = BodyCapture(directory: env.directory, budget: budget)
        capture?.append([1, 2, 3, 4, 5, 6])
        #expect(budget.usedBytes == 6)
        capture = nil
        #expect(budget.usedBytes == 0)
    }

    @Test func unfinishedEarlySpillDeinitDeletesOrphanedFile() throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let budget = BodyMemoryBudget(limit: 10)
        var capture: BodyCapture? = BodyCapture(directory: env.directory, budget: budget)
        capture?.append([1, 2, 3, 4, 5, 6])
        capture?.append([7, 8, 9, 10, 11, 12])
        let url = try #require(capture?.file?.url)
        #expect(budget.usedBytes == 0)
        capture = nil
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(budget.usedBytes == 0)
    }

    @Test(arguments: [true, false]) func failedSpillKeepsBoundedPrefixReservedUntilFinishOrDeinit(finish: Bool) throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        try FileManager.default.createDirectory(at: env.directory, withIntermediateDirectories: true)
        let blocker = env.directory.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        let budget = BodyMemoryBudget(limit: 10)
        var capture: BodyCapture? = BodyCapture(directory: blocker.appendingPathComponent("Bodies"), budget: budget)
        capture?.append(Array("abcdef".utf8))
        capture?.append(Array("ghijkl".utf8))
        capture?.append(Array("mnopqr".utf8))
        #expect(capture?.isTruncated == true)
        #expect(capture?.file == nil)
        #expect(budget.usedBytes == 6)
        #expect(budget.reserve(4))
        #expect(!budget.reserve(1))
        if finish {
            let result = try #require(capture?.finish())
            #expect((try? result.body?.load()) == Data("abcdef".utf8))
            #expect(result.truncated)
            #expect(budget.usedBytes == 4)
            #expect(capture?.finish().body == nil)
        }
        capture = nil
        #expect(budget.usedBytes == 4)
        budget.release(4)
    }
}
