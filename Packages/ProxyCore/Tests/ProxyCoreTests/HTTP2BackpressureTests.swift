import NIOCore
import NIOHTTP1
import NIOHTTP2
import NIOHPACK
import Testing
import os
@testable import ProxyCore

@Suite(.productionChinese) struct HTTP2BackpressureTests {
    @Test func downstreamWritabilityPausesAndResumesPairedSourceWithPositiveCredit() async throws {
        let children = OSAllocatedUnfairLock(initialState: [Channel]())
        let body = (0..<64).map { String(repeating: String($0 % 10), count: 4096) }.joined()
        var response = HTTP2TestOrigin.Response()
        response.bodiesByPath = ["/pressure": body]
        try await HTTP2TestOrigin.withOrigin(protocols: ["h2"], response: response) { origin in
            var limits = HTTPTransportLimits(); limits.highWatermark = 8192; limits.lowWatermark = 4096
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true, limits: limits,
                streamCreationGate: { child in
                    children.withLock { $0.append(child) }
                    return child.eventLoop.makeSucceededVoidFuture()
                }) { fixture, client in
                // Prime the real TLS/SETTINGS path. Both peers retain their positive
                // default stream/connection windows; this test sends no WINDOW_UPDATE.
                #expect(try await client.rawRequest(headers: backpressureHeaders(origin, "/prime")).status == 200)
                let connection = try #require(fixture.connections.withLock { $0.first })
                let parent = try await fixture.channel.eventLoop.submit { connection.value.channel }.boundedGet()
                let gate = try await HTTP2FrameWriteGate.install(on: parent, path: "/pressure")
                do {
                    let pending = try await client.startRawRequest(headers: backpressureHeaders(origin, "/pressure"))
                    try await pending.end()
                    let held = try await parent.eventLoop.submit { gate.value.held.futureResult }.boundedGet()
                    try await held.boundedGet()
                    let source = try #require(children.withLock { $0.last })
                    let snapshot = try await HTTP2FlowControlFixture.snapshot(fixture)
                    let blocked = try #require(snapshot.exchanges.first { $0.path == "/pressure" })
                    let queued = try #require(blocked.downstreamQueuedBodyBytes)
                    #expect(queued >= 8192 && queued <= 65_535)
                    #expect(blocked.responseReading == false)
                    #expect(!(try await source.getOption(ChannelOptions.autoRead).boundedGet()))
                    let resumed = try await HTTP2ResumeReadProbe.install(on: source)
                    // The gate withholds only this child's DATA before encoding, so it
                    // consumes no peer stream or connection credit and preserves controls.
                    #expect(try await client.rawRequest(headers: backpressureHeaders(origin, "/healthy")).body == "fixture-body")
                    try await HTTP2FlowControlFixture.ping(parent)
                    let upstream = try #require(fixture.upstreams.withLock { $0.first })
                    try await HTTP2FlowControlFixture.ping(upstream)
                    #expect(try await parent.getOption(ChannelOptions.autoRead).boundedGet())
                    #expect(try await upstream.getOption(ChannelOptions.autoRead).boundedGet())
                    try await parent.eventLoop.submit {
                        #expect(gate.value.heldBytes >= 8192 && gate.value.heldBytes <= 65_535)
                        #expect(gate.value.otherDataBytes >= "fixture-body".utf8.count)
                        print("HTTP2 positive-credit writability snapshot: \(blocked), held DATA bytes: \(gate.value.heldBytes)")
                        gate.value.release()
                    }.boundedGet()
                    #expect(try await resumed.boundedGet())
                    print("HTTP2 positive-credit source resumed")
                    let delivered = try await pending.response.boundedGet()
                    #expect(delivered.body == body)
                    #expect(delivered.trailers?.first(name: "x-finish") == "done")
                    #expect(try await HTTP2FlowControlFixture.snapshot(fixture).exchanges.isEmpty)
                    #expect(try await client.rawRequest(headers: backpressureHeaders(origin, "/after-resume")).status == 200)
                    #expect(origin.counts.connections == 1)
                } catch {
                    if let snapshot = try? await HTTP2FlowControlFixture.snapshot(fixture) {
                        print("HTTP2 positive-credit failure snapshot: \(snapshot)")
                    }
                    try? await parent.eventLoop.submit { gate.value.release() }.boundedGet()
                    throw error
                }
            }
        }
    }


    @Test func leaseReadControlPausesOnlyPairedChildWithPositiveCredit() async throws {
        try await withHTTP2ControlLoop { loop in
            let head = loop.makePromise(of: Void.self)
            let gate = loop.makePromise(of: Void.self)
            var response = HTTP2TestOrigin.Response()
            response.bodyBarriersByPath = ["/paused": gate.futureResult]
            response.bodiesByPath = ["/paused": String(repeating: "p", count: 131_072)]
            try await HTTP2TestOrigin.withOrigin(protocols: ["h2"], response: response) { origin in
                let client = try await HTTP2TestClient.connect(origin: origin)
                var released = false
                do {
                    let owner = try await client.channel.eventLoop.flatSubmit {
                        let sink = HTTP2TestClient.Sink(loop: client.channel.eventLoop)
                        sink.onHead = { [weak sink] in
                            sink?.lease?.setResponseReading(false)
                            head.succeed(())
                        }
                        return client.state.value.session!.openStream(responseSink: sink).assumeIsolated().map { lease in
                            sink.lease = lease
                            _ = lease.write(.head(.init(version: .http2, method: .GET, uri: "/paused",
                                                       headers: .init([("host", "localhost")]))))
                            _ = lease.write(.end(nil)); lease.flush()
                            return NIOLoopBound((lease, sink), eventLoop: client.channel.eventLoop)
                        }.nonisolated()
                    }.boundedGet()
                    try await head.futureResult.boundedGet()
                    // The header consumes the already-issued read. A sibling round trip
                    // completes before DATA is released, so the pause has taken effect.
                    #expect(try await client.request(path: "/healthy").body == "fixture-body")
                    gate.succeed(()); released = true
                    try await HTTP2FlowControlFixture.ping(client.channel)
                    try await client.channel.eventLoop.submit {
                        #expect(!owner.value.1.done)
                        #expect((owner.value.0 as? HTTP2UpstreamLease)?.reading == false)
                        #expect(client.state.value.session?.snapshot.reservedStreams == 1)
                        owner.value.0.setResponseReading(true)
                    }.boundedGet()
                    let result = try await client.channel.eventLoop.flatSubmit { owner.value.1.promise.futureResult }.boundedGet()
                    #expect(result.body == String(repeating: "p", count: 131_072))
                    #expect(try await client.channel.getOption(ChannelOptions.autoRead).boundedGet())
                    #expect(origin.counts.connections == 1)
                    try await client.stop()
                } catch {
                    if !released { gate.succeed(()) }
                    try? await client.stop(); throw error
                }
            }
        }
    }
    @Test(arguments: [174, 175])
    func headerBudgetIncludesFourSynthesizedPseudoFields(bytes: Int) async throws {
        try await HTTP2TestOrigin.withOrigin(protocols: ["h2"]) { origin in
            var limits = HTTPTransportLimits(); limits.headerBytes = bytes
            let client = try await HTTP2TestClient.connect(origin: origin, limits: limits)
            do {
                // GET+https+localhost+/ and four names plus 4*32 overhead = 175 bytes.
                if bytes == 174 {
                    do { _ = try await client.request(); Issue.record("Pseudo-header budget ignored") }
                    catch { #expect(error is HTTP2TransportError) }
                    #expect(origin.counts.requests == 0)
                    #expect(client.channel.isActive)
                } else {
                    #expect(try await client.request().status == 200)
                    #expect(origin.counts.requests == 1)
                }
                try await client.stop()
            } catch { try? await client.stop(); throw error }
        }
    }

    @Test(arguments: [false, true])
    func early413DisposesUnfinishedUploadByDeadlineAndPreservesFlow(upstreamH2: Bool) async throws {
        var response = HTTP2TestOrigin.Response()
        response.status = .payloadTooLarge
        response.earlyPaths = ["/early"]
        try await HTTP2TestOrigin.withOrigin(protocols: upstreamH2 ? ["h2"] : ["http/1.1"], response: response) { origin in
            var limits = HTTPTransportLimits(); limits.drainTimeout = .milliseconds(100)
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true, limits: limits) { fixture, client in
                let early = try await client.startRawRequest(headers: backpressureHeaders(origin, "/early", method: "POST"))
                #expect(try await early.response.boundedGet().status == 413)
                // Completion is recorded once the final downstream write settles, possibly after the client read it.
                let flow = try await waitForFlow(fixture.store) { $0.path == "/early" && $0.state != .inProgress }
                #expect(flow.state == .completed)
                #expect(try await client.rawRequest(headers: backpressureHeaders(origin, "/healthy")).status == 413)
                try await early.channel.closeFuture.boundedGet()
                #expect(try await HTTP2FlowControlFixture.snapshot(fixture).exchanges.isEmpty)
                let final = fixture.store.allFlows().filter { $0.path == "/early" }
                #expect(final.count == 1)
                #expect(final.first?.state == .completed)
                #expect(final.first?.completedAt == flow.completedAt)
                #expect(final.first?.transport.upstreamResponse == (upstreamH2 ? .http2 : .http1_1))
                #expect(try await client.rawRequest(headers: backpressureHeaders(origin, "/after-disposal")).status == 413)
            }
        }
    }

    @Test func zeroUploadStreamWindowBoundsQueueWithoutBlockingSiblingOrPing() async throws {
        try await withHTTP2ControlLoop { loop in
            let seen = loop.makePromise(of: Void.self)
            var response = HTTP2TestOrigin.Response()
            response.requestsObserved = seen; response.requestCountTarget = 3
            var originLimits = HTTPTransportLimits(); originLimits.receiveWindow = 0
            try await HTTP2TestOrigin.withOrigin(protocols: ["h2"], response: response, limits: originLimits) { origin in
                var limits = HTTPTransportLimits()
                limits.highWatermark = 16_384; limits.lowWatermark = 8192
                try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true, limits: limits) { fixture, client in
                    // Complete a round trip so the origin's initial SETTINGS have taken
                    // effect before the upload; pre-SETTINGS DATA is legitimately in flight.
                    #expect(try await client.rawRequest(headers: backpressureHeaders(origin, "/prime")).status == 200)
                    let stalled = try await client.startRawRequest(headers: backpressureHeaders(origin, "/stalled", method: "POST"))
                    try await stalled.body(String(repeating: "x", count: 32_768))
                    let healthy = try await client.startRawRequest(headers: backpressureHeaders(origin, "/healthy", method: "POST"))
                    try await seen.futureResult.boundedGet()
                    #expect(origin.counts.streamIDs == [1, 3, 5])
                    let parent = try #require(origin.counts.parents.first)
                    try await parent.writeAndFlush(HTTP2Frame(streamID: HTTP2StreamID(origin.counts.streamIDs[2]),
                        payload: .windowUpdate(windowSizeIncrement: 65_535))).boundedGet()
                    try await healthy.body("small"); try await healthy.end()
                    #expect(try await healthy.response.boundedGet().status == 200)
                    let upstream = try #require(fixture.upstreams.withLock { $0.first })
                    try await HTTP2FlowControlFixture.ping(upstream)
                    let snapshot = try await HTTP2FlowControlFixture.snapshot(fixture)
                    let blocked = try #require(snapshot.exchanges.first { $0.path == "/stalled" })
                    let queued = try #require(blocked.upstreamQueuedBodyBytes)
                    #expect(queued >= 16_384)
                    #expect(queued <= 65_535)
                    #expect(blocked.requestReading == false)
                    #expect(snapshot.pendingBytes == 0)
                    #expect(origin.counts.bodies["/stalled"] == nil)
                    #expect(origin.counts.bodies["/healthy"] == "small")
                    #expect(try await upstream.getOption(ChannelOptions.autoRead).boundedGet())
                    print("HTTP2 upload zero-window snapshot: \(snapshot)")
                    try? await stalled.channel.close().boundedGet()
                    do { _ = try await stalled.response.boundedGet(); Issue.record("Reset upload succeeded") } catch { #expect(!(error is HTTP2FixtureDeadlineExceeded)) }
                    _ = try await waitForFlow(fixture.store) { $0.path == "/stalled" && $0.completedAt != nil }
                    #expect(try await HTTP2FlowControlFixture.snapshot(fixture).exchanges.isEmpty)
                    #expect(origin.counts.connections == 1)
                }
            }
        }
    }

    @Test func zeroDownloadStreamWindowPreservesSiblingDataAndParentControls() async throws {
        try await withHTTP2ControlLoop { loop in
            var response = HTTP2TestOrigin.Response()
            response.bodiesByPath = ["/stalled": String(repeating: "x", count: 262_144)]
            try await HTTP2TestOrigin.withOrigin(protocols: ["h2"], response: response) { origin in
                var limits = HTTPTransportLimits()
                limits.highWatermark = 16_384; limits.lowWatermark = 8192
                var clientLimits = HTTPTransportLimits(); clientLimits.receiveWindow = 0
                try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true, limits: limits,
                                                      clientLimits: clientLimits) { fixture, client in
                    let head = loop.makePromise(of: Void.self)
                    let stalled = try await client.startRawRequest(headers: backpressureHeaders(origin, "/stalled"), headObserved: head)
                    try await stalled.end()
                    try await head.futureResult.boundedGet()
                    let healthy = try await client.startRawRequest(headers: backpressureHeaders(origin, "/healthy"))
                    // Every stream started at zero. Explicitly grant only the healthy child's
                    // real NIO ID credit; connection credit remains available throughout.
                    try await HTTP2FlowControlFixture.credit(healthy, parent: client.channel, bytes: 65_535)
                    try await healthy.end()
                    #expect(try await healthy.response.boundedGet().body == "fixture-body")
                    try await HTTP2FlowControlFixture.ping(client.channel)
                    let snapshot = try await HTTP2FlowControlFixture.snapshot(fixture)
                    let blocked = try #require(snapshot.exchanges.first { $0.path == "/stalled" })
                    let queued = try #require(blocked.downstreamQueuedBodyBytes)
                    #expect(queued >= 16_384)
                    #expect(queued <= 65_535)
                    #expect(blocked.responseReading == false)
                    print("HTTP2 download zero-window snapshot: \(snapshot)")
                    #expect(snapshot.pendingBytes == 0)
                    let upstream = try #require(fixture.upstreams.withLock { $0.first })
                    #expect(try await upstream.getOption(ChannelOptions.autoRead).boundedGet())
                    let original = try #require(fixture.connections.withLock { $0.first })
                    #expect(try await fixture.channel.eventLoop.flatSubmit {
                        original.value.channel.getOption(ChannelOptions.autoRead)
                    }.boundedGet())
                    try? await stalled.channel.close().boundedGet()
                    do { _ = try await stalled.response.boundedGet(); Issue.record("Reset stalled response succeeded") } catch { #expect(!(error is HTTP2FixtureDeadlineExceeded)) }
                    _ = try await waitForFlow(fixture.store) { $0.path == "/stalled" && $0.completedAt != nil }
                    #expect(try await HTTP2FlowControlFixture.snapshot(fixture).exchanges.isEmpty)
                    #expect(origin.counts.connections == 1)
                }
            }
        }
    }
}

private func backpressureHeaders(_ origin: HTTP2TestOrigin, _ path: String, method: String = "GET") -> HPACKHeaders {
    HPACKHeaders([ (":method", method), (":scheme", "https"), (":authority", "localhost:\(origin.port)"), (":path", path) ])
}
