import Darwin
import FlowStore
import Foundation
import NIOCore
import NIOHPACK
import NIOHTTP1
import NIOHTTP2
import NIOSSL
import Testing
@testable import ProxyCore
@testable import RulesEngine

/// Close connection (spec 6.9, D15): no response byte is written; graceful = FIN, reset = RST (SO_LINGER 0);
/// over HTTP/2 only that stream is reset (NO_ERROR / INTERNAL_ERROR) and the connection stays. The flow
/// ends failed, naming the rule, and the completion point still runs.
@Suite(.serialized, .timeLimit(.minutes(3)), .productionChinese) struct RuleCloseConnectionIntegrationTests {
    // MARK: HTTP/1 on the wire

    @Test func closeWritesNoBytes() async throws {
        try await ProxyFixture.run(rules: TestRules.provider([closing(.graceful)])) { fx in
            let reply = try await wireExchange(port: fx.proxyPort, get(fx, "/close"))
            #expect(reply.bytes.isEmpty, "\(String(decoding: reply.bytes, as: UTF8.self))")
        }
        try await ProxyFixture.run(rules: TestRules.provider([closing(.reset)])) { fx in
            let reply = try await wireExchange(port: fx.proxyPort, get(fx, "/close"))
            #expect(reply.bytes.isEmpty, "\(String(decoding: reply.bytes, as: UTF8.self))")
        }
    }

    @Test func gracefulCloseIsFIN() async throws {
        try await ProxyFixture.run(rules: TestRules.provider([closing(.graceful)])) { fx in
            let reply = try await wireExchange(port: fx.proxyPort, get(fx, "/close"))
            #expect(reply.ending == .fin)
        }
    }

    @Test func resetClosesWithRST() async throws {
        try await ProxyFixture.run(rules: TestRules.provider([closing(.reset)])) { fx in
            let reply = try await wireExchange(port: fx.proxyPort, get(fx, "/close"))
            #expect(reply.ending == .reset)
        }
    }

    @Test func flowIsFailedWithRuleClosedReason() async throws {
        let rule = closing(.reset, name: "Shut it")
        try await ProxyFixture.run(rules: TestRules.provider([rule])) { fx in
            _ = try await wireExchange(port: fx.proxyPort, get(fx, "/close"))
            let flow = try await waitForFlow(fx.store) { $0.path == "/close" && $0.completedAt != nil }
            let reason = HTTPLocalFailureText.ruleClosed(ruleName: "Shut it")
            #expect(reason.contains("Shut it"))
            #expect(flow.state == .failed(reason))
            #expect(flow.messages[.upstreamRequest] == nil)
            #expect(flow.messages[.downstreamResponse] == nil)
            #expect(flow.messages[.generatedResponse] == nil)
            #expect(flow.provenance.generatedResponse == nil)
            #expect(flow.provenance.rulesModified == false)
            #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: rule.id, code: .applied)])
        }
    }

    /// An earlier Map Remote does not route the request anywhere either: the decision's route closes.
    @Test func originIsNeverContacted() async throws {
        let provider = TestRules.provider([])
        try await ProxyFixture.run(rules: provider) { fx in
            let map = Rule(name: "map", conditions: ConditionGroup(rows: []), actions: [RuleAction(.mapRemote(MapRemoteAction(
                targetScheme: "http", targetHost: "127.0.0.1", targetPort: fx.origin.port, path: .preserve)))])
            TestRules.publish([map, closing(.graceful)], revision: 2, to: provider)
            let reply = try await wireExchange(port: fx.proxyPort, get(fx, "/close"))
            #expect(reply.bytes.isEmpty)
            _ = try await waitForFlow(fx.store) { $0.path == "/close" && $0.completedAt != nil }
            #expect(fx.origin.acceptedConnections == 0)
            #expect(fx.origin.receivedRequestCount == 0)
        }
    }

    /// The completion point still runs on the closed exchange: a higher-priority "session failed" rule marks it.
    @Test func closedExchangeStillReachesCompletionPoint() async throws {
        let failed = Rule(name: "failed", conditions: ConditionGroup(rows: [ConditionRow(field: .sessionState, op: .equals, value: "failed")]),
                          actions: [RuleAction(.mark(MarkAction(background: "#FF0000")))])
        let close = closing(.graceful)
        try await ProxyFixture.run(rules: TestRules.provider([failed, close])) { fx in
            _ = try await wireExchange(port: fx.proxyPort, get(fx, "/close"))
            let flow = try await waitForFlow(fx.store) { $0.path == "/close" && $0.completedAt != nil && $0.ruleMark != nil }
            if case .failed = flow.state {} else { Issue.record("expected a failed flow, got \(flow.state)") }
            #expect(flow.ruleMark?.source == .rule(id: failed.id, name: "failed"))
            #expect(flow.provenance.ruleMatches?.ruleIDs.contains(failed.id) == true)
        }
    }

    /// Requests queued behind the closed one on the same connection are never handled.
    @Test func pipelinedH1RequestsAreDropped() async throws {
        let close = closing(.graceful, path: "/close")
        try await ProxyFixture.run(rules: TestRules.provider([close])) { fx in
            let host = "127.0.0.1:\(fx.origin.port)"
            let pipelined = "GET http://\(host)/close HTTP/1.1\r\nHost: \(host)\r\n\r\n"
                + "GET http://\(host)/hello HTTP/1.1\r\nHost: \(host)\r\n\r\n"
            let reply = try await wireExchange(port: fx.proxyPort, pipelined)
            #expect(reply.bytes.isEmpty, "\(String(decoding: reply.bytes, as: UTF8.self))")
            #expect(reply.ending == .fin)
            _ = try await waitForFlow(fx.store) { $0.path == "/close" && $0.completedAt != nil }
            #expect(fx.store.allFlows().contains { $0.path == "/hello" } == false)
            #expect(fx.origin.acceptedConnections == 0)
        }
    }

    @Test func closeOnUpgradeHandshakeWorks() async throws {
        let close = closing(.reset)
        try await ProxyFixture.run(rules: TestRules.provider([close])) { fx in
            let host = "127.0.0.1:\(fx.origin.port)"
            let reply = try await wireExchange(port: fx.proxyPort, "GET http://\(host)/ws HTTP/1.1\r\nHost: \(host)\r\nUpgrade: websocket\r\n"
                + "Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n")
            #expect(reply.bytes.isEmpty)
            #expect(reply.ending == .reset)
            let flow = try await waitForFlow(fx.store) { $0.path == "/ws" && $0.completedAt != nil }
            if case .failed = flow.state {} else { Issue.record("expected a failed flow, got \(flow.state)") }
            #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: close.id, code: .applied)])
            #expect(fx.origin.acceptedConnections == 0)
        }
    }

    /// A partly sent upload: nothing of it is forwarded, the flow records the request as incomplete.
    @Test func closeBeforeBodyUploadFinishesDoesNotLeak() async throws {
        try await ProxyFixture.run(rules: TestRules.provider([closing(.graceful)])) { fx in
            let host = "127.0.0.1:\(fx.origin.port)"
            let reply = try await wireExchange(port: fx.proxyPort,
                "POST http://\(host)/upload HTTP/1.1\r\nHost: \(host)\r\nContent-Length: 1000000\r\n\r\npartial upload")
            #expect(reply.bytes.isEmpty)
            let flow = try await waitForFlow(fx.store) { $0.path == "/upload" && $0.completedAt != nil }
            if case .failed = flow.state {} else { Issue.record("expected a failed flow, got \(flow.state)") }
            #expect(flow.messages[.downstreamRequest]?.bodyState == .incomplete)
            #expect(flow.messages[.upstreamRequest] == nil)
            #expect(fx.origin.acceptedConnections == 0)
        }
        // HTTP/2: the stream is reset while the client is still uploading; nothing stays reserved.
        try await HTTP2TestOrigin.withOrigin(protocols: ["h2"]) { origin in
            // Judged at the request (a path row), so the CONNECT point (R4 T11) lets the MITM CONNECT through.
            let rules = TestRules.provider([closing(.reset, path: "/upload")])
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true, rules: rules) { fx, client in
                let pending = try await client.startRawRequest(headers: h2Headers(origin, method: "POST", path: "/upload"))
                try? await pending.body("partial upload")
                await #expect(throws: (any Error).self) { try await pending.response.get() }
                let flow = try await waitForFlow(fx.store) { $0.path == "/upload" && $0.completedAt != nil }
                if case .failed = flow.state {} else { Issue.record("expected a failed flow, got \(flow.state)") }
                #expect(flow.messages[.upstreamRequest] == nil)
                #expect(origin.counts.paths.contains("/upload") == false)
                try await RulesComposeBarriers.expectIdle(fx)
            }
        }
    }

    /// A graceful close stays a FIN while the client is still uploading: the proxy half-closes and drains the
    /// upload (bounded), so unread bytes never turn the close into a reset.
    @Test func gracefulCloseWhileClientKeepsUploadingIsFIN() async throws {
        let size = 8 * 1_048_576
        try await ProxyFixture.run(rules: TestRules.provider([closing(.graceful)])) { fx in
            let host = "127.0.0.1:\(fx.origin.port)"
            let reply = try await wireExchange(port: fx.proxyPort,
                "POST http://\(host)/upload HTTP/1.1\r\nHost: \(host)\r\nContent-Length: \(size)\r\n\r\n", streaming: size)
            #expect(reply.ending == .fin)
            #expect(reply.streamed == size)
            #expect(reply.bytes.isEmpty)
            #expect(fx.origin.acceptedConnections == 0)
        }
    }

    /// A rule that needed the request body (a peek, spooled to disk) and then closes: FIN, no byte, and the
    /// spool file and its budget are released.
    @Test func closeAfterSpooledPeekReleasesTheSpool() async throws {
        let limits = RulesLimits(minimumFreeDiskBytes: 0)
        let budgets = OwnedFileBudgets(limits: limits)
        let runtime = BreakpointBodyRuntime(budgets: budgets, limits: limits)
        let peekThenClose = Rule(name: "peek close", conditions: ConditionGroup(rows: [ConditionRow(field: .requestBody, op: .contains, value: "a")]),
                                 actions: [RuleAction(.closeConnection(.graceful))])
        let size = 600_000
        try await ProxyFixture.run(rules: TestRules.provider([peekThenClose]), bodyRuntime: runtime) { fx in
            let host = "127.0.0.1:\(fx.origin.port)"
            let reply = try await wireExchange(port: fx.proxyPort, "POST http://\(host)/spooled HTTP/1.1\r\nHost: \(host)\r\n"
                + "Content-Type: text/plain\r\nContent-Length: \(size)\r\n\r\n", streaming: size)
            #expect(reply.ending == .fin)
            #expect(reply.bytes.isEmpty)
            let flow = try await waitForFlow(fx.store) { $0.path == "/spooled" && $0.completedAt != nil }
            #expect(flow.state == .failed(HTTPLocalFailureText.ruleClosed(ruleName: "peek close")))
            #expect(budgets.snapshot().peak.values.contains { $0 > 0 }, "the body was held: \(budgets.snapshot())")
            try await waitUntil("spool and buffers released: \(budgets.snapshot())") { budgets.snapshot().reservedBytes == 0 }
            try await waitUntil("spool directory back to its baseline") {
                ((try? FileManager.default.contentsOfDirectory(atPath: runtime.directory.path)) ?? []).allSatisfy { $0.hasPrefix(".") }
            }
            #expect(fx.origin.acceptedConnections == 0)
        }
    }

    /// Nothing is sent before the close, not even an interim 100 Continue: the rule decides on the head alone.
    /// (A rule that reads the body, or a full-body request breakpoint, must send 100 Continue to receive it;
    /// those interim responses can precede the close, but never a final response byte.)
    @Test func expectContinueGetsNoInterimBeforeTheClose() async throws {
        try await ProxyFixture.run(rules: TestRules.provider([closing(.graceful)])) { fx in
            let host = "127.0.0.1:\(fx.origin.port)"
            let reply = try await wireExchange(port: fx.proxyPort,
                "POST http://\(host)/expect HTTP/1.1\r\nHost: \(host)\r\nExpect: 100-continue\r\nContent-Length: 10\r\n\r\n")
            #expect(reply.bytes.isEmpty, "\(String(decoding: reply.bytes, as: UTF8.self))")
            #expect(reply.ending == .fin)
        }
    }

    /// Under TLS a reset is abrupt as well: only a graceful close sends close_notify first.
    @Test(arguments: RulesEngine.CloseMode.allCases)
    func interceptedHTTPSSendsCloseNotifyOnlyWhenGraceful(mode: RulesEngine.CloseMode) async throws {
        try await HTTP2TestOrigin.withOrigin(protocols: ["http/1.1"]) { origin in
            // Judged at the request (a path row), so the CONNECT point (R4 T11) lets the MITM CONNECT through.
            let fixture = try await HTTP2ProxyFixture.start(origin: origin, rules: TestRules.provider([closing(mode, path: "/close")]))
            do {
                let client = try await RawClient.connect(port: try #require(fixture.channel.localAddress?.port))
                do {
                    try await client.send("CONNECT localhost:\(origin.port) HTTP/1.1\r\nHost: localhost:\(origin.port)\r\n\r\n")
                    #expect(try await client.receive(until: "\r\n\r\n").hasPrefix("HTTP/1.1 200 "))
                    try await client.startTLS(trustRoots: .certificates([
                        NIOSSLCertificate(bytes: fixture.ca.rootCertificateDER, format: .der)
                    ]), serverName: "localhost")
                    try await client.send("GET /close HTTP/1.1\r\nHost: localhost:\(origin.port)\r\n\r\n")
                    try await client.waitUntilClosed()
                    #expect(client.remainingBytes().isEmpty)
                    let unclean = client.observedErrors.contains { $0.contains("uncleanShutdown") }
                    #expect(unclean == (mode == .reset), "\(mode): \(client.observedErrors)")
                    try await client.close()
                } catch { try? await client.close(); throw error }
                #expect(origin.counts.paths.isEmpty)
                try await fixture.stop()
            } catch { try? await fixture.stop(); throw error }
        }
    }

    // MARK: HTTP/2

    @Test func h2CloseLeavesSiblingStreamsAlone() async throws {
        try await HTTP2TestOrigin.withOrigin(protocols: ["h2"]) { origin in
            let rules = TestRules.provider([closing(.reset, path: "/close")])
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true, rules: rules) { fx, client in
                let probe = try await ResetProbe.install(on: client.channel)
                let sibling = try await client.startRawRequest(headers: h2Headers(origin, method: "POST", path: "/keep"))
                await #expect(throws: (any Error).self) { try await client.rawRequest(headers: h2Headers(origin, path: "/close")) }
                try await sibling.body("still here", endStream: true)
                let kept = try await sibling.response.get()
                #expect(kept.status == 200)
                // The parent connection stays usable.
                let after = try await client.rawRequest(headers: h2Headers(origin, path: "/after"))
                #expect(after.status == 200)
                let resets = try await probe.resets()
                #expect(resets.count == 1, "\(resets)")
                #expect(origin.counts.paths.contains("/close") == false)
                let flow = try await waitForFlow(fx.store) { $0.path == "/close" && $0.completedAt != nil }
                if case .failed = flow.state {} else { Issue.record("expected a failed flow, got \(flow.state)") }
                try await RulesComposeBarriers.expectIdle(fx)
            }
        }
    }

    @Test func h2GracefulSendsNoErrorRST() async throws {
        try await expectH2Reset(.graceful, code: .noError)
    }

    @Test func h2ResetSendsInternalErrorRST() async throws {
        try await expectH2Reset(.reset, code: .internalError)
    }

    private func expectH2Reset(_ mode: RulesEngine.CloseMode, code: HTTP2ErrorCode) async throws {
        try await HTTP2TestOrigin.withOrigin(protocols: ["h2"]) { origin in
            // Judged at the request (a path row), so the CONNECT point (R4 T11) lets the MITM CONNECT through.
            let rules = TestRules.provider([closing(mode, path: "/close")])
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true, rules: rules) { fx, client in
                let probe = try await ResetProbe.install(on: client.channel)
                await #expect(throws: (any Error).self) { try await client.rawRequest(headers: h2Headers(origin, path: "/close")) }
                let resets = try await probe.resets()
                #expect(Array(resets.values) == [code], "\(resets)")
                #expect(try await probe.heads().isEmpty)
                #expect(origin.counts.connections == 0)
                let flow = try await waitForFlow(fx.store) { $0.path == "/close" && $0.completedAt != nil }
                #expect(flow.state == .failed(HTTPLocalFailureText.ruleClosed(ruleName: "close")))
            }
        }
    }

    // MARK: Compose

    @Test func composeVirtualClientAbortsCleanly() async throws {
        try await ComposeFixture.run(rules: TestRules.provider([closing(.reset)])) { fx in
            let result = await fx.compose.send(ComposeRequest(method: "GET", url: fx.url("/hello"), policy: ComposePolicy(applyRules: true)))
            #expect(result.response == nil)
            #expect(result.failure?.code == HTTPLocalFailureCode.ruleClosed.rawValue)
            #expect(result.failure?.message == HTTPLocalFailureText.ruleClosed(ruleName: "close"))
            #expect(result.partialResponse == nil)
            #expect(result.delivery == .notSent)
            #expect(fx.origin.state.withLock { $0.connections } == 0)
            let flowID = try #require(result.flowID)
            let flow = try await waitForFlow(fx.store) { $0.id == flowID && $0.completedAt != nil }
            if case .failed = flow.state {} else { Issue.record("expected a failed flow, got \(flow.state)") }
            fx.expectIdle()
        }
    }

    // MARK: the writer seam

    @Test func closeReachesTheWriterOnceAndWritesNothing() async throws {
        try await withConnectionFixture { fixture in
            let writer = RecordingResponseWriter(channel: fixture.client, version: .http2)
            let context = fixture.context(rules: TestRules.provider([closing(.reset)]))
            let exchange = fixture.admit("/close", method: .POST, headers: HTTPHeaders([("Content-Length", "100")]),
                                         writer: writer, context: context)
            exchange.receiveRequest(.body(ByteBuffer(string: "partial")))
            #expect(context.snapshot.pendingBytes > 0)
            exchange.execute()
            #expect(writer.closes == [.reset])
            #expect(writer.aborts == 0)
            #expect(writer.heads.isEmpty && writer.body.isEmpty && writer.ends == 0)
            #expect(fixture.connections.isEmpty)
            #expect(context.snapshot.pendingBytes == 0)
            #expect(context.snapshot.exchanges.isEmpty)
            // The rest of the upload goes nowhere.
            exchange.receiveRequest(.body(ByteBuffer(string: "more")))
            exchange.receiveRequest(.end(nil))
            #expect(context.snapshot.pendingBytes == 0)
            #expect(writer.closes == [.reset])
            #expect(exchange.localFailure == .ruleClosed)
            let flow = try fixture.flow("/close")
            #expect(flow.state == .failed(HTTPLocalFailureText.ruleClosed(ruleName: "close")))
        }
    }
}

