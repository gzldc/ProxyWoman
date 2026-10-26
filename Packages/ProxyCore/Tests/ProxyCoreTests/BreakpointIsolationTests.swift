import FlowStore
import Foundation
import NIOCore
import NIOConcurrencyHelpers
import NIOHTTP1
import NIOHTTP2
import Testing
@testable import ProxyCore
@testable import RulesEngine

@Suite(.serialized, .productionChinese) struct BreakpointIsolationTests {
    @Test func h2PausedChildDoesNotBlockSiblingOrPing() async throws {
        let b = BreakpointCoordinator()
        let rule = TestRules.breakpoint(.response, matcher: .init(path: .exact("/paused")))
        try await HTTP2TestOrigin.withOrigin(protocols: ["h2"]) { origin in
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true,
                rules: TestRules.provider([rule]), breakpoints: b) { fixture, client in
                let observed = client.channel.eventLoop.makePromise(of: Void.self)
                let seen = NIOLockedValueBox(false)
                observed.futureResult.whenSuccess { seen.withLockedValue { $0 = true } }
                let pending = try await client.startRawRequest(headers: breakpointH2Headers(origin, path: "/paused"), headObserved: observed)
                try await pending.end()
                defer { b.shutdown() }
                let ticket = try await breakpointTicket(b, on: fixture.channel.eventLoop)
                #expect(!seen.withLockedValue { $0 })
                #expect(try await client.rawRequest(headers: breakpointH2Headers(origin, path: "/sibling")).body == "fixture-body")
                try await HTTP2FlowControlFixture.ping(client.channel)
                try await client.channel.writeAndFlush(HTTP2Frame(streamID: .rootStream, payload: .settings(.settings([])))).boundedGet()
                try await HTTP2FlowControlFixture.ping(client.channel)
                let owner = try #require(fixture.connections.withLock { $0.first })
                #expect(try await fixture.channel.eventLoop.flatSubmit { owner.value.channel.getOption(ChannelOptions.autoRead) }.boundedGet())
                let paused = try await HTTP2FlowControlFixture.snapshot(fixture)
                #expect(paused.exchanges.first { $0.path == "/paused" }?.responseReading == false)
                #expect(!seen.withLockedValue { $0 })
                #expect(origin.counts.connections == 1)
                #expect(await b.perform(.continue(token: ticket.token, edit: .init(head: ticket.effectiveHead))) == .accepted)
                #expect(try await pending.response.boundedGet().body == "fixture-body")
                try await waitForCompletedFlows(fixture.store, atLeast: 2)
                #expect(b.snapshot().isEmpty)
            }
        }
    }

    @Test func pausedResponseKeepsUpstreamH1Exclusive() async throws {
        let b = BreakpointCoordinator()
        let rule = TestRules.breakpoint(.response, matcher: .init(path: .exact("/paused")))
        try await HTTP2TestOrigin.withOrigin(protocols: ["http/1.1"]) { origin in
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true,
                rules: TestRules.provider([rule]), breakpoints: b) { fixture, client in
                let pending = try await client.startRawRequest(headers: breakpointH2Headers(origin, path: "/paused"))
                try await pending.end()
                defer { b.shutdown() }
                let t = try await breakpointTicket(b, on: fixture.channel.eventLoop)
                #expect(try await client.rawRequest(headers: breakpointH2Headers(origin, path: "/sibling")).status == 200)
                #expect(origin.counts.connections == 2)
                #expect(await b.perform(.continue(token: t.token, edit: .init(head: t.effectiveHead))) == .accepted)
                #expect(try await pending.response.boundedGet().body == "fixture-body")
                try await waitForCompletedFlows(fixture.store, atLeast: 2)
                #expect(try await client.rawRequest(headers: breakpointH2Headers(origin, path: "/after")).status == 200)
                #expect(origin.counts.connections == 2)
            }
        }
    }

    @Test(arguments: [false, true])
    func h1PipelinedSuccessorsStayOrderedAndBounded(oversized: Bool) async throws {
        do {
            let b = BreakpointCoordinator()
            var response = HTTP2TestOrigin.Response(); response.trailers = nil
            response.bodiesByPath = ["/first": "one", "/second": "second-body"]
            let origin = try await HTTP2TestOrigin.start(protocols: ["http/1.1"], response: response, plaintext: true)
            do {
                var limits = HTTPTransportLimits(); limits.pendingBytesPerExchange = 512
                let fixture = try await HTTP2ProxyFixture.start(origin: origin, limits: limits,
                    rules: TestRules.provider([TestRules.breakpoint(.response, matcher: .init(path: .exact("/first")))]), breakpoints: b)
                do {
                    let client = try await RawClient.connect(port: try #require(fixture.channel.localAddress?.port))
                    do {
                        let first = "GET http://localhost:\(origin.port)/first HTTP/1.1\r\nHost: localhost:\(origin.port)\r\n\r\n"
                        let payload = oversized ? String(repeating: "x", count: 1024) : ""
                        let second = "POST http://localhost:\(origin.port)/second HTTP/1.1\r\nHost: localhost:\(origin.port)\r\nContent-Length: \(payload.utf8.count)\r\nConnection: close\r\n\r\n" + payload
                        try await client.send(first + second)
                        if oversized {
                            try await client.waitUntilClosed()
                            #expect(origin.counts.paths.allSatisfy { $0 == "/first" })
                            let snapshot = try await HTTP2FlowControlFixture.snapshot(fixture)
                            #expect(snapshot.pendingBytes == 0 && snapshot.exchanges.isEmpty)
                        } else {
                            let t = try await breakpointTicket(b, on: fixture.channel.eventLoop)
                            #expect(client.remainingBytes().isEmpty)
                            #expect(origin.counts.paths == ["/first"])
                            let snapshot = try await HTTP2FlowControlFixture.snapshot(fixture)
                            #expect(snapshot.pendingBytes > 0 && snapshot.pendingBytes <= 512)
                            #expect(await b.perform(.continue(token: t.token, edit: .init(head: t.effectiveHead))) == .accepted)
                            try await client.waitUntilClosed()
                            for bodyFrame in ["3\r\none\r\n0\r\n\r\n", "b\r\nsecond-body\r\n0\r\n\r\n"] {
                                let head = try await client.receive(until: "\r\n\r\n")
                                #expect(head.hasPrefix("HTTP/1.1 200 OK\r\n"))
                                #expect(head.lowercased().contains("transfer-encoding: chunked\r\n"))
                                #expect(!head.lowercased().contains("content-length:"))
                                let actual = try await client.receive(count: bodyFrame.utf8.count)
                                #expect(actual == Array(bodyFrame.utf8))
                            }
                            #expect(client.remainingBytes().isEmpty)
                            #expect(origin.counts.paths == ["/first", "/second"])
                            try await waitForCompletedFlows(fixture.store, atLeast: 2)
                        }
                        b.shutdown(); try await client.close()
                    } catch { b.shutdown(); try? await client.close(); throw error }
                    try await fixture.stop()
                } catch { try? await fixture.stop(); throw error }
                try await origin.stop()
            } catch { try? await origin.stop(); throw error }
        }
    }
}

