import Dispatch
import FlowStore
import Foundation
import Localization
import NIOCore
import NIOHTTP1
import NIOPosix
import os
import Testing
@testable import ProxyCore
@testable import RulesEngine

/// Response body rewrite rules through the real proxy (spec B1-B17): what the client's wire
/// carries, what the origin saw, what each flow boundary keeps and which outcome each rule left.
@Suite(.serialized, .timeLimit(.minutes(3)), .productionChinese) struct BodyRewriteResponseTests {
    @Test func textResponseIsRewrittenAndContentLengthRecomputed() async throws {
        let rule = TestRules.rewriteBody(find: "world", replacement: "proxy-woman")
        try await withScriptedOrigin { origin in
            origin.route("/text", [.send(textResponse("hello world"))])
            try await ProxyFixture.run(rules: TestRules.provider([rule])) { fx in
                let reply = try await fetch(fx, origin, "/text")
                #expect(reply.head.hasPrefix("HTTP/1.1 200 OK\r\n"))
                #expect(reply.body == Data("hello proxy-woman".utf8))
                #expect(reply.field("content-length") == ["17"])
                #expect(reply.field("transfer-encoding").isEmpty)
                let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                #expect(try flow.messages[.upstreamResponse]?.body?.load() == Data("hello world".utf8))
                #expect(try flow.messages[.downstreamResponse]?.body?.load() == Data("hello proxy-woman".utf8))
                #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: rule.id, code: .applied)])
            }
        }
    }

    @Test func chunkedResponseIsRewritten() async throws {
        let rule = TestRules.rewriteBody(find: "world", replacement: "there")
        try await withScriptedOrigin { origin in
            origin.route("/chunked", [.send(chunkedHead()), .send(chunk("hello ")), .send(chunk("world")), .send(lastChunk())])
            try await ProxyFixture.run(rules: TestRules.provider([rule])) { fx in
                let reply = try await fetch(fx, origin, "/chunked")
                #expect(reply.body == Data("hello there".utf8))
                #expect(reply.field("content-length") == ["11"])
                #expect(reply.field("transfer-encoding").isEmpty)
                let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                #expect(try flow.messages[.upstreamResponse]?.body?.load() == Data("hello world".utf8))
                #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: rule.id, code: .applied)])
            }
        }
    }

    @Test func gzipResponseIsRewrittenToIdentity() async throws {
        let rule = TestRules.rewriteBody(find: "hello", replacement: "bye")
        try await withScriptedOrigin { origin in
            origin.route("/gzip", [.send(gzipResponse())])
            try await ProxyFixture.run(rules: TestRules.provider([rule])) { fx in
                let reply = try await fetch(fx, origin, "/gzip")
                #expect(reply.body == Data("bye".utf8))
                #expect(reply.field("content-encoding").isEmpty)
                #expect(reply.field("etag").isEmpty)
                #expect(reply.field("content-length") == ["3"])
                let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                #expect(try flow.messages[.upstreamResponse]?.body?.load() == Data(gzipHello))
                #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: rule.id, code: .applied)])
            }
        }
    }

    @Test func noMatchForwardsOriginalGzipBytesAndHeaders() async throws {
        let rule = TestRules.rewriteBody(find: "absent", replacement: "x")
        try await withScriptedOrigin { origin in
            origin.route("/gzip", [.send(gzipResponse())])
            try await ProxyFixture.run(rules: TestRules.provider([rule])) { fx in
                let reply = try await fetch(fx, origin, "/gzip")
                #expect([UInt8](reply.body) == gzipHello)
                #expect(reply.field("content-encoding") == ["gzip"])
                #expect(reply.field("etag") == ["\"v1\""])
                #expect(reply.field("content-length") == [String(gzipHello.count)])
                let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: rule.id, code: .bodyNoMatch)])
                #expect(try flow.messages[.downstreamResponse]?.body?.load() == Data(gzipHello))
            }
        }
    }

    @Test func exhaustedRewriteMemoryForwardsOriginalAndRecordsBusy() async throws {
        let rule = TestRules.rewriteBody(find: "world", replacement: "proxy-woman")
        let limits = RulesLimits(editorMemoryBytes: 10, minimumFreeDiskBytes: 0)
        let budgets = OwnedFileBudgets(limits: limits)
        let runtime = BreakpointBodyRuntime(budgets: budgets, limits: limits)
        try await withScriptedOrigin { origin in
            origin.route("/text", [.send(textResponse("hello world"))])
            try await ProxyFixture.run(rules: TestRules.provider([rule]), bodyRuntime: runtime) { fx in
                let reply = try await fetch(fx, origin, "/text")
                #expect(reply.head.hasPrefix("HTTP/1.1 200 OK\r\n"))
                #expect(reply.body == Data("hello world".utf8), "the original is forwarded, complete")
                let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: rule.id, code: .bodySkippedBusy)])
                try await waitUntil("budgets released: \(budgets.snapshot())") { budgets.snapshot().reservedBytes == 0 }
            }
        }
    }

    @Test func nonTextContentTypeStreamsUntouched() async throws {
        let rule = TestRules.rewriteBody(find: "first", replacement: "x")
        try await withScriptedOrigin { origin in
            let barrier = origin.makePromise()
            origin.route("/binary", [
                .send(chunkedHead(contentType: "application/octet-stream")), .send(chunk("first-part")),
                .wait(barrier.futureResult), .send(chunk("second-part")), .send(lastChunk()),
            ])
            try await ProxyFixture.run(rules: TestRules.provider([rule])) { fx in
                let client = try await RawClient.connect(port: fx.proxyPort)
                do {
                    try await client.send(request(origin, "/binary"))
                    // The first chunk reaches the client while the origin still holds the rest: not buffered.
                    _ = try await client.receive(until: "first-part")
                    barrier.succeed(())
                    _ = try await client.receive(until: "\r\n0\r\n\r\n")
                    try await client.close()
                } catch { barrier.succeed(()); try? await client.close(); throw error }
                let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: rule.id, code: .bodySkippedNotText)])
            }
        }
    }

    @Test func knownLengthOverLimitPassesUntouchedAndRecordsTooLarge() async throws {
        let rule = TestRules.rewriteBody(find: "a", replacement: "b")
        let body = String(repeating: "a", count: 2000)
        try await withScriptedOrigin { origin in
            origin.route("/large", [.send(textResponse(body))])
            try await ProxyFixture.run(rules: TestRules.provider([rule]), bodyRuntime: smallRuntime()) { fx in
                let reply = try await fetch(fx, origin, "/large")
                #expect(reply.body == Data(body.utf8))
                #expect(reply.field("content-length") == ["2000"])
                let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: rule.id, code: .bodySkippedTooLarge)])
            }
        }
    }

    @Test func unknownLengthOverLimitFailsLocally502WithLocalizedPage() async throws {
        let rule = TestRules.rewriteBody(find: "a", replacement: "b")
        try await withScriptedOrigin { origin in
            origin.route("/large", [.send(chunkedHead()), .send(chunk(String(repeating: "a", count: 700))),
                                    .send(chunk(String(repeating: "a", count: 700))), .send(lastChunk())])
            try await ProxyFixture.run(rules: TestRules.provider([rule]), bodyRuntime: smallRuntime()) { fx in
                let reply = try await fetch(fx, origin, "/large")
                #expect(reply.head.hasPrefix("HTTP/1.1 502 Bad Gateway\r\n"))
                let message = HTTPLocalFailureText.rewrite(.rewriteBodyTooLarge, limitMiB: 0)
                #expect(String(decoding: reply.body, as: UTF8.self).contains(message))
                let flow = try await waitForFlow(fx.store) { $0.state != .inProgress }
                #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: rule.id, code: .rejected)])
            }
        }
    }

    @Test func mapLocalFileResponseBodyIsRewritten() async throws {
        let rewrite = TestRules.rewriteBody(find: "local", replacement: "rewritten")
        try await withLocalAsset(Data("local file".utf8)) { asset in
            let map = Rule(id: UUID(), name: "asset", enabled: true, order: 0, matcher: RuleMatcher(),
                           action: .mapLocal(MapLocalAction(assetID: asset.asset.id, status: 200,
                                                            headers: [HeaderField(name: "Content-Type", value: "text/plain")])))
            // R1 intentional change class 1: a rule must rank above the Return File rule to act on its exchange.
            try await ProxyFixture.run(rules: TestRules.provider([rewrite, map]), assets: asset.store) { fx in
                let reply = try await fetchTestOrigin(fx, "/local")
                #expect(reply.head.hasPrefix("HTTP/1.1 200 OK\r\n"))
                #expect(reply.body == Data("rewritten file".utf8))
                #expect(reply.field("content-length") == ["14"])
                #expect(fx.origin.acceptedConnections == 0)
                let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                #expect(try flow.messages[.generatedResponse]?.body?.load() == Data("local file".utf8))
                #expect(try flow.messages[.downstreamResponse]?.body?.load() == Data("rewritten file".utf8))
                #expect(flow.provenance.ruleMatches?.outcomes.contains(RuleOutcome(ruleID: rewrite.id, code: .applied)) == true)
            }
        }
    }

    @Test func mapLocalDirectoryResponseBodyIsRewritten() async throws {
        let rewrite = TestRules.rewriteBody(find: "red", replacement: "blue")
        try await withMappedDirectory(["a.css": Data("body{color:red}".utf8)]) { dir in
            // R1 intentional change class 1: a rule must rank above the Return File rule to act on its exchange.
            try await ProxyFixture.run(rules: dir.rules(higher: [rewrite]), assets: dir.store) { fx in
                let reply = try await fetchTestOrigin(fx, "/static/a.css", host: "app.test")
                #expect(reply.head.hasPrefix("HTTP/1.1 200 OK\r\n"))
                #expect(reply.body == Data("body{color:blue}".utf8))
                #expect(reply.field("content-length") == ["16"])
                let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                #expect(flow.provenance.ruleMatches?.outcomes.contains(RuleOutcome(ruleID: rewrite.id, code: .applied)) == true)
            }
        }
    }

    @Test func localNotFoundPageRewriteSkippedNoBody() async throws {
        let rewrite = TestRules.rewriteBody(find: "a", replacement: "b")
        try await withMappedDirectory(["a.css": Data("body{}".utf8)]) { dir in
            // R1 intentional change class 1: a rule must rank above the Return File rule to act on its exchange.
            try await ProxyFixture.run(rules: dir.rules(higher: [rewrite]), assets: dir.store) { fx in
                let reply = try await fetchTestOrigin(fx, "/static/missing.css", host: "app.test")
                #expect(reply.head.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
                #expect(reply.body.isEmpty)
                let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                #expect(flow.provenance.ruleMatches?.outcomes.contains(RuleOutcome(ruleID: rewrite.id, code: .bodySkippedNoBody)) == true)
            }
        }
    }

    @Test func headResponseNotCollected() async throws {
        let rule = TestRules.rewriteBody(find: "a", replacement: "b")
        try await withScriptedOrigin { origin in
            origin.route("/text", [.send(Array("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 11\r\n\r\n".utf8))])
            try await ProxyFixture.run(rules: TestRules.provider([rule])) { fx in
                let reply = try await fetch(fx, origin, "/text", method: "HEAD")
                #expect(reply.head.hasPrefix("HTTP/1.1 200 OK\r\n"))
                #expect(reply.field("content-length") == ["11"])
                #expect(reply.body.isEmpty)
                let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: rule.id, code: .bodySkippedNoBody)])
            }
        }
    }

    @Test func status304And204NotCollected() async throws {
        let rule = TestRules.rewriteBody(find: "a", replacement: "b")
        try await withScriptedOrigin { origin in
            origin.route("/s204", [.send(Array("HTTP/1.1 204 No Content\r\nContent-Type: text/plain\r\n\r\n".utf8))])
            origin.route("/s304", [.send(Array("HTTP/1.1 304 Not Modified\r\nContent-Type: text/plain\r\n\r\n".utf8))])
            try await ProxyFixture.run(rules: TestRules.provider([rule])) { fx in
                let noContent = try await fetch(fx, origin, "/s204")
                #expect(noContent.head.hasPrefix("HTTP/1.1 204 No Content\r\n"))
                let notModified = try await fetch(fx, origin, "/s304")
                #expect(notModified.head.hasPrefix("HTTP/1.1 304 Not Modified\r\n"))
                try await waitForCompletedFlows(fx.store, atLeast: 2)
                for flow in fx.store.allFlows() {
                    #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: rule.id, code: .bodySkippedNoBody)])
                }
            }
        }
    }

    @Test func breakpointSameDirectionWinsAndRewriteIsSkipped() async throws {
        let rewrite = TestRules.rewriteBody(find: "hello", replacement: "bye")
        let breakpoint = TestRules.breakpoint(.response)
        let coordinator = BreakpointCoordinator()
        try await withScriptedOrigin { origin in
            origin.route("/text", [.send(textResponse("hello world"))])
            try await ProxyFixture.run(rules: TestRules.provider([rewrite, breakpoint]), breakpoints: coordinator) { fx in
                let reply = Task { try await fetch(fx, origin, "/text") }
                try await waitUntil("response paused") { !coordinator.snapshot().isEmpty }
                let ticket = try #require(coordinator.snapshot().first)
                #expect(await coordinator.perform(.continue(token: ticket.token, edit: .init(head: ticket.effectiveHead))) == .accepted)
                #expect(try await reply.value.body == Data("hello world".utf8))
                let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: rewrite.id, code: .bodySkippedBreakpoint),
                                                                  RuleOutcome(ruleID: breakpoint.id, code: .applied)])
            }
        }
    }

    @Test func rulesApplyInOrderOnSameBuffer() async throws {
        let first = TestRules.rewriteBody(find: "cat", replacement: "dog")
        let second = TestRules.rewriteBody(find: "dog", replacement: "bird")
        let third = TestRules.rewriteBody(find: "absent", replacement: "x")
        try await withScriptedOrigin { origin in
            origin.route("/text", [.send(textResponse("cat and dog"))])
            try await ProxyFixture.run(rules: TestRules.provider([first, second, third])) { fx in
                let reply = try await fetch(fx, origin, "/text")
                #expect(reply.body == Data("bird and bird".utf8))
                let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                #expect(flow.provenance.ruleMatches?.outcomes == [
                    RuleOutcome(ruleID: first.id, code: .applied), RuleOutcome(ruleID: second.id, code: .applied),
                    RuleOutcome(ruleID: third.id, code: .bodyNoMatch),
                ])
            }
        }
    }

    @Test func regexTimeoutForwardsOriginalAndRecordsPatternTimedOut() async throws {
        let rule = TestRules.rewriteBody(find: catastrophicFind, replacement: "x", syntax: .regex)
        let cache = PatternCache(bodyBudget: SteppingClock().budget)
        try await withScriptedOrigin { origin in
            origin.route("/slow", [.send(textResponse(catastrophicInput))])
            try await ProxyFixture.run(rules: TestRules.provider([rule], patternCache: cache)) { fx in
                let reply = try await fetch(fx, origin, "/slow")
                #expect(reply.body == Data(catastrophicInput.utf8))
                let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: rule.id, code: .patternTimedOut)])
            }
        }
    }

    @Test func regexDisabledAfterThreeTimeoutsRecordsPatternDisabled() async throws {
        let rule = TestRules.rewriteBody(find: catastrophicFind, replacement: "x", syntax: .regex)
        let cache = PatternCache(bodyBudget: SteppingClock().budget)
        try await withScriptedOrigin { origin in
            origin.route("/slow", [.send(textResponse(catastrophicInput))])
            try await ProxyFixture.run(rules: TestRules.provider([rule], patternCache: cache)) { fx in
                for count in 1...4 {
                    let reply = try await fetch(fx, origin, "/slow")
                    #expect(reply.body == Data(catastrophicInput.utf8))
                    try await waitForCompletedFlows(fx.store, atLeast: count)
                }
                let codes = fx.store.allFlows().sorted { $0.id < $1.id }.map { $0.provenance.ruleMatches?.outcomes.map(\.code) ?? [] }
                #expect(codes == [[.patternTimedOut], [.patternTimedOut], [.patternTimedOut], [.patternDisabled]])
                #expect(cache.isBodyPatternDisabled(BodyRewriteAction(find: catastrophicFind, replacement: "x", syntax: .regex)))
            }
        }
    }

    @Test(arguments: [false, true])
    func http2ResponseIsRewritten(downstreamH2: Bool) async throws {
        try await http2RoundTrip(contentLength: true, downstreamH2: downstreamH2)
    }

    @Test func http2ResponseWithoutContentLengthIsRewritten() async throws {
        try await http2RoundTrip(contentLength: false, downstreamH2: true)
    }

    private func http2RoundTrip(contentLength: Bool, downstreamH2: Bool) async throws {
        let rule = TestRules.rewriteBody(find: "fixture", replacement: "rewritten")
        var response = HTTP2TestOrigin.Response()
        response.headers = HTTPHeaders([("content-type", "text/plain")])
        if contentLength { response.headers.add(name: "content-length", value: "12") }
        try await HTTP2TestOrigin.withOrigin(protocols: ["h2"], response: response) { origin in
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: downstreamH2, rules: TestRules.provider([rule])) { fixture, client in
                let reply = try await client.request(headers: HTTPHeaders([("host", "localhost:\(origin.port)")]), path: "/h2")
                #expect(reply.status == 200)
                #expect(reply.body == "rewritten-body")
                #expect(reply.headers["content-length"] == ["14"])
                try await waitForCompletedFlows(fixture.store, atLeast: 1)
                let flow = try #require(fixture.store.allFlows().first { $0.path == "/h2" })
                #expect(try flow.messages[.upstreamResponse]?.body?.load() == Data("fixture-body".utf8))
                #expect(try flow.messages[.downstreamResponse]?.body?.load() == Data("rewritten-body".utf8))
                #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: rule.id, code: .applied)])
            }
        }
    }

    @Test func upgradeResponseNotCollected() async throws {
        let rule = TestRules.rewriteBody(find: "welcome", replacement: "x")
        try await ProxyFixture.run(rules: TestRules.provider([rule])) { fx in
            let client = try await RawClient.connect(port: fx.proxyPort)
            let p = fx.origin.port
            try await client.send(
                "GET http://127.0.0.1:\(p)/ws HTTP/1.1\r\nHost: 127.0.0.1:\(p)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
            let head = try await client.receive(until: "\r\n\r\n")
            #expect(head.hasPrefix("HTTP/1.1 101 Switching Protocols\r\n"))
            #expect(try await client.receive(until: TestOriginServer.wsGreeting) == TestOriginServer.wsGreeting)
            try await client.close()
            let flow = try await waitForFlow(fx.store) { $0.path == "/ws" && $0.state == .completed }
            #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: rule.id, code: .unsupportedUpgradeAction)])
        }
    }

    @Test func clientDisconnectDuringCollectionReleasesEverything() async throws {
        let rule = TestRules.rewriteBody(find: "a", replacement: "b")
        let limits = RulesLimits(minimumFreeDiskBytes: 0)
        let budgets = OwnedFileBudgets(limits: limits)
        let runtime = BreakpointBodyRuntime(budgets: budgets, limits: limits)
        try await withScriptedOrigin { origin in
            let barrier = origin.makePromise()
            origin.route("/held", [.send(chunkedHead()), .send(chunk("aaaa")), .wait(barrier.futureResult), .send(lastChunk())])
            do {
                try await ProxyFixture.run(rules: TestRules.provider([rule]), bodyRuntime: runtime) { fx in
                    let client = try await RawClient.connect(port: fx.proxyPort)
                    try await client.send(request(origin, "/held"))
                    try await waitUntil("body collecting") { (budgets.snapshot().bytes[.breakpoint] ?? 0) == 4 }
                    #expect(client.remainingBytes().isEmpty, "nothing is forwarded while the body is collected")
                    try await client.close()
                    try await waitUntil("spool and buffers released: \(budgets.snapshot())") { budgets.snapshot().reservedBytes == 0 }
                    // The upstream lease was given up: its connection is closed, not pooled.
                    try await waitUntil("origin connection closed") { origin.closedConnections == 1 }
                    let flow = try await waitForFlow(fx.store) { $0.state != .inProgress }
                    if case .failed = flow.state {} else { Issue.record("expected a failed flow, got \(flow.state)") }
                    // The provisional `applied` never survives a rewrite that did not happen.
                    let settled = try await waitForFlow(fx.store) {
                        $0.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: rule.id, code: .bodySkippedAborted)]
                    }
                    #expect(settled.id == flow.id)
                }
            } catch { barrier.succeed(()); throw error }
            barrier.succeed(())
        }
    }

    @Test func clientDisconnectDuringTransformRecordsAborted() async throws {
        let rule = TestRules.rewriteBody(find: "world", replacement: "there")
        let hold = HoldingClock()
        let limits = RulesLimits(minimumFreeDiskBytes: 0)
        let budgets = OwnedFileBudgets(limits: limits)
        let runtime = BreakpointBodyRuntime(budgets: budgets, limits: limits)
        try await withScriptedOrigin { origin in
            origin.route("/text", [.send(textResponse("hello world"))])
            do {
                try await ProxyFixture.run(rules: TestRules.provider([rule], patternCache: PatternCache(bodyBudget: hold.budget)),
                                           bodyRuntime: runtime) { fx in
                    let client = try await RawClient.connect(port: fx.proxyPort)
                    try await client.send(request(origin, "/text"))
                    await hold.waitEntered()
                    #expect(budgets.snapshot().bytes[.editor] == 33)
                    try await client.close()
                    let flow = try await waitForFlow(fx.store) { $0.state != .inProgress }
                    if case .failed = flow.state {} else { Issue.record("expected a failed flow, got \(flow.state)") }
                    hold.open()
                    try await waitUntil("transform settled: \(budgets.snapshot())") { budgets.snapshot().reservedBytes == 0 }
                    let settled = try await waitForFlow(fx.store) {
                        $0.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: rule.id, code: .bodySkippedAborted)]
                    }
                    #expect(settled.id == flow.id)
                    #expect(client.remainingBytes().isEmpty)
                }
            } catch { hold.open(); throw error }
        }
    }

    /// A client-side writability flip while the rewrite waits for more upstream bytes must not
    /// leave upstream reading off (which would end in the 504 deadline). The exchange runs on a
    /// real HTTP/2 connection's loop with a writer whose writability the test drives.
    @Test func downstreamWritabilityFlipDuringCollectionDoesNotStall() async throws {
        let rule = TestRules.rewriteBody(find: "fixture", replacement: "rewritten")
        let barrierLoop = MultiThreadedEventLoopGroup.singleton.next()
        let barrier = barrierLoop.makePromise(of: Void.self)
        var response = HTTP2TestOrigin.Response()
        response.headers = HTTPHeaders([("content-type", "text/plain")])
        response.bodyBarriersByPath["/flip"] = barrier.futureResult
        do {
            try await HTTP2TestOrigin.withOrigin(protocols: ["h2"], response: response) { origin in
                try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true, rules: TestRules.provider([rule])) { f, _ in
                    let context = try #require(f.connections.withLock { $0.first })
                    let loop = context.eventLoop
                    let bound = try await loop.submit {
                        let writer = FlipWriter(loop: loop)
                        let x = HTTPExchange(requestHead: .init(version: .http2, method: .GET, uri: "/flip",
                                                                headers: HTTPHeaders([("host", "localhost:\(origin.port)")])),
                            target: RequestTarget(host: "localhost", port: origin.port, originForm: "/flip", defaultPort: 443),
                            scheme: "https", downstream: writer, connection: context.value, transport: .init())
                        x.execute(); x.receiveRequest(.end(nil))
                        return NIOLoopBound((x, writer), eventLoop: loop)
                    }.get()
                    // Collecting (the deadline timer is armed) while the origin holds the body.
                    try await waitOnLoop(loop, "rewrite collecting") {
                        bound.value.0.snapshot.breakpointTimers == 1 && bound.value.0.snapshot.responseReading == true
                    }
                    let reading = try await loop.submit {
                        let (x, writer) = bound.value
                        writer.isWritable = false; x.downstreamWritabilityChanged(false)
                        writer.isWritable = true; x.downstreamWritabilityChanged(true)
                        return x.snapshot.responseReading
                    }.get()
                    #expect(reading == true)
                    barrier.succeed(())
                    try await waitOnLoop(loop, "rewritten body delivered") { bound.value.1.ends == 1 }
                    let (status, body) = try await loop.submit { (bound.value.1.heads.map(\.status.code), bound.value.1.body) }.get()
                    #expect(status == [200])
                    #expect(body == "rewritten-body")
                    try await loop.submit { bound.value.0.cancel(reason: "test cleanup") }.get()
                }
            }
        } catch { barrier.succeed(()); throw error }
    }

    @Test func responseRewriteDoesNotChangeUpstreamRequestBytes() async throws {
        let rule = TestRules.rewriteBody(find: "world", replacement: "there")
        try await withScriptedOrigin { origin in
            origin.route("/text", [.send(textResponse("hello world"))])
            try await ProxyFixture.run { fx in
                let reply = try await fetch(fx, origin, "/text")
                #expect(reply.body == Data("hello world".utf8))
            }
            try await ProxyFixture.run(rules: TestRules.provider([rule])) { fx in
                let reply = try await fetch(fx, origin, "/text")
                #expect(reply.body == Data("hello there".utf8))
            }
            let requests = origin.requests
            #expect(requests.count == 2)
            #expect(requests.first == requests.last)
        }
    }

    @Test func noBodyRulesTrafficByteIdentical() async throws {
        let paths = ["/text", "/chunked", "/gzip"]
        try await withScriptedOrigin { origin in
            origin.route("/text", [.send(textResponse("hello world"))])
            origin.route("/chunked", [.send(chunkedHead()), .send(chunk("hello ")), .send(chunk("world")), .send(lastChunk())])
            origin.route("/gzip", [.send(gzipResponse())])
            var plain: [String: [UInt8]] = [:]
            try await ProxyFixture.run { fx in
                for path in paths { plain[path] = try await fetch(fx, origin, path).raw }
            }
            let withoutRules = origin.requests
            // A body rule exists but matches none of these hosts.
            let rules = TestRules.provider([TestRules.rewriteBody(find: "hello", replacement: "bye",
                                                                  matcher: RuleMatcher(hostPattern: "no-such-host.test"))])
            try await ProxyFixture.run(rules: rules) { fx in
                for path in paths { #expect(try await fetch(fx, origin, path).raw == plain[path], "\(path)") }
                try await waitForCompletedFlows(fx.store, atLeast: paths.count)
                #expect(fx.store.allFlows().allSatisfy { $0.provenance.ruleMatches == nil })
            }
            #expect(Array(origin.requests.dropFirst(paths.count)) == withoutRules)
        }
    }

    @Test func statusRewriteAndBodyRewriteTogether() async throws {
        let status = TestRules.rewriteStatus(200)
        let body = TestRules.rewriteBody(find: "missing", replacement: "found")
        try await withScriptedOrigin { origin in
            origin.route("/gone", [.send(textResponse("missing page", status: "404 Not Found"))])
            try await ProxyFixture.run(rules: TestRules.provider([status, body])) { fx in
                let reply = try await fetch(fx, origin, "/gone")
                #expect(reply.head.hasPrefix("HTTP/1.1 200 OK\r\n"))
                #expect(reply.body == Data("found page".utf8))
                #expect(reply.field("content-length") == ["10"])
                let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                #expect(flow.messages[.upstreamResponse]?.status == 404)
                #expect(flow.messages[.downstreamResponse]?.status == 200)
                #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: status.id, code: .applied),
                                                                  RuleOutcome(ruleID: body.id, code: .applied)])
            }
        }
    }

    /// Framing outcomes (`breakpointLengthCorrected`, `breakpointTrailersDropped`) follow the existing
    /// breakpoint-edit recording semantics: they are only attached to the breakpoint rules of that
    /// direction, so a rewrite rule's provenance carries just its own outcome. The rewritten bytes
    /// are recorded on the downstream boundary, the origin's on the upstream boundary.
    @Test func rewrittenBodyIsRecordedWithFramingOutcomes() async throws {
        let rule = TestRules.rewriteBody(find: "world", replacement: "there")
        try await withScriptedOrigin { origin in
            origin.route("/trailers", [
                .send(chunkedHead(extra: "Trailer: x-check\r\n")), .send(chunk("hello world")),
                .send(Array("0\r\nx-check: 1\r\n\r\n".utf8)),
            ])
            try await ProxyFixture.run(rules: TestRules.provider([rule])) { fx in
                let reply = try await fetch(fx, origin, "/trailers")
                #expect(reply.body == Data("hello there".utf8))
                #expect(reply.field("content-length") == ["11"])
                #expect(reply.field("trailer").isEmpty)
                let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: rule.id, code: .applied)])
                #expect(try flow.messages[.upstreamResponse]?.body?.load() == Data("hello world".utf8))
                #expect(try flow.messages[.downstreamResponse]?.body?.load() == Data("hello there".utf8))
            }
        }
    }
}

