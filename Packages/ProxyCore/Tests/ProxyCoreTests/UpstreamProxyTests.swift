import CertKit
import FlowStore
import Foundation
import NIOCore
import NIOEmbedded
import NIOSSL
import Testing
@testable import ProxyCore

/// Proxy A (decrypting, the one under test) chains through proxy B (`decryption.enabled = false`,
/// so it only tunnels) to B's origin. curl talks to A and trusts A's CA; A trusts the origin's CA.
private struct ChainSetup {
    let proxyCA: CertificateAuthority
    let originCA: CertificateAuthority
    let directory: URL

    var proxyCAFile: String { directory.appendingPathComponent("A.pem").path }

    init() throws {
        proxyCA = try CertificateAuthority.generate(commonName: "Test CA A")
        originCA = try CertificateAuthority.generate(commonName: "Test CA Origin")
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("upstream-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try proxyCA.rootCertificatePEM.write(toFile: proxyCAFile, atomically: true, encoding: .utf8)
    }

    /// Starts B (on `upstreamListenHost`) with an origin (HTTPS with the origin CA's leaf for
    /// `originTLSHost`, or plain HTTP if nil), then A chained to B, and runs `body(a, b)`;
    /// `b.origin` is the origin. A trusts the origin CA, or only the system roots if `trustOrigin`
    /// is false. `configureUpstream` adjusts A's `UpstreamProxy`.
    func run(
        originTLSHost: String? = nil,
        upstreamListenHost: String = "127.0.0.1",
        trustOrigin: Bool = true,
        configureUpstream: (inout UpstreamProxy) -> Void = { _ in },
        _ body: (_ a: ProxyFixture, _ b: ProxyFixture) async throws -> Void
    ) async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let originRoots: NIOSSLTrustRoots = trustOrigin
            ? .certificates([try NIOSSLCertificate(bytes: originCA.rootCertificateDER, format: .der)])
            : .default
        try await ProxyFixture.run(
            configure: {
                $0.decryption.enabled = false
                $0.listenHost = upstreamListenHost
            },
            originTLS: try originTLSHost.map(originCA.leaf(for:))
        ) { b in
            var upstream = UpstreamProxy(host: upstreamListenHost, port: b.proxyPort, bypass: [])
            upstream.alwaysBypassLoopback = false
            configureUpstream(&upstream)
            try await ProxyFixture.run(
                configure: {
                    $0.upstreamProxy = upstream
                    $0.upstreamTrustRoots = originRoots
                },
                certificateAuthority: proxyCA
            ) { a in
                try await body(a, b)
            }
        }
    }
}

@Suite(.productionChinese) struct UpstreamProxyTests {
    @Test func httpsIsChainedThroughUpstream() async throws {
        let setup = try ChainSetup()
        try await setup.run(originTLSHost: "localhost") { a, b in
            let p = b.origin.port
            let r = try curl(["-x", a.proxyURL, "--cacert", setup.proxyCAFile, "https://localhost:\(p)/hello"])
            #expect(r.exitCode == 0, "\(r.stderr)")
            #expect(r.text == "hello")
            let decrypted = try await waitForFlow(a.store) { $0.state == .completed }
            #expect(decrypted.scheme == "https")
            #expect(decrypted.path == "/hello")
            #expect(a.store.allFlows().count == 1)
            let tunnel = try await waitForFlow(b.store) { $0.state == .tunnel }
            #expect(tunnel.method == "CONNECT")
            #expect(tunnel.host == "localhost")
            #expect(tunnel.port == p)
        }
    }

    @Test func plainHTTPIsChainedThroughUpstream() async throws {
        let setup = try ChainSetup()
        try await setup.run { a, b in
            let p = b.origin.port
            let r = try curl(["-x", a.proxyURL, "http://localhost:\(p)/hello"])
            #expect(r.exitCode == 0, "\(r.stderr)")
            #expect(r.text == "hello")
            let f = try await waitForFlow(a.store) { $0.state == .completed }
            #expect(f.scheme == "http")
            #expect(f.path == "/hello")
            let tunnel = try await waitForFlow(b.store) { $0.state == .tunnel }
            #expect(tunnel.method == "CONNECT")
            #expect(tunnel.host == "localhost")
            #expect(tunnel.port == p)
            // B only saw the tunnel: the request inside it was origin-form, sent to the origin.
            #expect(b.store.allFlows().count == 1)
        }
    }

