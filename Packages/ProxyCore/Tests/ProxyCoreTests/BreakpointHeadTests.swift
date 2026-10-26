import FlowStore
import Foundation
import NIOCore
import NIOConcurrencyHelpers
import NIOEmbedded
import NIOHTTP1
import NIOHPACK
import NIOPosix
import NIOSSL
import Testing
@testable import ProxyCore
@testable import RulesEngine

@Suite(.productionChinese) struct BreakpointHeadTests {
    @Test func requestPausesBeforeOriginAcquired() async throws {
        try await withConnectionFixture { f in
            let (c, x, w, b) = breakpointExchange(f)
            defer { x.cancel(reason: "cleanup") }
            #expect(f.connections.isEmpty)
            #expect(w.heads.isEmpty)
            #expect(c.snapshot.exchanges.count == 1)
            #expect(b.snapshot().count == 1)
        }
    }

    @Test func editURLQueryHeaderThenContinueSendsExactlyOneRequest() async throws {
        try await withConnectionFixture { f in
            let (_, x, w, b) = breakpointExchange(f)
            x.receiveRequest(.end(nil))
            let t = try #require(b.snapshot().first)
            let edited = HTTPMessageHead.request(.init(scheme: "http", host: "example.test", port: 80,
                method: "GET", pathAndQuery: "/edited?q=2"), headers: t.effectiveHead.headers + [.init(name: "X-Edited", value: "yes")])
            #expect(try breakpointPerform(b, .continue(token: t.token, edit: .init(head: edited)), f) == .accepted)
            #expect(x.snapshot.breakpointTimers == 0)
            try #require(f.connections.count == 1)
            let upstream = try f.connect(0)
            let wire = try f.written(upstream)
            #expect(wire.contains("GET /edited?q=2 HTTP/1.1"))
            #expect(wire.contains("X-Edited: yes"))
            #expect(f.connections.count == 1)
            #expect(b.snapshot().isEmpty)
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
            #expect(w.finishes == 1)
        }
    }

    @Test func invalidEditKeepsTicketPaused() async throws {
        try await withConnectionFixture { f in
            let (_, x, _, b) = breakpointExchange(f)
            defer { x.cancel(reason: "cleanup") }
            let t = try #require(b.snapshot().first)
            guard case .request(let target, let fields) = t.effectiveHead else { return }
            for field in [HeaderField(name: "bad name", value: "x"), .init(name: "Content-Length", value: "20"),
                          .init(name: "Connection", value: "close")] {
                let edit = BreakpointEdit(head: .request(target, headers: fields + [field]))
                #expect(try breakpointPerform(b, .continue(token: t.token, edit: edit), f) == .invalid)
                #expect(b.snapshot().first?.token == t.token)
                #expect(b.snapshot().first?.deadline == t.deadline)
                #expect(b.snapshot().first?.state == .pausedHeaders)
                #expect(f.connections.isEmpty)
            }
            #expect(try breakpointPerform(b, .continue(token: t.token, edit: .init(head: t.effectiveHead)), f) == .accepted)
            _ = try f.connect(0)
        }
    }

    @Test func emptyBodyEndStreamDoesNotHang() async throws {
        try await withConnectionFixture { f in
            let (_, x, w, b) = breakpointExchange(f, version: .http2)
            x.receiveRequest(.end(nil))
            let t = try #require(b.snapshot().first)
            #expect(try breakpointPerform(b, .continue(token: t.token, edit: .init(head: t.effectiveHead)), f) == .accepted)
            try #require(f.connections.count == 1)
            let upstream = try f.connect(0)
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
            #expect(w.finishes == 1)
            #expect(b.snapshot().isEmpty)
        }
    }

    @Test func pendingBodyInSamePacketStaysWithinBudget() async throws {
        for count in [30 * 1024, 65 * 1024] {
            try await withConnectionFixture { f in
                let (c, x, w, b) = breakpointExchange(f, method: .POST,
                    headers: HTTPHeaders([("Content-Length", String(count))]))
                x.requestReadStarted()
                x.receiveRequest(.body(ByteBuffer(repeating: 120, count: count)))
                x.receiveRequest(.end(nil))
                x.requestReadComplete()
                if count > 65536 {
                    #expect(x.localFailure == .pendingBytesExceeded)
                    #expect(w.heads.map(\.status.code) == [502])
                    #expect(b.snapshot().isEmpty)
                    #expect(c.snapshot.pendingBytes == 0)
                } else {
                    #expect(c.snapshot.pendingBytes >= count)
                    let t = try #require(b.snapshot().first)
                    #expect(try breakpointPerform(b, .continue(token: t.token, edit: .init(head: t.effectiveHead)), f) == .accepted)
                    try #require(f.connections.count == 1)
                    let upstream = try f.connect(0)
                    let wire = try f.written(upstream)
                    let body = try #require(wire.components(separatedBy: "\r\n\r\n").last)
                    #expect(body.utf8.count == count)
                    #expect(body.utf8.elementsEqual(Array(repeating: UInt8(120), count: count)))
                    try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
                    #expect(c.snapshot.pendingBytes == 0)
                    #expect(try f.flow("/paused").requestBody?.load().count == count)
                }
            }
        }
    }

    @Test func breakpointsUnsetMeansUnsupported() async throws {
        try await withConnectionFixture { f in
            let c = f.context(rules: TestRules.provider([TestRules.breakpoint(.request)]))
            let w = RecordingResponseWriter(channel: f.client)
            let x = f.admit("/unset", writer: w, context: c)
            x.execute(); x.receiveRequest(.end(nil))
            #expect(x.localFailure == .ruleActionUnsupported)
            #expect(w.heads.map(\.status.code) == [502])
            #expect(f.connections.isEmpty)
        }
    }
}

final class EmbeddedBreakpointClock: BreakpointClock, Sendable {
    private let instant: NIOLockedValueBox<NIODeadline>
    init(now: NIODeadline) { instant = .init(now) }
    var now: NIODeadline { instant.withLockedValue { $0 } }
    func advance(by amount: TimeAmount) { instant.withLockedValue { $0 = $0 + amount } }
}
func breakpointAdvance(_ f: ConnectionFixture, _ b: BreakpointCoordinator, by amount: TimeAmount) {
    (b.clock as? EmbeddedBreakpointClock)?.advance(by: amount)
    f.loop.advanceTime(by: amount)
}

func breakpointExchange(_ f: ConnectionFixture, coordinator: BreakpointCoordinator? = nil,
                        context: ClientConnectionContext? = nil, version: HTTPWireVersion = .http1_1,
                        method: HTTPMethod = .GET, headers: HTTPHeaders = .init())
    -> (ClientConnectionContext, HTTPExchange, RecordingResponseWriter, BreakpointCoordinator) {
    let b = coordinator ?? BreakpointCoordinator(clock: EmbeddedBreakpointClock(now: f.loop.now))
    let c = context ?? f.context(rules: TestRules.provider([TestRules.breakpoint(.request)]), breakpoints: b)
    let w = RecordingResponseWriter(channel: f.client, version: version)
    let x = f.admit("/paused", method: method, headers: headers, writer: w, context: c)
    x.execute()
    return (c, x, w, b)
}

func breakpointPerform(_ b: BreakpointCoordinator, _ command: BreakpointCommand,
                       _ f: ConnectionFixture) throws -> BreakpointCommandResult {
    let result = NIOLockedValueBox<BreakpointCommandResult?>(nil)
    b.perform(command) { value in result.withLockedValue { $0 = value } }
    f.loop.run()
    return try #require(result.withLockedValue { $0 })
}

