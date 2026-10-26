import CertKit
import FlowStore
import Foundation
import NIOCore
import NIOEmbedded
import NIOPosix
import NIOSSL
import Testing
@testable import ProxyCore
import RulesEngine

/// The proxy intercepts with CA "A"; the origin serves a CA "B" certificate for localhost, and the
/// proxy trusts B upstream. Both roots are written to PEM files for curl's `--cacert`.
@Suite(.productionChinese) struct HTTPSSetup {
    let proxyCA: CertificateAuthority
    let originCA: CertificateAuthority
    let directory: URL

    var proxyCAFile: String { directory.appendingPathComponent("A.pem").path }
    var originCAFile: String { directory.appendingPathComponent("B.pem").path }

    init() throws {
        proxyCA = try CertificateAuthority.generate(commonName: "Test CA A")
        originCA = try CertificateAuthority.generate(commonName: "Test CA B")
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("https-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try proxyCA.rootCertificatePEM.write(toFile: proxyCAFile, atomically: true, encoding: .utf8)
        try originCA.rootCertificatePEM.write(toFile: originCAFile, atomically: true, encoding: .utf8)
    }

    var originTrustRoots: NIOSSLTrustRoots {
        get throws { .certificates([try NIOSSLCertificate(bytes: originCA.rootCertificateDER, format: .der)]) }
    }

    var proxyTrustRoots: NIOSSLTrustRoots {
        get throws { .certificates([try NIOSSLCertificate(bytes: proxyCA.rootCertificateDER, format: .der)]) }
    }

    /// Runs a `ProxyFixture` whose origin speaks HTTPS with B's leaf for `originHost`;
    /// `configure` runs after the B trust roots are set.
    func run(
        originHost: String = "localhost",
        configure: (inout ProxyConfiguration) -> Void = { _ in },
        rules: RuleSnapshotProvider? = nil,
        _ body: (ProxyFixture) async throws -> Void
    ) async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let roots = try originTrustRoots
        try await ProxyFixture.run(
            configure: {
                $0.upstreamTrustRoots = roots
                configure(&$0)
            },
            certificateAuthority: proxyCA,
            originTLS: try originCA.leaf(for: originHost),
            rules: rules,
            body)
    }
}

@Suite(.productionChinese) struct HTTPSProxyTests {
    @Test func httpsGetIsDecryptedAndRecorded() async throws {
        let setup = try HTTPSSetup()
        try await setup.run { fx in
            let p = fx.origin.port
            let r = try curl(["-x", fx.proxyURL, "--cacert", setup.proxyCAFile, "https://localhost:\(p)/json"])
            #expect(r.exitCode == 0, "\(r.stderr)")
            #expect(r.text == #"{"b":1,"a":[true,null]}"#)
            let f = try await waitForFlow(fx.store) { $0.state == .completed }
            #expect(f.scheme == "https")
            #expect(f.method == "GET")
            #expect(f.host == "localhost")
            #expect(f.port == p)
            #expect(f.path == "/json")
            #expect(f.url == "https://localhost:\(p)/json")
            #expect(f.statusCode == 200)
            #expect(try f.responseBody?.load() == Data(#"{"b":1,"a":[true,null]}"#.utf8))
            #expect(f.client?.name == "curl")
            // A decrypted CONNECT leaves no flow of its own, only the requests inside it.
            #expect(fx.store.allFlows().count == 1)
        }
    }

    @Test func httpsPostIsDecrypted() async throws {
        let setup = try HTTPSSetup()
        try await setup.run { fx in
            let r = try curl([
                "-x", fx.proxyURL, "--cacert", setup.proxyCAFile, "--data-binary", "x=1",
                "https://localhost:\(fx.origin.port)/echo",
            ])
            #expect(r.exitCode == 0, "\(r.stderr)")
            #expect(r.text == "x=1")
            let f = try await waitForFlow(fx.store) { $0.state == .completed }
            #expect(f.scheme == "https")
            #expect(f.method == "POST")
            #expect(try f.requestBody?.load() == Data("x=1".utf8))
            #expect(try f.responseBody?.load() == Data("x=1".utf8))
        }
    }

