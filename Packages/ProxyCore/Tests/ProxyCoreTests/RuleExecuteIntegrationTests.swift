import FlowStore
import Foundation
import Testing
@testable import ProxyCore
@testable import RulesEngine

/// Rules 2.0 phase R6, Execute against real traffic: the offline evaluation of a captured flow produces the
/// same response the live pipeline sent, sends nothing to the network, and leaves the live records, the hit
/// counts and later live traffic exactly as they were.
///
/// Transport headers (`Connection`, `Date`, `Transfer-Encoding`) are ignored when a live response is compared
/// with an Execute overlay: the overlay holds the rules' result, not the wire framing (ruled in the brief).
@Suite(.serialized, .timeLimit(.minutes(3)), .productionChinese) struct RuleExecuteIntegrationTests {
    // MARK: helpers

    private static let permissive = RulesLimits(minimumFreeDiskBytes: 0)

    private static func bodyRuntime() -> BreakpointBodyRuntime {
        BreakpointBodyRuntime(budgets: OwnedFileBudgets(limits: permissive), limits: permissive)
    }

    private static func rule(_ name: String, _ kinds: ActionKind..., rows: [ConditionRow] = [], final: Bool = false) -> Rule {
        Rule(
            name: name, conditions: ConditionGroup(rows: rows),
            actions: kinds.map { RuleAction($0, isFinal: final) })
    }

    private static func responseHeader(_ name: String, _ value: String) -> ActionKind {
        .editHeaders(direction: .response, operations: [.set(name: name, value: value)])
    }

    private static func requestHeader(_ name: String, _ value: String) -> ActionKind {
        .editHeaders(direction: .request, operations: [.set(name: name, value: value)])
    }

    private static let red = MarkAction(background: "#FF3B30", foreground: "#FFFFFF", text: "parity")

    /// One GET through the proxy; the whole raw reply.
    private static func fetch(_ fx: ProxyFixture, target: String, authority: String) async throws -> String {
        let client = try await RawClient.connect(port: fx.proxyPort)
        do {
            try await client.send(
                "GET http://\(authority)\(target) HTTP/1.1\r\nHost: \(authority)\r\nX-Orig-Req: 1\r\nConnection: close\r\n\r\n")
            try await client.waitUntilClosed()
            let text = String(decoding: client.remainingBytes(), as: UTF8.self)
            try await client.close()
            return text
        } catch { try? await client.close(); throw error }
    }

    private static let transportHeaders: Set<String> = ["connection", "date", "transfer-encoding"]

    private static func comparable(_ headers: [HeaderField]) -> [HeaderField] {
        headers.filter { !transportHeaders.contains($0.name.lowercased()) }
    }

    private static func completedFlow(_ store: FlowStore, excluding known: Set<Int> = []) async throws -> Flow {
        try await waitForFlow(store) { $0.state == .completed && !known.contains($0.id) }
    }

    private static func environment(assets: ManagedAssetStore? = nil, cache: PatternCache = PatternCache()) -> ExecuteEnvironment {
        let store = assets ?? ManagedAssetStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("pw-t13-\(UUID().uuidString)"),
            limits: permissive, budgets: OwnedFileBudgets(limits: permissive))
        return ExecuteEnvironment(assets: store, limits: permissive, cache: cache, timeZone: .gmt, makeBody: { .memory($0) })
    }

    private static func execute(
        _ flow: Flow, rules: RuleSnapshotProvider, environment: ExecuteEnvironment, prepare: Bool = true
    ) async throws -> ExecuteFlowResult {
        let snapshot = rules.current()
        // A run compiles its patterns once (which also forgets earlier timeouts), then evaluates every flow.
        if prepare { ExecuteEngine.prepare(snapshot, cache: environment.cache) }
        return try await ExecuteEngine.run(flow, snapshot: snapshot, environment: environment)
    }

    /// What `ExecuteRunner` does with a result: the writer on the stored flow.
    private static func write(_ result: ExecuteFlowResult, to id: Int, in store: FlowStore) {
        let found = store.update(id) { ExecuteWriter.apply(result, runID: UUID(), to: &$0) }
        #expect(found)
    }

    private static func markParts(_ mark: FlowMark?) -> [String?] { [mark?.background, mark?.foreground, mark?.text] }

    private static func executeMark(_ result: ExecuteFlowResult) -> FlowMark? {
        for case .mark(let mark) in result.annotations.reversed() { return mark }
        return nil
    }

    private static let originReply = Array(
        ("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nX-Origin: o\r\nContent-Length: 11\r\n\r\nhello world").utf8)

    /// The five-rule scenario of the parity test: request header edit, response header edit, status rewrite,
    /// body find and replace, mark.
    private static func scenarioRules() -> [Rule] {
        [
            rule("req", requestHeader("X-Added-Req", "r")),
            rule("resp", responseHeader("X-Added-Resp", "p")),
            rule("status", .rewriteStatus(RewriteStatusAction(status: 202))),
            rule("body", .rewriteBody(direction: .response, BodyRewriteAction(find: "hello", replacement: "goodbye, dear"))),
            rule("mark", .mark(red)),
        ]
    }

    // MARK: parity

    @Test func executeMatchesLiveForTheSameRules() async throws {
        try await withScriptedOrigin { origin in
            origin.route("/p", [.send(Self.originReply)])
            let rules = TestRules.provider(Self.scenarioRules())
            try await ProxyFixture.run(rules: rules, bodyRuntime: Self.bodyRuntime()) { fx in
                let authority = "127.0.0.1:\(origin.port)"
                // A: the rules run live.
                _ = try await Self.fetch(fx, target: "/p", authority: authority)
                let live = try await Self.completedFlow(fx.store)
                let liveResponse = try #require(live.messages[.downstreamResponse])
                #expect(live.ruleMark != nil)
                #expect(try liveResponse.body?.load() == Data("goodbye, dear world".utf8), "the live rules really changed the body")
                // B: the same request with the rules off.
                rules.setEnabled(false)
                _ = try await Self.fetch(fx, target: "/p", authority: authority)
                let captured = try await Self.completedFlow(fx.store, excluding: [live.id])
                #expect(captured.provenance.ruleMatches == nil)
                #expect(try captured.messages[.downstreamResponse]?.body?.load() == Data("hello world".utf8))

                let result = try await Self.execute(captured, rules: rules, environment: Self.environment())
                let overlay = try #require(result.overlay?.response)
                #expect(result.overlay?.responseIsLocal == false)
                guard case .response(let status, let reason, _) = overlay.head,
                    case .response(let liveStatus, let liveReason, _) = liveResponse.head
                else { Issue.record("not response heads"); return }
                #expect(status == liveStatus && status == 202)
                #expect(reason == liveReason, "reason \(String(describing: reason)) vs \(String(describing: liveReason))")
                #expect(Self.comparable(overlay.headers) == Self.comparable(liveResponse.headers))
                #expect(try overlay.body?.load() == liveResponse.body?.load())
                #expect(Self.markParts(Self.executeMark(result)) == Self.markParts(live.ruleMark))
                #expect(Self.executeMark(result) != nil)
                // The request side: the origin saw the added header live, and the overlay request has it.
                let sentUpstream = try #require(live.messages[.upstreamRequest])
                #expect(sentUpstream.headers.contains { $0.name.lowercased() == "x-added-req" && $0.value == "r" })
                let overlayRequest = try #require(result.overlay?.request)
                #expect(overlayRequest.headers.contains { $0.name.lowercased() == "x-added-req" && $0.value == "r" })
                // The same rules fired, in the same order, with the same outcomes.
                #expect(result.matches?.ruleIDs == live.provenance.ruleMatches?.ruleIDs)
                #expect(result.matches?.outcomes.map(\.code) == live.provenance.ruleMatches?.outcomes.map(\.code))
            }
        }
    }

    @Test func executeFinalReturnFileMatchesLive() async throws {
        try await withLocalAsset(Data("local-bytes".utf8)) { asset in
            let higher = Self.rule("higher", Self.responseHeader("X-Higher", "1"))
            let local = Self.rule(
                "local", .returnFile(MapLocalAction(
                    assetID: asset.asset.id, headers: [
                        HeaderField(name: "Content-Type", value: "application/octet-stream"),
                        // A forged length: live still frames the response with the real body length.
                        HeaderField(name: "Content-Length", value: "999"),
                    ])))
            let lower = Self.rule("lower", Self.responseHeader("X-Lower", "1"))
            let rules = TestRules.provider([higher, local, lower])
            try await ProxyFixture.run(rules: rules, assets: asset.store) { fx in
                let authority = "127.0.0.1:\(fx.origin.port)"
                _ = try await Self.fetch(fx, target: "/hello", authority: authority)
                let live = try await Self.completedFlow(fx.store)
                let liveResponse = try #require(live.messages[.downstreamResponse])
                #expect(liveResponse.headers.contains { $0.name.lowercased() == "x-higher" })
                #expect(!liveResponse.headers.contains { $0.name.lowercased() == "x-lower" })
                #expect(fx.origin.receivedRequestCount == 0)

                rules.setEnabled(false)
                _ = try await Self.fetch(fx, target: "/hello", authority: authority)
                let captured = try await Self.completedFlow(fx.store, excluding: [live.id])
                #expect(fx.origin.receivedRequestCount == 1)

                let result = try await Self.execute(
                    captured, rules: rules, environment: Self.environment(assets: asset.store))
                let overlay = try #require(result.overlay?.response)
                #expect(result.overlay?.responseIsLocal == true)
                guard case .response(let status, let reason, _) = overlay.head,
                    case .response(let liveStatus, let liveReason, _) = liveResponse.head
                else { Issue.record("not response heads"); return }
                #expect(status == liveStatus)
                #expect(reason == liveReason, "reason \(String(describing: reason)) vs \(String(describing: liveReason))")
                #expect(Self.comparable(overlay.headers) == Self.comparable(liveResponse.headers))
                #expect(try overlay.body?.load() == Data("local-bytes".utf8))
                #expect(try overlay.body?.load() == liveResponse.body?.load())
                #expect(result.matches?.ruleIDs == live.provenance.ruleMatches?.ruleIDs)
                #expect(result.matches?.outcomes.map(\.code) == live.provenance.ruleMatches?.outcomes.map(\.code))
            }
        }
    }

    // MARK: no network

    @Test func executeAfterLiveTrafficSendsNothingUpstream() async throws {
        try await withScriptedOrigin { origin in
            origin.route("/p", [.send(Self.originReply)])
            let rules = TestRules.provider(Self.scenarioRules())
            try await ProxyFixture.run(rules: rules, bodyRuntime: Self.bodyRuntime()) { fx in
                let authority = "127.0.0.1:\(origin.port)"
                _ = try await Self.fetch(fx, target: "/p", authority: authority)
                let live = try await Self.completedFlow(fx.store)
                let before = origin.requests
                #expect(before.count == 1)
                let result = try await Self.execute(live, rules: rules, environment: Self.environment())
                Self.write(result, to: live.id, in: fx.store)
                // Execute again over the stored flow, the way a second run does.
                let stored = try #require(fx.store.flow(live.id))
                let second = try await Self.execute(stored, rules: rules, environment: Self.environment())
                Self.write(second, to: live.id, in: fx.store)
                #expect(result.overlay != nil)
                #expect(origin.requests == before)
                #expect(origin.closedConnections <= 1)
            }
        }
    }

    // MARK: the live pipeline stays as it was

    @Test func executeLeavesLiveRecordsAndHitsUntouched() async throws {
        try await withScriptedOrigin { origin in
            origin.route("/p", [.send(Self.originReply)])
            let scenario = Self.scenarioRules()
            let rules = TestRules.provider(scenario)
            try await ProxyFixture.run(rules: rules, bodyRuntime: Self.bodyRuntime()) { fx in
                _ = try await Self.fetch(fx, target: "/p", authority: "127.0.0.1:\(origin.port)")
                let live = try await Self.completedFlow(fx.store)
                let hitsBefore = scenario.map { rules.hits.count($0.id) }
                #expect(hitsBefore.allSatisfy { $0 == 1 }, "live traffic counted its hits: \(hitsBefore)")
                let connectBefore = scenario.map { rules.hits.connectCount($0.id) }
                let matchesBefore = try #require(live.provenance.ruleMatches)
                #expect(live.provenance.rulesModified)
                let digestBefore = try FlowDigest(live)

                let result = try await Self.execute(live, rules: rules, environment: Self.environment())
                Self.write(result, to: live.id, in: fx.store)

                let after = try #require(fx.store.flow(live.id))
                #expect(after.execute != nil && after.executeOverlay != nil, "Execute really wrote its record")
                #expect(after.provenance.ruleMatches == matchesBefore)
                #expect(after.provenance.rulesModified)
                #expect(after.provenance == live.provenance)
                #expect(scenario.map { rules.hits.count($0.id) } == hitsBefore)
                #expect(scenario.map { rules.hits.connectCount($0.id) } == connectBefore)
                // Everything the live pipeline recorded (both ends, every boundary, bodies, transport) is as it was;
                // only the user-visible fields Execute owns may differ.
                let digestAfter = try FlowDigest(after)
                #expect(digestAfter.withoutUserFields == digestBefore.withoutUserFields)
                #expect(digestAfter.responseHeaders == digestBefore.responseHeaders)
                #expect(digestAfter.responseBody == digestBefore.responseBody)
                #expect(digestAfter.statusCode == digestBefore.statusCode)
                // Undoing Execute restores the live record completely.
                var restored = after
                #expect(ExecuteWriter.undo(&restored))
                #expect(try FlowDigest(restored) == digestBefore)
            }
        }
    }

    @Test func liveTrafficAfterExecuteIsByteIdentical() async throws {
        try await withScriptedOrigin { origin in
            origin.route("/p", [.send(Self.originReply)])
            let rules = TestRules.provider(Self.scenarioRules())
            try await ProxyFixture.run(rules: rules, bodyRuntime: Self.bodyRuntime()) { fx in
                let authority = "127.0.0.1:\(origin.port)"
                let firstReply = try await Self.fetch(fx, target: "/p", authority: authority)
                let live = try await Self.completedFlow(fx.store)
                let result = try await Self.execute(live, rules: rules, environment: Self.environment())
                Self.write(result, to: live.id, in: fx.store)
                #expect(result.overlay != nil)

                let secondReply = try await Self.fetch(fx, target: "/p", authority: authority)
                #expect(secondReply == firstReply, "client bytes: \(firstReply) vs \(secondReply)")
                #expect(firstReply.hasPrefix("HTTP/1.1 202 "), "\(firstReply)")
                let heads = origin.requests
                #expect(heads.count == 2)
                #expect(heads.first == heads.last, "origin bytes: \(heads)")
                // The second live flow was recorded the way the first one was.
                let second = try await Self.completedFlow(fx.store, excluding: [live.id])
                #expect(second.execute == nil && second.executeOverlay == nil)
                #expect(try FlowDigest(second).withoutUserFields.responseBody == FlowDigest(live).withoutUserFields.responseBody)
                #expect(second.provenance.ruleMatches?.outcomes.map(\.code) == live.provenance.ruleMatches?.outcomes.map(\.code))
            }
        }
    }

    @Test func executeDoesNotDisableLiveRegex() async throws {
        // A pattern that backtracks without end on the captured path, with its own text so no other test shares
        // its breaker in the process-wide cache.
        let pattern = "/(x|xx)+z-parity-t13"
        let hostile = "/" + String(repeating: "x", count: 48)
        let watcher = Self.rule(
            "regex", .mark(Self.red), rows: [ConditionRow(field: .pathAndQuery, op: .regexWhole, value: pattern, caseSensitive: true)])
        try await withScriptedOrigin { origin in
            origin.route(hostile, [.send(Self.originReply)])
            origin.route("/xxz-parity-t13", [.send(Self.originReply)])
            let rules = TestRules.provider([watcher], patternCache: .shared)
            rules.setEnabled(false)
            try await ProxyFixture.run(rules: rules) { fx in
                let authority = "127.0.0.1:\(origin.port)"
                _ = try await Self.fetch(fx, target: hostile, authority: authority)
                let captured = try await Self.completedFlow(fx.store)
                #expect(captured.ruleMark == nil)

                let environment = Self.environment()
                ExecuteEngine.prepare(rules.current(), cache: environment.cache)
                var codes: [[RuleOutcomeCode]] = []
                for _ in 0..<4 {
                    let result = try await Self.execute(captured, rules: rules, environment: environment, prepare: false)
                    codes.append(result.matches?.outcomes.map(\.code) ?? [])
                }
                // Execute's private cache timed the pattern out and then switched it off ...
                #expect(codes.first == [.patternTimedOut], "\(codes)")
                #expect(codes.last == [.patternDisabled], "\(codes)")
                #expect(environment.cache.isRegexDisabled(pattern, caseInsensitive: false))
                // ... and the live cache never heard of it.
                #expect(!PatternCache.shared.isRegexDisabled(pattern, caseInsensitive: false))
                #expect(!PatternCache.shared.isRegexDisabled(pattern, mode: .find, caseInsensitive: false))

                rules.setEnabled(true)
                _ = try await Self.fetch(fx, target: "/xxz-parity-t13", authority: authority)
                let matching = try await Self.completedFlow(fx.store, excluding: [captured.id])
                #expect(matching.ruleMark?.background == "#FF3B30", "the live rule still fires")
                #expect(matching.provenance.ruleMatches?.outcomes.map(\.code) == [.applied])
            }
        }
    }
}