extension BreakpointHeadTests {
    @Test(arguments: [false, true])
    func editedMethodUsesActualUpstreamAndOriginalDownstreamSemantics(originalHEAD: Bool) async throws {
        try await withConnectionFixture { f in
            let (c, x, w, b) = breakpointExchange(f, method: originalHEAD ? .HEAD : .GET)
            x.receiveRequest(.end(nil))
            let t = try #require(b.snapshot().first)
            guard case .request(var target, let fields) = t.effectiveHead else { return }
            target.method = originalHEAD ? "GET" : "HEAD"
            #expect(try breakpointPerform(b, .continue(token: t.token, edit: .init(head: .request(target, headers: fields))), f) == .accepted)
            try #require(f.connections.count == 1)
            let upstream = try f.connect(0)
            let wire = try f.written(upstream)
            #expect(wire.hasPrefix(originalHEAD ? "GET " : "HEAD "))
            // Real HTTP/1 decoder uses the forwarded method to identify whether bytes follow.
            let response = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n" + (originalHEAD ? "hello" : "")
            try upstream.writeInbound(ByteBuffer(string: response))
            #expect(w.heads.first?.headers["content-length"] == [originalHEAD ? "5" : "0"])
            #expect(w.body.isEmpty)
            #expect(w.finishes == 1)
            #expect(c.snapshot.exchanges.isEmpty)
            #expect(try f.flow("/paused").messages[.upstreamRequest]?.target?.method == target.method)
        }
    }

    @Test(arguments: [false, true])
    func crossOriginStripsInheritedButKeepsNewExplicitCredentials(explicit: Bool) async throws {
        try await withConnectionFixture { f in
            let b = BreakpointCoordinator(clock: EmbeddedBreakpointClock(now: f.loop.now))
            let rules = TestRules.provider([
                TestRules.mapRemote(host: "mapped.test", port: 80, preserveCredentials: true), TestRules.breakpoint(.request)
            ], revision: 31)
            let c = f.context(rules: rules, breakpoints: b)
            let w = RecordingResponseWriter(channel: f.client)
            let x = f.admit("/original", headers: HTTPHeaders([("Authorization", "old"), ("Cookie", "old-cookie"),
                ("Origin", "http://source.test"), ("Referer", "http://source.test/path"), ("Proxy-Authorization", "proxy-old")]), writer: w, context: c)
            x.execute(); x.receiveRequest(.end(nil))
            let t = try #require(b.snapshot().first)
            guard case .request(var target, var fields) = t.effectiveHead else { return }
            #expect(target.host == "mapped.test")
            #expect(fields.values(for: "authorization") == ["old"])
            #expect(fields.values(for: "proxy-authorization").isEmpty)
            target.host = "final.test"; target.pathAndQuery = "/final?q=2"
            if explicit {
                fields.removeAll { ["authorization", "cookie"].contains($0.name.lowercased()) }
                fields += [.init(name: "Authorization", value: "final-token"), .init(name: "Cookie", value: "final-cookie")]
            }
            TestRules.publish([TestRules.mapRemote(host: "wrong.test", port: 80)], revision: 32, to: rules)
            f.expectedEndpoint = ("final.test", 80)
            #expect(try breakpointPerform(b, .continue(token: t.token, edit: .init(head: .request(target, headers: fields))), f) == .accepted)
            try #require(f.connections.count == 1)
            let upstream = try f.connect(0)
            let wire = try f.written(upstream)
            #expect(wire.contains("Host: final.test"))
            #expect(!wire.contains("old"))
            #expect(!wire.contains("source.test"))
            #expect(wire.contains("final-token") == explicit)
            #expect(wire.contains("final-cookie") == explicit)
            #expect(t.token.revision == 31)
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
            #expect(try f.flow("/original").provenance.ruleMatches?.revision == 31)
            #expect(f.connections.count == 1)
        }
    }

    @Test func localTargetAndMethodStayReadonlyAndFullBodyIsUnsupported() async throws {
        try await withConnectionFixture { f in
            let b = BreakpointCoordinator(clock: EmbeddedBreakpointClock(now: f.loop.now))
            // R1 intentional change class 1: a rule must rank above the Return File rule to act on its exchange.
            let c = f.context(rules: TestRules.provider([TestRules.breakpoint(.request), TestRules.mapLocal()]), breakpoints: b)
            let w = RecordingResponseWriter(channel: f.client)
            let x = f.admit("/local", writer: w, context: c)
            x.execute(); x.receiveRequest(.end(nil))
            let t = try #require(b.snapshot().first)
            #expect(t.routeKind == .local)
            guard case .request(let target, let fields) = t.effectiveHead else { return }
            for change in ["method", "target"] {
                var altered = target
                if change == "method" { altered.method = "POST" } else { altered.pathAndQuery = "/other" }
                #expect(try breakpointPerform(b, .continue(token: t.token, edit: .init(head: .request(altered, headers: fields))), f) == .invalid)
            }
            #expect(try breakpointPerform(b, .collectBody(token: t.token), f) == .unsupported)
            #expect(b.snapshot().first?.deadline == t.deadline)
            #expect(try breakpointPerform(b, .continue(token: t.token, edit: .init(head: .request(target, headers: fields + [.init(name: "X-Local", value: "yes")]))), f) == .accepted)
            // No asset store was supplied: the existing MapLocal admission rejects explicitly.
            #expect(x.localFailure == .ruleActionUnsupported)
            #expect(f.connections.isEmpty)
            var rule = TestRules.breakpoint(.request)
            rule.action = .breakpoint(direction: .request, mode: .fullBody)
            let fullContext = f.context(rules: TestRules.provider([rule]), breakpoints: b)
            let full = f.admit("/full", writer: RecordingResponseWriter(channel: f.client), context: fullContext)
            full.execute(); full.receiveRequest(.end(nil))
            #expect(full.localFailure == .ruleActionUnsupported)
            #expect(b.snapshot().isEmpty)
        }
    }

    @Test func connectionNominatedFieldsCannotBeEdited() async throws {
        try await withConnectionFixture { f in
            let (_, x, _, b) = breakpointExchange(f, headers: .init([("Connection", "X-Bound"), ("X-Bound", "old")]))
            defer { x.cancel(reason: "cleanup") }
            let t = try #require(b.snapshot().first)
            guard case .request(let target, let fields) = t.effectiveHead else { return }
            let changed = fields.map { $0.name.lowercased() == "x-bound" ? HeaderField(name: "X-Bound", value: "new") : $0 }
            #expect(try breakpointPerform(b, .continue(token: t.token, edit: .init(head: .request(target, headers: changed))), f) == .invalid)
            #expect(f.connections.isEmpty)
        }
    }
}