    @Test func ipLiteralTargetIsDecrypted() async throws {
        let setup = try HTTPSSetup()
        try await setup.run(originHost: "127.0.0.1") { fx in
            // The proxy's leaf for 127.0.0.1 carries an IP SAN; upstream it sends no SNI.
            let r = try curl([
                "-x", fx.proxyURL, "--cacert", setup.proxyCAFile, "https://127.0.0.1:\(fx.origin.port)/hello",
            ])
            #expect(r.exitCode == 0, "\(r.stderr)")
            #expect(r.text == "hello")
            let f = try await waitForFlow(fx.store) { $0.state == .completed }
            #expect(f.host == "127.0.0.1")
            #expect(f.scheme == "https")
        }
    }

    @Test func ipLiteralOriginWithoutMatchingIPSANReturns502() async throws {
        let setup = try HTTPSSetup()
        // The origin's certificate is trusted, but issued for "localhost", not for 127.0.0.1.
        try await setup.run { fx in
            let r = try curl([
                "-x", fx.proxyURL, "--cacert", setup.proxyCAFile, "-w", "\n%{http_code}",
                "https://127.0.0.1:\(fx.origin.port)/hello",
            ])
            #expect(r.exitCode == 0, "\(r.stderr)")
            #expect(r.text.hasPrefix("ProxyWoman：上游证书校验失败（"), "\(r.text)")
            #expect(r.text.hasSuffix("\n502"), "\(r.text)")
        }
    }

    @Test func excludedHostIsTunneled() async throws {
        let setup = try HTTPSSetup()
        try await setup.run(configure: { $0.decryption.excludedHosts = ["localhost"] }) { fx in
            let p = fx.origin.port
            let r = try curl(["-x", fx.proxyURL, "--cacert", setup.originCAFile, "https://localhost:\(p)/hello"])
            #expect(r.exitCode == 0, "\(r.stderr)")
            #expect(r.text == "hello")
            let f = try await waitForFlow(fx.store) { $0.state == .tunnel && $0.completedAt != nil }
            #expect(f.method == "CONNECT")
            #expect(f.scheme == "https")
            #expect(f.host == "localhost")
            #expect(f.port == p)
            #expect(f.path == "")
            #expect(f.url == "localhost:\(p)")
            #expect(f.bytesSent > 0)
            #expect(f.bytesReceived > 0)
            #expect(fx.store.allFlows().count == 1)
        }
    }

    @Test func unreachableTunnelTargetReturns502() async throws {
        let setup = try HTTPSSetup()
        try await setup.run(configure: { $0.decryption.excludedHosts = ["localhost"] }) { fx in
            let r = try curl([
                "-x", fx.proxyURL, "--cacert", setup.originCAFile, "-w", "%{http_connect}",
                "https://localhost:1/hello",
            ])
            #expect(r.exitCode != 0)
            #expect(r.text.hasSuffix("502"), "\(r.text) \(r.stderr)")
            let f = try await waitForFlow(fx.store) { $0.method == "CONNECT" }
            #expect(f.state == .failed("连接被拒绝"))
            #expect(f.completedAt != nil)
        }
    }

    @Test func handshakeFailureMarksPassthroughWhenAutoPassthroughOn() async throws {
        let setup = try HTTPSSetup()
        try await setup.run(configure: { $0.autoPassthroughOnHandshakeFailure = true }) { fx in
            let url = "https://localhost:\(fx.origin.port)/hello"
            // The client only trusts B, so it rejects the A-signed interception certificate.
            let first = try curl(["-x", fx.proxyURL, "--cacert", setup.originCAFile, url])
            #expect([35, 60].contains(first.exitCode), "\(first.exitCode) \(first.stderr)")
            let failed = try await waitForFlow(fx.store) { $0.state == .failed("TLS 握手失败") }
            #expect(failed.method == "CONNECT")
            #expect(failed.host == "localhost")
            #expect(failed.note?.contains("证书锁定") == true, "\(String(describing: failed.note))")
            #expect(failed.note == "疑似证书锁定，已自动改为直通（不解密）")
            #expect(fx.passthrough.contains("localhost"))

            let second = try curl(["-x", fx.proxyURL, "--cacert", setup.originCAFile, url])
            #expect(second.exitCode == 0, "\(second.stderr)")
            #expect(second.text == "hello")
            let tunnel = try await waitForFlow(fx.store) { $0.state == .tunnel }
            #expect(tunnel.id == fx.store.allFlows().map(\.id).max())
            // Exactly one failure flow for the rejected connection.
            #expect(fx.store.allFlows().filter { $0.state == .failed("TLS 握手失败") }.count == 1)
        }
    }

