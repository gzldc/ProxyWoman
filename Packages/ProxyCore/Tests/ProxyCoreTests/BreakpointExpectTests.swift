import CertKit
import FlowStore
import Foundation
import NIOHTTP1
import NIOCore
import RulesEngine
import Testing
@testable import ProxyCore

@Suite(.serialized, .productionChinese) struct BreakpointExpectTests {
    // A rewrite or swallowed upstream 100 outside collection breaks this wire handshake.
    @Test func expectWithoutBreakpointUnchanged() async throws {
        try await withExpectProxy { server, origin, store in
            let client = try await RawClient.connect(port: try #require(server.boundPort))
            do {
                try await client.send("POST http://127.0.0.1:\(origin.port)/expect HTTP/1.1\r\nHost: 127.0.0.1:\(origin.port)\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n")
                #expect(try await client.receive(until: "\r\n\r\n") == "HTTP/1.1 100 Continue\r\n\r\n")
                try await client.send("hello")
                #expect(try await client.receive(until: "\r\n\r\n").contains("200 OK"))
                #expect(try await client.receive(count: 5) == Array("hello".utf8))
                let flow = try await waitForFlow(store) { $0.state == .completed }
                #expect(flow.messages[.upstreamRequest]?.headers.value(for: "expect") == "100-continue")
                #expect(flow.statusCode == 200)
                #expect(client.remainingBytes().isEmpty)
                try await client.close()
            } catch { try? await client.close(); throw error }
        }
    }
    // Missing local 100 deadlocks a conforming client before it uploads even one byte.
    @Test func expectWithFullBodyBreakpointGetsLocal100Once() async throws {
        try await collectedExpect(path: "/expect", explicit: false)
    }
    @Test func upstream100IsSwallowedAfterLocal100() async throws {
        try await collectedExpect(path: "/expect-duplicate", explicit: false)
    }
    @Test func earlyHints103StillForwarded() async throws {
        try await collectedExpect(path: "/expect-hints", explicit: false)
    }
    @Test func headersCollectBodyGetsLocal100Once() async throws {
        try await collectedExpect(path: "/expect", explicit: true)
    }
    private func collectedExpect(path: String, explicit: Bool) async throws {
        let b = BreakpointCoordinator()
        var rule = TestRules.breakpoint(.request)
        rule.action = .breakpoint(direction: .request, mode: explicit ? .headers : .fullBody)
        try await withExpectProxy(rules: TestRules.provider([rule]), breakpoints: b) { server, origin, store in
            let client = try await RawClient.connect(port: try #require(server.boundPort))
            do {
                try await client.send("POST http://127.0.0.1:\(origin.port)\(path) HTTP/1.1\r\nHost: 127.0.0.1:\(origin.port)\r\nExpect: 100-Continue, 100-continue\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n")
                if explicit {
                    try await waitUntil("headers ticket") { b.snapshot().first?.state == .pausedHeaders }
                    let t = try #require(b.snapshot().first)
                    #expect(client.remainingBytes().isEmpty && origin.acceptedConnections == 0)
                    #expect(await b.perform(.collectBody(token: t.token)) == .accepted)
                }
                let interim = try await client.receive(until: "\r\n\r\n")
                try #require(interim == "HTTP/1.1 100 Continue\r\n\r\n")
                #expect(origin.acceptedConnections == 0)
                #expect(store.allFlows().first?.statusCode == nil)
                #expect(store.allFlows().first?.messages[.downstreamResponse] == nil)
                try await client.send("he"); try await client.send("llo")
                try await waitUntil("body ticket") { b.snapshot().first?.state == .pausedBody }
                let t = try #require(b.snapshot().first)
                #expect(t.originalHead.headers.values(for: "expect") == ["100-Continue, 100-continue", "100-continue"])
                #expect(t.bodyLength == 5)
                // Even an edit retaining/reintroducing Expect must not resurrect the handshake.
                #expect(await b.perform(.continue(token: t.token, edit: .init(head: t.effectiveHead))) == .accepted)
                if path == "/expect-hints" {
                    for value in ["first", "second"] {
                        let hint = try await client.receive(until: "\r\n\r\n")
                        #expect(hint.hasPrefix("HTTP/1.1 103 ") && hint.contains(value))
                    }
                }
                #expect(try await client.receive(until: "\r\n\r\n").hasPrefix("HTTP/1.1 200 "))
                #expect(try await client.receive(count: 5) == Array("hello".utf8))
                let flow = try await waitForFlow(store) { $0.state == .completed }
                #expect(flow.messages[.upstreamRequest]?.headers.value(for: "expect") == nil)
                #expect(flow.messages[.downstreamRequest]?.headers.values(for: "expect").count == 2)
                #expect(flow.statusCode == 200 && flow.messages[.upstreamResponse]?.status == 200)
                #expect(client.remainingBytes().isEmpty)
                try await client.close()
            } catch { try? await client.close(); throw error }
        }
    }

}

func withExpectProxy(rules: RuleSnapshotProvider? = nil, breakpoints: BreakpointCoordinator? = nil,
                     runtime: BreakpointBodyRuntime? = nil, assets: ManagedAssetStore? = nil,
                     _ body: (ProxyServer, TestOriginServer, FlowStore) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("expect-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FlowStore(bodyDirectory: directory)
    let origin = try await TestOriginServer.start()
    var configuration = ProxyConfiguration(); configuration.port = 0
    let server = ProxyServer(configuration: configuration, certificateAuthority: try CertificateAuthority.generate(),
        store: store, passthrough: PassthroughRegistry(), processLookup: .none, drainDeadline: .standard,
        rules: rules, assets: assets, breakpoints: breakpoints, bodyRuntime: runtime)
    do { try await server.start(); try await body(server, origin, store); try await server.stop(); try await origin.stop() }
    catch { try? await server.stop(); try? await origin.stop(); throw error }
}

extension BreakpointExpectTests {
    @Test(arguments: [false, true], [false, true])
    func h2ExpectBreakpointLocal100(upstreamH2: Bool, extraInformational: Bool) async throws {
        let b = BreakpointCoordinator()
        var rule = TestRules.breakpoint(.request); rule.action = .breakpoint(direction: .request, mode: .fullBody)
        var config = HTTP2TestOrigin.Response()
        if extraInformational { config.informationalStatuses = [100, 103, 103] }
        try await HTTP2TestOrigin.withOrigin(protocols: upstreamH2 ? ["h2"] : ["http/1.1"], response: config) { origin in
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true,
                rules: TestRules.provider([rule]), breakpoints: b) { f, client in
                let task = Task { try await client.request(headers: .init([("host", "localhost:\(origin.port)"), ("expect", "100-continue"), ("content-length", "5")]),
                    path: "/expect-h2", method: .POST, body: "hello", waitForContinue: true) }
                do {
                    try await waitUntil("h2 collected body") { b.snapshot().first?.state == .pausedBody }
                    let t = try #require(b.snapshot().first)
                    #expect(origin.counts.connections == 0 && t.bodyLength == 5)
                    #expect(await b.perform(.continue(token: t.token, edit: .init(head: t.effectiveHead))) == .accepted)
                    let response = try await task.value
                    #expect(response.statuses == (extraInformational ? [100, 103, 103, 200] : [100, 200]))
                    let interim = try #require(response.snapshots.first)
                    #expect(!interim.endStream && interim.regularHeaders.isEmpty)
                    #expect(response.snapshots.filter { $0.kind == .informational }.allSatisfy { !$0.endStream })
                    #expect(origin.counts.requestHeaders.first?.contains(name: "expect") == false)
                    let flow = try await waitForFlow(f.store) { $0.path == "/expect-h2" && $0.state == .completed }
                    #expect(flow.statusCode == 200 && flow.messages[.downstreamResponse]?.transferState == .finished)
                } catch { b.shutdown(); _ = try? await task.value; throw error }
            }
        }
    }
    @Test func cancelAfterLocal100HasOneFinalFailureAndNoOrigin() async throws {
        let b = BreakpointCoordinator()
        var rule = TestRules.breakpoint(.request); rule.action = .breakpoint(direction: .request, mode: .fullBody)
        try await withExpectProxy(rules: TestRules.provider([rule]), breakpoints: b) { server, origin, store in
            let c = try await RawClient.connect(port: try #require(server.boundPort))
            do {
                try await c.send("POST http://127.0.0.1:\(origin.port)/expect HTTP/1.1\r\nHost: localhost\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n")
                #expect(try await c.receive(until: "\r\n\r\n").contains("100 Continue"))
                let t = try #require(b.snapshot().first)
                #expect(await b.perform(.cancel(token: t.token)) == .accepted)
                #expect(try await c.receive(until: "\r\n\r\n").contains("502 Bad Gateway"))
                #expect(await b.perform(.cancel(token: t.token)) == .invalid)
                let flow = try await waitForFlow(store) { if case .failed = $0.state { true } else { false } }
                #expect(flow.messages[.downstreamResponse]?.status == 502 && origin.acceptedConnections == 0)
                #expect(flow.messages[.upstreamRequest] == nil)
                try await c.close()
            } catch { try? await c.close(); throw error }
        }
    }
    @Test func knownTooLargeExpectWaitsForContinueAndOrigin100() async throws {
        var limits = RulesLimits(); limits.breakpointBodyBytes = 4
        let b = BreakpointCoordinator(limits: limits)
        var rule = TestRules.breakpoint(.request); rule.action = .breakpoint(direction: .request, mode: .fullBody)
        try await withExpectProxy(rules: TestRules.provider([rule]), breakpoints: b) { server, origin, store in
            let c = try await RawClient.connect(port: try #require(server.boundPort))
            do {
                try await c.send("POST http://127.0.0.1:\(origin.port)/expect HTTP/1.1\r\nHost: localhost\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n")
                try await waitUntil("known-too-large") { b.snapshot().first?.bodyUnavailable != nil }
                let t = try #require(b.snapshot().first)
                #expect(c.remainingBytes().isEmpty && origin.acceptedConnections == 0)
                #expect(await b.perform(.continue(token: t.token, edit: .init(head: t.effectiveHead))) == .accepted)
                #expect(try await c.receive(until: "\r\n\r\n").contains("100 Continue"))
                try await c.send("hello")
                #expect(try await c.receive(until: "\r\n\r\n").contains("200 OK"))
                #expect(try await c.receive(count: 5) == Array("hello".utf8))
                let flow = try await waitForFlow(store) { $0.state == .completed }
                #expect(flow.messages[.upstreamRequest]?.headers.value(for: "expect") == "100-continue")
                try await c.close()
            } catch { try? await c.close(); throw error }
        }
    }
}

extension BreakpointExpectTests {
    @Test func local100WriteFailureCancelsWithoutOriginOrFinalCapture() async throws {
        try await withConnectionFixture { f in
            let limits = RulesLimits()
            let runtime = BreakpointBodyRuntime(budgets: OwnedFileBudgets(limits: limits), limits: limits)
            f.environment.bodyRuntime = runtime
            let b = BreakpointCoordinator(clock: EmbeddedBreakpointClock(now: f.loop.now))
            var rule = TestRules.breakpoint(.request); rule.action = .breakpoint(direction: .request, mode: .fullBody)
            let c = f.context(rules: TestRules.provider([rule]), breakpoints: b)
            let w = ContinueSettlementWriter(loop: f.loop)
            let x = HTTPExchange(requestHead: .init(version: .http1_1, method: .POST, uri: "/expect-failure",
                headers: .init([("expect", "100-continue"), ("content-length", "4")])),
                target: .init(host: "example.test", port: 80, originForm: "/expect-failure", defaultPort: 80),
                scheme: "http", downstream: w, connection: c, transport: .init())
            x.execute()
            #expect(w.statuses == [100] && w.flushes > 0)
            #expect(b.snapshot().count == 1 && f.connections.isEmpty)
            w.pending.fail(HTTPTransportError.closed); f.loop.run()
            #expect(b.snapshot().isEmpty && f.connections.isEmpty)
            #expect(w.statuses == [100] && w.ends == 0)
            let flow = try #require(f.store.allFlows().first)
            #expect(flow.messages[.downstreamResponse] == nil && flow.messages[.upstreamResponse] == nil)
            if case .failed = flow.state {} else { Issue.record("failed informational write must settle exchange") }
            #expect(x.snapshot.breakpointTimers == 0)
            x.cancel(reason: "already terminal")
        }
    }
    @Test(arguments: ["fancy", "100-continue, fancy", "", "100-continue,"])
    func unsupportedExplicitCollectionDoesNotSend100(expectation: String) async throws {
        try await withConnectionFixture { f in
            let limits = RulesLimits()
            let runtime = BreakpointBodyRuntime(budgets: OwnedFileBudgets(limits: limits), limits: limits)
            f.environment.bodyRuntime = runtime
            let b = BreakpointCoordinator(clock: EmbeddedBreakpointClock(now: f.loop.now))
            let c = f.context(rules: TestRules.provider([TestRules.breakpoint(.request)]), breakpoints: b)
            let w = RecordingResponseWriter(channel: f.client)
            let x = f.admit("/unsupported", headers: .init([("expect", expectation), ("content-length", "4")]), writer: w, context: c)
            defer { x.cancel(reason: "cleanup") }
            x.execute()
            let t = try #require(b.snapshot().first)
            #expect(try breakpointPerform(b, .collectBody(token: t.token), f) == .unsupported)
            #expect(w.heads.isEmpty && f.connections.isEmpty)
            #expect(b.snapshot().first?.state == .pausedHeaders && b.snapshot().first?.deadline == t.deadline)
            #expect(runtime.activePins == 0 && runtime.budgets.snapshot().reservedBytes == 0)
        }
    }
    @Test func expectCollectionWithoutBodyResourcesStillUnsupported() async throws {
        try await withConnectionFixture { f in
            let b = BreakpointCoordinator(clock: EmbeddedBreakpointClock(now: f.loop.now))
            var rule = TestRules.breakpoint(.request); rule.action = .breakpoint(direction: .request, mode: .fullBody)
            let c = f.context(rules: TestRules.provider([rule]), breakpoints: b)
            let w = RecordingResponseWriter(channel: f.client)
            let x = f.admit("/no-body-runtime", headers: .init([("expect", "100-continue")]), writer: w, context: c)
            x.execute()
            #expect(w.heads.map(\.status.code) == [502] && f.connections.isEmpty)
            #expect(x.localFailure == .ruleActionUnsupported && b.snapshot().isEmpty)
        }
    }
}

private final class ContinueSettlementWriter: DownstreamResponseWriter {
    let eventLoop: EventLoop
    let version: HTTPWireVersion = .http1_1
    let isWritable = true
    let isActive = true
    let pending: EventLoopPromise<Void>
    var statuses: [UInt] = []
    var ends = 0
    var flushes = 0
    init(loop: EventLoop) { eventLoop = loop; pending = loop.makePromise() }
    func write(_ part: HTTPServerResponsePart) -> EventLoopFuture<Void> {
        if case .head(let head) = part { statuses.append(head.status.code) }
        if case .end = part { ends += 1 }
        return pending.futureResult
    }
    func flush() { flushes += 1 }
    func setRequestReading(_ enabled: Bool) {}
    func responseFinished() {}
    func abort(_ error: Error) {}
}

extension BreakpointExpectTests {
    @Test func local100KeepsAbsoluteDeadlineAndFailedAdmissionEmitsNone() async throws {
        for capacity in [3, 4] {
            try await withConnectionFixture { f in
                var limits = RulesLimits(); limits.breakpointSpoolBytes = capacity
                let runtime = BreakpointBodyRuntime(budgets: OwnedFileBudgets(limits: limits), limits: limits)
                f.environment.bodyRuntime = runtime
                let b = BreakpointCoordinator(clock: EmbeddedBreakpointClock(now: f.loop.now), limits: limits)
                let c = f.context(rules: TestRules.provider([TestRules.breakpoint(.request)]), breakpoints: b)
                let w = RecordingResponseWriter(channel: f.client)
                let x = f.admit("/expect-deadline", headers: .init([("expect", "100-continue"), ("content-length", "4")]), writer: w, context: c)
                defer { x.cancel(reason: "cleanup") }
                x.execute()
                let t = try #require(b.snapshot().first)
                breakpointAdvance(f, b, by: .seconds(119))
                let result = try breakpointPerform(b, .collectBody(token: t.token), f)
                if capacity == 3 {
                    #expect(result == .invalid)
                    #expect(w.heads.map(\.status.code) == [502])
                } else {
                    #expect(result == .accepted)
                    #expect(w.heads.map(\.status.code) == [100])
                    #expect(b.snapshot().first?.deadline == t.deadline)
                    #expect(try breakpointPerform(b, .collectBody(token: t.token), f) == .invalid)
                    #expect(w.heads.map(\.status.code) == [100])
                    breakpointAdvance(f, b, by: .seconds(1))
                    #expect(w.heads.map(\.status.code) == [100, 504])
                }
                #expect(f.connections.isEmpty && b.snapshot().isEmpty)
                #expect(x.snapshot.breakpointTimers == 0)
            }
        }
    }
    @Test func headersOnlyExpectWaitsUntilContinueThenOrigin100() async throws {
        let b = BreakpointCoordinator()
        try await withExpectProxy(rules: TestRules.provider([TestRules.breakpoint(.request)]), breakpoints: b) { server, origin, store in
            let c = try await RawClient.connect(port: try #require(server.boundPort))
            do {
                try await c.send("POST http://127.0.0.1:\(origin.port)/expect HTTP/1.1\r\nHost: localhost\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n")
                try await waitUntil("headers breakpoint") { b.snapshot().first?.state == .pausedHeaders }
                let t = try #require(b.snapshot().first)
                #expect(c.remainingBytes().isEmpty && origin.acceptedConnections == 0)
                #expect(await b.perform(.continue(token: t.token, edit: .init(head: t.effectiveHead))) == .accepted)
                #expect(try await c.receive(until: "\r\n\r\n").contains("100 Continue"))
                try await c.send("hello")
                #expect(try await c.receive(until: "\r\n\r\n").contains("200 OK"))
                #expect(try await c.receive(count: 5) == Array("hello".utf8))
                let flow = try await waitForFlow(store) { $0.state == .completed }
                #expect(flow.messages[.upstreamRequest]?.headers.value(for: "expect") == "100-continue")
                try await c.close()
            } catch { try? await c.close(); throw error }
        }
    }
}