    @Test func bypassedHostGoesDirect() async throws {
        let setup = try ChainSetup()
        try await setup.run(configureUpstream: { $0.bypass = ["127.0.0.1"] }) { a, b in
            let r = try curl(["-x", a.proxyURL, "http://127.0.0.1:\(b.origin.port)/hello"])
            #expect(r.exitCode == 0, "\(r.stderr)")
            #expect(r.text == "hello")
            _ = try await waitForFlow(a.store) { $0.state == .completed }
            #expect(b.store.allFlows().isEmpty)
        }
    }

    @Test func deadUpstreamReturns502() async throws {
        var upstream = UpstreamProxy(host: "127.0.0.1", port: 1, bypass: [])
        upstream.alwaysBypassLoopback = false
        try await ProxyFixture.run(configure: { $0.upstreamProxy = upstream }) { fx in
            let p = fx.origin.port
            let r = try curl(["-x", fx.proxyURL, "-w", "\n%{http_code}", "http://localhost:\(p)/hello"])
            #expect(r.exitCode == 0, "\(r.stderr)")
            #expect(r.text.contains("无法连接"), "\(r.text)")
            #expect(r.text == "ProxyWoman：无法连接 localhost:\(p)（上游代理 127.0.0.1:1：连接被拒绝）\n502")
            let f = try await waitForFlow(fx.store) { $0.path == "/hello" }
            #expect(f.state == .failed("上游代理 127.0.0.1:1：连接被拒绝"))
        }
    }

    @Test func deadUpstreamFailsTunnelWith502() async throws {
        var upstream = UpstreamProxy(host: "127.0.0.1", port: 1, bypass: [])
        upstream.alwaysBypassLoopback = false
        try await ProxyFixture.run(configure: {
            $0.upstreamProxy = upstream
            $0.decryption.enabled = false
        }) { fx in
            let r = try curl(["-x", fx.proxyURL, "-w", "%{http_connect}", "https://localhost:\(fx.origin.port)/hello"])
            #expect(r.exitCode != 0)
            #expect(r.text.hasSuffix("502"), "\(r.text) \(r.stderr)")
            let f = try await waitForFlow(fx.store) { $0.method == "CONNECT" }
            #expect(f.state == .failed("上游代理 127.0.0.1:1：连接被拒绝"))
        }
    }

    /// Through a tunnel the TLS peer address is B's (::1 here), so the origin's IP SAN must be
    /// compared with the target IP (127.0.0.1), not with the socket address.
    @Test func chainedIPLiteralTargetIsVerifiedAgainstTargetIP() async throws {
        let setup = try ChainSetup()
        try await setup.run(originTLSHost: "127.0.0.1", upstreamListenHost: "::1") { a, b in
            let p = b.origin.port
            let r = try curl(["-x", a.proxyURL, "--cacert", setup.proxyCAFile, "https://127.0.0.1:\(p)/hello"])
            #expect(r.exitCode == 0, "\(r.stderr)")
            #expect(r.text == "hello")
            let f = try await waitForFlow(a.store) { $0.state == .completed }
            #expect(f.host == "127.0.0.1")
            #expect(f.scheme == "https")
            let tunnel = try await waitForFlow(b.store) { $0.state == .tunnel }
            #expect(tunnel.host == "127.0.0.1")
        }
    }

    @Test func chainedIPLiteralTargetWithoutMatchingIPSANReturns502() async throws {
        let setup = try ChainSetup()
        // The origin's trusted certificate names ::1 — the tunnel's peer address — not 127.0.0.1.
        try await setup.run(originTLSHost: "::1", upstreamListenHost: "::1") { a, b in
            let r = try curl([
                "-x", a.proxyURL, "--cacert", setup.proxyCAFile, "-w", "\n%{http_code}",
                "https://127.0.0.1:\(b.origin.port)/hello",
            ])
            #expect(r.exitCode == 0, "\(r.stderr)")
            #expect(r.text.hasPrefix("ProxyWoman：上游证书校验失败（"), "\(r.text)")
            #expect(r.text.hasSuffix("\n502"), "\(r.text)")
        }
    }

    @Test func chainedIPLiteralTargetWithUntrustedCertificateReturns502() async throws {
        let setup = try ChainSetup()
        // A trusts only the system roots, so the origin's chain is not trusted.
        try await setup.run(originTLSHost: "127.0.0.1", upstreamListenHost: "::1", trustOrigin: false) { a, b in
            let r = try curl([
                "-x", a.proxyURL, "--cacert", setup.proxyCAFile, "-w", "\n%{http_code}",
                "https://127.0.0.1:\(b.origin.port)/hello",
            ])
            #expect(r.exitCode == 0, "\(r.stderr)")
            #expect(r.text.hasPrefix("ProxyWoman：上游证书校验失败（"), "\(r.text)")
            #expect(r.text.hasSuffix("\n502"), "\(r.text)")
        }
    }
}

