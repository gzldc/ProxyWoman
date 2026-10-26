import Dispatch
import FlowStore
import Foundation
import NIOCore
import NIOEmbedded
import NIOPosix
import os
import Testing
@testable import ProxyCore
@testable import RulesEngine

/// The rewrite gate on its own: a controllable test loop, a real file pool and private spool files.
/// `NIOAsyncTestingEventLoop` stands in for `EmbeddedEventLoop`: the file pool and the transform
/// task complete their futures from other threads, which only a thread-safe loop accepts; time
/// still moves only when the test advances it.
private final class RewriterFixture: Sendable {
    let loop = NIOAsyncTestingEventLoop()
    let pool = NIOThreadPool(numberOfThreads: 2)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pw-rewrite-\(UUID().uuidString)")
    let limits: RulesLimits
    let budgets: OwnedFileBudgets
    let io: BodyFileIO
    /// Free disk the budgets see; a test drops it to make a write fail.
    let freeDisk = OSAllocatedUnfairLock(initialState: Int64.max / 2)
    let events = RewriterEvents()
    var directory: URL { root.appendingPathComponent("spool") }

    init(limits: RulesLimits = RulesLimits(minimumFreeDiskBytes: 0)) {
        pool.start()
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.limits = limits
        let disk = freeDisk
        budgets = OwnedFileBudgets(limits: limits, freeDiskBytes: { _ in disk.withLock { $0 } })
        io = BodyFileIO(directory: root.appendingPathComponent("spool"), eventLoop: loop, budgets: budgets,
                        limits: limits, threadPool: pool, hooks: BodyFileIOHooks())
    }

    func close() async throws {
        try? await pool.shutdownGracefully()
        await loop.shutdownGracefully()
        try? FileManager.default.removeItem(at: root)
    }

    var files: [String] { (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] }

