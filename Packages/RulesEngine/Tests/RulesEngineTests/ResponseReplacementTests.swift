import FlowStore
import Foundation
import Testing

@testable import RulesEngine

/// Spec 12.7 (final review): Return File / manual / predefined response, close and delay work at either point. In a
/// rule judged at the response they answer in place of the origin's response, close the client, or hold the head.
@Suite("Response replacement")
struct ResponseReplacementTests {
    private static let ok = ConditionRow(field: .statusCode, op: .inRange, value: "200-299")

    private func target() -> HTTPMessageTarget {
        HTTPMessageTarget(scheme: "https", host: "a.test", port: 443, method: "GET", pathAndQuery: "/v1/items")
    }

    private let preset = RuleAction(.returnPreset(PresetResponse(preset: .notFound404)))
    private let manual = RuleAction(.returnHandwritten(HandwrittenResponse(text: "HTTP/1.1 201 Created\r\nX-Made: 1\r\n\r\nhi")))
    private let mark = RuleAction(.mark(MarkAction(background: "#FF0000")))

    private func makeRule(_ name: String = "r", _ actions: RuleAction...) -> Rule {
        Rule(name: name, conditions: ConditionGroup(rows: [Self.ok]), actions: actions)
    }

    private func decide(
        _ rules: [Rule], isLocal: Bool = false, upgrade: Bool = false
    ) throws -> (request: RequestRuleDecision, response: ResponseRuleDecision) {
        let snapshot = RuleSnapshot(revision: 3, rules: rules)
        let cache = PatternCache(budget: RegexBudget(clock: { .zero }))
        let request = HTTPMessageHead.request(target(), headers: upgrade ? [HeaderField(name: "Upgrade", value: "websocket"), HeaderField(name: "Connection", value: "Upgrade")] : [])
        let p1 = try RuleEvaluator.request(request, snapshot: snapshot, cache: cache)
        let origin = HTTPMessageHead.response(status: 200, reason: "OK", headers: [HeaderField(name: "X-Origin", value: "1")])
        let p2 = try RuleEvaluator.response(origin, after: p1, snapshot: snapshot, requestWasUpgradeCandidate: upgrade, isLocalResponse: isLocal,
            cache: cache)
        return (p1, p2)
    }