// MARK: rules

private func closing(_ mode: RulesEngine.CloseMode, name: String = "close", path: String? = nil) -> Rule {
    let rows = path.map { [ConditionRow(field: .pathAndQuery, op: .startsWith, value: $0)] } ?? []
    return Rule(name: name, conditions: ConditionGroup(rows: rows), actions: [RuleAction(.closeConnection(mode))])
}

private func get(_ fx: ProxyFixture, _ path: String) -> String {
    let host = "127.0.0.1:\(fx.origin.port)"
    return "GET http://\(host)\(path) HTTP/1.1\r\nHost: \(host)\r\n\r\n"
}

private func h2Headers(_ origin: HTTP2TestOrigin, method: String = "GET", path: String) -> HPACKHeaders {
    HPACKHeaders([(":method", method), (":scheme", "https"), (":authority", "localhost:\(origin.port)"), (":path", path)])
}

// MARK: wire observation

/// How the proxy ended the TCP connection, as a plain socket sees it.
enum WireEnding: Equatable, Sendable {
    /// An orderly close: read returned 0.
    case fin
    /// read failed with ECONNRESET.
    case reset
    case failed(Int32)
}

/// Sends `request` on a fresh plain socket, then `streaming` more body bytes (as a client still uploading
/// would), and reads until the proxy ends the connection. A send the peer refused with ECONNRESET / EPIPE
/// is a reset. The blocking socket runs on its own thread (never a NIO loop or the cooperative pool), with
/// a receive timeout.
func wireExchange(port: Int, _ request: String, streaming: Int = 0,
                  timeoutSeconds: Int = 5) async throws -> (bytes: [UInt8], ending: WireEnding, streamed: Int) {
    try await withCheckedThrowingContinuation { continuation in
        Thread.detachNewThread {
            continuation.resume(with: Result {
                try blockingExchange(port: port, request: Array(request.utf8), streaming: streaming, timeoutSeconds: timeoutSeconds)
            })
        }
    }
}