// Real socket/decoder coverage complements the controlled queue and race tests above.
extension BreakpointHeadTests {
    @Test func realHTTP1CoalescedUploadPausesBeforeAcquisitionAndEditsExactlyOnce() async throws {
        let b = BreakpointCoordinator()
        let rules = TestRules.provider([TestRules.breakpoint(.request)], revision: 50)
        let origin = try await HTTP2TestOrigin.start(protocols: ["http/1.1"], plaintext: true)
        do {
            let fixture = try await HTTP2ProxyFixture.start(origin: origin, rules: rules, breakpoints: b)
            do {
                let client = try await RawClient.connect(port: try #require(fixture.channel.localAddress?.port))
                do {
                    let body = String(repeating: "x", count: 30 * 1024)
                    // One raw write contains head+30KB body; decoder/read-batch coalescing, not a TCP packet claim.
                    try await client.send("POST http://localhost:\(origin.port)/paused HTTP/1.1\r\nHost: localhost:\(origin.port)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body)
                    let t = try await breakpointTicket(b, on: fixture.channel.eventLoop)
                    #expect(origin.counts.connections == 0)
                    #expect(origin.counts.requests == 0)
                    let paused = try await HTTP2FlowControlFixture.snapshot(fixture)
                    #expect(paused.pendingBytes > 0)
                    #expect(paused.pendingBytes <= 65_536)
                    guard case .request(var target, let fields) = t.effectiveHead else { throw HTTPTransportError.closed }
                    target.pathAndQuery = "/edited?q=2"
                    TestRules.publish([], revision: 51, to: rules)
                    #expect(await b.perform(.continue(token: t.token, edit: .init(head: .request(target,
                        headers: fields + [.init(name: "X-Edited", value: "yes")])))) == .accepted)
                    try await client.waitUntilClosed()
                    #expect(String(decoding: client.remainingBytes(), as: UTF8.self).contains("200 OK"))
                    #expect(origin.counts.requests == 1)
                    #expect(origin.counts.paths == ["/edited?q=2"])
                    #expect(origin.counts.requestHeaders.first?["x-edited"] == ["yes"])
                    let delivered = try #require(origin.counts.bodies["/edited?q=2"])
                    #expect(delivered.utf8.count == 30 * 1024)
                    #expect(delivered.utf8.elementsEqual(body.utf8))
                    let flow = try await waitForFlow(fixture.store) { $0.state == .completed }
                    #expect(flow.provenance.ruleMatches?.revision == 50)
                    #expect(flow.messages[.downstreamRequest]?.transferState == .finished)
                    #expect(flow.messages[.upstreamRequest]?.transferState == .finished)
                    #expect(try flow.messages[.upstreamRequest]?.body?.load().elementsEqual(Data(body.utf8)) == true)
                    #expect(b.snapshot().isEmpty)
                    try await client.close()
                } catch { b.shutdown(); try? await client.close(); throw error }
                try await fixture.stop()
            } catch { try? await fixture.stop(); throw error }
            try await origin.stop()
        } catch { try? await origin.stop(); throw error }
    }

    @Test func realHTTP2HeadersEndStreamAndHealthySiblingShareUnpausedParent() async throws {
        let b = BreakpointCoordinator()
        let rule = TestRules.breakpoint(.request, matcher: .init(path: .exact("/paused")))
        try await HTTP2TestOrigin.withOrigin(protocols: ["h2"]) { origin in
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true,
                rules: TestRules.provider([rule]), breakpoints: b) { fixture, client in
                let pending = Task { try await client.rawRequest(headers: breakpointH2Headers(origin, path: "/paused")) }
                do {
                    let t = try await breakpointTicket(b, on: fixture.channel.eventLoop)
                    #expect(origin.counts.connections == 0)
                    #expect(origin.counts.requests == 0)
                    #expect(try await client.rawRequest(headers: breakpointH2Headers(origin, path: "/sibling")).status == 200)
                    try await HTTP2FlowControlFixture.ping(client.channel)
                    let owner = try #require(fixture.connections.withLock { $0.first })
                    let reading = try await fixture.channel.eventLoop.flatSubmit {
                        owner.value.channel.getOption(ChannelOptions.autoRead)
                    }.boundedGet()
                    #expect(reading)
                    #expect(b.snapshot().count == 1)
                    #expect(await b.perform(.continue(token: t.token, edit: .init(head: t.effectiveHead))) == .accepted)
                    #expect(try await pending.value.status == 200)
                    #expect(origin.counts.paths == ["/sibling", "/paused"])
                    #expect(origin.counts.initialEndStreams == [true, true])
                    #expect(origin.counts.requests == 2)
                    #expect(b.snapshot().isEmpty)
                } catch { b.shutdown(); _ = try? await pending.value; throw error }
            }
        }
    }

    @Test(arguments: [false, true])
    func realEditedMethodCompletesWithoutInventingResponseBody(originalHEAD: Bool) async throws {
        let b = BreakpointCoordinator()
        var response = HTTP2TestOrigin.Response()
        response.headers = HTTPHeaders([("content-length", "5")]); response.body = "hello"; response.trailers = nil
        try await HTTP2TestOrigin.withOrigin(protocols: ["h2"], response: response) { origin in
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: false,
                rules: TestRules.provider([TestRules.breakpoint(.request)]), breakpoints: b) { fixture, client in
                let pending = Task { try await client.request(headers: .init([("host", "localhost:\(origin.port)")]),
                                                              method: originalHEAD ? .HEAD : .GET) }
                do {
                    let t = try await breakpointTicket(b, on: fixture.channel.eventLoop)
                    guard case .request(var target, let fields) = t.effectiveHead else { throw HTTPTransportError.closed }
                    target.method = originalHEAD ? "GET" : "HEAD"
                    #expect(await b.perform(.continue(token: t.token, edit: .init(head: .request(target, headers: fields)))) == .accepted)
                    let reply = try await pending.value
                    #expect(reply.status == 200)
                    #expect(reply.body.isEmpty)
                    #expect(reply.headers["content-length"] == [originalHEAD ? "5" : "0"])
                    #expect(origin.counts.requests == 1)
                    let flow = try await waitForFlow(fixture.store) { $0.state == .completed }
                    #expect(flow.messages[.upstreamResponse]?.observedBytes == (originalHEAD ? 5 : 0))
                    #expect(flow.messages[.downstreamResponse]?.observedBytes == 0)
                    #expect(flow.messages[.upstreamRequest]?.target?.method == (originalHEAD ? "GET" : "HEAD"))
                } catch { b.shutdown(); _ = try? await pending.value; throw error }
            }
        }
    }
}

func breakpointTicket(_ coordinator: BreakpointCoordinator, on loop: EventLoop) async throws -> BreakpointTicket {
    let promise = loop.makePromise(of: BreakpointTicket.self)
    let watcher = Task {
        for await _ in coordinator.changes() {
            if let ticket = coordinator.snapshot().first { promise.succeed(ticket); return }
        }
    }
    defer { watcher.cancel() }
    return try await promise.futureResult.boundedGet()
}

func breakpointH2Headers(_ origin: HTTP2TestOrigin, path: String) -> HPACKHeaders {
    HPACKHeaders([ (":method", "GET"), (":scheme", "https"), (":authority", "localhost:\(origin.port)"), (":path", path) ])
}

extension BreakpointHeadTests {
    @Test func duplicateCredentialsOnlyRebindNewValuesAcrossOrigins() async throws {
        try await withConnectionFixture { f in
            let (_, x, _, b) = breakpointExchange(f, headers: .init([("Cookie", "inherited"), ("Authorization", "old")]))
            x.receiveRequest(.end(nil))
            let t = try #require(b.snapshot().first)
            guard case .request(var target, let fields) = t.effectiveHead else { return }
            target.host = "final.test"
            f.expectedEndpoint = ("final.test", 80)
            let edit = BreakpointEdit(head: .request(target, headers: fields + [
                .init(name: "Cookie", value: "new"), .init(name: "authorization", value: "rebound")]))
            #expect(try breakpointPerform(b, .continue(token: t.token, edit: edit), f) == .accepted)
            try #require(f.connections.count == 1)
            let upstream = try f.connect(0)
            let wire = try f.written(upstream)
            #expect(!wire.contains("inherited"))
            #expect(!wire.contains("old"))
            #expect(wire.contains("Cookie: new"))
            #expect(wire.contains("authorization: rebound"))
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
        }
    }
}