    @Test func aPredefinedResponseReplacesTheOriginsAndEndsTheRule() throws {
        let rule = makeRule("r", preset, mark)
        let (p1, p2) = try decide([rule])
        #expect(p1.route == .original)
        let replacement = try #require(p2.replacement)
        #expect(replacement.ruleID == rule.id)
        #expect(replacement.actionIndex == 0)
        guard case .generated(let generated) = replacement.kind else { Issue.record("expected generated"); return }
        #expect(generated.status == 404)
        #expect(p2.rulesModified)
        #expect(p2.annotations.isEmpty)
        #expect(p2.carry.finalStop == RuleCarry.FinalStop(position: 0, actionIndex: 0))
        #expect(
            p2.matches.outcomes == [
                RuleOutcome(ruleID: rule.id, code: .applied, actionIndex: 0),
                RuleOutcome(ruleID: rule.id, code: .finalStop, actionIndex: 0),
                RuleOutcome(ruleID: rule.id, code: .skippedAfterFinal, actionIndex: 1),
            ])
    }

    /// A rule judged at completion reads what the client got, not the origin's response.
    @Test func completionRulesReadTheReplacementNotTheOrigin() throws {
        let seen = Rule(
            name: "seen",
            conditions: ConditionGroup(rows: [
                ConditionRow(field: .statusCode, op: .equals, value: "403"),
                ConditionRow(field: .responseBody, op: .contains, value: "nope"),
                ConditionRow(field: .durationMs, op: .greaterOrEqual, value: "0"),
            ]),
            actions: [mark])
        let forbidden = RuleAction(.returnPreset(PresetResponse(preset: .forbidden403, body: "nope")))
        let answer = makeRule("answer", forbidden)
        let snapshot = RuleSnapshot(revision: 3, rules: [seen, answer])
        let cache = PatternCache(budget: RegexBudget(clock: { .zero }))
        let p1 = try RuleEvaluator.request(.request(target(), headers: []), snapshot: snapshot, cache: cache)
        let origin = HTTPMessageHead.response(status: 200, reason: "OK", headers: [HeaderField(name: "X-Origin", value: "1")])
        let p2 = try RuleEvaluator.response(origin, after: p1, snapshot: snapshot, requestWasUpgradeCandidate: false, isLocalResponse: false, cache: cache)
        #expect(p2.replacement != nil)
        #expect(p2.carry.status == 403)
        let done = RuleEvaluator.completion(
            after: p1, response: p2, snapshot: snapshot, facts: ExchangeFacts(),
            completion: CompletionFacts(state: .completed, durationMilliseconds: 5, responseWireBytes: 4), cache: cache)
        #expect(done.matches.outcomes.contains { $0.ruleID == seen.id && $0.code == .applied })
    }

    /// R8F2 F4: the carried headers of a replacement are what the client receives, with the response path's `Content-Length`.
    @Test func theCarriedHeadersOfAReplacementAreWhatTheClientReceives() throws {
        let body = Data("nope".utf8)
        let handwritten = GeneratedResponse(
            status: 201, reason: "Created", headers: [HeaderField(name: "Content-Length", value: "999"), HeaderField(name: "X-A", value: "1")],
            body: body, kind: .handwritten)
        let carry = RuleEvaluator.responseCarry(
            finalStop: nil, status: 200, headers: [], body: .notCollected,
            replacement: ResponseReplacement(.generated(handwritten), ruleID: UUID(), actionIndex: nil), limits: RulesLimits())
        #expect(carry.headers == [HeaderField(name: "Content-Length", value: "4"), HeaderField(name: "X-A", value: "1")])
        let bare = GeneratedResponse(status: 200, reason: "OK", headers: [HeaderField(name: "Content-Type", value: "text/plain")], body: body, kind: .handwritten)
        #expect(bare.clientHeaders == [HeaderField(name: "Content-Type", value: "text/plain"), HeaderField(name: "Content-Length", value: "4")])
        let none = GeneratedResponse(status: 204, reason: "No Content", headers: [HeaderField(name: "content-length", value: "0")], body: Data(), kind: .handwritten)
        #expect(none.clientHeaders.isEmpty)
        // A preset states its own length and type; the carry keeps them.
        let preset = try RuleEvaluator.generated(PresetResponse(preset: .forbidden403, body: "nope"))
        #expect(preset.clientHeaders.contains(HeaderField(name: "Content-Length", value: String(preset.body.count))))
        #expect(preset.clientHeaders.contains { $0.name == "Content-Type" })
    }

    @Test func aManualResponseReplacesTheOriginsAndTheLowerRulesAreCut() throws {
        let first = makeRule("first", manual)
        let below = makeRule("below", RuleAction(.editHeaders(direction: .response, operations: [.set(name: "X-B", value: "1")])))
        let (_, p2) = try decide([first, below])
        guard case .generated(let generated)? = p2.replacement?.kind else { Issue.record("expected generated"); return }
        #expect(generated.status == 201)
        #expect(p2.effectiveHead.headers.contains { $0.name == "X-B" } == false)
        #expect(p2.matches.ruleIDs == [first.id])
    }

    @Test func returnFileReplacesWithTheFile() throws {
        let file = MapLocalAction(assetID: UUID(), status: 200, headers: [])
        let rule = makeRule("f", RuleAction(.returnFile(file)))
        let (_, p2) = try decide([rule])
        #expect(p2.replacement == ResponseReplacement(.file(file), ruleID: rule.id, actionIndex: nil))
        #expect(p2.replacement?.route == .local(file))
    }

    @Test func closeEndsTheExchangeAtTheResponse() throws {
        let rule = makeRule("c", RuleAction(.closeConnection(.reset)))
        let (_, p2) = try decide([rule])
        #expect(p2.replacement == ResponseReplacement(.close(.reset), ruleID: rule.id, actionIndex: nil))
        #expect(p2.replacement?.route == nil)
        #expect(!p2.rulesModified)
        #expect(p2.carry.finalStop != nil)
    }

    @Test func delaysOfResponseJudgedRulesAddUpAndAreCapped() throws {
        let a = makeRule("a", RuleAction(.delay(milliseconds: 300)))
        let b = makeRule("b", RuleAction(.delay(milliseconds: 400)))
        let (p1, p2) = try decide([a, b])
        #expect(p1.delayMilliseconds == 0)
        #expect(p2.delayMilliseconds == 700)
        #expect(p2.replacement == nil)
        #expect(!p2.rulesModified)
        #expect(p2.matches.outcomes == [RuleOutcome(ruleID: a.id, code: .applied), RuleOutcome(ruleID: b.id, code: .applied)])
        let big = makeRule("big", RuleAction(.delay(milliseconds: 50_000)), RuleAction(.delay(milliseconds: 50_000)))
        let (_, capped) = try decide([big])
        #expect(capped.delayMilliseconds == RulesLimits().delayMillisecondsMax)
        #expect(capped.matches.outcomes.contains { $0.code == .delayCapped })
    }

    @Test func aDelayBeforeAReturnHoldsTheReplacementToo() throws {
        let rule = makeRule("d", RuleAction(.delay(milliseconds: 250)), preset)
        let (_, p2) = try decide([rule])
        #expect(p2.delayMilliseconds == 250)
        #expect(p2.replacement != nil)
    }

    @Test func aRuleJudgedAtTheRequestStillActsAtTheRequestOnly() throws {
        let atRequest = Rule(
            name: "req", conditions: ConditionGroup(rows: [ConditionRow(field: .method, op: .equals, value: "GET")]),
            actions: [RuleAction(.delay(milliseconds: 100)), preset])
        let (p1, p2) = try decide([atRequest])
        #expect(p1.delayMilliseconds == 100)
        if case .generated = p1.route {} else { Issue.record("expected the request point to answer") }
        #expect(p2.replacement == nil)
        #expect(p2.delayMilliseconds == 0)
    }

    @Test func theProxysOwnResponseCannotBeReplacedAgain() throws {
        let rule = makeRule("r", preset)
        let (_, p2) = try decide([rule], isLocal: true)
        #expect(p2.replacement == nil)
        #expect(p2.matches.outcomes.first == RuleOutcome(ruleID: rule.id, code: .responseAlreadyLocal))
        // A close and a delay still work on it.
        let close = makeRule("c", RuleAction(.closeConnection(.graceful)))
        #expect(try decide([close], isLocal: true).response.replacement != nil)
    }

    @Test func anUpgradeHandshakeIsNotReplaced() throws {
        let rule = makeRule("r", preset)
        let (_, p2) = try decide([rule], upgrade: true)
        #expect(p2.replacement == nil)
        #expect(p2.matches.outcomes.first == RuleOutcome(ruleID: rule.id, code: .unsupportedUpgradeAction))
    }

    @Test func aReplacementDropsTheResponseBreakpointAndBodyRewrites() throws {
        let above = makeRule(
            "above", RuleAction(.breakpoint(direction: .response, mode: .headers)),
            RuleAction(.rewriteBody(direction: .response, BodyRewriteAction(find: "a", replacement: "b"))))
        let answering = makeRule("answer", preset)
        let (_, p2) = try decide([above, answering])
        #expect(p2.replacement != nil)
        #expect(p2.breakpoint == nil)
        #expect(p2.bodyRewrites.isEmpty)
        #expect(p2.matches.outcomes.contains(RuleOutcome(ruleID: above.id, code: .bodySkippedLocalRoute, actionIndex: 1)))
    }

    @Test func rulesWithoutThemDecideAsBefore() throws {
        let rule = makeRule("plain", RuleAction(.editHeaders(direction: .response, operations: [.set(name: "X-B", value: "1")])))
        let (_, p2) = try decide([rule])
        #expect(p2.replacement == nil)
        #expect(p2.delayMilliseconds == 0)
        #expect(p2.effectiveHead.headers.contains(HeaderField(name: "X-B", value: "1")))
    }

    // MARK: Execute

    @Test func executeShowsTheReplacementResponseInTheOverlay() async throws {
        let rule = ExecuteFixtures.rule(
            "answer", rows: [Self.ok], .returnPreset(PresetResponse(preset: .notFound404)))
        let result = try await ExecuteEngine.run(
            ExecuteFixtures.flow(), snapshot: ExecuteFixtures.snapshot(rule), environment: ExecuteFixtures.environment())
        let response = try #require(result.overlay?.response)
        #expect(result.overlay?.responseIsLocal == true)
        #expect(response.status == 404)
    }
}
