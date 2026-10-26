import Atomics
import CertKit
import Darwin
import FlowStore
import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOPosix
import NIOSSL
import Testing
import os
@testable import ProxyCore

/// Real loopback routing through the production forward-proxy pipeline, with an optional
/// coordinator (`nil` is the production observer-off path) and an injected monotonic clock.
final class WSLoadProxy: Sendable {
    static let frozenClock = WebSocketObservationClock(wallNow: { Date(timeIntervalSince1970: 1_000_000) }, monotonicNow: { 1 })
    let listener: Channel
    let store: FlowStore
    let coordinator: WebSocketCaptureCoordinator?
    let upstreams: OSAllocatedUnfairLock<[Channel]>
    let downstreams: OSAllocatedUnfairLock<[Channel]>
    private let group: MultiThreadedEventLoopGroup
    private let workers: NIOThreadPool
    private let directory: URL
    var port: Int { listener.localAddress!.port! }
    private init(listener: Channel, store: FlowStore, coordinator: WebSocketCaptureCoordinator?, upstreams: OSAllocatedUnfairLock<[Channel]>,
                 downstreams: OSAllocatedUnfairLock<[Channel]>, group: MultiThreadedEventLoopGroup, workers: NIOThreadPool, directory: URL) {
        self.listener = listener; self.store = store; self.coordinator = coordinator; self.upstreams = upstreams
        self.downstreams = downstreams; self.group = group; self.workers = workers; self.directory = directory
    }
    static func start(observe: Bool, limits: WebSocketLimits = .init(), clock: WebSocketObservationClock = frozenClock,
                      hooks: WebSocketObservationHooks = .init(), maxFlows: Int = 1000) async throws -> WSLoadProxy {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = FlowStore(bodyDirectory: directory, maxFlows: maxFlows, webSocketLimits: limits)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1), workers = NIOThreadPool(numberOfThreads: 1)
        workers.start()
        let recording = FlowRecording(store: store, isEnabled: ManagedAtomic(true))
        let coordinator = observe ? WebSocketCaptureCoordinator(store: store, clock: clock, hooks: hooks, controller: recording.webSocketController) : nil
        let upstreams = OSAllocatedUnfairLock(initialState: [Channel]()), downstreams = OSAllocatedUnfairLock(initialState: [Channel]())
        let environment = ProxyEnvironment(configuration: .init(), recording: recording,
            tls: TLSInterception(certificateAuthority: try CertificateAuthority.generate(commonName: "WS load CA")), passthrough: .init(),
            clientLookup: ClientLookupBatcher(processLookup: .none, threadPool: workers), webSockets: coordinator)
        do {
            let listener = try await ServerBootstrap(group: group).childChannelInitializer { child in
                downstreams.withLock { $0.append(child) }
                return child.eventLoop.makeCompletedFuture {
                    let connection = ClientConnectionContext(channel: child, environment: environment,
                        clientLookup: child.eventLoop.makeSucceededFuture(nil), connectionFactory: { host, port, loop in
                            ClientBootstrap(group: loop).connect(host: host, port: port).map { upstream in
                                upstreams.withLock { $0.append(upstream) }; return upstream
                            }
                        })
                    try child.pipeline.syncOperations.addHandlers([
                        HTTPMessageTranslation.responseEncoder(), HTTP1TransferCodingFramer<HTTPResponseHead>(),
                        ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)),
                        ProxyHandler(mode: .forwardProxy, environment: environment, inheritedConnection: connection),
                    ])
                }
            }.bind(host: "127.0.0.1", port: 0).get()
            return .init(listener: listener, store: store, coordinator: coordinator, upstreams: upstreams, downstreams: downstreams,
                         group: group, workers: workers, directory: directory)
        } catch {
            await coordinator?.shutdown(); try? await workers.shutdownGracefully(); try? await group.shutdownGracefully(); throw error
        }
    }
    func stop() async throws {
        try? await listener.close().get()
        for channel in downstreams.withLock({ $0 }) + upstreams.withLock({ $0 }) { try? await channel.close().get() }
        await coordinator?.shutdown()
        try await workers.shutdownGracefully(); try await group.shutdownGracefully()
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite(.serialized, .timeLimit(.minutes(3)), .productionChinese) struct WebSocketLoadTests {
    typealias IT = WebSocketIntegrationTests

    /// Runs `body` with a started origin and load proxy, always stopping both.
    static func with(origin script: [WebSocketOriginStep], extensions: String? = nil, observe: Bool = true,
                     limits: WebSocketLimits = .init(), hooks: WebSocketObservationHooks = .init(), maxFlows: Int = 1000,
                     _ body: (WebSocketOrigin, WSLoadProxy) async throws -> Void) async throws {
        let directory = IT.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let origin = try await WebSocketOrigin.start(tls: false, script: script, directory: directory, responseExtensions: extensions)
        var proxy: WSLoadProxy?
        do {
            let started = try await WSLoadProxy.start(observe: observe, limits: limits, hooks: hooks, maxFlows: maxFlows); proxy = started
            try await body(origin, started)
            try await started.stop(); try await origin.stop()
        } catch { try? await proxy?.stop(); try? await origin.stop(); throw error }
    }
    static func binary(_ index: Int, count: Int) -> [UInt8] { (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ index) } }
}

