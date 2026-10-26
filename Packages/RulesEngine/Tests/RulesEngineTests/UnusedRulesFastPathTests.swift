import FlowStore
import Foundation
import Testing

@testable import RulesEngine

/// A rule set that does nothing to an exchange leaves it exactly as it arrived: no edit, no route, no
/// breakpoint, no record, no hit counted. This is the evaluator half of "unused features: traffic
/// byte-identical to the last version" (spec 8); `RulesUnusedByteIdenticalTests` pins the wire half.
@Suite("UnusedRulesFastPath")
struct UnusedRulesFastPathTests {
    // MARK: fixtures

    private static let probe = RuleAction(
        .editHeaders(direction: .request, operations: [.set(name: "X-Probe", value: "1")]))

    private static func rule(
        _ name: String, when rows: [ConditionRow] = [], mode: ConditionGroup.Mode = .all,
        occurrence: Occurrence = .any, enabled: Bool = true, groupID: UUID? = nil, _ actions: [RuleAction]
    ) -> Rule {
        Rule(
            name: name, enabled: enabled, groupID: groupID,
            conditions: ConditionGroup(mode: mode, occurrence: occurrence, rows: rows), actions: actions)
    }

    private static let dupHeaders = [
        HeaderField(name: "X-Dup", value: "1"), HeaderField(name: "Accept", value: "*/*"),
        HeaderField(name: "X-Dup", value: "2"),
    ]

    /// A few requests of different shapes: plain, with a text body, and one asking to switch protocols.
    private static let requests: [(name: String, head: HTTPMessageHead)] = [
        ("get", OracleScenarios.get(headers: dupHeaders)),
        ("post", OracleScenarios.get(method: "POST", path: "/echo", headers: OracleScenarios.text())),
        ("upgrade", OracleScenarios.get(path: "/ws", headers: OracleScenarios.upgradeHeaders)),
    ]

    /// One rule per action kind (twelve in all, both directions where the kind has them), each with a
    /// condition group that does not match `a.test`'s `GET /v1/items?a=1` answered with 200 - in the
    /// ways a group can fail to match: one row off, an `any` group with every row off, a `none` group
    /// with a row that matches, a status range the response is not in, and a group inside a switched-off
    /// subtree.
    private static func nonMatchingRules() -> (rules: [Rule], groups: [RuleGroup]) {
        let hostIs = ConditionRow(field: .host, op: .hostPattern, value: "a.test")
        let portIs = ConditionRow(field: .port, op: .equals, value: "443")
        let otherHost = ConditionRow(field: .host, op: .hostPattern, value: "never.example")
        let otherPath = ConditionRow(field: .pathAndQuery, op: .startsWith, value: "/never", caseSensitive: true)
        let otherMethod = ConditionRow(field: .method, op: .equals, value: "DELETE", caseSensitive: true)
        let otherStatus = ConditionRow(field: .statusCode, op: .inRange, value: "599-599")
        let offGroup = RuleGroup(name: "off", enabled: false, order: 99)

        let rules: [Rule] = [
            rule("file", when: [otherHost], [RuleAction(.returnFile(OracleScenarios.localFile))]),
            rule(
                "directory", when: [otherPath],
                [RuleAction(.returnDirectory(OracleScenarios.directory, pathPrefix: "/never/"))]),
            rule("remote", when: [otherMethod], [RuleAction(.mapRemote(OracleScenarios.remote("b.test")))]),
            rule("request edit", when: [hostIs, otherPath], [Self.probe]),
            rule(
                "request breakpoint", when: [otherHost, otherPath], mode: .any,
                [RuleAction(.breakpoint(direction: .request, mode: .headers))]),
            rule(
                "request body", when: [hostIs, portIs], mode: .none,
                [RuleAction(.rewriteBody(direction: .request, OracleScenarios.body()))]),
            rule(
                "response edit", when: [hostIs, otherStatus],
                [RuleAction(.editHeaders(direction: .response, operations: [.set(name: "X-R", value: "1")]))]),
            rule(
                "response breakpoint", when: [otherHost],
                [RuleAction(.breakpoint(direction: .response, mode: .fullBody))]),
            rule(
                "response body", when: [hostIs, otherStatus],
                [RuleAction(.rewriteBody(direction: .response, OracleScenarios.body()))]),
            rule(
                "status", when: [hostIs, otherStatus],
                [RuleAction(.rewriteStatus(RewriteStatusAction(status: 500)))]),
            // Several actions, and an occurrence range that only counts a group that matched.
            rule(
                "several", when: [otherPath], occurrence: .times(1...1),
                [
                    Self.probe,
                    RuleAction(.editHeaders(direction: .response, operations: [.remove(name: "Server")])),
                    RuleAction(.rewriteStatus(RewriteStatusAction(status: 404))),
                ]),
            rule("in a switched-off group", groupID: offGroup.id, [RuleAction(.mapRemote(OracleScenarios.remote("c.test")))]),
        ]
        return (rules, [offGroup])
    }