    @Test func handshakeFailureDoesNotMarkPassthroughWhenAutoPassthroughOff() async throws {
        let setup = try HTTPSSetup()
        try await setup.run { fx in
            let r = try curl([
                "-x", fx.proxyURL, "--cacert", setup.originCAFile, "https://localhost:\(fx.origin.port)/hello",
            ])
            #expect([35, 60].contains(r.exitCode), "\(r.exitCode) \(r.stderr)")
            let failed = try await waitForFlow(fx.store) { $0.state == .failed("TLS 握手失败") }
            #expect(failed.method == "CONNECT")
            #expect(failed.note?.contains("根证书未被信任") == true, "\(String(describing: failed.note))")
            #expect(failed.note == "根证书未被信任，客户端拒绝了 ProxyWoman 的证书")
            #expect(fx.passthrough.hosts.isEmpty)
        }
    }

    @Test func oneAbruptClientHelloDoesNotMarkPassthroughButTwoDo() async throws {
        let setup = try HTTPSSetup()
        try await setup.run(configure: { $0.autoPassthroughOnHandshakeFailure = true }) { fx in
            for attempt in 1...2 {
                let client = try await RawClient.connect(port: fx.proxyPort)
                try await client.send("CONNECT localhost:\(fx.origin.port) HTTP/1.1\r\nHost: localhost\r\n\r\n")
                _ = try await client.receive(until: "\r\n\r\n")
                try await client.send(String(decoding: tlsRecord(testClientHelloBytes()), as: UTF8.self))
                // The server flight proves it consumed the full ClientHello before this abrupt close.
                _ = try await client.receive(until: "\u{16}")
                try await client.close()
                try await waitUntil("failed TLS flow") {
                    fx.store.allFlows().filter { $0.state == .failed("TLS 握手失败") }.count == attempt
                }
                #expect(fx.passthrough.contains("localhost") == (attempt == 2))
                let failure = try #require(fx.store.allFlows().last)
                #expect(failure.note == (attempt == 2 ? InterceptedConnect.autoPassthroughNote : nil))
            }
        }
    }

    @Test func repeatedTruncatedPrefixesDoNotMarkPassthrough() async throws {
        let setup = try HTTPSSetup()
        try await setup.run(configure: { $0.autoPassthroughOnHandshakeFailure = true }) { fx in
            for attempt in 1...2 {
                let client = try await RawClient.connect(port: fx.proxyPort)
                try await client.send("CONNECT localhost:\(fx.origin.port) HTTP/1.1\r\nHost: localhost\r\n\r\n")
                _ = try await client.receive(until: "\r\n\r\n")
                try await client.send("\u{16}")
                try await client.close()
                try await waitUntil("failed attempted TLS flow") {
                    fx.store.allFlows().filter { $0.state == .failed("TLS 握手失败") }.count == attempt
                }
            }
            #expect(fx.passthrough.hosts.isEmpty)
            #expect(fx.store.allFlows().allSatisfy { $0.note == nil })
        }
    }

    @Test func genericHandshakeAlertDoesNotMarkPassthrough() async throws {
        let setup = try HTTPSSetup()
        try await setup.run(configure: { $0.autoPassthroughOnHandshakeFailure = true }) { fx in
            for attempt in 1...2 {
                let client = try await RawClient.connect(port: fx.proxyPort)
                try await client.send("CONNECT localhost:\(fx.origin.port) HTTP/1.1\r\nHost: localhost\r\n\r\n")
                _ = try await client.receive(until: "\r\n\r\n")
                try await client.send(String(decoding: tlsRecord(testClientHelloBytes()), as: UTF8.self))
                _ = try await client.receive(until: "\u{16}")
                // fatal handshake_failure is not a certificate rejection.
                try await client.send("\u{15}\u{03}\u{03}\u{00}\u{02}\u{02}\u{28}")
                try await client.waitUntilClosed()
                try await client.close()
                try await waitUntil("generic TLS failure") {
                    fx.store.allFlows().filter { $0.state == .failed("TLS 握手失败") }.count == attempt
                }
            }
            #expect(fx.passthrough.hosts.isEmpty)
        }
    }

