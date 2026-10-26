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

private func rewrite(_ find: String, _ replacement: String) -> ActionKind {
    .rewriteBody(direction: .request, BodyRewriteAction(find: find, replacement: replacement))
}

/// Request body conditions on live traffic (D12, D13): which bodies are peeked, that the peek never
/// changes or delays what is forwarded beyond collecting it, that the rules run off the event loop,
/// and that every exit releases the collected body.
@Suite(.serialized, .timeLimit(.minutes(3)), .productionChinese) struct RuleBodyConditionIntegrationTests {
    private func flow(_ fx: ProxyFixture) async throws -> Flow {
        try await waitForFlow(fx.store) { $0.path == "/echo" && $0.state != .inProgress }
    }

    // MARK: matching

    @Test func requestBodyContainsMarksTheFlow() async throws {
        let vip = rule("vip", [row(.requestBody, .contains, #""vip":true"#)])
        try await ProxyFixture.run(rules: TestRules.provider([vip])) { fx in
            let body = #"{"name":"a","vip":true}"#
            let reply = try await post(fx, contentType: "application/json", body: body)
            #expect(reply.head.hasPrefix("HTTP/1.1 200 OK\r\n"))
            #expect(reply.body == Data(body.utf8))
            let marked = try await flow(fx)
            #expect(marked.ruleMark?.source == .rule(id: vip.id, name: "vip"))
            #expect(marked.provenance.ruleMatches?.ruleIDs == [vip.id])
        }
        try await ProxyFixture.run(rules: TestRules.provider([vip])) { fx in
            _ = try await post(fx, contentType: "application/json", body: #"{"vip":false}"#)
            #expect(try await flow(fx).ruleMark == nil)
        }
    }

    @Test func requestBodyReachesTheOriginUnchangedWhenOnlyPeeked() async throws {
        let peek = rule("peek", [row(.requestBody, .contains, "world")])
        let body = Array(#"{"hello":"world"}"#.utf8)
        // A keep-alive client: the origin receives exactly the same bytes with and without the rule.
        let request: @Sendable (Int) -> [UInt8] = { port in
            Array(head(port: port, contentType: "application/json", fields: "Content-Length: \(body.count)\r\n", close: false).utf8) + body
        }
        let plain = try await originBytes(rules: nil, until: "world", request)
        let peeked = try await originBytes(rules: TestRules.provider([peek]), until: "world", request)
        #expect(plain.hasSuffix(String(decoding: body, as: UTF8.self)), "\(plain)")
        #expect(peeked == plain)
        try await ProxyFixture.run(rules: TestRules.provider([peek])) { fx in
            _ = try await post(fx, contentType: "application/json", body: String(decoding: body, as: UTF8.self))
            let flow = try await flow(fx)
            #expect(flow.ruleMark != nil)
            #expect(try flow.messages[.downstreamRequest]?.body?.load() == Data(body))
            #expect(try flow.messages[.upstreamRequest]?.body?.load() == Data(body))
            #expect(fx.origin.receivedRequests.last?.body == body)
        }
    }

    @Test func requestBodyRegexRunsOffTheEventLoop() async throws {
        let onLoop = OSAllocatedUnfairLock(initialState: [Bool]())
        let cache = PatternCache(bodyBudget: RegexBudget(maxDuration: .seconds(5), clock: {
            onLoop.withLock { $0.append(MultiThreadedEventLoopGroup.currentEventLoop != nil) }
            return RegexBudget.monotonicNow()
        }))
        let regex = rule("regex", [row(.requestBody, .regex, #""id":\s*\d+"#)])
        try await ProxyFixture.run(rules: TestRules.provider([regex], patternCache: cache)) { fx in
            _ = try await post(fx, contentType: "application/json", body: #"{"id": 42}"#)
            #expect(try await flow(fx).ruleMark != nil)
        }
        let readings = onLoop.withLock { $0 }
        #expect(!readings.isEmpty)
        #expect(readings.allSatisfy { !$0 }, "\(readings)")
    }

    @Test func emptyBodyGetMatchesIsEmpty() async throws {
        let empty = rule("empty", [row(.requestBody, .isEmpty)])
        try await ProxyFixture.run(rules: TestRules.provider([empty])) { fx in
            let reply = try await exchange(fx, Array(("GET http://127.0.0.1:\(fx.origin.port)/hello HTTP/1.1\r\n"
                + "Host: 127.0.0.1:\(fx.origin.port)\r\nConnection: close\r\n\r\n").utf8))
            #expect(reply.body == Data("hello".utf8))
            let flow = try await waitForFlow(fx.store) { $0.path == "/hello" && $0.state == .completed }
            #expect(flow.ruleMark?.source == .rule(id: empty.id, name: "empty"))
            #expect(flow.provenance.ruleMatches?.outcomes.allSatisfy { $0.code == .applied } == true)
        }
    }

    // MARK: bodies that are never collected

    @Test func chunkedRequestBodyIsSkippedAndNotHeld() async throws {
        let peek = rule("peek", [row(.requestBody, .contains, "hello")])
        try await ProxyFixture.run(rules: TestRules.provider([peek])) { fx in
            let client = try await RawClient.connect(port: fx.proxyPort)
            do {
                try await client.send(head(port: fx.origin.port, fields: "Transfer-Encoding: chunked\r\n") + chunk("hello "))
                // Forwarded before the body ended: the origin is contacted while the client still uploads.
                try await waitUntil("origin contacted") { fx.origin.acceptedConnections == 1 }
                try await client.send(chunk("world") + "0\r\n\r\n")
                try await client.waitUntilClosed()
                #expect(String(decoding: client.remainingBytes(), as: UTF8.self).hasPrefix("HTTP/1.1 200 OK\r\n"))
                try await client.close()
            } catch { try? await client.close(); throw error }
            #expect(fx.origin.receivedRequests.last?.body == Array("hello world".utf8))
            let flow = try await flow(fx)
            #expect(flow.ruleMark == nil)
            #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: peek.id, code: .bodySkippedStreaming)])
        }
    }

    @Test func oversizedRequestBodyIsNotCollected() async throws {
        let peek = rule("peek", [row(.requestBody, .contains, "a")])
        let size = 2 * 1_048_576
        try await ProxyFixture.run(rules: TestRules.provider([peek])) { fx in
            let client = try await RawClient.connect(port: fx.proxyPort)
            do {
                try await client.send(head(port: fx.origin.port, fields: "Content-Length: \(size)\r\n") + String(repeating: "a", count: 1024))
                try await waitUntil("origin contacted") { fx.origin.acceptedConnections == 1 }
                try await client.send(String(repeating: "a", count: size - 1024))
                try await client.waitUntilClosed()
                #expect(String(decoding: client.remainingBytes(), as: UTF8.self).hasPrefix("HTTP/1.1 200 OK\r\n"))
                try await client.close()
            } catch { try? await client.close(); throw error }
            let flow = try await flow(fx)
            #expect(flow.ruleMark == nil)
            #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: peek.id, code: .bodyTooLarge)])
        }
    }

    @Test func binaryRequestBodyIsSkippedNotText() async throws {
        let peek = rule("peek", [row(.requestBody, .notContains, "zzz")])
        try await ProxyFixture.run(rules: TestRules.provider([peek])) { fx in
            let reply = try await post(fx, contentType: "image/png", body: "PNGDATA")
            #expect(reply.body == Data("PNGDATA".utf8))
            let flow = try await flow(fx)
            #expect(flow.ruleMark == nil)
            #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: peek.id, code: .bodySkippedNotText)])
        }
    }

    // MARK: the collected body continues

    @Test func peekThenBodyRewriteUsesTheCollectedBody() async throws {
        let budgets = OwnedFileBudgets(limits: RulesLimits(minimumFreeDiskBytes: 0))
        let runtime = BreakpointBodyRuntime(budgets: budgets, limits: RulesLimits(minimumFreeDiskBytes: 0))
        let a = rule("a", [row(.requestBody, .contains, "foo")], [.mark(red), rewrite("foo", "bar")])
        try await ProxyFixture.run(rules: TestRules.provider([a]), bodyRuntime: runtime) { fx in
            let reply = try await post(fx, body: "x foo y")
            #expect(reply.head.hasPrefix("HTTP/1.1 200 OK\r\n"))
            #expect(reply.body == Data("x bar y".utf8))
            #expect(fx.origin.receivedRequests.last?.body == Array("x bar y".utf8))
            #expect(fx.origin.receivedRequests.last?.head.headers.first(name: "content-length") == "7")
            let flow = try await flow(fx)
            #expect(flow.ruleMark != nil)
            #expect(try flow.messages[.downstreamRequest]?.body?.load() == Data("x foo y".utf8))
            #expect(try flow.messages[.upstreamRequest]?.body?.load() == Data("x bar y".utf8))
            #expect(flow.provenance.ruleMatches?.outcomes.contains(RuleOutcome(ruleID: a.id, code: .applied, actionIndex: 1)) == true)
        }
        try await waitUntil("bodies released: \(budgets.snapshot())") { budgets.snapshot().reservedBytes == 0 }
    }

    @Test func peekThenFullBodyBreakpointPausesWithTheCollectedBody() async throws {
        let coordinator = BreakpointCoordinator()
        let pause = rule("pause", [row(.requestBody, .contains, "stop")], [.breakpoint(direction: .request, mode: .fullBody)])
        try await ProxyFixture.run(rules: TestRules.provider([pause]), breakpoints: coordinator) { fx in
            let reply = Task { try await post(fx, body: "please stop here") }
            try await waitUntil("paused with the body") { coordinator.snapshot().first?.state == .pausedBody }
            let ticket = try #require(coordinator.snapshot().first)
            #expect(ticket.bodyLength == 16)
            #expect(try await coordinator.bodyPreview(token: ticket.token, offset: 0, maxBytes: 100) == Data("please stop here".utf8))
            #expect(await coordinator.perform(.continue(token: ticket.token, edit: .init(head: ticket.effectiveHead))) == .accepted)
            #expect(try await reply.value.head.hasPrefix("HTTP/1.1 200 OK\r\n"))
            #expect(fx.origin.receivedRequests.last?.body == Array("please stop here".utf8))
        }
    }

    @Test func peekThenHeadersBreakpointContinuesWithTheCollectedBody() async throws {
        let coordinator = BreakpointCoordinator()
        let pause = rule("pause", [row(.requestBody, .contains, "stop")], [.breakpoint(direction: .request, mode: .headers)])
        try await ProxyFixture.run(rules: TestRules.provider([pause]), breakpoints: coordinator) { fx in
            let reply = Task { try await post(fx, body: "please stop here") }
            try await waitUntil("paused") { !coordinator.snapshot().isEmpty }
            let ticket = try #require(coordinator.snapshot().first)
            #expect(await coordinator.perform(.continue(token: ticket.token, edit: .init(head: ticket.effectiveHead))) == .accepted)
            #expect(try await reply.value.head.hasPrefix("HTTP/1.1 200 OK\r\n"))
            #expect(fx.origin.receivedRequests.last?.body == Array("please stop here".utf8))
        }
    }

    @Test func laterRuleConditionSeesEarlierBodyRewrite() async throws {
        let first = rule("first", [], [rewrite("cat", "dog")])
        let second = rule("second", [row(.requestBody, .contains, "dog")])
        try await ProxyFixture.run(rules: TestRules.provider([first, second])) { fx in
            _ = try await post(fx, body: "a cat")
            #expect(fx.origin.receivedRequests.last?.body == Array("a dog".utf8))
            #expect(try await flow(fx).ruleMark?.source == .rule(id: second.id, name: "second"))
        }
    }

    @Test func peekedRequestToAReturnFileRouteReleasesTheBody() async throws {
        let budgets = OwnedFileBudgets(limits: RulesLimits(minimumFreeDiskBytes: 0))
        let runtime = BreakpointBodyRuntime(budgets: budgets, limits: RulesLimits(minimumFreeDiskBytes: 0))
        try await withLocalAsset(Data("local".utf8)) { asset in
            let local = rule("local", [row(.requestBody, .contains, "go")],
                             [.returnFile(MapLocalAction(assetID: asset.asset.id, headers: [HeaderField(name: "Content-Type", value: "text/plain")]))])
            try await ProxyFixture.run(rules: TestRules.provider([local]), assets: asset.store, bodyRuntime: runtime) { fx in
                let reply = try await post(fx, body: "go")
                #expect(reply.body == Data("local".utf8))
                #expect(fx.origin.acceptedConnections == 0)
                try await waitUntil("bodies released: \(budgets.snapshot())") { budgets.snapshot().reservedBytes == 0 }
                try await waitUntil("spool files removed: \(spoolFiles(runtime))") { spoolFiles(runtime).isEmpty }
            }
        }
    }

    // MARK: release on every exit

    @Test func clientCancelDuringPeekReleasesEverything() async throws {
        let limits = RulesLimits(minimumFreeDiskBytes: 0)
        let budgets = OwnedFileBudgets(limits: limits)
        let runtime = BreakpointBodyRuntime(budgets: budgets, limits: limits)
        let peek = rule("peek", [row(.requestBody, .contains, "x")])
        try await ProxyFixture.run(rules: TestRules.provider([peek]), bodyRuntime: runtime) { fx in
            let client = try await RawClient.connect(port: fx.proxyPort)
            try await client.send(head(port: fx.origin.port, fields: "Content-Length: 10\r\n") + "abcd")
            try await waitUntil("body collecting: \(budgets.snapshot())") { (budgets.snapshot().bytes[.breakpoint] ?? 0) > 0 }
            #expect(fx.origin.acceptedConnections == 0, "nothing is forwarded while the body is peeked")
            try await client.close()
            try await waitUntil("spool and buffers released: \(budgets.snapshot())") { budgets.snapshot().reservedBytes == 0 }
            try await waitUntil("spool directory back to its baseline: \(spoolFiles(runtime))") { spoolFiles(runtime).isEmpty }
            let flow = try await flow(fx)
            if case .failed = flow.state {} else { Issue.record("expected a failed flow, got \(flow.state)") }
            #expect(fx.origin.receivedRequestCount == 0)
        }
    }

    @Test func peekTimeoutContinuesAsUnknown() async throws {
        let limits = RulesLimits(minimumFreeDiskBytes: 0, rewriteSeconds: 1)
        let budgets = OwnedFileBudgets(limits: limits)
        let runtime = BreakpointBodyRuntime(budgets: budgets, limits: limits)
        let peek = rule("peek", [row(.requestBody, .contains, "hello")])
        try await ProxyFixture.run(rules: TestRules.provider([peek]), bodyRuntime: runtime) { fx in
            let client = try await RawClient.connect(port: fx.proxyPort)
            do {
                // The client waits before it uploads: the peek gives up and the request goes on as it is.
                try await client.send(head(port: fx.origin.port, fields: "Content-Length: 5\r\n"))
                try await waitUntil(timeout: .seconds(10), "request forwarded after the peek gave up") { fx.origin.acceptedConnections == 1 }
                try await client.send("hello")
                try await client.waitUntilClosed()
                #expect(String(decoding: client.remainingBytes(), as: UTF8.self).hasPrefix("HTTP/1.1 200 OK\r\n"))
                try await client.close()
            } catch { try? await client.close(); throw error }
            #expect(fx.origin.receivedRequests.last?.body == Array("hello".utf8))
            let flow = try await flow(fx)
            #expect(flow.ruleMark == nil)
            #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: peek.id, code: .bodySkippedUnavailable)])
            try await waitUntil("released: \(budgets.snapshot())") { budgets.snapshot().reservedBytes == 0 }
        }
    }

    @Test func peekTimeoutAfterPartOfTheBodyFailsLocally() async throws {
        // Bytes already taken from the client cannot be forwarded as they were: the exchange ends locally
        // instead of sending a truncated body.
        let limits = RulesLimits(minimumFreeDiskBytes: 0, rewriteSeconds: 1)
        let budgets = OwnedFileBudgets(limits: limits)
        let runtime = BreakpointBodyRuntime(budgets: budgets, limits: limits)
        let peek = rule("peek", [row(.requestBody, .contains, "hello")])
        try await ProxyFixture.run(rules: TestRules.provider([peek]), bodyRuntime: runtime) { fx in
            let client = try await RawClient.connect(port: fx.proxyPort)
            do {
                try await client.send(head(port: fx.origin.port, fields: "Content-Length: 10\r\n") + "hel")
                // The page names the peek, not a body rewrite.
                let reply = try await client.receive(until: HTTPLocalFailureText.peek(.peekBodyTimeout))
                #expect(reply.hasPrefix("HTTP/1.1 504 Gateway Timeout\r\n"), "\(reply)")
                try await client.close()
            } catch { try? await client.close(); throw error }
            #expect(fx.origin.acceptedConnections == 0)
            try await waitUntil("released: \(budgets.snapshot())") { budgets.snapshot().reservedBytes == 0 }
        }
    }

    // MARK: when no peek happens

    @Test func requestsNoBodyRuleCanMatchAreNotHeld() async throws {
        // A body rule for another host: this request streams, untouched and unmarked, exactly as without it.
        let elsewhere = rule("elsewhere", [row(.host, .equals, "other.test"), row(.requestBody, .contains, "hello")])
        try await ProxyFixture.run(rules: TestRules.provider([elsewhere])) { fx in
            let client = try await RawClient.connect(port: fx.proxyPort)
            do {
                try await client.send(head(port: fx.origin.port, fields: "Content-Length: 11\r\n") + "hello")
                try await waitUntil("origin contacted before the body ended") { fx.origin.acceptedConnections == 1 }
                try await client.send(" world")
                try await client.waitUntilClosed()
                #expect(String(decoding: client.remainingBytes(), as: UTF8.self).hasPrefix("HTTP/1.1 200 OK\r\n"))
                try await client.close()
            } catch { try? await client.close(); throw error }
            let flow = try await flow(fx)
            #expect(flow.ruleMark == nil)
            #expect(flow.provenance.ruleMatches == nil)
        }
        let body = Array("hello world".utf8)
        let request: @Sendable (Int) -> [UInt8] = { port in
            Array(head(port: port, fields: "Content-Length: 11\r\n", close: false).utf8) + body
        }
        let plain = try await originBytes(rules: nil, until: "hello world", request)
        let ruled = try await originBytes(rules: TestRules.provider([elsewhere]), until: "hello world", request)
        #expect(ruled == plain)
        try await withConnectionFixture { fixture in
            fixture.environment.bodyRuntime = BreakpointBodyRuntime(budgets: OwnedFileBudgets(limits: RulesLimits()), limits: RulesLimits())
            let headers = HTTPHeaders([("Host", "example.test"), ("Content-Type", "text/plain"), ("Content-Length", "5")])
            let exchange = fixture.admit("/x", method: .POST, headers: headers, writer: RecordingResponseWriter(channel: fixture.client),
                                         context: fixture.context(rules: TestRules.provider([elsewhere])))
            exchange.execute()
            #expect(exchange.bodyGate == nil)
            #expect(!exchange.requestPeek.started)
        }
    }

    /// The stale pooled connection replay of R2 is kept for every request that is not peeked; a peeked
    /// request, like a rewritten one, is never sent twice.
    @Test func staleConnectionReplayIsKeptForRequestsThatAreNotPeeked() async throws {
        let elsewhere = rule("elsewhere", [row(.host, .equals, "other.test"), row(.requestBody, .contains, "hello")])
        let here = rule("here", [row(.requestBody, .contains, "hello")])
        for (rules, replayed) in [([elsewhere], true), ([here], false)] {
            let origin = try await StaleOrigin.start()
            try await ProxyFixture.run(rules: TestRules.provider(rules)) { fx in
                let client = try await RawClient.connect(port: fx.proxyPort)
                do {
                    try await client.send(origin.prime())
                    _ = try await client.receive(until: "primed")
                    try await client.send(origin.put())
                    if replayed { _ = try await client.receive(until: "retried") }
                    else {
                        let reply = try await client.receive(until: "\r\n\r\n")
                        #expect(reply.hasPrefix("HTTP/1.1 502 Bad Gateway\r\n"), "\(reply)")
                    }
                    try await client.close()
                } catch { try? await client.close(); throw error }
                _ = try await waitForFlow(fx.store) { $0.path == "/target" && $0.state != .inProgress }
            }
            #expect(origin.state.withLock { $0.connections } == (replayed ? 2 : 1), "\(replayed)")
            #expect(origin.state.withLock { $0.targetBodies }.count == (replayed ? 2 : 1), "\(replayed)")
            try await origin.stop()
        }
    }

    @Test func responsePointRegexOnThePeekedRequestBodyRunsOffTheEventLoop() async throws {
        let onLoop = OSAllocatedUnfairLock(initialState: [Bool]())
        let cache = PatternCache(bodyBudget: RegexBudget(maxDuration: .seconds(5), clock: {
            onLoop.withLock { $0.append(MultiThreadedEventLoopGroup.currentEventLoop != nil) }
            return RegexBudget.monotonicNow()
        }))
        // Judged at the response (status), reading the body the request point peeked.
        let late = rule("late", [row(.statusCode, .equals, "200"), row(.requestBody, .regex, #""id":\s*\d+"#)])
        try await ProxyFixture.run(rules: TestRules.provider([late], patternCache: cache)) { fx in
            let reply = try await post(fx, contentType: "application/json", body: #"{"id": 7}"#)
            #expect(reply.body == Data(#"{"id": 7}"#.utf8))
            #expect(try await flow(fx).ruleMark?.source == .rule(id: late.id, name: "late"))
        }
        let readings = onLoop.withLock { $0 }
        #expect(!readings.isEmpty)
        #expect(readings.allSatisfy { !$0 }, "\(readings)")
    }

    @Test func publicationHoldIsReleasedOnThePeekPaths() async throws {
        // A rule that can hide at the request point holds new flows back from subscribers until the
        // request point ran (R2); on the peek paths that point runs later, off the loop.
        let hider = rule("hider", [row(.host, .equals, "never.test")], [.hide])
        let peek = rule("peek", [row(.requestBody, .contains, "x")])
        try await ProxyFixture.run(rules: TestRules.provider([hider, peek])) { fx in
            let announced = Announced(fx.store)
            // Collecting: still held.
            let collecting = try await RawClient.connect(port: fx.proxyPort)
            try await collecting.send(head(port: fx.origin.port, fields: "Content-Length: 4\r\n") + "ab")
            let held = try await waitForFlow(fx.store) { $0.path == "/echo" }
            _ = try await exchange(fx, Array(("GET http://127.0.0.1:\(fx.origin.port)/hello HTTP/1.1\r\n"
                + "Host: 127.0.0.1:\(fx.origin.port)\r\nConnection: close\r\n\r\n").utf8))
            let fence = try await waitForFlow(fx.store) { $0.path == "/hello" }
            try await waitUntil("the fence is announced") { announced.contains(fence.id) }
            #expect(!announced.contains(held.id))
            // Not collected (chunked), judged off the loop, then streaming: announced while still in progress.
            let streaming = try await RawClient.connect(port: fx.proxyPort)
            try await streaming.send(head(port: fx.origin.port, fields: "Transfer-Encoding: chunked\r\n") + "1\r\nx\r\n")
            let open = try await waitForFlow(fx.store) { $0.path == "/echo" && $0.id != held.id }
            try await waitUntil("the streaming flow is announced") { announced.contains(open.id) }
            #expect(fx.store.flow(open.id)?.state == .inProgress)
            try await streaming.close()
            // The collected one is announced once its rules ran.
            try await collecting.send("cd")
            try await waitUntil("the collected flow is announced") { announced.contains(held.id) }
            try await collecting.close()
        }
    }

    @Test func upgradeRequestsAreNeverPeeked() async throws {
        let peek = rule("peek", [row(.requestBody, .isEmpty)])
        try await withConnectionFixture { fixture in
            fixture.environment.bodyRuntime = BreakpointBodyRuntime(budgets: OwnedFileBudgets(limits: RulesLimits()), limits: RulesLimits())
            let writer = RecordingResponseWriter(channel: fixture.client)
            let headers = HTTPHeaders([("Host", "example.test"), ("Connection", "Upgrade"), ("Upgrade", "websocket"),
                                       ("Sec-WebSocket-Version", "13"), ("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==")])
            let exchange = fixture.admit("/ws", headers: headers, writer: writer, context: fixture.context(rules: TestRules.provider([peek])))
            exchange.execute()
            #expect(exchange.bodyGate == nil)
            // Judged at once, on the loop, with the body unknown: nothing matched.
            let flow = try fixture.flow("/ws")
            #expect(flow.ruleMark == nil)
            #expect(exchange.requestPeek.started == false)
        }
    }

    @Test func noBodyRowsNoPeeker() async throws {
        let plain = rule("plain", [ConditionRow(field: .pathAndQuery, op: .startsWith, value: "/")])
        let peek = rule("peek", [row(.requestBody, .contains, "x")])
        try await withConnectionFixture { fixture in
            fixture.environment.bodyRuntime = BreakpointBodyRuntime(budgets: OwnedFileBudgets(limits: RulesLimits()), limits: RulesLimits())
            let headers = HTTPHeaders([("Host", "example.test"), ("Content-Type", "text/plain"), ("Content-Length", "5")])
            for (path, rules, peeks) in [("/none", [plain], false), ("/some", [plain, peek], true)] {
                let writer = RecordingResponseWriter(channel: fixture.client)
                let exchange = fixture.admit(path, method: .POST, headers: headers, writer: writer,
                                             context: fixture.context(rules: TestRules.provider(rules)))
                exchange.execute()
                #expect((exchange.bodyGate is ExchangeBodyPeeker) == peeks, "\(path)")
                #expect(exchange.requestPeek.started == peeks, "\(path)")
                // Without body rows the request point ran synchronously: the mark is already there.
                let flow = try fixture.flow(path)
                #expect((flow.ruleMark != nil) == !peeks, "\(path)")
            }
        }
    }

    @Test func http2RequestBodyPeek() async throws {
        let vip = rule("vip", [row(.requestBody, .contains, "fixture")])
        try await HTTP2TestOrigin.withOrigin(protocols: ["h2"]) { origin in
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true, rules: TestRules.provider([vip])) { fixture, client in
                let headers = HTTPHeaders([("host", "localhost:\(origin.port)"), ("content-type", "text/plain"), ("content-length", "12")])
                let reply = try await client.request(headers: headers, path: "/h2peek", method: .POST, body: "fixture-body")
                #expect(reply.status == 200)
                #expect(origin.counts.bodies["/h2peek"] == "fixture-body")
                try await waitForCompletedFlows(fixture.store, atLeast: 1)
                let flow = try #require(fixture.store.allFlows().first { $0.path == "/h2peek" })
                #expect(flow.ruleMark?.source == .rule(id: vip.id, name: "vip"))
                #expect(try flow.messages[.upstreamRequest]?.body?.load() == Data("fixture-body".utf8))
            }
        }
    }
}

// MARK: Fixtures

/// Every flow the store announced to subscribers.
private final class Announced: Sendable {
    private let seen = OSAllocatedUnfairLock(initialState: Set<Int>())
    private let task: Task<Void, Never>

    init(_ store: FlowStore) {
        let stream = store.changes()
        let seen = seen
        task = Task { for await change in stream { seen.withLock { $0.formUnion(change.upserted.map(\.id)) } } }
    }

    func contains(_ id: Int) -> Bool { seen.withLock { $0.contains(id) } }
    deinit { task.cancel() }
}

/// The body files in the runtime's spool directory (its owner marker is the baseline).
private func spoolFiles(_ runtime: BreakpointBodyRuntime) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: runtime.directory.path)) ?? []).filter { !$0.hasPrefix(".") }
}

private func chunk(_ text: String) -> String { "\(String(text.utf8.count, radix: 16))\r\n\(text)\r\n" }

private func head(port: Int, contentType: String = "text/plain", fields: String, close: Bool = true) -> String {
    "POST http://127.0.0.1:\(port)/echo HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Type: \(contentType)\r\n\(fields)"
        + (close ? "Connection: close\r\n" : "") + "\r\n"
}

private struct Reply {
    let head: String
    let body: Data
}

private func post(_ fixture: ProxyFixture, contentType: String = "text/plain", body: String) async throws -> Reply {
    try await exchange(fixture, Array((head(port: fixture.origin.port, contentType: contentType,
                                            fields: "Content-Length: \(body.utf8.count)\r\n") + body).utf8))
}

private func exchange(_ fixture: ProxyFixture, _ request: [UInt8]) async throws -> Reply {
    let client = try await RawClient.connect(port: fixture.proxyPort)
    do {
        try await client.send(bytes: request)
        try await client.waitUntilClosed()
        let data = Data(client.remainingBytes())
        try await client.close()
        let separator = try #require(data.range(of: Data("\r\n\r\n".utf8)))
        return Reply(head: String(decoding: data[..<separator.lowerBound], as: UTF8.self), body: Data(data[separator.upperBound...]))
    } catch { try? await client.close(); throw error }
}

/// Everything the origin of a fresh proxy received for `request` on a keep-alive client, which hangs
/// up once `marker` came back; the origin's port is made constant.
private func originBytes(rules: RuleSnapshotProvider?, until marker: String, _ request: @Sendable (Int) -> [UInt8]) async throws -> String {
    var result = ""
    try await ProxyFixture.run(rules: rules) { fx in
        let client = try await RawClient.connect(port: fx.proxyPort)
        do {
            try await client.send(bytes: request(fx.origin.port))
            _ = try await client.receive(until: marker)
            try await client.close()
        } catch { try? await client.close(); throw error }
        try await waitForCompletedFlows(fx.store, atLeast: 1)
        result = String(decoding: fx.origin.receivedBytes, as: UTF8.self).replacingOccurrences(of: String(fx.origin.port), with: "PORT")
    }
    return result
}