    /// Runs `body` on the loop, then lets every task it queued run too.
    func onLoop<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        let result = try await loop.executeInContext(body)
        await loop.run()
        return result
    }

    func make(steps: [BodyRewriteStep], headers: [HeaderField] = [HeaderField(name: "Content-Type", value: "text/plain")],
              expectedLength: Int64? = nil, cache: PatternCache = PatternCache()) async throws -> NIOLoopBound<ExchangeBodyRewriter> {
        let events = self.events, io = self.io, limits = self.limits, loop = self.loop
        return try await onLoop {
            let rewriter = try ExchangeBodyRewriter(
                loop: loop, io: io, limits: limits, cache: cache, direction: .response, steps: steps,
                effectiveHead: .response(status: 200, reason: "OK", headers: headers),
                expectedLength: expectedLength, sourceVersion: .http1_1,
                changed: { events.changed() },
                completed: { events.completed($0) },
                failed: { events.failed($0, $1) })
            return NIOLoopBound(rewriter, eventLoop: loop)
        }
    }

    func feed(_ gate: NIOLoopBound<ExchangeBodyRewriter>, _ chunks: [String], end: Bool = true) async throws {
        try await onLoop {
            for chunk in chunks { gate.value.append(ByteBuffer(string: chunk)) }
            if end { gate.value.finishBody(trailers: []) }
        }
    }

    /// Waits until the collector has written everything it was given, as the owner does before it
    /// reads the next part. Feeding faster than the file pool writes overflows the staging limit.
    func waitCanRead(_ gate: NIOLoopBound<ExchangeBodyRewriter>) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(try await onLoop { gate.value.canRead }) {
            guard ContinuousClock.now < deadline else { throw WaitTimeout(description: "collector still writing") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func waitReleased() async throws {
        try await waitUntil("budgets \(budgets.snapshot()) and files \(files) released") {
            budgets.snapshot().reservedBytes == 0 && files.isEmpty
        }
    }
}

/// Every callback the gate made, in order. Lock-protected; the gate calls it on its loop.
private final class RewriterEvents: Sendable {
    struct State: Sendable {
        var changes = 0
        var completions: [BodyRewriteCompletion] = []
        var failures: [(BodyRewriteFailure, [RuleOutcome])] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var snapshot: State { state.withLock { $0 } }
    func changed() { state.withLock { $0.changes += 1 } }
    func completed(_ completion: BodyRewriteCompletion) { state.withLock { $0.completions.append(completion) } }
    func failed(_ failure: BodyRewriteFailure, _ outcomes: [RuleOutcome]) { state.withLock { $0.failures.append((failure, outcomes)) } }

    func completion() async throws -> BodyRewriteCompletion {
        try await waitUntil("a completion; \(snapshot.failures)") { !snapshot.completions.isEmpty }
        return snapshot.completions[0]
    }
    func failure() async throws -> (BodyRewriteFailure, [RuleOutcome]) {
        try await waitUntil("a failure; \(snapshot.completions.count) completions") { !snapshot.failures.isEmpty }
        return snapshot.failures[0]
    }
}

/// A body-budget clock that runs on the transform's thread. `hold` parks the first read until the
/// test releases it (bounded, so a broken test fails instead of hanging).
private final class TransformProbe: Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let state = OSAllocatedUnfairLock(initialState: (reads: 0, onLoop: [Bool]()))
    let loop: EventLoop
    let hold: Bool
    let onFirstRead: @Sendable () -> Void
    init(loop: EventLoop, hold: Bool = false, onFirstRead: @escaping @Sendable () -> Void = {}) {
        self.loop = loop; self.hold = hold; self.onFirstRead = onFirstRead
    }
    var readsOnLoop: [Bool] { state.withLock { $0.onLoop } }
    var cache: PatternCache {
        PatternCache(bodyBudget: RegexBudget(maxDuration: .seconds(5), clock: { [self] in read() }))
    }
    private func read() -> Duration {
        let first = state.withLock { state -> Bool in
            state.reads += 1
            state.onLoop.append(loop.inEventLoop)
            return state.reads == 1
        }
        if first {
            onFirstRead()
            if hold {
                entered.signal()
                _ = release.wait(timeout: .now() + 10)
            }
        }
        return .zero
    }
    func waitEntered() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { _ = self.entered.wait(timeout: .now() + 10); continuation.resume() }
        }
    }
    func open() { release.signal() }
}

private func readAll(_ source: ExactBodySource) async throws -> String {
    var data = Data()
    while true {
        let chunk = try await source.read(offset: Int64(data.count), maxBytes: 65_536)
        if chunk.isEmpty { return String(decoding: data, as: UTF8.self) }
        data.append(chunk)
    }
}

private let ruleA = UUID(), ruleB = UUID()
private func step(_ find: String, _ replacement: String, rule id: UUID = ruleA) -> BodyRewriteStep {
    BodyRewriteStep(ruleID: id, action: BodyRewriteAction(find: find, replacement: replacement))
}
/// gzip("hello").
private let gzipHello: [UInt8] = [31, 139, 8, 0, 0, 0, 0, 0, 0, 3, 203, 72, 205, 201, 201, 7, 0, 134, 166, 16, 54, 5, 0, 0, 0]

/// gzip of `count` bytes of "x": a tiny wire body that inflates to `count` bytes. The decoder
/// checks the trailer, so it carries the real CRC32 and size.
private func gzipOfX(_ count: Int) throws -> [UInt8] {
    let plain = Data(repeating: UInt8(ascii: "x"), count: count)
    let deflated = try (plain as NSData).compressed(using: .zlib) as Data
    var crc: UInt32 = 0xffff_ffff
    for byte in plain {
        crc ^= UInt32(byte)
        for _ in 0..<8 { crc = (crc >> 1) ^ (0xedb8_8320 & (0 &- (crc & 1))) }
    }
    func le(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * UInt32($0))) } }
    return [0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3] + [UInt8](deflated) + le(~crc) + le(UInt32(truncatingIfNeeded: count))
}

