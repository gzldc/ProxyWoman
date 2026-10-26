import FlowStore
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing
@testable import ProxyCore
@testable import RulesEngine

/// The auto-rewrite features (request/response body rewrite, status rewrite, header edits) together,
/// end to end on real loopback sockets. Every scenario that does not need a TLS-only feature runs
/// once with an HTTP/1 client through the plain-HTTP forward proxy and once with an HTTP/2 client
/// and an HTTP/2 origin through MITM (the forward proxy speaks HTTP/1 only). Expectations are
/// literals; the origin's counters say what really arrived.
@Suite(.serialized, .timeLimit(.minutes(5)), .productionChinese) struct AutoRewriteEndToEndTests {
    // MARK: 1. Features off = byte identical

    @Test(arguments: [false, true])
    func allNewFeaturesOffIsByteIdenticalToNoRules(h2: Bool) async throws {
        let plain = try await observe(h2: h2, rules: nil)
        // A rule of each new action exists, and none of them matches any of these exchanges.
        let inert = TestRules.provider([
            TestRules.rewriteBody(.response, find: "origin", replacement: "x", matcher: RuleMatcher(hostPattern: "no-such-host.test")),
            TestRules.rewriteBody(.request, find: "client", replacement: "x", matcher: RuleMatcher(path: .prefix("/nowhere"))),
            TestRules.rewriteStatus(200, matcher: RuleMatcher(statusRange: 301...399)),
        ])
        let ruled = try await observe(h2: h2, rules: inert)
        #expect(plain.client.count == 3)
        #expect(ruled.client == plain.client, "bytes the client received")
        #expect(ruled.originPaths == plain.originPaths)
        #expect(ruled.originHeaders == plain.originHeaders, "request heads the origin received")
        #expect(ruled.originBodies == plain.originBodies, "request bodies the origin received")
        #expect(ruled.originBodies == ["/upload": "hello client", "/second": "hello again"])
        #expect(ruled.flows == plain.flows, "boundary snapshots of the recorded flows")
        #expect(ruled.flows.count == 3)
        #expect(ruled.provenance.allSatisfy { $0 == "nil" }, "no rule left a record: \(ruled.provenance)")
    }

    // MARK: 2. Header + status + response body + request body in one exchange

    @Test(arguments: [false, true])
    func statusHeaderAndBodyRulesComposeInOrder(h2: Bool) async throws {
        let header = TestRules.headers(.response, [.set(name: "X-Edited", value: "yes")])
        let status = TestRules.rewriteStatus(201)
        let responseBody = TestRules.rewriteBody(.response, find: "origin", replacement: "proxied")
        let requestBody = TestRules.rewriteBody(.request, find: "client", replacement: "proxy")
        try await withOrigin(h2: h2, response: textResponse("origin says hi")) { origin in
            try await withLeg(h2: h2, origin: origin, rules: TestRules.provider([header, status, responseBody, requestBody])) { leg in
                let reply = try await leg.deliver(.POST, path: "/compose", headers: [("content-type", "text/plain")], body: "hello client")
                #expect(reply.status == 201)
                if !h2 { #expect(String(decoding: reply.raw, as: UTF8.self).hasPrefix("HTTP/1.1 201 Created\r\n")) }
                #expect(reply.values("x-edited") == ["yes"])
                #expect(reply.text == "proxied says hi")
                #expect(reply.values("content-length") == ["15"])
                #expect(reply.values("transfer-encoding").isEmpty)
                // The origin saw the rewritten upload with its own length.
                #expect(origin.counts.bodies["/compose"] == "hello proxy")
                let seen = try #require(origin.counts.requestHeaders.first)
                #expect(seen["content-length"] == ["11"])
                #expect(seen["transfer-encoding"].isEmpty)
                let flow = try await waitForFlow(leg.fixture.store) { $0.path == "/compose" && $0.state == .completed }
                #expect(try flow.messages[.downstreamRequest]?.body?.load() == Data("hello client".utf8))
                #expect(try flow.messages[.upstreamRequest]?.body?.load() == Data("hello proxy".utf8))
                #expect(flow.messages[.upstreamResponse]?.status == 200)
                #expect(try flow.messages[.upstreamResponse]?.body?.load() == Data("origin says hi".utf8))
                #expect(flow.messages[.downstreamResponse]?.status == 201)
                #expect(try flow.messages[.downstreamResponse]?.body?.load() == Data("proxied says hi".utf8))
                let matches = try #require(flow.provenance.ruleMatches)
                for rule in [header, status, responseBody, requestBody] {
                    #expect(matches.outcomes.filter { $0.ruleID == rule.id } == [RuleOutcome(ruleID: rule.id, code: .applied)],
                            "\(rule.name): \(matches.outcomes)")
                }
                // Response-side rules are recorded in rule order.
                let order = [header, status, responseBody].compactMap { rule in matches.outcomes.firstIndex { $0.ruleID == rule.id } }
                #expect(order == order.sorted() && order.count == 3)
            }
        }
    }

    // MARK: 3. Evaluated once per message

    @Test(arguments: [false, true])
    func rulesEvaluatedExactlyOncePerMessage(h2: Bool) async throws {
        let header = TestRules.headers(.response, [.set(name: "X-Edited", value: "yes")])
        let status = TestRules.rewriteStatus(202)
        // "origin" appears twice in the body: still one rule, one outcome.
        let responseBody = TestRules.rewriteBody(.response, find: "origin", replacement: "proxied")
        let requestBody = TestRules.rewriteBody(.request, find: "client", replacement: "proxy")
        let rules = [header, status, responseBody, requestBody]
        try await withOrigin(h2: h2, response: textResponse("origin and origin")) { origin in
            try await withLeg(h2: h2, origin: origin, rules: TestRules.provider(rules, revision: 7)) { leg in
                for number in 1...2 {
                    let reply = try await leg.deliver(.POST, path: "/once-\(number)", headers: [("content-type", "text/plain")],
                                                      body: "client client")
                    #expect(reply.status == 202)
                    #expect(reply.text == "proxied and proxied")
                    #expect(origin.counts.bodies["/once-\(number)"] == "proxy proxy")
                }
                try await waitForCompletedFlows(leg.fixture.store, atLeast: 2)
                for flow in leg.fixture.store.allFlows() {
                    let matches = try #require(flow.provenance.ruleMatches, "\(flow.path)")
                    #expect(matches.revision == 7)
                    #expect(matches.ruleIDs.count == 4 && Set(matches.ruleIDs) == Set(rules.map(\.id)), "\(flow.path): \(matches.ruleIDs)")
                    #expect(matches.total == 4 && matches.omitted == 0)
                    #expect(matches.outcomes.count == 4, "\(flow.path): \(matches.outcomes)")
                    #expect(Set(matches.outcomes.map(\.ruleID)) == Set(rules.map(\.id)))
                    #expect(matches.outcomes.allSatisfy { $0.code == .applied })
                }
            }
        }
    }

    @Test(arguments: [false, true])
    func ruleRevisionChangeMidExchangeUsesFrozenSnapshot(h2: Bool) async throws {
        let first = [TestRules.rewriteBody(.request, find: "client", replacement: "one"),
                     TestRules.rewriteBody(.response, find: "origin", replacement: "first"),
                     TestRules.rewriteStatus(201)]
        let second = [TestRules.rewriteBody(.request, find: "client", replacement: "two"),
                      TestRules.rewriteBody(.response, find: "origin", replacement: "second")]
        let provider = TestRules.provider(first, revision: 1)
        let gates = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let release = gates.next().makePromise(of: Void.self)
        var released = false
        var response = textResponse("origin says hi")
        response.barriersByPath["/held"] = release.futureResult
        do {
            try await withOrigin(h2: h2, response: response) { origin in
                try await withLeg(h2: h2, origin: origin, rules: provider) { leg in
                    let held = Task { try await leg.deliver(.POST, path: "/held", headers: [("content-type", "text/plain")], body: "hello client") }
                    // The origin has the whole (rewritten) request and holds its response.
                    try await waitUntil("the held request reached the origin") { origin.counts.endedPaths.contains("/held") }
                    #expect(origin.counts.bodies["/held"] == "hello one")
                    TestRules.publish(second, revision: 2, to: provider)
                    release.succeed(()); released = true
                    let reply = try await held.value
                    // The response is judged by the rules the request was admitted with.
                    #expect(reply.status == 201)
                    #expect(reply.text == "first says hi")
                    let after = try await leg.deliver(.POST, path: "/after", headers: [("content-type", "text/plain")], body: "hello client")
                    #expect(after.status == 200)
                    #expect(after.text == "second says hi")
                    #expect(origin.counts.bodies["/after"] == "hello two")
                    try await waitForCompletedFlows(leg.fixture.store, atLeast: 2)
                    let flows = leg.fixture.store.allFlows()
                    let heldFlow = try #require(flows.first { $0.path == "/held" })
                    let afterFlow = try #require(flows.first { $0.path == "/after" })
                    #expect(heldFlow.provenance.ruleMatches?.revision == 1)
                    #expect(Set(heldFlow.provenance.ruleMatches?.ruleIDs ?? []) == Set(first.map(\.id)))
                    #expect(afterFlow.provenance.ruleMatches?.revision == 2)
                    #expect(Set(afterFlow.provenance.ruleMatches?.ruleIDs ?? []) == Set(second.map(\.id)))
                }
            }
        } catch {
            if !released { release.succeed(()) }
            try? await gates.shutdownGracefully()
            throw error
        }
        try await gates.shutdownGracefully()
    }

    // MARK: 4. Streaming is untouched by rules for other hosts

    @Test(arguments: [false, true])
    func largeStreamingDownloadWithBodyRuleOnOtherHostStreams(h2: Bool) async throws {
        let big = String(repeating: "abcdefghij", count: 600_000) // 6,000,000 bytes, text/plain: eligible but for the host
        var response = textResponse(big)
        response.bodiesByPath["/small"] = "origin says hi"
        let other = TestRules.rewriteBody(.response, find: "abc", replacement: "x", matcher: RuleMatcher(hostPattern: "other.test"))
        let small = TestRules.rewriteBody(.response, find: "origin", replacement: "proxied", matcher: RuleMatcher(path: .exact("/small")))
        try await withOrigin(h2: h2, response: response) { origin in
            try await withLeg(h2: h2, origin: origin, rules: TestRules.provider([other, small])) { leg in
                let budgets = leg.fixture.bodyRuntime.budgets
                let download = try await leg.deliver(path: "/big")
                #expect(download.status == 200)
                #expect(download.body == Array(big.utf8))
                // Not collected: no content length was invented, the origin's framing is still there.
                #expect(download.values("content-length").isEmpty)
                if !h2 { #expect(download.values("transfer-encoding") == ["chunked"]) }
                #expect(budgets.snapshot().peak.values.allSatisfy { $0 == 0 }, "nothing was reserved: \(budgets.snapshot())")
                try await waitForCompletedFlows(leg.fixture.store, atLeast: 1)
                let flow = try #require(leg.fixture.store.allFlows().first { $0.path == "/big" })
                #expect(flow.provenance.ruleMatches == nil)
                // A control that does match is collected, so the zero above is not vacuous.
                let rewritten = try await leg.deliver(path: "/small")
                #expect(rewritten.text == "proxied says hi")
                #expect(budgets.snapshot().peak.values.contains { $0 > 0 })
                try await waitUntil("budgets returned: \(budgets.snapshot())") { budgets.snapshot().reservedBytes == 0 }
            }
        }
    }

    // MARK: 5. gzip

    @Test(arguments: [false, true])
    func gzipRoundTripRewriteThenClientDecodes(h2: Bool) async throws {
        var response = textResponse("")
        response.headers = HTTPHeaders([("content-type", "text/plain"), ("content-encoding", "gzip"), ("etag", "\"v1\"")])
        response.rawBody = gzipVector
        let rewrite = TestRules.rewriteBody(.response, find: "hello", replacement: "bye", matcher: RuleMatcher(path: .exact("/rewritten")))
        let noMatch = TestRules.rewriteBody(.response, find: "absent", replacement: "x", matcher: RuleMatcher(path: .exact("/untouched")))
        let expected = gzipVectorText.replacingOccurrences(of: "hello", with: "bye")
        try await withOrigin(h2: h2, response: response) { origin in
            try await withLeg(h2: h2, origin: origin, rules: TestRules.provider([rewrite, noMatch])) { leg in
                // The client gets plain text: nothing left to decode, and no stale validators.
                let plain = try await leg.deliver(path: "/rewritten")
                #expect(plain.status == 200)
                #expect(plain.text == expected)
                #expect(plain.values("content-encoding").isEmpty)
                #expect(plain.values("etag").isEmpty)
                #expect(plain.values("content-length") == [String(expected.utf8.count)])

                // No match: the compressed bytes and their headers go through, and decode to the original.
                let untouched = try await leg.deliver(path: "/untouched")
                #expect(untouched.body == gzipVector)
                #expect(untouched.values("content-encoding") == ["gzip"])
                #expect(untouched.values("etag") == ["\"v1\""])
                let decoded = try BodyContentCodec.decode(Data(untouched.body), contentEncoding: "gzip", maxOutputBytes: 1 << 20)
                #expect(String(decoding: decoded, as: UTF8.self) == gzipVectorText)

                try await waitForCompletedFlows(leg.fixture.store, atLeast: 2)
                let flows = leg.fixture.store.allFlows()
                let rewritten = try #require(flows.first { $0.path == "/rewritten" })
                #expect(try rewritten.messages[.upstreamResponse]?.body?.load() == Data(gzipVector))
                #expect(try rewritten.messages[.downstreamResponse]?.body?.load() == Data(expected.utf8))
                #expect(rewritten.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: rewrite.id, code: .applied)])
                let kept = try #require(flows.first { $0.path == "/untouched" })
                #expect(kept.provenance.ruleMatches?.outcomes == [RuleOutcome(ruleID: noMatch.id, code: .bodyNoMatch)])
            }
        }
    }

    // MARK: 6. Saving rules publishes schema 3

    @Test(arguments: [false, true])
    func savingRulesWithRewriteRulesPublishesSchema3AndTrafficUsesThem(h2: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("auto-rewrite-e2e-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("config"), withIntermediateDirectories: true)
        let limits = RulesLimits(minimumFreeDiskBytes: 0)
        let assets = ManagedAssetStore(directory: root.appendingPathComponent("assets"), limits: limits,
                                       budgets: OwnedFileBudgets(limits: limits))
        let repository = RuleRepository(directory: root.appendingPathComponent("config"), assets: assets, limits: limits)
        _ = try await repository.load()

        let body = TestRules.rewriteBody(.response, find: "origin", replacement: "proxied")
        let status = TestRules.rewriteStatus(201)
        try await withOrigin(h2: h2, response: textResponse("origin says hi")) { origin in
            try await withLeg(h2: h2, origin: origin, rules: repository.provider) { leg in
                let before = try await leg.deliver(path: "/before")
                #expect(before.status == 200 && before.text == "origin says hi")

                let saved = try await repository.save(groups: [], rules: [body, status], expectedRevision: 0)
                #expect(saved.revision == 1)
                let file = try String(contentsOf: root.appendingPathComponent("config/rules.json"), encoding: .utf8)
                // Rules 2.0: the file itself is always schema 4 (spec 5.1).
                #expect(file.contains(#""schemaVersion":4"#), "\(file)")
                // A fresh repository over the same file reads the rules back.
                let reopened = RuleRepository(directory: root.appendingPathComponent("config"), assets: assets, limits: limits)
                let loaded = try await reopened.load()
                #expect(loaded.rules.map(\.id) == [body.id, status.id])

                let after = try await leg.deliver(path: "/after")
                #expect(after.status == 201)
                #expect(after.text == "proxied says hi")

                // Saving the rules away again, and traffic follows at once.
                let cleared = try await repository.save(groups: [], rules: [], expectedRevision: 1)
                #expect(cleared.revision == 2)
                let last = try await leg.deliver(path: "/last")
                #expect(last.status == 200 && last.text == "origin says hi")

                try await waitForCompletedFlows(leg.fixture.store, atLeast: 3)
                let flows = leg.fixture.store.allFlows()
                #expect(flows.first { $0.path == "/before" }?.provenance.ruleMatches == nil)
                let rewritten = try #require(flows.first { $0.path == "/after" })
                #expect(rewritten.provenance.ruleMatches?.revision == 1)
                let outcomes = rewritten.provenance.ruleMatches?.outcomes ?? []
                #expect(outcomes.count == 2 && outcomes.contains(RuleOutcome(ruleID: body.id, code: .applied))
                        && outcomes.contains(RuleOutcome(ruleID: status.id, code: .applied)))
                #expect(flows.first { $0.path == "/last" }?.provenance.ruleMatches == nil)
            }
        }
    }

    // MARK: 7. Disabling

    @Test(arguments: [false, true])
    func disablingRuleStopsRewritingForNextExchange(h2: Bool) async throws {
        let body = TestRules.rewriteBody(.response, find: "origin", replacement: "proxied")
        let status = TestRules.rewriteStatus(201)
        let provider = TestRules.provider([body, status], revision: 1)
        try await withOrigin(h2: h2, response: textResponse("origin says hi")) { origin in
            try await withLeg(h2: h2, origin: origin, rules: provider) { leg in
                let on = try await leg.deliver(path: "/on")
                #expect(on.status == 201 && on.text == "proxied says hi")

                var disabledBody = body, disabledStatus = status
                disabledBody.enabled = false
                disabledStatus.enabled = false
                TestRules.publish([disabledBody, disabledStatus], revision: 2, to: provider)
                let off = try await leg.deliver(path: "/off")
                #expect(off.status == 200 && off.text == "origin says hi")

                // The same rules enabled again rewrite again (a control for the step above).
                TestRules.publish([body, status], revision: 3, to: provider)
                let again = try await leg.deliver(path: "/again")
                #expect(again.status == 201 && again.text == "proxied says hi")

                // The global switch turns every rule off for the next exchange.
                provider.setEnabled(false)
                let switchedOff = try await leg.deliver(path: "/switched-off")
                #expect(switchedOff.status == 200 && switchedOff.text == "origin says hi")

                try await waitForCompletedFlows(leg.fixture.store, atLeast: 4)
                let flows = leg.fixture.store.allFlows()
                #expect(flows.first { $0.path == "/on" }?.provenance.ruleMatches?.revision == 1)
                #expect(flows.first { $0.path == "/off" }?.provenance.ruleMatches == nil)
                #expect(flows.first { $0.path == "/again" }?.provenance.ruleMatches?.revision == 3)
                #expect(flows.first { $0.path == "/switched-off" }?.provenance.ruleMatches == nil)
            }
        }
    }

    // MARK: 8. Compose

    @Test(arguments: [false, true])
    func rewriteRulesDoNotAffectComposeUnlessApplyRules(h2: Bool) async throws {
        let header = TestRules.headers(.response, [.set(name: "X-Edited", value: "yes")])
        let status = TestRules.rewriteStatus(201)
        let responseBody = TestRules.rewriteBody(.response, find: "origin", replacement: "proxied")
        let requestBody = TestRules.rewriteBody(.request, find: "client", replacement: "proxy")
        let rules = [header, status, responseBody, requestBody]
        try await withOrigin(h2: h2, response: textResponse("origin says hi")) { origin in
            try await RulesComposeServer.run(rules: TestRules.provider(rules), trusted: [origin.ca]) { fx in
                func send(_ path: String, applyRules: Bool) async throws -> ComposeResult {
                    await fx.compose.send(ComposeRequest(
                        method: "POST", url: try composeURL(origin, h2: h2, path: path),
                        headers: [HeaderField(name: "Content-Type", value: "text/plain")],
                        body: .bytes(Data("hello client".utf8)), policy: ComposePolicy(applyRules: applyRules)))
                }
                let off = try await send("/off", applyRules: false)
                #expect(off.failure == nil)
                #expect(off.response?.status == 200)
                #expect(off.response?.body == Data("origin says hi".utf8))
                #expect(off.response?.headers.contains { $0.name.lowercased() == "x-edited" } == false)
                #expect(origin.counts.bodies["/off"] == "hello client")
                let offFlow = try await waitForFlow(fx.store) { $0.id == off.flowID && $0.state == .completed }
                #expect(offFlow.provenance.rulesDisabled)
                #expect(offFlow.provenance.ruleMatches == nil)

                let on = try await send("/on", applyRules: true)
                #expect(on.failure == nil)
                #expect(on.response?.status == 201)
                #expect(on.response?.body == Data("proxied says hi".utf8))
                #expect(on.response?.headers.contains { $0.name.lowercased() == "x-edited" && $0.value == "yes" } == true)
                #expect(origin.counts.bodies["/on"] == "hello proxy")
                let onFlow = try await waitForFlow(fx.store) { $0.id == on.flowID && $0.state == .completed }
                #expect(!onFlow.provenance.rulesDisabled)
                let matches = try #require(onFlow.provenance.ruleMatches)
                for rule in rules {
                    #expect(matches.outcomes.filter { $0.ruleID == rule.id } == [RuleOutcome(ruleID: rule.id, code: .applied)],
                            "\(rule.name): \(matches.outcomes)")
                }
                await fx.expectComposeIdle()
            }
        }
    }

    // MARK: 9. Budgets

    @Test(arguments: [false, true])
    func budgetsReturnToZeroAfterManyRewrites(h2: Bool) async throws {
        let responseBody = TestRules.rewriteBody(.response, find: "origin", replacement: "proxied")
        let requestBody = TestRules.rewriteBody(.request, find: "client", replacement: "proxy")
        let count = 200
        try await withOrigin(h2: h2, response: textResponse("origin says hi")) { origin in
            try await withLeg(h2: h2, origin: origin, rules: TestRules.provider([requestBody, responseBody])) { leg in
                let budgets = leg.fixture.bodyRuntime.budgets
                for number in 1...count {
                    let reply = try await leg.deliver(.POST, path: "/n", headers: [("content-type", "text/plain")], body: "hello client \(number)")
                    #expect(reply.text == "proxied says hi", "exchange \(number)")
                    if reply.text != "proxied says hi" { break }
                }
                #expect(origin.counts.requests == count)
                #expect(origin.counts.bodies["/n"]?.hasSuffix("hello proxy \(count)") == true)
                try await waitForCompletedFlows(leg.fixture.store, atLeast: count)
                try await waitUntil("budgets returned: \(budgets.snapshot())") { budgets.snapshot().reservedBytes == 0 }
                let snapshot = budgets.snapshot()
                #expect(snapshot.bytes.isEmpty && snapshot.reservedBytes == 0, "\(snapshot)")
                #expect(snapshot.peak.values.contains { $0 > 0 }, "the rewrites really reserved budget: \(snapshot)")
                try await RulesComposeBarriers.expectIdle(leg.fixture)
                #expect(leg.fixture.store.allFlows().allSatisfy { $0.provenance.ruleMatches?.outcomes.allSatisfy { $0.code == .applied } == true })
            }
        }
    }
}