// MARK: - The CONNECT handshake with the upstream proxy

/// Collects the bytes that reach the end of the pipeline.
private final class Sink: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    var bytes = ""
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        bytes += String(buffer: unwrapInboundIn(data))
    }
}

private struct HandshakeHarness {
    let channel = EmbeddedChannel()
    let promise: EventLoopPromise<Void>

    init(host: String, port: Int, timeout: TimeAmount = .seconds(5)) throws {
        promise = channel.eventLoop.makePromise()
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 7897)).wait()
        try channel.pipeline.syncOperations.addHandler(
            UpstreamProxyHandshake(host: host, port: port, timeout: timeout, promise: promise))
    }

    func written() throws -> String {
        var text = ""
        while let buffer = try channel.readOutbound(as: ByteBuffer.self) { text += String(buffer: buffer) }
        return text
    }

    func result() -> Result<Void, Error>? {
        var result: Result<Void, Error>?
        promise.futureResult.assumeIsolated().whenComplete { result = $0 }
        return result
    }
}

@Test(.productionChinese) func upstreamHandshakeSendsConnectAndHandsOverLeftoverBytes() throws {
    let h = try HandshakeHarness(host: "example.com", port: 443)
    #expect(try h.written() == "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n")
    let sink = Sink()
    // Like the connector's callers: the next handlers are added once the tunnel stands.
    h.promise.futureResult.assumeIsolated().whenSuccess { try! h.channel.pipeline.syncOperations.addHandler(sink) }
    try h.channel.writeInbound(ByteBuffer(string: "HTTP/1.1 200 Connection"))
    #expect(h.result() == nil)
    try h.channel.writeInbound(ByteBuffer(string: " established\r\nVia: x\r\n\r\nserver-first"))
    guard case .success? = h.result() else {
        Issue.record("handshake did not succeed: \(String(describing: h.result()))")
        return
    }
    #expect(sink.bytes == "server-first")
    #expect(throws: (any Error).self) { try h.channel.pipeline.syncOperations.handler(type: UpstreamProxyHandshake.self) }
    try h.channel.writeInbound(ByteBuffer(string: "more"))
    #expect(sink.bytes == "server-firstmore")
}

@Test(.productionChinese) func upstreamHandshakeBracketsIPv6Targets() throws {
    let h = try HandshakeHarness(host: "::1", port: 8443)
    #expect(try h.written() == "CONNECT [::1]:8443 HTTP/1.1\r\nHost: [::1]:8443\r\n\r\n")
}

@Test(.productionChinese) func upstreamHandshakeRejectsNon2xx() throws {
    let h = try HandshakeHarness(host: "example.com", port: 443)
    _ = try h.written()
    try h.channel.writeInbound(ByteBuffer(string: "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n"))
    guard case .failure(let error)? = h.result() else {
        Issue.record("expected a failure, got \(String(describing: h.result()))")
        return
    }
    #expect(UpstreamConnector.describe(error) == "上游代理拒绝了 CONNECT（403）")
    #expect(!h.channel.isActive)
}

@Test(.productionChinese) func upstreamHandshakeRejectsOversizedHeader() throws {
    let h = try HandshakeHarness(host: "example.com", port: 443)
    _ = try h.written()
    try h.channel.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nX: " + String(repeating: "a", count: 17 * 1024)))
    guard case .failure(let error)? = h.result() else {
        Issue.record("expected a failure, got \(String(describing: h.result()))")
        return
    }
    #expect(UpstreamConnector.describe(error) == "上游代理的响应无效")
    #expect(!h.channel.isActive)
}

@Test(.productionChinese) func upstreamHandshakeFailsWhenProxyCloses() throws {
    let h = try HandshakeHarness(host: "example.com", port: 443)
    _ = try h.written()
    try h.channel.close().wait()
    guard case .failure(let error)? = h.result() else {
        Issue.record("expected a failure, got \(String(describing: h.result()))")
        return
    }
    #expect(UpstreamConnector.describe(error) == "上游代理关闭了连接")
}

@Test(.productionChinese) func upstreamHandshakeTimesOut() throws {
    let h = try HandshakeHarness(host: "example.com", port: 443, timeout: .milliseconds(500))
    _ = try h.written()
    h.channel.embeddedEventLoop.advanceTime(by: .milliseconds(499))
    #expect(h.result() == nil)
    h.channel.embeddedEventLoop.advanceTime(by: .milliseconds(1))
    guard case .failure(let error)? = h.result() else {
        Issue.record("expected a failure, got \(String(describing: h.result()))")
        return
    }
    #expect(UpstreamConnector.describe(error) == "上游代理响应超时")
    #expect(!h.channel.isActive)
}