extension BreakpointHeadTests {
    @Test func realMapLocalContinuesOriginalAssetAfterPermittedRequestHeaderEdit() async throws {
        let b = BreakpointCoordinator()
        try await withLocalAsset(Data("local paused response".utf8)) { asset in
            try await HTTP2TestOrigin.withOrigin(protocols: ["h2"]) { origin in
                try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true,
                    // R1 intentional change class 1: a rule must rank above the Return File rule to act on its exchange.
                    rules: asset.rules(higher: [TestRules.breakpoint(.request)]), assets: asset.store, breakpoints: b) { fixture, client in
                    let pending = Task { try await client.rawRequest(headers: breakpointH2Headers(origin, path: "/local")) }
                    do {
                        let t = try await breakpointTicket(b, on: fixture.channel.eventLoop)
                        guard case .request(var target, let fields) = t.effectiveHead else { throw HTTPTransportError.closed }
                        #expect(t.routeKind == .local)
                        target.pathAndQuery = "/forbidden"
                        #expect(await b.perform(.continue(token: t.token, edit: .init(head: .request(target, headers: fields)))) == .invalid)
                        #expect(b.snapshot().first?.token == t.token)
                        #expect(b.snapshot().first?.deadline == t.deadline)
                        guard case .request(let original, _) = t.effectiveHead else { throw HTTPTransportError.closed }
                        #expect(await b.perform(.continue(token: t.token, edit: .init(head: .request(original,
                            headers: fields + [.init(name: "X-Local", value: "allowed")])))) == .accepted)
                        let response = try await pending.value
                        #expect(response.status == 200)
                        #expect(response.body == "local paused response")
                        #expect(origin.counts.requests == 0)
                        #expect(origin.counts.connections == 0)
                        let flow = try await waitForFlow(fixture.store) { $0.state == .completed }
                        #expect(flow.provenance.generatedResponse?.assetID == asset.asset.id)
                        #expect(flow.messages[.upstreamRequest] == nil)
                    } catch { b.shutdown(); _ = try? await pending.value; throw error }
                }
            }
        }
    }
}

extension BreakpointHeadTests {
    @Test func nilAndFullBodyKeepUnsupportedBeforeContinuationPreparation() async throws {
        for injected in [false, true] {
            try await withConnectionFixture { f in
                let b = BreakpointCoordinator(clock: EmbeddedBreakpointClock(now: f.loop.now))
                var rule = TestRules.breakpoint(.request)
                if injected { rule.action = .breakpoint(direction: .request, mode: .fullBody) }
                let c = f.context(rules: TestRules.provider([TestRules.mapRemote(host: "elsewhere.test", port: 80), rule]),
                                  breakpoints: injected ? b : nil)
                let w = RecordingResponseWriter(channel: f.client)
                let x = f.admit("*", method: .OPTIONS, writer: w, context: c)
                x.execute(); x.receiveRequest(.end(nil))
                #expect(x.localFailure == .ruleActionUnsupported)
                #expect(b.snapshot().isEmpty)
                #expect(f.connections.isEmpty)
            }
        }
    }
}

extension BreakpointHeadTests {
    @Test func realServerStopAbandonsTicketsAndRestartReusesInjectedCoordinator() async throws {
        let b = BreakpointCoordinator()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            try await ProxyFixture.run(processLookup: .init(lookup: { _, _ in nil }),
                rules: TestRules.provider([TestRules.breakpoint(.request)]), breakpoints: b,
                drainDeadline: .init(schedule: { loop, expire in loop.execute(expire); return {} })) { f in
                let first = try await RawClient.connect(port: f.proxyPort)
                do {
                    try await first.send("GET http://127.0.0.1:\(f.origin.port)/hello HTTP/1.1\r\nHost: 127.0.0.1:\(f.origin.port)\r\nConnection: close\r\n\r\n")
                    let old = try await breakpointTicket(b, on: group.next())
                    #expect(f.origin.acceptedConnections == 0)
                    try await f.server.stop()
                    try await first.waitUntilClosed()
                    #expect(b.snapshot().isEmpty)
                    #expect(await b.perform(.cancel(token: old.token)) == .invalid)
                    try await first.close()
                    try await f.server.start()
                    let second = try await RawClient.connect(port: try #require(f.server.boundPort))
                    do {
                        try await second.send("GET http://127.0.0.1:\(f.origin.port)/hello HTTP/1.1\r\nHost: 127.0.0.1:\(f.origin.port)\r\nConnection: close\r\n\r\n")
                        let fresh = try await breakpointTicket(b, on: group.next())
                        #expect(fresh.contextID != old.contextID)
                        #expect(await b.perform(.continue(token: fresh.token, edit: .init(head: fresh.effectiveHead))) == .accepted)
                        try await second.waitUntilClosed()
                        #expect(String(decoding: second.remainingBytes(), as: UTF8.self).hasSuffix("hello"))
                        #expect(f.origin.acceptedConnections == 1)
                        #expect(b.snapshot().isEmpty)
                        try await second.close()
                    } catch { b.shutdown(); try? await second.close(); throw error }
                } catch { b.shutdown(); try? await first.close(); throw error }
            }
            try await group.shutdownGracefully()
        } catch { try? await group.shutdownGracefully(); throw error }
    }
}

// I1: admission bounds apply independently to both retained heads, before publication.
extension BreakpointHeadTests {
    @Test func ticketReservationBoundsBothHeadsAtExactCombinedByteBoundary() throws {
        // Metadata: http(4) + a(1) + port 80(2) + GET(3) + /(1) = 11.
        // Header x + ab + 32 = 35. Combined 46, not merely the 35-byte field block.
        let target = HTTPMessageTarget(scheme: "http", host: "a", port: 80, method: "GET", pathAndQuery: "/")
        let exact = HTTPMessageHead.request(target, headers: [.init(name: "x", value: "ab")])
        let over = HTTPMessageHead.request(target, headers: [.init(name: "x", value: "abc")])
        for originalOver in [false, true] {
            let b = BreakpointCoordinator(limits: .init(headerBytes: 46))
            defer { b.shutdown() }
            let invalid = breakpointBudgetTicket(original: originalOver ? over : exact, effective: originalOver ? exact : over)
            var mutation: HTTPMutationError?
            do { try b.reserve(invalid) { _ in } }
            catch let error as HTTPMutationError { mutation = error }
            #expect(mutation == .init(code: .headerBlockTooLarge, field: .headers))
            #expect(b.snapshot().count == 0)
        }
        let b = BreakpointCoordinator(limits: .init(headerBytes: 46))
        defer { b.shutdown() }
        let accepted = breakpointBudgetTicket(original: exact, effective: exact)
        #expect(try b.reserve(accepted) { _ in } == accepted.token)
        #expect(b.snapshot().count == 1)
    }

    @Test func ticketReservationBoundsRegularFieldCountAt256() throws {
        let target = HTTPMessageTarget(scheme: "http", host: "a", port: 80, method: "GET", pathAndQuery: "/")
        for count in [256, 257] {
            let head = HTTPMessageHead.request(target, headers: Array(repeating: .init(name: "x", value: ""), count: count))
            let b = BreakpointCoordinator()
            defer { b.shutdown() }
            var mutation: HTTPMutationError?
            do { try b.reserve(breakpointBudgetTicket(original: head, effective: head)) { _ in } }
            catch let error as HTTPMutationError { mutation = error }
            #expect(mutation == (count == 256 ? nil : .init(code: .tooManyHeaderFields, field: .headers)))
            #expect(b.snapshot().count == (count == 256 ? 1 : 0))
        }
    }