// MARK: - Delayed drain, saturation and backpressure

extension WebSocketLoadTests {
    /// The worker is held on its first chunk while 640 KiB more arrive: the per-session mailbox
    /// (256 KiB) refuses, capture stops first, and the raw relay still delivers every byte.
    @Test func delayedDrainSaturationStopsCaptureFirstWhileRawTransferFinishes() async throws {
        let greeting = WSWire.frame(1, Array("first".utf8))
        let bulk = (0..<40).map { WSWire.frame(2, Self.binary($0, count: 16_384)) }
        let take = WSBarrier()
        let tasks = ManagedAtomic(0)
        let hooks = WebSocketObservationHooks(afterTake: { await take.enter() }, coordinator: { stage in
            if stage == .beforeTaskPublication { tasks.wrappingIncrement(ordering: .relaxed) }
        })
        let directory = IT.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = [WebSocketOriginStep.send(bytes: Data(greeting))] + bulk.map { .send(bytes: Data($0)) } + [.barrier(name: "done"), .closeTransport]
        let origin = try await WebSocketOrigin.start(tls: false, script: script, directory: directory)
        let store = observationStore()
        do {
            try await IT.withServer(store: store, originCA: nil, hooks: hooks) { server, _ in
                let peer = try await WSProxyPeer.connect(proxyPort: try #require(server.boundPort), originPort: origin.port, tls: nil)
                do {
                    try await WSProxyPeer.upgrade(peer, originPort: origin.port, absolute: true)
                    let expected = greeting + bulk.flatMap { $0 }
                    #expect(try await peer.receive(count: expected.count, timeout: .seconds(30)) == expected)
                    try await origin.barriers.waitFor("done")
                    let (_, token) = try await IT.session(store)
                    let held = try #require(store.webSocketSummary(token: token))
                    print("WS_LOAD_SATURATION mailbox=\(store.webSocketBudget.usedBytes(category: .mailbox)) working=\(store.webSocketBudget.usedBytes(category: .working)) metadata=\(store.webSocketBudget.usedBytes(category: .metadata)) wire=\(held.serverToClient.wireBytes) lowerBound=\(held.lowerBound) workerTasks=\(tasks.load(ordering: .relaxed))")
                    #expect(store.webSocketBudget.usedBytes(category: .mailbox) <= store.webSocketLimits.sessionMailboxBytes)
                    #expect(held.lowerBound) // refusal stopped capture while the relay kept running
                    #expect(held.serverToClient.wireBytes == UInt64(expected.count)) // observed-byte counter remains exact
                    await take.release()
                    origin.barriers.release("done")
                    try await peer.waitUntilClosed()
                    try await waitUntil("both ends recorded") { store.webSocketSummary(token: token)?.lifecycle == .transportEndedWithoutClose }
                    #expect(IT.rows(store, token).isEmpty) // nothing is published from a cancelled session
                    #expect(tasks.load(ordering: .relaxed) == 1) // one lifetime worker, not one per read
                    #expect(origin.sent == expected && origin.transcript.failures.isEmpty)
                    try await peer.close()
                } catch { await take.release(); origin.barriers.release("done"); try? await peer.close(); throw error }
            }
            IT.expectObserverReservationsReleased(store)
            try await origin.stop()
        } catch { await take.release(); try? await origin.stop(); throw error }
    }

    /// A stalled reader propagates backpressure to the real upstream socket (autoRead off) while
    /// observation is on; resuming delivers every byte and the capture is complete. The origin
    /// keeps writing until backpressure is observed, so larger kernel buffers cannot defeat it.
    @Test func stalledReceiverBackpressurePreservesBytesAndCompleteCapture() async throws {
        var limits = WebSocketLimits()
        // Keep capture complete for exact assertions; buffered bytes are bounded by socket buffers.
        limits.sessionMailboxBytes = 8_388_608; limits.sessionPayloadBytes = 33_554_432
        let payload = 60_000, frameSize = payload + 4
        let script: [WebSocketOriginStep] = [.barrier(name: "stalled"),
            .sendGenerated(until: "pressure") { Data(WSWire.frame(2, Self.binary($0, count: payload))) },
            .barrier(name: "done"), .closeTransport]
        try await Self.with(origin: script, limits: limits) { origin, proxy in
            let peer = try await WSProxyPeer.connect(proxyPort: proxy.port, originPort: origin.port, tls: nil, receiveBufferSize: 16_384)
            do {
                try await WSProxyPeer.upgrade(peer, originPort: origin.port, absolute: true)
                try await peer.setReading(false)
                origin.barriers.release("stalled")
                let upstream = try #require(proxy.upstreams.withLock { $0.first })
                // Bounded poll of the real upstream socket option set by the Glue writability handler.
                let deadline = ContinuousClock.now + .seconds(30)
                while try await upstream.getOption(ChannelOptions.autoRead).get() {
                    guard ContinuousClock.now < deadline else { throw WaitTimeout(description: "upstream autoRead never turned off") }
                    try await Task.sleep(for: .milliseconds(20))
                }
                let atPause = origin.sent.count
                origin.barriers.release("pressure")
                try await peer.setReading(true)
                try await origin.barriers.waitFor("done")
                let expected = origin.sent
                print("WS_LOAD_BACKPRESSURE upstreamAutoRead=false originWrittenAtPause=\(atPause) total=\(expected.count) frames=\(expected.count / frameSize)")
                #expect(expected.count % frameSize == 0)
                #expect(try await peer.receive(count: expected.count, timeout: .seconds(60)) == expected)
                #expect(try await upstream.getOption(ChannelOptions.autoRead).get()) // reading resumed after drain
                origin.barriers.release("done")
                try await peer.waitUntilClosed()
                let frames = expected.count / frameSize
                let (_, token) = try await IT.session(proxy.store)
                try await waitUntil(timeout: .seconds(20), "both ends recorded") {
                    proxy.store.webSocketSummary(token: token)?.lifecycle == .transportEndedWithoutClose
                }
                var rows: [WebSocketEventMetadata] = [], cursor: UInt64?, more = true
                while more {
                    let page = try #require(proxy.store.webSocketPage(token: token, after: cursor, limit: 200))
                    rows += page.rows; cursor = page.nextCursor
                    more = cursor != nil && !page.rows.isEmpty
                }
                #expect(rows.count == frames)
                for (index, row) in rows.enumerated() {
                    #expect(row.kind == .binary && row.integrity == .transportComplete)
                    #expect(IT.payload(proxy.store, token, row) == Self.binary(index, count: payload), "row \(row.id)")
                }
                let summary = try #require(proxy.store.webSocketSummary(token: token))
                #expect(summary.serverToClient.applicationBytes == UInt64(frames * payload) && !summary.lowerBound)
                #expect(summary.serverToClient.wireBytes == UInt64(expected.count))
                try await peer.close()
            } catch {
                for name in ["stalled", "pressure", "done"] { origin.barriers.release(name) }
                try? await peer.close(); throw error
            }
        }
    }
}

// MARK: - Clear/eviction during publication and Pause/Resume

extension WebSocketLoadTests {
    @Test(arguments: ["clear", "evict"])
    func clearOrEvictionDuringPublicationNeverRescuesContent(mode: String) async throws {
        let before = WSWire.frame(1, Array("before".utf8)), after = WSWire.frame(1, Array("after".utf8))
        let reply = WSWire.client(1, Array("reply".utf8)), second = WSWire.frame(1, Array("second".utf8))
        let take = WSBarrier()
        let hooks = WebSocketObservationHooks(afterTake: { await take.enter() })
        let script: [WebSocketOriginStep] = [.send(bytes: Data(before)), .barrier(name: "next"), .send(bytes: Data(after)),
                                             .expect(bytes: Data(reply)), .closeTransport]
        let directory = IT.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let secondOrigin = try await WebSocketOrigin.start(tls: false, script: [.send(bytes: Data(second))], directory: directory)
        do {
            try await Self.with(origin: script, hooks: hooks, maxFlows: mode == "evict" ? 1 : 1000) { origin, proxy in
                let store = proxy.store
                let peer = try await WSProxyPeer.connect(proxyPort: proxy.port, originPort: origin.port, tls: nil)
                var other: RawClient?
                do {
                    try await WSProxyPeer.upgrade(peer, originPort: origin.port, absolute: true)
                    #expect(try await peer.receive(count: before.count) == before)
                    try await take.wait(timeout: .seconds(10), "worker take barrier") // the worker owns the first chunk and has not published it
                    let (flow, token) = try await IT.session(store)
                    if mode == "clear" { store.clear() }
                    let connected = try await WSProxyPeer.connect(proxyPort: proxy.port, originPort: secondOrigin.port, tls: nil); other = connected
                    try await WSProxyPeer.upgrade(connected, originPort: secondOrigin.port, absolute: true)
                    // Eviction happens when the second exchange begins its flow (maxFlows 1).
                    #expect(store.flow(flow.id) == nil && store.webSocketToken(flowID: flow.id) == nil)
                    #expect(store.webSocketSummary(token: token) == nil)
                    await take.release()
                    origin.barriers.release("next")
                    #expect(try await peer.receive(count: after.count) == after)
                    try await peer.send(bytes: reply)
                    try await peer.waitUntilClosed()
                    try await origin.waitUntilFinished()
                    #expect(origin.sent == before + after && origin.received == reply)
                    #expect(try await connected.receive(count: second.count) == second)
                    let fresh = try await waitForFlow(store) { $0.statusCode == 101 && $0.id != flow.id }
                    let freshToken = try #require(store.webSocketToken(flowID: fresh.id))
                    try await waitUntil("fresh session captured") { IT.rows(store, freshToken).first?.completedAt != nil }
                    #expect(IT.rows(store, freshToken).map { IT.payload(store, freshToken, $0) } == [Array("second".utf8)])
                    #expect(store.allFlows().map(\.id) == [fresh.id])
                    #expect(store.webSocketSummary(token: token) == nil) // the old session is never resurrected
                    try await connected.close(); other = nil; try await peer.close()
                } catch { await take.release(); origin.barriers.release("next"); try? await other?.close(); try? await peer.close(); throw error }
            }
            try await secondOrigin.stop()
        } catch { try? await secondOrigin.stop(); throw error }
    }

