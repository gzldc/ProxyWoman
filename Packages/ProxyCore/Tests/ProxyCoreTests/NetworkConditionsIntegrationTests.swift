import CertKit
import FlowStore
import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import os
import Testing
@testable import ProxyCore
@testable import RulesEngine

/// Network conditions through a real proxy: the download gate on upstream connections, the
/// upload gate on client connections, host rules, the offline preset and the off state. Timing
/// assertions are lower bounds only (the theoretical serialisation time, with headroom).
@Suite(.productionChinese, .serialized, .timeLimit(.minutes(2))) struct NetworkConditionsIntegrationTests {
    private static func provider(_ selection: NetworkSelection?, hostRules: [HostNetworkRule] = [],
                                 enabled: Bool = true) -> TrafficPolicyProvider {
        var policy = TrafficPolicy()
        policy.conditions.enabled = enabled
        policy.conditions.global = selection
        policy.conditions.hostRules = hostRules
        return TrafficPolicyProvider(policy)
    }

    private static func custom(downloadKbps: Int? = nil, uploadKbps: Int? = nil, latencyMs: Int = 0) -> NetworkSelection {
        .custom(NetworkProfile(downloadKbps: downloadKbps, uploadKbps: uploadKbps, latencyMs: latencyMs, lossPercent: 0))
    }

    private static func withOrigin(_ body: (TestOriginServer) async throws -> Void) async throws {
        let origin = try await TestOriginServer.start()
        do { try await body(origin) } catch { try? await origin.stop(); throw error }
        try await origin.stop()
    }

    @Test func downloadRateIsAtLeastTheTheoreticalTime() async throws {
        // 1000 kbps = 125_000 bytes/s: 100_000 body bytes take at least 0.8 s.
        try await ComposeFixture.run(traffic: Self.provider(Self.custom(downloadKbps: 1000))) { fx in
            let clock = ContinuousClock()
            let started = clock.now
            let request = ComposeRequest(method: "GET", url: fx.url("/big?bytes=100000"))
            let result = await fx.compose.send(request)
            let elapsed = clock.now - started
            #expect(result.failure == nil)
            let response = try #require(result.response)
            #expect(response.status == 200)
            #expect(!response.truncated)
            #expect(response.bodyBytes == 100_000)
            #expect(response.body == Data(repeating: 0x62, count: 100_000))
            #expect(elapsed >= .milliseconds(700), "\(elapsed)")
            let flowID = try #require(result.flowID)
            let flow = try await waitForFlow(fx.store) { $0.id == flowID && $0.state == .completed }
            #expect(flow.provenance.tools.networkCondition == "custom")
            try await fx.expectReleased(request.id)
        }
    }

    @Test func uploadRateThroughForwardProxy() async throws {
        // 400 kbps = 50_000 bytes/s: a 50_000-byte body takes about 1 s to go up.
        try await Self.withOrigin { origin in
            try await RulesComposeServer.run(traffic: Self.provider(Self.custom(uploadKbps: 400))) { fx in
                let body = (0..<50_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }
                let client = try await RawClient.connect(port: try fx.port)
                do {
                    let head = "POST http://127.0.0.1:\(origin.port)/echo HTTP/1.1\r\nHost: 127.0.0.1:\(origin.port)\r\n"
                        + "Content-Type: application/octet-stream\r\nContent-Length: \(body.count)\r\n\r\n"
                    let clock = ContinuousClock()
                    let started = clock.now
                    try await client.send(bytes: Array(head.utf8) + body)
                    let responseHead = try await client.receive(until: "\r\n\r\n", timeout: .seconds(20))
                    let echoed = try await client.receive(count: body.count, timeout: .seconds(20))
                    let elapsed = clock.now - started
                    try await client.close()
                    #expect(responseHead.hasPrefix("HTTP/1.1 200"), "\(responseHead)")
                    #expect(echoed == body)
                    #expect(elapsed >= .milliseconds(900), "\(elapsed)")
                } catch { try? await client.close(); throw error }
                let flow = try await waitForFlow(fx.store) { $0.path == "/echo" && $0.state == .completed }
                #expect(flow.provenance.tools.networkCondition == "custom")
            }
        }
    }

    @Test func hostRuleOnlyAffectsItsHost() async throws {
        let slow = Self.custom(downloadKbps: 100, latencyMs: 50)
        let elsewhere = Self.provider(nil, hostRules: [HostNetworkRule(hostPattern: "elsewhere.test", selection: slow)])
        try await ComposeFixture.run(traffic: elsewhere) { fx in
            let result = await fx.compose.send(ComposeRequest(method: "GET", url: fx.url("/hello")))
            #expect(result.response?.body == Data("hello".utf8))
            let flowID = try #require(result.flowID)
            let flow = try await waitForFlow(fx.store) { $0.id == flowID && $0.state == .completed }
            #expect(flow.provenance.tools.networkCondition == nil)
        }
        let matching = Self.provider(nil, hostRules: [
            HostNetworkRule(enabled: false, hostPattern: "127.0.0.1", selection: .preset(.offline)),
            HostNetworkRule(hostPattern: "127.0.0.1", selection: slow),
        ])
        try await ComposeFixture.run(traffic: matching) { fx in
            let result = await fx.compose.send(ComposeRequest(method: "GET", url: fx.url("/hello")))
            #expect(result.response?.body == Data("hello".utf8))
            let flowID = try #require(result.flowID)
            let flow = try await waitForFlow(fx.store) { $0.id == flowID && $0.state == .completed }
            #expect(flow.provenance.tools.networkCondition == "custom")
        }
    }

    @Test func offlinePresetFailsNewConnectionsLocally() async throws {
        try await ComposeFixture.run(traffic: Self.provider(.preset(.offline))) { fx in
            let request = ComposeRequest(method: "GET", url: fx.url("/hello"))
            let result = await fx.compose.send(request)
            #expect(result.response == nil)
            #expect(result.failure?.code == "upstream.unreachable")
            #expect(result.failure?.message.contains("模拟断网") == true, "\(String(describing: result.failure))")
            #expect(fx.origin.state.withLock { $0.connections } == 0)
            let flowID = try #require(result.flowID)
            let flow = try await waitForFlow(fx.store) { $0.id == flowID && $0.state != .inProgress }
            if case .failed(let reason) = flow.state { #expect(reason.contains("模拟断网"), "\(reason)") }
            else { Issue.record("expected a failed flow, got \(flow.state)") }
            #expect(flow.provenance.tools.networkCondition == "preset.offline")
            try await fx.expectReleased(request.id)
        }
    }

    @Test func offlineConnectIsRecordedAsFailedTunnel() async throws {
        // Tunnelled untouched (excluded from decryption): the CONNECT itself gets the local page.
        try await Self.withOrigin { origin in
            try await RulesComposeServer.run(traffic: Self.provider(.preset(.offline)),
                                             configure: { $0.decryption.excludedHosts = ["127.0.0.1"] }) { fx in
                let client = try await RawClient.connect(port: try fx.port)
                do {
                    try await client.send("CONNECT 127.0.0.1:\(origin.port) HTTP/1.1\r\nHost: 127.0.0.1:\(origin.port)\r\n\r\n")
                    try await client.waitUntilClosed()
                    let text = String(decoding: client.remainingBytes(), as: UTF8.self)
                    try await client.close()
                    #expect(text.hasPrefix("HTTP/1.1 502"), "\(text)")
                    #expect(text.contains("模拟断网"), "\(text)")
                } catch { try? await client.close(); throw error }
                #expect(origin.acceptedConnections == 0)
                let flow = try await waitForFlow(fx.store) { $0.method == "CONNECT" && $0.state != .inProgress }
                if case .failed(let reason) = flow.state { #expect(reason.contains("模拟断网"), "\(reason)") }
                else { Issue.record("expected a failed CONNECT flow, got \(flow.state)") }
            }
        }
        // Intercepted: the CONNECT is answered first, and the tunnel opened for the client's first
        // (here non-TLS) bytes fails and is recorded the same way.
        try await Self.withOrigin { origin in
            try await RulesComposeServer.run(traffic: Self.provider(.preset(.offline))) { fx in
                let client = try await RawClient.connect(port: try fx.port)
                do {
                    try await client.send("CONNECT 127.0.0.1:\(origin.port) HTTP/1.1\r\nHost: 127.0.0.1:\(origin.port)\r\n\r\n")
                    let head = try await client.receive(until: "\r\n\r\n")
                    #expect(head == "HTTP/1.1 200 Connection Established\r\n\r\n")
                    try await client.send("GET /hello HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
                    try await client.waitUntilClosed()
                    try await client.close()
                } catch { try? await client.close(); throw error }
                #expect(origin.acceptedConnections == 0)
                let flow = try await waitForFlow(fx.store) { $0.method == "CONNECT" && $0.state != .inProgress }
                if case .failed(let reason) = flow.state { #expect(reason.contains("模拟断网"), "\(reason)") }
                else { Issue.record("expected a failed CONNECT flow, got \(flow.state)") }
            }
        }
    }

    @Test func disabledConditionsAreByteIdentical() async throws {
        func exchange(traffic: TrafficPolicyProvider?) async throws -> [UInt8] {
            var captured: [UInt8] = []
            try await Self.withOrigin { origin in
                try await RulesComposeServer.run(traffic: traffic) { fx in
                    let client = try await RawClient.connect(port: try fx.port)
                    do {
                        try await client.send("GET http://127.0.0.1:\(origin.port)/hello HTTP/1.1\r\nHost: 127.0.0.1:\(origin.port)\r\n\r\n")
                        let hello = try await client.receive(until: "hello")
                        try await client.send("POST http://127.0.0.1:\(origin.port)/echo HTTP/1.1\r\nHost: 127.0.0.1:\(origin.port)\r\n"
                            + "Content-Length: 4\r\n\r\nping")
                        let echoed = try await client.receive(until: "ping")
                        try await client.close()
                        captured = Array((hello + echoed).utf8)
                    } catch { try? await client.close(); throw error }
                    let flow = try await waitForFlow(fx.store) { $0.path == "/echo" && $0.state == .completed }
                    #expect(flow.provenance.tools.networkCondition == nil)
                }
            }
            return captured
        }
        let without = try await exchange(traffic: nil)
        let off = try await exchange(traffic: Self.provider(Self.custom(downloadKbps: 8, uploadKbps: 8, latencyMs: 2_000),
            hostRules: [HostNetworkRule(hostPattern: "127.0.0.1", selection: .preset(.offline))], enabled: false))
        #expect(!without.isEmpty)
        #expect(off == without)
    }

    @Test func pendingBudgetsReturnToZero() async throws {
        try await ComposeFixture.run(traffic: Self.provider(Self.custom(downloadKbps: 4_000, uploadKbps: 4_000, latencyMs: 20))) { fx in
            let upload = ComposeRequest(method: "POST", url: fx.url("/echo"), body: .bytes(Data(repeating: 0x75, count: 40_000)))
            let download = ComposeRequest(method: "GET", url: fx.url("/big?bytes=60000"))
            let first = await fx.compose.send(upload)
            let second = await fx.compose.send(download)
            #expect(first.response?.bodyBytes == 40_000)
            #expect(second.response?.bodyBytes == 60_000)
            try await fx.expectReleased(upload.id)
            try await fx.expectReleased(download.id)
            #expect(fx.compose.resources == ComposeResources())
        }
    }

    @Test func h2OverTLSIsPacedAfterDecryption() async throws {
        // The upstream TLS handler goes in front of the gate: the handshake is not paced, the
        // decrypted HTTP/2 frames are (at least one 150 ms read cycle before the response).
        let origin = try await HTTP2TestOrigin.start(protocols: ["h2"])
        do {
            let roots = NIOSSLTrustRoots.certificates([try NIOSSLCertificate(bytes: origin.ca.rootCertificateDER, format: .der)])
            try await ComposeFixture.run(traffic: Self.provider(Self.custom(latencyMs: 150)),
                                         configure: { $0.upstreamTrustRoots = roots }) { fx in
                let clock = ContinuousClock()
                let started = clock.now
                let request = ComposeRequest(method: "GET", url: try #require(URL(string: "https://localhost:\(origin.port)/h2")))
                let result = await fx.compose.send(request)
                let elapsed = clock.now - started
                #expect(result.failure == nil)
                #expect(result.response?.status == 200)
                #expect(result.response?.body == Data("fixture-body".utf8))
                #expect(result.response?.trailers.contains(HeaderField(name: "x-finish", value: "done")) == true)
                #expect(elapsed >= .milliseconds(150), "\(elapsed)")
                let flowID = try #require(result.flowID)
                let flow = try await waitForFlow(fx.store) { $0.id == flowID && $0.state == .completed }
                #expect(flow.transport.upstreamRequest == .http2)
                #expect(flow.provenance.tools.networkCondition == "custom")
                try await fx.expectReleased(request.id)
            }
            try await origin.stop()
        } catch { try? await origin.stop(); throw error }
    }

    @Test func flappingAutoReadCannotGrowTheQueuePastTheCap() async throws {
        // A fast origin and a slow consumer that turns autoRead off and on for every paced read
        // (as HTTP/1 response backpressure does). NIO re-enables autoRead with a direct socket
        // read that never passes the gate, so without the gate's own handling every flip would
        // admit one more read cycle past the cap.
        let origin = try await BlastOrigin.start(bytes: 4 * 1_048_576)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            var policy = TrafficPolicy()
            policy.conditions.enabled = true
            policy.conditions.global = Self.custom(downloadKbps: 8_192) // 1_024_000 bytes/s
            let connector = UpstreamConnector(configuration: ProxyConfiguration(), traffic: TrafficPolicyProvider(policy))
            let loop = group.next()
            let watermark = OSAllocatedUnfairLock(initialState: (maxQueued: 0, consumed: 0))
            let channel = try await loop.flatSubmit {
                connector.connect(host: "127.0.0.1", port: origin.port, on: loop)
            }.flatMapThrowing { channel in
                let pipeline = channel.pipeline.syncOperations
                let pacer = try pipeline.handler(type: ConnectionPacer.self)
                try pipeline.addHandler(QueueSampler(pacer: pacer, watermark: watermark), position: .first)
                try pipeline.addHandler(FlappingConsumer(watermark: watermark))
                return channel
            }.get()
            try await waitUntil(timeout: .seconds(20), "400 KB consumed at the paced rate") {
                watermark.withLock { $0.consumed } >= 400_000
            }
            try? await channel.close().get()
            let maxQueued = watermark.withLock { $0.maxQueued }
            // At most the cap plus one NIO read cycle (maxMessagesPerRead 4 x 64 KiB buffers).
            #expect(maxQueued <= ConnectionPacer.maxQueuedBytes + 4 * 65_536, "\(maxQueued)")
        } catch {
            try? await group.shutdownGracefully()
            try? await origin.stop()
            throw error
        }
        try await group.shutdownGracefully()
        try await origin.stop()
    }

    @Test func closeDelimitedResponseBelowTheQueueCapIsStillPaced() async throws {
        // The origin writes 300_000 bytes and closes at once, so its whole answer sits in the
        // gate's queue (below the read cap) when the FIN arrives. 1000 kbps = 125_000 bytes/s:
        // the body takes at least 2.4 s, and the end of the stream must wait for it.
        try await Self.withOrigin { origin in
            try await RulesComposeServer.run(traffic: Self.provider(Self.custom(downloadKbps: 1000))) { fx in
                let client = try await RawClient.connect(port: try fx.port)
                do {
                    let clock = ContinuousClock()
                    let started = clock.now
                    try await client.send("GET http://127.0.0.1:\(origin.port)/close-delimited-bytes?bytes=300000 HTTP/1.1\r\nHost: 127.0.0.1:\(origin.port)\r\n\r\n")
                    try await client.waitUntilClosed(timeout: .seconds(20))
                    let elapsed = clock.now - started
                    let bytes = client.remainingBytes()
                    try await client.close()
                    let text = String(decoding: bytes, as: UTF8.self)
                    #expect(text.hasPrefix("HTTP/1.0 200"), "\(text.prefix(40))")
                    let separator = try #require(text.range(of: "\r\n\r\n"))
                    #expect(text[separator.upperBound...] == String(repeating: "b", count: 300_000))
                    #expect(elapsed >= .milliseconds(1_900), "\(elapsed)")
                } catch { try? await client.close(); throw error }
                let flow = try await waitForFlow(fx.store) { $0.path.hasPrefix("/close-delimited-bytes") && $0.state != .inProgress }
                #expect(flow.state == .completed, "\(flow.state)")
            }
        }
    }

    @Test func closeDelimitedHttpsResponseIsPacedThroughTheTLSLayer() async throws {
        // Same as above through TLS: the origin's close_notify and FIN arrive at the TLS handler
        // in front of the gate, which must hand the end on as half closure, not close at once.
        let originCA = try CertificateAuthority.generate(commonName: "Pacer TLS origin CA")
        let origin = try await TestOriginServer.start(tls: try originCA.leaf(for: "localhost"))
        do {
            try await RulesComposeServer.run(traffic: Self.provider(Self.custom(downloadKbps: 1000)), trusted: [originCA]) { fx in
                let url = try #require(URL(string: "https://localhost:\(origin.port)/close-delimited-bytes?bytes=300000"))
                let clock = ContinuousClock()
                let started = clock.now
                let result = await fx.compose.send(ComposeRequest(method: "GET", url: url))
                let elapsed = clock.now - started
                #expect(result.failure == nil, "\(String(describing: result.failure))")
                let response = try #require(result.response)
                #expect(response.status == 200)
                #expect(response.bodyBytes == 300_000)
                #expect(response.body == Data(repeating: 0x62, count: 300_000))
                #expect(elapsed >= .milliseconds(1_900), "\(elapsed)")
            }
        } catch {
            try? await origin.stop()
            throw error
        }
        try await origin.stop()
    }

    @Test func raggedTLSCloseDelimitedResponseEndsRightAfterPacingNotAfterTheShutdownTimeout() async throws {
        // The origin drops TCP without a TLS close_notify (very common). The gate's own close must
        // not wait for the peer's close_notify (NIOSSL's shutdown timeout is about 5 s): the
        // exchange ends when the last paced byte is delivered, as an unthrottled FIN would.
        let originCA = try CertificateAuthority.generate(commonName: "Pacer ragged TLS origin CA")
        let origin = try await RaggedTLSOrigin.start(identity: try originCA.leaf(for: "localhost"), bytes: 300_000)
        do {
            for (traffic, pacedFloor) in [(TrafficPolicyProvider(), Duration.zero),
                                          (Self.provider(Self.custom(downloadKbps: 1000)), .milliseconds(1_900))] {
                try await RulesComposeServer.run(traffic: traffic, trusted: [originCA]) { fx in
                    let url = try #require(URL(string: "https://localhost:\(origin.port)/ragged"))
                    let clock = ContinuousClock()
                    let started = clock.now
                    let result = await fx.compose.send(ComposeRequest(method: "GET", url: url))
                    let elapsed = clock.now - started
                    let response = try #require(result.response, "\(String(describing: result.failure))")
                    #expect(response.bodyBytes == 300_000)
                    #expect(response.body == Data(repeating: 0x62, count: 300_000))
                    #expect(elapsed >= pacedFloor, "\(elapsed)")
                    // 300_000 bytes at 125_000 bytes/s is 2.4 s; a wait for close_notify would add ~5 s.
                    #expect(elapsed < .milliseconds(4_500), "\(elapsed)")
                }
            }
        } catch {
            try? await origin.stop()
            throw error
        }
        try await origin.stop()
    }

    @Test func tunnelledCloseDelimitedResponseIsPacedToo() async throws {
        // A CONNECT tunnel is raw relay: the origin's FIN reaches the gate the same way, and the
        // client still gets every byte before the tunnel closes.
        try await Self.withOrigin { origin in
            try await RulesComposeServer.run(traffic: Self.provider(Self.custom(downloadKbps: 1000)),
                                             configure: { $0.decryption.excludedHosts = ["127.0.0.1"] }) { fx in
                let client = try await RawClient.connect(port: try fx.port)
                do {
                    try await client.send("CONNECT 127.0.0.1:\(origin.port) HTTP/1.1\r\nHost: 127.0.0.1:\(origin.port)\r\n\r\n")
                    _ = try await client.receive(until: "\r\n\r\n", timeout: .seconds(10))
                    let clock = ContinuousClock()
                    let started = clock.now
                    try await client.send("GET /close-delimited-bytes?bytes=300000 HTTP/1.1\r\nHost: 127.0.0.1:\(origin.port)\r\n\r\n")
                    try await client.waitUntilClosed(timeout: .seconds(20))
                    let elapsed = clock.now - started
                    let text = String(decoding: client.remainingBytes(), as: UTF8.self)
                    try await client.close()
                    #expect(text.hasPrefix("HTTP/1.0 200"), "\(text.prefix(40))")
                    let separator = try #require(text.range(of: "\r\n\r\n"))
                    #expect(text[separator.upperBound...] == String(repeating: "b", count: 300_000))
                    #expect(elapsed >= .milliseconds(1_900), "\(elapsed)")
                } catch { try? await client.close(); throw error }
            }
        }
    }

    @Test func clientLeavingDuringAPacedCloseDelimitedResponseEndsTheExchangePromptly() async throws {
        // 8 kbps = 1000 bytes/s: the 300_000 bytes queued at the FIN would take five minutes.
        // The client going away must end the exchange at once rather than keep pacing for it.
        try await Self.withOrigin { origin in
            try await RulesComposeServer.run(traffic: Self.provider(Self.custom(downloadKbps: 8))) { fx in
                let client = try await RawClient.connect(port: try fx.port)
                do {
                    try await client.send("GET http://127.0.0.1:\(origin.port)/close-delimited-bytes?bytes=300000 HTTP/1.1\r\nHost: 127.0.0.1:\(origin.port)\r\n\r\n")
                    _ = try await client.receive(count: 1, timeout: .seconds(20))
                } catch { try? await client.close(); throw error }
                try await client.close()
                let flow = try await waitForFlow(fx.store) { $0.path.hasPrefix("/close-delimited-bytes") && $0.state != .inProgress }
                #expect(flow.state != .completed, "\(flow.state)")
                #expect(flow.bytesReceived < 300_000, "\(flow.bytesReceived)")
            }
        }
    }

    @Test func closeDelimitedResponseIsNotTruncated() async throws {
        // The origin closes right after the body: the queued bytes and the end still reach the
        // client in order (the channel's teardown releases the gate's queue instead of dropping it).
        try await Self.withOrigin { origin in
            try await RulesComposeServer.run(traffic: Self.provider(Self.custom(downloadKbps: 8, latencyMs: 300))) { fx in
                let client = try await RawClient.connect(port: try fx.port)
                do {
                    try await client.send("GET http://127.0.0.1:\(origin.port)/close-delimited-10 HTTP/1.1\r\nHost: 127.0.0.1:\(origin.port)\r\n\r\n")
                    try await client.waitUntilClosed(timeout: .seconds(10))
                    let text = String(decoding: client.remainingBytes(), as: UTF8.self)
                    try await client.close()
                    #expect(text.hasPrefix("HTTP/1.0 200"), "\(text)")
                    #expect(text.hasSuffix("\r\n\r\ncomplete after EOF"), "\(text)")
                } catch { try? await client.close(); throw error }
                let flow = try await waitForFlow(fx.store) { $0.path == "/close-delimited-10" && $0.state != .inProgress }
                #expect(flow.state == .completed, "\(flow.state)")
            }
        }
    }
}

/// A TLS origin that answers any request with an HTTP/1.0 close-delimited body of `bytes` bytes
/// and then drops the TCP connection WITHOUT a TLS close_notify (the close goes out from a handler
/// in front of the TLS layer, so the TLS layer never sees it).
private final class RaggedTLSOrigin: Sendable {
    let port: Int
    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel

    private init(port: Int, group: MultiThreadedEventLoopGroup, channel: Channel) {
        self.port = port
        self.group = group
        self.channel = channel
    }

    static func start(identity: LeafIdentity, bytes: Int) async throws -> RaggedTLSOrigin {
        let configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(try NIOSSLCertificate(bytes: identity.certificateDER, format: .der))],
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: identity.privateKeyDER, format: .der)))
        let tls = try NIOSSLContext(configuration: configuration)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let channel = try await ServerBootstrap(group: group).childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let pipeline = channel.pipeline.syncOperations
                    try pipeline.addHandler(RawCloser())
                    try pipeline.addHandler(NIOSSLServerHandler(context: tls))
                    try pipeline.addHandler(Responder(bytes: bytes))
                }
            }.bind(host: "127.0.0.1", port: 0).get()
            return RaggedTLSOrigin(port: channel.localAddress!.port!, group: group, channel: channel)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    func stop() async throws {
        try? await channel.close().get()
        try await group.shutdownGracefully()
    }

    /// Closest to the socket: closing through its own context skips the TLS layer.
    private final class RawCloser: ChannelOutboundHandler {
        typealias OutboundIn = NIOAny
        private var context: ChannelHandlerContext?
        func handlerAdded(context: ChannelHandlerContext) { self.context = context }
        func handlerRemoved(context: ChannelHandlerContext) { self.context = nil }
        func closeSocket() { context?.close(promise: nil) }
    }

    private final class Responder: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer
        let bytes: Int
        private var answered = false
        init(bytes: Int) { self.bytes = bytes }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            guard !answered else { return }
            answered = true
            var response = ByteBuffer(string: "HTTP/1.0 200 OK\r\n\r\n")
            response.writeRepeatingByte(0x62, count: bytes)
            let closer = try? context.pipeline.syncOperations.handler(type: RawCloser.self)
            context.writeAndFlush(wrapOutboundOut(response)).assumeIsolated().whenComplete { _ in closer?.closeSocket() }
        }
        func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
    }
}

