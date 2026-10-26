import CertKit
import FlowStore
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing
import os
@testable import ProxyCore
@testable import RulesEngine

/// Rules, breakpoints and Compose together, end to end on real sockets: every scenario runs once
/// with an HTTP/1 client through the plain-HTTP forward proxy and once with an HTTP/2 client and
/// an HTTP/2 origin through MITM (forward-proxy plain HTTP is HTTP/1 only). Origins are loopback
/// fixtures whose counters record what really arrived; expectations are literals. Each scenario
/// ends by checking that pending quota, exchanges, pool acquisitions, tickets, body pins and
/// transient file budgets are back to zero.
@Suite(.serialized, .timeLimit(.minutes(3)), .productionChinese) struct RulesComposeEndToEndTests {
    // MARK: 1. Header rule + Map Remote

    @Test(arguments: [false, true])
    func headerRuleAndMapRemoteApplyTogether(h2: Bool) async throws {
        try await withOrigins(h2: h2) { a, b in
            let header = TestRules.headers(.request, [.set(name: "X-Rule", value: "applied"), .remove(name: "X-Drop")])
            let remote = TestRules.mapRemote(scheme: h2 ? "https" : "http", host: "127.0.0.1", port: b.port)
            try await withLeg(h2: h2, origin: a, rules: TestRules.provider([header, remote]), trusted: [a.ca, b.ca]) { leg in
                let reply = try await leg.send(path: "/both?x=1", headers: [("X-Drop", "1"), ("X-Keep", "1"), ("Cookie", "s=1")])
                #expect(reply.status == 200)
                #expect(reply.body == Array("fixture-body".utf8))
                #expect(a.counts.connections == 0 && a.counts.requests == 0)
                #expect(b.counts.paths == ["/both?x=1"])
                let seen = try #require(b.counts.requestHeaders.first)
                #expect(seen["x-rule"] == ["applied"])
                #expect(seen["x-drop"].isEmpty)
                #expect(seen["x-keep"] == ["1"])
                #expect(seen["cookie"].isEmpty) // cross-origin Map Remote drops inherited credentials
                if h2 { #expect(b.counts.authorities == ["127.0.0.1:\(b.port)"]) }
                else { #expect(seen["host"] == ["127.0.0.1:\(b.port)"]) }
                let flow = try await waitForFlow(leg.fixture.store) { $0.state == .completed }
                #expect(flow.messages[.downstreamRequest]?.target?.port == a.port)
                #expect(flow.messages[.downstreamRequest]?.headers.contains(HeaderField(name: "X-Drop", value: "1")) == true
                        || flow.messages[.downstreamRequest]?.headers.contains(HeaderField(name: "x-drop", value: "1")) == true)
                #expect(flow.messages[.upstreamRequest]?.target?.port == b.port)
                #expect(flow.messages[.upstreamRequest]?.headers.contains { $0.name.lowercased() == "x-drop" } == false)
                #expect(Set(flow.provenance.ruleMatches?.ruleIDs ?? []) == [header.id, remote.id])
                try await RulesComposeBarriers.expectIdle(leg.fixture)
            }
        }
    }

    // MARK: 2. Map Local + response header rule

    @Test(arguments: [false, true])
    func mapLocalWithResponseHeaderRule(h2: Bool) async throws {
        let bytes = Data((0..<70_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try await withLocalAsset(bytes) { asset in
            try await withOrigins(h2: h2) { origin, _ in
                let edit = TestRules.headers(.response, [.set(name: "X-Local-Edited", value: "yes")])
                // R1 intentional change class 1: a rule must rank above the Return File rule to act on its exchange.
                try await withLeg(h2: h2, origin: origin, rules: asset.rules(higher: [edit]), assets: asset.store) { leg in
                    let reply = try await leg.send(path: "/local")
                    #expect(reply.status == 200)
                    #expect(reply.headers["x-local-edited"] == ["yes"])
                    #expect(reply.headers["content-length"] == ["70000"])
                    #expect(reply.headers["transfer-encoding"].isEmpty)
                    #expect(reply.body == Array(bytes))
                    #expect(origin.counts.connections == 0)
                    let flow = try await waitForFlow(leg.fixture.store) { $0.state == .completed }
                    #expect(flow.provenance.generatedResponse?.assetID == asset.asset.id)
                    #expect(flow.messages[.upstreamRequest] == nil)
                    #expect(try flow.messages[.downstreamResponse]?.body?.load() == bytes)
                    #expect(flow.messages[.downstreamResponse]?.headers.contains { $0.name.lowercased() == "x-local-edited" } == true)
                    #expect(flow.messages[.generatedResponse]?.headers.contains { $0.name.lowercased() == "x-local-edited" } == false)
                    try await RulesComposeBarriers.expectIdle(leg.fixture)
                    // The managed asset is persistent: exactly its size stays charged.
                    #expect(asset.budgets.snapshot().bytes[.asset] == Int64(bytes.count))
                }
            }
        }
    }

    // MARK: 3. Request breakpoint edits the URL to another origin

    @Test(arguments: [false, true])
    func requestBreakpointCrossOriginEditStripsCredentialsAndReachesOriginB(h2: Bool) async throws {
        let coordinator = BreakpointCoordinator()
        try await withOrigins(h2: h2) { a, b in
            try await withLeg(h2: h2, origin: a, rules: TestRules.provider([TestRules.breakpoint(.request)]),
                              breakpoints: coordinator, trusted: [a.ca, b.ca]) { leg in
                let pending = Task {
                    try await leg.send(path: "/a?x=1", headers: [("Authorization", "Basic a"), ("Cookie", "s=1"), ("X-Keep", "1")])
                }
                do {
                    let ticket = try await RulesComposeBarriers.ticket(coordinator, on: leg.loop)
                    #expect(a.counts.connections == 0) // paused before any origin acquisition
                    guard case .request(var target, let fields) = ticket.effectiveHead else { throw WaitTimeout(description: "not a request") }
                    target.host = "127.0.0.1"
                    target.port = b.port
                    target.pathAndQuery = "/b?y=2"
                    #expect(await coordinator.perform(.continue(token: ticket.token, edit: .init(head: .request(target, headers: fields)))) == .accepted)
                    let reply = try await pending.value
                    #expect(reply.status == 200)
                    #expect(reply.body == Array("fixture-body".utf8))
                } catch { coordinator.shutdown(); _ = try? await pending.value; throw error }
                #expect(a.counts.connections == 0 && a.counts.requests == 0)
                #expect(b.counts.paths == ["/b?y=2"])
                let seen = try #require(b.counts.requestHeaders.first)
                #expect(seen["authorization"].isEmpty)
                #expect(seen["cookie"].isEmpty)
                #expect(seen["x-keep"] == ["1"])
                if h2 { #expect(b.counts.authorities == ["127.0.0.1:\(b.port)"]) }
                else { #expect(seen["host"] == ["127.0.0.1:\(b.port)"]) }
                let flow = try await waitForFlow(leg.fixture.store) { $0.state == .completed }
                #expect(flow.messages[.downstreamRequest]?.target?.pathAndQuery == "/a?x=1")
                #expect(flow.messages[.upstreamRequest]?.target?.port == b.port)
                #expect(flow.messages[.upstreamRequest]?.target?.pathAndQuery == "/b?y=2")
                try await RulesComposeBarriers.expectIdle(leg.fixture, breakpoints: coordinator)
            }
        }
    }

    // MARK: 4. Response breakpoint replaces the full body

    @Test(arguments: [false, true])
    func responseBreakpointFullBodyEditDeliversNewBodyWithItsLength(h2: Bool) async throws {
        let coordinator = BreakpointCoordinator()
        var rule = TestRules.breakpoint(.response)
        rule.action = .breakpoint(direction: .response, mode: .fullBody)
        var response = HTTP2TestOrigin.Response()
        response.body = "original"
        try await withOrigins(h2: h2, response: response) { origin, _ in
            try await withLeg(h2: h2, origin: origin, rules: TestRules.provider([rule]), breakpoints: coordinator) { leg in
                let pending = Task { try await leg.send(path: "/body") }
                do {
                    let ticket = try await RulesComposeBarriers.ticket(coordinator, on: leg.loop) { $0.state == .pausedBody }
                    #expect(ticket.bodyLength == 8)
                    #expect(try await coordinator.bodyPreview(token: ticket.token, offset: 0, maxBytes: 64) == Data("original".utf8))
                    #expect(await coordinator.perform(.continue(token: ticket.token, edit: .init(head: ticket.effectiveHead,
                        body: .replace(Data("edited response body".utf8))))) == .accepted)
                    let reply = try await pending.value
                    #expect(reply.status == 200)
                    #expect(reply.body == Array("edited response body".utf8))
                    #expect(reply.headers["transfer-encoding"].isEmpty)
                    if h2 { #expect(reply.headers["content-length"].allSatisfy { $0 == "20" }) }
                    else { #expect(reply.headers["content-length"] == ["20"]) }
                } catch { coordinator.shutdown(); _ = try? await pending.value; throw error }
                #expect(origin.counts.requests == 1)
                let flow = try await waitForFlow(leg.fixture.store) { $0.path == "/body" && $0.state == .completed }
                #expect(try flow.messages[.upstreamResponse]?.body?.load() == Data("original".utf8))
                #expect(try flow.messages[.downstreamResponse]?.body?.load() == Data("edited response body".utf8))
                #expect(flow.messages[.downstreamResponse]?.transferState == .finished)
                try await RulesComposeBarriers.expectIdle(leg.fixture, breakpoints: coordinator)
            }
        }
    }

    // MARK: 5. Compose pauses at a request breakpoint, is edited and recorded

    @Test(arguments: [false, true])
    func composeHitsRequestBreakpointIsEditedAndRecorded(h2: Bool) async throws {
        let coordinator = BreakpointCoordinator()
        let rule = TestRules.breakpoint(.request)
        try await withOrigins(h2: h2) { origin, _ in
            try await RulesComposeServer.run(rules: TestRules.provider([rule], revision: 4), breakpoints: coordinator,
                                             trusted: h2 ? [origin.ca] : []) { fx in
                let request = ComposeRequest(method: "GET", url: try composeURL(origin, h2: h2, path: "/compose?q=1"),
                                             headers: [HeaderField(name: "X-Original", value: "1")], policy: ComposePolicy(applyRules: true))
                let send = Task { await fx.compose.send(request) }
                let ticket = try await RulesComposeBarriers.ticket(coordinator, on: origin.channel.eventLoop)
                #expect(ticket.contextID == request.id)
                guard case .compose(let sendID, _, _) = ticket.source else { Issue.record("not a Compose ticket"); fx.compose.cancel(request.id); return }
                #expect(sendID == request.id)
                #expect(origin.counts.connections == 0)
                guard case .request(var target, let fields) = ticket.effectiveHead else { fx.compose.cancel(request.id); return }
                target.pathAndQuery = "/edited?q=2"
                let edit = BreakpointEdit(head: .request(target, headers: fields + [HeaderField(name: "X-Edited", value: "yes")]))
                #expect(await coordinator.perform(.continue(token: ticket.token, edit: edit)) == .accepted)
                let result = await send.value
                #expect(result.failure == nil)
                #expect(result.response?.status == 200)
                #expect(result.response?.body == Data("fixture-body".utf8))
                #expect(result.delivery == .answered)
                #expect(origin.counts.paths == ["/edited?q=2"])
                let seen = try #require(origin.counts.requestHeaders.first)
                #expect(seen["x-original"] == ["1"] && seen["x-edited"] == ["yes"])
                let flowID = try #require(result.flowID)
                let flow = try await waitForFlow(fx.store) { $0.id == flowID && $0.state == .completed }
                guard case .compose(let recordedID, _, _) = flow.provenance.source else { Issue.record("not Compose provenance"); return }
                #expect(recordedID == request.id)
                #expect(!flow.provenance.rulesDisabled)
                #expect(flow.provenance.ruleMatches?.ruleIDs == [rule.id])
                #expect(flow.provenance.ruleMatches?.revision == 4)
                #expect(flow.messages[.composeSubmitted]?.target?.pathAndQuery == "/compose?q=1")
                #expect(flow.messages[.upstreamRequest]?.target?.pathAndQuery == "/edited?q=2")
                #expect(flow.transport.upstreamRequest == (h2 ? .http2 : .http1_1))
                await fx.expectComposeIdle()
                try await fx.expectReleased(request.id)
            }
        }
    }

    // MARK: 6. Compose ignores rules unless asked (with a positive control)

    @Test(arguments: [false, true])
    func composeIgnoresRulesWhenOffAndAppliesThemWhenOn(h2: Bool) async throws {
        try await withOrigins(h2: h2) { a, b in
            let header = TestRules.headers(.request, [.set(name: "X-Rule", value: "applied")])
            let remote = TestRules.mapRemote(scheme: h2 ? "https" : "http", host: "127.0.0.1", port: b.port)
            try await RulesComposeServer.run(rules: TestRules.provider([header, remote]), trusted: [a.ca, b.ca]) { fx in
                let off = ComposeRequest(method: "GET", url: try composeURL(a, h2: h2, path: "/off"))
                let offResult = await fx.compose.send(off)
                #expect(offResult.response?.status == 200)
                #expect(a.counts.paths == ["/off"])
                #expect(a.counts.requestHeaders.first?["x-rule"].isEmpty == true)
                #expect(b.counts.requests == 0)
                let offFlow = try await waitForFlow(fx.store) { $0.id == offResult.flowID && $0.state == .completed }
                #expect(offFlow.provenance.rulesDisabled)
                #expect(offFlow.provenance.ruleMatches == nil)

                let on = ComposeRequest(method: "GET", url: try composeURL(a, h2: h2, path: "/on"), policy: ComposePolicy(applyRules: true))
                let onResult = await fx.compose.send(on)
                #expect(onResult.response?.status == 200)
                #expect(a.counts.paths == ["/off"])
                #expect(b.counts.paths == ["/on"])
                #expect(b.counts.requestHeaders.first?["x-rule"] == ["applied"])
                if h2 { #expect(b.counts.authorities == ["127.0.0.1:\(b.port)"]) }
                let onFlow = try await waitForFlow(fx.store) { $0.id == onResult.flowID && $0.state == .completed }
                #expect(!onFlow.provenance.rulesDisabled)
                #expect(Set(onFlow.provenance.ruleMatches?.ruleIDs ?? []) == [header.id, remote.id])
                #expect(onFlow.messages[.upstreamRequest]?.target?.port == b.port)
                await fx.expectComposeIdle()
                try await fx.expectReleased(off.id)
                try await fx.expectReleased(on.id)
            }
        }
    }

    // MARK: 7. Clear revokes paused tickets exactly once

    @Test(arguments: [false, true])
    func clearRevokesPausedTicketsExactlyOnce(h2: Bool) async throws {
        let coordinator = BreakpointCoordinator()
        let rule = TestRules.breakpoint(.request, matcher: RuleMatcher(path: .prefix("/paused")))
        try await withOrigins(h2: h2) { origin, _ in
            try await withLeg(h2: h2, origin: origin, rules: TestRules.provider([rule]), breakpoints: coordinator) { leg in
                let first = Task { try await leg.send(path: "/paused-1") }
                let second = Task { try await leg.send(path: "/paused-2") }
                do {
                    let tickets = try await RulesComposeBarriers.tickets(coordinator, count: 2, on: leg.loop)
                    #expect(Set(tickets.compactMap(\.flowID)).count == 2)
                    leg.fixture.store.clear()
                    #expect(coordinator.snapshot().isEmpty)
                    let replies = [try await first.value, try await second.value]
                    // One local 502 per paused request, and nothing else on its stream or socket.
                    #expect(replies.map(\.status) == [502, 502])
                    #expect(replies.allSatisfy { $0.extraResponses == 0 })
                    leg.fixture.store.clear()
                    for ticket in tickets {
                        #expect(await coordinator.perform(.continue(token: ticket.token, edit: .init(head: ticket.effectiveHead))) == .invalid)
                    }
                } catch { coordinator.shutdown(); _ = try? await first.value; _ = try? await second.value; throw error }
                #expect(origin.counts.requests == 0)
                // The client and the proxy stay usable; the revoked flows do not come back.
                let after = try await leg.send(path: "/after")
                #expect(after.status == 200)
                _ = try await waitForFlow(leg.fixture.store) { $0.path == "/after" && $0.state == .completed }
                #expect(leg.fixture.store.allFlows().map(\.path) == ["/after"])
                #expect(origin.counts.paths == ["/after"])
                try await RulesComposeBarriers.expectIdle(leg.fixture, breakpoints: coordinator)
            }
        }
    }

    // MARK: 8. Server stop ends paused tickets and Compose sends; everything is returned

    @Test(arguments: [false, true])
    func serverStopEndsPausedTicketsAndComposeSendsAndReturnsEveryResource(h2: Bool) async throws {
        let coordinator = BreakpointCoordinator()
        let rule = TestRules.breakpoint(.request, matcher: RuleMatcher(path: .exact("/paused")))
        let gate = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let hold = gate.next().makePromise(of: Void.self)
        var response = HTTP2TestOrigin.Response()
        response.barriersByPath = ["/hold": hold.futureResult]
        // `hold` is completed on every path while its loop and the origin's loop still run.
        do {
            try await withOrigins(h2: h2, response: response) { origin, _ in
                try await RulesComposeServer.run(rules: TestRules.provider([rule]), breakpoints: coordinator, trusted: h2 ? [origin.ca] : [],
                                                 composeLimits: .init(concurrentSends: 2, queuedSends: 1), drainImmediately: true) { fx in
                    let loop = origin.channel.eventLoop
                    // A client request paused at its request breakpoint.
                    let raw: RawClient? = h2 ? nil : try await RawClient.connect(port: try fx.port)
                    let h2Client: HTTP2TestClient? = h2 ? try await fx.h2Client(origin) : nil
                    let clientReply = Task { () -> Int? in
                        if let h2Client {
                            return try? await h2Client.request(headers: HTTPHeaders([("host", "localhost:\(origin.port)")]), path: "/paused").status
                        }
                        try await raw?.send("GET http://127.0.0.1:\(origin.port)/paused HTTP/1.1\r\nHost: 127.0.0.1:\(origin.port)\r\nConnection: close\r\n\r\n")
                        return nil
                    }
                    let clientTicket = try await RulesComposeBarriers.ticket(coordinator, on: loop)
                    // Compose A paused at the same breakpoint, B in flight with a file body, C queued.
                    let a = ComposeRequest(method: "GET", url: try composeURL(origin, h2: h2, path: "/paused"), policy: ComposePolicy(applyRules: true))
                    let asset = try await fx.importAsset(Data(repeating: 0x62, count: 200_000))
                    let b = ComposeRequest(method: "POST", url: try composeURL(origin, h2: h2, path: "/hold"), body: .asset(asset.id))
                    let c = ComposeRequest(method: "GET", url: try composeURL(origin, h2: h2, path: "/queued"))
                    let sendA = Task { await fx.compose.send(a) }
                    let tickets = try await RulesComposeBarriers.tickets(coordinator, count: 2, on: loop)
                    let composeTicket = try #require(tickets.first { $0.contextID == a.id })
                    let sendB = Task { await fx.compose.send(b) }
                    try await waitUntil("origin received B's whole body") { origin.counts.endedPaths.contains("/hold") }
                    #expect(origin.counts.bodies["/hold"]?.utf8.count == 200_000)
                    let sendC = Task { await fx.compose.send(c) }
                    try await waitUntil("C queued") { fx.compose.resources.queued == 1 }
                    #expect(fx.compose.resources.active == 2)

                    try await fx.server.stop()

                    for (id, send) in [(a.id, sendA), (b.id, sendB), (c.id, sendC)] {
                        let result = await send.value
                        #expect(result.failure?.code == ComposeFailureCode.shutdown.rawValue, "\(id)")
                        #expect(result.response == nil, "\(id)")
                    }
                    if let raw {
                        try await raw.waitUntilClosed()
                        let bytes = raw.remainingBytes()
                        // Either nothing or exactly one local failure; never a forwarded response.
                        if let parsed = RawHTTP1Response.parse(bytes) {
                            #expect(parsed.response.statusLine.hasPrefix("HTTP/1.1 5"), "\(parsed.response.head)")
                            #expect(parsed.rest.isEmpty)
                        } else { #expect(bytes.isEmpty) }
                        try await raw.close()
                    }
                    let status = try await clientReply.value
                    if h2 { #expect(status == nil || (500..<600).contains(status!)) }
                    if let h2Client { try await h2Client.stop() }

                    #expect(coordinator.snapshot().isEmpty)
                    for ticket in [clientTicket, composeTicket] {
                        #expect(await coordinator.perform(.continue(token: ticket.token, edit: .init(head: ticket.effectiveHead))) == .invalid)
                    }
                    await fx.expectComposeIdle()
                    try await fx.expectReleased(a.id)
                    try await fx.expectReleased(b.id)
                    #expect(!fx.lifetimes.alive(c.id).tracked) // never left the queue
                    #expect(fx.budgets.snapshot().bytes[.asset] == 200_000)
                    let spooled = ((try? FileManager.default.contentsOfDirectory(atPath: fx.spool.path)) ?? [])
                        .filter { $0 != SpoolDirectoryOwner.markerName }
                    #expect(spooled.isEmpty)
                    // Neither paused request reached the origin; every upstream socket is closed.
                    #expect(origin.counts.paths == ["/hold"])
                    try await waitUntil("every origin connection closed") { origin.counts.parents.allSatisfy { !$0.isActive } }
                    let afterStop = await fx.compose.send(ComposeRequest(method: "GET", url: try composeURL(origin, h2: h2, path: "/late")))
                    #expect(afterStop.failure?.code == HTTPLocalFailureCode.serviceUnavailable.rawValue)
                    #expect(afterStop.flowID == nil)
                }
                // Release the held response while the origin's loop still runs (its socket is closed).
                hold.succeed(())
            }
            hold.succeed(())
            try await gate.shutdownGracefully()
        } catch { hold.succeed(()); try? await gate.shutdownGracefully(); throw error }
    }

    // MARK: T10b m3: ordinary traffic through a silent upstream proxy

    /// The upstream proxy accepts TCP and never answers the CONNECT. When the client goes away,
    /// the pending attempt is closed at once rather than at the 20 s connect timeout.
    @Test func clientDisconnectClosesThePendingUpstreamProxyConnect() async throws {
        let proxy = try await ComposeSilentServer.start()
        do {
            try await ProxyFixture.run(configure: { configuration in
                var upstream = UpstreamProxy(host: "127.0.0.1", port: proxy.port, bypass: [])
                upstream.alwaysBypassLoopback = false
                configuration.upstreamProxy = upstream
                configuration.connectTimeout = .seconds(20)
            }, processLookup: .none) { fx in
                let client = try await RawClient.connect(port: fx.proxyPort)
                do {
                    try await client.send("GET http://127.0.0.1:\(fx.origin.port)/hello HTTP/1.1\r\nHost: 127.0.0.1:\(fx.origin.port)\r\n\r\n")
                    try await waitUntil("the CONNECT reached the silent proxy") { proxy.state.withLock { $0.receivedBytes } > 0 }
                    #expect(proxy.state.withLock { $0.connections } == 1)
                    try await client.close()
                } catch { try? await client.close(); throw error }
                try await waitUntil("the proxy saw the pending CONNECT close") { proxy.state.withLock { $0.closed } == 1 }
                #expect(fx.origin.acceptedConnections == 0)
            }
            try await proxy.stop()
        } catch { try? await proxy.stop(); throw error }
    }
}

// MARK: - Legs

/// A response as the client received it, normalized across HTTP/1 and HTTP/2.
struct LegResponse: Sendable {
    var status: Int
    var headers: HTTPHeaders
    var body: [UInt8]
    /// Bytes or responses that arrived after the first complete one (HTTP/1 only).
    var extraResponses: Int
}

/// One client leg through the fixture proxy: HTTP/1 forward proxy with a raw socket per request,
/// or one HTTP/2 MITM client connection with a stream per request.
struct Leg: Sendable {
    let h2: Bool
    let fixture: HTTP2ProxyFixture
    let client: HTTP2TestClient?
    let origin: HTTP2TestOrigin
    var loop: EventLoop { fixture.channel.eventLoop }

    func send(_ method: HTTPMethod = .GET, path: String, headers: [(String, String)] = []) async throws -> LegResponse {
        if let client {
            let reply = try await client.request(headers: HTTPHeaders([("host", "localhost:\(origin.port)")] + headers), path: path, method: method)
            return LegResponse(status: reply.status, headers: reply.headers, body: reply.bytes, extraResponses: 0)
        }
        let raw = try await RawClient.connect(port: try #require(fixture.channel.localAddress?.port))
        do {
            let fields = headers.map { "\($0.0): \($0.1)\r\n" }.joined()
            try await raw.send("\(method.rawValue) http://127.0.0.1:\(origin.port)\(path) HTTP/1.1\r\nHost: 127.0.0.1:\(origin.port)\r\n"
                               + fields + "Connection: close\r\n\r\n")
            try await raw.waitUntilClosed()
            let bytes = raw.remainingBytes()
            try await raw.close()
            let parsed = try #require(RawHTTP1Response.parse(bytes), "incomplete response: \(String(decoding: bytes, as: UTF8.self))")
            var fieldsOut = HTTPHeaders()
            for line in parsed.response.head.components(separatedBy: "\r\n").dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                fieldsOut.add(name: String(line[..<colon]), value: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            }
            let status = Int(parsed.response.statusLine.split(separator: " ").dropFirst().first ?? "") ?? 0
            return LegResponse(status: status, headers: fieldsOut, body: parsed.response.body, extraResponses: parsed.rest.isEmpty ? 0 : 1)
        } catch { try? await raw.close(); throw error }
    }
}

/// Runs `body` with a proxy fixture and one client leg; tickets still held when `body` throws are
/// shut down so nothing waits for the time limit.
func withLeg(h2: Bool, origin: HTTP2TestOrigin, rules: RuleSnapshotProvider? = nil, assets: ManagedAssetStore? = nil,
             breakpoints: BreakpointCoordinator? = nil, trusted: [CertificateAuthority]? = nil,
             traffic: TrafficPolicyProvider? = nil, _ body: (Leg) async throws -> Void) async throws {
    if h2 {
        try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true, rules: rules, assets: assets,
                                              breakpoints: breakpoints, trustedOrigins: trusted, traffic: traffic) { fixture, client in
            do { try await body(Leg(h2: true, fixture: fixture, client: client, origin: origin)) }
            catch { breakpoints?.shutdown(); throw error }
        }
        return
    }
    let fixture = try await HTTP2ProxyFixture.start(origin: origin, rules: rules, assets: assets, breakpoints: breakpoints,
                                                    trustedOrigins: trusted, traffic: traffic)
    do { try await body(Leg(h2: false, fixture: fixture, client: nil, origin: origin)) }
    catch { breakpoints?.shutdown(); try? await fixture.stop(); throw error }
    try await fixture.stop()
}

/// Two loopback origins: plain HTTP/1 for the forward-proxy leg, TLS HTTP/2 for the MITM leg.
/// `b` presents a certificate for 127.0.0.1, the host every rule or edit maps to.
func withOrigins(h2: Bool, response: HTTP2TestOrigin.Response = .init(),
                 _ body: (HTTP2TestOrigin, HTTP2TestOrigin) async throws -> Void) async throws {
    let a = try await HTTP2TestOrigin.start(protocols: h2 ? ["h2"] : [], response: response, plaintext: !h2)
    let b: HTTP2TestOrigin
    do { b = try await HTTP2TestOrigin.start(protocols: h2 ? ["h2"] : [], response: response, certificateHost: "127.0.0.1", plaintext: !h2) }
    catch { try? await a.stop(); throw error }
    do { try await body(a, b) } catch { try? await a.stop(); try? await b.stop(); throw error }
    try await a.stop()
    try await b.stop()
}

/// The URL a Compose send uses for `origin`: plain HTTP on 127.0.0.1, or HTTPS on localhost.
func composeURL(_ origin: HTTP2TestOrigin, h2: Bool, path: String) throws -> URL {
    try #require(URL(string: h2 ? "https://localhost:\(origin.port)\(path)" : "http://127.0.0.1:\(origin.port)\(path)"))
}