// MARK: Fixtures

/// gzip("hello").
private let gzipHello: [UInt8] = [31, 139, 8, 0, 0, 0, 0, 0, 0, 3, 203, 72, 205, 201, 201, 7, 0, 134, 166, 16, 54, 5, 0, 0, 0]
private let catastrophicFind = "(a|aa)+c"
private let catastrophicInput = String(repeating: "a", count: 60) + "b"

/// A body budget whose first clock read parks the transform until the test opens it (bounded).
private final class HoldingClock: Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let reads = OSAllocatedUnfairLock(initialState: 0)
    var budget: RegexBudget {
        RegexBudget(maxDuration: .seconds(5), clock: { [self] in
            if reads.withLock({ $0 += 1; return $0 == 1 }) {
                entered.signal()
                _ = release.wait(timeout: .now() + 10)
            }
            return .zero
        })
    }
    func waitEntered() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { _ = self.entered.wait(timeout: .now() + 10); continuation.resume() }
        }
    }
    func open() { release.signal() }
}

/// Polls `condition` on `loop` until it holds, or throws `WaitTimeout`.
private func waitOnLoop(_ loop: EventLoop, _ what: String, _ condition: @escaping @Sendable () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while try await !loop.submit(condition).get() {
        guard ContinuousClock.now < deadline else { throw WaitTimeout(description: "timed out waiting for \(what)") }
        try await Task.sleep(for: .milliseconds(20))
    }
}

