import CertKit
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOHTTP2
import NIOHPACK
import NIOTLS
import NIOSSL
import Testing
@testable import ProxyCore

@Suite(.productionChinese) struct HTTP2NegotiationTests {
    @Test(arguments: ["h2", "http/1.1", ""]) func selectionWaitsForConfiguratorAndPreservesFirstBytes(_ token: String) throws {
        let channel = EmbeddedChannel()
        let barrier = channel.eventLoop.makePromise(of: Void.self)
        let selected = HTTP2Pipeline.installNegotiation(on: channel) { protocolID, channel in
            #expect(protocolID == (token == "h2" ? .http2 : .http1))
            return barrier.futureResult
        }
        let ready = NIOLockedValueBox(false)
        let selection = try selected.wait().readyProtocol
        selection.whenSuccess { _ in ready.withLockedValue { $0 = true } }
        channel.pipeline.fireUserInboundEventTriggered(TLSUserEvent.handshakeCompleted(negotiatedProtocol: token.isEmpty ? nil : token))
        try channel.writeInbound(ByteBuffer(string: "first-data"))
        #expect(!ready.withLockedValue { $0 })
        #expect(try channel.readInbound(as: ByteBuffer.self) == nil)
        barrier.succeed(())
        channel.embeddedEventLoop.run()
        #expect(ready.withLockedValue { $0 })
        #expect(try channel.readInbound(as: ByteBuffer.self)?.getString(at: 0, length: 10) == "first-data")
        _ = try channel.finish()
    }