    @Test func oversizedOriginalShrunkByRulesNeverPublishesOrSchedulesTicket() async throws {
        try await withConnectionFixture { f in
            let b = BreakpointCoordinator(clock: EmbeddedBreakpointClock(now: f.loop.now))
            let c = f.context(rules: TestRules.provider([
                TestRules.headers(.request, [.remove(name: "X-Big")]), TestRules.breakpoint(.request)
            ]), breakpoints: b)
            let w = RecordingResponseWriter(channel: f.client)
            let x = f.admit("/oversize", headers: .init([("X-Big", String(repeating: "a", count: 70 * 1024))]), writer: w, context: c)
            defer { x.cancel(reason: "cleanup") }
            x.execute(); x.receiveRequest(.end(nil))
            #expect(x.localFailure == .ruleRejected)
            #expect(w.heads.map(\.status.code) == [502])
            #expect(w.body.contains("headerBlockTooLarge"))
            #expect(b.snapshot().count == 0)
            #expect(x.snapshot.breakpointTimers == 0)
            #expect(c.snapshot.pendingBytes == 0)
            #expect(f.connections.isEmpty)
        }
    }

    @Test func oversizedEditedTargetKeepsTicketAndOriginalDeadline() async throws {
        try await withConnectionFixture { f in
            let b = BreakpointCoordinator(clock: EmbeddedBreakpointClock(now: f.loop.now), limits: .init(headerBytes: 100))
            let (_, x, _, _) = breakpointExchange(f, coordinator: b)
            defer { x.cancel(reason: "cleanup") }
            let t = try #require(b.snapshot().first)
            guard case .request(var target, let fields) = t.effectiveHead else { return }
            target.pathAndQuery = "/" + String(repeating: "p", count: 100)
            let result = try breakpointPerform(b, .continue(token: t.token, edit: .init(head: .request(target, headers: fields))), f)
            #expect(result == .invalid)
            #expect(b.snapshot().first?.token == t.token)
            #expect(b.snapshot().first?.deadline == t.deadline)
            #expect(x.snapshot.breakpointTimers == 1)
            #expect(f.connections.isEmpty)
            // A failing old implementation may acquire: settle that owned future as well.
            if !f.connections.isEmpty { _ = try f.connect(0) }
        }
    }

    @Test(arguments: [false, true])
    func realHTTP1OversizedTicketHeadIsRejectedBeforePublication(shrinkEffective: Bool) async throws {
        let b = BreakpointCoordinator()
        var rules: [Rule] = shrinkEffective ? [TestRules.headers(.request, [.remove(name: "X-Big")])] : []
        rules.append(TestRules.breakpoint(.request))
        try await HTTP2TestOrigin.withOrigin(protocols: ["http/1.1"]) { origin in
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: false,
                rules: TestRules.provider(rules), breakpoints: b) { fixture, client in
                // Race two actual observable outcomes, not a sleep: old behavior publishes a
                // ticket; fixed behavior replies. BoundedGet is only a failure watchdog.
                let observed = fixture.channel.eventLoop.makePromise(of: Bool.self)
                let signalled = NIOLockedValueBox(false)
                let signal: @Sendable (Bool) -> Void = { published in
                    let first = signalled.withLockedValue { value in defer { value = true }; return !value }
                    if first { observed.succeed(published) }
                }
                let watcher = Task {
                    for await _ in b.changes() {
                        if !b.snapshot().isEmpty { signal(true); return }
                    }
                }
                defer { watcher.cancel() }
                let request = Task {
                    do {
                        let response = try await client.request(headers: .init([
                            ("Host", "localhost:\(origin.port)"), ("X-Big", String(repeating: "a", count: 70 * 1024))]))
                        signal(false)
                        return response
                    } catch { signal(false); throw error }
                }
                do {
                    let published = try await observed.futureResult.boundedGet()
                    #expect(!published)
                    #expect(b.snapshot().count == 0)
                    let snapshot = try await HTTP2FlowControlFixture.snapshot(fixture)
                    #expect(snapshot.exchanges.allSatisfy { $0.breakpointTimers == 0 })
                    #expect(snapshot.pendingBytes == 0)
                    // Always settle the pending request if the intentionally old behavior paused it.
                    if published { b.shutdown() }
                    let response = try await request.value
                    #expect(response.status == 502)
                    #expect(response.body.contains("headerBlockTooLarge"))
                    #expect(origin.counts.connections == 0)
                    #expect(origin.counts.requests == 0)
                } catch { b.shutdown(); _ = try? await request.value; throw error }
            }
        }
    }

    @Test func realHTTP1HeaderShrinkWithoutBreakpointRetainsLegacyForwarding() async throws {
        let b = BreakpointCoordinator()
        try await HTTP2TestOrigin.withOrigin(protocols: ["http/1.1"]) { origin in
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: false,
                rules: TestRules.provider([TestRules.headers(.request, [.remove(name: "X-Big")])]), breakpoints: b) { _, client in
                let response = try await client.request(headers: .init([
                    ("Host", "localhost:\(origin.port)"), ("X-Big", String(repeating: "a", count: 70 * 1024))]))
                #expect(response.status == 200)
                #expect(origin.counts.requests == 1)
                #expect(origin.counts.requestHeaders.first?["x-big"].isEmpty == true)
                #expect(b.snapshot().count == 0)
            }
        }
    }
}

private func breakpointBudgetTicket(original: HTTPMessageHead, effective: HTTPMessageHead) -> BreakpointTicket {
    BreakpointTicket(token: .init(ticketID: .init(), generation: 0, revision: 1), contextID: UUID(), flowID: nil,
        direction: .request, originalHead: original, effectiveHead: effective, routeKind: .network, source: .passive,
        mode: .headers, state: .pausedHeaders, matchedAt: .uptimeNanoseconds(0), deadline: .uptimeNanoseconds(120_000_000_000),
        matches: .init(revision: 1, ruleIDs: [], total: 0))
}

extension BreakpointHeadTests {
    // Real socket fixtures share the process with legacy subsecond timing tests.
    @Suite(.serialized) struct Responses {
        @Test func responseHeadPausedUntilEditedContinue() async throws {
            try await withConnectionFixture { f in
                let (c, x, w, b) = responseBreakpointExchange(f)
                defer { x.cancel(reason: "cleanup") }
                let upstream = try f.connect(0)
                try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nX-Original: x\r\nContent-Length: 5\r\n\r\nhello"))
                #expect(w.heads.isEmpty)
                #expect(w.body.isEmpty)
                let ticket = try #require(b.snapshot().first)
                #expect(ticket.direction == .response)
                #expect(x.snapshot.breakpointTimers == 1)
                let invalid = HTTPMessageHead.response(status: 99, reason: "bad", headers: ticket.effectiveHead.headers)
                #expect(try breakpointPerform(b, .continue(token: ticket.token, edit: .init(head: invalid)), f) == .invalid)
                #expect(b.snapshot().first?.deadline == ticket.deadline)
                let edited = HTTPMessageHead.response(status: 201, reason: "Created", headers: ticket.effectiveHead.headers + [.init(name: "X-Edited", value: "y")])
                #expect(try breakpointPerform(b, .continue(token: ticket.token, edit: .init(head: edited)), f) == .accepted)
                #expect(w.heads.map(\.status.code) == [201])
                #expect(w.heads.first?.headers["x-edited"] == ["y"])
                #expect(w.body == "hello")
                #expect(w.ends == 1 && w.finishes == 1)
                #expect(c.snapshot.pendingBytes == 0)
                #expect(x.snapshot.breakpointTimers == 0)
                breakpointAdvance(f, b, by: .seconds(120))
                #expect(w.heads.count == 1)
            }
        }