private struct WireError: Error, CustomStringConvertible {
    let description: String
}

private func blockingExchange(port: Int, request: [UInt8], streaming: Int,
                              timeoutSeconds: Int) throws -> (bytes: [UInt8], ending: WireEnding, streamed: Int) {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw WireError(description: "socket: \(errno)") }
    defer { Darwin.close(fd) }
    var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(port).bigEndian)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard connected == 0 else { throw WireError(description: "connect: \(errno)") }
    var offset = 0
    while offset < request.count {
        let sent = request[offset...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        guard sent > 0 else { break }   // The proxy may already have closed; the read below tells how.
        offset += sent
    }
    let chunk = [UInt8](repeating: UInt8(ascii: "a"), count: 65_536)
    var streamed = 0
    while streamed < streaming {
        let sent = chunk.withUnsafeBytes { send(fd, $0.baseAddress, min($0.count, streaming - streamed), 0) }
        if sent > 0 { streamed += sent; continue }
        let code = errno
        if code == EINTR { continue }
        if code == ECONNRESET || code == EPIPE { return ([], .reset, streamed) }
        if code == EAGAIN { throw WireError(description: "the proxy stopped reading the upload within \(timeoutSeconds) s") }
        throw WireError(description: "send: \(code)")
    }
    var received: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
        if count > 0 { received.append(contentsOf: buffer[..<count]); continue }
        if count == 0 { return (received, .fin, streamed) }
        let code = errno
        if code == EINTR { continue }
        if code == EAGAIN { throw WireError(description: "the proxy did not close the connection within \(timeoutSeconds) s") }
        return (received, code == ECONNRESET ? .reset : .failed(code), streamed)
    }
}