/// A downstream writer on a real loop whose writability the test sets; every write succeeds.
private final class FlipWriter: DownstreamResponseWriter {
    let eventLoop: EventLoop
    let version: HTTPWireVersion = .http2
    var isWritable = true
    let isActive = true
    var heads: [HTTPResponseHead] = []
    var body = ""
    var ends = 0
    init(loop: EventLoop) { eventLoop = loop }
    func write(_ part: HTTPServerResponsePart) -> EventLoopFuture<Void> {
        switch part {
        case .head(let head): heads.append(head)
        case .body(.byteBuffer(let bytes)): body += String(buffer: bytes)
        case .body(.fileRegion): break
        case .end: ends += 1
        }
        return eventLoop.makeSucceededVoidFuture()
    }
    func flush() {}
    func setRequestReading(_ enabled: Bool) {}
    func responseFinished() {}
    func abort(_ error: Error) {}
}

/// A body budget whose clock advances one millisecond per read: the catastrophic pattern reads it
/// far more often than its 5 ms allowance, a plain search does not.
private final class SteppingClock: Sendable {
    private let now = OSAllocatedUnfairLock(initialState: Duration.zero)
    var budget: RegexBudget {
        RegexBudget(maxDuration: .milliseconds(5), clock: { [self] in now.withLock { $0 += .milliseconds(1); return $0 } })
    }
}