@Suite(.serialized, .timeLimit(.minutes(2)), .productionChinese) struct ExchangeBodyRewriterTests {
    /// The wire size of a compressed body says nothing about its decoded size: the reservation
    /// covers the decoded text and the result at the rewrite cap, and a budget that cannot hold
    /// them forwards the original untouched.
    @Test func compressedBodyReservesForTheDecodedSize() async throws {
        let wire = try gzipOfX(512 * 1024)
        #expect(wire.count < 4096)
        let headers = [HeaderField(name: "Content-Type", value: "text/plain"), HeaderField(name: "Content-Encoding", value: "gzip")]
        let cap = 1_048_576
        // 3 x the wire size would fit this budget easily; the decoded size does not.
        let small = RewriterFixture(limits: RulesLimits(editorMemoryBytes: 1_048_576, minimumFreeDiskBytes: 0, rewriteBodyBytes: cap))
        let refused = try await small.make(steps: [step("x", "y")], headers: headers)
        try await small.onLoop {
            refused.value.start()
            refused.value.append(ByteBuffer(bytes: wire))
            refused.value.finishBody(trailers: [])
        }
        let skipped = try await small.events.completion()
        #expect(skipped.outcomes == [RuleOutcome(ruleID: ruleA, code: .bodySkippedBusy)])
        #expect(!skipped.continuation.bytesChanged)
        #expect(skipped.continuation.source.size == Int64(wire.count))
        skipped.continuation.source.cancel()
        try await small.waitReleased()
        try await small.close()

        let f = RewriterFixture(limits: RulesLimits(minimumFreeDiskBytes: 0, rewriteBodyBytes: cap))
        let probe = TransformProbe(loop: f.loop, hold: true)
        let gate = try await f.make(steps: [step("zzz", "y")], headers: headers, cache: probe.cache)
        try await f.onLoop {
            gate.value.start()
            gate.value.append(ByteBuffer(bytes: wire))
            gate.value.finishBody(trailers: [])
        }
        await probe.waitEntered()
        #expect(f.budgets.snapshot().bytes[.editor] == Int64(wire.count + 2 * cap))
        probe.open()
        let completion = try await f.events.completion()
        #expect(completion.outcomes == [RuleOutcome(ruleID: ruleA, code: .bodyNoMatch)])
        completion.continuation.source.cancel()
        try await f.waitReleased()
        try await f.close()
    }

    @Test func collectsThenRewritesAndCompletesChanged() async throws {
        let f = RewriterFixture()
        let gate = try await f.make(steps: [step("world", "there")])
        try await f.onLoop { gate.value.start() }
        #expect(try await f.onLoop { gate.value.isCollecting && gate.value.direction == .response && gate.value.timerCount == 1 })
        try await f.feed(gate, ["hello ", "world"])
        let completion = try await f.events.completion()
        #expect(completion.outcomes == [RuleOutcome(ruleID: ruleA, code: .applied)])
        #expect(completion.continuation.bytesChanged)
        #expect(completion.continuation.descriptor == HTTPBodyDescriptor(length: 11, complete: true, changed: true))
        #expect(completion.continuation.version == .http1_1)
        #expect(try await readAll(completion.continuation.source) == "hello there")
        #expect(try await f.onLoop { !gate.value.isCollecting && gate.value.timerCount == 0 && gate.value.receivedEnd })
        #expect(f.events.snapshot.failures.isEmpty)
        // The transform's memory is returned; the original spool is given up (its file is
        // released off the loop), so only the replacement stays held.
        #expect(f.budgets.snapshot().bytes[.editor] == nil)
        try await waitUntil("original spool released") { f.budgets.snapshot().bytes[.breakpoint] == 11 && f.files.count == 1 }
        completion.continuation.source.cancel()
        try await f.waitReleased()
        try await f.close()
    }

    @Test func noMatchCompletesUnchangedWithOriginalSource() async throws {
        let f = RewriterFixture()
        let gate = try await f.make(steps: [step("zzz", "y")])
        try await f.onLoop { gate.value.start() }
        try await f.feed(gate, ["hello ", "world"])
        let completion = try await f.events.completion()
        #expect(completion.outcomes == [RuleOutcome(ruleID: ruleA, code: .bodyNoMatch)])
        #expect(!completion.continuation.bytesChanged)
        #expect(completion.continuation.descriptor == HTTPBodyDescriptor(length: 11, complete: true, changed: false))
        #expect(try await readAll(completion.continuation.source) == "hello world")
        completion.continuation.source.cancel()
        try await f.waitReleased()
        try await f.close()
    }

    @Test func gzipSourceRewrittenWithRemoveEncodingChoice() async throws {
        let f = RewriterFixture()
        let gate = try await f.make(steps: [step("hello", "bye")], headers: [
            HeaderField(name: "Content-Type", value: "text/plain"), HeaderField(name: "Content-Encoding", value: "gzip"),
        ], expectedLength: Int64(gzipHello.count))
        try await f.onLoop {
            gate.value.start()
            gate.value.append(ByteBuffer(bytes: gzipHello))
            gate.value.finishBody(trailers: [])
        }
        let completion = try await f.events.completion()
        #expect(completion.outcomes == [RuleOutcome(ruleID: ruleA, code: .applied)])
        #expect(completion.continuation.descriptor.encodingChoice == .removeEncoding)
        #expect(completion.continuation.descriptor.length == 3)
        #expect(try await readAll(completion.continuation.source) == "bye")
        completion.continuation.source.cancel()
        try await f.waitReleased()
        try await f.close()
    }

    @Test func unknownLengthOverLimitFailsTooLarge() async throws {
        let f = RewriterFixture(limits: RulesLimits(minimumFreeDiskBytes: 0, rewriteBodyBytes: 1024))
        let gate = try await f.make(steps: [step("a", "b"), step("c", "d", rule: ruleB)])
        try await f.onLoop { gate.value.start() }
        try await f.feed(gate, [String(repeating: "a", count: 600), String(repeating: "a", count: 600)], end: false)
        let (failure, outcomes) = try await f.events.failure()
        #expect(failure == .tooLarge)
        #expect(outcomes == [RuleOutcome(ruleID: ruleA, code: .rejected), RuleOutcome(ruleID: ruleB, code: .rejected)])
        #expect(try await f.onLoop { !gate.value.isCollecting && gate.value.timerCount == 0 })
        try await f.waitReleased()
        #expect(f.events.snapshot.completions.isEmpty)
        try await f.close()
    }

    @Test func knownLengthIsCheckedByExpectedLength() async throws {
        let f = RewriterFixture(limits: RulesLimits(minimumFreeDiskBytes: 0, rewriteBodyBytes: 1024))
        // Over the cap: refused before anything is reserved (the exchange then streams it untouched).
        await #expect(throws: BodyRewriteFailure.tooLarge) { _ = try await f.make(steps: [step("a", "b")], expectedLength: 2048) }
        #expect(f.budgets.snapshot().reservedBytes == 0)
        // Within the cap the declared length is exact: more bytes than announced fail the collection.
        let gate = try await f.make(steps: [step("a", "b")], expectedLength: 5)
        #expect(f.budgets.snapshot().bytes[.breakpoint] == 5)
        try await f.onLoop { gate.value.start() }
        try await f.feed(gate, ["aaaaaa"], end: false)
        let (failure, outcomes) = try await f.events.failure()
        #expect(failure == .unavailable)
        #expect(outcomes == [RuleOutcome(ruleID: ruleA, code: .rejected)])
        try await f.waitReleased()
        try await f.close()
    }

    @Test func collectionDeadlineFiresTimedOutWithEmbeddedTimeAdvance() async throws {
        let f = RewriterFixture(limits: RulesLimits(minimumFreeDiskBytes: 0, rewriteSeconds: 30))
        let gate = try await f.make(steps: [step("a", "b")])
        try await f.onLoop { gate.value.start() }
        try await f.feed(gate, ["aaa"], end: false)
        await f.loop.advanceTime(by: .seconds(29))
        #expect(f.events.snapshot.failures.isEmpty)
        #expect(try await f.onLoop { gate.value.timerCount == 1 && gate.value.isCollecting })
        await f.loop.advanceTime(by: .seconds(2))
        let (failure, outcomes) = try await f.events.failure()
        #expect(failure == .timedOut)
        #expect(outcomes == [RuleOutcome(ruleID: ruleA, code: .rejected)])
        #expect(try await f.onLoop { gate.value.timerCount == 0 && !gate.value.isCollecting })
        try await f.waitReleased()
        try await f.close()
    }

    /// A 1 MiB matched response arriving at the P1 Edge download rate takes about 35 s in total
    /// (more than `rewriteSeconds`), yet no gap between chunks comes near the deadline.
    @Test func bodyArrivingAtTheEdgeRateOverTheTotalDeadlineStillCompletes() async throws {
        let f = RewriterFixture(limits: RulesLimits(minimumFreeDiskBytes: 0, rewriteSeconds: 30))
        let gate = try await f.make(steps: [step("needle", "pin")])
        try await f.onLoop { gate.value.start() }
        let bytesPerSecond = Int64(try #require(NetworkPreset.edge.profile.downloadKbps)) * 1000 / 8
        let chunkBytes = 65_536, chunks = 16
        let gapMilliseconds = Int64(chunkBytes) * 1000 / bytesPerSecond
        #expect(Int64(chunks) * gapMilliseconds > 30_000, "the whole transfer outlasts the deadline")
        #expect(gapMilliseconds < 5_000, "but the origin is never idle for long")
        var plain = String(repeating: "n", count: chunkBytes * chunks)
        plain.replaceSubrange(plain.index(plain.startIndex, offsetBy: 700_000)..<plain.index(plain.startIndex, offsetBy: 700_006), with: "needle")
        var offset = plain.startIndex
        for _ in 0..<chunks {
            let end = plain.index(offset, offsetBy: chunkBytes)
            try await f.waitCanRead(gate)
            try await f.feed(gate, [String(plain[offset..<end])], end: false)
            offset = end
            await f.loop.advanceTime(by: .milliseconds(gapMilliseconds))
            #expect(f.events.snapshot.failures.isEmpty, "no failure while chunks keep arriving")
        }
        try await f.onLoop { gate.value.finishBody(trailers: []) }
        let completion = try await f.events.completion()
        #expect(completion.outcomes == [RuleOutcome(ruleID: ruleA, code: .applied)])
        let rewritten = try await readAll(completion.continuation.source)
        #expect(rewritten == plain.replacingOccurrences(of: "needle", with: "pin"))
        completion.continuation.source.cancel()
        try await f.waitReleased()
        try await f.close()
    }

    @Test func everyChunkReArmsOneDeadlineAndNoTimerAccumulates() async throws {
        let f = RewriterFixture(limits: RulesLimits(minimumFreeDiskBytes: 0, rewriteSeconds: 30))
        let gate = try await f.make(steps: [step("a", "b")])
        try await f.onLoop { gate.value.start() }
        for _ in 0..<5 {
            try await f.feed(gate, ["aaa"], end: false)
            #expect(try await f.onLoop { gate.value.timerCount == 1 })
            await f.loop.advanceTime(by: .seconds(20))
        }
        #expect(f.events.snapshot.failures.isEmpty)
        try await f.onLoop { gate.value.abandon() }
        #expect(try await f.onLoop { gate.value.timerCount == 0 })
        try await f.waitReleased()
        try await f.close()
    }

    @Test func originThatStallsAfterProgressTimesOutOnlyAfterTheIdleDeadline() async throws {
        let f = RewriterFixture(limits: RulesLimits(minimumFreeDiskBytes: 0, rewriteSeconds: 30))
        let gate = try await f.make(steps: [step("a", "b")])
        try await f.onLoop { gate.value.start() }
        try await f.feed(gate, ["aaa"], end: false)
        await f.loop.advanceTime(by: .seconds(25))
        try await f.feed(gate, ["aaa"], end: false)
        await f.loop.advanceTime(by: .seconds(25))
        try await f.feed(gate, ["aaa"], end: false)
        // 50 s after the first byte, but only 29 s without one.
        await f.loop.advanceTime(by: .seconds(29))
        #expect(f.events.snapshot.failures.isEmpty)
        #expect(try await f.onLoop { gate.value.timerCount == 1 && gate.value.isCollecting })
        await f.loop.advanceTime(by: .seconds(2))
        let (failure, outcomes) = try await f.events.failure()
        #expect(failure == .timedOut)
        #expect(outcomes == [RuleOutcome(ruleID: ruleA, code: .rejected)])
        #expect(f.events.snapshot.failures.count == 1)
        try await f.waitReleased()
        try await f.close()
    }

    /// One byte every 29 s never trips the 30 s idle deadline; only the overall cap (10 minutes by
    /// default) ends it, and it ends it exactly like the idle deadline does.
    @Test func dribbleJustInsideTheIdleDeadlineFailsAtTheOverallCap() async throws {
        let f = RewriterFixture(limits: RulesLimits(minimumFreeDiskBytes: 0, rewriteSeconds: 30))
        #expect(f.limits.rewriteTotalSeconds == 600)
        let gate = try await f.make(steps: [step("a", "b")])
        try await f.onLoop { gate.value.start() }
        for _ in 0..<20 {
            try await f.feed(gate, ["a"], end: false)
            await f.loop.advanceTime(by: .seconds(29))
        }
        // 580 s of dribbling: well past any idle deadline, still under the cap.
        #expect(f.events.snapshot.failures.isEmpty)
        #expect(try await f.onLoop { gate.value.isCollecting })
        try await f.feed(gate, ["a"], end: false)
        await f.loop.advanceTime(by: .seconds(21))
        let (failure, outcomes) = try await f.events.failure()
        #expect(failure == .timedOut)
        #expect(outcomes == [RuleOutcome(ruleID: ruleA, code: .rejected)])
        #expect(f.events.snapshot.failures.count == 1)
        #expect(try await f.onLoop { gate.value.timerCount == 0 && gate.value.overallTimerCount == 0 && !gate.value.isCollecting })
        try await f.waitReleased()
        try await f.close()
    }

    @Test func injectedOverallCapEndsASteadyTrickleAtItsOwnValue() async throws {
        let f = RewriterFixture(limits: RulesLimits(minimumFreeDiskBytes: 0, rewriteSeconds: 30, rewriteTotalSeconds: 60))
        let gate = try await f.make(steps: [step("a", "b")])
        try await f.onLoop { gate.value.start() }
        for _ in 0..<2 {
            try await f.feed(gate, ["a"], end: false)
            await f.loop.advanceTime(by: .seconds(25))
        }
        #expect(f.events.snapshot.failures.isEmpty)
        try await f.feed(gate, ["a"], end: false)
        await f.loop.advanceTime(by: .seconds(11))
        let (failure, _) = try await f.events.failure()
        #expect(failure == .timedOut)
        try await f.waitReleased()
        try await f.close()
    }

    @Test func overallCapIsInjectableAndNeverFiresOnceCollectionHasFinished() async throws {
        let f = RewriterFixture(limits: RulesLimits(minimumFreeDiskBytes: 0, rewriteSeconds: 30, rewriteTotalSeconds: 60))
        let gate = try await f.make(steps: [step("a", "b")])
        try await f.onLoop { gate.value.start() }
        try await f.feed(gate, ["aaa"], end: false)
        await f.loop.advanceTime(by: .seconds(20))
        try await f.feed(gate, ["aaa"], end: false)
        await f.loop.advanceTime(by: .seconds(20))
        try await f.feed(gate, ["aaa"], end: false)
        await f.loop.advanceTime(by: .seconds(19))
        #expect(f.events.snapshot.failures.isEmpty)
        try await f.onLoop { gate.value.finishBody(trailers: []) }
        let completion = try await f.events.completion()
        #expect(completion.outcomes == [RuleOutcome(ruleID: ruleA, code: .applied)])
        #expect(try await f.onLoop { gate.value.overallTimerCount == 0 })
        await f.loop.advanceTime(by: .seconds(120))
        #expect(f.events.snapshot.failures.isEmpty)
        completion.continuation.source.cancel()
        try await f.waitReleased()
        try await f.close()
    }

    /// P2b minor: the two deadlines had no range check; zero or negative seconds fired at once and
    /// failed a perfectly healthy exchange. They are held to at least one second.
    @Test func nonPositiveDeadlinesAreHeldToOneSecond() async throws {
        for (idle, total) in [(0, 600), (-5, 600), (30, 0), (30, -1), (0, 0)] {
            let f = RewriterFixture(limits: RulesLimits(minimumFreeDiskBytes: 0, rewriteSeconds: idle, rewriteTotalSeconds: total))
            let gate = try await f.make(steps: [step("a", "b")])
            try await f.onLoop { gate.value.start() }
            try await f.feed(gate, ["aaa"], end: true)
            let completion = try await f.events.completion()
            #expect(completion.outcomes == [RuleOutcome(ruleID: ruleA, code: .applied)], "idle \(idle) total \(total)")
            #expect(f.events.snapshot.failures.isEmpty)
            completion.continuation.source.cancel()
            try await f.waitReleased()
            try await f.close()
        }
    }

    /// A one-second idle deadline still ends a quiet origin, and an absurd value does not overflow.
    @Test func oneSecondIdleDeadlineStillFiresAndHugeValuesAreAccepted() async throws {
        let quick = RewriterFixture(limits: RulesLimits(minimumFreeDiskBytes: 0, rewriteSeconds: 0))
        let gate = try await quick.make(steps: [step("a", "b")])
        try await quick.onLoop { gate.value.start() }
        try await quick.feed(gate, ["aaa"], end: false)
        await quick.loop.advanceTime(by: .milliseconds(1100))
        let (failure, _) = try await quick.events.failure()
        #expect(failure == .timedOut)
        try await quick.waitReleased()
        try await quick.close()

        let huge = RewriterFixture(limits: RulesLimits(minimumFreeDiskBytes: 0, rewriteSeconds: Int.max, rewriteTotalSeconds: Int.max))
        let open = try await huge.make(steps: [step("a", "b")])
        try await huge.onLoop { open.value.start() }
        try await huge.feed(open, ["aaa"], end: true)
        let completion = try await huge.events.completion()
        #expect(completion.outcomes == [RuleOutcome(ruleID: ruleA, code: .applied)])
        completion.continuation.source.cancel()
        try await huge.waitReleased()
        try await huge.close()
    }

    @Test func editorBudgetExhaustionYieldsBusyOutcomesAndOriginalSource() async throws {
        let f = RewriterFixture(limits: RulesLimits(editorMemoryBytes: 10, minimumFreeDiskBytes: 0))
        let gate = try await f.make(steps: [step("world", "there"), step("hello", "bye", rule: ruleB)])
        try await f.onLoop { gate.value.start() }
        try await f.feed(gate, ["hello world"])
        let completion = try await f.events.completion()
        #expect(completion.outcomes == [RuleOutcome(ruleID: ruleA, code: .bodySkippedBusy),
                                        RuleOutcome(ruleID: ruleB, code: .bodySkippedBusy)])
        #expect(!completion.continuation.bytesChanged)
        #expect(!completion.continuation.descriptor.changed)
        #expect(try await readAll(completion.continuation.source) == "hello world")
        completion.continuation.source.cancel()
        try await f.waitReleased()
        try await f.close()
    }

    @Test func abandonDuringCollectionReleasesSpoolAndBudgets() async throws {
        let f = RewriterFixture()
        let gate = try await f.make(steps: [step("a", "b")])
        try await f.onLoop { gate.value.start() }
        try await f.feed(gate, ["aaaa", "bbbb"], end: false)
        try await waitUntil("bytes spooled") { (f.budgets.snapshot().bytes[.breakpoint] ?? 0) == 8 }
        try await f.onLoop { gate.value.abandon() }
        #expect(try await f.onLoop { !gate.value.isCollecting && !gate.value.canRead && gate.value.timerCount == 0 })
        try await f.waitReleased()
        #expect(f.budgets.snapshot().reservedBytes == 0)
        // A late END after abandon is ignored.
        try await f.onLoop { gate.value.finishBody(trailers: []) }
        #expect(f.events.snapshot.completions.isEmpty && f.events.snapshot.failures.isEmpty)
        try await f.close()
    }

    @Test func abandonDuringTransformCancelsTaskAndReleasesReservation() async throws {
        let f = RewriterFixture()
        let probe = TransformProbe(loop: f.loop, hold: true)
        let gate = try await f.make(steps: [step("world", "there")], cache: probe.cache)
        try await f.onLoop { gate.value.start() }
        try await f.feed(gate, ["hello world"])
        await probe.waitEntered()
        #expect(f.budgets.snapshot().bytes[.editor] == 33)
        try await f.onLoop { gate.value.abandon() }
        // The reservation outlives the abandon until the transform task has settled.
        #expect(f.budgets.snapshot().bytes[.editor] == 33)
        probe.open()
        try await f.waitReleased()
        #expect(f.events.snapshot.completions.isEmpty && f.events.snapshot.failures.isEmpty)
        try await f.close()
    }

    @Test func transformRunsOffTheEventLoop() async throws {
        let f = RewriterFixture()
        let probe = TransformProbe(loop: f.loop)
        let gate = try await f.make(steps: [step("world", "there")], cache: probe.cache)
        try await f.onLoop { gate.value.start() }
        try await f.feed(gate, ["hello world"])
        let completion = try await f.events.completion()
        #expect(completion.continuation.bytesChanged)
        #expect(!probe.readsOnLoop.isEmpty)
        #expect(probe.readsOnLoop.allSatisfy { !$0 })
        completion.continuation.source.cancel()
        try await f.waitReleased()
        try await f.close()
    }

    @Test func staleCompletionAfterAbandonIsIgnored() async throws {
        let f = RewriterFixture()
        let probe = TransformProbe(loop: f.loop, hold: true)
        let gate = try await f.make(steps: [step("world", "there")], cache: probe.cache)
        try await f.onLoop { gate.value.start() }
        try await f.feed(gate, ["hello world"])
        await probe.waitEntered()
        let changes = f.events.snapshot.changes
        try await f.onLoop { gate.value.abandon() }
        probe.open()
        try await f.waitReleased()
        await f.loop.run()
        let state = f.events.snapshot
        #expect(state.completions.isEmpty)
        #expect(state.failures.isEmpty)
        #expect(state.changes == changes)
        try await f.close()
    }

    @Test func replacementWriteFailureIsUnavailable() async throws {
        let f = RewriterFixture()
        // The disk "fills up" while the transform runs, so only the replacement write fails.
        let disk = f.freeDisk
        let probe = TransformProbe(loop: f.loop, onFirstRead: { disk.withLock { $0 = 0 } })
        let gate = try await f.make(steps: [step("world", "there"), step("hello", "bye", rule: ruleB)], cache: probe.cache)
        try await f.onLoop { gate.value.start() }
        try await f.feed(gate, ["hello world"])
        let completion = try await f.events.completion()
        #expect(completion.outcomes == [RuleOutcome(ruleID: ruleA, code: .bodySkippedUnavailable),
                                        RuleOutcome(ruleID: ruleB, code: .bodySkippedUnavailable)])
        #expect(!completion.continuation.bytesChanged)
        #expect(try await readAll(completion.continuation.source) == "hello world")
        completion.continuation.source.cancel()
        try await f.waitReleased()
        try await f.close()
    }
}