// MARK: - Fixtures

/// gzip(gzipVectorText), mtime 0.
private let gzipVector: [UInt8] = [
    31, 139, 8, 0, 0, 0, 0, 0, 2, 255, 203, 72, 205, 201, 201, 87, 40, 207, 47, 202, 73, 209, 81, 200, 0, 115, 10, 138, 242,
    43, 42, 129, 66, 185, 137, 121, 122, 80, 161, 81, 249, 81, 249, 81, 249, 81, 249, 225, 39, 15, 0, 19, 48, 193, 185, 0, 5, 0, 0,
]
private let gzipVectorText = String(repeating: "hello world, hello proxy woman. ", count: 40)

/// A plain-text origin answer for every path (HTTP/1: chunked; HTTP/2: no length), without trailers.
private func textResponse(_ body: String) -> HTTP2TestOrigin.Response {
    var response = HTTP2TestOrigin.Response()
    response.headers = HTTPHeaders([("content-type", "text/plain")])
    response.body = body
    response.trailers = nil
    return response
}

/// One origin: plain HTTP for the HTTP/1 leg, TLS HTTP/2 for the MITM leg.
private func withOrigin(h2: Bool, response: HTTP2TestOrigin.Response, _ body: (HTTP2TestOrigin) async throws -> Void) async throws {
    let origin = try await HTTP2TestOrigin.start(protocols: h2 ? ["h2"] : [], response: response, plaintext: !h2)
    do { try await body(origin) } catch { try? await origin.stop(); throw error }
    try await origin.stop()
}