    @Test(arguments: [42, 43, 44, 45, 46, 48])
    func explicitPeerCertificateAlertsMarkPassthrough(alert: Int) async throws {
        let setup = try HTTPSSetup()
        try await setup.run(configure: { $0.autoPassthroughOnHandshakeFailure = true }) { fx in
            let client = try await RawClient.connect(port: fx.proxyPort)
            try await client.send("CONNECT localhost:\(fx.origin.port) HTTP/1.1\r\nHost: localhost\r\n\r\n")
            _ = try await client.receive(until: "\r\n\r\n")
            try await client.send(String(decoding: tlsRecord(testClientHelloBytes()), as: UTF8.self))
            _ = try await client.receive(until: "\u{16}")
            try await client.send(String(decoding: [0x15, 0x03, 0x03, 0x00, 0x02, 0x02, UInt8(alert)], as: UTF8.self))
            try await client.waitUntilClosed()
            try await client.close()
            _ = try await waitForFlow(fx.store) { $0.state == .failed("TLS 握手失败") }
            #expect(fx.passthrough.contains("localhost"))
        }
    }

    @Test func invalidUpstreamCertificateReturns502() async throws {
        let setup = try HTTPSSetup()
        // System roots: the origin's B certificate is not trusted.
        try await setup.run(configure: { $0.upstreamTrustRoots = .default }) { fx in
            let r = try curl([
                "-x", fx.proxyURL, "--cacert", setup.proxyCAFile, "-w", "\n%{http_code}",
                "https://localhost:\(fx.origin.port)/hello",
            ])
            #expect(r.exitCode == 0, "\(r.stderr)")
            #expect(r.text.hasSuffix("\n502"), "\(r.text)")
            #expect(r.text.hasPrefix("ProxyWoman：上游证书校验失败（"), "\(r.text)")
            let f = try await waitForFlow(fx.store) { $0.path == "/hello" }
            guard case .failed(let reason) = f.state else {
                Issue.record("expected a failed flow, got \(f.state)")
                return
            }
            #expect(reason.contains("上游证书校验失败"), "\(reason)")
            #expect(f.scheme == "https")
        }
    }

    @Test func upstreamWithoutTLSReturns502() async throws {
        let setup = try HTTPSSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        // A plain-HTTP origin answers the proxy's ClientHello with garbage.
        try await ProxyFixture.run(certificateAuthority: setup.proxyCA) { fx in
            let r = try curl([
                "-x", fx.proxyURL, "--cacert", setup.proxyCAFile, "-w", "\n%{http_code}",
                "https://localhost:\(fx.origin.port)/hello",
            ])
            #expect(r.exitCode == 0, "\(r.stderr)")
            #expect(r.text == "ProxyWoman：无法连接 localhost:\(fx.origin.port)（TLS 握手失败）\n502")
            let f = try await waitForFlow(fx.store) { $0.path == "/hello" }
            #expect(f.state == .failed("TLS 握手失败"))
        }
    }

    @Test func connectClosedWithoutDataLeavesNoTrace() async throws {
        let setup = try HTTPSSetup()
        try await setup.run(configure: { $0.autoPassthroughOnHandshakeFailure = true }) { fx in
            let p = fx.origin.port
            let client = try await RawClient.connect(port: fx.proxyPort)
            try await client.send("CONNECT localhost:\(p) HTTP/1.1\r\nHost: localhost:\(p)\r\n\r\n")
            _ = try await client.receive(until: "\r\n\r\n")
            try await client.close()  // e.g. a cancelled navigation: no ClientHello was ever sent
            try await Task.sleep(for: .milliseconds(300))
            #expect(fx.passthrough.hosts.isEmpty)
            #expect(!fx.store.allFlows().contains { if case .failed = $0.state { true } else { false } })
        }
    }

