import FlowStore
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing
import os
@testable import AppCore
@testable import ProxyCore
@testable import RulesEngine

/// The P1 traffic tools together, end to end on real sockets: Allow/Block lists, No Caching, network
/// conditions and repeat runs through the same server the app uses. Origins are loopback fixtures
/// whose counters record what really arrived; every wait is a barrier or `waitUntil` on a real
/// counter, never a fixed delay.
@Suite(.productionChinese, .serialized, .timeLimit(.minutes(3))) struct TrafficToolsEndToEndTests {
    // MARK: Policies

    /// Every tool present in some form yet doing nothing: lists that are off or whose entries are
    /// off, no-caching off, and a conditions switch that is off over a global and a host rule that
    /// would otherwise slow or cut every request.
    private static func inertPolicy() -> TrafficPolicy {
        var policy = TrafficPolicy()
        policy.allowEnabled = false
        policy.allowEntries = [TrafficFilterEntry(matcher: RuleMatcher(hostPattern: "only.test"))]
        policy.blockEnabled = true
        policy.blockEntries = [TrafficFilterEntry(enabled: false, matcher: RuleMatcher(hostPattern: "127.0.0.1"))]
        policy.noCaching = false
        policy.conditions.enabled = false
        policy.conditions.global = .preset(.edge)
        policy.conditions.hostRules = [HostNetworkRule(hostPattern: "127.0.0.1", selection: .preset(.offline))]
        return policy
    }

    private static func block(_ matcher: RuleMatcher) -> TrafficFilterEntry { TrafficFilterEntry(matcher: matcher) }

    // MARK: 1. Everything off is byte-identical to no provider

    /// One scripted session: what the client received and what the origin received, with the origin's
    /// port and any `Date` line normalised away.
    private struct Transcript: Equatable {
        var client: [String] = []
        var origin: [String] = []
    }

    private static func normalised(_ bytes: [UInt8], port: Int) -> String {
        String(decoding: bytes, as: UTF8.self)
            .replacingOccurrences(of: "\(port)", with: "PORT")
            .components(separatedBy: "\r\n").filter { !$0.lowercased().hasPrefix("date:") }.joined(separator: "\r\n")
    }

    private static func session(traffic: TrafficPolicyProvider?) async throws -> Transcript {
        let origin = try await RawOrigin.start()
        var transcript = Transcript()
        do {
            try await RulesComposeServer.run(traffic: traffic) { fx in
                let p = origin.port
                let proxyPort = try fx.port
                let requests = [
                    "GET http://127.0.0.1:\(p)/plain HTTP/1.1\r\nHost: 127.0.0.1:\(p)\r\nConnection: close\r\n\r\n",
                    "GET http://127.0.0.1:\(p)/cond HTTP/1.1\r\nHost: 127.0.0.1:\(p)\r\nIf-None-Match: \"v1\"\r\n"
                        + "If-Modified-Since: Tue, 20 Oct 2026 00:00:00 GMT\r\nCache-Control: max-age=60\r\nX-Keep: yes\r\n"
                        + "Connection: close\r\n\r\n",
                    "POST http://127.0.0.1:\(p)/post HTTP/1.1\r\nHost: 127.0.0.1:\(p)\r\nContent-Type: text/plain\r\n"
                        + "Content-Length: 11\r\nConnection: close\r\n\r\nhello-world",
                ]
                for request in requests {
                    let client = try await RawClient.connect(port: proxyPort)
                    do {
                        try await client.send(request)
                        try await client.waitUntilClosed()
                        transcript.client.append(Self.normalised(client.remainingBytes(), port: p))
                        try await client.close()
                    } catch { try? await client.close(); throw error }
                }
                // A CONNECT to the plain-text origin: the established line, then a request relayed raw.
                let tunnel = try await RawClient.connect(port: proxyPort)
                do {
                    try await tunnel.send("CONNECT 127.0.0.1:\(p) HTTP/1.1\r\nHost: 127.0.0.1:\(p)\r\n\r\n")
                    let established = try await tunnel.receive(until: "\r\n\r\n")
                    try await tunnel.send("GET /tunnelled HTTP/1.1\r\nHost: 127.0.0.1:\(p)\r\nIf-None-Match: \"v1\"\r\n\r\n")
                    let reply = try await tunnel.receive(until: "origin-ok")
                    try await tunnel.close()
                    transcript.client.append(Self.normalised(Array((established + reply).utf8), port: p))
                } catch { try? await tunnel.close(); throw error }
                try await waitUntil("the tunnelled request reached the origin") { origin.requests.count == 4 }
            }
            transcript.origin = origin.requests.map { Self.normalised($0, port: origin.port) }
            try await origin.stop()
        } catch { try? await origin.stop(); throw error }
        return transcript
    }

    @Test func allToolsOffAreByteIdenticalToNoProvider() async throws {
        let without = try await Self.session(traffic: nil)
        let empty = try await Self.session(traffic: TrafficPolicyProvider())
        let inert = try await Self.session(traffic: TrafficPolicyProvider(Self.inertPolicy()))
        #expect(without.client.count == 4 && without.origin.count == 4)
        #expect(without.client.allSatisfy { $0.hasPrefix("HTTP/1.1 200") })
        // The validators the tool exists to remove are really on the wire when it is off.
        #expect(without.origin[1].contains("If-None-Match: \"v1\"\r\n"))
        #expect(without.origin[1].contains("Cache-Control: max-age=60\r\n"))
        #expect(without.origin[2].hasSuffix("\r\n\r\nhello-world"))
        #expect(without.origin[3].contains("If-None-Match: \"v1\"\r\n"))
        #expect(empty == without)
        #expect(inert == without)
    }

    // MARK: 2. Block + No Caching + Conditions, through Compose

    @Test func blockPlusNoCachingPlusConditionsCompose() async throws {
        var policy = TrafficPolicy()
        let blocked = Self.block(RuleMatcher(hostPattern: "localhost"))
        policy.blockEnabled = true
        policy.blockEntries = [blocked]
        policy.noCaching = true
        policy.conditions.enabled = true
        policy.conditions.hostRules = [HostNetworkRule(hostPattern: "127.0.0.1", selection: .preset(.edge))]
        try await ComposeFixture.run(traffic: TrafficPolicyProvider(policy)) { fx in
            let origin = fx.origin
            let conditional = [HeaderField(name: "If-None-Match", value: "\"v1\""),
                               HeaderField(name: "If-Modified-Since", value: "Tue, 20 Oct 2026 00:00:00 GMT"),
                               HeaderField(name: "X-Keep", value: "yes")]
            let refusedURL = try #require(URL(string: "http://localhost:\(origin.port)/hello"))
            let refused = ComposeRequest(method: "GET", url: refusedURL, headers: conditional)
            let refusedResult = await fx.compose.send(refused)
            #expect(refusedResult.delivery == .notSent)
            #expect(origin.state.withLock { $0.connections } == 0)
            let refusedFlowID = try #require(refusedResult.flowID)
            let refusedFlow = try await waitForFlow(fx.store) { $0.id == refusedFlowID && $0.state != .inProgress }
            if case .failed = refusedFlow.state {} else { Issue.record("expected a failed flow, got \(refusedFlow.state)") }
            #expect(refusedFlow.provenance.tools.blockedByEntry == blocked.id)
            #expect(refusedFlow.provenance.isCompose)
            #expect(!refusedFlow.provenance.tools.noCaching)
            #expect(refusedFlow.provenance.tools.networkCondition == nil)
            try await fx.expectReleased(refused.id)

            let sent = ComposeRequest(method: "GET", url: fx.url("/hello"), headers: conditional)
            let sentResult = await fx.compose.send(sent)
            #expect(sentResult.failure == nil)
            #expect(sentResult.response?.status == 200)
            #expect(sentResult.response?.body == Data("hello".utf8))
            #expect(origin.state.withLock { $0.heads.count } == 1)
            let seen = try #require(origin.state.withLock { $0.heads.last })
            #expect(seen.headers["if-none-match"].isEmpty)
            #expect(seen.headers["if-modified-since"].isEmpty)
            #expect(seen.headers["cache-control"] == ["no-cache"])
            #expect(seen.headers["x-keep"] == ["yes"])
            let flowID = try #require(sentResult.flowID)
            let flow = try await waitForFlow(fx.store) { $0.id == flowID && $0.state == .completed }
            #expect(flow.provenance.tools.noCaching)
            #expect(flow.provenance.tools.networkCondition == "preset.edge")
            #expect(flow.provenance.tools.blockedByEntry == nil)
            #expect(flow.provenance.isCompose)
            try await fx.expectReleased(sent.id)
        }
    }

    // MARK: 3. Block and No Caching under HTTP/2 MITM

    @Test(arguments: [true, false])
    func blockedAndUncachedWorkOverHTTP2MITM(upstreamH2: Bool) async throws {
        var policy = TrafficPolicy()
        // A path entry never matches the CONNECT, so the tunnel is opened and decrypted first.
        let blocked = Self.block(RuleMatcher(path: .prefix("/blocked")))
        policy.blockEnabled = true
        policy.blockEntries = [blocked]
        policy.noCaching = true
        let origin = try await HTTP2TestOrigin.start(protocols: upstreamH2 ? ["h2"] : ["http/1.1"])
        do {
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true, traffic: TrafficPolicyProvider(policy)) { fixture, client in
                let host = HTTPHeaders([("host", "localhost:\(origin.port)")])
                let refused = try await client.request(headers: host, path: "/blocked/x")
                #expect(refused.status == 403)
                #expect(origin.counts.requests == 0 && origin.counts.paths.isEmpty)
                var conditional = host
                conditional.add(name: "if-none-match", value: "\"v1\"")
                conditional.add(name: "if-modified-since", value: "Tue, 20 Oct 2026 00:00:00 GMT")
                conditional.add(name: "x-keep", value: "yes")
                let reply = try await client.request(headers: conditional, path: "/ok")
                #expect(reply.status == 200)
                #expect(reply.headers["cache-control"] == ["no-cache, no-store"])
                #expect(origin.counts.paths == ["/ok"])
                let seen = try #require(origin.counts.requestHeaders.first)
                #expect(seen["if-none-match"].isEmpty)
                #expect(seen["if-modified-since"].isEmpty)
                #expect(seen["cache-control"] == ["no-cache"])
                #expect(seen["pragma"] == ["no-cache"])
                #expect(seen["x-keep"] == ["yes"])
                let refusedFlow = try await waitForFlow(fixture.store) { $0.path == "/blocked/x" && $0.state != .inProgress }
                if case .failed = refusedFlow.state {} else { Issue.record("expected a failed flow, got \(refusedFlow.state)") }
                #expect(refusedFlow.provenance.tools.blockedByEntry == blocked.id)
                let flow = try await waitForFlow(fixture.store) { $0.path == "/ok" && $0.state == .completed }
                #expect(flow.provenance.tools.noCaching)
                #expect(flow.transport.upstreamRequest == (upstreamH2 ? .http2 : .http1_1))
                try await RulesComposeBarriers.expectIdle(fixture)
            }
            try await origin.stop()
        } catch { try? await origin.stop(); throw error }
    }

    // MARK: 4. Repeat runs through Compose

    @Test func repeatThroughComposeRecordsTaggedFlows() async throws {
        try await ComposeFixture.run { fx in
            let client = ServiceComposeClient(service: fx.compose)
            var options = RepeatOptions()
            options.count = 12
            options.concurrency = 4
            let hello = ComposeDraft(method: "GET", url: fx.url("/hello").absoluteString)
            let run = await MainActor.run { RepeatRunModel(draft: hello, client: client, options: options) }
            let runID = await run.runID
            await run.start()
            #expect(await run.phase == .finished)
            #expect(await run.progress == RepeatProgress(total: 12, started: 12, succeeded: 12, failed: 0, cancelled: 0))
            #expect(await run.failures.isEmpty)
            let flowIDs = await run.flowIDs
            #expect(flowIDs.count == 12)
            try await waitUntil("12 tagged flows completed") {
                fx.store.allFlows().filter { $0.provenance.tools.repeatRun?.runID == runID && $0.state == .completed }.count == 12
            }
            let flows = fx.store.allFlows().filter { $0.provenance.tools.repeatRun?.runID == runID }
            #expect(flows.count == 12)
            #expect(flows.allSatisfy { $0.provenance.tools.repeatRun?.total == 12 && $0.provenance.isCompose })
            #expect(Set(flows.compactMap { $0.provenance.tools.repeatRun?.index }) == Set(1...12))
            #expect(Set(flows.map(\.id)) == Set(flowIDs))
            #expect(fx.origin.state.withLock { $0.requests["/hello"] } == 12)
            fx.expectIdle()

            // A cancelled run: two sends are held at the origin, the cancel stops the rest.
            var long = RepeatOptions()
            long.count = 1000
            long.concurrency = 2
            let hold = ComposeDraft(method: "GET", url: fx.url("/hold").absoluteString)
            let cancelled = await MainActor.run { RepeatRunModel(draft: hold, client: client, options: long) }
            let cancelledID = await cancelled.runID
            let running = Task { await cancelled.start() }
            try await waitUntil("both lanes held at the origin") { fx.origin.state.withLock { $0.concurrent } == 2 }
            #expect(await cancelled.phase == .running)
            await cancelled.cancel()
            await running.value
            let progress = await cancelled.progress
            #expect(await cancelled.phase == .cancelled)
            #expect(progress.total == 1000)
            #expect(progress.started == 2)
            #expect(progress.cancelled == 2 && progress.finished == progress.started)
            #expect(progress.failed == 0)
            fx.expectIdle()
            let ofCancelled = fx.store.allFlows().filter { $0.provenance.tools.repeatRun?.runID == cancelledID }
            #expect(ofCancelled.count == 2)
            #expect(Set(ofCancelled.compactMap { $0.provenance.tools.repeatRun?.index }) == [1, 2])
            #expect(fx.origin.state.withLock { $0.requests["/hold"] } == 2)
            // Nothing else was ever started for the first run or for any other tag.
            #expect(fx.store.allFlows().count == 14)
        }
    }

    // MARK: 5. WebSocket upgrade with the pacer installed

    @Test func webSocketUpgradeStillRelaysWithPacerInstalled() async throws {
        var policy = TrafficPolicy()
        policy.conditions.enabled = true
        policy.conditions.global = .custom(NetworkProfile(downloadKbps: 8_000, uploadKbps: 8_000, latencyMs: 0, lossPercent: 0))
        let origin = try await TestOriginServer.start()
        do {
            try await RulesComposeServer.run(traffic: TrafficPolicyProvider(policy)) { fx in
                let client = try await RawClient.connect(port: try fx.port)
                do {
                    let p = origin.port
                    try await client.send("GET http://127.0.0.1:\(p)/ws HTTP/1.1\r\nHost: 127.0.0.1:\(p)\r\n"
                        + "Upgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
                    let head = try await client.receive(until: "\r\n\r\n")
                    #expect(head.hasPrefix("HTTP/1.1 101"), "\(head)")
                    // Sent by the origin in the same segment as the 101.
                    #expect(try await client.receive(until: TestOriginServer.wsGreeting) == TestOriginServer.wsGreeting)
                    for message in ["ping", "second-round-trip"] {
                        try await client.send(message)
                        #expect(try await client.receive(until: message) == message)
                    }
                    try await client.close()
                } catch { try? await client.close(); throw error }
                let flow = try await waitForFlow(fx.store) { $0.path == "/ws" && $0.state == .completed }
                #expect(flow.statusCode == 101)
                #expect(flow.provenance.tools.networkCondition == "custom")
            }
            try await origin.stop()
        } catch { try? await origin.stop(); throw error }
    }

    // MARK: 5b. Offline blocks reuse of an idle pooled connection (D11)

    /// Map Remote sends `mapped.test` to a loopback origin; its connection stays idle in the client's
    /// pool. Once that target is offline the next request must fail locally instead of reusing it.
    @Test func offlineTargetIsNotReachedThroughAnIdlePooledConnection() async throws {
        let origin = try await RawOrigin.start()
        do {
            var policy = TrafficPolicy()
            policy.conditions.enabled = true
            let traffic = TrafficPolicyProvider(policy)
            let remote = TestRules.mapRemote(host: "127.0.0.1", port: origin.port, matcher: RuleMatcher(hostPattern: "mapped.test"))
            try await RulesComposeServer.run(rules: TestRules.provider([remote]), traffic: traffic) { fx in
                let client = try await RawClient.connect(port: try fx.port)
                do {
                    let request = "GET http://mapped.test/one HTTP/1.1\r\nHost: mapped.test\r\n\r\n"
                    try await client.send(request)
                    _ = try await client.receive(until: "origin-ok")
                    #expect(origin.requests.count == 1)

                    policy.conditions.hostRules = [HostNetworkRule(hostPattern: "127.0.0.1", port: origin.port, selection: .preset(.offline))]
                    traffic.publish(policy)
                    try await client.send(request)
                    let failure = try await client.receive(until: "模拟断网")
                    #expect(failure.hasPrefix("HTTP/1.1 502"), "\(failure)")
                    try await client.close()
                } catch { try? await client.close(); throw error }
                #expect(origin.requests.count == 1, "the offline target received nothing more")
            }
            try await origin.stop()
        } catch { try? await origin.stop(); throw error }
    }

    // MARK: 6. Everything returns to zero

    @Test func resourcesReturnToZeroAfterEverything() async throws {
        var policy = TrafficPolicy()
        policy.blockEnabled = true
        policy.blockEntries = [Self.block(RuleMatcher(path: .prefix("/blocked")))]
        policy.noCaching = true
        policy.conditions.enabled = true
        policy.conditions.global = .custom(NetworkProfile(downloadKbps: 8_000, uploadKbps: 8_000, latencyMs: 0, lossPercent: 0))
        let traffic = TrafficPolicyProvider(policy)

        // Client connections: pending quota, live exchanges, upstream pool and pins after forwarded and blocked traffic.
        try await withOrigins(h2: false) { origin, _ in
            try await withLeg(h2: false, origin: origin, traffic: traffic) { leg in
                let ok = try await leg.send(path: "/ok", headers: [("If-None-Match", "\"v1\"")])
                #expect(ok.status == 200)
                let refused = try await leg.send(path: "/blocked/y")
                #expect(refused.status == 403)
                #expect(origin.counts.paths == ["/ok"])
                _ = try await waitForFlow(leg.fixture.store) { $0.path == "/ok" && $0.state == .completed }
                _ = try await waitForFlow(leg.fixture.store) { $0.path == "/blocked/y" && $0.state != .inProgress }
                try await RulesComposeBarriers.expectIdle(leg.fixture)
            }
        }

        // Compose: slots, queue, pending bytes, sockets and leases after a forwarded and a blocked send.
        try await ComposeFixture.run(traffic: traffic) { fx in
            let sent = ComposeRequest(method: "GET", url: fx.url("/hello"))
            let refused = ComposeRequest(method: "GET", url: fx.url("/blocked/z"))
            #expect(await fx.compose.send(sent).response?.status == 200)
            let blocked = await fx.compose.send(refused)
            #expect(blocked.delivery == .notSent)
            try await fx.expectReleased(sent.id)
            try await fx.expectReleased(refused.id)
            fx.expectIdle()
            #expect(fx.origin.state.withLock { $0.requests } == ["/hello": 1])
        }
    }
}

