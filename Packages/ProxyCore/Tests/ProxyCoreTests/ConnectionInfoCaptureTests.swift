import CertKit
import FlowStore
import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import Testing
@testable import ProxyCore
@testable import RulesEngine

/// What the proxy records about the two connections of an exchange: the client's address, the origin's
/// address, both TLS versions and the origin's certificate. All of it is read, never asked for (D20).
@Suite(.serialized, .timeLimit(.minutes(3)), .productionChinese) struct ConnectionInfoCaptureTests {
    @Test func plainHTTPRecordsClientIPAndRemoteIPButNoTLS() async throws {
        try await ProxyFixture.run { fx in
            let r = try curl(["-x", fx.proxyURL, "http://127.0.0.1:\(fx.origin.port)/json"])
            #expect(r.exitCode == 0, "\(r.stderr)")
            let flow = try await waitForFlow(fx.store) { $0.state == .completed }
            #expect(flow.clientIP == "127.0.0.1")
            #expect(flow.remoteIP == "127.0.0.1")
            #expect(flow.transport.downstreamTLSVersion == nil)
            #expect(flow.transport.upstreamTLSVersion == nil)
            #expect(flow.upstreamCertificate == nil)
        }
    }

    @Test func httpsRecordsTLSVersionsAndCertificate() async throws {
        let setup = try HTTPSSetup()
        try await setup.run { fx in
            let r = try curl(["-x", fx.proxyURL, "--cacert", setup.proxyCAFile, "https://localhost:\(fx.origin.port)/json"])
            #expect(r.exitCode == 0, "\(r.stderr)")
            let flow = try await waitForFlow(fx.store) { $0.state == .completed }
            #expect(flow.clientIP == "127.0.0.1")
            #expect(flow.remoteIP == "127.0.0.1" || flow.remoteIP == "::1")
            #expect(flow.transport.downstreamTLSVersion?.hasPrefix("TLS 1.") == true)
            #expect(flow.transport.upstreamTLSVersion?.hasPrefix("TLS 1.") == true)
            let certificate = try #require(flow.upstreamCertificate)
            #expect(certificate.subject.contains("localhost"))
            #expect(certificate.issuer.contains("Test CA B"))
            #expect(certificate.sha256Fingerprint.count == 64)
            #expect(certificate.version == 3)
            #expect(certificate.sha1Fingerprint.count == 40)
            #expect(certificate.subjectCommonName == "localhost")
            #expect(certificate.subjectAlternativeNames.contains("localhost"))
            #expect(!certificate.publicKey.isEmpty && !certificate.signature.isEmpty)
            #expect(certificate.isTrusted == true)
            #expect(certificate.notBefore < certificate.notAfter)
        }
    }

    @Test(arguments: [false, true])
    func http2RecordsTheSameFields(downstreamH2: Bool) async throws {
        try await HTTP2TestOrigin.withOrigin(protocols: ["h2"]) { origin in
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: downstreamH2) { fixture, client in
                let result = try await client.request(
                    headers: HTTPHeaders([("host", "localhost:\(origin.port)")]), path: "/info")
                #expect(result.status == 200)
                try await waitForCompletedFlows(fixture.store, atLeast: 1)
                let flow = try #require(fixture.store.allFlows().first)
                #expect(flow.transport.upstreamResponse == .http2)
                #expect(flow.clientIP == "127.0.0.1")
                #expect(flow.remoteIP == "127.0.0.1" || flow.remoteIP == "::1")
                #expect(flow.transport.downstreamTLSVersion?.hasPrefix("TLS 1.") == true)
                #expect(flow.transport.upstreamTLSVersion?.hasPrefix("TLS 1.") == true)
                let certificate = try #require(flow.upstreamCertificate)
                #expect(certificate.subject.contains("localhost"))
                #expect(certificate.sha256Fingerprint.count == 64)
            }
        }
    }

    @Test func composeSendHasNoClientIP() async throws {
        try await ComposeFixture.run { fx in
            let result = await fx.compose.send(ComposeRequest(method: "GET", url: fx.url("/hello")))
            #expect(result.failure == nil)
            let flowID = try #require(result.flowID)
            let flow = try await waitForFlow(fx.store) { $0.id == flowID && $0.state == .completed }
            #expect(flow.clientIP == nil)
            #expect(flow.transport.downstreamTLSVersion == nil)
            #expect(flow.remoteIP == "127.0.0.1")
            #expect(flow.upstreamCertificate == nil)
        }
    }

    @Test func failedUpstreamConnectLeavesRemoteIPNil() async throws {
        try await ProxyFixture.run { fx in
            let r = try curl(["-x", fx.proxyURL, "-w", "\n%{http_code}", "http://127.0.0.1:1/"])
            #expect(r.text.hasSuffix("\n502"))
            let flow = try await waitForFlow(fx.store) { if case .failed = $0.state { true } else { false } }
            #expect(flow.clientIP == "127.0.0.1")
            #expect(flow.remoteIP == nil)
            #expect(flow.transport.upstreamTLSVersion == nil)
            #expect(flow.upstreamCertificate == nil)
        }
    }

    @Test func localResponseHasNoRemoteIPOrCertificate() async throws {
        try await withLocalAsset(Data("local".utf8)) { asset in
            try await ProxyFixture.run(rules: asset.rules(), assets: asset.store) { fx in
                // The proxy closes first (Connection: close, read to EOF), so the client never drops a
                // response whose last write has not settled.
                let reply = try await directoryRaw(fx, host: "127.0.0.1:\(fx.origin.port)", path: "/local")
                #expect(reply.body == Data("local".utf8))
                let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                #expect(fx.origin.acceptedConnections == 0)
                #expect(flow.clientIP == "127.0.0.1")
                #expect(flow.remoteIP == nil)
                #expect(flow.transport.upstreamTLSVersion == nil)
                #expect(flow.upstreamCertificate == nil)
            }
        }
    }

    /// Capturing is read-only: two runs of the same traffic put the same bytes on both wires and record the
    /// same flows (`FlowDigest` ignores the connection-info fields, D20), while the fields are filled.
    @Test func capturingConnectionInfoLeavesWireBytesAlone() async throws {
        let origin = try await TestOriginServer.start()
        do {
            let requests = RulesUnusedByteIdenticalTests.requests(port: origin.port)
            let first = try await RulesUnusedByteIdenticalTests.capture(nil, requests, origin: { origin.receivedBytes })
            let second = try await RulesUnusedByteIdenticalTests.capture(nil, requests, origin: { origin.receivedBytes })
            #expect(first.client == second.client)
            #expect(first.origin == second.origin)
            #expect(!first.origin.isEmpty)
            #expect(first.flows == second.flows)
            #expect(first.recorded.allSatisfy { $0.clientIP != nil && $0.remoteIP != nil })
            try await origin.stop()
        } catch { try? await origin.stop(); throw error }
    }

    /// Wire-neutral: the summary is computed once per connection, however many exchanges ask.
    @Test func upstreamCertificateSummaryIsReadOncePerConnection() throws {
        final class Lease: UpstreamLease {
            let channel: Channel
            init(_ channel: Channel) { self.channel = channel }
            var version: HTTPWireVersion { .http1_1 }
            var wasReused: Bool { false }
            var isWritable: Bool { true }
            func write(_ part: HTTPClientRequestPart) -> EventLoopFuture<Void> { channel.eventLoop.makeSucceededVoidFuture() }
            func flush() {}
            func setResponseReading(_ enabled: Bool) {}
            func release(reusable: Bool) {}
            func cancel(error: Error?) {}
        }
        let summary = CertificateSummary(
            subject: "CN=a", issuer: "CN=ca", serialNumber: "01", sha256Fingerprint: String(repeating: "a", count: 64),
            notBefore: Date(timeIntervalSince1970: 0), notAfter: Date(timeIntervalSince1970: 100))
        var reads = 0
        let first = EmbeddedChannel()
        let second = EmbeddedChannel()
        defer { _ = try? first.finish(); _ = try? second.finish() }
        let read: (Channel) -> CertificateSummary? = { _ in reads += 1; return summary }
        let infos = [
            ConnectionInfoReader.upstream(of: Lease(first), readCertificate: read),
            ConnectionInfoReader.upstream(of: Lease(first), readCertificate: read),
            ConnectionInfoReader.upstream(of: Lease(first), readCertificate: read),
        ]
        #expect(reads == 1)
        #expect(infos.allSatisfy { $0.upstreamCertificate == summary })
        // Another connection reads its own.
        #expect(ConnectionInfoReader.upstream(of: Lease(second), readCertificate: read).upstreamCertificate == summary)
        #expect(reads == 2)
    }
}
