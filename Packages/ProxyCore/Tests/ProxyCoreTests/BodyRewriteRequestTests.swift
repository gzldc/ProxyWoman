import Dispatch
import FlowStore
import Foundation
import Localization
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing
import os
@testable import ProxyCore
@testable import RulesEngine

/// Request body rewrite rules through the real proxy: what the origin received on the wire, what
/// each flow boundary keeps, and which outcome each rule left. Uploads are raw bytes on a
/// `Connection: close` connection so the framing the client used is exact.
@Suite(.serialized, .timeLimit(.minutes(3)), .productionChinese) struct BodyRewriteRequestTests {
    @Test func jsonRequestBodyIsRewrittenAndOriginSeesNewContentLength() async throws {
        let rule = TestRules.rewriteBody(.request, find: "world", replacement: "proxy-woman")
        let body = #"{"greeting":"hello world"}"#, rewritten = #"{"greeting":"hello proxy-woman"}"#
        try await ProxyFixture.run(rules: TestRules.provider([rule])) { fx in
            let reply = try await post(fx, contentType: "application/json", fields: "Content-Length: \(body.utf8.count)\r\n", body: Array(body.utf8))
            #expect(reply.head.hasPrefix("HTTP/1.1 200 OK\r\n"))
            #expect(reply.body == Data(rewritten.utf8))
            let seen = try #require(fx.origin.receivedRequests.last)
            #expect(seen.body == Array(rewritten.utf8))
            #expect(seen.head.headers.first(name: "content-length") == String(rewritten.utf8.count))
            #expect(!seen.head.headers.contains(name: "transfer-encoding"))
            let flow = try await waitForFlow(fx.store) { $0.state == .completed }
            #expect(try flow.messages[.downstreamRequest]?.body?.load() == Data(body.utf8))
            #expect(try flow.messages[.upstreamRequest]?.body?.load() == Data(rewritten.utf8))
            #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: rule.id, code: .applied)])
        }
    }

    @Test func gzipRequestBodyIsRewrittenToIdentity() async throws {
        let rule = TestRules.rewriteBody(.request, find: "hello", replacement: "bye")
        try await ProxyFixture.run(rules: TestRules.provider([rule])) { fx in
            let reply = try await post(fx, fields: "Content-Encoding: gzip\r\nContent-Length: \(gzipHello.count)\r\n", body: gzipHello)
            #expect(reply.head.hasPrefix("HTTP/1.1 200 OK\r\n"))
            let seen = try #require(fx.origin.receivedRequests.last)
            #expect(seen.body == Array("bye".utf8))
            #expect(!seen.head.headers.contains(name: "content-encoding"))
            #expect(seen.head.headers.first(name: "content-length") == "3")
            let flow = try await waitForFlow(fx.store) { $0.state == .completed }
            #expect(try flow.messages[.downstreamRequest]?.body?.load() == Data(gzipHello))
            #expect(try flow.messages[.upstreamRequest]?.body?.load() == Data("bye".utf8))
            #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: rule.id, code: .applied)])
        }
    }

    @Test func chunkedUploadIsRewritten() async throws {
        let rule = TestRules.rewriteBody(.request, find: "world", replacement: "there")
        try await ProxyFixture.run(rules: TestRules.provider([rule])) { fx in
            let reply = try await post(fx, fields: "Transfer-Encoding: chunked\r\n",
                                       body: Array((chunk("hello ") + chunk("world") + lastChunk()).utf8))
            #expect(reply.head.hasPrefix("HTTP/1.1 200 OK\r\n"))
            let seen = try #require(fx.origin.receivedRequests.last)
            #expect(seen.body == Array("hello there".utf8))
            #expect(seen.head.headers.first(name: "content-length") == "11")
            #expect(!seen.head.headers.contains(name: "transfer-encoding"))
            let flow = try await waitForFlow(fx.store) { $0.state == .completed }
            #expect(try flow.messages[.downstreamRequest]?.body?.load() == Data("hello world".utf8))
            #expect(try flow.messages[.upstreamRequest]?.body?.load() == Data("hello there".utf8))
            #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: rule.id, code: .applied)])
        }
    }

    @Test func expectContinueGetsLocalContinueAfterCollectionStarts() async throws {
        let rule = TestRules.rewriteBody(.request, find: "world", replacement: "there")
        try await ProxyFixture.run(rules: TestRules.provider([rule])) { fx in
            let client = try await RawClient.connect(port: fx.proxyPort)
            do {
                try await client.send(postHead(fx, fields: "Expect: 100-continue\r\nContent-Length: 11\r\n"))
                // The proxy answers the client itself; the origin has seen nothing.
                _ = try await client.receive(until: "HTTP/1.1 100 Continue\r\n\r\n")
                #expect(fx.origin.receivedRequestCount == 0)
                try await client.send("hello world")
                try await client.waitUntilClosed()
                let final = String(decoding: client.remainingBytes(), as: UTF8.self)
                #expect(final.hasPrefix("HTTP/1.1 200 OK\r\n"), "\(final)")
                try await client.close()
            } catch { try? await client.close(); throw error }
            let seen = try #require(fx.origin.receivedRequests.last)
            #expect(seen.body == Array("hello there".utf8))
            #expect(!seen.head.headers.contains(name: "expect"))
            let flow = try await waitForFlow(fx.store) { $0.state == .completed }
            #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: rule.id, code: .applied)])
        }
    }

    @Test func otherExpectValueFallsBackWithUnavailableOutcome() async throws {
        let rule = TestRules.rewriteBody(.request, find: "world", replacement: "there")
        try await ProxyFixture.run(rules: TestRules.provider([rule])) { fx in
            let reply = try await post(fx, fields: "Expect: x-custom\r\nContent-Length: 11\r\n", body: Array("hello world".utf8))
            #expect(reply.head.hasPrefix("HTTP/1.1 200 OK\r\n"))
            #expect(!reply.head.contains("100 Continue"))
            #expect(try #require(fx.origin.receivedRequests.last).body == Array("hello world".utf8))
            let flow = try await waitForFlow(fx.store) { $0.state == .completed }
            #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: rule.id, code: .bodySkippedUnavailable)])
        }
    }

    @Test(arguments: [false, true])
    func http2RequestBodyIsRewritten(downstreamH2: Bool) async throws {
        let rule = TestRules.rewriteBody(.request, find: "fixture", replacement: "rewritten")
        try await HTTP2TestOrigin.withOrigin(protocols: ["h2"]) { origin in
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: downstreamH2, rules: TestRules.provider([rule])) { fixture, client in
                let headers = HTTPHeaders([("host", "localhost:\(origin.port)"), ("content-type", "text/plain"), ("content-length", "12")])
                let reply = try await client.request(headers: headers, path: "/h2up", method: .POST, body: "fixture-body")
                #expect(reply.status == 200)
                #expect(origin.counts.bodies["/h2up"] == "rewritten-body")
                #expect(origin.counts.requestHeaders.first?["content-length"] == ["14"])
                try await waitForCompletedFlows(fixture.store, atLeast: 1)
                let flow = try #require(fixture.store.allFlows().first { $0.path == "/h2up" })
                #expect(try flow.messages[.downstreamRequest]?.body?.load() == Data("fixture-body".utf8))
                #expect(try flow.messages[.upstreamRequest]?.body?.load() == Data("rewritten-body".utf8))
                #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: rule.id, code: .applied)])
            }
        }
    }

    @Test func http2RequestWithoutBodySkipsNoBody() async throws {
        let rule = TestRules.rewriteBody(.request, find: "a", replacement: "b")
        try await HTTP2TestOrigin.withOrigin(protocols: ["h2"]) { origin in
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true, rules: TestRules.provider([rule])) { fixture, client in
                let reply = try await client.request(headers: HTTPHeaders([("host", "localhost:\(origin.port)"), ("content-type", "text/plain")]),
                                                      path: "/h2none")
                #expect(reply.status == 200)
                try await waitForCompletedFlows(fixture.store, atLeast: 1)
                let flow = try #require(fixture.store.allFlows().first { $0.path == "/h2none" })
                #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: rule.id, code: .bodySkippedNoBody)])
                // No gate was created: the request reached the origin straight away.
                #expect(origin.counts.initialEndStreams == [true])
            }
        }
    }

    @Test func getWithoutBodySkipsNoBody() async throws {
        let rule = TestRules.rewriteBody(.request, find: "a", replacement: "b")
        try await ProxyFixture.run(rules: TestRules.provider([rule])) { fx in
            let reply = try await exchange(fx, Array(("GET http://127.0.0.1:\(fx.origin.port)/hello HTTP/1.1\r\n"
                + "Host: 127.0.0.1:\(fx.origin.port)\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n").utf8))
            #expect(reply.body == Data("hello".utf8))
            let flow = try await waitForFlow(fx.store) { $0.state == .completed }
            #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: rule.id, code: .bodySkippedNoBody)])
        }
    }

    @Test func knownLengthOverLimitForwardsUntouched() async throws {
        let rule = TestRules.rewriteBody(.request, find: "a", replacement: "b")
        let body = String(repeating: "a", count: 2000)
        try await ProxyFixture.run(rules: TestRules.provider([rule]), bodyRuntime: smallRuntime()) { fx in
            let reply = try await post(fx, fields: "Content-Length: 2000\r\n", body: Array(body.utf8))
            #expect(reply.body == Data(body.utf8))
            #expect(try #require(fx.origin.receivedRequests.last).body == Array(body.utf8))
            let flow = try await waitForFlow(fx.store) { $0.state == .completed }
            #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: rule.id, code: .bodySkippedTooLarge)])
        }
        // Without a rule the origin sees exactly the same bytes.
        let withRule = try await originBytes(rules: TestRules.provider([rule]), runtime: smallRuntime()) { port in
            postBytes(port: port, fields: "Content-Length: 2000\r\n", body: Array(body.utf8))
        }
        let without = try await originBytes(rules: nil, runtime: nil) { port in
            postBytes(port: port, fields: "Content-Length: 2000\r\n", body: Array(body.utf8))
        }
        #expect(withRule == without)
    }

    @Test func unknownLengthOverLimitFailsLocally413() async throws {
        let rule = TestRules.rewriteBody(.request, find: "a", replacement: "b")
        try await ProxyFixture.run(rules: TestRules.provider([rule]), bodyRuntime: smallRuntime()) { fx in
            let upload = chunk(String(repeating: "a", count: 700)) + chunk(String(repeating: "a", count: 700)) + lastChunk()
            let reply = try await post(fx, fields: "Transfer-Encoding: chunked\r\n", body: Array(upload.utf8))
            #expect(reply.head.hasPrefix("HTTP/1.1 413 Payload Too Large\r\n"), "\(reply.head)")
            let message = HTTPLocalFailureText.rewrite(.rewriteBodyTooLarge, limitMiB: 0)
            #expect(String(decoding: reply.body, as: UTF8.self).contains(message))
            #expect(fx.origin.receivedRequestCount == 0)
            #expect(fx.origin.acceptedConnections == 0)
            let flow = try await waitForFlow(fx.store) { $0.state != .inProgress }
            #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: rule.id, code: .rejected)])
        }
    }

    @Test func mapLocalRouteSkipsRequestRules() async throws {
        let rewrite = TestRules.rewriteBody(.request, find: "hello", replacement: "bye")
        try await withLocalAsset(Data("local file".utf8)) { asset in
            let map = Rule(id: UUID(), name: "asset", enabled: true, order: 0, matcher: RuleMatcher(),
                           action: .mapLocal(MapLocalAction(assetID: asset.asset.id, status: 200,
                                                            headers: [HeaderField(name: "Content-Type", value: "text/plain")])))
            // R1 intentional change class 1: a rule must rank above the Return File rule to act on its exchange.
            try await ProxyFixture.run(rules: TestRules.provider([rewrite, map]), assets: asset.store) { fx in
                let reply = try await post(fx, fields: "Content-Length: 11\r\n", body: Array("hello world".utf8))
                #expect(reply.head.hasPrefix("HTTP/1.1 200 OK\r\n"))
                #expect(reply.body == Data("local file".utf8))
                #expect(fx.origin.acceptedConnections == 0)
                let flow = try await waitForFlow(fx.store) { $0.state == .completed }
                #expect(flow.provenance.ruleMatches?.outcomes.contains(RuleOutcome(ruleID: rewrite.id, code: .bodySkippedLocalRoute)) == true)
            }
        }
    }

    @Test func mapRemoteTargetReceivesRewrittenBody() async throws {
        let rewrite = TestRules.rewriteBody(.request, find: "world", replacement: "there",
                                            matcher: RuleMatcher(hostPattern: "remote.test"))
        let provider = TestRules.provider([rewrite])
        try await ProxyFixture.run(rules: provider) { fx in
            let remote = TestRules.mapRemote(host: "127.0.0.1", port: fx.origin.port, matcher: RuleMatcher(hostPattern: "remote.test"))
            // R1 intentional change class 2: a rule below the Map Remote reads the mapped host, so the
            // rewrite naming the original host ranks above it.
            TestRules.publish([rewrite, remote], revision: 2, to: provider)
            let reply = try await exchange(fx, Array(("POST http://remote.test/echo HTTP/1.1\r\nHost: remote.test\r\n"
                + "Content-Type: text/plain\r\nContent-Length: 11\r\nConnection: close\r\n\r\nhello world").utf8))
            #expect(reply.head.hasPrefix("HTTP/1.1 200 OK\r\n"), "\(reply.head)")
            #expect(try #require(fx.origin.receivedRequests.last).body == Array("hello there".utf8))
            let flow = try await waitForFlow(fx.store) { $0.state == .completed }
            #expect(try flow.messages[.downstreamRequest]?.body?.load() == Data("hello world".utf8))
            #expect(try flow.messages[.upstreamRequest]?.body?.load() == Data("hello there".utf8))
            #expect(flow.provenance.ruleMatches?.outcomes.contains(RuleOutcome(ruleID: rewrite.id, code: .applied)) == true)
        }
    }

    @Test func requestBreakpointWinsAndRewriteIsSkipped() async throws {
        let rewrite = TestRules.rewriteBody(.request, find: "hello", replacement: "bye")
        let breakpoint = TestRules.breakpoint(.request)
        let coordinator = BreakpointCoordinator()
        try await ProxyFixture.run(rules: TestRules.provider([rewrite, breakpoint]), breakpoints: coordinator) { fx in
            let reply = Task { try await post(fx, fields: "Content-Length: 11\r\n", body: Array("hello world".utf8)) }
            try await waitUntil("request paused") { !coordinator.snapshot().isEmpty }
            let ticket = try #require(coordinator.snapshot().first)
            #expect(await coordinator.perform(.continue(token: ticket.token, edit: .init(head: ticket.effectiveHead))) == .accepted)
            #expect(try await reply.value.head.hasPrefix("HTTP/1.1 200 OK\r\n"))
            #expect(try #require(fx.origin.receivedRequests.last).body == Array("hello world".utf8))
            let flow = try await waitForFlow(fx.store) { $0.state == .completed }
            #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: rewrite.id, code: .bodySkippedBreakpoint),
                                                              RuleOutcome(ruleID: breakpoint.id, code: .applied)])
        }
    }

    @Test func noMatchForwardsOriginalBytes() async throws {
        let rule = TestRules.rewriteBody(.request, find: "absent", replacement: "x")
        let body = Array("hello world".utf8)
        // A keep-alive client: the origin receives the same bytes with and without the rule.
        let request: @Sendable (Int) -> [UInt8] = { port in
            Array(postHead(port: port, fields: "Content-Length: 11\r\n").replacingOccurrences(of: "Connection: close\r\n", with: "").utf8) + body
        }
        let plain = try await originBytes(rules: nil, runtime: nil, keepAliveUntil: "hello world", request)
        let matched = try await originBytes(rules: TestRules.provider([rule]), runtime: nil, keepAliveUntil: "hello world", request)
        #expect(plain.hasSuffix("\r\n\r\nhello world"), "\(plain)")
        #expect(matched == plain)
        // With `Connection: close` the exact-body framing keeps that field for the origin (as a
        // breakpoint continuation does); the body bytes are still the client's.
        try await ProxyFixture.run(rules: TestRules.provider([rule])) { fx in
            _ = try await post(fx, fields: "Content-Length: 11\r\n", body: body)
            let flow = try await waitForFlow(fx.store) { $0.state == .completed }
            #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: rule.id, code: .bodyNoMatch)])
            #expect(fx.origin.receivedBytes.suffix(body.count) == body[...])
            #expect(try flow.messages[.upstreamRequest]?.body?.load() == Data(body))
        }
    }

    @Test func rewrittenRequestIsNotRetriedAsReplay() async throws {
        let rule = TestRules.rewriteBody(.request, find: "world", replacement: "there")
        // Control: an untouched PUT on a stale pooled connection is replayed on a fresh one.
        let control = try await StaleOrigin.start()
        try await ProxyFixture.run { fx in
            let client = try await RawClient.connect(port: fx.proxyPort)
            try await client.send(control.prime())
            _ = try await client.receive(until: "primed")
            try await client.send(control.put())
            _ = try await client.receive(until: "retried")
            try await client.close()
        }
        #expect(control.state.withLock { $0.connections } == 2)
        #expect(control.state.withLock { $0.targetBodies } == [Array("hello world".utf8), Array("hello world".utf8)])
        try await control.stop()

        // The rewritten body is never sent a second time, whatever the connection's fate.
        let origin = try await StaleOrigin.start()
        try await ProxyFixture.run(rules: TestRules.provider([rule])) { fx in
            let client = try await RawClient.connect(port: fx.proxyPort)
            try await client.send(origin.prime())
            _ = try await client.receive(until: "primed")
            try await client.send(origin.put())
            let head = try await client.receive(until: "\r\n\r\n")
            #expect(head.hasPrefix("HTTP/1.1 502 Bad Gateway\r\n"), "\(head)")
            try await client.waitUntilClosed()
            try await client.close()
            _ = try await waitForFlow(fx.store) { $0.path == "/target" && $0.state != .inProgress }
        }
        #expect(origin.state.withLock { $0.connections } == 1)
        #expect(origin.state.withLock { $0.targetBodies } == [Array("hello there".utf8)])
        try await origin.stop()
    }

    @Test func clientDisconnectMidUploadReleasesEverything() async throws {
        let rule = TestRules.rewriteBody(.request, find: "a", replacement: "b")
        let limits = RulesLimits(minimumFreeDiskBytes: 0)
        let budgets = OwnedFileBudgets(limits: limits)
        let runtime = BreakpointBodyRuntime(budgets: budgets, limits: limits)
        try await ProxyFixture.run(rules: TestRules.provider([rule]), bodyRuntime: runtime) { fx in
            let client = try await RawClient.connect(port: fx.proxyPort)
            try await client.send(postHead(fx, fields: "Transfer-Encoding: chunked\r\n") + chunk("aaaa"))
            try await waitUntil("body collecting") { (budgets.snapshot().bytes[.breakpoint] ?? 0) == 4 }
            #expect(fx.origin.acceptedConnections == 0, "nothing is forwarded while the body is collected")
            try await client.close()
            try await waitUntil("spool and buffers released: \(budgets.snapshot())") { budgets.snapshot().reservedBytes == 0 }
            let flow = try await waitForFlow(fx.store) { $0.state != .inProgress }
            if case .failed = flow.state {} else { Issue.record("expected a failed flow, got \(flow.state)") }
            let settled = try await waitForFlow(fx.store) {
                $0.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: rule.id, code: .bodySkippedAborted)]
            }
            #expect(settled.id == flow.id)
            #expect(fx.origin.receivedRequestCount == 0)
        }
    }

    @Test func requestAndResponseRulesTogether() async throws {
        let request = TestRules.rewriteBody(.request, find: "hello", replacement: "HI")
        let response = TestRules.rewriteBody(.response, find: "world", replacement: "there")
        try await ProxyFixture.run(rules: TestRules.provider([request, response])) { fx in
            let reply = try await post(fx, fields: "Content-Length: 11\r\n", body: Array("hello world".utf8))
            #expect(reply.body == Data("HI there".utf8))
            #expect(reply.field("content-length") == ["8"])
            #expect(try #require(fx.origin.receivedRequests.last).body == Array("HI world".utf8))
            let flow = try await waitForFlow(fx.store) { $0.state == .completed }
            #expect(try flow.messages[.downstreamRequest]?.body?.load() == Data("hello world".utf8))
            #expect(try flow.messages[.upstreamRequest]?.body?.load() == Data("HI world".utf8))
            #expect(try flow.messages[.upstreamResponse]?.body?.load() == Data("HI world".utf8))
            #expect(try flow.messages[.downstreamResponse]?.body?.load() == Data("HI there".utf8))
            #expect(flow.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: request.id, code: .applied),
                                                              RuleOutcome(ruleID: response.id, code: .applied)])
        }
    }

    @Test func noRequestRulesTrafficByteIdentical() async throws {
        let unrelated = TestRules.provider([TestRules.rewriteBody(.request, find: "hello", replacement: "bye",
                                                                    matcher: RuleMatcher(hostPattern: "no-such-host.test"))])
        let requests: [@Sendable (Int) -> [UInt8]] = [
            { postBytes(port: $0, fields: "Content-Length: 11\r\n", body: Array("hello world".utf8)) },
            { postBytes(port: $0, fields: "Transfer-Encoding: chunked\r\n", body: Array((chunk("hello ") + chunk("world") + lastChunk()).utf8)) },
            { Array(("GET http://127.0.0.1:\($0)/hello HTTP/1.1\r\nHost: 127.0.0.1:\($0)\r\nConnection: close\r\n\r\n").utf8) },
        ]
        for build in requests {
            let plain = try await originBytes(rules: nil, runtime: nil, build)
            let ruled = try await originBytes(rules: unrelated, runtime: nil, build)
            #expect(ruled == plain)
        }
        try await ProxyFixture.run(rules: unrelated) { fx in
            _ = try await post(fx, fields: "Content-Length: 11\r\n", body: Array("hello world".utf8))
            try await waitForCompletedFlows(fx.store, atLeast: 1)
            #expect(fx.store.allFlows().allSatisfy { $0.provenance.ruleMatches == nil })
        }
    }
}

