import Atomics
import CertKit
import FlowStore
import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOPosix
import Testing
import os
@testable import ProxyCore
import RulesEngine

/// A started proxy (fresh store, OS-assigned port) plus a `TestOriginServer`, torn down after `body`.
@Suite(.productionChinese) struct ProxyFixture: Sendable {
    let store: FlowStore
    let passthrough: PassthroughRegistry
    let server: ProxyServer
    let origin: TestOriginServer
    let proxyPort: Int

    var proxyURL: String { "http://127.0.0.1:\(proxyPort)" }

    /// `certificateAuthority` signs the proxy's interception certificates (a fresh one if nil);
    /// `originTLS` makes the origin serve HTTPS with that identity.
    static func run(
        configure: (inout ProxyConfiguration) -> Void = { _ in },
        processLookup: ProcessLookup = .live,
        certificateAuthority: CertificateAuthority? = nil,
        originTLS: LeafIdentity? = nil,
        slowResponseBarrier: EventLoopFuture<Void>? = nil,
        maxCapturedBodyBytes: Int = BodyCapture.defaultMaxCapturedBytes,
        rules: RuleSnapshotProvider? = nil, assets: ManagedAssetStore? = nil, breakpoints: BreakpointCoordinator? = nil,
        localResponseHooks: LocalResponseSource.Hooks? = nil, bodyRuntime: BreakpointBodyRuntime? = nil, drainDeadline: ProxyDrainDeadline = .standard,
        ruleDelayHook: RuleDelayHook? = nil,
        _ body: (ProxyFixture) async throws -> Void
    ) async throws {
        let bodyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxycore-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: bodyDirectory) }
        let store = FlowStore(bodyDirectory: bodyDirectory, maxCapturedBodyBytes: maxCapturedBodyBytes)
        let passthrough = PassthroughRegistry()
        var configuration = ProxyConfiguration()
        configuration.port = 0
        configure(&configuration)
        let server = ProxyServer(
            configuration: configuration, certificateAuthority: try certificateAuthority ?? CertificateAuthority.generate(),
            store: store, passthrough: passthrough, processLookup: processLookup, drainDeadline: drainDeadline, rules: rules, assets: assets, breakpoints: breakpoints, localResponseHooks: localResponseHooks, bodyRuntime: bodyRuntime,
            ruleDelayHook: ruleDelayHook)
        let origin = try await TestOriginServer.start(tls: originTLS, slowResponseBarrier: slowResponseBarrier)
        do {
            try await server.start()
            let port = try #require(server.boundPort)
            try await body(ProxyFixture(store: store, passthrough: passthrough, server: server, origin: origin, proxyPort: port))
        } catch {
            try? await server.stop()
            try? await origin.stop()
            throw error
        }
        try await server.stop()
        try await origin.stop()
    }
}