    /// Pause lands between the fragments of a compressed message in each direction. The
    /// paused messages are discarded, yet both directions' inflate history keeps advancing so the
    /// first post-Resume message (which back-references discarded text) decodes exactly.
    @Test func pauseResumeDuringCompressedFragmentedTrafficKeepsInflateContext() async throws {
        let server = try WebSocketDeflater(), client = try WebSocketDeflater()
        let m1 = WSWire.frame(1, Array(try server.message(Data("alpha alpha alpha".utf8))), rsv1: true)
        let m2 = Array(try server.message(Data("bravo bravo bravo alpha".utf8)))
        let m2a = WSWire.frame(1, Array(m2.prefix(m2.count / 2)), fin: false, rsv1: true)
        let m2b = WSWire.frame(0, Array(m2.dropFirst(m2.count / 2))) + WSWire.frame(9, [])
        let m3 = WSWire.frame(1, Array(try server.message(Data("charlie bravo bravo".utf8))), rsv1: true)
        let c2 = Array(try client.message(Data("delta delta delta".utf8)))
        let c2Frames = WSWire.client(1, Array(c2.prefix(c2.count / 2)), fin: false, rsv1: true)
            + WSWire.client(0, Array(c2.dropFirst(c2.count / 2))) + WSWire.client(9, [])
        let c3 = WSWire.client(1, Array(try client.message(Data("echo delta delta".utf8))), rsv1: true)
        let directory = IT.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let origin = try await WebSocketOrigin.start(tls: false, script: [
            .send(bytes: Data(m1 + m2a)), .barrier(name: "paused"), .send(bytes: Data(m2b)), .expect(bytes: Data(c2Frames)),
            .barrier(name: "resumed"), .send(bytes: Data(m3)), .expect(bytes: Data(c3)), .closeTransport],
            directory: directory, responseExtensions: "permessage-deflate")
        let store = observationStore()
        do {
            try await IT.withServer(store: store, originCA: nil) { proxy, _ in
                let peer = try await WSProxyPeer.connect(proxyPort: try #require(proxy.boundPort), originPort: origin.port, tls: nil)
                do {
                    try await WSProxyPeer.upgrade(peer, originPort: origin.port, absolute: true, extensions: "permessage-deflate")
                    var received = try await peer.receive(count: m1.count + m2a.count)
                    let (_, token) = try await IT.session(store)
                    try await waitUntil("m1 complete and m2 provisional") {
                        let rows = IT.rows(store, token)
                        return rows.count == 2 && rows[0].completedAt != nil && rows[1].completedAt == nil
                    }
                    proxy.updateConfiguration { $0.recordingEnabled = false }
                    origin.barriers.release("paused")
                    received += try await peer.receive(count: m2b.count)
                    try await peer.send(bytes: c2Frames)
                    try await origin.barriers.waitFor("resumed")
                    // Both paused pings (new headers) were really consumed by the worker before Resume.
                    try await waitUntil("paused input consumed") {
                        guard let summary = store.webSocketSummary(token: token) else { return false }
                        return summary.serverToClient.droppedEvents == 1 && summary.clientToServer.droppedEvents == 2
                    }
                    proxy.updateConfiguration { $0.recordingEnabled = true }
                    origin.barriers.release("resumed")
                    received += try await peer.receive(count: m3.count)
                    try await peer.send(bytes: c3)
                    try await peer.waitUntilClosed()
                    try await origin.waitUntilFinished()
                    #expect(received == origin.sent && origin.sent == m1 + m2a + m2b + m3)
                    #expect(origin.received == c2Frames + c3)
                    try await waitUntil("post-resume rows") { IT.rows(store, token).filter { $0.completedAt != nil }.count >= 3 }
                    let rows = IT.rows(store, token)
                    let server = rows.filter { $0.direction == .serverToClient }, client = rows.filter { $0.direction == .clientToServer }
                    try #require(server.count == 3 && client.count == 1)
                    #expect(IT.payload(store, token, server[0]) == Array("alpha alpha alpha".utf8))
                    #expect(IT.payload(store, token, server[1]) == nil) // paused prefix is unavailable, never empty
                    #expect(server[1].integrity == .partialPaused && server[1].isCaptureTerminal)
                    #expect(IT.payload(store, token, server[2]) == Array("charlie bravo bravo".utf8))
                    #expect(IT.payload(store, token, client[0]) == Array("echo delta delta".utf8))
                    #expect(server[2].compressed && client[0].compressed && client[0].utf8 == .valid)
                    let summary = try #require(store.webSocketSummary(token: token))
                    #expect(summary.pausedIntervals.totalCount == 1)
                    try await peer.close()
                } catch { origin.barriers.release("paused"); origin.barriers.release("resumed"); try? await peer.close(); throw error }
            }
            IT.expectObserverReservationsReleased(store)
            try await origin.stop()
        } catch { try? await origin.stop(); throw error }
    }
}

// MARK: - Limits through real loopback with a monotonic fake clock

extension WebSocketLoadTests {
    @Test(arguments: ["emptyFrames", "metadata", "native"])
    func limitStopsCaptureWhileRawRelayCompletes(kind: String) async throws {
        var limits = WebSocketLimits()
        var server: [UInt8], extensions: String?
        switch kind {
        case "emptyFrames":
            limits.sessionFramesPerSecond = 64 // frozen clock: the burst never refills
            server = (0..<300).flatMap { _ in WSWire.frame(9, []) }
        case "metadata":
            limits.metadataBytes = 140_000 // admits the session, refuses the 132,096-byte parser staging reserve
            server = WSWire.frame(1, Array("hello".utf8))
        default:
            limits.nativeBytes = 4_096 // smaller than zlib's inflate state + window
            server = WSWire.frame(1, Array(WebSocketCompressionVectors.sync), rsv1: true); extensions = "permessage-deflate"
        }
        let clientBytes = WSWire.client(1, Array("client".utf8))
        let peak = ManagedAtomic(0)
        try await Self.with(origin: [.send(bytes: Data(server)), .expect(bytes: Data(clientBytes)), .closeTransport],
                            extensions: extensions, limits: limits) { origin, proxy in
            let store = proxy.store
            let peer = try await WSProxyPeer.connect(proxyPort: proxy.port, originPort: origin.port, tls: nil)
            do {
                try await WSProxyPeer.upgrade(peer, originPort: origin.port, absolute: true, extensions: extensions)
                #expect(try await peer.receive(count: server.count) == server)
                try await peer.send(bytes: clientBytes)
                try await peer.waitUntilClosed()
                try await origin.waitUntilFinished()
                #expect(origin.received == clientBytes && origin.sent == server)
                let (_, token) = try await IT.session(store)
                try await waitUntil("both ends") {
                    peak.store(max(peak.load(ordering: .relaxed), store.webSocketBudget.usedBytes(category: .metadata)), ordering: .relaxed)
                    return store.webSocketSummary(token: token)?.lifecycle == .transportEndedWithoutClose
                }
                let summary = try #require(store.webSocketSummary(token: token))
                let rows = IT.rows(store, token)
                print("WS_LOAD_LIMIT kind=\(kind) rows=\(rows.count) s2c=\(String(describing: summary.serverToClient.diagnostic?.code)) c2s=\(String(describing: summary.clientToServer.diagnostic?.code)) metadataPeakSample=\(peak.load(ordering: .relaxed)) nativeCap=\(limits.nativeBytes)")
                #expect(summary.lowerBound)
                #expect(summary.serverToClient.wireBytes == UInt64(server.count) && summary.clientToServer.wireBytes == UInt64(clientBytes.count))
                switch kind {
                case "emptyFrames":
                    #expect(rows.count == 65 && rows.filter { $0.completedAt != nil }.count == 64)
                    #expect(rows.last?.captureAbandoned == true && rows.allSatisfy { $0.kind == .ping })
                case "metadata":
                    #expect(rows.isEmpty)
                    #expect(summary.serverToClient.diagnostic?.code == "observationWorkingMemory")
                    #expect(peak.load(ordering: .relaxed) <= limits.metadataBytes)
                default:
                    #expect(rows.isEmpty)
                    #expect(summary.serverToClient.diagnostic?.code == "inflateInitialization")
                    #expect(summary.clientToServer.diagnostic?.code == "inflateInitialization")
                }
                try await peer.close()
            } catch { try? await peer.close(); throw error }
            for category in WebSocketMemoryCategory.allCases {
                #expect(store.webSocketBudget.usedBytes(category: category) <= WebSocketLoadTests.cap(category, limits))
            }
        }
    }
    static func cap(_ category: WebSocketMemoryCategory, _ limits: WebSocketLimits) -> Int {
        switch category {
        case .retained: limits.retainedBytes
        case .working: limits.workingBytes
        case .mailbox: limits.mailboxBytes
        case .native: limits.nativeBytes
        case .metadata: limits.metadataBytes
        }
    }
}

// MARK: - Observer off/on replay

extension WebSocketLoadTests {
    static func replayFrames() -> (server: [[UInt8]], client: [UInt8], serverApplication: Int, clientApplication: Int) {
        var server: [[UInt8]] = [], client: [UInt8] = [], serverApplication = 0, clientApplication = 0
        for index in 0..<200 {
            let size = (index * 977) % 16_384
            let payload = index % 3 == 0 ? Array(String(repeating: "t", count: size).utf8) : Self.binary(index, count: size)
            server.append(WSWire.frame(index % 3 == 0 ? 1 : 2, payload)); serverApplication += size
            client += WSWire.client(index % 3 == 0 ? 1 : 2, payload); clientApplication += size
        }
        return (server, client, serverApplication, clientApplication)
    }
    struct Sample { let observe: Bool; let wall: Duration; let cpuMicros: Int64; let bytes: Int }
    static func cpuMicros() -> Int64 {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Int64(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1_000_000 + Int64(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec)
    }

    /// Identical scripted replay with observation off (production `webSockets == nil`) and on.
    /// Forwarded bytes and closure are compared exactly; time/CPU are reported, not thresholded.
    @Test func identicalReplayObserverOffAndOnPreservesBytesAndReportsCost() async throws {
        let replay = Self.replayFrames()
        let serverBytes = replay.server.flatMap { $0 }
        var limits = WebSocketLimits(); limits.sessionMailboxBytes = 8_388_608 // measure full capture, not a refusal shortcut
        var samples: [Sample] = []
        for round in 0..<6 {
            let observe = round % 2 == 1
            let script = replay.server.map { WebSocketOriginStep.send(bytes: Data($0)) } + [.expect(bytes: Data(replay.client)), .closeTransport]
            try await Self.with(origin: script, observe: observe, limits: limits) { origin, proxy in
                let peer = try await WSProxyPeer.connect(proxyPort: proxy.port, originPort: origin.port, tls: nil)
                do {
                    try await WSProxyPeer.upgrade(peer, originPort: origin.port, absolute: true)
                    let clock = ContinuousClock(), start = clock.now, cpu = Self.cpuMicros()
                    try await peer.send(bytes: replay.client)
                    let received = try await peer.receive(count: serverBytes.count, timeout: .seconds(60))
                    try await peer.waitUntilClosed()
                    try await origin.waitUntilFinished()
                    samples.append(.init(observe: observe, wall: clock.now - start, cpuMicros: Self.cpuMicros() - cpu, bytes: serverBytes.count + replay.client.count))
                    #expect(received == serverBytes && origin.sent == serverBytes && origin.received == replay.client)
                    #expect(peer.remainingBytes().isEmpty && origin.transcript.closed && !peer.isActive)
                    let flow = try await waitForFlow(proxy.store) { $0.statusCode == 101 }
                    #expect(flow.bytesSent == 0 && flow.bytesReceived == 0)
                    if observe {
                        let token = try #require(proxy.store.webSocketToken(flowID: flow.id))
                        try await waitUntil(timeout: .seconds(20), "replay fully observed") {
                            proxy.store.webSocketSummary(token: token)?.lifecycle == .transportEndedWithoutClose
                        }
                        let summary = try #require(proxy.store.webSocketSummary(token: token))
                        #expect(summary.serverToClient.applicationBytes == UInt64(replay.serverApplication))
                        #expect(summary.clientToServer.applicationBytes == UInt64(replay.clientApplication))
                        #expect(!summary.lowerBound && summary.serverToClient.droppedEvents == 0 && summary.clientToServer.droppedEvents == 0)
                    } else {
                        #expect(proxy.store.webSocketToken(flowID: flow.id) == nil)
                        for category in WebSocketMemoryCategory.allCases { #expect(proxy.store.webSocketBudget.usedBytes(category: category) == 0) }
                    }
                    try await peer.close()
                } catch { try? await peer.close(); throw error }
            }
        }
        for observe in [false, true] {
            let chosen = samples.filter { $0.observe == observe }
            let walls = chosen.map { Double($0.wall.components.attoseconds) / 1e15 + Double($0.wall.components.seconds) * 1000 }.sorted()
            let cpus = chosen.map { Double($0.cpuMicros) / 1000 }.sorted()
            print("WS_LOAD_COMPARE observer=\(observe ? "on" : "off") samples=\(chosen.count) bytesPerSample=\(chosen.first?.bytes ?? 0) wallMsMedian=\(walls[walls.count / 2]) wallMs=\(walls) processCpuMs=\(cpus) os=\(ProcessInfo.processInfo.operatingSystemVersionString) cores=\(ProcessInfo.processInfo.activeProcessorCount)")
        }
    }

    /// Deterministic EmbeddedChannel replay of the actual Glue pair: forwarded bytes, flush
    /// count, autoRead writes and close count are identical with and without an observer, across
    /// compressed traffic and repeated writability toggles.
    @Test func embeddedGlueReplayTraceIsIdenticalWithObserverOffAndOn() async throws {
        struct Trace: Equatable { let a: [UInt8]; let b: [UInt8]; let flushA: Int; let flushB: Int; let closeA: Int; let closeB: Int; let autoA: [Bool]; let autoB: [Bool] }
        let store = observationStore(), progress = WSProgress()
        let owner = WebSocketCaptureCoordinator(store: store, hooks: .init(afterChunk: { await progress.advance() }))
        var heads = observationHeads()
        heads.0.headers.add(name: "Sec-WebSocket-Extensions", value: "permessage-deflate")
        heads.1.headers.add(name: "Sec-WebSocket-Extensions", value: "permessage-deflate")
        let id = observationFlow(store)
        let handle = try #require(owner.begin(flowID: id, request: heads.0, response: heads.1, eventLoop: MultiThreadedEventLoopGroup.singleton.next()))
        let deflater = try WebSocketDeflater()
        var clientReads: [[UInt8]] = [], serverReads: [[UInt8]] = []
        for index in 0..<60 {
            clientReads.append(WSWire.client(2, Self.binary(index, count: index * 97)))
            let text = String(repeating: "replay \(index % 7) ", count: 20)
            serverReads.append(WSWire.frame(1, Array(try deflater.message(Data(text.utf8))), rsv1: true))
        }
        func trace(_ handle: ObservationHandle?) throws -> Trace {
            let loop = EmbeddedEventLoop(), left = WSWireTrace(), right = WSWireTrace()
            let (a, b) = GlueHandler.makePair()
            a.onObservedRead = { handle?.offer($0, direction: .clientToServer) }
            b.onObservedRead = { handle?.offer($0, direction: .serverToClient) }
            a.onClose = { handle?.transportEnded(direction: .clientToServer) }
            b.onClose = { handle?.transportEnded(direction: .serverToClient) }
            let client = EmbeddedChannel(handlers: [left, a], loop: loop), origin = EmbeddedChannel(handlers: [right, b], loop: loop)
            try client.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 12345)).wait()
            try origin.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 12346)).wait()
            var automaticA: [Bool] = [], automaticB: [Bool] = []
            for index in 0..<60 {
                try client.writeInbound(ByteBuffer(bytes: clientReads[index]))
                try origin.writeInbound(ByteBuffer(bytes: serverReads[index]))
                if index % 10 == 9 {
                    let writable = index % 20 == 19
                    client.isWritable = writable; origin.isWritable = writable
                    client.pipeline.fireChannelWritabilityChanged(); origin.pipeline.fireChannelWritabilityChanged()
                    // Embedded getOption(autoRead) hardcodes true; its options list keeps actual setOption writes.
                    automaticA.append(try #require(client.options.last { $0.option is ChannelOptions.Types.AutoReadOption }?.value as? Bool))
                    automaticB.append(try #require(origin.options.last { $0.option is ChannelOptions.Types.AutoReadOption }?.value as? Bool))
                }
            }
            _ = try? client.finish(); _ = try? origin.finish(); loop.run()
            return Trace(a: left.bytes, b: right.bytes, flushA: left.flushes, flushB: right.flushes, closeA: left.closes,
                         closeB: right.closes, autoA: automaticA, autoB: automaticB)
        }
        let baseline = try trace(nil), observed = try trace(handle)
        #expect(observed == baseline)
        #expect(observed.a == serverReads.flatMap { $0 } && observed.b == clientReads.flatMap { $0 })
        #expect(observed.flushA == 60 && observed.flushB == 60 && observed.autoA == [false, true, false, true, false, true])
        try await progress.wait(120, timeout: .seconds(20))
        let token = try #require(store.webSocketToken(flowID: id))
        let rows = IT.rows(store, token)
        #expect(rows.count == 120 && rows.allSatisfy { $0.completedAt != nil && $0.integrity == .transportComplete })
        #expect(rows.filter { $0.direction == .serverToClient }.allSatisfy { $0.compressed && $0.utf8 == .valid })
        print("WS_GLUE_REPLAY reads=120 bytesA=\(observed.a.count) bytesB=\(observed.b.count) flushA=\(observed.flushA) flushB=\(observed.flushB) closeA=\(observed.closeA) closeB=\(observed.closeB) autoA=\(observed.autoA) equal=true rows=\(rows.count)")
        await owner.shutdown()
        IT.expectObserverReservationsReleased(store)
    }
}

