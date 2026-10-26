import FlowStore
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing
@testable import ProxyCore

@Suite(.serialized, .timeLimit(.minutes(1)), .productionChinese) struct HTTP2UpgradeTests {
    @Test func cachedH2AndActiveLeaseSurviveDedicatedMITMUpgrade() async throws {
        let gates = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let release = gates.next().makePromise(of: Void.self)
        var released = false
        do {
            var response = HTTP2TestOrigin.Response()
            response.barriersByPath["/held"] = release.futureResult
            try await withUpgrade(tls: true, response: response) { origin, fixture, client in
                // This normal request actually crosses CONNECT + MITM and primes this context's TLS/pool.
                try await prime(client, origin: origin)
                let first = try await waitForFlow(fixture.store) { $0.path == "/prime" && $0.state == .completed }
                #expect(first.transport.upstreamRequest == .http2)
                #expect(first.transport.upstreamResponse == .http2)
                #expect(first.transport.downstreamRequest == .http1_1)
                let parent = try #require(fixture.upstreams.withLock { $0.first })
                let owner = try #require(fixture.connections.withLock { $0.first })
                let loop = parent.eventLoop
                // The serial downstream h1 adapter cannot issue concurrent requests. Supplement the
                // real client handoff with a genuine active TLS h2 stream on its SAME production pool.
                let held = try await acquire(owner, on: loop, port: origin.port, path: "/held", parent: parent)
                try await waitUntil("held origin stream") { origin.counts.paths.contains("/held") }
                #expect(try await loop.submit { owner.value.upstreamPool.snapshot.sessions.first?.activeStreams }.get() == 1)
                #expect(origin.counts.connections == 1)
                try await client.send(HTTP2UpgradeWire.request(target: "/ws", port: origin.port))
                try await assertHandshake(client)
                #expect(origin.counts.negotiated == [.http2, .http1])
                #expect(origin.counts.connections == 2)
                #expect(fixture.connections.withLock { $0.count } == 1)
                #expect(parent.isActive)
                let during = try await loop.submit { owner.value.upstreamPool.snapshot }.get()
                #expect(during.sessions.first?.activeStreams == 1)
                #expect(during.physicalSockets == 1) // h1 socket has permanently detached for Glue.
                try await assertFrameRelay(client, origin: origin)
                release.succeed(()); released = true
                let completed = try await loop.flatSubmit { held.value.promise.futureResult }.boundedGet()
                #expect(completed.body == "fixture-body")
                #expect(completed.status == 200)
                let after = try await acquire(owner, on: loop, port: origin.port, path: "/after", parent: parent)
                #expect(try await loop.flatSubmit { after.value.promise.futureResult }.boundedGet().status == 200)
                #expect(origin.counts.connections == 2)
                #expect(parent.isActive)
                // Cache policy is independently observable: a fresh TLS connection using this same
                // TLSInterception instance still offers h2 after the dedicated h1 context was cached.
                let tls = try await loop.submit { owner.value.environment.tls }.get()
                let fresh = try await HTTP2TestClient.connect(origin: origin, tls: tls)
                #expect(fresh.selected == .http2)
                #expect(try await fresh.request().status == 200)
                try await fresh.stop()
                let upgraded = try await waitForFlow(fixture.store) { $0.path == "/ws" && $0.state == .completed }
                #expect(upgraded.statusCode == 101)
                // Both TLS versions are recorded now (T8); the version fields are compared separately.
                var wire = upgraded.transport
                #expect(wire.downstreamTLSVersion?.hasPrefix("TLS 1.") == true)
                #expect(wire.upstreamTLSVersion?.hasPrefix("TLS 1.") == true)
                wire.downstreamTLSVersion = nil
                wire.upstreamTLSVersion = nil
                #expect(wire == .init(downstreamRequest: .http1_1, downstreamResponse: .http1_1,
                    upstreamRequest: .http1_1, upstreamResponse: .http1_1))
                #expect(fixture.store.allFlows().filter { $0.path == "/ws" }.count == 1)
                #expect(origin.counts.paths.filter { $0 == "/ws" }.count == 1)
                #expect(origin.counts.streamIDs.count == 4) // prime, held, after, independent cache probe.
                #expect(Set(origin.counts.streamIDs.prefix(3)).count == 3)
            }
            try await gates.shutdownGracefully()
        } catch {
            if !released { release.succeed(()) }
            try? await gates.shutdownGracefully(); throw error
        }
    }

    @Test func plaintextHTTP1UpgradePreservesSamePacketAndBinaryFrames() async throws {
        try await withUpgrade(tls: false) { origin, fixture, client in
            try await client.send(HTTP2UpgradeWire.request(target: "http://localhost:\(origin.port)/ws", port: origin.port))
            try await assertHandshake(client)
            try await assertFrameRelay(client, origin: origin)
            let flow = try await waitForFlow(fixture.store) { $0.path == "/ws" && $0.state == .completed }
            #expect(flow.transport.upstreamRequest == .http1_1)
            #expect(flow.statusCode == 101)
            #expect(fixture.store.allFlows().count == 1)
            #expect(origin.counts.connections == 1)
            #expect(origin.counts.paths == ["/ws"])
        }
    }

    @Test(arguments: [false, true]) func failedUpgradeIsNeverRetried(tls: Bool) async throws {
        try await withUpgrade(tls: tls) { origin, fixture, client in
            if tls { try await prime(client, origin: origin) }
            let target = tls ? "/ws-fail" : "http://localhost:\(origin.port)/ws-fail"
            try await client.send(HTTP2UpgradeWire.request(target: target, port: origin.port))
            #expect(try await client.receive(until: "\r\n\r\n").contains("502"))
            try await waitUntil("failed upgrade closes client") { !client.channel.isActive }
            let flow = try await waitForFlow(fixture.store) {
                guard $0.path == "/ws-fail" else { return false }
                if case .failed = $0.state { return true }; return false
            }
            #expect(flow.statusCode == nil) // Local failure is not an origin response.
            #expect(flow.transport.upstreamResponse == nil)
            #expect(flow.transport.downstreamResponse == .http1_1)
            #expect(fixture.store.allFlows().filter { $0.path == "/ws-fail" }.count == 1)
            #expect(origin.counts.paths.filter { $0 == "/ws-fail" }.count == 1)
            #expect(origin.counts.connections == (tls ? 2 : 1))
        }
    }

    private func prime(_ client: HTTP2UpgradeClient, origin: HTTP2TestOrigin) async throws {
        try await client.send(Array("GET /prime HTTP/1.1\r\nHost: localhost:\(origin.port)\r\n\r\n".utf8))
        let response = try await client.receive(until: "0\r\n\r\n")
        #expect(response.hasPrefix("HTTP/1.1 200"))
        #expect(response.contains("fixture-body"))
    }
    private func assertHandshake(_ client: HTTP2UpgradeClient) async throws {
        let head = try await client.receive(until: "\r\n\r\n")
        #expect(head.hasPrefix("HTTP/1.1 101 Switching Protocols\r\n"))
        #expect(head.contains("Sec-WebSocket-Accept: " + HTTP2UpgradeWire.accept + "\r\n"))
        #expect(head.lowercased().contains("upgrade: websocket\r\n"))
        #expect(head.lowercased().contains("connection: upgrade\r\n"))
        // Header order may be normalized; every byte after the head must be unchanged.
        #expect(try await client.receive(count: HTTP2UpgradeWire.greeting.count) == HTTP2UpgradeWire.greeting)
    }
    private func assertFrameRelay(_ client: HTTP2UpgradeClient, origin: HTTP2TestOrigin) async throws {
        try await client.send(HTTP2UpgradeWire.clientFrame)
        #expect(try await client.receive(count: HTTP2UpgradeWire.serverFrame.count) == HTTP2UpgradeWire.serverFrame)
        #expect(origin.counts.upgradeBytes == HTTP2UpgradeWire.clientFrame)
    }
    private func acquire(_ owner: NIOLoopBound<ClientConnectionContext>, on loop: EventLoop,
                         port: Int, path: String, parent: Channel) async throws -> NIOLoopBound<HTTP2TestClient.Sink> {
        try await loop.flatSubmit {
            let sink = HTTP2TestClient.Sink(loop: loop)
            return owner.value.upstreamPool.acquire(route: .init(scheme: "https", host: "localhost", port: port, policy: .automatic),
                forceFresh: false, responseSink: sink).futureResult.assumeIsolated().map { lease in
                    #expect(lease.version == .http2)
                    #expect(lease.channel.parent === parent)
                    #expect(lease.wasReused)
                    sink.lease = lease
                    lease.write(.head(.init(version: .http2, method: .GET, uri: path,
                        headers: .init([("host", "localhost:\(port)")])))).assumeIsolated().whenFailure { sink.upstreamClosed(error: $0) }
                    lease.write(.end(nil)).assumeIsolated().whenFailure { sink.upstreamClosed(error: $0) }
                    lease.flush()
                    return NIOLoopBound(sink, eventLoop: loop)
                }.nonisolated()
        }.boundedGet()
    }
    private func withUpgrade(tls: Bool, response: HTTP2TestOrigin.Response = .init(),
        _ body: (HTTP2TestOrigin, HTTP2ProxyFixture, HTTP2UpgradeClient) async throws -> Void) async throws {
        var response = response; response.supportsUpgrade = true; response.trailers = nil
        let origin = try await HTTP2TestOrigin.start(protocols: ["h2", "http/1.1"], response: response, plaintext: !tls)
        var fixture: HTTP2ProxyFixture?
        var client: HTTP2UpgradeClient?
        do {
            let proxy = try await HTTP2ProxyFixture.start(origin: origin); fixture = proxy
            let connected = try await HTTP2UpgradeClient.connect(fixture: proxy, origin: origin, tls: tls); client = connected
            try await body(origin, proxy, connected)
            try await connected.stop(); try await proxy.stop(); try await origin.stop()
        } catch {
            if let client { try? await client.stop() }
            if let fixture { try? await fixture.stop() }
            try? await origin.stop(); throw error
        }
    }
}