@Suite(.productionChinese) struct HTTPProxyTests {
    @Test func forwardedPartsFlushAtReadCompleteAndEndFlushesImmediately() async throws {
        try await withMetadataPipeline { client, upstream, store in
            try client.writeInbound(ByteBuffer(string: "POST http://example.com/batch HTTP/1.1\r\nHost: example.com\r\nContent-Length: 6\r\n\r\n"))
            _ = try drainMetadataBytes(upstream)
            client.pipeline.fireChannelRead(ByteBuffer(string: "abc"))
            #expect(try drainMetadataBytes(upstream).isEmpty)
            client.pipeline.fireChannelReadComplete()
            #expect(try drainMetadataBytes(upstream) == "abc")
            client.pipeline.fireChannelRead(ByteBuffer(string: "def"))
            #expect(try drainMetadataBytes(upstream) == "def") // terminal request flush
            client.pipeline.fireChannelReadComplete()
            upstream.pipeline.fireChannelRead(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\nabc"))
            #expect(try drainMetadataBytes(client).isEmpty)
            upstream.pipeline.fireChannelReadComplete()
            #expect(try drainMetadataBytes(client).hasSuffix("\r\n\r\nabc"))
            upstream.pipeline.fireChannelRead(ByteBuffer(string: "def"))
            #expect(try drainMetadataBytes(client) == "def") // END must settle writes before readComplete
            #expect(store.allFlows().first?.state == .completed)
            upstream.pipeline.fireChannelReadComplete()
        }
    }

    @Test func sameBatchMalformedResponseFlushesBeforeFailureClose() async throws {
        try await withMetadataPipeline { client, upstream, store in
            try client.writeInbound(ByteBuffer(string: "GET http://example.com/broken HTTP/1.1\r\nHost: example.com\r\n\r\n"))
            _ = try drainMetadataBytes(upstream)
            upstream.pipeline.fireChannelRead(ByteBuffer(string: "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\nZ\r\n"))
            // No readComplete follows a decoder error that closes this batch.
            #expect(!upstream.isActive)
            #expect(!client.isActive)
            #expect(try drainMetadataBytes(client).hasSuffix("3\r\nabc\r\n"))
            let flow = try #require(store.allFlows().first)
            if case .failed = flow.state {} else { Issue.record("Malformed response must fail capture") }
            #expect(flow.completedAt != nil)
        }
    }

    @Test func http10LocalPersistenceIsExplicitOnConsecutiveWireResponses() async throws {
        try await withMetadataPipeline { client, upstream, _ in
            for target in ["/", "http://example.com/fail", "/again"] {
                try client.writeInbound(ByteBuffer(string: "GET \(target) HTTP/1.0\r\nHost: example.com\r\nConnection: keep-alive\r\n\r\n"))
                if target.contains("fail") { _ = try drainMetadataBytes(upstream); try upstream.close().wait() }
                let bytes = try drainMetadataBytes(client)
                #expect(bytes.hasPrefix("HTTP/1.0 "))
                #expect(bytes.lowercased().contains("connection: keep-alive\r\n"))
                #expect(client.isActive)
            }
        }
    }

    @Test func invalidSemanticTrailerCancelsTheLeaseAndFailsAnAlreadyStartedResponse() async throws {
        try await withMetadataPipeline { client, upstream, store in
            try client.writeInbound(ByteBuffer(string: "GET http://example.com/trailer HTTP/1.1\r\nHost: example.com\r\n\r\n"))
            _ = try drainMetadataBytes(upstream)
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n"))
            #expect(try drainMetadataBytes(client).hasSuffix("3\r\nabc\r\n"))
            // Inject at the semantic sink boundary: a wire decoder rejects this earlier.
            // This verifies that translation errors also settle correctly after a head.
            let handler = try upstream.pipeline.syncOperations.handler(type: UpstreamResponseHandler.self)
            let context = try upstream.pipeline.syncOperations.context(handler: handler)
            handler.channelRead(context: context, data: NIOAny(HTTPClientResponsePart.end(HTTPHeaders([("X-End", "bad\r\ninjected")]))))
            #expect(try drainMetadataBytes(client).isEmpty)
            #expect(!client.isActive)
            #expect(!upstream.isActive)
            let flow = try #require(store.allFlows().first)
            if case .failed = flow.state {} else { Issue.record("invalid trailer must fail, not complete the flow") }
            #expect(flow.completedAt != nil)
        }
    }

    @Test func compoundCodingsAndHopNormalizationKeepOriginalHeaderProvenance() async throws {
        try await withMetadataPipeline { client, upstream, store in
            try client.writeInbound(ByteBuffer(string: "GET http://example.com/opaque HTTP/1.1\r\nHost: example.com\r\nConnection: X-Hop\r\nX-Hop: original\r\nTransfer-Encoding: gzip, chunked\r\nContent-Encoding: br\r\n\r\n3\r\nabc\r\n0\r\nX-Upload: a\r\nX-Upload: b\r\n\r\n"))
            let request = try drainMetadataBytes(upstream)
            #expect(request.hasPrefix("GET /opaque HTTP/1.1\r\n"))
            #expect(request.contains("Transfer-Encoding: gzip, chunked\r\n"))
            #expect(request.contains("Content-Encoding: br\r\n"))
            #expect(!request.contains("X-Hop:"))
            #expect(request.hasSuffix("\r\n\r\n3\r\nabc\r\n0\r\nX-Upload: a\r\nX-Upload: b\r\n\r\n"))
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nConnection: X-Private\r\nX-Private: source\r\nTransfer-Encoding: gzip, chunked\r\n\r\n3\r\nxyz\r\n0\r\nX-End: 1\r\nX-End: 2\r\n\r\n"))
            let response = try drainMetadataBytes(client)
            #expect(response.contains("Transfer-Encoding: gzip, chunked\r\n"))
            #expect(!response.contains("X-Private:"))
            #expect(response.hasSuffix("\r\n\r\n3\r\nxyz\r\n0\r\nX-End: 1\r\nX-End: 2\r\n\r\n"))
            let flow = try #require(store.allFlows().first)
            #expect(flow.requestHeaders.value(for: "X-Hop") == "original")
            #expect(flow.responseHeaders.value(for: "X-Private") == "source")
            #expect(flow.requestHeaders.value(for: "Transfer-Encoding") == "gzip, chunked")
            #expect(flow.responseHeaders.value(for: "Transfer-Encoding") == "gzip, chunked")
            #expect(flow.requestTrailers.map(\.value) == ["a", "b"])
            #expect(flow.responseTrailers.map(\.value) == ["1", "2"])
            #expect(try flow.requestBody?.load() == Data("abc".utf8))
            #expect(try flow.responseBody?.load() == Data("xyz".utf8))
            #expect(flow.state == .completed)
        }
    }

    @Test func opaqueNonChunkedResponseKeepsCodingUntilOriginEOFFlushesAndCloses() async throws {
        try await withMetadataPipeline { client, upstream, store in
            try client.writeInbound(ByteBuffer(string: "GET http://example.com/opaque HTTP/1.1\r\nHost: example.com\r\n\r\n"))
            _ = try drainMetadataBytes(upstream)
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\n\r\nopaque"))
            let response = try drainMetadataBytes(client)
            #expect(response.contains("Transfer-Encoding: gzip\r\n"))
            #expect(response.lowercased().contains("connection: close\r\n"))
            #expect(response.hasSuffix("\r\n\r\nopaque"))
            #expect(client.isActive)
            try upstream.close().wait()
            #expect(try drainMetadataBytes(client).isEmpty)
            #expect(!client.isActive)
            let flow = try #require(store.allFlows().first)
            #expect(flow.state == .completed)
            #expect(try flow.responseBody?.load() == Data("opaque".utf8))
        }
    }

    @Test func unsupportedDowngradeFailsBeforeOriginHeadReachesClient() async throws {
        try await withMetadataPipeline { client, upstream, store in
            try client.writeInbound(ByteBuffer(string: "GET http://example.com/opaque HTTP/1.0\r\nHost: example.com\r\n\r\n"))
            _ = try drainMetadataBytes(upstream)
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n"))
            let response = try drainMetadataBytes(client)
            #expect(response.hasPrefix("HTTP/1.0 502 Bad Gateway\r\n"))
            #expect(!response.contains("200 OK"))
            #expect(!response.lowercased().contains("transfer-encoding"))
            #expect(response.contains("目标协议不支持此 HTTP 传输编码"))
            let flow = try #require(store.allFlows().first)
            #expect(flow.responseHeaders.value(for: "Transfer-Encoding") == "gzip, chunked")
            #expect(flow.transport.upstreamResponse == .http1_1)
            #expect(flow.transport.downstreamResponse == .http1_0)
            if case .failed = flow.state {} else { Issue.record("unsupported conversion must fail") }
        }
    }

    @Test func http10ClientReceivesCloseDelimitedOrigin11StreamAfterFinalFlush() async throws {
        try await withMetadataPipeline { client, upstream, store in
            try client.writeInbound(ByteBuffer(string: "GET http://example.com/stream HTTP/1.0\r\nHost: example.com\r\nConnection: keep-alive\r\n\r\n"))
            #expect(try drainMetadataBytes(upstream).hasPrefix("GET /stream HTTP/1.0\r\n"))
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nTrailer: X-End\r\n\r\n5\r\nfirst\r\n"))
            let first = try drainMetadataBytes(client)
            #expect(first.hasPrefix("HTTP/1.0 200 OK\r\n"))
            #expect(!first.lowercased().contains("transfer-encoding"))
            #expect(!first.lowercased().contains("trailer:"))
            #expect(first.hasSuffix("\r\n\r\nfirst"))
            #expect(client.isActive)
            try upstream.writeInbound(ByteBuffer(string: "6\r\nsecond\r\n0\r\nX-End: captured\r\n\r\n"))
            #expect(try drainMetadataBytes(client) == "second")
            #expect(!client.isActive)
            let flow = try #require(store.allFlows().first)
            #expect(flow.transport == .init(downstreamRequest: .http1_0, downstreamResponse: .http1_0,
                                            upstreamRequest: .http1_0, upstreamResponse: .http1_1))
            #expect(flow.responseHeaders.value(for: "Transfer-Encoding") == "chunked")
            #expect(flow.responseTrailers == [.init(name: "X-End", value: "captured")])
            #expect(try flow.responseBody?.load() == Data("firstsecond".utf8))
            #expect(flow.state == .completed)
        }
    }

    @Test func headAnd304KeepRepresentationLengthAndDoNotCorruptFollowingResponse() async throws {
        try await withMetadataPipeline { client, upstream, store in
            try client.writeInbound(ByteBuffer(string: "HEAD http://example.com/head HTTP/1.1\r\nHost: example.com\r\n\r\nGET http://example.com/cached HTTP/1.1\r\nHost: example.com\r\n\r\nGET http://example.com/next HTTP/1.1\r\nHost: example.com\r\n\r\n"))
            _ = try drainMetadataBytes(upstream)
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n"))
            client.embeddedEventLoop.run()
            #expect(try drainMetadataBytes(client) == "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n")
            #expect(try drainMetadataBytes(upstream).hasPrefix("GET /cached HTTP/1.1\r\n"))
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 304 Not Modified\r\nContent-Length: 42\r\n\r\n"))
            client.embeddedEventLoop.run()
            #expect(try drainMetadataBytes(client) == "HTTP/1.1 304 Not Modified\r\nContent-Length: 42\r\n\r\n")
            #expect(try drainMetadataBytes(upstream).hasPrefix("GET /next HTTP/1.1\r\n"))
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"))
            client.embeddedEventLoop.run()
            #expect(try drainMetadataBytes(client) == "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
            #expect(store.allFlows().count == 3)
            #expect(store.allFlows().allSatisfy { $0.state == .completed })
        }
    }

    @Test func loopbackHTTP10StreamingContainsEntityBytesAndCloses() async throws {
        try await ProxyFixture.run(processLookup: .none) { fixture in
            let client = try await RawClient.connect(port: fixture.proxyPort)
            do {
                try await client.send("GET http://127.0.0.1:\(fixture.origin.port)/slow HTTP/1.0\r\nHost: 127.0.0.1:\(fixture.origin.port)\r\nConnection: keep-alive\r\n\r\n")
                let response = try await client.receive(until: "second")
                #expect(response.hasPrefix("HTTP/1.0 200 OK\r\n"))
                #expect(!response.lowercased().contains("transfer-encoding"))
                #expect(response.hasSuffix("\r\n\r\nfirstsecond"))
                try await client.waitUntilClosed(timeout: .seconds(1))
            } catch {
                try? await client.close()
                throw error
            }
            try await client.close()
        }
    }

    @Test func originalHeadersAreCapturedBeforeForwardingNormalization() async throws {
        try await withMetadataPipeline { client, upstream, store in
            try client.writeInbound(ByteBuffer(string:
                "GET http://example.com/original HTTP/1.0\r\nProxy-Connection: keep-alive\r\n\r\n"))
            let forwarded = try drainMetadataBytes(upstream)
            #expect(forwarded.hasPrefix("GET /original HTTP/1.0\r\n"))
            #expect(forwarded.contains("Host: example.com\r\n"))
            #expect(!forwarded.lowercased().contains("proxy-connection"))
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nok"))
            #expect(try drainMetadataBytes(client).hasPrefix("HTTP/1.0 200 OK\r\n"))
            let flow = try #require(store.allFlows().first)
            #expect(flow.requestHeaders.value(for: "Proxy-Connection") == "keep-alive")
            #expect(flow.requestHeaders.value(for: "Host") == nil)
            #expect(flow.state == .completed)
            #expect(flow.transport == .init(downstreamRequest: .http1_0, downstreamResponse: .http1_0,
                                            upstreamRequest: .http1_0, upstreamResponse: .http1_0))
        }
    }

    @Test func pipelineCapturesAsymmetricResponseAndOrderedTrailers() async throws {
        try await withMetadataPipeline { client, upstream, store in
            try client.writeInbound(ByteBuffer(string: "GET http://example.com/asymmetric HTTP/1.1\r\nHost: example.com\r\n\r\n"))
            #expect(try drainMetadataBytes(upstream).hasPrefix("GET /asymmetric HTTP/1.1\r\n"))
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 103 Early Hints\r\nLink: </a>\r\n\r\nHTTP/1.0 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok"))
            #expect(try drainMetadataBytes(client).contains("HTTP/1.0 200 OK\r\n"))
            let asymmetric = try #require(store.allFlows().first)
            #expect(asymmetric.transport == .init(downstreamRequest: .http1_1, downstreamResponse: .http1_0,
                                                 upstreamRequest: .http1_1, upstreamResponse: .http1_0))
            try client.writeInbound(ByteBuffer(string: "POST http://example.com/trailers HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\nTrailer: X-Upload\r\n\r\n3\r\nabc\r\n0\r\nX-Upload: a\r\nX-Upload: b\r\n\r\n"))
            let forwarded = try drainMetadataBytes(upstream)
            #expect(forwarded.contains("X-Upload: a\r\nX-Upload: b\r\n"))
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nTrailer: X-End\r\n\r\n3\r\nxyz\r\n0\r\nX-End: 1\r\nX-Other: 2\r\nX-End: 3\r\n\r\n"))
            #expect(try drainMetadataBytes(client).contains("X-End: 1\r\nX-Other: 2\r\nX-End: 3\r\n"))
            let flow = try #require(store.allFlows().last)
            #expect(flow.path == "/trailers")
            #expect(flow.requestTrailers == [.init(name: "X-Upload", value: "a"), .init(name: "X-Upload", value: "b")])
            #expect(flow.responseTrailers == [.init(name: "X-End", value: "1"), .init(name: "X-Other", value: "2"), .init(name: "X-End", value: "3")])
            #expect(flow.requestHeaders.value(for: "X-Upload") == nil)
            #expect(flow.responseHeaders.value(for: "X-End") == nil)
            #expect(flow.transport == .init(downstreamRequest: .http1_1, downstreamResponse: .http1_1,
                                            upstreamRequest: .http1_1, upstreamResponse: .http1_1))
            #expect(try flow.requestBody?.load() == Data("abc".utf8))
            #expect(try flow.responseBody?.load() == Data("xyz".utf8))
        }
    }

    @Test func connectionFailureRecordsOnlyTheSubmittedLocalResponseVersion() async throws {
        try await withMetadataPipeline(connectionFails: true) { client, upstream, store in
            try client.writeInbound(ByteBuffer(string: "GET http://example.com/failure HTTP/1.1\r\nHost: example.com\r\n\r\n"))
            #expect(try drainMetadataBytes(upstream).isEmpty)
            #expect(try drainMetadataBytes(client).hasPrefix("HTTP/1.1 502"))
            let flow = try #require(store.allFlows().first)
            #expect(flow.transport == .init(downstreamRequest: .http1_1, downstreamResponse: .http1_1))
            if case .failed = flow.state {} else { Issue.record("connection failure must remain failed") }
            #expect(flow.statusCode == nil)
            #expect(flow.responseHeaders.isEmpty)
            #expect(flow.responseBody == nil)
            #expect(flow.bytesReceived == 0)
        }
    }

    @Test func connectionFailureAfterHandlerRemovalStillSettlesTheFlow() async throws {
        var pendingConnection: EventLoopPromise<Channel>?
        try await withMetadataPipeline(connectionFactory: { _, _, eventLoop in
            let promise = eventLoop.makePromise(of: Channel.self)
            pendingConnection = promise
            return promise.futureResult
        }) { client, upstream, store in
            try client.writeInbound(ByteBuffer(string: "GET http://example.com/removed HTTP/1.1\r\nHost: example.com\r\n\r\n"))
            let owner = try client.pipeline.syncOperations.handler(type: ProxyHandler.self)
            client.pipeline.syncOperations.removeHandler(owner, promise: nil)
            client.embeddedEventLoop.run()
            try #require(pendingConnection).fail(ChannelError.ioOnClosedChannel)
            #expect(try drainMetadataBytes(upstream).isEmpty)
            #expect(try drainMetadataBytes(client).isEmpty)
            let flow = try #require(store.allFlows().first)
            #expect(flow.transport == .init(downstreamRequest: .http1_1))
            if case .failed = flow.state {} else { Issue.record("removed handler must still settle a failed connect") }
            #expect(flow.completedAt != nil)
            #expect(flow.statusCode == nil)
            #expect(flow.responseBody == nil)
            // Release the loop-bound promise before the async fixture teardown suspends.
            pendingConnection = nil
        }
    }

    @Test(arguments: [100, 103])
    func interimThenEOFDoesNotInventFinalResponseVersion(status: Int) async throws {
        try await withMetadataPipeline { client, upstream, store in
            try client.writeInbound(ByteBuffer(string: "GET http://example.com/interim HTTP/1.1\r\nHost: example.com\r\n\r\n"))
            _ = try drainMetadataBytes(upstream)
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 \(status) Interim\r\n\r\n"))
            try upstream.close().wait()
            let response = try drainMetadataBytes(client)
            #expect(response.hasPrefix("HTTP/1.1 \(status)"))
            #expect(!response.contains("502"))
            let flow = try #require(store.allFlows().first)
            #expect(flow.transport == .init(downstreamRequest: .http1_1, upstreamRequest: .http1_1))
            #expect(flow.statusCode == nil)
            if case .failed = flow.state {} else { Issue.record("interim EOF must fail") }
        }
    }

    @Test func plainGetIsForwardedAndRecorded() async throws {
        try await ProxyFixture.run { fx in
            let r = try curl(["-x", fx.proxyURL, "-H", "Proxy-Connection: keep-alive", "http://localhost:\(fx.origin.port)/json"])
            #expect(r.exitCode == 0, "\(r.stderr)")
            #expect(r.text == #"{"b":1,"a":[true,null]}"#)
            let f = try await waitForFlow(fx.store) { $0.state == .completed }
            #expect(f.method == "GET")
            #expect(f.scheme == "http")
            #expect(f.host == "localhost")
            #expect(f.port == fx.origin.port)
            #expect(f.path == "/json")
            #expect(f.statusCode == 200)
            #expect(f.responseHeaders.value(for: "Content-Type") == "application/json")
            #expect(f.requestHeaders.value(for: "Proxy-Connection") == "keep-alive")
            #expect(f.requestHeaders.value(for: "Host") == "localhost:\(fx.origin.port)")
            #expect(try f.responseBody?.load() == Data(#"{"b":1,"a":[true,null]}"#.utf8))
            #expect(f.completedAt != nil)
            #expect(f.client?.name == "curl")
        }
    }

    @Test func postBodyIsForwardedAndCaptured() async throws {
        try await ProxyFixture.run { fx in
            let r = try curl(["-x", fx.proxyURL, "--data-binary", "x=1", "http://localhost:\(fx.origin.port)/echo"])
            #expect(r.exitCode == 0, "\(r.stderr)")
            #expect(r.text == "x=1")
            let f = try await waitForFlow(fx.store) { $0.state == .completed }
            #expect(f.method == "POST")
            #expect(try f.requestBody?.load() == Data("x=1".utf8))
            #expect(try f.responseBody?.load() == Data("x=1".utf8))
            #expect(f.bytesSent == 3)
            #expect(f.bytesReceived == 3)
        }
    }

    @Test func keepAliveServesSequentialRequests() async throws {
        try await ProxyFixture.run { fx in
            let url = "http://localhost:\(fx.origin.port)/hello"
            // num_connects is 0 for a transfer that reused the previous connection.
            let r = try curl(["-x", fx.proxyURL, "-w", "%{num_connects}\n", url, url])
            #expect(r.exitCode == 0, "\(r.stderr)")
            #expect(r.text == "hello1\nhello0\n")
            try await waitUntil("two completed flows") {
                fx.store.allFlows().filter { $0.state == .completed }.count == 2
            }
            #expect(fx.store.allFlows().map(\.path) == ["/hello", "/hello"])
        }
    }

    @Test func originConnectionCloseIsHonored() async throws {
        try await ProxyFixture.run { fx in
            let base = "http://localhost:\(fx.origin.port)"
            let r = try curl(["-x", fx.proxyURL, "\(base)/close", "\(base)/hello"])
            #expect(r.exitCode == 0, "\(r.stderr)")
            #expect(r.text == "byehello")
            try await waitUntil("two completed flows") {
                fx.store.allFlows().filter { $0.state == .completed }.count == 2
            }
        }
    }

    @Test func bigResponseIsStreamedAndSpilledToDisk() async throws {
        try await ProxyFixture.run { fx in
            let r = try curl(["-x", fx.proxyURL, "http://localhost:\(fx.origin.port)/big?mb=50"])
            #expect(r.exitCode == 0, "\(r.stderr)")
            #expect(r.stdout.count == 52_428_800)
            let f = try await waitForFlow(fx.store) { $0.state == .completed }
            guard case .managed(let handle)? = f.responseBody else {
                Issue.record("expected a spilled body, got \(String(describing: f.responseBody))")
                return
            }
            #expect(handle.size == 52_428_800)
            #expect(f.bytesReceived == 52_428_800)
            // Exactly the default capture cap: nothing was cut.
            #expect(!f.responseBodyTruncated)
        }
    }

    @Test func bodiesBeyondTheCaptureCapAreForwardedButRecordedAsPrefix() async throws {
        try await ProxyFixture.run(maxCapturedBodyBytes: 5) { fx in
            let r = try curl(["-x", fx.proxyURL, "--data-binary", "hello world", "http://localhost:\(fx.origin.port)/echo"])
            #expect(r.exitCode == 0, "\(r.stderr)")
            #expect(r.text == "hello world")
            let f = try await waitForFlow(fx.store) { $0.state == .completed }
            #expect(try f.requestBody?.load() == Data("hello".utf8))
            #expect(f.requestBodyTruncated)
            #expect(try f.responseBody?.load() == Data("hello".utf8))
            #expect(f.responseBodyTruncated)
            #expect(f.bytesSent == 11)
            #expect(f.bytesReceived == 11)
        }
    }

    @Test func spilledResponseBeyondTheCaptureCapIsCut() async throws {
        try await ProxyFixture.run(maxCapturedBodyBytes: 2 << 20) { fx in
            let r = try curl(["-x", fx.proxyURL, "http://localhost:\(fx.origin.port)/big?mb=3"])
            #expect(r.exitCode == 0, "\(r.stderr)")
            #expect(r.stdout.count == 3 << 20)
            let f = try await waitForFlow(fx.store) { $0.state == .completed }
            #expect(f.responseBody?.size == 2 << 20)
            #expect(f.responseBodyTruncated)
            #expect(f.bytesReceived == 3 << 20)
            #expect(!f.requestBodyTruncated)
        }
    }

    @Test func slowChunkedResponseStreamsFirstChunkEarly() async throws {
        try await ProxyFixture.run { fx in
            let r = try curl([
                "-x", fx.proxyURL, "-o", "/dev/null", "-w", "%{time_starttransfer} %{time_total}",
                "http://localhost:\(fx.origin.port)/slow",
            ])
            #expect(r.exitCode == 0, "\(r.stderr)")
            let times = r.text.split(separator: " ").compactMap { Double($0) }
            try #require(times.count == 2, "\(r.text)")
            #expect(times[0] < 0.4)
            #expect(times[1] >= 0.5)
            let f = try await waitForFlow(fx.store) { $0.state == .completed }
            #expect(try f.responseBody?.load() == Data("firstsecond".utf8))
        }
    }

    @Test func unreachableOriginReturns502() async throws {
        try await ProxyFixture.run { fx in
            let r = try curl(["-x", fx.proxyURL, "-w", "\n%{http_code}", "http://localhost:1/"])
            #expect(r.exitCode == 0, "\(r.stderr)")
            #expect(r.text.hasSuffix("\n502"))
            #expect(r.text.contains("无法连接"))
            #expect(r.text.contains("localhost:1"))
            let failed = try await waitForFlow(fx.store) {
                if case .failed = $0.state { true } else { false }
            }
            #expect(failed.host == "localhost")
            #expect(failed.port == 1)

            let next = try curl(["-x", fx.proxyURL, "http://localhost:\(fx.origin.port)/hello"])
            #expect(next.exitCode == 0, "\(next.stderr)")
            #expect(next.text == "hello")
        }
    }

    @Test func websocketUpgradeIsRelayedRaw() async throws {
        try await ProxyFixture.run { fx in
            let client = try await RawClient.connect(port: fx.proxyPort)
            let p = fx.origin.port
            try await client.send(
                "GET http://localhost:\(p)/ws HTTP/1.1\r\nHost: localhost:\(p)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
            let head = try await client.receive(until: "\r\n\r\n")
            #expect(head.contains("101"))
            // Sent by the origin in the same segment as the 101: it was buffered in the proxy's
            // response decoder and must be handed on when the decoder is removed.
            #expect(try await client.receive(until: TestOriginServer.wsGreeting) == TestOriginServer.wsGreeting)
            try await client.send("ping")
            #expect(try await client.receive(until: "ping", timeout: .seconds(2)) == "ping")
            try await client.close()

            let f = try await waitForFlow(fx.store) { $0.path == "/ws" && $0.state == .completed }
            #expect(f.statusCode == 101)
            #expect(f.note == "已升级为 WebSocket")
        }
    }

    @Test func concurrentConnectionsShareClientLookupScans() async throws {
        let scans = OSAllocatedUnfairLock(initialState: (calls: 0, ports: 0))
        let lookup = ProcessLookup(
            lookup: { _, _ in nil },
            lookupAll: { ports, _ in
                scans.withLock {
                    $0.calls += 1
                    $0.ports += ports.count
                }
                Thread.sleep(forTimeInterval: 0.02)  // a scan takes a while; arrivals queue meanwhile
                return Dictionary(uniqueKeysWithValues: ports.map { ($0, ClientApp(pid: 1, name: "batched")) })
            })
        try await ProxyFixture.run(processLookup: lookup) { fx in
            let urls = (0..<20).map { "http://localhost:\(fx.origin.port)/hello?i=\($0)" }
            let r = try curl(["-x", fx.proxyURL, "-Z", "--parallel-immediate", "--parallel-max", "20"] + urls)
            #expect(r.exitCode == 0, "\(r.stderr)")
            #expect(r.text == String(repeating: "hello", count: 20))
            try await waitUntil("20 completed flows with their client filled in") {
                let flows = fx.store.allFlows()
                return flows.count == 20 && flows.allSatisfy { $0.state == .completed && $0.client?.name == "batched" }
            }
            let (calls, ports) = scans.withLock { ($0.calls, $0.ports) }
            #expect(ports == 20)  // one connection per transfer, each looked up exactly once
            #expect(calls <= 5, "\(calls) scans for 20 connections")
        }
    }

    @Test func earlyResponseDuringUploadDoesNotHang() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString)")
        try Data(repeating: 0x62, count: 8 << 20).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try await ProxyFixture.run { fx in
            let started = ContinuousClock.now
            // "Expect:" off, so curl uploads right away instead of waiting for a 100 Continue.
            let r = try curl([
                "-x", fx.proxyURL, "-H", "Expect:", "--data-binary", "@\(file.path)", "-w", "\n%{http_code}",
                "http://localhost:\(fx.origin.port)/early413",
            ])
            #expect(ContinuousClock.now - started < .seconds(5), "\(r.stderr)")
            #expect(r.text.hasSuffix("\n413"), "\(r.text.suffix(100)) \(r.stderr)")
            let f = try await waitForFlow(fx.store) { $0.path == "/early413" && $0.state == .completed }
            #expect(f.statusCode == 413)

            let next = try curl(["-x", fx.proxyURL, "http://localhost:\(fx.origin.port)/hello"])
            #expect(next.text == "hello", "\(next.stderr)")
        }
    }

    @Test func earlyNonKeepAliveResponseClosesUnfinishedUpload() async throws {
        try await ProxyFixture.run { fx in
            let client = try await RawClient.connect(port: fx.proxyPort)
            let p = fx.origin.port
            // Announce 8 MiB but send only a little: the upload is still running when the
            // origin answers 413 + Connection: close.
            try await client.send(
                "POST http://localhost:\(p)/early413 HTTP/1.1\r\nHost: localhost:\(p)\r\nContent-Length: 8388608\r\n\r\n"
                    + String(repeating: "b", count: 65536))
            let response = try await client.receive(until: "too large")
            #expect(response.hasPrefix("HTTP/1.1 413"))
            try await client.waitUntilClosed(timeout: .seconds(2))
            try await client.close()

            let f = try await waitForFlow(fx.store) { $0.path == "/early413" && $0.state == .completed }
            #expect(f.statusCode == 413)
        }
    }

    @Test func productNameComesFromConfiguration() async throws {
        try await ProxyFixture.run(configure: { $0.productName = "测试代理" }) { fx in
            let page = try curl(["http://127.0.0.1:\(fx.proxyPort)/"])
            #expect(page.text == "测试代理 代理正在运行")
            let failure = try curl(["-x", fx.proxyURL, "http://localhost:1/"])
            #expect(failure.text.hasPrefix("测试代理：无法连接 localhost:1（"))
        }
    }

    @Test func portInUseFallsBackToNextPort() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let blocker = try await occupyPortWithFreeSuccessor(group: group)
        let occupied = try #require(blocker.localAddress?.port)
        var configuration = ProxyConfiguration()
        configuration.port = occupied
        let server = try makeServer(configuration)
        do {
            try await server.start()
            #expect(server.boundPort == occupied + 1)
        } catch {
            Issue.record(error)
        }
        try await server.stop()
        try await blocker.close().get()
        try await group.shutdownGracefully()
    }

    @Test func allPortsInUseThrowsPortUnavailable() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let blocker = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
        var configuration = ProxyConfiguration()
        configuration.port = try #require(blocker.localAddress?.port)
        configuration.portFallbackCount = 0
        let server = try makeServer(configuration)
        await #expect(throws: ProxyServerError.portUnavailable) { try await server.start() }
        #expect(server.boundPort == nil)
        try await blocker.close().get()
        try await group.shutdownGracefully()
    }

    @Test func directRequestToProxyShowsRunningPage() async throws {
        try await ProxyFixture.run { fx in
            let r = try curl(["http://127.0.0.1:\(fx.proxyPort)/"])
            #expect(r.exitCode == 0, "\(r.stderr)")
            #expect(r.text.contains("ProxyWoman 代理正在运行"))
            #expect(fx.store.allFlows().isEmpty)
        }
    }

    @Test(arguments: [
        ("GET", "/", 200, "Fixture 代理正在运行"),
        ("OPTIONS", "*", 400, "不支持的请求（OPTIONS *）"),
    ])
    func locallyAnsweredUpgradeDeliversCompleteResponseThenCloses(
        method: String, target: String, status: Int, body: String
    ) async throws {
        try await ProxyFixture.run(configure: { $0.productName = "Fixture" }, processLookup: .none) { fx in
            let client = try await RawClient.connect(port: fx.proxyPort)
            do {
                // Following bytes arrive in the same write. The Upgrade request stops the HTTP
                // decoder, so a local answer must close instead of leaving that input hanging.
                try await client.send(
                    "\(method) \(target) HTTP/1.1\r\nHost: local.test\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n"
                        + "GET /following HTTP/1.1\r\nHost: local.test\r\n\r\n")
                let head = try await client.receive(until: "\r\n\r\n")
                #expect(head.hasPrefix("HTTP/1.1 \(status) "))
                #expect(head.lowercased().contains("content-length: \(body.utf8.count)\r\n"))
                #expect(head.lowercased().contains("connection: close\r\n"))
                #expect(try await client.receive(until: body) == body)
                try await client.waitUntilClosed(timeout: .seconds(1))
                #expect(fx.store.allFlows().isEmpty)
            } catch {
                try? await client.close()
                throw error
            }
            try await client.close()
        }
    }

    @Test func ordinaryLocalResponsesStillServePipelinedKeepAliveRequests() async throws {
        try await ProxyFixture.run(configure: { $0.productName = "Fixture" }, processLookup: .none) { fx in
            let client = try await RawClient.connect(port: fx.proxyPort)
            let body = "Fixture 代理正在运行"
            do {
                try await client.send(
                    "GET /first HTTP/1.1\r\nHost: local.test\r\n\r\n"
                        + "GET /second HTTP/1.1\r\nHost: local.test\r\nConnection: close\r\n\r\n")
                let first = try await client.receive(until: "\r\n\r\n")
                #expect(first.hasPrefix("HTTP/1.1 200 "))
                #expect(!first.lowercased().contains("connection: close\r\n"))
                #expect(try await client.receive(until: body) == body)
                let second = try await client.receive(until: "\r\n\r\n")
                #expect(second.hasPrefix("HTTP/1.1 200 "))
                #expect(second.lowercased().contains("connection: close\r\n"))
                #expect(try await client.receive(until: body) == body)
                try await client.waitUntilClosed(timeout: .seconds(1))
                #expect(fx.store.allFlows().isEmpty)
            } catch {
                try? await client.close()
                throw error
            }
            try await client.close()
        }
    }

    private func makeServer(_ configuration: ProxyConfiguration) throws -> ProxyServer {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("proxycore-tests-\(UUID().uuidString)")
        return ProxyServer(
            configuration: configuration, certificateAuthority: try CertificateAuthority.generate(),
            store: FlowStore(bodyDirectory: directory), passthrough: PassthroughRegistry(), processLookup: .none)
    }

    /// Binds 127.0.0.1:p such that p+1 is (at this moment) free, so the fallback lands on p+1.
    /// p is picked below the ephemeral range (49152+): the OS hands those out roughly in order to
    /// the sockets of tests running in parallel, which could take p+1 right after the probe.
    private func occupyPortWithFreeSuccessor(group: EventLoopGroup) async throws -> Channel {
        for _ in 0..<50 {
            let port = Int.random(in: 20_000..<40_000)
            guard let blocker = try? await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: port).get()
            else { continue }
            if let probe = try? await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: port + 1).get() {
                try await probe.close().get()
                return blocker
            }
            try await blocker.close().get()
        }
        throw WaitTimeout(description: "no port p with a free p+1 found")
    }
}