    @Test func plainTrafficOverConnectIsRelayedUntouched() async throws {
        let setup = try HTTPSSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        // ws:// through a proxy: CONNECT host:80, then plain HTTP. The origin here speaks plain HTTP.
        try await ProxyFixture.run(
            configure: { $0.autoPassthroughOnHandshakeFailure = true }, certificateAuthority: setup.proxyCA
        ) { fx in
            let p = fx.origin.port
            let client = try await RawClient.connect(port: fx.proxyPort)
            try await client.send("CONNECT localhost:\(p) HTTP/1.1\r\nHost: localhost:\(p)\r\n\r\n")
            #expect(try await client.receive(until: "\r\n\r\n") == "HTTP/1.1 200 Connection Established\r\n\r\n")
            try await client.send("GET /hello HTTP/1.1\r\nHost: localhost:\(p)\r\n\r\n")
            let response = try await client.receive(until: "hello")
            #expect(response.hasPrefix("HTTP/1.1 200 OK"))
            try await client.close()

            let f = try await waitForFlow(fx.store) { $0.state == .tunnel && $0.completedAt != nil }
            #expect(f.method == "CONNECT")
            #expect(f.bytesSent > 0)
            #expect(f.bytesReceived > 0)
            #expect(fx.store.allFlows().count == 1)
            #expect(fx.passthrough.hosts.isEmpty)
        }
    }

    @Test func connectWithoutClientHelloTimesOutQuietly() async throws {
        let setup = try HTTPSSetup()
        try await setup.run(configure: {
            $0.autoPassthroughOnHandshakeFailure = true
            $0.connectTimeout = .milliseconds(500)
        }) { fx in
            let p = fx.origin.port
            let client = try await RawClient.connect(port: fx.proxyPort)
            try await client.send("CONNECT localhost:\(p) HTTP/1.1\r\nHost: localhost:\(p)\r\n\r\n")
            _ = try await client.receive(until: "\r\n\r\n")
            try await client.waitUntilClosed(timeout: .seconds(1))
            try await client.close()
            #expect(fx.passthrough.hosts.isEmpty)
            #expect(fx.store.allFlows().isEmpty)
        }
    }

    @Test func stalledClientHandshakeTimesOutWithoutPassthrough() async throws {
        let setup = try HTTPSSetup()
        try await setup.run(configure: {
            $0.autoPassthroughOnHandshakeFailure = true
            $0.connectTimeout = .milliseconds(500)
        }) { fx in
            let p = fx.origin.port
            let client = try await RawClient.connect(port: fx.proxyPort)
            try await client.send("CONNECT localhost:\(p) HTTP/1.1\r\nHost: localhost:\(p)\r\n\r\n")
            _ = try await client.receive(until: "\r\n\r\n")
            try await client.send("\u{16}\u{03}\u{01}")  // the start of a ClientHello record, then silence
            try await client.waitUntilClosed(timeout: .seconds(1))
            try await client.close()
            let f = try await waitForFlow(fx.store) { $0.method == "CONNECT" }
            #expect(f.state == .failed("TLS 握手超时"))
            #expect(fx.passthrough.hosts.isEmpty)  // a timeout is not certificate pinning
        }
    }

    @Test func stalledUpstreamHandshakeReturns502() async throws {
        let setup = try HTTPSSetup()
        let silent = try await SilentServer.start()
        try await setup.run(configure: { $0.connectTimeout = .milliseconds(500) }) { fx in
            let r = try curl([
                "-x", fx.proxyURL, "--cacert", setup.proxyCAFile, "-w", "\n%{http_code}",
                "https://localhost:\(silent.port)/hello",
            ])
            #expect(r.exitCode == 0, "\(r.stderr)")
            #expect(r.text == "ProxyWoman：上游 TLS 握手超时\n502")
            let f = try await waitForFlow(fx.store) { $0.path == "/hello" }
            #expect(f.state == .failed("上游 TLS 握手超时"))
        }
        try await silent.stop()
    }

    @Test func websocketUpgradeOverMITM() async throws {
        let setup = try HTTPSSetup()
        try await setup.run { fx in
            let p = fx.origin.port
            let client = try await RawClient.connect(port: fx.proxyPort)
            try await client.send("CONNECT localhost:\(p) HTTP/1.1\r\nHost: localhost:\(p)\r\n\r\n")
            let established = try await client.receive(until: "\r\n\r\n")
            #expect(established == "HTTP/1.1 200 Connection Established\r\n\r\n")
            try await client.startTLS(trustRoots: try setup.proxyTrustRoots, serverName: "localhost")
            try await client.send(
                "GET /ws HTTP/1.1\r\nHost: localhost:\(p)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
            let head = try await client.receive(until: "\r\n\r\n")
            #expect(head.contains("101"))
            #expect(try await client.receive(until: TestOriginServer.wsGreeting) == TestOriginServer.wsGreeting)
            try await client.send("ping")
            #expect(try await client.receive(until: "ping", timeout: .seconds(2)) == "ping")
            try await client.close()

            let f = try await waitForFlow(fx.store) { $0.path == "/ws" && $0.state == .completed }
            #expect(f.scheme == "https")
            #expect(f.statusCode == 101)
            #expect(f.note == "已升级为 WebSocket")
        }
    }
}

@Test(.productionChinese) func tunnelByteCountsArePublishedAtMostEvery250ms() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tunnel-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FlowStore(bodyDirectory: directory)
    let loop = EmbeddedEventLoop()
    let recorder = TunnelRecorder(store: store, host: "Example.com", port: 443, client: nil, eventLoop: loop)
    let id = try #require(store.allFlows().first?.id)