    @Test func unknownALPNAndConfiguratorFailureFailReadiness() throws {
        for token in ["unexpected", "h2"] {
            let channel = EmbeddedChannel()
            let result = HTTP2Pipeline.installNegotiation(on: channel) { _, channel in
                channel.eventLoop.makeFailedFuture(FixtureError.setup)
            }
            channel.pipeline.fireUserInboundEventTriggered(TLSUserEvent.handshakeCompleted(negotiatedProtocol: token))
            channel.embeddedEventLoop.run()
            do { _ = try result.wait().readyProtocol.wait(); Issue.record("Readiness incorrectly succeeded") }
            catch { if token == "h2" { #expect(error is FixtureError) } else { #expect(error is HTTP2TransportError) } }
            _ = try? channel.finish()
        }
    }

    @Test func handshakeErrorIsPreservedAndCloseBeforeNegotiationFails() throws {
        let channel = EmbeddedChannel()
        let result = HTTP2Pipeline.installNegotiation(on: channel) { _, channel in channel.eventLoop.makeSucceededVoidFuture() }
        channel.pipeline.fireErrorCaught(FixtureError.setup)
        do { _ = try result.wait().readyProtocol.wait(); Issue.record("Readiness incorrectly succeeded") }
        catch { #expect(error is FixtureError) }
        _ = try? channel.finish()
        let closed = EmbeddedChannel()
        let closedResult = HTTP2Pipeline.installNegotiation(on: closed) { _, channel in channel.eventLoop.makeSucceededVoidFuture() }
        _ = try closed.finish()
        #expect(throws: (any Error).self) { try closedResult.wait().readyProtocol.wait() }
    }

    @Test(arguments: [["h2", "http/1.1"], ["http/1.1"], []])
    func realTLSSelectionAndResponse(_ offers: [String]) async throws {
        try await HTTP2TestOrigin.withOrigin(protocols: offers) { origin in
            let client = try await HTTP2TestClient.connect(origin: origin)
            do {
                #expect(client.selected == (offers.first == "h2" ? .http2 : .http1))
                let response = try await client.request()
                #expect(response.status == 200)
                #expect(response.body == "fixture-body")
                #expect(response.headers["set-cookie"] == ["a=1", "b=2"])
                #expect(response.trailers?["x-finish"] == ["done"])
                #expect(origin.counts.connections == 1)
                #expect(origin.counts.requests == 1)
                if client.selected == .http2 { #expect(origin.counts.streamIDs == [1]) }
                try await client.stop()
            } catch { try? await client.stop(); throw error }
        }
    }

    @Test func upgradePolicyAndTrustRootGenerationsDoNotReuseAutomaticContext() async throws {
        try await HTTP2TestOrigin.withOrigin(protocols: ["h2", "http/1.1"]) { origin in
            let tls = TLSInterception(certificateAuthority: origin.ca, applicationProtocols: ["h2", "http/1.1"])
            for policy in [UpstreamProtocolPolicy.automatic, .http1OnlyUpgrade, .automatic] {
                let client = try await HTTP2TestClient.connect(origin: origin, tls: tls, policy: policy)
                #expect(client.selected == (policy == .automatic ? .http2 : .http1))
                try await client.stop()
            }
            let other = try CertificateAuthority.generate(commonName: "Untrusted fixture CA")
            let badRoots = NIOSSLTrustRoots.certificates([try NIOSSLCertificate(bytes: other.rootCertificateDER, format: .der)])
            do {
                let bad = try await HTTP2TestClient.connect(origin: origin, tls: tls, roots: badRoots)
                try await bad.stop()
                Issue.record("Invalid certificate accepted after cache hit")
            } catch { #expect(TLSInterception.certificateFailureReason(error) != nil) }
            let restored = try await HTTP2TestClient.connect(origin: origin, tls: tls)
            #expect(restored.selected == .http2)
            try await restored.stop()
        }
    }

    @Test func productionDefaultNegotiatesHTTP2() async throws {
        try await HTTP2TestOrigin.withOrigin(protocols: ["h2", "http/1.1"]) { origin in
            let client = try await HTTP2TestClient.connect(origin: origin, tls: TLSInterception(certificateAuthority: origin.ca))
            #expect(client.selected == .http2)
            try await client.stop()
        }
    }
    @Test func realHandshakeAndFirstSettingsAreBufferedUntilConfiguratorCompletes() async throws {
        try await HTTP2TestOrigin.withOrigin(protocols: ["h2"]) { origin in
            let loop = origin.channel.eventLoop
            let barrier = loop.makePromise(of: Void.self)
            let started = loop.makePromise(of: Void.self)
            let bytes = loop.makePromise(of: Void.self)
            let completed = NIOLockedValueBox(false)
            let connecting = Task {
                let client = try await HTTP2TestClient.connect(origin: origin, barrier: barrier.futureResult,
                    configurationStarted: started, firstBytes: bytes)
                completed.withLockedValue { $0 = true }
                return client
            }
            try await started.futureResult.get()
            try await bytes.futureResult.get()
            #expect(!completed.withLockedValue { $0 })
            barrier.succeed(())
            let client = try await connecting.value
            do {
                #expect(try await client.request().body == "fixture-body")
                try await client.stop()
            } catch { try? await client.stop(); throw error }
        }
    }

    @Test func closeWhileConfiguratorIsPendingCannotBecomeReadyLater() throws {
        let channel = EmbeddedChannel()
        let barrier = channel.eventLoop.makePromise(of: Void.self)
        let negotiation = try HTTP2Pipeline.installNegotiation(on: channel) { _, _ in barrier.futureResult }.wait()
        channel.pipeline.fireUserInboundEventTriggered(TLSUserEvent.handshakeCompleted(negotiatedProtocol: "h2"))
        try channel.writeInbound(ByteBuffer(string: "buffered"))
        _ = try channel.finish()
        #expect(throws: (any Error).self) { try negotiation.readyProtocol.wait() }
        barrier.succeed(())
        channel.embeddedEventLoop.run()
        #expect(throws: (any Error).self) { try negotiation.readyProtocol.wait() }
    }

    @Test func realUnknownALPNAndSetupFailureKeepOriginalError() async throws {
        for unknown in [true, false] {
            try await HTTP2TestOrigin.withOrigin(protocols: unknown ? ["unexpected"] : ["h2"]) { origin in
                let tls = TLSInterception(certificateAuthority: origin.ca, applicationProtocols: unknown ? ["unexpected"] : ["h2"])
                do {
                    let client = try await HTTP2TestClient.connect(origin: origin, tls: tls, configurationFails: !unknown)
                    try await client.stop()
                    Issue.record("Unexpectedly ready")
                } catch {
                    if unknown { #expect(error is HTTP2TransportError) }
                    else { #expect(error is FixtureError) }
                }
            }
        }
    }

    @Test func tunneledIPVerificationIsRetainedAcrossCachePolicies() async throws {
        let origin = try await HTTP2TestOrigin.start(protocols: ["h2", "http/1.1"], certificateHost: "127.0.0.1")
        do {
            let tls = TLSInterception(certificateAuthority: origin.ca, applicationProtocols: ["h2", "http/1.1"])
            for tunneled in [false, true, false] {
                let client = try await HTTP2TestClient.connect(origin: origin, tls: tls, verificationHost: "127.0.0.1", tunneled: tunneled)
                #expect(client.selected == .http2)
                try await client.stop()
            }
            do {
                let client = try await HTTP2TestClient.connect(origin: origin, tls: tls, policy: .http1OnlyUpgrade,
                    verificationHost: "127.0.0.2", tunneled: true)
                try await client.stop()
                Issue.record("Wrong IP SAN accepted")
            } catch { #expect(TLSInterception.certificateFailureReason(error) != nil) }
            try await origin.stop()
        } catch { try? await origin.stop(); throw error }
    }

    @Test func initialEndStreamAndOriginalHeadersAreCapturedBeforeCodecSynthesis() async throws {
        try await HTTP2TestOrigin.withOrigin(protocols: ["h2"]) { origin in
            let client = try await HTTP2TestClient.connect(origin: origin)
            do {
                let headers = HPACKHeaders([ (":method", "GET"), (":scheme", "https"), (":authority", "localhost"),
                    (":path", "/"), ("cookie", "a=1"), ("cookie", "b=2") ])
                #expect(try await client.rawRequest(headers: headers).body == "fixture-body")
                #expect(origin.counts.streamIDs == [1])
                #expect(origin.counts.initialEndStreams == [true])
                #expect(origin.counts.authorities == ["localhost"])
                #expect(origin.counts.originalHeaders.first?["cookie"] == ["a=1", "b=2"])
                #expect(origin.counts.originalHeaders.first?["host"] == [])
                #expect(origin.counts.originalHeaders.first?["transfer-encoding"] == [])
                try await client.stop()
            } catch { try? await client.stop(); throw error }
        }
    }

    @Test func invalidAuthorityResetsOnlyItsStream() async throws {
        try await HTTP2TestOrigin.withOrigin(protocols: ["h2"]) { origin in
            let client = try await HTTP2TestClient.connect(origin: origin)
            do {
                let headers = HPACKHeaders([ (":method", "GET"), (":scheme", "https"), (":authority", "user@localhost"), (":path", "/") ])
                do { _ = try await client.rawRequest(headers: headers); Issue.record("Invalid authority accepted") }
                catch { #expect(error is NIOHTTP2Errors.StreamClosed) }
                #expect(origin.counts.requests == 0)
                #expect(try await client.request().status == 200)
                #expect(origin.counts.streamIDs == [3])
                #expect(origin.counts.connections == 1)
                try await client.stop()
            } catch { try? await client.stop(); throw error }
        }
    }

    @Test func streamReservationsAreBoundedAndReleasedExactlyOnce() async throws {
        try await HTTP2TestOrigin.withOrigin(protocols: ["h2"]) { origin in
            var limits = HTTPTransportLimits(); limits.upstreamStreams = 1
            let client = try await HTTP2TestClient.connect(origin: origin, limits: limits)
            do {
                try await client.channel.eventLoop.flatSubmit {
                    let session = client.state.value.session!
                    let sink = HTTP2TestClient.Sink(loop: client.channel.eventLoop)
                    sink.promise.futureResult.whenFailure { _ in }
                    return session.openStream(responseSink: sink).assumeIsolated().flatMap { lease in
                        #expect(session.availableStreams == 0)
                        #expect((lease as? HTTP2UpstreamLease)?.streamID == nil)
                        return session.openStream(responseSink: sink).assumeIsolated().map { _ in
                            Issue.record("Exceeded stream cap")
                        }.flatMapError { error in
                            #expect(error is HTTPTransportError)
                            lease.cancel(error: FixtureError.setup)
                            lease.release(reusable: true)
                            #expect(session.availableStreams == 1)
                            return client.channel.eventLoop.makeSucceededVoidFuture()
                        }.nonisolated()
                    }.nonisolated()
                }.get()
                #expect(try await client.request().status == 200)
                try await client.stop()
            } catch { try? await client.stop(); throw error }
        }
    }

    @Test func controlObserverUpdatesStateBeforeForwarding() throws {
        let channel = EmbeddedChannel()
        try channel.connect(to: .init(ipAddress: "127.0.0.1", port: 1)).wait()
        let route = UpstreamRoute(scheme: "https", host: "localhost", port: 443, policy: .automatic)
        let mux = HTTP2StreamMultiplexer(mode: .client, channel: channel, inboundStreamInitializer: nil)
        let session = HTTP2Session(channel: channel, route: route, limits: .init(), multiplexer: mux)
        let checker = ControlOrderCheck(session: session)
        try channel.pipeline.syncOperations.addHandlers([HTTP2ConnectionObserver(session: session), checker])
        try channel.writeInbound(HTTP2Frame(streamID: .rootStream, payload: .settings(.settings([
            .init(parameter: .maxConcurrentStreams, value: 0),
        ]))))
        #expect(checker.capacityWhenSettingsForwarded == 0)
        try channel.writeInbound(HTTP2Frame(streamID: .rootStream, payload: .goAway(lastStreamID: .rootStream, errorCode: .noError, opaqueData: nil)))
        #expect(checker.drainingWhenGoAwayForwarded == true)
        #expect(!channel.isActive)
        _ = try channel.finish(acceptAlreadyClosed: true)
    }

    @Test func upstreamLeaseExposesOriginalInterimFinalAndTrailingMetadata() async throws {
        var response = HTTP2TestOrigin.Response()
        response.informational = HTTPHeaders([("link", "</style.css>")])
        try await HTTP2TestOrigin.withOrigin(protocols: ["h2"], response: response) { origin in
            let client = try await HTTP2TestClient.connect(origin: origin)
            do {
                let received = try await client.request()
                #expect(received.snapshots.map(\.kind) == [.informational, .initial, .trailers])
                #expect(received.snapshots.map { Int($0.streamID) } == [1, 1, 1])
                #expect(received.snapshots.map(\.endStream) == [false, false, true])
                #expect(received.snapshots[1].regularHeaders["transfer-encoding"].isEmpty)
                #expect(received.snapshots[1].regularHeaders["set-cookie"] == ["a=1", "b=2"])
                #expect(received.snapshots[2].regularHeaders["x-finish"] == ["done"])
                try await client.stop()
            } catch { try? await client.stop(); throw error }
        }
    }

    @Test(arguments: [false, true]) func outboundHeaderBudgetRejectsBeforeOpeningWireStream(bytes: Bool) async throws {
        try await HTTP2TestOrigin.withOrigin(protocols: ["h2"]) { origin in
            var limits = HTTPTransportLimits()
            if bytes { limits.headerBytes = 256 } else { limits.headerFields = 8 }
            let client = try await HTTP2TestClient.connect(origin: origin, limits: limits)
            do {
                var headers = HTTPHeaders([("host", "localhost")])
                if bytes { headers.add(name: "x-large", value: String(repeating: "x", count: 512)) }
                else { for index in 0..<8 { headers.add(name: "x-\(index)", value: "value") } }
                do { _ = try await client.request(headers: headers); Issue.record("Outbound header budget ignored") }
                catch { #expect(error is HTTP2TransportError) }
                #expect(origin.counts.requests == 0)
                #expect(try await client.request().status == 200)
                try await client.stop()
            } catch { try? await client.stop(); throw error }
        }
    }

    @Test func inboundHeaderFieldBudgetFailsOnlyTheResponseStream() async throws {
        var response = HTTP2TestOrigin.Response()
        for index in 0..<8 { response.headers.add(name: "x-\(index)", value: "value") }
        try await HTTP2TestOrigin.withOrigin(protocols: ["h2"], response: response) { origin in
            var limits = HTTPTransportLimits(); limits.headerFields = 8
            let client = try await HTTP2TestClient.connect(origin: origin, limits: limits)
            do {
                do { _ = try await client.request(); Issue.record("Inbound header budget ignored") }
                catch { #expect(error is HTTP2TransportError) }
                #expect(client.channel.isActive)
                try await client.stop()
            } catch { try? await client.stop(); throw error }
        }
    }

    @Test func negotiationInstallationFailureDoesNotLeaveReadinessPending() throws {
        let channel = EmbeddedChannel()
        _ = try channel.finish()
        let installation = HTTP2Pipeline.installNegotiation(on: channel) { _, channel in channel.eventLoop.makeSucceededVoidFuture() }
        #expect(throws: (any Error).self) { try installation.wait() }
    }

    @Test func streamScopedNIOErrorDoesNotCloseTheParent() throws {
        let channel = EmbeddedChannel()
        try channel.connect(to: .init(ipAddress: "127.0.0.1", port: 1)).wait()
        let checker = ProtocolErrorCapture()
        try channel.pipeline.syncOperations.addHandlers([HTTP2ConnectionObserver(session: nil), checker])
        channel.pipeline.fireErrorCaught(NIOHTTP2Errors.streamError(streamID: 1, baseError: FixtureError.setup))
        #expect(channel.isActive)
        #expect((checker.error as? NIOHTTP2Errors.StreamError)?.baseError is FixtureError)
        _ = try channel.finish(acceptAlreadyClosed: true)
    }

    @Test func responseInitialEndStreamAndRequestTrailerProvenanceAreExact() async throws {
        var response = HTTP2TestOrigin.Response(); response.headersOnly = true
        try await HTTP2TestOrigin.withOrigin(protocols: ["h2"], response: response) { origin in
            let client = try await HTTP2TestClient.connect(origin: origin)
            do {
                let received = try await client.request()
                #expect(received.body.isEmpty)
                #expect(received.snapshots.count == 1)
                #expect(received.snapshots.first?.kind == .initial)
                #expect(received.snapshots.first?.endStream == true)
                let headers = HPACKHeaders([ (":method", "POST"), (":scheme", "https"), (":authority", "[::1]:8443"), (":path", "/") ])
                let trailers = HPACKHeaders([ ("x-check", "one"), ("x-check", "two") ])
                #expect(try await client.rawRequest(headers: headers, body: "data", trailers: trailers).status == 200)
                #expect(origin.counts.originalTrailers.first?["x-check"] == ["one", "two"])
                #expect(origin.counts.authorities == ["localhost", "[::1]:8443"])
                #expect(origin.counts.initialEndStreams == [true, false])
                try await client.stop()
            } catch { try? await client.stop(); throw error }
        }
    }

    @Test func concurrentStreamsShareOneConnectionAndCompleteBehindBarrier() async throws {
        try await withHTTP2ControlLoop { control in
            let barrier = control.makePromise(of: Void.self)
            let observed = control.makePromise(of: Void.self)
            var response = HTTP2TestOrigin.Response()
            response.barrier = barrier.futureResult
            response.requestsObserved = observed
            response.requestCountTarget = 2
            try await HTTP2TestOrigin.withOrigin(protocols: ["h2"], response: response) { origin in
                let client = try await HTTP2TestClient.connect(origin: origin)
                do {
                    async let first = client.request()
                    async let second = client.request()
                    try await observed.futureResult.get()
                    #expect(origin.counts.connections == 1)
                    #expect(origin.counts.streamIDs.sorted() == [1, 3])
                    barrier.succeed(())
                    let results = try await [first, second]
                    #expect(results.map(\.status) == [200, 200])
                    try await client.stop()
                } catch { barrier.succeed(()); try? await client.stop(); throw error }
            }
        }
    }

    @Test func goAwayRejectsNewLeasesWhileAcceptedStreamDrains() async throws {
        try await withHTTP2ControlLoop { control in
            let barrier = control.makePromise(of: Void.self)
            let observed = control.makePromise(of: Void.self)
            var response = HTTP2TestOrigin.Response()
            response.barrier = barrier.futureResult; response.requestsObserved = observed
            try await HTTP2TestOrigin.withOrigin(protocols: ["h2"], response: response) { origin in
                let client = try await HTTP2TestClient.connect(origin: origin)
                do {
                    async let first = client.request()
                    try await observed.futureResult.get()
                    try await client.channel.eventLoop.flatSubmit {
                        let session = client.state.value.session!
                        session.receivedGoAway(lastStreamID: 1, errorCode: .noError)
                        #expect(session.isDraining)
                        #expect(client.channel.isActive)
                        let sink = HTTP2TestClient.Sink(loop: client.channel.eventLoop)
                        sink.promise.succeed(.init())
                        return session.openStream(responseSink: sink).assumeIsolated().map { _ in
                            Issue.record("GOAWAY accepted new lease")
                        }.flatMapError { error in
                            #expect(error is HTTP2TransportError)
                            return client.channel.eventLoop.makeSucceededVoidFuture()
                        }.nonisolated()
                    }.get()
                    barrier.succeed(())
                    #expect(try await first.status == 200)
                    try await client.channel.closeFuture.get()
                    #expect(!client.channel.isActive)
                    try await client.stop()
                } catch { barrier.succeed(()); try? await client.stop(); throw error }
            }
        }
    }

    @Test func goAwayBeforeFirstWriteDoesNotInventAStreamID() async throws {
        try await HTTP2TestOrigin.withOrigin(protocols: ["h2"]) { origin in
            let client = try await HTTP2TestClient.connect(origin: origin)
            do {
                do {
                    try await client.channel.eventLoop.flatSubmit {
                        let session = client.state.value.session!
                        let sink = HTTP2TestClient.Sink(loop: client.channel.eventLoop)
                        session.openStream(responseSink: sink).assumeIsolated().whenSuccess { lease in
                            #expect((lease as? HTTP2UpstreamLease)?.streamID == nil)
                            session.receivedGoAway(lastStreamID: .rootStream, errorCode: .noError)
                            lease.release(reusable: true)
                        }
                        return sink.promise.futureResult.map { _ in () }
                    }.get()
                    Issue.record("Unsent lease survived GOAWAY")
                } catch {
                    guard case HTTP2TransportError.draining = error else { Issue.record("Unexpected error: \(error)"); throw error }
                }
                #expect(origin.counts.requests == 0)
                try await client.stop()
            } catch { try? await client.stop(); throw error }
        }
    }

}

enum FixtureError: Error { case setup }


private final class ControlOrderCheck: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame
    let session: HTTP2Session
    var capacityWhenSettingsForwarded: Int?
    var drainingWhenGoAwayForwarded: Bool?
    init(session: HTTP2Session) { self.session = session }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data).payload {
        case .settings: capacityWhenSettingsForwarded = session.availableStreams
        case .goAway: drainingWhenGoAwayForwarded = session.isDraining
        default: break
        }
    }
}


private final class ProtocolErrorCapture: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame
    var error: Error?
    func errorCaught(context: ChannelHandlerContext, error: Error) { self.error = error }
}
