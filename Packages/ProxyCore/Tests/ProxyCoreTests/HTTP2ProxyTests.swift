import Darwin
import Foundation
import FlowStore
import NIOCore
import NIOHTTP1
import NIOHPACK
import NIOHTTP2
import Testing
@testable import ProxyCore

@Suite(.timeLimit(.minutes(1)), .productionChinese) struct HTTP2ProxyTests {
    // Actual raw CONNECT/TLS wire: the H1 adapter capability must not erase H1.0.
    @Test(arguments: ["unknown", "fixed", "empty", "head"])
    func http10ClientOfH2OriginPreservesWireCapability(kind: String) async throws {
        try await withHTTP2ControlLoop { loop in
        let releaseBody = loop.makePromise(of: Void.self)
        var released = false
        defer { if !released { releaseBody.succeed(()) } }
        var response = HTTP2TestOrigin.Response()
        response.bodyBarriersByPath["/old-client"] = releaseBody.futureResult
        response.trailers = HTTPHeaders([("x-late", "one"), ("x-late", "two")])
        if kind == "fixed" { response.headers.add(name: "content-length", value: "12") }
        if kind == "empty" { response.headersOnly = true; response.trailers = nil }
        if kind == "head" { response.headers.add(name: "content-length", value: "12"); response.trailers = nil }
        try await HTTP2TestOrigin.withOrigin(protocols: ["h2"], response: response) { origin in
            let fixture = try await HTTP2ProxyFixture.start(origin: origin)
            var client: HTTP2UpgradeClient?
            do {
                let raw = try await HTTP2UpgradeClient.connect(fixture: fixture, origin: origin, tls: true)
                client = raw
                let method = kind == "head" ? "HEAD" : "GET"
                try await raw.send(Array("\(method) /old-client HTTP/1.0\r\nHost: localhost:\(origin.port)\r\n\r\n".utf8))
                let head = try await raw.receive(until: "\r\n\r\n")
                releaseBody.succeed(()); released = true
                #expect(head.hasPrefix("HTTP/1.0 200"))
                #expect(!head.lowercased().contains("transfer-encoding:"))
                #expect(!head.lowercased().contains("x-late:"))
                if kind == "unknown" || kind == "fixed" {
                    #expect(String(decoding: try await raw.receive(count: 12), as: UTF8.self) == "fixture-body")
                }
                try await raw.channel.closeFuture.boundedGet()
                #expect(raw.remainingBytes().isEmpty)
                let flow = try await waitForFlow(fixture.store) { $0.path == "/old-client" && $0.completedAt != nil }
                #expect(flow.state == .completed)
                #expect(flow.transport.downstreamRequest == .http1_0)
                #expect(flow.transport.downstreamResponse == .http1_0)
                #expect(flow.transport.upstreamRequest == .http2)
                #expect(flow.transport.upstreamResponse == .http2)
                #expect(flow.responseTrailers.map(\.value) == ((kind == "unknown" || kind == "fixed") ? ["one", "two"] : []))
                if kind == "fixed" || kind == "head" { #expect(head.lowercased().contains("content-length: 12\r\n")) }
                if kind == "empty" { #expect(head.lowercased().contains("content-length: 0\r\n")) }
                try await raw.stop(); try await fixture.stop()
            } catch {
                if let client { try? await client.stop() }
                try? await fixture.stop(); throw error
            }
        }
        }
    }

    /// Removing either production ALPN adapter breaks its corresponding real CONNECT matrix.
    @Test(arguments: [false, true], [false, true])
    func fourRealTLSMatrices(downstreamH2: Bool, upstreamH2: Bool) async throws {
        try await HTTP2TestOrigin.withOrigin(protocols: upstreamH2 ? ["h2", "http/1.1"] : ["http/1.1"]) { origin in
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: downstreamH2) { fixture, client in
                #expect(client.selected == (downstreamH2 ? .http2 : .http1))
                var fields = HTTPHeaders([("host", "localhost:\(origin.port)"), ("x-order", "a"), ("x-order", "b"), ("transfer-encoding", "chunked")])
                if downstreamH2 { fields.remove(name: "transfer-encoding") }
                var clientStreamIDs: [String: Int] = [:]
                for path in ["/one?x=%2f", "/two"] {
                    let result = try await client.request(headers: fields, path: path, method: .POST,
                        body: "request-\u{0}payload", trailers: HTTPHeaders([("x-trailer", "a"), ("x-trailer", "b")]))
                    if let snapshot = result.snapshots.first { clientStreamIDs[path] = Int(snapshot.streamID) }
                    #expect(result.status == 200)
                    #expect(result.body == "fixture-body")
                    #expect(result.headers["set-cookie"] == ["a=1", "b=2"])
                    #expect(result.trailers?["x-finish"] == ["done"])
                }
                try await waitForCompletedFlows(fixture.store, atLeast: 2)
                let flows = fixture.store.allFlows()
                #expect(flows.count == 2)
                #expect(Set(flows.map(\.id)).count == 2)
                for flow in flows {
                    #expect(flow.state == .completed)
                    #expect(try flow.requestBody?.load() == Data("request-\u{0}payload".utf8))
                    #expect(try flow.responseBody?.load() == Data("fixture-body".utf8))
                    #expect(flow.requestHeaders.filter { $0.name == "x-order" }.map(\.value) == ["a", "b"])
                    #expect(flow.requestTrailers.map(\.value) == ["a", "b"])
                    #expect(flow.transport.downstreamRequest == (downstreamH2 ? .http2 : .http1_1))
                    #expect(flow.transport.downstreamResponse == (downstreamH2 ? .http2 : .http1_1))
                    #expect(flow.transport.upstreamRequest == (upstreamH2 ? .http2 : .http1_1))
                    #expect(flow.transport.upstreamResponse == (upstreamH2 ? .http2 : .http1_1))
                    #expect((flow.transport.downstreamStreamID != nil) == downstreamH2)
                    #expect(flow.transport.downstreamStreamID == clientStreamIDs[flow.path])
                    #expect((flow.transport.upstreamStreamID != nil) == upstreamH2)
                }
                if upstreamH2 {
                    #expect(Set(flows.compactMap { $0.transport.upstreamStreamID }) == Set(origin.counts.streamIDs))
                }
                #expect(fixture.lookups.withLock { $0 } == 1)
                #expect(origin.counts.connections == 1)
            }
        }
    }
    @Test func endpointNormalizationIncludesDefaultsAndParsedIPv6() {
        #expect(HTTP2StreamMetadataHandler.sameEndpoint("EXAMPLE.test", "example.test:0443", defaultPort: 443))
        #expect(HTTP2StreamMetadataHandler.sameEndpoint("[0:0:0:0:0:0:0:1]", "[::1]:443", defaultPort: 443))
        #expect(!HTTP2StreamMetadataHandler.sameEndpoint("[::1]:444", "[::1]", defaultPort: 443))
        #expect(!HTTP2StreamMetadataHandler.sameEndpoint("example.test", "other.test", defaultPort: 443))
        #expect(!HTTP2StreamMetadataHandler.sameEndpoint("[::invalid]", "[::invalid]", defaultPort: 443))
    }

    @Test func differentAuthorityFailsBeforeAcquiringAnyOrigin() async throws {
        try await HTTP2TestOrigin.withOrigin(protocols: ["h2"]) { origin in
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true) { fixture, client in
                let rejected = try await client.rawRequest(headers: headers(origin, authority: "other.test:443"))
                #expect(rejected.status == 421)
                #expect(origin.counts.connections == 0)
                #expect(fixture.upstreams.withLock { $0.count } == 0)
                let healthy = try await client.rawRequest(headers: headers(origin))
                #expect(healthy.status == 200)
                #expect(client.channel.isActive)
            }
        }
    }

    @Test(arguments: ["scheme", "path", "host", "connect", "star"])
    func malformedPseudoOrHostOnlyRejectsItsChild(kind: String) async throws {
        try await HTTP2TestOrigin.withOrigin(protocols: ["h2"]) { origin in
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true) { _, client in
                var fields = headers(origin, scheme: kind == "scheme" ? "http" : "https",
                    path: kind == "path" ? "/bad#fragment" : (kind == "star" ? "*" : "/"),
                    method: kind == "connect" ? "CONNECT" : "GET")
                if kind == "host" { fields.add(name: "host", value: "elsewhere.test") }
                do {
                    let invalid = try await client.rawRequest(headers: fields)
                    #expect(invalid.status >= 400)
                } catch { /* RST_STREAM is also an intentional child rejection. */ }
                #expect(origin.counts.requests == 0)
                let valid = try await client.rawRequest(headers: headers(origin, path: "*", method: "OPTIONS"))
                #expect(valid.status == 200)
                #expect(origin.counts.paths == ["*"])
            }
        }
    }

    @Test func originalFieldsAndInitialEndStreamSurviveCodecSynthesis() async throws {
        var response = HTTP2TestOrigin.Response()
        response.headersOnly = true; response.trailers = nil
        try await HTTP2TestOrigin.withOrigin(protocols: ["h2"], response: response) { origin in
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: false) { fixture, client in
                let result = try await client.request(headers: .init([("host", "localhost:\(origin.port)")]))
                #expect(result.status == 200)
                #expect(result.body.isEmpty)
                #expect(result.headers["content-length"] == ["0"])
                #expect(fixture.store.allFlows().first?.responseHeaders.map(\.name) == ["set-cookie", "set-cookie"])
            }
        }
        try await HTTP2TestOrigin.withOrigin(protocols: ["http/1.1"]) { origin in
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true) { fixture, client in
                var fields = headers(origin, path: "/%2F?X=%2f&X=2")
                fields.add(name: "x-original", value: "a")
                fields.add(name: "x-original", value: "b")
                let result = try await client.rawRequest(headers: fields)
                #expect(result.status == 200)
                #expect(origin.counts.requestHeaders.first?["content-length"] == ["0"])
                #expect(origin.counts.requestHeaders.first?["transfer-encoding"] == [])
                let flow = try #require(fixture.store.allFlows().first)
                #expect(flow.path == "/%2F?X=%2f&X=2")
                #expect(flow.requestHeaders.map(\.name) == ["x-original", "x-original"])
            }
        }
    }

    @Test(arguments: [false, true])
    func h2ReusedParentFailureIsNeverImplicitlyRetried(pipe: Bool) async throws {
        try await withHTTP2ControlLoop { loop in
            let seen = loop.makePromise(of: Void.self)
            let barrier = loop.makePromise(of: Void.self)
            var released = false
            defer { if !released { barrier.succeed(()) } }
            var response = HTTP2TestOrigin.Response()
            response.requestCountTarget = 2; response.requestsObserved = seen
            response.barriersByPath = ["/failure": barrier.futureResult]
            try await HTTP2TestOrigin.withOrigin(protocols: ["h2"], response: response) { origin in
                try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true) { fixture, client in
                    _ = try await client.rawRequest(headers: headers(origin, path: "/prime"))
                    let pending = Task { try await client.rawRequest(headers: headers(origin, path: "/failure")) }
                    try await seen.futureResult.get()
                    let parent = try #require(fixture.upstreams.withLock { $0.first })
                    try await parent.eventLoop.submit {
                        parent.pipeline.fireErrorCaught(IOError(errnoCode: pipe ? EPIPE : ECONNRESET, reason: "fixture"))
                    }.get()
                    barrier.succeed(()); released = true
                    let result = try await pending.value
                    #expect(result.status == 502)
                    #expect(origin.counts.connections == 1)
                    #expect(origin.counts.requests == 2)
                    #expect(fixture.upstreams.withLock { $0.count } == 1)
                    // The downstream response version is recorded once the writer accepted the 502 head.
                    _ = try await waitForFlow(fixture.store) { $0.path == "/failure" && $0.transport.downstreamResponse != nil }
                    let failed = fixture.store.allFlows().filter { $0.path == "/failure" }
                    #expect(failed.count == 1)
                    #expect(failed.first?.completedAt != nil)
                    #expect(failed.first?.transport.upstreamResponse == nil)
                    #expect(failed.first?.transport.downstreamResponse == .http2)
                }
            }
        }
    }

    @Test(arguments: [false, true])
    func interleavedPOSTsOverlapAndResponsesFinishOutOfOrder(upstreamH2: Bool) async throws {
        try await withHTTP2ControlLoop { loop in
            let seen = loop.makePromise(of: Void.self)
            let ended = loop.makePromise(of: Void.self)
            let firstGate = loop.makePromise(of: Void.self)
            let secondGate = loop.makePromise(of: Void.self)
            var released = false
            defer { if !released { firstGate.succeed(()); secondGate.succeed(()) } }
            var response = HTTP2TestOrigin.Response()
            response.requestsObserved = seen; response.requestCountTarget = 2
            response.endsObserved = ended; response.endsTarget = 2
            response.barriersByPath = ["/first": firstGate.futureResult, "/second": secondGate.futureResult]
            try await HTTP2TestOrigin.withOrigin(protocols: upstreamH2 ? ["h2"] : ["http/1.1"], response: response) { origin in
                var limits = HTTPTransportLimits()
                limits.http1SocketsPerRoute = 2; limits.totalUpstreamSockets = 2
                try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true, limits: limits) { fixture, client in
                    let first = try await client.startRawRequest(headers: headers(origin, path: "/first", method: "POST"))
                    let second = try await client.startRawRequest(headers: headers(origin, path: "/second", method: "POST"))
                    try await seen.futureResult.get()
                    #expect(origin.counts.connections == (upstreamH2 ? 1 : 2))
                    #expect(origin.counts.endedPaths.isEmpty)
                    if upstreamH2 { #expect(Set(origin.counts.streamIDs).count == 2) }
                    try await first.body("first-")
                    try await second.body("second-")
                    try await first.body("payload")
                    try await second.body("payload")
                    try await first.end(trailers: HPACKHeaders([("x-order", "a"), ("x-order", "b")]))
                    try await second.end(trailers: HPACKHeaders([("x-order", "c"), ("x-order", "d")]))
                    try await ended.futureResult.get()
                    #expect(origin.counts.bodies == ["/first": "first-payload", "/second": "second-payload"])
                    #expect(origin.counts.responseOrder.isEmpty)
                    secondGate.succeed(())
                    #expect(try await second.response.get().body == "fixture-body")
                    #expect(origin.counts.responseOrder == ["/second"])
                    firstGate.succeed(()); released = true
                    #expect(try await first.response.get().body == "fixture-body")
                    #expect(origin.counts.responseOrder == ["/second", "/first"])
                    try await waitForCompletedFlows(fixture.store, atLeast: 2)
                    let flows = fixture.store.allFlows()
                    #expect(flows.count == 2)
                    #expect(flows.allSatisfy { $0.state == .completed })
                    #expect(Set(flows.compactMap { $0.transport.downstreamStreamID }).count == 2)
                    #expect(fixture.upstreams.withLock { $0.count } == (upstreamH2 ? 1 : 2))
                }
            }
        }
    }

    @Test func recordingPauseResumeUsesEachChildAndOneOriginalLookup() async throws {
        try await HTTP2TestOrigin.withOrigin(protocols: ["h2"]) { origin in
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true) { fixture, client in
                _ = try await client.rawRequest(headers: headers(origin, path: "/recorded"))
                fixture.recording.isEnabled.store(false, ordering: .relaxed)
                _ = try await client.rawRequest(headers: headers(origin, path: "/paused"))
                fixture.recording.isEnabled.store(true, ordering: .relaxed)
                _ = try await client.rawRequest(headers: headers(origin, path: "/resumed"))
                #expect(Set(fixture.store.allFlows().map(\.path)) == ["/recorded", "/resumed"])
                #expect(fixture.lookups.withLock { $0 } == 1)
                #expect(origin.counts.connections == 1)
            }
        }
    }

    @Test(arguments: [false, true])
    func clearingOrEvictingLiveStreamNeverResurrectsIt(eviction: Bool) async throws {
        try await withHTTP2ControlLoop { loop in
            let observed = loop.makePromise(of: Void.self)
            let gate = loop.makePromise(of: Void.self)
            var released = false
            defer { if !released { gate.succeed(()) } }
            var response = HTTP2TestOrigin.Response()
            response.requestsObserved = observed
            response.barriersByPath = ["/removed": gate.futureResult]
            try await HTTP2TestOrigin.withOrigin(protocols: ["h2"], response: response) { origin in
                try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true, maxFlows: eviction ? 1 : 1000) { fixture, client in
                    let live = Task { try await client.rawRequest(headers: headers(origin, path: "/removed")) }
                    try await observed.futureResult.get()
                    if !eviction { fixture.store.clear() }
                    _ = try await client.rawRequest(headers: headers(origin, path: "/retained"))
                    gate.succeed(()); released = true
                    #expect(try await live.value.status == 200)
                    #expect(fixture.store.allFlows().map(\.path) == ["/retained"])
                }
            }
        }
    }

    @Test func originalContentLengthStillValidatesAfterH1ChunkedTranslation() async throws {
        try await withHTTP2ControlLoop { loop in
            let seen = loop.makePromise(of: Void.self)
            var response = HTTP2TestOrigin.Response()
            response.requestsObserved = seen
            try await HTTP2TestOrigin.withOrigin(protocols: ["http/1.1"], response: response) { origin in
                try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true) { fixture, client in
                    var bad = headers(origin, path: "/bad-length", method: "POST")
                    bad.add(name: "content-length", value: "99")
                    let invalid = try await client.startRawRequest(headers: bad)
                    try await seen.futureResult.get()
                    #expect(origin.counts.requestHeaders.first?["transfer-encoding"] == ["chunked"])
                    #expect(origin.counts.requestHeaders.first?["content-length"] == [])
                    try? await invalid.body("short", endStream: true)
                    do { _ = try await invalid.response.get(); Issue.record("Mismatched original length accepted") } catch { }
                    let healthy = try await client.rawRequest(headers: headers(origin, path: "/healthy"))
                    #expect(healthy.status == 200)
                    #expect(!origin.counts.endedPaths.contains("/bad-length"))
                    let flow = try #require(fixture.store.allFlows().first { $0.path == "/bad-length" })
                    #expect(flow.state != .completed)
                    #expect(flow.requestHeaders.first { $0.name == "content-length" }?.value == "99")
                }
            }
        }
    }

    @Test func localH2HEADFailureEndsWithoutFabricatingOriginResponse() async throws {
        try await HTTP2TestOrigin.withOrigin(protocols: ["h2"]) { origin in
            var limits = HTTPTransportLimits()
            limits.pendingBytesPerExchange = 1
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true, limits: limits) { fixture, client in
                let response = try await client.rawRequest(headers: headers(origin, method: "HEAD"))
                #expect(response.status == 502)
                #expect(response.body.isEmpty)
                // The downstream version is recorded when the writer accepts the head, which can
                // settle just after the client has already read the response.
                let flow = try await waitForFlow(fixture.store) { $0.transport.downstreamResponse != nil }
                #expect(flow.transport.downstreamResponse == .http2)
                #expect(flow.transport.upstreamRequest == nil)
                #expect(flow.transport.upstreamResponse == nil)
                #expect(flow.responseHeaders.isEmpty)
                #expect(origin.counts.connections == 0)
            }
        }
    }

    @Test func goAwayCreatesBoundedReplacementWhileAcceptedSiblingDrains() async throws {
        try await withHTTP2ControlLoop { loop in
            let seen = loop.makePromise(of: Void.self)
            let gate = loop.makePromise(of: Void.self)
            var released = false
            defer { if !released { gate.succeed(()) } }
            var response = HTTP2TestOrigin.Response()
            response.requestsObserved = seen
            response.barriersByPath = ["/draining": gate.futureResult]
            try await HTTP2TestOrigin.withOrigin(protocols: ["h2"], response: response) { origin in
                var limits = HTTPTransportLimits()
                limits.totalUpstreamSockets = 2
                try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true, limits: limits) { fixture, client in
                    let draining = Task { try await client.rawRequest(headers: headers(origin, path: "/draining")) }
                    try await seen.futureResult.get()
                    let parent = try #require(origin.counts.parents.first)
                    let upstream = try #require(fixture.upstreams.withLock { $0.first })
                    let goAwaySeen = try await HTTP2FixtureControlBarrier.install(on: upstream)
                    try await parent.writeAndFlush(HTTP2Frame(streamID: .rootStream,
                        payload: .goAway(lastStreamID: HTTP2StreamID(1), errorCode: .noError, opaqueData: nil))).get()
                    try await goAwaySeen.get()
                    let response = try await client.rawRequest(headers: headers(origin, path: "/replacement"))
                    #expect(response.status == 200)
                    #expect(origin.counts.connections == 2)
                    #expect(fixture.upstreams.withLock { $0.filter(\.isActive).count } <= 2)
                    #expect(origin.counts.responseOrder == ["/replacement"])
                    gate.succeed(()); released = true
                    #expect(try await draining.value.status == 200)
                }
            }
        }
    }

    @Test func pendingAcquisitionCancellationNeverRevivesAndReleaseWakesSibling() async throws {
        try await withHTTP2ControlLoop { loop in
            let seen = loop.makePromise(of: Void.self)
            let gate = loop.makePromise(of: Void.self)
            var released = false
            defer { if !released { gate.succeed(()) } }
            var response = HTTP2TestOrigin.Response()
            response.requestsObserved = seen; response.barriersByPath = ["/held": gate.futureResult]
            try await HTTP2TestOrigin.withOrigin(protocols: ["h2"], response: response) { origin in
                var limits = HTTPTransportLimits()
                limits.upstreamStreams = 1; limits.totalUpstreamSockets = 1
                try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true, limits: limits) { fixture, client in
                    let held = try await client.startRawRequest(headers: headers(origin, path: "/held"))
                    try await held.end()
                    try await seen.futureResult.get()
                    let cancelled = try await client.startRawRequest(headers: headers(origin, path: "/cancelled"))
                    try await cancelled.end()
                    _ = try await waitForFlow(fixture.store) { $0.path == "/cancelled" }
                    try? await cancelled.channel.close().get()
                    do { _ = try await cancelled.response.get(); Issue.record("Reset request unexpectedly succeeded") } catch { }
                    _ = try await waitForFlow(fixture.store) { $0.path == "/cancelled" && $0.completedAt != nil }
                    let next = try await client.startRawRequest(headers: headers(origin, path: "/next"))
                    try await next.end()
                    _ = try await waitForFlow(fixture.store) { $0.path == "/next" }
                    #expect(origin.counts.paths == ["/held"])
                    gate.succeed(()); released = true
                    #expect(try await held.response.get().status == 200)
                    #expect(try await next.response.get().status == 200)
                    #expect(origin.counts.paths == ["/held", "/next"])
                    #expect(origin.counts.connections == 1)
                    #expect(fixture.upstreams.withLock { $0.count } == 1)
                }
            }
        }
    }

    @Test func rawFixtureStreamSetupFailureSettlesWithoutHarmingParent() async throws {
        try await HTTP2TestOrigin.withOrigin(protocols: ["h2"]) { origin in
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true) { _, client in
                do {
                    _ = try await client.rawRequest(headers: headers(origin), failStreamSetup: true)
                    Issue.record("Injected initializer failure succeeded")
                } catch { }
                let response = try await client.rawRequest(headers: headers(origin))
                #expect(response.status == 200)
                #expect(origin.counts.connections == 1)
            }
        }
    }

    @Test func normalizedHostAndAuthorityAreAcceptedWithoutRewritingCapture() async throws {
        try await HTTP2TestOrigin.withOrigin(protocols: ["h2"]) { origin in
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true) { fixture, client in
                var fields = headers(origin, authority: "LOCALHOST:0\(origin.port)")
                fields.add(name: "host", value: "localhost:\(origin.port)")
                let response = try await client.rawRequest(headers: fields)
                #expect(response.status == 200)
                #expect(fixture.store.allFlows().first?.requestHeaders.first?.value == "localhost:\(origin.port)")
                #expect(origin.counts.connections == 1)
            }
        }
    }

    @Test func earlyResponseCancelsOnlyPairedUploadAndHEADStillEnds() async throws {
        var response = HTTP2TestOrigin.Response()
        response.earlyPaths = ["/early"]
        try await HTTP2TestOrigin.withOrigin(protocols: ["h2"], response: response) { origin in
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true) { fixture, client in
                let early = try await client.startRawRequest(headers: headers(origin, path: "/early", method: "POST"))
                #expect(try await early.response.get().status == 200)
                try await early.body("discarded-upload")
                try await early.end()
                _ = try await waitForFlow(fixture.store) { $0.path == "/early" && $0.bytesSent == 16 }
                let head = try await client.rawRequest(headers: headers(origin, path: "/head", method: "HEAD"))
                #expect(head.status == 200)
                #expect(head.body.isEmpty)
                let healthy = try await client.rawRequest(headers: headers(origin, path: "/healthy"))
                #expect(healthy.body == "fixture-body")
                #expect(origin.counts.connections == 1)
                try await waitForCompletedFlows(fixture.store, atLeast: 3)
                #expect(fixture.store.allFlows().allSatisfy { $0.state == .completed })
            }
        }
    }

    @Test func peerSettingsIncreaseWakesWaiterOnSameParent() async throws {
        try await withHTTP2ControlLoop { loop in
            let seen = loop.makePromise(of: Void.self)
            let gate = loop.makePromise(of: Void.self)
            var released = false
            defer { if !released { gate.succeed(()) } }
            var response = HTTP2TestOrigin.Response()
            response.requestsObserved = seen; response.barriersByPath = ["/held": gate.futureResult]
            try await HTTP2TestOrigin.withOrigin(protocols: ["h2"], response: response) { origin in
                try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true) { fixture, client in
                    let held = Task { try await client.rawRequest(headers: headers(origin, path: "/held")) }
                    try await seen.futureResult.get()
                    let parent = try #require(origin.counts.parents.first)
                    let upstream = try #require(fixture.upstreams.withLock { $0.first })
                    let reduced = try await HTTP2FixtureControlBarrier.install(on: upstream, maximum: 1)
                    try await parent.writeAndFlush(HTTP2Frame(streamID: .rootStream,
                        payload: .settings(.settings([.init(parameter: .maxConcurrentStreams, value: 1)])))).get()
                    try await reduced.get()
                    let waiting = Task { try await client.rawRequest(headers: headers(origin, path: "/waiting")) }
                    _ = try await waitForFlow(fixture.store) { $0.path == "/waiting" }
                    #expect(origin.counts.paths == ["/held"])
                    let increased = try await HTTP2FixtureControlBarrier.install(on: upstream, maximum: 2)
                    try await parent.writeAndFlush(HTTP2Frame(streamID: .rootStream,
                        payload: .settings(.settings([.init(parameter: .maxConcurrentStreams, value: 2)])))).get()
                    try await increased.get()
                    #expect(try await waiting.value.status == 200)
                    #expect(origin.counts.connections == 1)
                    #expect(origin.counts.responseOrder == ["/waiting"])
                    gate.succeed(()); released = true
                    #expect(try await held.value.status == 200)
                }
            }
        }
    }

}

private func headers(_ origin: HTTP2TestOrigin, authority: String? = nil, scheme: String = "https",
                     path: String = "/", method: String = "GET") -> HPACKHeaders {
    HPACKHeaders([ (":method", method), (":scheme", scheme), (":authority", authority ?? "localhost:\(origin.port)"), (":path", path) ])
}