private func textResponse(_ body: String, status: String = "200 OK") -> [UInt8] {
    Array("HTTP/1.1 \(status)\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
}
private func gzipResponse() -> [UInt8] {
    Array("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Encoding: gzip\r\nETag: \"v1\"\r\nContent-Length: \(gzipHello.count)\r\n\r\n".utf8)
        + gzipHello
}
private func chunkedHead(contentType: String = "text/plain", extra: String = "") -> [UInt8] {
    Array("HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\n\(extra)Transfer-Encoding: chunked\r\n\r\n".utf8)
}
private func chunk(_ text: String) -> [UInt8] { Array("\(String(text.utf8.count, radix: 16))\r\n\(text)\r\n".utf8) }
private func lastChunk() -> [UInt8] { Array("0\r\n\r\n".utf8) }

/// 1 KiB rewrite cap for the over-limit tests.
private func smallRuntime() -> BreakpointBodyRuntime {
    let limits = RulesLimits(minimumFreeDiskBytes: 0, rewriteBodyBytes: 1024)
    return BreakpointBodyRuntime(budgets: OwnedFileBudgets(limits: limits), limits: limits)
}

private func request(_ origin: ScriptedOrigin, _ path: String, method: String = "GET") -> String {
    let host = "127.0.0.1:\(origin.port)"
    return "\(method) http://\(host)\(path) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n"
}

/// One proxied request on its own `Connection: close` connection.
private struct Reply {
    let raw: [UInt8]
    let head: String
    /// The payload with any chunked framing removed.
    let body: Data

    func field(_ name: String) -> [String] {
        head.components(separatedBy: "\r\n").dropFirst().compactMap { line in
            guard let colon = line.firstIndex(of: ":"), line[..<colon].lowercased() == name else { return nil }
            return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
    }
}

private func fetch(_ fixture: ProxyFixture, _ origin: ScriptedOrigin, _ path: String, method: String = "GET") async throws -> Reply {
    try await exchange(fixture, request(origin, path, method: method))
}

private func fetchTestOrigin(_ fixture: ProxyFixture, _ path: String, host: String? = nil) async throws -> Reply {
    let host = host ?? "127.0.0.1:\(fixture.origin.port)"
    return try await exchange(fixture, "GET http://\(host)\(path) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n")
}

private func exchange(_ fixture: ProxyFixture, _ text: String) async throws -> Reply {
    let client = try await RawClient.connect(port: fixture.proxyPort)
    do {
        try await client.send(text)
        try await client.waitUntilClosed()
        let bytes = client.remainingBytes()
        try await client.close()
        let data = Data(bytes)
        let separator = try #require(data.range(of: Data("\r\n\r\n".utf8)))
        let head = String(decoding: data[..<separator.lowerBound], as: UTF8.self)
        var body = Data(data[separator.upperBound...])
        if head.lowercased().contains("\r\ntransfer-encoding: chunked") { body = try dechunk(body) }
        return Reply(raw: bytes, head: head, body: body)
    } catch { try? await client.close(); throw error }
}

private func dechunk(_ data: Data) throws -> Data {
    var rest = data[...], out = Data()
    while true {
        let line = try #require(rest.range(of: Data("\r\n".utf8)))
        let size = try #require(Int(String(decoding: rest[..<line.lowerBound], as: UTF8.self), radix: 16))
        rest = rest[line.upperBound...]
        if size == 0 { return out }
        out.append(rest.prefix(size))
        rest = rest.dropFirst(size + 2)
    }
}
