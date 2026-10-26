import FlowStore
import Foundation
import Testing
@testable import ProxyCore
@testable import RulesEngine

/// Wildcard and regular-expression rule matching through the real proxy: real listener, rules session,
/// traffic policy, Map Local writer and a loopback origin that records what actually arrived.
@Suite("RuleMatchingSyntaxIntegration", .serialized, .timeLimit(.minutes(3)), .productionChinese) struct RuleMatchingSyntaxIntegrationTests {
    // MARK: Fixtures

    private struct Reply { var head: String; var body: Data
        var status: Int { Int(head.split(separator: " ").dropFirst().first ?? "") ?? 0 }
    }

    /// One request on its own connection; `target` is absolute-form, `Connection: close` ends the read.
    private static func fetch(_ proxyPort: Int, _ target: String, fields: String = "") async throws -> Reply {
        let url = try #require(URL(string: target, encodingInvalidCharacters: false))
        let authority = url.port.map { "\(url.host ?? ""):\($0)" } ?? (url.host ?? "")
        let client = try await RawClient.connect(port: proxyPort)
        do {
            try await client.send("GET \(target) HTTP/1.1\r\nHost: \(authority)\r\n\(fields)Connection: close\r\n\r\n")
            try await client.waitUntilClosed()
            let bytes = Data(client.remainingBytes())
            try await client.close()
            let separator = try #require(bytes.range(of: Data("\r\n\r\n".utf8)))
            return Reply(head: String(decoding: bytes[..<separator.lowerBound], as: UTF8.self),
                         body: Data(bytes[separator.upperBound...]))
        } catch { try? await client.close(); throw error }
    }

    private static func withOrigin(_ body: (TestOriginServer) async throws -> Void) async throws {
        let origin = try await TestOriginServer.start()
        do { try await body(origin) } catch { try? await origin.stop(); throw error }
        try await origin.stop()
    }

    private static func headerValues(_ request: OriginRequest, _ name: String) -> [String] { request.head.headers[name] }

    /// Origin-visible request paths in arrival order.
    private static func paths(_ origin: TestOriginServer) -> [String] { origin.receivedRequests.map(\.head.uri) }

    // MARK: Wildcard host

    @Test func wildcardHostRuleEditsOnlyMatchingHosts() async throws {
        try await Self.withOrigin { origin in
            let route = TestRules.mapRemote(host: "127.0.0.1", port: origin.port)
            let edit = TestRules.headers(.request, [.set(name: "X-Wild", value: "yes")],
                                         matcher: RuleMatcher(hostPattern: "*.example.test", hostSyntax: .wildcard))
            // R1 intentional change class 2: a rule below the Map Remote reads the mapped host, so the
            // edit naming the original hosts ranks above it.
            try await RulesComposeServer.run(rules: TestRules.provider([edit, route])) { fx in
                let port = try fx.port
                #expect(try await Self.fetch(port, "http://a.b.example.test/hello").status == 200)
                #expect(try await Self.fetch(port, "http://example.test/hello").status == 200)
                #expect(try await Self.fetch(port, "http://A.B.Example.Test/hello").status == 200)
                let requests = origin.receivedRequests
                try #require(requests.count == 3)
                #expect(Self.headerValues(requests[0], "X-Wild") == ["yes"])
                #expect(Self.headerValues(requests[1], "X-Wild").isEmpty)
                #expect(Self.headerValues(requests[2], "X-Wild") == ["yes"], "wildcard host matching ignores case")
            }
        }
    }

    // MARK: Regex path

    @Test func regexPathRuleMapsLocalFile() async throws {
        try await Self.withOrigin { origin in
            let provider = TestRules.provider([])
            try await RulesComposeServer.run(rules: provider) { probe in
                let asset = try await probe.importAsset(Data("from-local-file".utf8))
                let rule = Rule(id: UUID(), name: "regex local", enabled: true, order: 0,
                                matcher: RuleMatcher(path: .regex("/v[0-9]+/users/[0-9]+")),
                                action: .mapLocal(MapLocalAction(assetID: asset.id, headers: [HeaderField(name: "Content-Type", value: "text/plain")])))
                TestRules.publish([rule], revision: 2, to: provider)
                let port = try probe.port
                let base = "http://127.0.0.1:\(origin.port)"
                let hit = try await Self.fetch(port, base + "/v12/users/345")
                #expect(hit.status == 200)
                #expect(String(decoding: hit.body, as: UTF8.self) == "from-local-file")
                #expect(origin.receivedRequestCount == 0, "a matching request never reaches the origin")
                for miss in ["/v12/users/abc", "/x/v12/users/345", "/v12/users/345/extra", "/v/users/1"] {
                    let reply = try await Self.fetch(port, base + miss)
                    #expect(reply.status == 404, "\(miss) is answered by the origin")
                    #expect(String(decoding: reply.body, as: UTF8.self) == "not found")
                }
                #expect(Self.paths(origin) == ["/v12/users/abc", "/x/v12/users/345", "/v12/users/345/extra", "/v/users/1"])
                await probe.assets.discardImports([asset.id])
            }
        }
    }

    // MARK: Block / allow lists

    @Test func wildcardBlockEntryBlocksMatchingRequests() async throws {
        try await Self.withOrigin { origin in
            var policy = TrafficPolicy()
            policy.blockEnabled = true
            let entry = TrafficFilterEntry(matcher: RuleMatcher(path: .wildcard("/blocked/*.js")))
            policy.blockEntries = [entry]
            try await RulesComposeServer.run(traffic: TrafficPolicyProvider(policy)) { fx in
                let port = try fx.port
                let base = "http://127.0.0.1:\(origin.port)"
                #expect(try await Self.fetch(port, base + "/blocked/a/b.js").status == 403)
                #expect(origin.receivedRequestCount == 0)
                // The pattern covers the whole path and query, so a query suffix is not matched.
                #expect(try await Self.fetch(port, base + "/blocked/b.js?x=1").status == 404)
                #expect(try await Self.fetch(port, base + "/blocked/a/b.css").status == 404, "extension differs: forwarded")
                #expect(try await Self.fetch(port, base + "/hello").status == 200)
                #expect(Self.paths(origin) == ["/blocked/b.js?x=1", "/blocked/a/b.css", "/hello"])
                let flow = try await waitForFlow(fx.store) { $0.path == "/blocked/a/b.js" && $0.state != .inProgress }
                #expect(flow.provenance.tools.blockedByEntry == entry.id)
            }
        }
    }

    @Test func allowListRegexHostPassesThroughMatchingHostsOnly() async throws {
        // An Allow hit is recorded and rule-processed; an Allow miss is forwarded untouched, unrecorded.
        let tag = TestRules.headers(.request, [.set(name: "X-Rule", value: "applied")])
        for (allowedHost, isHit) in [(#"127\.0\.0\.[0-9]+"#, true), (#"10\.[0-9.]+|localhost"#, false)] {
            var policy = TrafficPolicy()
            policy.allowEnabled = true
            policy.allowEntries = [TrafficFilterEntry(matcher: RuleMatcher(hostPattern: allowedHost, hostSyntax: .regex))]
            try await Self.withOrigin { origin in
                try await RulesComposeServer.run(rules: TestRules.provider([tag]), traffic: TrafficPolicyProvider(policy)) { fx in
                    let reply = try await Self.fetch(try fx.port, "http://127.0.0.1:\(origin.port)/hello")
                    #expect(reply.status == 200, "an Allow list never blocks")
                    let request = try #require(origin.receivedRequests.first)
                    #expect(Self.headerValues(request, "X-Rule") == (isHit ? ["applied"] : []))
                    if isHit {
                        _ = try await waitForFlow(fx.store) { $0.path == "/hello" && $0.state == .completed }
                    } else {
                        #expect(fx.store.allFlows().isEmpty, "an Allow miss is not recorded")
                    }
                }
            }
        }
    }

    // MARK: Catastrophic regex

    @Test func catastrophicRegexRuleNeverStallsTheProxy() async throws {
        // The proxy uses the app-wide `PatternCache.shared`; a pattern text unique to this test keeps
        // its circuit breaker apart from every other test (nothing here mutates or clears the cache).
        let pattern = "/(a|aa)+cIntegrationBudget"
        let path = "/" + String(repeating: "a", count: 60) + "b"
        let input = path
        try await Self.withOrigin { origin in
            let edit = TestRules.headers(.request, [.set(name: "X-Catastrophic", value: "hit")],
                                         matcher: RuleMatcher(path: .regex(pattern)))
            try await RulesComposeServer.run(rules: TestRules.provider([edit])) { fx in
                let port = try fx.port
                func disabled() -> Bool { PatternCache.shared.isRegexDisabled(pattern, caseInsensitive: false) }
                #expect(!disabled())
                var requests = 0
                while !disabled(), requests < 4 {
                    let reply = try await Self.fetch(port, "http://127.0.0.1:\(origin.port)\(path)")
                    #expect(reply.status == 404, "forwarded to the origin even though the rule timed out")
                    requests += 1
                }
                #expect(disabled(), "the pattern is cut off within 4 requests")
                #expect(requests >= 1 && requests <= 4)
                let compiled = try PatternCache.shared.regex(pattern, caseInsensitive: false)
                // Once cut off the pattern is not run any more.
                #expect(compiled.matches(input) == .disabled)
                let before = origin.receivedRequestCount
                let fifth = try await Self.fetch(port, "http://127.0.0.1:\(origin.port)\(path)")
                #expect(fifth.status == 404)
                #expect(origin.receivedRequestCount == before + 1)
                #expect(disabled())
                #expect(compiled.matches(input) == .disabled)
                for request in origin.receivedRequests {
                    #expect(Self.headerValues(request, "X-Catastrophic").isEmpty, "a timed-out rule never matches")
                }
                // The silence is not silent: every flow says why the rule did not apply.
                try await waitUntil("all \(requests + 1) flows completed") {
                    let flows = fx.store.allFlows()
                    return flows.count == requests + 1 && flows.allSatisfy { $0.state == .completed }
                }
                let flows = fx.store.allFlows().sorted { $0.id < $1.id }
                let codes = flows.map { $0.provenance.ruleMatches?.outcomes.map(\.code) ?? [] }
                #expect(codes.first == [.patternTimedOut], "the first request timed out: \(codes)")
                #expect(codes.last == [.patternDisabled], "once cut off the flow says so: \(codes)")
                #expect(flows.allSatisfy { ($0.provenance.ruleMatches?.total ?? 0) == 0 })
                // Other traffic is unaffected.
                #expect(try await Self.fetch(port, "http://127.0.0.1:\(origin.port)/hello").status == 200)
            }
        }
    }

    // MARK: Unused advanced syntax leaves traffic untouched

    /// Everything one scripted session put on the two wires, with ports and `Date` lines normalised.
    private struct Transcript: Equatable { var client: [String]; var origin: String }

    private static func session(rules: RuleSnapshotProvider?, paths: [String]) async throws -> Transcript {
        let origin = try await TestOriginServer.start()
        var transcript = Transcript(client: [], origin: "")
        do {
            try await RulesComposeServer.run(rules: rules) { fx in
                for path in paths {
                    let reply = try await fetch(try fx.port, "http://127.0.0.1:\(origin.port)\(path)", fields: "X-Probe: 1\r\n")
                    transcript.client.append(normalised(reply.head, port: origin.port) + "\r\n\r\n" + String(decoding: reply.body, as: UTF8.self))
                }
            }
            transcript.origin = normalised(String(decoding: origin.receivedBytes, as: UTF8.self), port: origin.port)
            try await origin.stop()
        } catch { try? await origin.stop(); throw error }
        return transcript
    }

    private static func normalised(_ text: String, port: Int) -> String {
        text.replacingOccurrences(of: "\(port)", with: "PORT")
            .components(separatedBy: "\r\n").filter { !$0.lowercased().hasPrefix("date:") }.joined(separator: "\r\n")
    }

    @Test func literalRulesAreByteIdenticalWithAdvancedSyntaxUnused() async throws {
        let paths = ["/hello", "/json", "/missing?q=1"]
        let literal = Rule(id: UUID(), name: "literal", enabled: true, order: 0,
                           matcher: RuleMatcher(hostPattern: "never.test", path: .prefix("/hello")),
                           action: .editHeaders(direction: .request, operations: [.set(name: "X-Never", value: "1")]))
        let without = try await Self.session(rules: nil, paths: paths)
        let withRule = try await Self.session(rules: TestRules.provider([literal]), paths: paths)
        #expect(without.client.count == 3 && without.client[0].hasPrefix("HTTP/1.1 200"))
        #expect(without.origin.contains("X-Probe: 1\r\n"))
        #expect(withRule == without)
    }

    @Test func advancedRuleOnlyAffectsItsOwnExchanges() async throws {
        let paths = ["/hello", "/json", "/hello?edited=1"]
        let baseline = try await Self.session(rules: nil, paths: paths)
        let edit = TestRules.headers(.request, [.set(name: "X-Advanced", value: "1")],
                                     matcher: RuleMatcher(path: .wildcard("/hello?edited=*")))
        let edited = try await Self.session(rules: TestRules.provider([edit]), paths: paths)
        // Only the third request differs, and only by the one header the rule sets.
        #expect(edited.client == baseline.client)
        let baselineRequests = Array(baseline.origin.components(separatedBy: "GET ").dropFirst())
        let editedRequests = Array(edited.origin.components(separatedBy: "GET ").dropFirst())
        try #require(baselineRequests.count == 3 && editedRequests.count == 3)
        #expect(Array(editedRequests.prefix(2)) == Array(baselineRequests.prefix(2)))
        #expect(!baselineRequests[2].contains("X-Advanced"))
        #expect(editedRequests[2].contains("X-Advanced: 1\r\n"))
        #expect(editedRequests[2].replacingOccurrences(of: "X-Advanced: 1\r\n", with: "") == baselineRequests[2])
    }

    // MARK: Schema 1 golden

    /// Captured from the code before schema 2 existed (same text as RuleSchemaCompatibilityTests).
    private static let goldenRuleJSON = #"{"action":{"editHeaders":{"direction":"request","operations":[{"set":{"name":"X-Test","value":"1"}}]}},"enabled":true,"id":"00000000-0000-0000-0000-0000000000A1","matcher":{"hostPattern":"*.example.com","method":"GET","path":{"prefix":{"_0":"\/api\/"}},"port":443,"scheme":"https"},"name":"golden","order":3}"#

    @Test func rulesJSONLiteralGoldenStillMatches() async throws {
        let golden = try JSONDecoder().decode(LegacyRule.self, from: Data(Self.goldenRuleJSON.utf8))
        let rule = Rule(migrating: golden)
        #expect(golden.matcher.hostSyntax == .literal && !golden.matcher.usesAdvancedSyntax)
        let hit = HTTPMessageTarget(scheme: "https", host: "v1.example.com", port: 443, method: "GET", pathAndQuery: "/api/users")
        #expect(golden.matcher.matches(hit, status: nil))
        var other = hit; other.pathAndQuery = "/web/users"
        #expect(!golden.matcher.matches(other, status: nil))
        other = hit; other.host = "example.org"
        #expect(!golden.matcher.matches(other, status: nil))

        // The repository writes schema 4 (spec 5.1) and reads the same rule back; the old rule matches as before
        // through the 2.0 rows the migration made of it.
        #expect(rule.simple?.matcher == golden.matcher)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rule-syntax-golden-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("config"), withIntermediateDirectories: true)
        let limits = RulesLimits()
        let assets = ManagedAssetStore(directory: root.appendingPathComponent("assets"), limits: limits,
                                       budgets: OwnedFileBudgets(limits: limits))
        let repository = RuleRepository(directory: root.appendingPathComponent("config"), assets: assets, limits: limits)
        _ = try await repository.load()
        _ = try await repository.save(groups: [], rules: [rule], expectedRevision: 0)
        let stored = try String(contentsOf: root.appendingPathComponent("config/rules.json"), encoding: .utf8)
        #expect(stored.hasSuffix(#""schemaVersion":4,"templatesInstalled":false}"#), "\(stored)")
        let reopened = RuleRepository(directory: root.appendingPathComponent("config"), assets: assets, limits: limits)
        #expect(try await reopened.load().rules == [rule])
    }
}