// MARK: - Fixtures

/// A Compose facade directly over the server's `ComposeService` (the same conversion the app bridge
/// makes), so a repeat run exercises the real send path.
private final class ServiceComposeClient: ComposeClient {
    private let service: ComposeService

    init(service: ComposeService) { self.service = service }

    func send(_ request: ComposeOutgoingRequest) async -> ComposeOutcome {
        guard let url = URL(string: request.url, encodingInvalidCharacters: false) else {
            return ComposeOutcome(flowID: nil, failure: ComposeOutcomeFailure(code: "invalid.url", message: "invalid URL"), delivery: .notSent)
        }
        let result = await service.send(ComposeRequest(
            id: request.id, method: request.method, url: url, headers: request.headers,
            body: request.body.isEmpty ? .none : .bytes(request.body), sourceFlowID: request.sourceFlowID,
            policy: ComposePolicy(applyRules: request.applyRules, timeout: .seconds(request.timeoutSeconds),
                                  httpVersion: request.http1Only ? .http1Only : .automatic),
            repeatTag: request.repeatTag))
        return ComposeOutcome(flowID: result.flowID,
                              response: result.response.map { ComposeResponseSnapshot(
                                  status: $0.status, reason: $0.reason, headers: $0.headers, body: $0.body, bodyBytes: $0.bodyBytes,
                                  truncated: $0.truncated, trailers: $0.trailers) },
                              failure: result.failure.map {
                                  ComposeOutcomeFailure(code: $0.code, message: $0.message,
                                                        isCancellation: $0.code == ComposeFailureCode.cancelled.rawValue)
                              },
                              delivery: result.delivery == .answered ? .answered : (result.delivery == .unknown ? .unknown : .notSent))
    }

