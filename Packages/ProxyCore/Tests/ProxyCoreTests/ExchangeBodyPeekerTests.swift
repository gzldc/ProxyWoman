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

/// The request peek gate on its own, like `ExchangeBodyRewriterTests`: a thread-safe test loop whose
/// time only moves when the test advances it, a real file pool and private spool files.
private final class PeekerFixture: Sendable {
    let loop = NIOAsyncTestingEventLoop()
    let pool = NIOThreadPool(numberOfThreads: 2)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pw-peek-\(UUID().uuidString)")
    let limits: RulesLimits
    let budgets: OwnedFileBudgets
    let io: BodyFileIO
    let events = PeekerEvents()
    var directory: URL { root.appendingPathComponent("spool") }

    init(limits: RulesLimits = RulesLimits(minimumFreeDiskBytes: 0)) {
        pool.start()
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.limits = limits
        budgets = OwnedFileBudgets(limits: limits, freeDiskBytes: { _ in Int64.max / 2 })
        io = BodyFileIO(directory: root.appendingPathComponent("spool"), eventLoop: loop, budgets: budgets,
                        limits: limits, threadPool: pool, hooks: BodyFileIOHooks())
    }

    func close() async throws {
        try? await pool.shutdownGracefully()
        await loop.shutdownGracefully()
        try? FileManager.default.removeItem(at: root)
    }

    var files: [String] { (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] }

    func onLoop<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        let result = try await loop.executeInContext(body)
        await loop.run()
        return result
    }

    func make(length: Int64, direction: HTTPMessageDirection = .request, headers: [HeaderField] = [HeaderField(name: "Content-Type", value: "application/json")],
              decode: @escaping @Sendable (Data, [HeaderField], RulesLimits) -> BodyPeek = ExchangeBodyPeeker.standardDecode)
        async throws -> NIOLoopBound<ExchangeBodyPeeker>
    {
        let events = self.events, io = self.io, limits = self.limits, loop = self.loop
        return try await onLoop {
            let peeker = try ExchangeBodyPeeker(
                loop: loop, io: io, limits: limits, expectedLength: length, headers: headers, direction: direction, decode: decode,
                changed: { events.changed() },
                completed: { events.completed($0, $1) },
                failed: { events.failed($0) })
            return NIOLoopBound(peeker, eventLoop: loop)
        }
    }

    func feed(_ gate: NIOLoopBound<ExchangeBodyPeeker>, _ chunks: [String], end: Bool = true) async throws {
        try await onLoop {
            for chunk in chunks { gate.value.append(ByteBuffer(string: chunk)) }
            if end { gate.value.finishBody(trailers: []) }
        }
    }

    func waitReleased() async throws {
        try await waitUntil("budgets \(budgets.snapshot()) and files \(files) released") {
            budgets.snapshot().reservedBytes == 0 && files.isEmpty
        }
    }
}

/// Every callback the gate made. Lock-protected; the gate calls it on its loop.
private final class PeekerEvents: Sendable {
    struct State: Sendable {
        var changes = 0
        var completions: [(ExactBodySource, BodyPeek)] = []
        var failures: [BodyRewriteFailure] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var snapshot: State { state.withLock { $0 } }
    func changed() { state.withLock { $0.changes += 1 } }
    func completed(_ source: ExactBodySource, _ peek: BodyPeek) { state.withLock { $0.completions.append((source, peek)) } }
    func failed(_ failure: BodyRewriteFailure) { state.withLock { $0.failures.append(failure) } }

