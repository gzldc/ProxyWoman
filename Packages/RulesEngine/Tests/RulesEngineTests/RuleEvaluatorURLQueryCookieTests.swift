import FlowStore
import Foundation
import Testing

@testable import RulesEngine

private func target(host: String = "a.test", path: String = "/v1/items?a=1") -> HTTPMessageTarget {
    HTTPMessageTarget(scheme: "https", host: host, port: 443, method: "GET", pathAndQuery: path)
}

private func request(_ target: HTTPMessageTarget = target(), headers: [HeaderField] = []) -> HTTPMessageHead {
    .request(target, headers: headers)
}

private let upgradeHeaders = [
    HeaderField(name: "Connection", value: "Upgrade"), HeaderField(name: "Upgrade", value: "websocket"),
    HeaderField(name: "Sec-WebSocket-Key", value: "k"),
]

private func urlSet(_ url: String, preserve: Bool = false) -> RuleAction {
    RuleAction(.modifyURL(URLEditAction(mode: .set, replacement: url, preserveCredentials: preserve)))
}

private func urlFind(_ find: String, _ replacement: String) -> RuleAction {
    RuleAction(.modifyURL(URLEditAction(mode: .findReplace, find: find, replacement: replacement)))
}

private func urlRegex(_ find: String, _ replacement: String) -> RuleAction {
    RuleAction(.modifyURL(URLEditAction(mode: .regex, find: find, replacement: replacement, caseSensitive: true)))
}

private func query(_ operations: QueryEdit...) -> RuleAction {
    RuleAction(.modifyQuery(QueryEditAction(operations: operations)))
}

private func cookies(_ direction: HTTPMessageDirection, _ operations: CookieEdit...) -> RuleAction {
    RuleAction(.editCookies(direction: direction, operations: operations))
}

private func delay(_ milliseconds: Int) -> RuleAction { RuleAction(.delay(milliseconds: milliseconds)) }

private func setHeader(_ name: String, _ value: String, final: Bool = false) -> RuleAction {
    RuleAction(.editHeaders(direction: .request, operations: [.set(name: name, value: value)]), isFinal: final)
}

private func remote(_ host: String, path: RemotePathPolicy = .preserve) -> RuleAction {
    RuleAction(
        .mapRemote(MapRemoteAction(targetScheme: "https", targetHost: host, targetPort: 443, path: path)))
}

private func hostIs(_ value: String) -> ConditionRow {
    ConditionRow(field: .host, op: .hostPattern, value: value)
}

private func rule(id: UUID = UUID(), when rows: [ConditionRow] = [], _ actions: RuleAction...) -> Rule {
    Rule(
        id: id, name: "r", enabled: true, groupID: nil, order: 0,
        conditions: ConditionGroup(mode: .all, occurrence: .any, rows: rows), actions: actions)
}

private func snapshot(_ rules: Rule...) -> RuleSnapshot { RuleSnapshot(revision: 7, groups: [], rules: rules) }

private func evaluate(
    _ snapshot: RuleSnapshot, limits: RulesLimits = RulesLimits(), allowance: RegexAllowance = RegexAllowance(),
    cache: PatternCache = PatternCache(budget: RegexBudget(clock: { .zero }))
) throws -> RequestRuleDecision {
    try evaluate(request(), snapshot, limits: limits, allowance: allowance, cache: cache)
}

private func evaluate(
    _ head: HTTPMessageHead, _ snapshot: RuleSnapshot, limits: RulesLimits = RulesLimits(),
    allowance: RegexAllowance = RegexAllowance(),
    cache: PatternCache = PatternCache(budget: RegexBudget(clock: { .zero }))
) throws -> RequestRuleDecision {
    try RuleEvaluator.request(head, snapshot: snapshot, allowance: allowance, limits: limits, cache: cache)
}

private func outcome(_ id: UUID, _ code: RuleOutcomeCode, _ index: Int? = nil) -> RuleOutcome {
    RuleOutcome(ruleID: id, code: code, actionIndex: index)
}

private func remoteAction(
    _ host: String = "a.test", path: String, preserve: Bool = false
) -> MapRemoteAction {
    MapRemoteAction(
        targetScheme: "https", targetHost: host, targetPort: 443, path: .replace(path),
        preserveCredentials: preserve)
}

