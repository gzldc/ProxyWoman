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

private func response(_ status: Int = 200, headers: [HeaderField] = []) -> HTTPMessageHead {
    .response(status: status, reason: "OK", headers: headers)
}

private let upgradeHeaders = [
    HeaderField(name: "Connection", value: "Upgrade"), HeaderField(name: "Upgrade", value: "websocket"),
    HeaderField(name: "Sec-WebSocket-Key", value: "k"),
]

// MARK: actions

private func preset(_ preset: PresetResponse.Preset, body: String? = nil, final: Bool = false) -> RuleAction {
    RuleAction(.returnPreset(PresetResponse(preset: preset, body: body)), isFinal: final)
}

private func handwritten(_ text: String, final: Bool = false) -> RuleAction {
    RuleAction(.returnHandwritten(HandwrittenResponse(text: text)), isFinal: final)
}

private func close(_ mode: CloseMode = .graceful) -> RuleAction { RuleAction(.closeConnection(mode)) }

private func setHeader(
    _ name: String, _ value: String, on direction: HTTPMessageDirection = .request, final: Bool = false
) -> RuleAction {
    RuleAction(.editHeaders(direction: direction, operations: [.set(name: name, value: value)]), isFinal: final)
}

private func urlSet(_ url: String, final: Bool = false) -> RuleAction {
    RuleAction(.modifyURL(URLEditAction(mode: .set, replacement: url)), isFinal: final)
}

private func rewriteStatus(_ status: Int, includeLocal: Bool = false) -> RuleAction {
    RuleAction(.rewriteStatus(RewriteStatusAction(status: status, includeLocalResponses: includeLocal)))
}

private func rewriteBody(_ direction: HTTPMessageDirection = .request) -> RuleAction {
    RuleAction(.rewriteBody(direction: direction, BodyRewriteAction(find: "a", replacement: "b")))
}

private let red = "#FF3B30"
private func mark() -> RuleAction { RuleAction(.mark(MarkAction(background: red))) }

// MARK: conditions

private func hostIs(_ value: String) -> ConditionRow { ConditionRow(field: .host, op: .hostPattern, value: value) }
private func statusEquals(_ code: Int) -> ConditionRow {
    ConditionRow(field: .statusCode, op: .equals, value: "\(code)")
}
private func sessionState(_ value: String) -> ConditionRow {
    ConditionRow(field: .sessionState, op: .equals, value: value)
}

private func rule(id: UUID = UUID(), name: String = "r", when rows: [ConditionRow] = [], _ actions: RuleAction...)
    -> Rule
{
    Rule(
        id: id, name: name, enabled: true, groupID: nil, order: 0,
        conditions: ConditionGroup(mode: .all, occurrence: .any, rows: rows), actions: actions)
}

/// Rules are evaluated in the order given (they all have order 0).
private func snapshot(_ rules: Rule...) -> RuleSnapshot { RuleSnapshot(revision: 7, groups: [], rules: rules) }

private func calmCache() -> PatternCache { PatternCache(budget: RegexBudget(clock: { .zero })) }

private func evaluate(_ snapshot: RuleSnapshot) throws -> RequestRuleDecision { try evaluate(request(), snapshot) }

private func evaluate(_ head: HTTPMessageHead, _ snapshot: RuleSnapshot) throws -> RequestRuleDecision {
    try RuleEvaluator.request(head, snapshot: snapshot, cache: calmCache())
}

private func respond(
    _ head: HTTPMessageHead = response(), after decision: RequestRuleDecision, _ snapshot: RuleSnapshot,
    local: Bool = false
) throws -> ResponseRuleDecision {
    try RuleEvaluator.response(head, after: decision, snapshot: snapshot, isLocalResponse: local, cache: calmCache())
}

private func outcome(_ id: UUID, _ code: RuleOutcomeCode, _ index: Int? = nil) -> RuleOutcome {
    RuleOutcome(ruleID: id, code: code, actionIndex: index)
}