extension BreakpointIsolationTests {
    @Test func realH1ResponseReadGateStaysClosedAcrossDownstreamWritability() async throws {
        let b = BreakpointCoordinator()
        try await HTTP2TestOrigin.withOrigin(protocols: ["http/1.1"]) { origin in
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: false,
                rules: TestRules.provider([TestRules.breakpoint(.response)]), breakpoints: b) { fixture, client in
                let pending = Task { try await client.request() }
                do {
                    let t = try await breakpointTicket(b, on: fixture.channel.eventLoop)
                    let upstream = try #require(fixture.upstreams.withLock { $0.first })
                    let owner = try #require(fixture.connections.withLock { $0.first })
                    try await fixture.channel.eventLoop.submit { owner.value.channel.pipeline.fireChannelWritabilityChanged() }.boundedGet()
                    #expect(try await upstream.getOption(ChannelOptions.autoRead).boundedGet() == false)
                    #expect(await b.perform(.continue(token: t.token, edit: .init(head: t.effectiveHead))) == .accepted)
                    #expect(try await pending.value.body == "fixture-body")
                } catch { b.shutdown(); _ = try? await pending.value; throw error }
            }
        }
    }
}

extension BreakpointIsolationTests {
    @Test(arguments: [336, 337])
    func h1SuccessorQueueExactBoundaryAndDisconnectRelease(bodyCount: Int) async throws {
        try await withConnectionFixture { f in
            let b = BreakpointCoordinator(clock: EmbeddedBreakpointClock(now: f.loop.now))
            var limits = HTTPTransportLimits(); limits.pendingBytesPerExchange = 512
            let c = f.context(limits: limits, rules: TestRules.provider([TestRules.breakpoint(.response)]), breakpoints: b)
            try f.client.pipeline.syncOperations.addHandlers([
                HTTPMessageTranslation.responseEncoder(), HTTP1TransferCodingFramer<HTTPResponseHead>(),
                ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)),
                ProxyHandler(mode: .forwardProxy, environment: f.environment, inheritedConnection: c),
            ])
            let first = "GET http://example.test/first HTTP/1.1\r\nHost: example.test\r\n\r\n"
            // Successor charge: slot1 + URI26 + POST4 + Host48 + Content-Length49 + Connection47
            // =175 head, body336, END1 =>512. The next byte must fail closed.
            let second = "POST http://example.test/second HTTP/1.1\r\nHost: example.test\r\nContent-Length: \(bodyCount)\r\nConnection: close\r\n\r\n" + String(repeating: "x", count: bodyCount)
            try f.client.writeInbound(ByteBuffer(string: first + second))
            let upstream = try f.connect(0) // settle even an acquisition cancelled by overflow
            if bodyCount == 336 {
                #expect(c.snapshot.pendingBytes == 512)
                #expect(try f.written(upstream).contains("GET /first"))
                try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
                #expect(c.snapshot.pendingBytes == 513)
                #expect(b.snapshot().count == 1)
                try f.client.close().wait()
                f.loop.run()
            } else { #expect(!f.client.isActive) }
            #expect(c.snapshot.pendingBytes == 0 && c.snapshot.exchanges.isEmpty)
            #expect(b.snapshot().isEmpty)
            breakpointAdvance(f, b, by: .seconds(120))
            #expect(c.snapshot.pendingBytes == 0)
        }
    }
}
