import FlowStore
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing
import os
@testable import ProxyCore
@testable import RulesEngine

private let red = MarkAction(background: "#FF0000")

private func row(_ field: ConditionField, _ op: ConditionOperator, _ value: String = "") -> ConditionRow {
    ConditionRow(field: field, op: op, value: value)
}

private func rule(_ name: String, _ rows: [ConditionRow], _ actions: [ActionKind] = [.mark(red)]) -> Rule {
    Rule(name: name, conditions: ConditionGroup(rows: rows), actions: actions.map { RuleAction($0) })
}

/// The body files in the runtime's spool directory (its owner marker is the baseline).
private func spoolFiles(_ runtime: BreakpointBodyRuntime) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: runtime.directory.path)) ?? []).filter { !$0.hasPrefix(".") }
}

// MARK: Response bodies (T12)

/// Response body conditions on live traffic (D12, D13): which responses are held for a peek, that the
/// client still receives the origin's bytes exactly, and that every exit releases the collected body.
@Suite(.productionChinese, .serialized, .timeLimit(.minutes(3))) struct RuleResponseBodyConditionIntegrationTests {
    private func flow(_ fx: ProxyFixture, _ path: String) async throws -> Flow {
        try await waitForFlow(fx.store) { $0.path == path && $0.state != .inProgress }
    }

    // MARK: matching

    @Test func responseBodyContainsMarksTheFlow() async throws {
        let vip = rule("vip", [row(.responseBody, .contains, "vip")])
        try await withScriptedOrigin { origin in
            origin.route("/yes", [.send(textBytes("a vip body"))])
            origin.route("/no", [.send(textBytes("plain body"))])
            try await ProxyFixture.run(rules: TestRules.provider([vip])) { fx in
                let reply = try await fetch(fx, origin, "/yes")
                #expect(reply.head.hasPrefix("HTTP/1.1 200 OK\r\n"))
                #expect(reply.body == Data("a vip body".utf8))
                let marked = try await flow(fx, "/yes")
                #expect(marked.ruleMark?.source == .rule(id: vip.id, name: "vip"))
                #expect(marked.provenance.ruleMatches?.ruleIDs == [vip.id])
                _ = try await fetch(fx, origin, "/no")
                #expect(try await flow(fx, "/no").ruleMark == nil)
            }
        }
    }

    @Test func responseBodyReachesTheClientUnchangedWhenOnlyPeeked() async throws {
        let peek = rule("peek", [row(.responseBody, .contains, "world")])
        var plain: [UInt8] = []
        var peeked: [UInt8] = []
        for (rules, keep) in [(nil as RuleSnapshotProvider?, 0), (TestRules.provider([peek]), 1)] {
            try await withScriptedOrigin { origin in
                origin.route("/t", [.send(textBytes("hello world"))])
                try await ProxyFixture.run(rules: rules) { fx in
                    let reply = try await fetch(fx, origin, "/t")
                    if keep == 0 { plain = reply.raw } else { peeked = reply.raw }
                    let flow = try await flow(fx, "/t")
                    #expect((flow.ruleMark != nil) == (keep == 1))
                    #expect(try flow.messages[.upstreamResponse]?.body?.load() == Data("hello world".utf8))
                    #expect(try flow.messages[.downstreamResponse]?.body?.load() == Data("hello world".utf8))
                }
            }
        }
        #expect(!plain.isEmpty)
        #expect(peeked == plain, "\(String(decoding: peeked, as: UTF8.self))")
    }

    @Test func gzipResponseBodyIsDecodedForTheCondition() async throws {
        let hello = rule("hello", [row(.responseBody, .contains, "hello")])
        try await withScriptedOrigin { origin in
            origin.route("/gz", [.send(gzipBytes())])
            try await ProxyFixture.run(rules: TestRules.provider([hello])) { fx in
                _ = try await fetch(fx, origin, "/gz")
                #expect(try await flow(fx, "/gz").ruleMark?.source == .rule(id: hello.id, name: "hello"))
            }
        }
    }

    @Test func clientStillReceivesTheOriginalCompressedBytes() async throws {
        let hello = rule("hello", [row(.responseBody, .contains, "hello")])
        try await withScriptedOrigin { origin in
            origin.route("/gz", [.send(gzipBytes())])
            try await ProxyFixture.run(rules: TestRules.provider([hello])) { fx in
                let reply = try await fetch(fx, origin, "/gz")
                #expect([UInt8](reply.body) == gzipHello)
                #expect(reply.head.lowercased().contains("content-encoding: gzip"))
                #expect(reply.head.lowercased().contains("content-length: \(gzipHello.count)"))
                #expect(try await flow(fx, "/gz").ruleMark != nil)
            }
        }
    }

    @Test func headResponseIsEmptyBody() async throws {
        let empty = rule("empty", [row(.responseBody, .isEmpty)])
        try await withScriptedOrigin { origin in
            origin.route("/h", [.send(Array("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\n".utf8))])
            try await ProxyFixture.run(rules: TestRules.provider([empty])) { fx in
                let reply = try await fetch(fx, origin, "/h", method: "HEAD")
                #expect(reply.head.hasPrefix("HTTP/1.1 200 OK\r\n"))
                #expect(reply.body.isEmpty)
                let flow = try await flow(fx, "/h")
                #expect(flow.ruleMark?.source == .rule(id: empty.id, name: "empty"))
                #expect(flow.provenance.ruleMatches?.outcomes.allSatisfy { $0.code == .applied } == true)
            }
        }
    }

    @Test func responseBodyRegexRunsOffTheEventLoop() async throws {
        let onLoop = OSAllocatedUnfairLock(initialState: [Bool]())
        let cache = PatternCache(bodyBudget: RegexBudget(maxDuration: .seconds(5), clock: {
            onLoop.withLock { $0.append(MultiThreadedEventLoopGroup.currentEventLoop != nil) }
            return RegexBudget.monotonicNow()
        }))
        let regex = rule("regex", [row(.responseBody, .regex, #""id":\s*\d+"#)])
        try await withScriptedOrigin { origin in
            origin.route("/j", [.send(textBytes(#"{"id": 42}"#, type: "application/json"))])
            try await ProxyFixture.run(rules: TestRules.provider([regex], patternCache: cache)) { fx in
                _ = try await fetch(fx, origin, "/j")
                #expect(try await flow(fx, "/j").ruleMark != nil)
            }
        }
        let readings = onLoop.withLock { $0 }
        #expect(!readings.isEmpty)
        #expect(readings.allSatisfy { !$0 }, "\(readings)")
    }

    @Test func responseBodyRuleCanAlsoMarkAfterPeekedRewrite() async throws {
        let budgets = OwnedFileBudgets(limits: RulesLimits(minimumFreeDiskBytes: 0))
        let runtime = BreakpointBodyRuntime(budgets: budgets, limits: RulesLimits(minimumFreeDiskBytes: 0))
        let first = TestRules.rewriteBody(find: "cat", replacement: "dog")
        let second = rule("second", [row(.responseBody, .contains, "dog")])
        try await withScriptedOrigin { origin in
            origin.route("/r", [.send(textBytes("a cat"))])
            try await ProxyFixture.run(rules: TestRules.provider([first, second]), bodyRuntime: runtime) { fx in
                let reply = try await fetch(fx, origin, "/r")
                #expect(reply.body == Data("a dog".utf8))
                let flow = try await flow(fx, "/r")
                #expect(flow.ruleMark?.source == .rule(id: second.id, name: "second"))
                #expect(try flow.messages[.upstreamResponse]?.body?.load() == Data("a cat".utf8))
                #expect(try flow.messages[.downstreamResponse]?.body?.load() == Data("a dog".utf8))
            }
        }
        try await waitUntil("bodies released: \(budgets.snapshot())") { budgets.snapshot().reservedBytes == 0 }
    }

    // MARK: bodies that are never collected

    @Test func chunkedResponseIsSkippedAndStreamsImmediately() async throws {
        let peek = rule("peek", [row(.responseBody, .contains, "first")])
        try await withScriptedOrigin { origin in
            let barrier = origin.makePromise()
            origin.route("/c", [.send(chunkedHeadBytes()), .send(chunkBytes("first-part")), .wait(barrier.futureResult),
                                .send(chunkBytes("second-part")), .send(Array("0\r\n\r\n".utf8))])
            try await ProxyFixture.run(rules: TestRules.provider([peek])) { fx in
                let client = try await RawClient.connect(port: fx.proxyPort)
                do {
                    try await client.send(requestText(origin, "/c"))
                    // The first chunk reaches the client while the origin still holds the rest.
                    _ = try await client.receive(until: "first-part")
                    barrier.succeed(())
                    _ = try await client.receive(until: "\r\n0\r\n\r\n")
                    try await client.close()
                } catch { barrier.succeed(()); try? await client.close(); throw error }
                let flow = try await flow(fx, "/c")
                #expect(flow.ruleMark == nil)
                #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: peek.id, code: .bodySkippedStreaming)])
            }
        }
    }

    @Test func sseResponseIsNeverHeld() async throws {
        let peek = rule("peek", [row(.responseBody, .contains, "data")])
        try await withScriptedOrigin { origin in
            let barrier = origin.makePromise()
            origin.route("/sse", [
                .send(Array("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: 20\r\n\r\ndata: a\n\n".utf8)),
                .wait(barrier.futureResult), .send(Array("data: b\n\n".utf8)),
            ])
            try await ProxyFixture.run(rules: TestRules.provider([peek])) { fx in
                let client = try await RawClient.connect(port: fx.proxyPort)
                do {
                    try await client.send(requestText(origin, "/sse"))
                    _ = try await client.receive(until: "data: a")
                    barrier.succeed(())
                    _ = try await client.receive(until: "data: b")
                    try await client.close()
                } catch { barrier.succeed(()); try? await client.close(); throw error }
                let flow = try await flow(fx, "/sse")
                #expect(flow.ruleMark == nil)
                #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: peek.id, code: .bodySkippedStreaming)])
            }
        }
    }

    @Test func oversizedResponseIsNotCollected() async throws {
        let peek = rule("peek", [row(.responseBody, .contains, "a")])
        let size = 2 * 1_048_576
        try await withScriptedOrigin { origin in
            let barrier = origin.makePromise()
            origin.route("/big", [
                .send(Array("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(size)\r\n\r\n".utf8) + Array(repeating: 97, count: 1024)),
                .wait(barrier.futureResult), .send(Array(repeating: 97, count: size - 1024)),
            ])
            try await ProxyFixture.run(rules: TestRules.provider([peek])) { fx in
                let client = try await RawClient.connect(port: fx.proxyPort)
                do {
                    try await client.send(requestText(origin, "/big"))
                    // Streamed: the first kilobyte arrives before the origin sent the rest.
                    _ = try await client.receive(count: 1024 + 60)
                    barrier.succeed(())
                    try await client.waitUntilClosed(timeout: .seconds(20))
                    try await client.close()
                } catch { barrier.succeed(()); try? await client.close(); throw error }
                let flow = try await flow(fx, "/big")
                #expect(flow.ruleMark == nil)
                #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: peek.id, code: .bodyTooLarge)])
            }
        }
    }

    // MARK: when no peek happens

    @Test func noResponseBodyRowsNoPeeker() async throws {
        let status = rule("status", [row(.statusCode, .equals, "200")])
        try await expectStreams(rules: [status]) { fx, flow in
            #expect(flow.ruleMark?.source == .rule(id: status.id, name: "status"))
        }
    }

    @Test func responsesNoBodyRuleCanMatchAreNotHeld() async throws {
        let elsewhere = rule("elsewhere", [row(.statusCode, .equals, "404"), row(.responseBody, .contains, "12345")])
        try await expectStreams(rules: [elsewhere]) { fx, flow in
            #expect(flow.ruleMark == nil)
            #expect(flow.provenance.ruleMatches == nil)
        }
    }

    /// A known-length text response a rule cannot match reaches the client part by part: the first
    /// half arrives before the origin sent the second.
    private func expectStreams(rules: [Rule], _ check: (ProxyFixture, Flow) throws -> Void) async throws {
        try await withScriptedOrigin { origin in
            let barrier = origin.makePromise()
            origin.route("/s", [.send(Array("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 10\r\n\r\n12345".utf8)),
                                .wait(barrier.futureResult), .send(Array("67890".utf8))])
            try await ProxyFixture.run(rules: TestRules.provider(rules)) { fx in
                let client = try await RawClient.connect(port: fx.proxyPort)
                do {
                    try await client.send(requestText(origin, "/s"))
                    _ = try await client.receive(until: "12345")
                    barrier.succeed(())
                    _ = try await client.receive(until: "67890")
                    try await client.close()
                } catch { barrier.succeed(()); try? await client.close(); throw error }
                try check(fx, try await flow(fx, "/s"))
            }
        }
    }

    // MARK: release on every exit

    @Test func clientCancelDuringResponsePeekReleasesEverything() async throws {
        let limits = RulesLimits(minimumFreeDiskBytes: 0)
        let budgets = OwnedFileBudgets(limits: limits)
        let runtime = BreakpointBodyRuntime(budgets: budgets, limits: limits)
        let peek = rule("peek", [row(.responseBody, .contains, "x")])
        try await withScriptedOrigin { origin in
            let barrier = origin.makePromise()
            origin.route("/p", [.send(Array("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 10\r\n\r\nabc".utf8)),
                                .wait(barrier.futureResult)])
            try await ProxyFixture.run(rules: TestRules.provider([peek]), bodyRuntime: runtime) { fx in
                let client = try await RawClient.connect(port: fx.proxyPort)
                do {
                    try await client.send(requestText(origin, "/p"))
                    try await waitUntil("body collecting: \(budgets.snapshot())") { (budgets.snapshot().bytes[.breakpoint] ?? 0) > 0 }
                    try await client.close()
                    try await waitUntil("spool and buffers released: \(budgets.snapshot())") { budgets.snapshot().reservedBytes == 0 }
                    try await waitUntil("spool directory back to its baseline: \(spoolFiles(runtime))") { spoolFiles(runtime).isEmpty }
                    barrier.succeed(())
                } catch { barrier.succeed(()); try? await client.close(); throw error }
                let flow = try await flow(fx, "/p")
                if case .failed = flow.state {} else { Issue.record("expected a failed flow, got \(flow.state)") }
            }
        }
    }

    @Test func peekTimeoutLetsTheResponseThrough() async throws {
        let limits = RulesLimits(minimumFreeDiskBytes: 0, rewriteSeconds: 1)
        let budgets = OwnedFileBudgets(limits: limits)
        let runtime = BreakpointBodyRuntime(budgets: budgets, limits: limits)
        let peek = rule("peek", [row(.responseBody, .contains, "hello")])
        try await withScriptedOrigin { origin in
            let barrier = origin.makePromise()
            origin.route("/slow", [.send(Array("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\n".utf8)),
                                   .wait(barrier.futureResult), .send(Array("hello".utf8))])
            try await ProxyFixture.run(rules: TestRules.provider([peek]), bodyRuntime: runtime) { fx in
                let client = try await RawClient.connect(port: fx.proxyPort)
                do {
                    try await client.send(requestText(origin, "/slow"))
                    // The origin sends no body: the peek gives up and the head is forwarded.
                    _ = try await client.receive(until: "\r\n\r\n", timeout: .seconds(10))
                    barrier.succeed(())
                    _ = try await client.receive(until: "hello")
                    try await client.close()
                } catch { barrier.succeed(()); try? await client.close(); throw error }
                let flow = try await flow(fx, "/slow")
                #expect(flow.ruleMark == nil)
                #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: peek.id, code: .bodySkippedUnavailable)])
                try await waitUntil("released: \(budgets.snapshot())") { budgets.snapshot().reservedBytes == 0 }
            }
        }
    }

    @Test(arguments: [true, false])
    func peekFailureAfterBytesWereTakenNamesTheResponse(timeout: Bool) async throws {
        // Bytes already taken from the origin cannot be forwarded as they arrived: the exchange ends with
        // a page that names the response body (not the request body).
        let limits = RulesLimits(minimumFreeDiskBytes: 0, rewriteSeconds: 1)
        let budgets = OwnedFileBudgets(limits: limits)
        let runtime = BreakpointBodyRuntime(budgets: budgets, limits: limits)
        let peek = rule("peek", [row(.responseBody, .contains, "hello")])
        let code: HTTPLocalFailureCode = timeout ? .peekResponseBodyTimeout : .peekResponseBodyUnavailable
        try await withScriptedOrigin { origin in
            let barrier = origin.makePromise()
            let partial = Array("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 10\r\n\r\nabc".utf8)
            origin.route("/part", [.send(partial)] + (timeout ? [.wait(barrier.futureResult)] : [.close]))
            try await ProxyFixture.run(rules: TestRules.provider([peek]), bodyRuntime: runtime) { fx in
                let client = try await RawClient.connect(port: fx.proxyPort)
                do {
                    try await client.send(requestText(origin, "/part"))
                    let reply = try await client.receive(until: HTTPLocalFailureText.peek(code), timeout: .seconds(10))
                    #expect(reply.hasPrefix(timeout ? "HTTP/1.1 504 Gateway Timeout\r\n" : "HTTP/1.1 502 Bad Gateway\r\n"), "\(reply)")
                    #expect(!reply.contains("请求正文"))
                    try await client.close()
                } catch { barrier.succeed(()); try? await client.close(); throw error }
                barrier.succeed(())
                try await waitUntil("released: \(budgets.snapshot())") { budgets.snapshot().reservedBytes == 0 }
            }
        }
    }

    @Test func noBodyStatusesAreNotHeld() async throws {
        // 204 and 304 carry no body whatever their headers say: judged at once as empty.
        let empty = rule("empty", [row(.responseBody, .isEmpty)])
        try await withScriptedOrigin { origin in
            origin.route("/204", [.send(Array("HTTP/1.1 204 No Content\r\nContent-Type: text/plain\r\n\r\n".utf8))])
            origin.route("/304", [.send(Array("HTTP/1.1 304 Not Modified\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\n".utf8))])
            try await ProxyFixture.run(rules: TestRules.provider([empty])) { fx in
                for (path, status) in [("/204", "204"), ("/304", "304")] {
                    let reply = try await fetch(fx, origin, path)
                    #expect(reply.head.hasPrefix("HTTP/1.1 \(status) "), "\(reply.head)")
                    let flow = try await flow(fx, path)
                    #expect(flow.ruleMark?.source == .rule(id: empty.id, name: "empty"), "\(path)")
                }
            }
        }
    }

    @Test func upgradeResponsesAreNeverHeld() async throws {
        let peek = rule("peek", [row(.responseBody, .isEmpty)])
        try await withScriptedOrigin { origin in
            let barrier = origin.makePromise()
            origin.route("/ws", [
                .send(Array(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                    + "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\nContent-Length: 20\r\n\r\n").utf8)),
                .wait(barrier.futureResult),
            ])
            try await ProxyFixture.run(rules: TestRules.provider([peek])) { fx in
                let client = try await RawClient.connect(port: fx.proxyPort)
                do {
                    let host = "127.0.0.1:\(origin.port)"
                    try await client.send("GET http://\(host)/ws HTTP/1.1\r\nHost: \(host)\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n"
                        + "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n")
                    // Forwarded at once, while the origin still holds the connection open.
                    let head = try await client.receive(until: "\r\n\r\n")
                    #expect(head.hasPrefix("HTTP/1.1 101 "), "\(head)")
                    barrier.succeed(())
                    try await client.close()
                } catch { barrier.succeed(()); try? await client.close(); throw error }
                let flow = try await flow(fx, "/ws")
                #expect(flow.ruleMark == nil)
            }
        }
    }

    // MARK: with a breakpoint

    @Test(arguments: [BreakpointPauseMode.fullBody, .headers])
    func responseBodyPeekAndResponseBreakpointCoexist(mode: BreakpointPauseMode) async throws {
        let coordinator = BreakpointCoordinator()
        let peek = rule("peek", [row(.responseBody, .contains, "stop")])
        let pause = rule("pause", [], [.breakpoint(direction: .response, mode: mode)])
        try await withScriptedOrigin { origin in
            origin.route("/b", [.send(textBytes("please stop here"))])
            try await ProxyFixture.run(rules: TestRules.provider([peek, pause]), breakpoints: coordinator) { fx in
                let reply = Task { try await fetch(fx, origin, "/b") }
                try await waitUntil("paused") { coordinator.snapshot().first.map { $0.state == (mode == .fullBody ? .pausedBody : .pausedHeaders) } == true }
                let ticket = try #require(coordinator.snapshot().first)
                if mode == .fullBody {
                    #expect(try await coordinator.bodyPreview(token: ticket.token, offset: 0, maxBytes: 100) == Data("please stop here".utf8))
                }
                #expect(await coordinator.perform(.continue(token: ticket.token, edit: .init(head: ticket.effectiveHead))) == .accepted)
                #expect(try await reply.value.body == Data("please stop here".utf8))
                #expect(try await flow(fx, "/b").ruleMark?.source == .rule(id: peek.id, name: "peek"))
            }
        }
    }

    // MARK: other transports

    @Test func http2ResponseBodyPeek() async throws {
        let vip = rule("vip", [row(.responseBody, .contains, "fixture")])
        var response = HTTP2TestOrigin.Response()
        response.headers = HTTPHeaders([("content-type", "text/plain"), ("content-length", "12")])
        try await HTTP2TestOrigin.withOrigin(protocols: ["h2"], response: response) { origin in
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true, rules: TestRules.provider([vip])) { fixture, client in
                let reply = try await client.request(headers: HTTPHeaders([("host", "localhost:\(origin.port)")]), path: "/h2peek")
                #expect(reply.status == 200)
                #expect(reply.body == "fixture-body")
                try await waitForCompletedFlows(fixture.store, atLeast: 1)
                let flow = try #require(fixture.store.allFlows().first { $0.path == "/h2peek" })
                #expect(flow.ruleMark?.source == .rule(id: vip.id, name: "vip"))
                #expect(try flow.messages[.downstreamResponse]?.body?.load() == Data("fixture-body".utf8))
            }
        }
    }

    @Test func localResponseBodyConditionMatches() async throws {
        let peek = rule("peek", [row(.responseBody, .contains, "local")])
        try await withLocalAsset(Data("local file".utf8)) { asset in
            let local = rule("asset", [], [.returnFile(MapLocalAction(assetID: asset.asset.id, headers: [HeaderField(name: "Content-Type", value: "text/plain")]))])
            try await ProxyFixture.run(rules: TestRules.provider([peek, local]), assets: asset.store) { fx in
                let reply = try await rawGet(fx, "http://127.0.0.1:\(fx.origin.port)/local")
                #expect(reply.head.hasPrefix("HTTP/1.1 200 OK\r\n"))
                #expect(reply.body == Data("local file".utf8))
                #expect(fx.origin.acceptedConnections == 0)
                let flow = try await flow(fx, "/local")
                #expect(flow.ruleMark?.source == .rule(id: peek.id, name: "peek"))
                #expect(try flow.messages[.downstreamResponse]?.body?.load() == Data("local file".utf8))
            }
        }
    }
}

// MARK: Response fixtures

/// gzip("hello").
private let gzipHello: [UInt8] = [31, 139, 8, 0, 0, 0, 0, 0, 0, 3, 203, 72, 205, 201, 201, 7, 0, 134, 166, 16, 54, 5, 0, 0, 0]

private func textBytes(_ body: String, type: String = "text/plain") -> [UInt8] {
    Array("HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
}
private func gzipBytes() -> [UInt8] {
    Array("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Encoding: gzip\r\nContent-Length: \(gzipHello.count)\r\n\r\n".utf8) + gzipHello
}
private func chunkedHeadBytes() -> [UInt8] {
    Array("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
}
private func chunkBytes(_ text: String) -> [UInt8] { Array("\(String(text.utf8.count, radix: 16))\r\n\(text)\r\n".utf8) }

private func requestText(_ origin: ScriptedOrigin, _ path: String, method: String = "GET") -> String {
    let host = "127.0.0.1:\(origin.port)"
    return "\(method) http://\(host)\(path) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n"
}

private struct RawReply {
    let raw: [UInt8]
    let head: String
    let body: Data
}

private func fetch(_ fixture: ProxyFixture, _ origin: ScriptedOrigin, _ path: String, method: String = "GET") async throws -> RawReply {
    let client = try await RawClient.connect(port: fixture.proxyPort)
    do {
        try await client.send(requestText(origin, path, method: method))
        try await client.waitUntilClosed()
        let bytes = client.remainingBytes()
        try await client.close()
        let data = Data(bytes)
        let separator = try #require(data.range(of: Data("\r\n\r\n".utf8)))
        return RawReply(raw: bytes, head: String(decoding: data[..<separator.lowerBound], as: UTF8.self),
                        body: Data(data[separator.upperBound...]))
    } catch { try? await client.close(); throw error }
}

private func rawGet(_ fixture: ProxyFixture, _ url: String) async throws -> RawReply {
    let host = URL(string: url)!.host! + ":" + String(URL(string: url)!.port!)
    let client = try await RawClient.connect(port: fixture.proxyPort)
    do {
        try await client.send("GET \(url) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n")
        try await client.waitUntilClosed()
        let bytes = client.remainingBytes()
        try await client.close()
        let data = Data(bytes)
        let separator = try #require(data.range(of: Data("\r\n\r\n".utf8)))
        return RawReply(raw: bytes, head: String(decoding: data[..<separator.lowerBound], as: UTF8.self),
                        body: Data(data[separator.upperBound...]))
    } catch { try? await client.close(); throw error }
}