private struct TargetCase: Sendable, CustomTestStringConvertible {
    let uri: String
    let host: String
    let port: Int
    let originForm: String
    let flowHost: String
    var testDescription: String { uri }
}

private let targetCases: [TargetCase] = [
    TargetCase(uri: "http://LocalHost:8080/a/b?q=1", host: "LocalHost", port: 8080, originForm: "/a/b?q=1", flowHost: "localhost"),
    TargetCase(uri: "http://example.com", host: "example.com", port: 80, originForm: "/", flowHost: "example.com"),
    TargetCase(uri: "http://example.com?x=1", host: "example.com", port: 80, originForm: "/?x=1", flowHost: "example.com"),
    TargetCase(uri: "http://user:pw@example.com:81/p#frag", host: "example.com", port: 81, originForm: "/p", flowHost: "example.com"),
    TargetCase(uri: "http://[::1]:9000/x", host: "::1", port: 9000, originForm: "/x", flowHost: "[::1]"),
]

@Test(.productionChinese, arguments: targetCases)
private func absoluteFormTargetIsParsed(testCase: TargetCase) throws {
    let target = try #require(RequestTarget(absoluteForm: testCase.uri))
    #expect(target.host == testCase.host)
    #expect(target.port == testCase.port)
    #expect(target.originForm == testCase.originForm)
    #expect(FlowRecorder.flowHost(target.host) == testCase.flowHost)
}