        @Test func responseBodyArrivingDuringPauseIsQueuedAndDeliveredInOrder() async throws {
            try await withConnectionFixture { f in
                let (c, x, w, b) = responseBreakpointExchange(f)
                defer { x.cancel(reason: "cleanup") }
                let upstream = try f.connect(0)
                let body = String(repeating: "0123456789", count: 2048)
                try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 20480\r\n\r\n" + body))
                #expect(w.heads.isEmpty && w.body.isEmpty)
                #expect(c.snapshot.pendingBytes == 20481) // body plus the bounded END slot
                #expect(x.snapshot.pendingBodyCapacity >= 20480)
                x.downstreamWritabilityChanged(true)
                // EmbeddedChannel always reports autoRead=true; the real h1 test verifies its gate.
                // A fully queued final response remains deliverable after an ordinary upstream close.
                try upstream.close().wait()
                f.loop.run()
                let ticket = try #require(b.snapshot().first)
                #expect(try breakpointPerform(b, .continue(token: ticket.token, edit: .init(head: ticket.effectiveHead)), f) == .accepted)
                #expect(w.body == body)
                #expect(w.heads.map(\.status.code) == [200])
                #expect(w.ends == 1 && w.finishes == 1)
                #expect(c.snapshot.pendingBytes == 0)
                #expect(x.snapshot.pendingBodyCapacity == 0)
            }
        }

        @Test func responseQueueOverBudgetFailsNotDrops() async throws {
            try await withConnectionFixture { f in
                var limits = HTTPTransportLimits(); limits.pendingBytesPerExchange = 128
                let (c, x, w, b) = responseBreakpointExchange(f, limits: limits)
                let upstream = try f.connect(0)
                try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 200\r\n\r\n" + String(repeating: "x", count: 200)))
                #expect(x.localFailure == .pendingBytesExceeded)
                #expect(w.heads.map(\.status.code) == [502])
                #expect(!w.body.contains(String(repeating: "x", count: 128)))
                #expect(w.ends == 1 && w.finishes == 1)
                #expect(c.snapshot.pendingBytes == 0 && b.snapshot().isEmpty)
            }
        }

        @Test func requestThenResponseBreakpointsOneTicketEach() async throws {
            try await withConnectionFixture { f in
                let b = BreakpointCoordinator(clock: EmbeddedBreakpointClock(now: f.loop.now))
                let c = f.context(rules: TestRules.provider([TestRules.breakpoint(.request), TestRules.breakpoint(.request),
                    TestRules.breakpoint(.response), TestRules.breakpoint(.response)], revision: 77), breakpoints: b)
                let (_, x, w, _) = breakpointExchange(f, coordinator: b, context: c)
                defer { x.cancel(reason: "cleanup") }
                x.receiveRequest(.end(nil))
                let first = try #require(b.snapshot().first)
                #expect(b.snapshot().count == 1 && first.direction == .request)
                #expect(try breakpointPerform(b, .continue(token: first.token, edit: .init(head: first.effectiveHead)), f) == .accepted)
                let upstream = try f.connect(0)
                try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
                let second = try #require(b.snapshot().first)
                #expect(b.snapshot().count == 1 && second.direction == .response)
                #expect(second.token.ticketID != first.token.ticketID && second.token.revision == 77)
                #expect(try breakpointPerform(b, .continue(token: second.token, edit: .init(head: second.effectiveHead)), f) == .accepted)
                #expect(w.finishes == 1 && b.snapshot().isEmpty)
            }
        }

        @Test(arguments: [204, 304])
        func originalNoBodyStatusEditedTo200HasTruthfulZeroLength(status: Int) async throws {
            try await withConnectionFixture { f in
                let (_, x, w, b) = responseBreakpointExchange(f)
                defer { x.cancel(reason: "cleanup") }
                let upstream = try f.connect(0)
                let length = status == 304 ? "Content-Length: 99\r\n" : ""
                try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 \(status) Empty\r\n\(length)\r\n"))
                let t = try #require(b.snapshot().first)
                let edited = HTTPMessageHead.response(status: 200, reason: "OK", headers: t.effectiveHead.headers)
                #expect(try breakpointPerform(b, .continue(token: t.token, edit: .init(head: edited)), f) == .accepted)
                #expect(w.heads.first?.headers["content-length"] == ["0"])
                #expect(w.body.isEmpty && w.finishes == 1)
            }
        }

        @Test(arguments: [204, 304])
        func editedNoBodyStatusConsumesAndCapturesOriginalWithoutDelivering(status: Int) async throws {
            try await withConnectionFixture { f in
                let (_, x, w, b) = responseBreakpointExchange(f)
                defer { x.cancel(reason: "cleanup") }
                let upstream = try f.connect(0)
                try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello"))
                let t = try #require(b.snapshot().first)
                #expect(try breakpointPerform(b, .continue(token: t.token, edit: .init(head: .response(status: status, reason: "Empty", headers: t.effectiveHead.headers))), f) == .accepted)
                #expect(w.heads.map(\.status.code) == [UInt(status)])
                #expect(w.body.isEmpty && w.finishes == 1)
                let flow = try f.flow("/response-paused")
                #expect(flow.messages[.upstreamResponse]?.observedBytes == 5)
                #expect(flow.messages[.downstreamResponse]?.observedBytes == 0)
            }
        }
    }
}

func responseBreakpointExchange(_ f: ConnectionFixture, limits: HTTPTransportLimits = .init(),
    coordinator: BreakpointCoordinator? = nil) -> (ClientConnectionContext, HTTPExchange, RecordingResponseWriter, BreakpointCoordinator) {
    let b = coordinator ?? BreakpointCoordinator(clock: EmbeddedBreakpointClock(now: f.loop.now))
    let c = f.context(limits: limits, rules: TestRules.provider([TestRules.breakpoint(.response)]), breakpoints: b)
    let w = RecordingResponseWriter(channel: f.client)
    let x = f.admit("/response-paused", writer: w, context: c)
    x.execute(); x.receiveRequest(.end(nil))
    return (c, x, w, b)
}

extension BreakpointHeadTests.Responses {
    @Test(arguments: [false, true])
    func mapLocalResponseBreakpointBehavesSame(cancel: Bool) async throws {
        let b = BreakpointCoordinator()
        try await withLocalAsset(Data("local paused response".utf8)) { asset in
            let reads = NIOLockedValueBox(0)
            let hooks = LocalResponseSource.Hooks(beforeRead: { _, _ in reads.withLockedValue { $0 += 1 } })
            try await HTTP2TestOrigin.withOrigin(protocols: ["h2"]) { origin in
                try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: false,
                    // R1 intentional change class 1: a rule must rank above the Return File rule to act on its exchange.
                    rules: asset.rules(higher: [TestRules.breakpoint(.response)]), assets: asset.store, breakpoints: b,
                    localResponseHooks: hooks) { fixture, client in
                    let pending = Task { try await client.request() }
                    do {
                        let t = try await breakpointTicket(b, on: fixture.channel.eventLoop)
                        #expect(t.routeKind == .local && t.direction == .response)
                        #expect(reads.withLockedValue { $0 } == 0)
                        if cancel { #expect(await b.perform(.cancel(token: t.token)) == .accepted) }
                        else {
                            #expect(await b.perform(.continue(token: t.token, edit: .init(head: .response(status: 201, reason: "Created",
                                headers: t.effectiveHead.headers + [.init(name: "X-Edited", value: "yes")])))) == .accepted)
                        }
                        let reply = try await pending.value
                        #expect(reply.status == (cancel ? 502 : 201))
                        #expect(!reply.body.contains("HTTP/1.1"))
                        #expect(reply.headers["content-length"] == [String(reply.body.utf8.count)])
                        if !cancel { #expect(reply.body == "local paused response" && reply.headers["x-edited"] == ["yes"]) }
                        else { #expect(reads.withLockedValue { $0 } == 0) }
                        #expect(origin.counts.requests == 0)
                        _ = try await waitForFlow(fixture.store) { $0.state != .inProgress }
                        #expect(b.snapshot().isEmpty)
                    } catch { b.shutdown(); _ = try? await pending.value; throw error }
                }
            }
        }
    }
}