    func completion() async throws -> (ExactBodySource, BodyPeek) {
        try await waitUntil("a completion; \(snapshot.failures)") { !snapshot.completions.isEmpty }
        return snapshot.completions[0]
    }
    func failure() async throws -> BodyRewriteFailure {
        try await waitUntil("a failure; \(snapshot.completions.count) completions") { !snapshot.failures.isEmpty }
        return snapshot.failures[0]
    }
}

private func readAll(_ source: ExactBodySource) async throws -> String {
    var data = Data()
    while true {
        let chunk = try await source.read(offset: Int64(data.count), maxBytes: 65_536)
        if chunk.isEmpty { return String(decoding: data, as: UTF8.self) }
        data.append(chunk)
    }
}

@Suite(.serialized, .timeLimit(.minutes(2)), .productionChinese) struct ExchangeBodyPeekerTests {
    @Test func responseDirectionPeekCollectsAndHandsOnTheBody() async throws {
        let fixture = PeekerFixture()
        let gate = try await fixture.make(length: 5, direction: .response)
        #expect(try await fixture.onLoop { gate.value.direction } == .response)
        try await fixture.onLoop { gate.value.start() }
        try await fixture.feed(gate, ["hel", "lo"])
        let (source, peek) = try await fixture.events.completion()
        #expect(peek == .text("hello"))
        #expect(try await readAll(source) == "hello")
        source.cancel()
        try await fixture.waitReleased()
        try await fixture.close()
    }

    @Test func collectsTheBodyAndHandsItOnUntouched() async throws {
        let f = PeekerFixture()
        let body = #"{"vip":true,"name":"x"}"#
        let gate = try await f.make(length: Int64(body.utf8.count))
        try await f.onLoop { gate.value.start() }
        #expect(try await f.onLoop {
            gate.value.isCollecting && gate.value.direction == .request && gate.value.timerCount == 1 && gate.value.canRead
        })
        try await f.feed(gate, [String(body.prefix(5)), String(body.dropFirst(5))])
        let (source, peek) = try await f.events.completion()
        #expect(peek == .text(body))
        #expect(source.size == Int64(body.utf8.count))
        #expect(try await readAll(source) == body)
        #expect(try await f.onLoop {
            !gate.value.isCollecting && gate.value.timerCount == 0 && gate.value.receivedEnd && gate.value.received == 23
        })
        #expect(f.events.snapshot.failures.isEmpty)
        // The decode memory is returned once the peek is handed on; only the collected body stays.
        try await waitUntil("decode memory returned") { f.budgets.snapshot().bytes[.editor] == nil }
        source.cancel()
        try await f.waitReleased()
        try await f.close()
    }

    @Test func idleDeadlineFailsWithoutLeakingTheSpool() async throws {
        let f = PeekerFixture(limits: RulesLimits(minimumFreeDiskBytes: 0, rewriteSeconds: 30))
        let gate = try await f.make(length: 10)
        try await f.onLoop { gate.value.start() }
        try await f.feed(gate, ["abc"], end: false)
        try await waitUntil("bytes spooled") { (f.budgets.snapshot().bytes[.breakpoint] ?? 0) > 0 }
        await f.loop.advanceTime(by: .seconds(29))
        #expect(f.events.snapshot.failures.isEmpty)
        await f.loop.advanceTime(by: .seconds(2))
        #expect(try await f.events.failure() == .timedOut)
        #expect(try await f.onLoop { gate.value.timerCount == 0 && !gate.value.isCollecting && gate.value.received == 3 })
        try await f.waitReleased()
        #expect(f.events.snapshot.completions.isEmpty)
        try await f.close()
    }

    @Test func overallDeadlineFails() async throws {
        // The peek's own overall cap (60 s by default), not the rewriter's 600 s.
        #expect(RulesLimits().conditionBodyTotalSeconds == 60)
        let f = PeekerFixture(limits: RulesLimits(minimumFreeDiskBytes: 0, rewriteSeconds: 30, conditionBodyTotalSeconds: 50))
        let gate = try await f.make(length: 100)
        try await f.onLoop { gate.value.start() }
        // A steady trickle never trips the idle deadline, but the overall cap still ends it.
        for _ in 0..<2 {
            try await f.feed(gate, ["a"], end: false)
            await f.loop.advanceTime(by: .seconds(20))
        }
        #expect(f.events.snapshot.failures.isEmpty)
        try await f.feed(gate, ["a"], end: false)
        await f.loop.advanceTime(by: .seconds(11))
        #expect(try await f.events.failure() == .timedOut)
        #expect(try await f.onLoop { gate.value.timerCount == 0 && gate.value.overallTimerCount == 0 })
        try await f.waitReleased()
        try await f.close()
    }

    @Test func abandonReleasesBudgetAndFile() async throws {
        let f = PeekerFixture()
        let gate = try await f.make(length: 20)
        try await f.onLoop { gate.value.start() }
        try await f.feed(gate, ["aaaa", "bbbb"], end: false)
        try await waitUntil("bytes spooled") { (f.budgets.snapshot().bytes[.breakpoint] ?? 0) > 0 }
        try await f.onLoop { gate.value.abandon() }
        #expect(try await f.onLoop { !gate.value.isCollecting && !gate.value.canRead && gate.value.timerCount == 0 })
        try await f.waitReleased()
        // Nothing fires after an abandon, not even for a late END.
        try await f.onLoop { gate.value.finishBody(trailers: []) }
        #expect(f.events.snapshot.completions.isEmpty && f.events.snapshot.failures.isEmpty)
        try await f.close()
    }

    @Test func abandonWhileDecodingReleasesTheCollectedBody() async throws {
        let f = PeekerFixture()
        let entered = OSAllocatedUnfairLock(initialState: false)
        let release = DispatchSemaphore(value: 0)
        let gate = try await f.make(length: 5, decode: { data, headers, limits in
            entered.withLock { $0 = true }
            // Bounded, so a broken test fails instead of hanging.
            _ = release.wait(timeout: .now() + 10)
            return ExchangeBodyPeeker.standardDecode(data, headers, limits)
        })
        try await f.onLoop { gate.value.start() }
        try await f.feed(gate, ["hello"])
        try await waitUntil("decode entered") { entered.withLock { $0 } }
        try await f.onLoop { gate.value.abandon() }
        release.signal()
        try await f.waitReleased()
        #expect(f.events.snapshot.completions.isEmpty && f.events.snapshot.failures.isEmpty)
        try await f.close()
    }

    @Test func knownLengthOverTheCapIsNeverCreated() async throws {
        let limits = RulesLimits(minimumFreeDiskBytes: 0)
        let over = limits.conditionBodyBytes + 1
        let headers = [HeaderField(name: "Content-Type", value: "application/json"), HeaderField(name: "Content-Length", value: "\(over)")]
        #expect(BodyPeekRules.classify(headers: headers, knownLength: nil, isHeadOrNoBody: false, limits: limits) == .skip(.bodyTooLarge))
        let f = PeekerFixture(limits: limits)
        let events = f.events, io = f.io, loop = f.loop
        let refused = try await f.onLoop { () -> Bool in
            do {
                _ = try ExchangeBodyPeeker(loop: loop, io: io, limits: limits, expectedLength: Int64(over), headers: headers,
                                           changed: { events.changed() }, completed: { events.completed($0, $1) },
                                           failed: { events.failed($0) })
                return false
            } catch BodyRewriteFailure.tooLarge { return true }
        }
        #expect(refused)
        #expect(f.budgets.snapshot().reservedBytes == 0 && f.files.isEmpty)
        try await f.close()
    }

    @Test func peekIsDecodedOffTheLoop() async throws {
        let f = PeekerFixture()
        let onLoop = OSAllocatedUnfairLock(initialState: [Bool]())
        let loop = f.loop
        let gate = try await f.make(length: 5, decode: { data, headers, limits in
            onLoop.withLock { $0.append(loop.inEventLoop) }
            return ExchangeBodyPeeker.standardDecode(data, headers, limits)
        })
        try await f.onLoop { gate.value.start() }
        try await f.feed(gate, ["hello"])
        let (source, peek) = try await f.events.completion()
        #expect(peek == .text("hello"))
        #expect(onLoop.withLock { $0 } == [false])
        source.cancel()
        try await f.waitReleased()
        try await f.close()
    }

    @Test func busyDecodeMemoryStillHandsTheBodyOnAsUnknown() async throws {
        // Too little editor memory for the decode: the peek is unknown, the collected body still continues.
        let f = PeekerFixture(limits: RulesLimits(editorMemoryBytes: 1024, minimumFreeDiskBytes: 0))
        let gate = try await f.make(length: 5)
        try await f.onLoop { gate.value.start() }
        try await f.feed(gate, ["hello"])
        let (source, peek) = try await f.events.completion()
        #expect(peek == .skipped(.bodySkippedUnavailable))
        #expect(try await readAll(source) == "hello")
        source.cancel()
        try await f.waitReleased()
        try await f.close()
    }

    @Test func gzipBodyIsDecodedForThePeekButHandedOnCompressed() async throws {
        let f = PeekerFixture()
        let gzipHello: [UInt8] = [31, 139, 8, 0, 0, 0, 0, 0, 0, 3, 203, 72, 205, 201, 201, 7, 0, 134, 166, 16, 54, 5, 0, 0, 0]
        let headers = [HeaderField(name: "Content-Type", value: "text/plain"), HeaderField(name: "Content-Encoding", value: "gzip")]
        let gate = try await f.make(length: Int64(gzipHello.count), headers: headers)
        try await f.onLoop {
            gate.value.start()
            gate.value.append(ByteBuffer(bytes: gzipHello))
            gate.value.finishBody(trailers: [])
        }
        let (source, peek) = try await f.events.completion()
        #expect(peek == .text("hello"))
        var data = Data()
        while Int64(data.count) < source.size { data.append(try await source.read(offset: Int64(data.count), maxBytes: 65_536)) }
        #expect(data == Data(gzipHello))
        source.cancel()
        try await f.waitReleased()
        try await f.close()
    }
}