private func generated(_ preset: PresetResponse.Preset, body: String? = nil) -> GeneratedResponse {
    guard case .success(let response) = PresetResponse(preset: preset, body: body).build() else {
        preconditionFailure("a preset that builds")
    }
    return response
}

@Suite("RuleEvaluatorTransportActions")
struct RuleEvaluatorTransportActionsTests {
    // MARK: generated responses

    @Test func returnPresetBuildsGeneratedRoute() throws {
        let r = rule(preset(.forbidden403, body: "nope"))
        let decision = try evaluate(snapshot(r))
        guard case .generated(let response) = decision.route else {
            Issue.record("expected a generated route, got \(decision.route)")
            return
        }
        #expect(response.status == 403)
        #expect(response.reason == "Forbidden")
        #expect(response.body == Data("nope".utf8))
        #expect(response.headers.values(for: "Content-Length") == ["4"])
        #expect(response.kind == .preset(.forbidden403))
        #expect(decision.route == .generated(generated(.forbidden403, body: "nope")))
        #expect(decision.matches.outcomes == [outcome(r.id, .applied)])
        #expect(decision.carry?.finalStop == RuleCarry.FinalStop(position: 0, actionIndex: 0))
    }

    @Test func returnHandwrittenBuildsGeneratedRoute() throws {
        let r = rule(handwritten("HTTP/1.1 418 Teapot\r\nX-A: 1\r\n\r\nshort and stout"))
        let decision = try evaluate(snapshot(r))
        guard case .generated(let response) = decision.route else {
            Issue.record("expected a generated route, got \(decision.route)")
            return
        }
        #expect(response.status == 418)
        #expect(response.reason == "Teapot")
        #expect(response.headers.values(for: "X-A") == ["1"])
        #expect(response.headers.values(for: "Content-Length") == ["15"])
        #expect(response.body == Data("short and stout".utf8))
        #expect(response.kind == .handwritten)
        #expect(decision.matches.outcomes == [outcome(r.id, .applied)])
    }