extension BreakpointHeadTests.Responses {
    @Test(arguments: [false, true])
    func disabledPauseBypassesTicketOnlyBudgetAndFullBodyWhileKeepingHeaderRules(fullBody: Bool) async throws {
        try await withConnectionFixture { f in
            let b = BreakpointCoordinator(clock: EmbeddedBreakpointClock(now: f.loop.now))
            b.setAdmissionEnabled(false, existing: .keep)
            var breakpoint = TestRules.breakpoint(.request)
            if fullBody { breakpoint.action = .breakpoint(direction: .request, mode: .fullBody) }
            let c = f.context(rules: TestRules.provider([
                TestRules.headers(.request, [.remove(name: "X-Big"), .set(name: "X-Applied", value: "yes")]), breakpoint,
                TestRules.headers(.response, [.set(name: "X-Response", value: "yes")]), TestRules.breakpoint(.response)
            ]), breakpoints: b)
            let w = RecordingResponseWriter(channel: f.client)
            let x = f.admit("/disabled", headers: .init([("X-Big", String(repeating: "a", count: 70 * 1024))]), writer: w, context: c)
            x.execute(); x.receiveRequest(.end(nil))
            defer { x.cancel(reason: "cleanup") }
            try #require(f.connections.count == 1)
            let upstream = try f.connect(0)
            let wire = try f.written(upstream)
            #expect(!wire.contains("X-Big") && wire.contains("X-Applied: yes"))
            try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"))
            #expect(w.heads.map(\.status.code) == [200] && w.body == "ok")
            #expect(w.heads.first?.headers["x-response"] == ["yes"])
            #expect(b.snapshot().isEmpty && x.snapshot.breakpointTimers == 0)
        }
    }

    @Test func responseQueueCopiesReadableSlicesAndPreservesTrailers() async throws {
        try await withConnectionFixture { f in
            let (c, x, w, b) = responseBreakpointExchange(f)
            defer { x.cancel(reason: "cleanup") }
            _ = try f.connect(0)
            x.receiveResponse(.head(.init(version: .http1_1, status: .ok, headers: .init([("Transfer-Encoding", "chunked")]))), attempt: 0)
            var buffer = ByteBuffer(repeating: 120, count: 1_000_000)
            buffer.moveReaderIndex(to: 999_998)
            x.receiveResponse(.body(buffer), attempt: 0)
            x.receiveResponse(.body(ByteBuffer(string: "yz")), attempt: 0)
            x.receiveResponse(.end(.init([("X-End", "tail")])), attempt: 0)
            #expect(x.snapshot.pendingBodyCapacity < 1024)
            #expect(c.snapshot.pendingBytes == 45) // 4 bytes + X-End(5)+tail(4)+32
            let t = try #require(b.snapshot().first)
            #expect(try breakpointPerform(b, .continue(token: t.token, edit: .init(head: t.effectiveHead)), f) == .accepted)
            #expect(w.body == "xxyz" && w.ends == 1)
            let flow = try f.flow("/response-paused")
            #expect(flow.messages[.downstreamResponse]?.trailers.values(for: "x-end") == ["tail"])
            #expect(c.snapshot.pendingBytes == 0)
        }
    }

    @Test(arguments: [204, 304], [false, true])
    func realNoBodyStatusEditCompletesWithZeroFraming(status: Int, downstreamH2: Bool) async throws {
        let b = BreakpointCoordinator()
        var response = HTTP2TestOrigin.Response(); response.status = .init(statusCode: status)
        response.headers = status == 304 ? .init([("Content-Length", "99")]) : .init()
        response.body = ""; response.trailers = nil
        try await HTTP2TestOrigin.withOrigin(protocols: ["h2"], response: response) { origin in
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: downstreamH2,
                rules: TestRules.provider([TestRules.breakpoint(.response)]), breakpoints: b) { fixture, client in
                let pending = Task { try await client.request(headers: .init([("Host", "localhost:\(origin.port)")])) }
                do {
                    let t = try await breakpointTicket(b, on: fixture.channel.eventLoop)
                    #expect(await b.perform(.continue(token: t.token, edit: .init(head: .response(status: 200, reason: "OK", headers: t.effectiveHead.headers)))) == .accepted)
                    let reply = try await pending.value
                    #expect(reply.status == 200 && reply.body.isEmpty)
                    #expect(reply.headers["content-length"] == ["0"])
                    _ = try await waitForFlow(fixture.store) { $0.state == .completed }
                } catch { b.shutdown(); _ = try? await pending.value; throw error }
            }
        }
    }

    @Test func failedServerBindSealsCoordinatorUntilExplicitNewRun() async throws {
        try await ProxyFixture.run(processLookup: .init(lookup: { _, _ in nil })) { occupied in
            let b = BreakpointCoordinator()
            var bindFailed = false
            do {
                try await ProxyFixture.run(configure: { $0.port = occupied.proxyPort; $0.portFallbackCount = 0 },
                    processLookup: .init(lookup: { _, _ in nil }), breakpoints: b) { _ in Issue.record("occupied port bound") }
            } catch { bindFailed = true }
            #expect(bindFailed)
            let head = HTTPMessageHead.request(.init(scheme: "http", host: "a", port: 80, method: "GET", pathAndQuery: "/"), headers: [])
            let ticket = breakpointBudgetTicket(original: head, effective: head)
            var rejected = false
            do { try b.reserve(ticket) { _ in } } catch { rejected = true }
            #expect(rejected && b.snapshot().isEmpty)
            b.shutdown()
            try await ProxyFixture.run(processLookup: .init(lookup: { _, _ in nil }), breakpoints: b) { _ in
                let reserved = try b.reserve(ticket) { _ in }
                #expect(reserved == ticket.token)
                b.shutdown()
            }
        }
    }
}


extension BreakpointHeadTests.Responses {
    enum CompletedH2Response: CaseIterable, Sendable {
        case pausedBody, pausedEmptyAfterInterim, unpausedBody
    }