    func cancel(_ id: UUID) { service.cancel(id) }
}

/// A loopback HTTP/1.1 origin that keeps the exact bytes of every request (head and body) and
/// answers each with the same fixed response, so two runs can be compared byte for byte.
private final class RawOrigin: Sendable {
    let port: Int
    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel
    private let received: OSAllocatedUnfairLock<[[UInt8]]>

    private init(port: Int, group: MultiThreadedEventLoopGroup, channel: Channel, received: OSAllocatedUnfairLock<[[UInt8]]>) {
        self.port = port; self.group = group; self.channel = channel; self.received = received
    }

    var requests: [[UInt8]] { received.withLock { $0 } }

    static func start() async throws -> RawOrigin {
        let received = OSAllocatedUnfairLock<[[UInt8]]>(initialState: [])
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let channel = try await ServerBootstrap(group: group).childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(RawOriginHandler(received: received))
                }
            }.bind(host: "127.0.0.1", port: 0).get()
            return RawOrigin(port: try #require(channel.localAddress?.port), group: group, channel: channel, received: received)
        } catch { try? await group.shutdownGracefully(); throw error }
    }

    func stop() async throws {
        try? await channel.close().get()
        try await group.shutdownGracefully()
    }
}

private final class RawOriginHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private static let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 9\r\nETag: \"v1\"\r\n\r\norigin-ok"
    private let received: OSAllocatedUnfairLock<[[UInt8]]>
    private var pending: [UInt8] = []

    init(received: OSAllocatedUnfairLock<[[UInt8]]>) { self.received = received }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        pending += Array(unwrapInboundIn(data).readableBytesView)
        let separator = Array("\r\n\r\n".utf8)
        while true {
            let bytes = pending
            guard let end = bytes.indices.first(where: { bytes[$0...].starts(with: separator) }) else { return }
            let head = String(decoding: bytes[..<end], as: UTF8.self)
            let length = head.components(separatedBy: "\r\n").compactMap { line -> Int? in
                guard line.lowercased().hasPrefix("content-length:") else { return nil }
                return Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
            }.first ?? 0
            let total = end + separator.count + length
            guard pending.count >= total else { return }
            let request = Array(bytes[..<total])
            received.withLock { $0.append(request) }
            pending.removeFirst(total)
            context.writeAndFlush(wrapOutboundOut(ByteBuffer(string: Self.response)), promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