/// What a client leg received, normalized across HTTP/1 and HTTP/2. `raw` is the HTTP/1 wire.
private struct Delivered: Sendable {
    var status: Int
    /// `name: value`, names lower-cased, in arrival order.
    var fields: [String]
    var body: [UInt8]
    var raw: [UInt8]

    var text: String { String(decoding: body, as: UTF8.self) }
    func values(_ name: String) -> [String] {
        let prefix = name.lowercased() + ": "
        return fields.compactMap { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil }
    }
}

extension Leg {
    /// One request on its own connection (HTTP/1) or its own stream (HTTP/2), with an optional body.
    fileprivate func deliver(_ method: HTTPMethod = .GET, path: String, headers: [(String, String)] = [],
                             body: String? = nil) async throws -> Delivered {
        if let client {
            var fields = [("host", "localhost:\(origin.port)")] + headers
            if let body { fields.append(("content-length", String(body.utf8.count))) }
            let reply = try await client.request(headers: HTTPHeaders(fields), path: path, method: method, body: body)
            return Delivered(status: reply.status, fields: reply.headers.map { "\($0.name.lowercased()): \($0.value)" },
                             body: reply.bytes, raw: [])
        }
        let raw = try await RawClient.connect(port: try #require(fixture.channel.localAddress?.port))
        do {
            let authority = "127.0.0.1:\(origin.port)"
            var head = "\(method.rawValue) http://\(authority)\(path) HTTP/1.1\r\nHost: \(authority)\r\n"
            for (name, value) in headers { head += "\(name): \(value)\r\n" }
            if let body { head += "Content-Length: \(body.utf8.count)\r\n" }
            head += "Connection: close\r\n\r\n"
            try await raw.send(head + (body ?? ""))
            try await raw.waitUntilClosed()
            let bytes = raw.remainingBytes()
            try await raw.close()
            let parsed = try #require(RawHTTP1Response.parse(bytes), "incomplete response: \(String(decoding: bytes, as: UTF8.self))")
            let lines = parsed.response.head.components(separatedBy: "\r\n")
            let status = Int(lines[0].split(separator: " ").dropFirst().first ?? "") ?? 0
            let fields = lines.dropFirst().compactMap { line -> String? in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                return line[..<colon].lowercased() + ": " + line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            return Delivered(status: status, fields: fields, body: parsed.response.body, raw: bytes)
        } catch { try? await raw.close(); throw error }
    }
}

// MARK: - Observation (byte identity)

private struct Observation: Sendable {
    var client: [String]
    var originPaths: [String]
    var originHeaders: [String]
    var originBodies: [String: String]
    var flows: [String]
    var provenance: [String]
}

/// Three exchanges through a fresh proxy and origin: everything the client got, the origin saw and
/// the flow store recorded, with the origin's port made constant.
private func observe(h2: Bool, rules: RuleSnapshotProvider?) async throws -> Observation {
    var response = textResponse("origin says hello client")
    response.trailers = HTTPHeaders([("x-finish", "done")])
    var result: Observation?
    try await withOrigin(h2: h2, response: response) { origin in
        try await withLeg(h2: h2, origin: origin, rules: rules) { leg in
            let port = String(origin.port)
            let replies = [
                try await leg.deliver(path: "/plain?x=1"),
                try await leg.deliver(.POST, path: "/upload", headers: [("content-type", "text/plain")], body: "hello client"),
                try await leg.deliver(.POST, path: "/second", headers: [("content-type", "text/plain")], body: "hello again"),
            ]
            try await waitForCompletedFlows(leg.fixture.store, atLeast: 3)
            let flows = leg.fixture.store.allFlows().sorted { $0.path < $1.path }
            let counts = origin.counts
            result = Observation(
                client: replies.map {
                    h2 ? "\($0.status)\n\($0.fields.joined(separator: "\n"))\n\($0.text)" : String(decoding: $0.raw, as: UTF8.self)
                },
                originPaths: counts.paths,
                originHeaders: counts.requestHeaders.map { String(describing: $0).replacingOccurrences(of: port, with: "PORT") },
                originBodies: counts.bodies,
                flows: flows.map { describe($0, port: port) },
                provenance: flows.map { String(describing: $0.provenance.ruleMatches) })
        }
    }
    return try #require(result)
}

private func describe(_ flow: Flow, port: String) -> String {
    var lines = ["\(flow.method) \(flow.path) \(flow.state) sent=\(flow.bytesSent) received=\(flow.bytesReceived)",
                 "transport \(flow.transport)"]
    for boundary in HTTPMessageBoundary.allCases {
        guard let message = flow.messages[boundary] else { continue }
        let body = (try? message.body?.load()).map { String(decoding: $0, as: UTF8.self) } ?? "-"
        lines.append("\(boundary.rawValue) \(message.head) trailers=\(message.trailers) wire=\(String(describing: message.wireVersion)) "
                     + "stream=\(String(describing: message.streamID)) \(message.bodyState) observed=\(message.observedBytes) "
                     + "\(message.transferState) body=\(body)")
    }
    return lines.joined(separator: "\n").replacingOccurrences(of: port, with: "PORT")
}