/// Records the RST_STREAM frames and response heads the client connection decodes, before its multiplexer.
final class ResetProbe: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame
    private var resetCodes: [HTTP2StreamID: HTTP2ErrorCode] = [:]
    private var headStreams: [HTTP2StreamID] = []

    struct Handle: Sendable {
        let probe: NIOLoopBound<ResetProbe>
        let loop: EventLoop
        func resets() async throws -> [HTTP2StreamID: HTTP2ErrorCode] {
            try await loop.submit { probe.value.resetCodes }.get()
        }
        func heads() async throws -> [HTTP2StreamID] {
            try await loop.submit { probe.value.headStreams }.get()
        }
    }

    static func install(on parent: Channel) async throws -> Handle {
        try await parent.eventLoop.submit {
            let probe = ResetProbe()
            let mux = try parent.pipeline.syncOperations.handler(type: HTTP2StreamMultiplexer.self)
            try parent.pipeline.syncOperations.addHandler(probe, position: .before(mux))
            return Handle(probe: NIOLoopBound(probe, eventLoop: parent.eventLoop), loop: parent.eventLoop)
        }.get()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.payload {
        case .rstStream(let code): resetCodes[frame.streamID] = code
        case .headers(let block) where block.headers.contains(name: ":status"): headStreams.append(frame.streamID)
        default: break
        }
        context.fireChannelRead(data)
    }
}