    /// The response a request gets in these tests.
    private static let ok = OracleScenarios.response(200, reason: "OK", headers: OracleScenarios.text())

    // MARK: tests

    @Test func emptySnapshotDecisionEqualsForwardUnchanged() throws {
        let snapshot = RuleSnapshot(revision: 7, rules: [])
        for (name, head) in Self.requests {
            let hits = RuleHitCounter()
            let decision = try RuleEvaluator.request(
                head, snapshot: snapshot, hits: hits, cache: OracleScenarios.calmCache())
            guard case .request(let target, let headers) = head else {
                Issue.record("\(name): not a request head")
                continue
            }
            #expect(decision.effectiveHead == head, "\(name)")
            #expect(decision.route == .original, "\(name)")
            #expect(decision.breakpoint == nil, "\(name)")
            #expect(decision.bodyRewrites.isEmpty, "\(name)")
            #expect(!decision.rulesModified, "\(name)")
            #expect(decision.matches == RuleMatchSummary(revision: 7, ruleIDs: [], total: 0), "\(name)")
            #expect(!decision.matches.hasRecords, "\(name)")
            #expect(decision.carry == RuleCarry(target: target, requestHeaders: headers), "\(name)")

            let answer = name == "upgrade" ? OracleScenarios.response(101, reason: "Switching Protocols",
                headers: OracleScenarios.switchingHeaders) : Self.ok
            let response = try RuleEvaluator.response(
                answer, after: decision, snapshot: snapshot, requestWasUpgradeCandidate: name == "upgrade",
                hits: hits, cache: OracleScenarios.calmCache())
            #expect(response.effectiveHead == answer, "\(name)")
            #expect(response.breakpoint == nil, "\(name)")
            #expect(response.bodyRewrites.isEmpty, "\(name)")
            #expect(response.statusRewrite == nil, "\(name)")
            #expect(!response.rulesModified, "\(name)")
            #expect(!response.matches.hasRecords, "\(name)")
            #expect(hits.snapshot().isEmpty, "\(name)")
        }

        // The old evaluator says the same about no rules at all.
        let scenario = OracleScenario("emptyRequest", request: OracleScenarios.get(headers: Self.dupHeaders), [])
        #expect(OracleRequestResult { try scenario.migratedRequest() } == OracleRequestResult { try scenario.legacyRequest() })
        let responseScenario = OracleResponseScenario("emptyResponse", response: Self.ok, [])
        #expect(
            OracleResponseResult { try responseScenario.migratedResponse() }
                == OracleResponseResult { try responseScenario.legacyResponse() })

