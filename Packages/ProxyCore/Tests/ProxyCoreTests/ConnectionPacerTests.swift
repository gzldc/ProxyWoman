import Foundation
import NIOCore
import NIOEmbedded
import NIOSSL
import os
import Testing
@testable import ProxyCore
@testable import RulesEngine

/// The read gate on its own, on an `EmbeddedChannel` with a manually advanced clock: nothing in
/// here sleeps. Inbound bytes are fired from the socket side (the head of the pipeline), reads
/// come from the downstream side (the tail), and `SocketReads` counts the reads that reach the
/// socket.
@Suite(.serialized, .timeLimit(.minutes(1)), .productionChinese) struct ConnectionPacerTests {
    static let host = "origin.test"
    static let port = 443

    // MARK: Fast path

    @Test func inactivePacerPassesBytesAndEventsThroughUntouched() throws {
        func script(_ harness: PacerHarness) throws -> [PacerLog.Event] {
            harness.downstreamRead()
            harness.socket(bytes: 100, fill: 1)
            harness.socket(bytes: 3, fill: 2, complete: false)
            harness.sync.fireUserInboundEventTriggered(PacerTestEvent.ping)
            harness.sync.fireErrorCaught(PacerTestError.boom)
            harness.downstreamRead()
            harness.socket(bytes: 7, fill: 3)
            harness.sync.fireChannelInactive()
            return harness.log.events
        }
        let direct = try PacerHarness(traffic: nil)
        let expected = try script(direct)
        #expect(direct.reads.count == 2)
        // A provider with nothing switched on, one whose conditions are off, an unbound pacer
        // and a host no rule matches: all take the fast path.
        var disabled = TrafficPolicy()
        disabled.conditions.global = .custom(NetworkProfile(downloadKbps: 8, uploadKbps: 8, latencyMs: 900, lossPercent: 0))
        var elsewhere = TrafficPolicy()
        elsewhere.conditions.enabled = true
        elsewhere.conditions.hostRules = [HostNetworkRule(hostPattern: "elsewhere.test", selection: .preset(.edge))]
        for (policy, bound) in [(TrafficPolicy(), true), (disabled, true), (Self.throttled(latencyMs: 500), false), (elsewhere, true)] {
            let harness = try PacerHarness(policy: policy, bind: bound)
            #expect(try script(harness) == expected)
            #expect(harness.reads.count == direct.reads.count)
            #expect(harness.pacer?.queuedBytes == 0)
            #expect(harness.pacer?.hasPendingTimer == false)
            // Not a copy: the buffer downstream is the very storage the socket produced.
            #expect(harness.log.storages == harness.sentStorages)
        }
    }

    // MARK: Shaping

    @Test func bandwidthDelaysDeliveryInDueOrder() throws {
        // 800 kbps = 100_000 bytes/s: 10_000 bytes take 100 ms, the next 10_000 another 100 ms.
        let harness = try PacerHarness(policy: Self.throttled(downloadKbps: 800), direction: .download)
        harness.socket(bytes: 10_000, fill: 1)
        harness.socket(bytes: 10_000, fill: 2)
        #expect(harness.pacer?.queuedBytes == 20_000)
        harness.advance(ms: 99)
        #expect(harness.log.events.isEmpty)
        harness.advance(ms: 1)
        #expect(harness.log.events == [.data(10_000, fill: 1), .readComplete])
        harness.advance(ms: 99)
        #expect(harness.log.events.count == 2)
        harness.advance(ms: 1)
        #expect(harness.log.events == [.data(10_000, fill: 1), .readComplete, .data(10_000, fill: 2), .readComplete])
        #expect(harness.pacer?.queuedBytes == 0)
        #expect(harness.pacer?.hasPendingTimer == false)
    }

    @Test func slicesAreAtMostSliceBytes() throws {
        // 131_072 kbps = 16_384_000 bytes/s: one 16 KiB slice per millisecond.
        let harness = try PacerHarness(policy: Self.throttled(downloadKbps: 131_072), direction: .download)
        harness.socket(bytes: 40_000, fill: 7)
        harness.advance(ms: 1)
        // Each delivery burst ends the downstream read cycle, so bytes are flushed as they pace.
        #expect(harness.log.events == [.data(16_384, fill: 7), .readComplete])
        harness.advance(ms: 2)
        #expect(harness.log.dataSizes == [16_384, 16_384, 7_232])
        #expect(harness.log.dataSizes.allSatisfy { $0 <= ConnectionPacer.sliceBytes })
        #expect(harness.log.events.last == .readComplete)
        #expect(harness.log.events.filter { $0 == .readComplete }.count == 3)
        #expect(harness.log.bytes == [UInt8](repeating: 7, count: 40_000))
    }

    @Test func latencyDelaysFirstByte() throws {
        let harness = try PacerHarness(policy: Self.throttled(latencyMs: 50), direction: .download)
        harness.socket(bytes: 1, fill: 1)
        harness.advance(ms: 49)
        #expect(harness.log.events.isEmpty)
        harness.advance(ms: 1)
        #expect(harness.log.events == [.data(1, fill: 1), .readComplete])
    }

    @Test func uploadAndDownloadUseTheirOwnRates() throws {
        // Download 800 kbps (100 ms for 10_000 bytes), upload 400 kbps (200 ms).
        let policy = Self.throttled(downloadKbps: 800, uploadKbps: 400)
        let download = try PacerHarness(policy: policy, direction: .download)
        let upload = try PacerHarness(policy: policy, direction: .upload)
        download.socket(bytes: 10_000, fill: 1)
        upload.socket(bytes: 10_000, fill: 1)
        download.advance(ms: 100)
        upload.advance(ms: 199)
        #expect(download.log.dataSizes == [10_000])
        #expect(upload.log.dataSizes.isEmpty)
        upload.advance(ms: 1)
        #expect(upload.log.dataSizes == [10_000])
    }

    @Test func lossAddsRetransmitDelayWithInjectedRandom() throws {
        // 50 % loss on a one-packet chunk: a draw below 0.5 is a loss and costs one retransmit,
        // max(200 ms, 4 × 100 ms) = 400 ms on top of the 100 ms latency.
        let lost = try PacerHarness(policy: Self.throttled(latencyMs: 100, lossPercent: 50), direction: .download, draws: [0.1, 0.9])
        lost.socket(bytes: 100, fill: 1)
        lost.socket(bytes: 100, fill: 2)
        lost.advance(ms: 100)
        // The second chunk was not lost, but TCP order keeps it behind the retransmitted first.
        #expect(lost.log.events.isEmpty)
        lost.advance(ms: 399)
        #expect(lost.log.events.isEmpty)
        lost.advance(ms: 1)
        #expect(lost.log.dataSizes == [100, 100])
        let kept = try PacerHarness(policy: Self.throttled(latencyMs: 100, lossPercent: 50), direction: .download, draws: [0.9])
        kept.socket(bytes: 100, fill: 1)
        kept.advance(ms: 100)
        #expect(kept.log.dataSizes == [100])
    }

    // MARK: Pull model and memory bound

    @Test func noDeliveryWithoutDownstreamRead() throws {
        let harness = try PacerHarness(policy: Self.throttled(latencyMs: 10), direction: .download)
        let automatic = OSAllocatedUnfairLock(initialState: false)
        harness.pacer?.autoReadProbe = { _ in automatic.withLock { $0 } }
        harness.socket(bytes: 10, fill: 1)
        harness.socket(bytes: 20, fill: 2)
        harness.advance(ms: 1_000)
        #expect(harness.log.events.isEmpty)
        #expect(harness.pacer?.queuedBytes == 30)
        // One downstream read is one read cycle: up to the next channelReadComplete.
        harness.downstreamRead()
        #expect(harness.log.events == [.data(10, fill: 1), .readComplete])
        harness.advance(ms: 1_000)
        #expect(harness.log.events.count == 2)
        harness.downstreamRead()
        #expect(harness.log.events == [.data(10, fill: 1), .readComplete, .data(20, fill: 2), .readComplete])
    }

    @Test func reenabledAutoReadResumesWithoutNewSocketData() throws {
        // Turning autoRead back on never reaches the pipeline as a read(); the paused gate notices
        // it on its own, without any further byte from the socket.
        let harness = try PacerHarness(policy: Self.throttled(latencyMs: 10), direction: .download)
        let automatic = OSAllocatedUnfairLock(initialState: false)
        harness.pacer?.autoReadProbe = { _ in automatic.withLock { $0 } }
        harness.socket(bytes: 10, fill: 1)
        harness.advance(ms: 100)
        #expect(harness.log.events.isEmpty)
        #expect(harness.pacer?.hasPendingTimer == true)
        automatic.withLock { $0 = true }
        harness.advance(ms: Int(ConnectionPacer.pausedRecheck.nanoseconds / 1_000_000))
        #expect(harness.log.events == [.data(10, fill: 1), .readComplete])
        #expect(harness.pacer?.hasPendingTimer == false)
    }

    @Test func socketReadsStopAtMaxQueuedBytes() throws {
        // 8_192 kbps = 1_024_000 bytes/s: one 16 KiB slice every 16 ms.
        let harness = try PacerHarness(policy: Self.throttled(downloadKbps: 8_192), direction: .download)
        harness.downstreamRead()
        #expect(harness.reads.count == 1)
        for fill in 0..<16 { harness.socket(bytes: 16_384, fill: UInt8(fill), complete: false) }
        harness.sync.fireChannelReadComplete()
        #expect(harness.pacer?.queuedBytes == ConnectionPacer.maxQueuedBytes)
        harness.downstreamRead()
        #expect(harness.reads.count == 1)
        harness.advance(ms: 15)
        #expect(harness.reads.count == 1)
        harness.advance(ms: 1)
        #expect(harness.log.dataSizes == [16_384])
        #expect(harness.pacer?.queuedBytes == ConnectionPacer.maxQueuedBytes - 16_384)
        // The withheld read reaches the socket once the queue is below the cap again, once.
        #expect(harness.reads.count == 2)
        harness.advance(ms: 16)
        #expect(harness.reads.count == 2)
    }

    @Test func autoReadReEnableIsHeldAtTheCap() throws {
        // 8_192 kbps = 1_024_000 bytes/s: one 16 KiB slice every 16 ms.
        let harness = try PacerHarness(policy: Self.throttled(downloadKbps: 8_192), direction: .download)
        let pacer = try #require(harness.pacer)
        // The real flag stays off while a re-enable is held (an embedded channel always says on).
        pacer.autoReadProbe = { _ in false }
        // Below the cap a re-enable goes straight to the channel, and with nothing queued the
        // gate never takes part (the off state is unchanged).
        harness.channel.setAutoRead(true)
        #expect(!pacer.autoReadHeld)
        for fill in 0..<16 { harness.socket(bytes: 16_384, fill: UInt8(fill), complete: false) }
        harness.sync.fireChannelReadComplete()
        harness.channel.setAutoRead(false)
        harness.channel.setAutoRead(true)
        #expect(pacer.autoReadHeld)
        // Turning reading off again drops the held re-enable; turning it on holds it again.
        harness.channel.setAutoRead(false)
        #expect(!pacer.autoReadHeld)
        harness.advance(ms: 16)
        #expect(harness.log.events.isEmpty)
        // A held re-enable counts as reading: the due slice goes at once, and with the queue
        // below the cap the re-enable is applied to the channel.
        harness.channel.setAutoRead(true)
        #expect(harness.log.events == [.data(16_384, fill: 0), .readComplete])
        #expect(pacer.queuedBytes < ConnectionPacer.maxQueuedBytes)
        #expect(!pacer.autoReadHeld)
    }

    // MARK: Ordering

    @Test func eofWaitsForQueuedData() throws {
        let harness = try PacerHarness(policy: Self.throttled(latencyMs: 100), direction: .download)
        harness.socket(bytes: 1_000, fill: 4)
        harness.sync.fireChannelInactive()
        harness.advance(ms: 99)
        #expect(harness.log.events.isEmpty)
        harness.advance(ms: 1)
        #expect(harness.log.events == [.data(1_000, fill: 4), .readComplete, .inactive])
    }

    @Test func remoteEndOfInputIsPacedLikeTheBytesBeforeIt() throws {
        // A download gate that shapes asks the channel to keep it open at the origin's FIN (half
        // closure), because NIO would otherwise close the channel and tear the pipeline down,
        // releasing the whole queue at once. The end of input is held behind the queued bytes
        // and the gate closes the channel itself when they are all delivered.
        // 800 kbps = 100_000 bytes/s: 10_000 bytes take 100 ms.
        let harness = try PacerHarness(policy: Self.throttled(downloadKbps: 800), direction: .download)
        try harness.activate()
        #expect(try harness.channel.syncOptions?.getOption(ChannelOptions.allowRemoteHalfClosure) == true)
        harness.socket(bytes: 10_000, fill: 3)
        harness.sync.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
        harness.advance(ms: 99)
        #expect(harness.log.events.isEmpty)
        #expect(harness.channel.isActive)
        harness.advance(ms: 1)
        #expect(harness.log.bytes == [UInt8](repeating: 3, count: 10_000))
        #expect(!harness.channel.isActive)
        #expect(harness.log.events.last == .inactive)
        #expect(!harness.log.events.contains(.user("inputClosed")))
        #expect(harness.pacer?.queuedBytes == 0)
        #expect(harness.pacer?.hasPendingTimer == false)
    }

    @Test func remoteEndOfInputWithNothingQueuedClosesAtOnce() throws {
        let harness = try PacerHarness(policy: Self.throttled(downloadKbps: 800), direction: .download)
        try harness.activate()
        harness.sync.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
        #expect(!harness.channel.isActive)
        #expect(harness.log.events == [.inactive])
    }

    @Test func halfClosureIsOnlyAskedForWhileShapingTheDownload() throws {
        func halfClosure(_ harness: PacerHarness) throws -> Bool {
            try harness.activate()
            return try harness.channel.syncOptions?.getOption(ChannelOptions.allowRemoteHalfClosure) ?? false
        }
        // Without a condition the channel is configured exactly as without a gate, and a FIN
        // (which then arrives as channelInactive) passes untouched.
        #expect(try !halfClosure(PacerHarness(policy: TrafficPolicy(), direction: .download)))
        // The upload gate leaves the client connection alone: a client that disconnects is gone,
        // so what it sent is released in order at once.
        #expect(try !halfClosure(PacerHarness(policy: Self.throttled(latencyMs: 50), direction: .upload)))
        // A live change follows the condition.
        let traffic = TrafficPolicyProvider(Self.throttled(latencyMs: 50))
        let live = try PacerHarness(traffic: traffic, direction: .download)
        #expect(try halfClosure(live))
        traffic.publish(TrafficPolicy())
        live.socket(bytes: 1, fill: 1)
        #expect(try !live.channel.syncOptions!.getOption(ChannelOptions.allowRemoteHalfClosure))
    }

    @Test func removalReleasesAHeldEndOfInputInOrder() throws {
        // A client that goes away mid-download tears the upstream channel down: what is queued
        // (bytes, then the held end of input, which is the close it stands for) is released at
        // once and in order, not paced.
        let harness = try PacerHarness(policy: Self.throttled(latencyMs: 100), direction: .download)
        try harness.activate()
        let pacer = try #require(harness.pacer)
        harness.socket(bytes: 64, fill: 5)
        harness.sync.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
        try harness.channel.pipeline.syncOperations.removeHandler(pacer).wait()
        #expect(harness.log.events == [.data(64, fill: 5), .readComplete, .inactive])
        #expect(!harness.channel.isActive)
        #expect(!pacer.hasPendingTimer)
        _ = try? harness.channel.finish()
    }

    @Test func raggedTLSEndClosesPastTheTLSLayerButACleanEndClosesThroughIt() throws {
        // A TLS layer in front of the gate waits for the peer's close_notify when it is asked to close.
        // After an unclean EOF none will come, so the close skips that layer; after a clean end it
        // goes through the layer as before.
        for ragged in [true, false] {
            let loop = EmbeddedEventLoop()
            let tls = FakeTLSLayer()
            let log = PacerLog()
            let pacer = ConnectionPacer(
                direction: .download, traffic: TrafficPolicyProvider(Self.throttled(downloadKbps: 800)),
                clock: { .nanoseconds(Int64(loop.now.uptimeNanoseconds)) })
            let channel = EmbeddedChannel(handlers: [UpstreamSocketCloser(), tls, pacer, log], loop: loop)
            pacer.bind(host: Self.host, port: Self.port)
            try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait()
            let sync = channel.pipeline.syncOperations
            sync.fireChannelRead(NIOAny(ByteBuffer(repeating: 1, count: 10_000)))
            sync.fireChannelReadComplete()
            if ragged { sync.fireErrorCaught(NIOSSLError.uncleanShutdown) }
            sync.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
            #expect(channel.isActive)
            loop.advanceTime(by: .milliseconds(100))
            #expect(!channel.isActive)
            #expect(tls.closes == (ragged ? 0 : 1), "ragged \(ragged)")
            #expect(log.bytes.count == 10_000)
            #expect(log.events.last == .inactive)
        }
    }

    @Test func errorsAndUserEventsKeepOrder() throws {
        let harness = try PacerHarness(policy: Self.throttled(latencyMs: 100), direction: .upload)
        harness.socket(bytes: 5, fill: 1, complete: false)
        harness.sync.fireUserInboundEventTriggered(PacerTestEvent.ping)
        harness.sync.fireErrorCaught(PacerTestError.boom)
        harness.socket(bytes: 6, fill: 2)
        #expect(harness.log.events.isEmpty)
        harness.advance(ms: 100)
        #expect(harness.log.events == [
            .data(5, fill: 1), .user("ping"), .error("boom"), .data(6, fill: 2), .readComplete,
        ])
    }

    // MARK: Live changes

    @Test func revisionChangeDrainsQueueThenFastPath() throws {
        let traffic = TrafficPolicyProvider(Self.throttled(latencyMs: 100))
        let harness = try PacerHarness(traffic: traffic, direction: .download)
        harness.socket(bytes: 10, fill: 1)
        traffic.publish(TrafficPolicy())
        // The condition is gone, but bytes read now still queue behind the undelivered ones.
        harness.socket(bytes: 20, fill: 2)
        harness.downstreamRead()
        #expect(harness.log.events.isEmpty)
        harness.advance(ms: 100)
        #expect(harness.log.events == [.data(10, fill: 1), .readComplete, .data(20, fill: 2), .readComplete])
        #expect(harness.pacer?.queuedBytes == 0)
        let delivered = harness.log.storages.count
        harness.socket(bytes: 30, fill: 3)
        #expect(harness.log.dataSizes == [10, 20, 30])
        #expect(harness.log.storages.suffix(from: delivered).elementsEqual(harness.sentStorages.suffix(1)))
        // And a newly published condition applies to the live connection at its next read.
        traffic.publish(Self.throttled(latencyMs: 50))
        harness.socket(bytes: 40, fill: 4)
        harness.advance(ms: 49)
        #expect(harness.log.dataSizes == [10, 20, 30])
        harness.advance(ms: 1)
        #expect(harness.log.dataSizes == [10, 20, 30, 40])
    }

    @Test func bindResolvesTheNewHost() throws {
        var policy = TrafficPolicy()
        policy.conditions.enabled = true
        policy.conditions.hostRules = [HostNetworkRule(hostPattern: "slow.test", selection: .custom(
            NetworkProfile(downloadKbps: nil, uploadKbps: nil, latencyMs: 100, lossPercent: 0)))]
        let harness = try PacerHarness(policy: policy, direction: .upload, bind: false)
        harness.pacer?.bind(host: "fast.test", port: 80)
        harness.socket(bytes: 1, fill: 1)
        #expect(harness.log.dataSizes == [1])
        harness.pacer?.bind(host: "slow.test", port: 80)
        harness.socket(bytes: 2, fill: 2)
        #expect(harness.log.dataSizes == [1])
        harness.advance(ms: 100)
        #expect(harness.log.dataSizes == [1, 2])
    }

    @Test func offlineClosesAtNextRead() throws {
        let traffic = TrafficPolicyProvider()
        let harness = try PacerHarness(traffic: traffic, direction: .download)
        try harness.activate()
        harness.socket(bytes: 3, fill: 1)
        #expect(harness.log.dataSizes == [3])
        var offline = TrafficPolicy()
        offline.conditions.enabled = true
        offline.conditions.global = .preset(.offline)
        traffic.publish(offline)
        #expect(harness.channel.isActive)
        harness.downstreamRead()
        #expect(!harness.channel.isActive)
        #expect(harness.reads.count == 0)
        #expect(harness.log.events.last == .inactive)

        // Bytes arriving after the change count as the next read; queued bytes go with them.
        let shaped = TrafficPolicyProvider(Self.throttled(latencyMs: 100))
        let arriving = try PacerHarness(traffic: shaped, direction: .upload)
        try arriving.activate()
        arriving.socket(bytes: 9, fill: 1)
        shaped.publish(offline)
        arriving.socket(bytes: 5, fill: 2)
        #expect(!arriving.channel.isActive)
        #expect(arriving.pacer?.queuedBytes == 0)
        #expect(arriving.pacer?.hasPendingTimer == false)
        arriving.advance(ms: 1_000)
        #expect(arriving.log.dataSizes.isEmpty)

        // Binding to a host that is already offline leaves the connection open: that connect
        // fails locally instead, and the client may still use the connection for other hosts.
        let bound = try PacerHarness(policy: offline, direction: .upload)
        try bound.activate()
        bound.socket(bytes: 2, fill: 1)
        bound.downstreamRead()
        #expect(bound.channel.isActive)
        #expect(bound.log.dataSizes == [2])
    }

    // MARK: Removal

    @Test func removalCancelsTimersAndReleasesQueue() throws {
        weak var released: ConnectionPacer?
        try {
            let harness = try PacerHarness(policy: Self.throttled(latencyMs: 100), direction: .download)
            let pacer = try #require(harness.pacer)
            released = pacer
            harness.socket(bytes: 64, fill: 5)
            harness.sync.fireChannelInactive()
            #expect(pacer.hasPendingTimer)
            // Removal (also pipeline teardown after a close) releases the queue in order rather
            // than dropping it: nothing is truncated and the end still reaches downstream.
            try harness.channel.pipeline.syncOperations.removeHandler(pacer).wait()
            #expect(harness.log.events == [.data(64, fill: 5), .readComplete, .inactive])
            #expect(pacer.queuedBytes == 0)
            #expect(!pacer.hasPendingTimer)
            harness.advance(ms: 1_000)
            #expect(harness.log.events.count == 3)
            _ = try? harness.channel.finish()
        }()
        #expect(released == nil)
    }

    // MARK: Support

    static func throttled(downloadKbps: Int? = nil, uploadKbps: Int? = nil, latencyMs: Int = 0,
                          lossPercent: Double = 0) -> TrafficPolicy {
        var policy = TrafficPolicy()
        policy.conditions.enabled = true
        policy.conditions.global = .custom(NetworkProfile(
            downloadKbps: downloadKbps, uploadKbps: uploadKbps ?? downloadKbps, latencyMs: latencyMs, lossPercent: lossPercent))
        return policy
    }
}