    @Test func invalidHandwrittenResponseRejects() {
        // Only a snapshot that skipped validation holds one.
        let first = rule(setHeader("X-A", "1"))
        let bad = rule(handwritten("not a status line"))
        do {
            _ = try evaluate(snapshot(first, bad))
            Issue.record("expected a rule evaluation failure")
        } catch let error as RuleEvaluationError {
            #expect(error.matches.ruleIDs == [first.id, bad.id])
            #expect(error.matches.outcomes == [outcome(first.id, .applied), outcome(bad.id, .rejected)])
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func invalidPresetRejects() {
        let bad = rule(RuleAction(.returnPreset(PresetResponse(preset: .found302))))
        do {
            _ = try evaluate(snapshot(bad))
            Issue.record("expected a rule evaluation failure")
        } catch let error as RuleEvaluationError {
            #expect(error.matches.outcomes == [outcome(bad.id, .rejected)])
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func generatedResponseMarksModified() throws {
        #expect(try evaluate(snapshot(rule(preset(.notFound404)))).rulesModified)
        #expect(try evaluate(snapshot(rule(handwritten("HTTP/1.1 200 OK\n\nhi")))).rulesModified)
    }

    @Test func generatedResponseOnUpgradeIsUnsupportedAndDoesNotStop() throws {
        let r = rule(preset(.notFound404), setHeader("X-After", "1"))
        let lower = rule(setHeader("X-Lower", "1"))
        let decision = try evaluate(request(headers: upgradeHeaders), snapshot(r, lower))
        #expect(decision.route == .original)
        #expect(decision.carry?.finalStop == nil)
        #expect(
            decision.matches.outcomes == [
                outcome(r.id, .unsupportedUpgradeAction, 0), outcome(r.id, .applied, 1), outcome(lower.id, .applied),
            ])
        #expect(decision.effectiveHead.headers.values(for: "X-Lower") == ["1"])
    }

    // MARK: close connection

    @Test func closeConnectionRouteCarriesRuleID() throws {
        let id = UUID()
        let decision = try evaluate(snapshot(rule(id: id, close(.reset))))
        #expect(decision.route == .close(.reset, ruleID: id))
        #expect(decision.matches.outcomes == [outcome(id, .applied)])
        #expect(decision.carry?.finalStop == RuleCarry.FinalStop(position: 0, actionIndex: 0))
        let graceful = try evaluate(snapshot(rule(id: id, close())))
        #expect(graceful.route == .close(.graceful, ruleID: id))
    }

    @Test func closeConnectionDoesNotMarkModified() throws {
        let decision = try evaluate(snapshot(rule(close())))
        #expect(!decision.rulesModified)
        // A lower rule reading "modified" never sees it either: the close cut it.
        let edited = try evaluate(snapshot(rule(setHeader("X-A", "1"), close())))
        #expect(edited.rulesModified)
    }

    @Test func closeConnectionOnUpgradeStillCloses() throws {
        let r = rule(close(.reset))
        let decision = try evaluate(request(headers: upgradeHeaders), snapshot(r))
        #expect(decision.route == .close(.reset, ruleID: r.id))
        #expect(decision.matches.outcomes == [outcome(r.id, .applied)])
        #expect(decision.carry?.finalStop == RuleCarry.FinalStop(position: 0, actionIndex: 0))
    }

    // MARK: final actions

    @Test func returnIsFinalAndCutsLowerRules() throws {
        let r = rule(preset(.noContent204))
        let lower = rule(setHeader("X-Lower", "1"), mark())
        let decision = try evaluate(snapshot(r, lower))
        #expect(decision.matches.ruleIDs == [r.id])
        #expect(decision.matches.outcomes == [outcome(r.id, .applied), outcome(r.id, .finalStop, 0)])
        #expect(decision.annotations.isEmpty)
        #expect(decision.effectiveHead.headers.values(for: "X-Lower").isEmpty)
        #expect(decision.carry?.finalStop == RuleCarry.FinalStop(position: 0, actionIndex: 0))
        // The same for a close.
        let closing = rule(close())
        let closed = try evaluate(snapshot(closing, lower))
        #expect(closed.matches.outcomes == [outcome(closing.id, .applied), outcome(closing.id, .finalStop, 0)])
    }

    @Test func actionsAfterAReturnInTheSameRuleAreSkipped() throws {
        let r = rule(preset(.notFound404), setHeader("X-After", "1"), mark())
        let decision = try evaluate(snapshot(r))
        #expect(
            decision.matches.outcomes == [
                outcome(r.id, .applied, 0), outcome(r.id, .finalStop, 0), outcome(r.id, .skippedAfterFinal, 1),
                outcome(r.id, .skippedAfterFinal, 2),
            ])
        #expect(decision.effectiveHead.headers.values(for: "X-After").isEmpty)
        #expect(decision.annotations.isEmpty)
    }

    @Test func actionsBeforeAReturnStillRun() throws {
        let r = rule(setHeader("X-Before", "1"), preset(.forbidden403))
        let decision = try evaluate(snapshot(r))
        #expect(decision.matches.outcomes == [outcome(r.id, .applied, 0), outcome(r.id, .applied, 1)])
        #expect(decision.carry?.requestHeaders.values(for: "X-Before") == ["1"])
        #expect(decision.carry?.finalStop == RuleCarry.FinalStop(position: 0, actionIndex: 1))
        // The response point's rules read the edited request headers.
        let reads = rule(
            when: [ConditionRow(field: .requestHeader, name: "X-Before", op: .equals, value: "1"), statusEquals(403)],
            setHeader("X-Seen", "1", on: .response))
        let both = snapshot(reads, r)
        let request = try evaluate(both)
        let answered = try respond(response(403), after: request, both, local: true)
        #expect(answered.effectiveHead.headers.values(for: "X-Seen") == ["1"])
    }

    @Test func higherPriorityResponseRuleStillRunsAfterGeneratedRoute() throws {
        // Spec 5.5.4: A (higher, judged at the response) edits the generated response; B returns it.
        let a = rule(when: [statusEquals(403)], setHeader("X-A", "1", on: .response))
        let b = rule(preset(.forbidden403))
        let rules = snapshot(a, b)
        let request = try evaluate(rules)
        #expect(request.matches.ruleIDs == [b.id])
        #expect(request.matches.outcomes == [outcome(b.id, .applied)])
        let answered = try respond(response(403), after: request, rules, local: true)
        #expect(answered.matches.ruleIDs == [a.id])
        #expect(answered.effectiveHead.headers.values(for: "X-A") == ["1"])
        // Its status rewrite keeps its "local responses too" choice.
        let rewrites = rule(when: [statusEquals(403)], rewriteStatus(500))
        let rewritesLocal = rule(when: [statusEquals(403)], rewriteStatus(503, includeLocal: true))
        let skipped = snapshot(rewrites, b)
        let skippedAnswer = try respond(response(403), after: try evaluate(skipped), skipped, local: true)
        #expect(skippedAnswer.matches.outcomes == [outcome(rewrites.id, .statusSkippedLocal)])
        let applied = snapshot(rewritesLocal, b)
        let appliedAnswer = try respond(response(403), after: try evaluate(applied), applied, local: true)
        #expect(appliedAnswer.statusRewrite == 503)
    }

    @Test func lowerPriorityResponseRuleCutByRequestPointFinal() throws {
        let b = rule(preset(.forbidden403))
        let below = rule(when: [statusEquals(403)], setHeader("X-Below", "1", on: .response))
        let pendingBelow = rule(setHeader("X-Pending", "1", on: .response))
        let rules = snapshot(b, below, pendingBelow)
        let request = try evaluate(rules)
        #expect(request.matches.outcomes == [outcome(b.id, .applied), outcome(b.id, .finalStop, 0)])
        let answered = try respond(response(403), after: request, rules, local: true)
        #expect(answered.matches.ruleIDs.isEmpty)
        #expect(answered.effectiveHead.headers.values(for: "X-Below").isEmpty)
        #expect(answered.effectiveHead.headers.values(for: "X-Pending").isEmpty)
        #expect(answered.carry.finalStop == RuleCarry.FinalStop(position: 0, actionIndex: 0))
    }

    @Test func closeCutsResponsePointButNotCompletion() throws {
        let failedAbove = rule(when: [sessionState("failed")], mark())
        let closing = rule(close())
        let failedBelow = rule(when: [sessionState("failed")], mark())
        let responseBelow = rule(when: [statusEquals(200)], setHeader("X-Below", "1", on: .response))
        let rules = snapshot(failedAbove, closing, failedBelow, responseBelow)
        let request = try evaluate(rules)
        #expect(request.route == .close(.graceful, ruleID: closing.id))
        #expect(request.matches.outcomes == [outcome(closing.id, .applied), outcome(closing.id, .finalStop, 0)])
        // Were a response point run, the close would cut it below the closing rule.
        let answered = try respond(after: request, rules)
        #expect(answered.matches.ruleIDs.isEmpty)
        // The completion point still runs the rules above the close, with no response.
        let failed = CompletionFacts(state: .failed, durationMilliseconds: 3, responseWireBytes: nil)
        let done = RuleEvaluator.completion(
            after: request, response: nil, snapshot: rules, facts: ExchangeFacts(), completion: failed,
            cache: calmCache())
        #expect(done.matches.ruleIDs == [failedAbove.id])
        #expect(done.matches.outcomes == [outcome(failedAbove.id, .applied)])
        #expect(done.annotations.count == 1)
    }

    // MARK: connect-only actions

    @Test func connectOnlyActionsNeverRunOrStopAtTheRequestPoint() throws {
        let noDecrypt = rule(when: [hostIs("a.test")], RuleAction(.noDecrypt))
        let tunnel = rule(when: [hostIs("a.test")], RuleAction(.returnConnectTunnel, isFinal: true), mark())
        let edit = rule(urlSet("https://a.test/moved"))
        let rules = snapshot(noDecrypt, tunnel, edit)
        #expect(noDecrypt.conditions.judgmentPoint == .connect)
        let decision = try evaluate(rules)
        #expect(decision.matches.ruleIDs == [tunnel.id, edit.id])
        #expect(decision.matches.outcomes == [outcome(tunnel.id, .applied, 1), outcome(edit.id, .applied)])
        #expect(decision.carry?.finalStop == nil)
        #expect(decision.carry?.target == target(path: "/moved"))
        #expect(!decision.matches.outcomes.contains { $0.ruleID == noDecrypt.id })
    }

    @Test func connectOnlyActionsSkippedAtTheResponsePointToo() throws {
        // Only a snapshot that skipped validation pairs them with a response condition.
        let odd = rule(when: [statusEquals(200)], RuleAction(.noDecrypt), RuleAction(.returnConnectTunnel), mark())
        let lower = rule(when: [statusEquals(200)], setHeader("X-Lower", "1", on: .response))
        let rules = snapshot(odd, lower)
        let request = try evaluate(rules)
        let answered = try respond(after: request, rules)
        #expect(answered.matches.ruleIDs == [odd.id, lower.id])
        #expect(answered.matches.outcomes == [outcome(odd.id, .applied, 2), outcome(lower.id, .applied)])
        #expect(answered.carry.finalStop == nil)
        #expect(answered.effectiveHead.headers.values(for: "X-Lower") == ["1"])
    }

    @Test func finalFlagOnNewKindsIsIgnoredWhenIntrinsic() throws {
        let lower = rule(setHeader("X-Lower", "1"))
        for (plain, ticked) in [
            (preset(.notFound404), preset(.notFound404, final: true)),
            (handwritten("HTTP/1.1 200 OK\n\n"), handwritten("HTTP/1.1 200 OK\n\n", final: true)),
            (close(), RuleAction(.closeConnection(.graceful), isFinal: true)),
        ] {
            let id = UUID()
            let untickedDecision = try evaluate(snapshot(rule(id: id, plain), lower))
            let tickedDecision = try evaluate(snapshot(rule(id: id, ticked), lower))
            #expect(untickedDecision == tickedDecision)
            #expect(tickedDecision.carry?.finalStop == RuleCarry.FinalStop(position: 0, actionIndex: 0))
        }
    }

    @Test func userTickedFinalOnModifyURLStopsLowerRules() throws {
        let r = rule(urlSet("https://a.test/moved", final: true))
        let lower = rule(setHeader("X-Lower", "1"))
        let decision = try evaluate(snapshot(r, lower))
        #expect(decision.matches.outcomes == [outcome(r.id, .applied), outcome(r.id, .finalStop, 0)])
        #expect(decision.effectiveHead.headers.values(for: "X-Lower").isEmpty)
        #expect(decision.route == .remote(
            MapRemoteAction(
                targetScheme: "https", targetHost: "a.test", targetPort: 443, path: .replace("/moved"),
                preserveCredentials: false)))
    }

