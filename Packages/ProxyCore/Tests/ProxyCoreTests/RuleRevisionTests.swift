import FlowStore
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing
@testable import ProxyCore
import RulesEngine

/// Each exchange freezes the published rule snapshot when its request head is admitted and uses it
/// for its response too; a later publish affects only later heads, even on the same connection.
@Suite(.serialized, .timeLimit(.minutes(2)), .productionChinese) struct RuleRevisionTests {
    private static func revisionRules(_ revision: Int) -> [Rule] {
        [TestRules.headers(.request, [.set(name: "X-Req-Rev", value: "\(revision)")]),
         TestRules.headers(.response, [.set(name: "X-Rev", value: "\(revision)")])]
    }

    @Test func concurrentStreamsOnOneConnectionKeepTheRevisionTheyWereAdmittedWith() async throws {
        let gates = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let release = gates.next().makePromise(of: Void.self)
        var released = false
        do {
            var response = HTTP2TestOrigin.Response()
            response.barriersByPath["/first"] = release.futureResult
            let rules = TestRules.provider(Self.revisionRules(1), revision: 1)
            try await HTTP2TestOrigin.withOrigin(protocols: ["h2"], response: response) { origin in
                try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true, rules: rules) { fixture, client in
                    #expect(client.selected == .http2)
                    let headers = HTTPHeaders([("host", "localhost:\(origin.port)")])
                    async let first = client.request(headers: headers, path: "/first")
                    try await waitUntil("held first stream") { origin.counts.endedPaths.contains("/first") }
                    TestRules.publish(Self.revisionRules(2), revision: 2, to: rules)
                    let second = try await client.request(headers: headers, path: "/second")
                    #expect(second.headers["x-rev"] == ["2"])
                    release.succeed(()); released = true
                    #expect(try await first.headers["x-rev"] == ["1"])

                    let seen = Dictionary(uniqueKeysWithValues: zip(origin.counts.paths, origin.counts.requestHeaders))
                    #expect(seen["/first"]?["x-req-rev"] == ["1"])
                    #expect(seen["/second"]?["x-req-rev"] == ["2"])
                    #expect(fixture.connections.withLock { $0.count } == 1)
                    try await waitForCompletedFlows(fixture.store, atLeast: 2)
                    let revisions = Dictionary(uniqueKeysWithValues: fixture.store.allFlows().map {
                        ($0.path, $0.provenance.ruleMatches?.revision)
                    })
                    #expect(revisions == ["/first": 1, "/second": 2])
                }
            }
            try await gates.shutdownGracefully()
        } catch {
            if !released { release.succeed(()) }
            try? await gates.shutdownGracefully(); throw error
        }
    }

    @Test func aPublishBetweenRequestAndResponseDoesNotChangeTheResponseRules() async throws {
        try await withConnectionFixture { fixture in
            let rules = TestRules.provider(Self.revisionRules(1), revision: 1)
            let context = fixture.context(rules: rules)
            let writer = RecordingResponseWriter(channel: fixture.client)
            let exchange = fixture.admit("/frozen", writer: writer, context: context)
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            let upstream = try fixture.connect(0)
            #expect(try fixture.written(upstream).contains("\r\nX-Req-Rev: 1\r\n"))
            TestRules.publish(Self.revisionRules(2), revision: 2, to: rules)
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
            fixture.loop.run()
            #expect(writer.heads.first?.headers["X-Rev"] == ["1"])
            #expect(try fixture.flow("/frozen").provenance.ruleMatches?.revision == 1)

            // The next head on the same connection (and the same pooled upstream) sees revision 2.
            let nextWriter = RecordingResponseWriter(channel: fixture.client)
            let next = fixture.admit("/next", writer: nextWriter, context: context)
            next.receiveRequest(.end(nil))
            next.execute()
            #expect(fixture.connections.count == 1)
            #expect(try fixture.written(upstream).contains("\r\nX-Req-Rev: 2\r\n"))
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
            fixture.loop.run()
            #expect(nextWriter.heads.first?.headers["X-Rev"] == ["2"])
        }
    }

    /// A lower rule reads the request as the Map Remote above it left it: a rule for the mapped host
    /// continues from it, and a second Map for the original host no longer matches (R1 classes 2 and 3;
    /// the rules run once, in order, so nothing recurses).
    @Test func laterMapsReadTheMappedRequest() async throws {
        try await withConnectionFixture { fixture in
            // R1 intentional change class 3: the second Map Remote continues from the first one's target.
            fixture.expectedEndpoint = (host: "chained.test", port: 82)
            let rules = TestRules.provider([
                TestRules.mapRemote(host: "mapped.test", port: 81, matcher: RuleMatcher(hostPattern: "example.test")),
                TestRules.mapRemote(host: "chained.test", port: 82, matcher: RuleMatcher(hostPattern: "mapped.test")),
                TestRules.mapRemote(host: "shadowed.test", port: 83, matcher: RuleMatcher(hostPattern: "example.test")),
            ])
            let writer = RecordingResponseWriter(channel: fixture.client)
            let exchange = fixture.admit("/map", writer: writer, context: fixture.context(rules: rules))
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            let upstream = try fixture.connect(0)
            let head = try fixture.written(upstream)
            #expect(head.hasPrefix("GET /map HTTP/1.1\r\n"))
            // R1 intentional change class 3: the second Map Remote continues from the first one's target.
            #expect(head.contains("\r\nHost: chained.test:82\r\n"))
            #expect(!head.contains("example.test"))
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
            fixture.loop.run()
            // R1 intentional change class 3: the second Map Remote continues from the first one's target.
            #expect(fixture.connectedEndpoints == ["chained.test:82"])
            let matches = try #require(try fixture.flow("/map").provenance.ruleMatches)
            #expect(matches.total == 2)
            // R1 intentional change class 2: the third rule names the original host, which the request no
            // longer has, so it stays silent instead of being shadowed; the second one ran.
            #expect(matches.outcomes.map(\.code) == [.applied, .applied])
        }
    }

    @Test(arguments: ["[::1]", "::1"], [80, 8080])
    func ipv6TargetsConnectUnbracketedAndOmitTheDefaultPort(host: String, port: Int) async throws {
        try await withConnectionFixture { fixture in
            fixture.expectedEndpoint = (host: "::1", port: port)
            let rules = TestRules.provider([TestRules.mapRemote(host: host, port: port)])
            let writer = RecordingResponseWriter(channel: fixture.client)
            let exchange = fixture.admit("/v6", writer: writer, context: fixture.context(rules: rules))
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            let upstream = try fixture.connect(0)
            let head = try fixture.written(upstream)
            #expect(head.contains(port == 80 ? "\r\nHost: [::1]\r\n" : "\r\nHost: [::1]:8080\r\n"), "\(head)")
            #expect(fixture.connectedEndpoints == ["::1:\(port)"])
        }
    }
}

