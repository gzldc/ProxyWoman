import FlowStore
import Foundation
import NIOCore
import NIOHTTP1
import Testing
@testable import ProxyCore
@testable import RulesEngine

private let red = MarkAction(background: "#FF0000")

private func marker(_ rows: ConditionRow..., mode: ConditionGroup.Mode = .all, name: String = "mark") -> Rule {
    Rule(name: name, conditions: ConditionGroup(mode: mode, rows: rows), actions: [RuleAction(.mark(red))])
}

private func row(_ field: ConditionField, _ name: String? = nil, _ op: ConditionOperator = .equals, _ value: String = "") -> ConditionRow {
    ConditionRow(field: field, name: name, op: op, value: value)
}

/// Conditions of R3 judged on live traffic: the fields the proxy knows at the request head, at the
/// response head, and about the connection. A rule's effect is a mark on the flow.
@Suite(.serialized, .timeLimit(.minutes(3)), .productionChinese) struct RuleConditionIntegrationTests {
    private func get(_ fx: ProxyFixture, _ path: String, fields: String = "") async throws -> DirectoryReply {
        try await directoryRaw(fx, host: "127.0.0.1:\(fx.origin.port)", path: path, fields: fields)
    }

    private func flow(_ fx: ProxyFixture, _ path: String) async throws -> Flow {
        try await waitForFlow(fx.store) { $0.path == path && $0.state == .completed }
    }

    // MARK: request head

    @Test func requestHeaderConditionMarksTheFlow() async throws {
        let rule = marker(row(.requestHeader, "X-Test", .equals, "1"))
        try await ProxyFixture.run(rules: TestRules.provider([rule])) { fx in
            _ = try await get(fx, "/hello", fields: "X-Test: 1\r\n")
            _ = try await get(fx, "/hello?plain=1")
            #expect(try await flow(fx, "/hello").ruleMark?.source == .rule(id: rule.id, name: "mark"))
            #expect(try await flow(fx, "/hello?plain=1").ruleMark == nil)
        }
    }

    @Test func cookieConditionMatches() async throws {
        let rule = marker(row(.requestCookie, "sid", .equals, "abc"))
        try await ProxyFixture.run(rules: TestRules.provider([rule])) { fx in
            _ = try await get(fx, "/hello", fields: "Cookie: other=1; sid=abc\r\n")
            _ = try await get(fx, "/hello?other=1", fields: "Cookie: sid=zzz\r\n")
            #expect(try await flow(fx, "/hello").ruleMark != nil)
            #expect(try await flow(fx, "/hello?other=1").ruleMark == nil)
        }
    }

    @Test func queryParamConditionMatches() async throws {
        let rule = marker(row(.queryParam, "mode", .equals, "fast"))
        try await ProxyFixture.run(rules: TestRules.provider([rule])) { fx in
            _ = try await get(fx, "/hello?mode=fast&x=1")
            _ = try await get(fx, "/hello?mode=slow")
            #expect(try await flow(fx, "/hello?mode=fast&x=1").ruleMark != nil)
            #expect(try await flow(fx, "/hello?mode=slow").ruleMark == nil)
        }
    }

    // MARK: response head

    @Test func responseHeaderConditionJudgedAtResponse() async throws {
        let rule = marker(row(.responseHeader, "Content-Type", .contains, "json"))
        try await ProxyFixture.run(rules: TestRules.provider([rule])) { fx in
            _ = try await get(fx, "/json")
            _ = try await get(fx, "/hello")
            #expect(try await flow(fx, "/json").ruleMark != nil)
            #expect(try await flow(fx, "/hello").ruleMark == nil)
        }
    }

    @Test func responseHeaderRuleCannotChangeTheRequest() async throws {
        // Validation refuses to save such a rule; a snapshot that carries one anyway must not run the
        // request-side action, because the rule is only judged once the response exists.
        let invalid = Rule(
            name: "invalid", conditions: ConditionGroup(rows: [row(.responseHeader, "Content-Type", .contains, "json")]),
            actions: [RuleAction(.editHeaders(direction: .request, operations: [.set(name: "X-Added", value: "1")]))])
        try await ProxyFixture.run(rules: TestRules.provider([invalid])) { fx in
            _ = try await get(fx, "/json")
            _ = try await flow(fx, "/json")
            let seen = try #require(fx.origin.receivedRequests.last)
            #expect(seen.head.headers["X-Added"].isEmpty)
        }
    }

    @Test func responseHeaderConditionOnLocalResponse() async throws {
        try await withLocalAsset(Data("local".utf8)) { asset in
            let reader = marker(row(.responseHeader, "X-Generated", .equals, "yes"))
            let local = Rule(name: "local", conditions: ConditionGroup(), actions: [RuleAction(.returnFile(MapLocalAction(
                assetID: asset.asset.id, headers: [HeaderField(name: "X-Generated", value: "yes")])))])
            try await ProxyFixture.run(rules: TestRules.provider([reader, local]), assets: asset.store) { fx in
                _ = try await get(fx, "/local")
                #expect(fx.origin.acceptedConnections == 0)
                #expect(try await flow(fx, "/local").ruleMark?.source == .rule(id: reader.id, name: "mark"))
            }
        }
    }

    // MARK: connection facts

    @Test func clientIPConditionMatchesLoopback() async throws {
        let hit = marker(row(.clientIP, nil, .equals, "127.0.0.1"), name: "hit")
        let miss = marker(row(.clientIP, nil, .equals, "10.1.2.3"), name: "miss")
        try await ProxyFixture.run(rules: TestRules.provider([miss, hit])) { fx in
            _ = try await get(fx, "/hello")
            #expect(try await flow(fx, "/hello").ruleMark?.source == .rule(id: hit.id, name: "hit"))
        }
    }

    @Test func remoteIPConditionMatchesTheOrigin() async throws {
        let rule = marker(row(.remoteIP, nil, .equals, "127.0.0.1"))
        try await ProxyFixture.run(rules: TestRules.provider([rule])) { fx in
            _ = try await get(fx, "/hello")
            #expect(try await flow(fx, "/hello").ruleMark != nil)
        }
    }

    @Test(arguments: ["upstream", "client", "certificate"])
    func tlsVersionAndCertificateConditionsOnHTTPS(which: String) async throws {
        let rule: Rule
        switch which {
        case "upstream": rule = marker(row(.upstreamTLSVersion, nil, .contains, "1."))
        case "client": rule = marker(row(.clientTLSVersion, nil, .startsWith, "TLS 1."))
        default:
            rule = marker(row(.certificate, "subject", .contains, "localhost"), row(.certificate, "issuer", .contains, "Test CA B"))
        }
        let miss = marker(row(.certificate, "subject", .contains, "no-such-host"), name: "miss")
        let setup = try HTTPSSetup()
        try await setup.run(rules: TestRules.provider([miss, rule])) { fx in
            let r = try curl(["-x", fx.proxyURL, "--cacert", setup.proxyCAFile, "https://localhost:\(fx.origin.port)/json"])
            #expect(r.exitCode == 0, "\(r.stderr)")
            let flow = try await waitForFlow(fx.store) { $0.state == .completed }
            #expect(flow.ruleMark?.source == .rule(id: rule.id, name: "mark"), "\(which)")
        }
    }

    // MARK: client app

    @Test func clientAppConditionWaitsForTheLookup() async throws {
        try await withConnectionFixture { fixture in
            let promise = fixture.loop.makePromise(of: ClientApp?.self)
            let rule = marker(row(.clientApp, "name", .equals, "Fixture"))
            let writer = RecordingResponseWriter(channel: fixture.client)
            let exchange = fixture.admit("/app", writer: writer,
                                         context: fixture.context(lookup: promise.futureResult, rules: TestRules.provider([rule])))
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            fixture.loop.run()
            #expect(fixture.connections.isEmpty, "the request is not forwarded before the lookup answered")
            promise.succeed(ClientApp(pid: 42, name: "Fixture", executablePath: "/Applications/Fixture.app"))
            fixture.loop.run()
            #expect(fixture.connections.count == 1)
            let marked = try fixture.flow("/app")
            #expect(marked.ruleMark?.source == .rule(id: rule.id, name: "mark"))
        }
    }

    @Test func clientAppConditionIsUnknownAfterTheGrace() async throws {
        try await withConnectionFixture { fixture in
            let promise = fixture.loop.makePromise(of: ClientApp?.self)
            let rule = marker(row(.clientApp, "name", .equals, "Fixture"))
            let writer = RecordingResponseWriter(channel: fixture.client)
            let exchange = fixture.admit("/app", writer: writer,
                                         context: fixture.context(lookup: promise.futureResult, rules: TestRules.provider([rule])))
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            #expect(fixture.connections.isEmpty)
            fixture.loop.advanceTime(by: ProxyHandler.clientLookupGrace)
            fixture.loop.run()
            #expect(fixture.connections.count == 1, "forwarding resumes when the grace is over")
            let flow = try fixture.flow("/app")
            #expect(flow.ruleMark == nil)
            #expect(flow.provenance.ruleMatches?.outcomes.contains(RuleOutcome(ruleID: rule.id, code: .appUnknown)) == true)
            promise.succeed(nil)
            fixture.loop.run()
        }
    }

    @Test func noRequirementsNoWait() async throws {
        try await withConnectionFixture { fixture in
            let promise = fixture.loop.makePromise(of: ClientApp?.self)
            let rule = marker(row(.requestHeader, "X-Test", .equals, "1"))
            let writer = RecordingResponseWriter(channel: fixture.client)
            let exchange = fixture.admit("/now", headers: HTTPHeaders([("X-Test", "1")]), writer: writer,
                                         context: fixture.context(lookup: promise.futureResult, rules: TestRules.provider([rule])))
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            // Judged in this very call, while the lookup is still pending and forwarding not yet allowed.
            let marked = try fixture.flow("/now")
            #expect(marked.ruleMark != nil)
            promise.succeed(nil)
            fixture.loop.run()
        }
    }

    @Test func composeSendNeverMatchesAppOrIPRows() async throws {
        let rules = [
            marker(row(.clientApp, "name", .equals, "Fixture"), name: "app"),
            marker(row(.clientIP, nil, .equals, "127.0.0.1"), name: "ip"),
            marker(row(.clientApp, "name", .notEquals, "Fixture"), name: "other app"),
            marker(row(.clientIP, nil, .notEquals, "127.0.0.1"), name: "other ip"),
        ]
        try await ComposeFixture.run(rules: TestRules.provider(rules, revision: 5)) { fx in
            let result = await fx.compose.send(ComposeRequest(method: "GET", url: fx.url("/hello"), policy: ComposePolicy(applyRules: true)))
            #expect(result.response?.status == 200)
            let flowID = try #require(result.flowID)
            let flow = try await waitForFlow(fx.store) { $0.id == flowID && $0.state == .completed }
            #expect(flow.ruleMark == nil)
            #expect(flow.provenance.ruleMatches?.ruleIDs.isEmpty != false)
        }
    }

    // MARK: what earlier rules did

    @Test func rulesModifiedConditionSeesHeaderEdit() async throws {
        try await withConnectionFixture { fixture in
            let edit = TestRules.headers(.request, [.set(name: "X-A", value: "1")])
            let before = marker(row(.rulesModified, nil, .equals, "true"), name: "before")
            let after = marker(row(.rulesModified, nil, .equals, "true"), name: "after")
            let writer = RecordingResponseWriter(channel: fixture.client)
            // `before` sits above the edit and reads an unmodified exchange; `after` sits below it.
            let exchange = fixture.admit("/modified", writer: writer,
                                         context: fixture.context(rules: TestRules.provider([before, edit, after])))
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            let marked = try fixture.flow("/modified")
            #expect(marked.ruleMark?.source == .rule(id: after.id, name: "after"))
        }
    }

    @Test func commentConditionSeesAnEarlierRulesComment() async throws {
        try await withConnectionFixture { fixture in
            let comment = Rule(name: "comment", conditions: ConditionGroup(),
                               actions: [RuleAction(.comment(CommentAction(mode: .set, text: "needs-review")))])
            let reader = marker(row(.comment, nil, .contains, "review"))
            let writer = RecordingResponseWriter(channel: fixture.client)
            let exchange = fixture.admit("/comment", writer: writer,
                                         context: fixture.context(rules: TestRules.provider([comment, reader])))
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            let flow = try fixture.flow("/comment")
            #expect(flow.comment == "needs-review")
            #expect(flow.ruleMark?.source == .rule(id: reader.id, name: "mark"))
        }
    }
}