    recorder.addSent(10)
    recorder.addReceived(100)
    #expect(store.flow(id)?.bytesReceived == 0)  // not per packet
    loop.advanceTime(by: .milliseconds(249))
    #expect(store.flow(id)?.bytesReceived == 0)
    loop.advanceTime(by: .milliseconds(1))
    #expect(store.flow(id)?.bytesSent == 10)
    #expect(store.flow(id)?.bytesReceived == 100)

    recorder.addReceived(5)
    recorder.close()  // published immediately on close
    let flow = try #require(store.flow(id))
    #expect(flow.bytesReceived == 105)
    #expect(flow.state == .tunnel)
    #expect(flow.completedAt != nil)
    #expect(flow.host == "example.com")
    recorder.addReceived(1)
    loop.advanceTime(by: .seconds(1))
    #expect(store.flow(id)?.bytesReceived == 105)  // nothing after close
}

/// Accepts TCP connections and never says anything.
private struct SilentServer {
    let group: MultiThreadedEventLoopGroup
    let channel: Channel
    var port: Int { channel.localAddress?.port ?? 0 }

    static func start() async throws -> SilentServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let channel = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
        return SilentServer(group: group, channel: channel)
    }

    func stop() async throws {
        try? await channel.close().get()
        try await group.shutdownGracefully()
    }
}

private struct AuthorityCase: Sendable, CustomTestStringConvertible {
    let authority: String
    let host: String
    let port: Int
    var testDescription: String { authority }
}

@Test(.productionChinese, arguments: [
    AuthorityCase(authority: "example.com:443", host: "example.com", port: 443),
    AuthorityCase(authority: "LocalHost:8443", host: "LocalHost", port: 8443),
    AuthorityCase(authority: "[::1]:9000", host: "::1", port: 9000),
    AuthorityCase(authority: "127.0.0.1:1", host: "127.0.0.1", port: 1),
])
private func connectAuthorityIsParsed(testCase: AuthorityCase) throws {
    let target = try #require(RequestTarget(authorityForm: testCase.authority))
    #expect(target.host == testCase.host)
    #expect(target.port == testCase.port)
}

@Test(.productionChinese, arguments: ["example.com", "example.com:0", "example.com:70000", ":443", "[::1]", "http://example.com:443", "a.com:443/x"])
private func invalidConnectAuthorityIsRejected(authority: String) {
    #expect(RequestTarget(authorityForm: authority) == nil)
}

/// A TLS 1.3 ClientHello with an empty key share: the server returns HelloRetryRequest.
/// All bytes are ASCII so RawClient's string transport preserves the wire fixture exactly.
func testClientHelloBytes() -> [UInt8] {
    [0x01, 0x00, 0x00, 0x48, 0x03, 0x03] + [UInt8](repeating: 0x41, count: 32)
        + [0x00, 0x00, 0x02, 0x13, 0x01, 0x01, 0x00, 0x00, 0x1d,
           0x00, 0x2b, 0x00, 0x03, 0x02, 0x03, 0x04,
           0x00, 0x0a, 0x00, 0x04, 0x00, 0x02, 0x00, 0x1d,
           0x00, 0x0d, 0x00, 0x04, 0x00, 0x02, 0x04, 0x03,
           0x00, 0x33, 0x00, 0x02, 0x00, 0x00]
}

func tlsRecord(_ payload: [UInt8]) -> [UInt8] {
    [0x16, 0x03, 0x03, UInt8(payload.count >> 8), UInt8(payload.count & 255)] + payload
}