// Phase fix I2d: with the global rules switch off, traffic is exactly what it is without rules:
// same upstream bytes, same flow provenance, no breakpoint ticket. Switching on applies to the next head.
extension RuleRevisionTests {
    private struct Observed: Equatable {
        var wire: String
        var provenance: FlowProvenance
        var status: Int?
        var tickets: Int
    }

    private static func observe(rules: RuleSnapshotProvider?, breakpoints: BreakpointCoordinator?) async throws -> Observed? {
        var observed: Observed?
        try await withConnectionFixture { fixture in
            let writer = RecordingResponseWriter(channel: fixture.client)
            let exchange = fixture.admit("/switch", headers: HTTPHeaders([("X-Orig", "1")]), writer: writer,
                                         context: fixture.context(rules: rules, breakpoints: breakpoints))
            defer { exchange.cancel(reason: "cleanup") }
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            guard fixture.connections.count == 1 else {
                observed = Observed(wire: "", provenance: .passive, status: nil, tickets: breakpoints?.snapshot().count ?? 0)
                return
            }
            let upstream = try fixture.connect(0)
            let wire = try fixture.written(upstream)
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nX-Origin: 1\r\n\r\nok"))
            fixture.loop.run()
            let flow = try fixture.flow("/switch")
            observed = Observed(wire: wire, provenance: flow.provenance, status: writer.heads.first.map { Int($0.status.code) },
                                tickets: breakpoints?.snapshot().count ?? 0)
            #expect(writer.body == "ok")
        }
        return observed
    }

    @Test func globallySwitchedOffRulesLeaveTrafficIdenticalToNoRules() async throws {
        let rules = [TestRules.headers(.request, [.set(name: "X-Rule", value: "1")]),
                     TestRules.headers(.response, [.set(name: "X-Resp-Rule", value: "1")]),
                     TestRules.breakpoint(.request)]
        let provider = TestRules.provider(rules, revision: 9)
        let coordinator = BreakpointCoordinator()
        defer { coordinator.shutdown() }

        let baseline = try #require(try await Self.observe(rules: nil, breakpoints: nil))
        #expect(baseline.status == 200 && !baseline.wire.contains("X-Rule"))

        provider.setEnabled(false)
        let off = try #require(try await Self.observe(rules: provider, breakpoints: coordinator))
        #expect(off == baseline)
        #expect(off.provenance.ruleMatches == nil)
        #expect(coordinator.snapshot().isEmpty)

        // Live: the next head after switching on pauses at the breakpoint again.
        provider.setEnabled(true)
        let on = try #require(try await Self.observe(rules: provider, breakpoints: coordinator))
        #expect(on.tickets == 1 && on.wire.isEmpty)
    }
}