// MARK: Fixtures

/// gzip("hello").
private let gzipHello: [UInt8] = [31, 139, 8, 0, 0, 0, 0, 0, 0, 3, 203, 72, 205, 201, 201, 7, 0, 134, 166, 16, 54, 5, 0, 0, 0]

private func chunk(_ text: String) -> String { "\(String(text.utf8.count, radix: 16))\r\n\(text)\r\n" }
private func lastChunk() -> String { "0\r\n\r\n" }

/// 1 KiB rewrite cap for the over-limit tests.
private func smallRuntime() -> BreakpointBodyRuntime {
    let limits = RulesLimits(minimumFreeDiskBytes: 0, rewriteBodyBytes: 1024)
    return BreakpointBodyRuntime(budgets: OwnedFileBudgets(limits: limits), limits: limits)
}

/// The head of a `POST /echo` through the proxy; `fields` carries the framing and any other fields.
private func postHead(_ fixture: ProxyFixture, contentType: String = "text/plain", fields: String) -> String {
    postHead(port: fixture.origin.port, contentType: contentType, fields: fields)
}

private func postHead(port: Int, contentType: String = "text/plain", fields: String) -> String {
    "POST http://127.0.0.1:\(port)/echo HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Type: \(contentType)\r\n\(fields)Connection: close\r\n\r\n"
}