@Suite("RuleEvaluatorURLQueryCookie")
struct RuleEvaluatorURLQueryCookieTests {
    // MARK: modify URL

    @Test func urlSetRoutesThroughMapRemoteRoute() throws {
        let r = rule(urlSet("https://a.test/new?x=1"))
        let decision = try evaluate(snapshot(r))
        #expect(decision.route == .remote(remoteAction(path: "/new?x=1")))
        #expect(decision.carry?.target == target(path: "/new?x=1"))
        #expect(decision.carry?.remote == remoteAction(path: "/new?x=1"))
        #expect(decision.effectiveHead == request())
        #expect(decision.matches.outcomes == [outcome(r.id, .applied)])
        #expect(decision.rulesModified)
    }

    @Test func laterRuleReadsEarlierURLEdit() throws {
        let edit = rule(urlFind("a.test", "b.com"))
        let old = rule(when: [hostIs("a.test")], setHeader("X-Old", "1"))
        let new = rule(when: [hostIs("b.com")], setHeader("X-New", "1"))
        let decision = try evaluate(snapshot(edit, old, new))
        #expect(decision.effectiveHead.headers.values(for: "X-Old").isEmpty)
        #expect(decision.effectiveHead.headers.values(for: "X-New") == ["1"])
        #expect(decision.carry?.target.host == "b.com")
        #expect(decision.route == .remote(remoteAction("b.com", path: "/v1/items?a=1")))
    }

    @Test func urlEditThenMapRemoteComposes() throws {
        // Same origin as the edit: the credential flag the edit asked for survives, the edit's path stays.
        let sameOrigin = try evaluate(
            snapshot(rule(urlSet("https://b.com/p", preserve: true)), rule(remote("b.com"))))
        #expect(sameOrigin.route == .remote(remoteAction("b.com", path: "/p", preserve: true)))
        #expect(sameOrigin.carry?.target == target(host: "b.com", path: "/p"))
        // Another origin than the edit's: credentials are dropped.
        let moved = try evaluate(
            snapshot(rule(urlSet("https://b.com/p", preserve: true)), rule(remote("c.com"))))
        #expect(moved.route == .remote(remoteAction("c.com", path: "/p", preserve: false)))
        // A later path replacement wins.
        let later = try evaluate(
            snapshot(rule(urlSet("https://b.com/p")), rule(remote("b.com", path: .replace("/q")))))
        #expect(later.route == .remote(remoteAction("b.com", path: "/q")))
    }

    @Test func urlEditToOtherOriginDropsCredentials() throws {
        let decision = try evaluate(snapshot(rule(urlSet("https://b.com/p"))))
        #expect(decision.route == .remote(remoteAction("b.com", path: "/p", preserve: false)))
        let kept = try evaluate(snapshot(rule(urlSet("https://b.com/p", preserve: true))))
        #expect(kept.route == .remote(remoteAction("b.com", path: "/p", preserve: true)))
    }

    @Test func urlEditSameOriginKeepsCredentials() throws {
        let decision = try evaluate(snapshot(rule(urlSet("https://a.test/p", preserve: true))))
        #expect(decision.route == .remote(remoteAction(path: "/p", preserve: true)))
        #expect(decision.carry?.target == target(path: "/p"))
    }

    @Test func urlEditOnUpgradeIsUnsupported() throws {
        let r = rule(urlSet("https://b.com/p"))
        let decision = try evaluate(request(headers: upgradeHeaders), snapshot(r))
        #expect(decision.matches.outcomes == [outcome(r.id, .unsupportedUpgradeAction)])
        #expect(decision.route == .original)
        #expect(decision.carry?.target == target())
        #expect(!decision.rulesModified)
    }