    // Catches using trailers' END_STREAM at Continue instead of the actual final head's fact.
    // The empty-after-103 control also catches freezing the first (informational) metadata.
    @Test(arguments: CompletedH2Response.allCases)
    func completedH2ResponseRetainsFinalHeadFraming(scenario: CompletedH2Response) async throws {
        let paused = scenario != .unpausedBody
        let empty = scenario == .pausedEmptyAfterInterim
        let b = BreakpointCoordinator(limits: .init(ticketSeconds: 3))
        var response = HTTP2TestOrigin.Response()
        response.headers = .init([("x-source", "origin")])
        response.body = "hello"
        response.headersOnly = empty
        response.informational = empty ? .init([("x-info", "before-final")]) : nil
        try await HTTP2TestOrigin.withOrigin(protocols: ["h2"], response: response) { origin in
            let fixture = try await HTTP2ProxyFixture.start(origin: origin,
                rules: TestRules.provider(paused ? [TestRules.breakpoint(.response)] : []), breakpoints: b)
            do {
                let client = try await RawClient.connect(port: try #require(fixture.channel.localAddress?.port))
                do {
                    try await client.send("CONNECT localhost:\(origin.port) HTTP/1.1\r\nHost: localhost:\(origin.port)\r\n\r\n")
                    let connected = try await client.receive(until: "\r\n\r\n")
                    #expect(connected.hasPrefix("HTTP/1.1 200 "))
                    try await client.startTLS(trustRoots: .certificates([
                        NIOSSLCertificate(bytes: fixture.ca.rootCertificateDER, format: .der)
                    ]), serverName: "localhost")
                    try await client.send("GET /framing HTTP/1.1\r\nHost: localhost:\(origin.port)\r\nConnection: close\r\n\r\n")
                    var ticket: BreakpointTicket?
                    if paused {
                        let t = try await breakpointTicket(b, on: fixture.channel.eventLoop)
                        ticket = t
                        // A body contributes 5; x-finish + done + field overhead contributes 44.
                        // No request bytes remain, so 49 proves trailers/END reached this queue.
                        // Empty HEADERS+END_STREAM queues only its one-unit END slot.
                        let deadline = ContinuousClock.now + .seconds(5)
                        while try await HTTP2FlowControlFixture.snapshot(fixture).pendingBytes != (empty ? 1 : 49) {
                            guard ContinuousClock.now < deadline else {
                                throw WaitTimeout(description: "complete h2 response did not enter paused queue")
                            }
                            await Task.yield()
                        }
                        let snapshot = try await HTTP2FlowControlFixture.snapshot(fixture)
                        #expect(snapshot.exchanges.count == 1)
                        #expect(snapshot.exchanges.first?.breakpointTimers == 1)
                        if empty {
                            let interim = try await client.receive(until: "\r\n\r\n")
                            #expect(interim.hasPrefix("HTTP/1.1 103 "))
                            #expect(interim.contains("x-info: before-final\r\n"))
                        }
                        #expect(client.remainingBytes().isEmpty) // no final head before Continue
                        #expect(await b.perform(.continue(token: t.token, edit: .init(head: t.effectiveHead))) == .accepted)
                    }
                    // A raw collector drains even the old invalid CL0+payload, so RED cleanup
                    // cannot hang behind an HTTP parser that accepted an apparently empty reply.
                    try await client.waitUntilClosed()
                    let head = try await client.receive(until: "\r\n\r\n")
                    #expect(head.hasPrefix("HTTP/1.1 200 OK\r\n"))
                    #expect(head.contains("x-source: origin\r\n"))
                    if empty {
                        #expect(head.lowercased().contains("content-length: 0\r\n"))
                        #expect(!head.lowercased().contains("transfer-encoding:"))
                    } else {
                        #expect(head.lowercased().contains("transfer-encoding: chunked\r\n"))
                        #expect(!head.lowercased().contains("content-length:"))
                    }
                    // Entire remainder, not a convenience decoder's first response: proves
                    // exact entity, chunk boundaries, trailers and absence of surplus bytes.
                    let bodyFrame = empty ? "" : "5\r\nhello\r\n0\r\nx-finish: done\r\n\r\n"
                    #expect(client.remainingBytes() == Array(bodyFrame.utf8))
                    let flow = try await waitForFlow(fixture.store) { $0.state == .completed }
                    for boundary in [HTTPMessageBoundary.upstreamResponse, .downstreamResponse] {
                        let message = try #require(flow.messages[boundary])
                        #expect(message.observedBytes == (empty ? 0 : 5))
                        #expect(message.headers.values(for: "x-source") == ["origin"])
                        if !empty {
                            #expect(try message.body?.load() == Data("hello".utf8))
                            #expect(message.trailers.values(for: "x-finish") == ["done"])
                        }
                    }
                    #expect(origin.counts.negotiated == [.http2])
                    #expect(origin.counts.requests == 1 && b.snapshot().isEmpty)
                    var settled = try await HTTP2FlowControlFixture.snapshot(fixture)
                    #expect(settled.pendingBytes == 0 && settled.exchanges.isEmpty)
                    if let t = ticket, !empty {
                        // Real owner-loop deadline barrier, not a sleep or fake-clock mismatch.
                        try await fixture.channel.eventLoop.scheduleTask(deadline: t.deadline + .milliseconds(1)) {}.futureResult.boundedGet()
                        #expect(await b.perform(.continue(token: t.token, edit: .init(head: t.effectiveHead))) == .invalid)
                        #expect(client.remainingBytes() == Array(bodyFrame.utf8))
                        #expect(fixture.store.allFlows().count == 1 && b.snapshot().isEmpty)
                        settled = try await HTTP2FlowControlFixture.snapshot(fixture)
                        #expect(settled.pendingBytes == 0 && settled.exchanges.isEmpty)
                    }
                    b.shutdown(); try await client.close()
                } catch { b.shutdown(); try? await client.close(); throw error }
                try await fixture.stop()
            } catch { try? await fixture.stop(); throw error }
        }
    }
}

// Phase fix I1 (design §11): stop revokes paused tickets before the bounded connection drain, so a
// paused ticket neither holds stop until the drain deadline nor lets a late Continue reach the origin.
extension BreakpointHeadTests {
    @Test func stopRevokesPausedTicketBeforeNonImmediateDrainDeadline() async throws {
        let b = BreakpointCoordinator()
        let expiries = NIOLockedValueBox<[@Sendable () -> Void]>([])
        let deadline = ProxyDrainDeadline(schedule: { _, expire in
            expiries.withLockedValue { $0.append(expire) }
            return {}
        })
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            try await ProxyFixture.run(processLookup: .init(lookup: { _, _ in nil }),
                rules: TestRules.provider([TestRules.breakpoint(.request)]), breakpoints: b, drainDeadline: deadline) { f in
                let client = try await RawClient.connect(port: f.proxyPort)
                do {
                    // Keep-alive: only the revoked exchange can let this connection drain.
                    try await client.send("GET http://127.0.0.1:\(f.origin.port)/hello HTTP/1.1\r\nHost: 127.0.0.1:\(f.origin.port)\r\n\r\n")
                    let ticket = try await breakpointTicket(b, on: group.next())
                    let finished = ManagedAtomicFlag()
                    let stop = Task { try await f.server.stop(); finished.set() }
                    let promptly = (try? await waitUntil(timeout: .seconds(3), "stop without the drain deadline") { finished.isSet }) != nil
                    // Stop has begun: a late Continue must not revive the request.
                    #expect(await b.perform(.continue(token: ticket.token, edit: .init(head: ticket.effectiveHead))) == .invalid)
                    if !promptly { for expire in expiries.withLockedValue({ $0 }) { expire() } }
                    try await stop.value
                    #expect(promptly, "stop waited for the drain deadline while a ticket was paused")
                    try await client.waitUntilClosed()
                    let response = String(decoding: client.remainingBytes(), as: UTF8.self)
                    #expect(response.components(separatedBy: "HTTP/1.1 502").count - 1 == 1)
                    #expect(response.contains(HTTPLocalFailureText.breakpoint(.breakpointCancelled)))
                    #expect(f.origin.acceptedConnections == 0)
                    #expect(b.snapshot().isEmpty)
                    try await client.close()
                } catch { b.shutdown(); for expire in expiries.withLockedValue({ $0 }) { expire() }; try? await client.close(); throw error }
            }
            try await group.shutdownGracefully()
        } catch { try? await group.shutdownGracefully(); throw error }
    }
}

private final class ManagedAtomicFlag: Sendable {
    private let value = NIOLockedValueBox(false)
    func set() { value.withLockedValue { $0 = true } }
    var isSet: Bool { value.withLockedValue { $0 } }
}