        // Rules that are all switched off are as good as none: a disabled rule, and a rule whose group is off.
        let group = RuleGroup(name: "g", enabled: false)
        let switchedOff = RuleSnapshot(
            revision: 8, groups: [group],
            rules: [
                Self.rule("disabled", enabled: false, [Self.probe]),
                Self.rule("disabled group", groupID: group.id, [Self.probe]),
            ])
        #expect(switchedOff.evaluationOrder.isEmpty)
        let head = OracleScenarios.get(headers: Self.dupHeaders)
        let decision = try RuleEvaluator.request(head, snapshot: switchedOff, cache: OracleScenarios.calmCache())
        #expect(decision.effectiveHead == head)
        #expect(decision.route == .original)
        #expect(!decision.matches.hasRecords)
        #expect(!decision.rulesModified)
    }

    @Test func nonMatchingRulesRecordNothingAndDoNotCountHits() throws {
        let (rules, groups) = Self.nonMatchingRules()
        let snapshot = RuleSnapshot(revision: 21, groups: groups, rules: rules)
        // Every kind of action is there, so a rule that wrongly matched would show.
        let kinds = Set(rules.flatMap(\.actions).map { String(describing: $0.kind).prefix { $0 != "(" } })
        #expect(kinds == ["returnFile", "returnDirectory", "mapRemote", "editHeaders", "breakpoint", "rewriteBody", "rewriteStatus"])
        #expect(snapshot.evaluationOrder.count == rules.count - 1)  // all but the one in the switched-off group

        for (name, head) in Self.requests {
            let hits = RuleHitCounter()
            let cache = OracleScenarios.calmCache()
            let decision = try RuleEvaluator.request(head, snapshot: snapshot, hits: hits, cache: cache)
            #expect(decision.effectiveHead == head, "\(name)")
            #expect(decision.route == .original, "\(name)")
            #expect(decision.breakpoint == nil, "\(name)")
            #expect(decision.bodyRewrites.isEmpty, "\(name)")
            #expect(!decision.rulesModified, "\(name)")
            #expect(!decision.matches.hasRecords, "\(name)")
            #expect(decision.matches.ruleIDs.isEmpty && decision.matches.outcomes.isEmpty, "\(name)")
            #expect(decision.carry?.pending.isEmpty == true, "\(name)")
            #expect(decision.carry?.finalStop == nil, "\(name)")
            #expect(decision.carry?.remote == nil, "\(name)")

            let response = try RuleEvaluator.response(
                Self.ok, after: decision, snapshot: snapshot, requestWasUpgradeCandidate: name == "upgrade",
                hits: hits, cache: cache)
            #expect(response.effectiveHead == Self.ok, "\(name)")
            #expect(response.breakpoint == nil, "\(name)")
            #expect(response.bodyRewrites.isEmpty, "\(name)")
            #expect(response.statusRewrite == nil, "\(name)")
            #expect(!response.rulesModified, "\(name)")
            #expect(!response.matches.hasRecords, "\(name)")
            // No rule matched, so none was counted - the occurrence range of "several" never advanced.
            #expect(hits.snapshot().isEmpty, "\(name)")
        }

        // The same set plus one rule that does match: the counter works and the record appears.
        let matching = Self.rule("matching", [Self.probe])
        let withMatch = RuleSnapshot(revision: 22, groups: groups, rules: rules + [matching])
        let hits = RuleHitCounter()
        let decision = try RuleEvaluator.request(
            Self.requests[0].head, snapshot: withMatch, hits: hits, cache: OracleScenarios.calmCache())
        #expect(decision.matches.ruleIDs == [matching.id])
        #expect(decision.rulesModified)
        #expect(hits.snapshot() == [matching.id: 1])
    }

    @Test func disabledGlobalSwitchGivesNoActiveSnapshot() {
        let matching = Self.rule("matching", [Self.probe])
        let snapshot = RuleSnapshot(revision: 3, rules: [matching])
        let provider = RuleSnapshotProvider(snapshot)
        #expect(provider.isEnabled)
        #expect(provider.active() == snapshot)
        #expect(provider.active() != nil)

        provider.setEnabled(false)
        #expect(!provider.isEnabled)
        // An exchange admitted now finds no snapshot and so runs no rule at all.
        #expect(provider.active() == nil)
        // The rules themselves are untouched: the editor and the next switch-on still see them.
        #expect(provider.current() == snapshot)
        #expect(provider.current().rules.map(\.id) == [matching.id])

        // A publish while the switch is off is kept and stays inactive.
        let later = RuleSnapshot(revision: 4, rules: [matching, Self.rule("second", [Self.probe])])
        provider.publish(later)
        #expect(provider.active() == nil)
        #expect(provider.current() == later)

        provider.setEnabled(true)
        #expect(provider.active() == later)

        // A provider nobody published to has an empty snapshot: nothing to run either way.
        let fresh = RuleSnapshotProvider()
        #expect(fresh.active()?.rules.isEmpty == true)
        #expect(fresh.active()?.evaluationOrder.isEmpty == true)
    }

    // MARK: the old evaluator as the oracle for rules the intended changes do not touch

    /// Eight rules, none of them in a class of spec 5.6.3: header edits and breakpoints of both
    /// directions, a body rewrite, a status range, a wildcard host and a path pattern, one status
    /// rewrite that nothing below it reads, and no Map Local or Map Remote at all.
    private static let unrelatedRules: [LegacyRule] = [
        OracleScenarios.rule(order: 0, OracleScenarios.edit(.request, .set(name: "X-Probe", value: "1"))),
        OracleScenarios.rule(
            order: 1, RuleMatcher(hostPattern: "*.example.com", hostSyntax: .wildcard),
            OracleScenarios.edit(.request, .append(name: "X-Wild", value: "1"), .remove(name: "Accept"))),
        OracleScenarios.rule(
            order: 2, RuleMatcher(method: "POST", path: .prefix("/v1/")),
            .breakpoint(direction: .request, mode: .headers)),
        OracleScenarios.rule(
            order: 3, RuleMatcher(path: .wildcard("/v1/*")),
            OracleScenarios.edit(.response, .append(name: "X-Resp", value: "1"))),
        OracleScenarios.rule(
            order: 4, RuleMatcher(statusRange: 500...599),
            OracleScenarios.edit(.response, .remove(name: "Server"), .set(name: "X-Error", value: "1"))),
        OracleScenarios.rule(
            order: 5, RuleMatcher(path: .prefix("/static/")), .breakpoint(direction: .response, mode: .headers)),
        OracleScenarios.rule(
            order: 6, RuleMatcher(path: .prefix("/v1/")), .rewriteBody(direction: .response, OracleScenarios.body("a", "b"))),
        OracleScenarios.rule(order: 7, OracleScenarios.status(418)),
    ]

    @Test func unrelatedHeaderRuleSetOutsideTheThreeClassesMatchesTheOracle() throws {
        let rules = Self.unrelatedRules
        #expect(rules.count == 8)
        // Outside the three classes is the analyzer's own verdict, not only this test's say-so.
        #expect(MigrationAnalyzer.report(for: rules).isEmpty)

        let requestHeads: [(name: String, head: HTTPMessageHead)] = [
            ("plain", OracleScenarios.get(headers: Self.dupHeaders)),
            ("postText", OracleScenarios.get(host: "x.example.com", method: "POST", path: "/v1/items", headers: OracleScenarios.text())),
            ("otherHost", OracleScenarios.get(host: "elsewhere.test", path: "/static/app.js")),
            ("put", OracleScenarios.get(method: "PUT", path: "/v1/items/7", headers: [HeaderField(name: "Authorization", value: "Bearer t")])),
            ("upgrade", OracleScenarios.get(path: "/ws", headers: OracleScenarios.upgradeHeaders)),
        ]
        let responses: [(name: String, head: HTTPMessageHead)] = [
            ("ok", OracleScenarios.response(200, reason: "OK", headers: OracleScenarios.text())),
            ("unavailable", OracleScenarios.response(503, reason: "Service Unavailable", headers: [HeaderField(name: "Server", value: "s")])),
            ("notFoundImage", OracleScenarios.response(404, reason: "Not Found", headers: OracleScenarios.text(type: "image/png"))),
        ]

        var compared = 0
        var applied = 0
        var codes: Set<String> = []
        var steps = 0
        var breakpoints = 0
        var statusRewrites = 0
        for request in requestHeads {
            for response in responses {
                let name = "\(request.name)/\(response.name)"
                let scenario = OracleResponseScenario(name, request: request.head, response: response.head, rules)
                let legacyRequest = OracleRequestResult { try scenario.requestPoint.legacyRequest() }
                let migratedRequest = OracleRequestResult { try scenario.requestPoint.migratedRequest() }
                #expect(legacyRequest == migratedRequest, "request point \(name)")
                let legacy = OracleResponseResult { try scenario.legacyResponse() }
                let next = OracleResponseResult { try scenario.migratedResponse() }
                #expect(legacy == next, "response point \(name)")
                if case .unexpected(let error) = next { Issue.record("\(name): \(error)") }
                compared += 1

                for outcome in (migratedRequest.matches?.outcomes ?? []) + (next.matches?.outcomes ?? []) {
                    codes.insert(outcome.code.rawValue)
                    if outcome.code == .applied { applied += 1 }
                }
                if case .decided(_, _, _, let bodyRewrites, _) = migratedRequest { steps += bodyRewrites.count }
                if case .decided(_, _, let breakpoint, _, _) = migratedRequest, breakpoint != nil { breakpoints += 1 }
                if case .decided(_, let breakpoint, let bodyRewrites, let status, _) = next {
                    steps += bodyRewrites.count
                    if breakpoint != nil { breakpoints += 1 }
                    if status != nil { statusRewrites += 1 }
                }
            }
        }
        // Not vacuous: rules applied, in both directions, with breakpoints, body steps and a status rewrite.
        #expect(compared == requestHeads.count * responses.count)
        #expect(applied >= 30)
        #expect(codes.contains("applied"))
        #expect(steps > 0)
        #expect(breakpoints > 0)
        #expect(statusRewrites > 0)
    }
}