enum PacerTestEvent: CustomStringConvertible {
    case ping
    var description: String { "ping" }
}

enum PacerTestError: Error, CustomStringConvertible {
    case boom
    var description: String { "boom" }
}

/// `SocketReads → ConnectionPacer → PacerLog` on an embedded channel whose loop is the pacer's
/// clock.
final class PacerHarness {
    let loop: EmbeddedEventLoop
    let channel: EmbeddedChannel
    let reads: SocketReads
    let log: PacerLog
    let pacer: ConnectionPacer?
    private(set) var sentStorages: [UInt] = []

    convenience init(policy: TrafficPolicy, direction: ConnectionPacer.Direction = .download, draws: [Double] = [],
                     bind: Bool = true) throws {
        try self.init(traffic: TrafficPolicyProvider(policy), direction: direction, draws: draws, bind: bind)
    }

    init(traffic: TrafficPolicyProvider?, direction: ConnectionPacer.Direction = .download, draws: [Double] = [],
         bind: Bool = true) throws {
        let loop = EmbeddedEventLoop()
        let reads = SocketReads()
        let log = PacerLog()
        let sequence = OSAllocatedUnfairLock(initialState: draws)
        let pacer = traffic.map { traffic in
            ConnectionPacer(direction: direction, traffic: traffic,
                            clock: { .nanoseconds(Int64(loop.now.uptimeNanoseconds)) },
                            random: { sequence.withLock { $0.isEmpty ? 0.999 : $0.removeFirst() } })
        }
        var handlers: [ChannelHandler] = [reads]
        if let pacer { handlers.append(pacer) }
        handlers.append(log)
        self.loop = loop
        self.reads = reads
        self.log = log
        self.pacer = pacer
        channel = EmbeddedChannel(handlers: handlers, loop: loop)
        if bind { pacer?.bind(host: ConnectionPacerTests.host, port: ConnectionPacerTests.port) }
    }