@Test(.productionChinese, arguments: ["/", "*", "example.com:443", "http://", "http://host:99999/", "http://[::1/x", "ftp://host/"])
private func invalidAbsoluteFormIsRejected(uri: String) {
    #expect(RequestTarget(absoluteForm: uri) == nil)
}

/// Real proxy codecs and handler, with synthetic byte channels on one embedded loop.
private func withMetadataPipeline(
    connectionFails: Bool = false,
    connectionFactory: ProxyHandler.ConnectionFactory? = nil,
    _ body: (EmbeddedChannel, EmbeddedChannel, FlowStore) throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pool = NIOThreadPool(numberOfThreads: 1)
    pool.start()
    let result = Result {
        let store = FlowStore(bodyDirectory: directory)
        let loop = EmbeddedEventLoop()
        let upstream = EmbeddedChannel(loop: loop)
        try upstream.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 12346)).wait()
        defer { _ = try? upstream.finish() }
        let environment = ProxyEnvironment(
            configuration: ProxyConfiguration(),
            recording: FlowRecording(store: store, isEnabled: ManagedAtomic(true)),
            tls: TLSInterception(certificateAuthority: try CertificateAuthority.generate()),
            passthrough: PassthroughRegistry(),
            clientLookup: ClientLookupBatcher(processLookup: .none, threadPool: pool))
        let owner = ProxyHandler(mode: .forwardProxy, environment: environment,
                                 connectionFactory: connectionFactory ?? { _, _, eventLoop in
                                     connectionFails ? eventLoop.makeFailedFuture(ChannelError.ioOnClosedChannel)
                                         : eventLoop.makeSucceededFuture(upstream)
                                 })
        let client = EmbeddedChannel(handlers: [HTTPMessageTranslation.responseEncoder(), HTTP1TransferCodingFramer<HTTPResponseHead>(),
                                              ByteToMessageHandler(HTTPRequestDecoder()), owner], loop: loop)
        defer { _ = try? client.finish() }
        try client.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 12345)).wait()
        try body(client, upstream, store)
    }
    try await pool.shutdownGracefully()
    try result.get()
}

private func drainMetadataBytes(_ channel: EmbeddedChannel) throws -> String {
    var result = ""
    while let data = try channel.readOutbound(as: IOData.self) {
        switch data {
        case .byteBuffer(var buffer): result += buffer.readString(length: buffer.readableBytes) ?? ""
        case .fileRegion: Issue.record("unexpected file region")
        }
    }
    return result
}