    @Test func urlEditInvalidResultRejects() {
        let first = rule(setHeader("X-A", "1"))
        let bad = rule(urlSet("ftp://b.com/p"))
        do {
            _ = try evaluate(snapshot(first, bad))
            Issue.record("expected a rule evaluation failure")
        } catch let error as RuleEvaluationError {
            #expect(error.mutation == HTTPMutationError(code: .invalidPath, field: .path))
            #expect(error.matches.ruleIDs == [first.id, bad.id])
            #expect(error.matches.outcomes == [outcome(first.id, .applied), outcome(bad.id, .rejected)])
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func urlRegexTimeoutLeavesTargetAndRecordsProblem() throws {
        let path = "/" + String(repeating: "a", count: 60) + "b"
        let r = rule(urlRegex("/(a|aa)+c", "/x"))
        let decision = try evaluate(request(target(path: path)), snapshot(r), cache: PatternCache(budget: StepClock().budget))
        #expect(decision.matches.outcomes == [outcome(r.id, .patternTimedOut)])
        #expect(decision.route == .original)
        #expect(decision.carry?.target == target(path: path))
        #expect(!decision.rulesModified)
    }

    @Test func urlRegexOnOversizedInputRecordsNothing() throws {
        let path = "/" + String(repeating: "a", count: 9_000)
        let r = rule(urlRegex("a+", "b"))
        let decision = try evaluate(request(target(path: path)), snapshot(r))
        #expect(decision.matches.outcomes.isEmpty)
        #expect(decision.route == .original)
        #expect(!decision.rulesModified)
    }

    // MARK: modify query

    @Test func queryEditKeepsOriginAndReplacesPathAndQuery() throws {
        let r = rule(query(.set(name: "q", value: "1")))
        let decision = try evaluate(snapshot(r))
        #expect(decision.route == .remote(remoteAction(path: "/v1/items?a=1&q=1")))
        #expect(decision.carry?.target == target(path: "/v1/items?a=1&q=1"))
        #expect(decision.matches.outcomes == [outcome(r.id, .applied)])
        // After a Map Remote to another origin the query edit stays on that origin.
        let moved = try evaluate(snapshot(rule(remote("b.com")), rule(query(.remove(name: "a")))))
        #expect(moved.route == .remote(remoteAction("b.com", path: "/v1/items")))
        #expect(moved.carry?.target == target(host: "b.com", path: "/v1/items"))
    }

    @Test func queryEditNoOpStillApplied() throws {
        let r = rule(query(.remove(name: "missing")))
        let decision = try evaluate(snapshot(r))
        #expect(decision.matches.outcomes == [outcome(r.id, .applied)])
        #expect(decision.route == .original)
        #expect(decision.carry?.target == target())
        #expect(decision.carry?.remote == nil)
    }

    @Test func queryEditThenConditionRowReadsNewQuery() throws {
        let edit = rule(query(.set(name: "mode", value: "debug")))
        let reader = rule(
            when: [ConditionRow(field: .queryParam, name: "mode", op: .equals, value: "debug")],
            setHeader("X-Debug", "1"))
        let decision = try evaluate(snapshot(edit, reader))
        #expect(decision.effectiveHead.headers.values(for: "X-Debug") == ["1"])
    }

    // MARK: cookies

    @Test func requestCookieEditVisibleToLaterRule() throws {
        let headers = [HeaderField(name: "Cookie", value: "a=1; b=2")]
        let edit = rule(cookies(.request, .set(name: "a", value: "9")))
        let reader = rule(
            when: [ConditionRow(field: .requestCookie, name: "a", op: .equals, value: "9")],
            setHeader("X-Seen", "1"))
        let decision = try evaluate(request(headers: headers), snapshot(edit, reader))
        #expect(decision.effectiveHead.headers.values(for: "Cookie") == ["a=9; b=2"])
        #expect(decision.effectiveHead.headers.values(for: "X-Seen") == ["1"])
        #expect(decision.carry?.requestHeaders.values(for: "Cookie") == ["a=9; b=2"])
    }

    @Test func responseCookieEditAtResponsePoint() throws {
        let edit = rule(cookies(.response, .set(name: "s", value: "2")))
        let reader = rule(
            when: [ConditionRow(field: .responseCookie, name: "s", op: .equals, value: "2")],
            RuleAction(.editHeaders(direction: .response, operations: [.set(name: "X-Seen", value: "1")])))
        let snap = snapshot(edit, reader)
        let decision = try evaluate(snap)
        #expect(!decision.rulesModified)
        let head = HTTPMessageHead.response(
            status: 200, reason: "OK", headers: [HeaderField(name: "Set-Cookie", value: "s=1; Path=/")])
        let result = try RuleEvaluator.response(head, after: decision, snapshot: snap)
        #expect(result.effectiveHead.headers.values(for: "Set-Cookie") == ["s=2; Path=/"])
        #expect(result.effectiveHead.headers.values(for: "X-Seen") == ["1"])
        #expect(result.matches.outcomes == [outcome(edit.id, .applied), outcome(reader.id, .applied)])
        #expect(result.rulesModified)
    }

    @Test func cookieEditOnUpgradeIsAllowed() throws {
        let r = rule(cookies(.request, .set(name: "a", value: "9")))
        let headers = upgradeHeaders + [HeaderField(name: "Cookie", value: "a=1")]
        let decision = try evaluate(request(headers: headers), snapshot(r))
        #expect(decision.matches.outcomes == [outcome(r.id, .applied)])
        #expect(decision.effectiveHead.headers.values(for: "Cookie") == ["a=9"])
    }

    @Test func cookieEditMarksModified() throws {
        let r = rule(cookies(.request, .set(name: "a", value: "9")))
        #expect(try evaluate(snapshot(r)).rulesModified)
    }

    // MARK: delay

    @Test func delaysAccumulateAndCap() throws {
        let summed = try evaluate(snapshot(rule(delay(300)), rule(delay(400))))
        #expect(summed.delayMilliseconds == 700)
        #expect(!summed.matches.outcomes.contains { $0.code == .delayCapped })

        let a = rule(delay(40_000))
        let b = rule(delay(30_000))
        let c = rule(delay(5))
        let capped = try evaluate(snapshot(a, b, c))
        #expect(capped.delayMilliseconds == 60_000)
        #expect(capped.matches.outcomes.filter { $0.code == .delayCapped } == [outcome(b.id, .delayCapped)])
        #expect(capped.matches.outcomes.filter { $0.code == .applied }.count == 3)

        let small = RulesLimits(delayMillisecondsMax: 100)
        #expect(try evaluate(snapshot(rule(delay(80), delay(80))), limits: small).delayMilliseconds == 100)
    }

    @Test func delayDoesNotMarkModified() throws {
        let r = rule(delay(10))
        let decision = try evaluate(snapshot(r))
        #expect(!decision.rulesModified)
        #expect(decision.matches.outcomes == [outcome(r.id, .applied)])
        #expect(decision.route == .original)
    }

    @Test func delayInFinalStopRuleStillCounted() throws {
        let r = rule(delay(500), setHeader("X-F", "1", final: true))
        let decision = try evaluate(snapshot(r))
        #expect(decision.delayMilliseconds == 500)
        #expect(decision.carry?.finalStop == RuleCarry.FinalStop(position: 0, actionIndex: 1))
    }

    @Test func delayAfterFinalActionIsSkipped() throws {
        let r = rule(setHeader("X-F", "1", final: true), delay(500))
        let decision = try evaluate(snapshot(r))
        #expect(decision.delayMilliseconds == 0)
        #expect(decision.matches.outcomes.contains(outcome(r.id, .skippedAfterFinal, 1)))
    }

    @Test func singleActionRulesRecordNoActionIndex() throws {
        let rules = [
            rule(urlSet("https://a.test/z")), rule(query(.add(name: "k", value: "v"))),
            rule(cookies(.request, .set(name: "a", value: "1"))), rule(delay(1)),
        ]
        let decision = try evaluate(snapshot(rules[0], rules[1], rules[2], rules[3]))
        #expect(decision.matches.outcomes.allSatisfy { $0.actionIndex == nil && $0.code == .applied })
        #expect(decision.matches.outcomes.count == 4)
    }

    @Test func multiActionRuleLabelsEachAction() throws {
        let r = rule(delay(1), query(.add(name: "k", value: "v")))
        let decision = try evaluate(snapshot(r))
        #expect(decision.matches.outcomes == [outcome(r.id, .applied, 0), outcome(r.id, .applied, 1)])
    }
}