/// Writes `bytes` bytes to every connection as fast as the socket takes them.
private final class BlastOrigin: Sendable {
    let port: Int
    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel

    private init(port: Int, group: MultiThreadedEventLoopGroup, channel: Channel) {
        self.port = port
        self.group = group
        self.channel = channel
    }

    static func start(bytes: Int) async throws -> BlastOrigin {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let channel = try await ServerBootstrap(group: group).childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(Blaster(bytes: bytes))
                }
            }.bind(host: "127.0.0.1", port: 0).get()
            return BlastOrigin(port: channel.localAddress!.port!, group: group, channel: channel)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    func stop() async throws {
        try? await channel.close().get()
        try await group.shutdownGracefully()
    }

    private final class Blaster: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer
        let bytes: Int
        init(bytes: Int) { self.bytes = bytes }
        func channelActive(context: ChannelHandlerContext) {
            context.writeAndFlush(wrapOutboundOut(ByteBuffer(repeating: 0x62, count: bytes)), promise: nil)
            context.fireChannelActive()
        }
        func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
    }
}

/// In front of the gate: records the largest queue right after each socket read.
private final class QueueSampler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    let pacer: ConnectionPacer
    let watermark: OSAllocatedUnfairLock<(maxQueued: Int, consumed: Int)>
    init(pacer: ConnectionPacer, watermark: OSAllocatedUnfairLock<(maxQueued: Int, consumed: Int)>) {
        self.pacer = pacer
        self.watermark = watermark
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.fireChannelRead(data)
        sample()
    }
    func channelReadComplete(context: ChannelHandlerContext) {
        context.fireChannelReadComplete()
        sample()
    }
    private func sample() {
        let queued = pacer.queuedBytes
        watermark.withLock { $0.maxQueued = max($0.maxQueued, queued) }
    }
}

/// Behind the gate: pauses reading on every delivery and resumes 1 ms later.
private final class FlappingConsumer: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    let watermark: OSAllocatedUnfairLock<(maxQueued: Int, consumed: Int)>
    init(watermark: OSAllocatedUnfairLock<(maxQueued: Int, consumed: Int)>) { self.watermark = watermark }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let count = unwrapInboundIn(data).readableBytes
        watermark.withLock { $0.consumed += count }
        let channel = context.channel
        channel.setAutoRead(false)
        context.eventLoop.assumeIsolated().scheduleTask(in: .milliseconds(1)) { channel.setAutoRead(true) }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