    func activate() throws {
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait()
    }

    /// Bytes from the socket: one read of `bytes` bytes of `fill`, optionally ending the cycle.
    func socket(bytes: Int, fill: UInt8, complete: Bool = true) {
        let buffer = ByteBuffer(repeating: fill, count: bytes)
        sentStorages.append(PacerLog.storage(of: buffer))
        sync.fireChannelRead(NIOAny(buffer))
        if complete { sync.fireChannelReadComplete() }
    }

    var sync: ChannelPipeline.SynchronousOperations { channel.pipeline.syncOperations }

    func downstreamRead() { sync.read() }

    func advance(ms: Int) { loop.advanceTime(by: .milliseconds(Int64(ms))) }
}

/// Stands for the TLS handler between the socket and the gate: counts the closes that reach it.
final class FakeTLSLayer: ChannelOutboundHandler {
    typealias OutboundIn = NIOAny
    private(set) var closes = 0
    func close(context: ChannelHandlerContext, mode: NIOCore.CloseMode, promise: EventLoopPromise<Void>?) {
        closes += 1
        context.close(mode: mode, promise: promise)
    }
}

/// Counts reads that reach the socket.
final class SocketReads: ChannelOutboundHandler {
    typealias OutboundIn = NIOAny
    private(set) var count = 0
    func read(context: ChannelHandlerContext) {
        count += 1
        context.read()
    }
}

/// Everything that arrives downstream of the gate, in order.
final class PacerLog: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    enum Event: Equatable {
        case data(Int, fill: UInt8?)
        case readComplete, inactive
        case user(String)
        case error(String)
    }
    private(set) var events: [Event] = []
    private(set) var storages: [UInt] = []
    private(set) var bytes: [UInt8] = []
    var dataSizes: [Int] {
        events.compactMap { if case .data(let size, _) = $0 { size } else { nil } }
    }

    static func storage(of buffer: ByteBuffer) -> UInt {
        buffer.withUnsafeReadableBytes { UInt(bitPattern: $0.baseAddress) }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        let content = Array(buffer.readableBytesView)
        events.append(.data(content.count, fill: Set(content).count == 1 ? content.first : nil))
        storages.append(Self.storage(of: buffer))
        bytes += content
    }
    func channelReadComplete(context: ChannelHandlerContext) { events.append(.readComplete) }
    func channelInactive(context: ChannelHandlerContext) { events.append(.inactive) }
    func errorCaught(context: ChannelHandlerContext, error: Error) { events.append(.error("\(error)")) }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) { events.append(.user("\(event)")) }
}