private func postBytes(port: Int, contentType: String = "text/plain", fields: String, body: [UInt8]) -> [UInt8] {
    Array(postHead(port: port, contentType: contentType, fields: fields).utf8) + body
}

private func post(_ fixture: ProxyFixture, contentType: String = "text/plain", fields: String, body: [UInt8]) async throws -> Reply {
    try await exchange(fixture, postBytes(port: fixture.origin.port, contentType: contentType, fields: fields, body: body))
}

/// Everything the origin of a fresh proxy received for `request`, with its port made constant.
/// With `keepAliveUntil` the client stays connected until that marker arrives, then hangs up.
private func originBytes(rules: RuleSnapshotProvider?, runtime: BreakpointBodyRuntime?, keepAliveUntil marker: String? = nil,
                         _ request: @Sendable (Int) -> [UInt8]) async throws -> String {
    var result = ""
    try await ProxyFixture.run(rules: rules, bodyRuntime: runtime) { fx in
        if let marker {
            let client = try await RawClient.connect(port: fx.proxyPort)
            do {
                try await client.send(bytes: request(fx.origin.port))
                _ = try await client.receive(until: marker)
                try await client.close()
            } catch { try? await client.close(); throw error }
        } else {
            _ = try await exchange(fx, request(fx.origin.port))
        }
        try await waitForCompletedFlows(fx.store, atLeast: 1)
        result = String(decoding: fx.origin.receivedBytes, as: UTF8.self)
            .replacingOccurrences(of: String(fx.origin.port), with: "PORT")
    }
    return result
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

private func exchange(_ fixture: ProxyFixture, _ request: [UInt8]) async throws -> Reply {
    let client = try await RawClient.connect(port: fixture.proxyPort)
    do {
        try await client.send(bytes: request)
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

/// An origin whose first connection closes without answering `/target` (a stale pooled
/// connection); every later connection answers "retried". `/prime` always answers "primed".
/// Also used by `RuleBodyConditionIntegrationTests`.
final class StaleOrigin: Sendable {
    struct State: Sendable {
        var connections = 0
        var targetBodies: [[UInt8]] = []
    }
    let state = OSAllocatedUnfairLock(initialState: State())
    let port: Int
    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel

    private init(port: Int, group: MultiThreadedEventLoopGroup, channel: Channel) {
        self.port = port; self.group = group; self.channel = channel
    }

    func prime() -> String {
        "GET http://127.0.0.1:\(port)/prime HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n"
    }
    func put() -> String {
        "PUT http://127.0.0.1:\(port)/target HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Type: text/plain\r\n"
            + "Content-Length: 11\r\nConnection: close\r\n\r\nhello world"
    }

    static func start() async throws -> StaleOrigin {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let box = OSAllocatedUnfairLock<StaleOrigin?>(initialState: nil)
        do {
            let channel = try await ServerBootstrap(group: group).childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandlers([
                        ByteToMessageHandler(HTTPRequestDecoder()), Handler(origin: box),
                    ])
                }
            }.bind(host: "127.0.0.1", port: 0).get()
            let origin = StaleOrigin(port: channel.localAddress!.port!, group: group, channel: channel)
            box.withLock { $0 = origin }
            return origin
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    func stop() async throws {
        try? await channel.close().get()
        try await group.shutdownGracefully()
    }

    private final class Handler: ChannelInboundHandler {
        typealias InboundIn = HTTPServerRequestPart
        let origin: OSAllocatedUnfairLock<StaleOrigin?>
        var number = 0
        var path = ""
        var body: [UInt8] = []
        init(origin: OSAllocatedUnfairLock<StaleOrigin?>) { self.origin = origin }

        func channelActive(context: ChannelHandlerContext) {
            number = origin.withLock { owner in owner?.state.withLock { $0.connections += 1; return $0.connections } ?? 0 }
            context.fireChannelActive()
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) {
            case .head(let head): path = head.uri; body = []
            case .body(let buffer): body.append(contentsOf: buffer.readableBytesView)
            case .end:
                if path == "/prime" {
                    context.writeAndFlush(NIOAny(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\nprimed")), promise: nil)
                    return
                }
                let received = body
                origin.withLock { owner in owner?.state.withLock { $0.targetBodies.append(received) } }
                if number == 1 { context.close(promise: nil); return }
                context.writeAndFlush(NIOAny(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 7\r\n\r\nretried")), promise: nil)
            }
        }
    }
}