    @Test func bodyRewriteIsSkippedOnGeneratedRoute() throws {
        let body = rule(rewriteBody())
        let returning = rule(preset(.forbidden403))
        let decision = try evaluate(snapshot(body, returning))
        #expect(decision.bodyRewrites.isEmpty)
        #expect(
            decision.matches.outcomes == [
                outcome(body.id, .bodySkippedLocalRoute), outcome(returning.id, .applied),
            ])
        let closing = rule(close())
        let closed = try evaluate(snapshot(body, closing))
        #expect(closed.bodyRewrites.isEmpty)
        #expect(closed.matches.outcomes.first == outcome(body.id, .bodySkippedLocalRoute))
    }

    @Test func oracleSuitesStillPass() throws {
        // The frozen oracle (EvaluatorOracleTests) runs untouched in the package gate; here, a snapshot
        // of the earlier kinds only routes and stops as before.
        let file = MapLocalAction(assetID: UUID(), headers: [])
        let returning = rule(RuleAction(.returnFile(file)))
        let lower = rule(setHeader("X-Lower", "1"))
        let decision = try evaluate(snapshot(returning, lower))
        #expect(decision.route == .local(file))
        #expect(decision.matches.outcomes == [outcome(returning.id, .applied), outcome(returning.id, .finalStop, 0)])
        #expect(decision.rulesModified)
    }
}
