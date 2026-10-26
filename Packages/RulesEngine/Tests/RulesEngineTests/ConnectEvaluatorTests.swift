import FlowStore
import Foundation
import Testing

@testable import RulesEngine

/// Rules 2.0 R4 Task 7: the CONNECT point (P0, D11–D13).

/// The target of a CONNECT line, as `TunnelRecorder` writes it.
private func connectTarget(host: String = "x.com", port: Int = 443) -> HTTPMessageTarget {
    HTTPMessageTarget(scheme: "https", host: host, port: port, method: "CONNECT", pathAndQuery: "")
}

// MARK: actions

private let red = "#FF3B30"
private func mark(final: Bool = false) -> RuleAction { RuleAction(.mark(MarkAction(background: red)), isFinal: final) }
private func comment(_ text: String = "note", _ mode: CommentAction.Mode = .append) -> RuleAction {
    RuleAction(.comment(CommentAction(mode: mode, text: text)))
}
private let hide = RuleAction(.hide)
private let noDecrypt = RuleAction(.noDecrypt)
private let returnTunnel = RuleAction(.returnConnectTunnel)
private func close(_ mode: CloseMode = .graceful) -> RuleAction { RuleAction(.closeConnection(mode)) }
private let delay = RuleAction(.delay(milliseconds: 100))
private let setHeader = RuleAction(.editHeaders(direction: .request, operations: [.set(name: "X", value: "1")]))

// MARK: conditions

private func row(_ field: ConditionField, _ op: ConditionOperator, _ value: String = "", name: String? = nil)
    -> ConditionRow
{
    ConditionRow(field: field, name: name, op: op, value: value)
}

private func rule(
    id: UUID = UUID(), name: String = "r", enabled: Bool = true, groupID: UUID? = nil, when rows: [ConditionRow] = [],
    occurrence: Occurrence = .any, _ actions: RuleAction...
) -> Rule {
    Rule(
        id: id, name: name, enabled: enabled, groupID: groupID, order: 0,
        conditions: ConditionGroup(mode: .all, occurrence: occurrence, rows: rows), actions: actions)
}

/// Rules are evaluated in the order given (they all have order 0).
private func snapshot(_ rules: Rule..., groups: [RuleGroup] = []) -> RuleSnapshot {
    RuleSnapshot(revision: 7, groups: groups, rules: rules)
}

private func calmCache() -> PatternCache { PatternCache(budget: RegexBudget(clock: { .zero })) }

private func atConnect(
    _ snapshot: RuleSnapshot, tool: ConnectToolDecision = .decrypt, target: HTTPMessageTarget = connectTarget(),
    hits: RuleHitCounter? = nil, facts: ExchangeFacts = ExchangeFacts(),
    allowance: RegexAllowance = RegexAllowance()
) -> ConnectRuleDecision {
    RuleEvaluator.connect(
        target: target, snapshot: snapshot, tool: tool, hits: hits, facts: facts, allowance: allowance,
        cache: calmCache())
}

private func outcome(_ id: UUID, _ code: RuleOutcomeCode, _ index: Int? = nil) -> RuleOutcome {
    RuleOutcome(ruleID: id, code: code, actionIndex: index)
}

private func flowMark(rule: Rule) -> FlowAnnotation {
    .mark(FlowMark(background: red, source: .rule(id: rule.id, name: rule.name))!)
}

/// A regular-expression clock that returns the given readings in order, then a long time.
private final class ScriptedClock: @unchecked Sendable {  // guarded by `lock`
    private let lock = NSLock()
    private var values: [Duration]
    init(_ millis: [Int]) { values = millis.map { .milliseconds($0) } }
    func read() -> Duration { lock.withLock { values.isEmpty ? .seconds(1000) : values.removeFirst() } }
}

struct ConnectEvaluatorTests {
    @Test func noRulesProceeds() {
        let decision = atConnect(snapshot())
        #expect(decision.disposition == .proceed)
        #expect(decision.matches == RuleMatchSummary(revision: 7, ruleIDs: [], total: 0))
        #expect(decision.annotations.isEmpty)
        #expect(decision.finalStop == nil)
    }

    @Test func noDecryptOnDecryptingHost() {
        let skip = rule(when: [row(.host, .hostPattern, "x.com")], noDecrypt)
        let decision = atConnect(snapshot(skip), tool: .decrypt)
        #expect(decision.disposition == .noDecrypt)
        #expect(decision.matches.ruleIDs == [skip.id])
        // Nothing below it, so the stop cut nothing and says nothing (R1 D8); the decision still has it.
        #expect(decision.matches.outcomes == [outcome(skip.id, .applied)])
        #expect(decision.finalStop == RuleCarry.FinalStop(position: 0, actionIndex: 0))
    }

    @Test func toolDecidedTunnelRecordsSkippedByTool() {
        let skip = rule(noDecrypt)
        let tunnel = rule(returnTunnel)
        let decision = atConnect(snapshot(skip, tunnel), tool: .tunnel)
        #expect(decision.disposition == .proceed)
        #expect(decision.matches.ruleIDs == [skip.id, tunnel.id])
        #expect(decision.matches.outcomes == [outcome(skip.id, .skippedByTool), outcome(tunnel.id, .skippedByTool)])
        #expect(decision.finalStop == nil)
    }

    @Test func skippedByToolDoesNotCutLowerRules() {
        let skip = rule(noDecrypt)
        let closing = rule(close(.reset))
        let decision = atConnect(snapshot(skip, closing), tool: .tunnel)
        #expect(decision.disposition == .close(.reset, ruleID: closing.id))
        #expect(decision.matches.outcomes == [outcome(skip.id, .skippedByTool), outcome(closing.id, .applied)])
        #expect(decision.finalStop == RuleCarry.FinalStop(position: 1, actionIndex: 0))
    }

    @Test func returnConnectTunnelTruncatesLowerNoDecrypt() {
        let tunnel = rule(returnTunnel)
        let skip = rule(noDecrypt)
        let decision = atConnect(snapshot(tunnel, skip), tool: .decrypt)
        #expect(decision.disposition == .proceed)
        #expect(decision.matches.ruleIDs == [tunnel.id])
        #expect(decision.matches.outcomes == [outcome(tunnel.id, .applied), outcome(tunnel.id, .finalStop, 0)])
        #expect(decision.finalStop == RuleCarry.FinalStop(position: 0, actionIndex: 0))
    }

    @Test func noDecryptAboveReturnTunnelWins() {
        let skip = rule(noDecrypt)
        let tunnel = rule(returnTunnel)
        let decision = atConnect(snapshot(skip, tunnel), tool: .decrypt)
        #expect(decision.disposition == .noDecrypt)
        #expect(decision.matches.ruleIDs == [skip.id])
        #expect(decision.matches.outcomes == [outcome(skip.id, .applied), outcome(skip.id, .finalStop, 0)])
    }

    @Test func closeGraceful() {
        let closing = rule(close(.graceful))
        let decision = atConnect(snapshot(closing))
        #expect(decision.disposition == .close(.graceful, ruleID: closing.id))
        #expect(decision.matches.outcomes == [outcome(closing.id, .applied)])
        #expect(decision.finalStop == RuleCarry.FinalStop(position: 0, actionIndex: 0))
    }

    @Test func closeReset() {
        let closing = rule(close(.reset))
        for tool in [ConnectToolDecision.decrypt, .tunnel] {
            // The tool's decision does not touch closing the connection (D12).
            let decision = atConnect(snapshot(closing), tool: tool)
            #expect(decision.disposition == .close(.reset, ruleID: closing.id))
            #expect(decision.matches.outcomes == [outcome(closing.id, .applied)])
        }
    }

    @Test func closeBeatsLowerNoDecrypt() {
        let closing = rule(close())
        let skip = rule(noDecrypt)
        let decision = atConnect(snapshot(closing, skip), tool: .decrypt)
        #expect(decision.disposition == .close(.graceful, ruleID: closing.id))
        #expect(decision.matches.ruleIDs == [closing.id])
        #expect(decision.matches.outcomes == [outcome(closing.id, .applied), outcome(closing.id, .finalStop, 0)])
    }

    @Test func annotationsAreCollectedInOrder() {
        let marking = rule(mark())
        let commenting = rule(comment("seen"))
        let hiding = rule(hide)
        let decision = atConnect(snapshot(marking, commenting, hiding))
        #expect(
            decision.annotations == [
                flowMark(rule: marking), .comment(CommentAction(mode: .append, text: "seen")), .hide,
            ])
        #expect(
            decision.matches.outcomes == [
                outcome(marking.id, .applied), outcome(commenting.id, .applied), outcome(hiding.id, .applied),
            ])
        #expect(decision.disposition == .proceed)
        #expect(decision.finalStop == RuleCarry.FinalStop(position: 2, actionIndex: 0))
    }

    @Test func hideIsFinalAtConnect() {
        let hiding = rule(hide)
        let closing = rule(close())
        let decision = atConnect(snapshot(hiding, closing))
        #expect(decision.disposition == .proceed)
        #expect(decision.annotations == [.hide])
        #expect(decision.matches.ruleIDs == [hiding.id])
        #expect(decision.matches.outcomes == [outcome(hiding.id, .applied), outcome(hiding.id, .finalStop, 0)])
    }

    @Test func userTickedFinalMarkStopsLowerRules() {
        let marking = rule(mark(final: true))
        let closing = rule(close())
        let decision = atConnect(snapshot(marking, closing))
        #expect(decision.disposition == .proceed)
        #expect(decision.matches.outcomes == [outcome(marking.id, .applied), outcome(marking.id, .finalStop, 0)])
    }

    @Test func colourlessMarkWithStopTickStopsLowerRulesAndIsRecorded() {
        for colour in [MarkAction.unchangedColor, MarkAction.defaultColor] {
            let marking = rule(RuleAction(.mark(MarkAction(background: colour)), isFinal: true))
            let closing = rule(close())
            let decision = atConnect(snapshot(marking, closing))
            #expect(decision.disposition == .proceed)
            #expect(decision.annotations == (colour == MarkAction.defaultColor ? [.resetMark(background: true, foreground: true)] : []))
            #expect(decision.matches.outcomes == [outcome(marking.id, .applied), outcome(marking.id, .finalStop, 0)])
            #expect(decision.finalStop == RuleCarry.FinalStop(position: 0, actionIndex: 0))
        }
    }

    @Test func colourlessMarkWithoutStopIsRecordedAsApplied() {
        let marking = rule(RuleAction(.mark(MarkAction(background: MarkAction.unchangedColor))))
        let decision = atConnect(snapshot(marking))
        #expect(decision.annotations.isEmpty)
        #expect(decision.matches.outcomes == [outcome(marking.id, .applied)])
    }

    @Test func actionsAfterAFinalOneInTheSameRuleAreSkipped() {
        let closing = rule(close(), mark())
        let decision = atConnect(snapshot(closing))
        #expect(decision.annotations.isEmpty)
        #expect(
            decision.matches.outcomes == [
                outcome(closing.id, .applied, 0), outcome(closing.id, .finalStop, 0),
                outcome(closing.id, .skippedAfterFinal, 1),
            ])
    }

    @Test func ruleWithRequestSideActionsOnlyRunsConnectCapableOnes() {
        let mixed = rule(mark(), delay)
        let decision = atConnect(snapshot(mixed))
        #expect(decision.annotations == [flowMark(rule: mixed)])
        #expect(decision.matches.outcomes == [outcome(mixed.id, .applied, 0)])
    }

    @Test func ruleJudgedAtRequestIsNotEvaluatedAtConnect() {
        let byPath = rule(when: [row(.path, .equals, "/")], mark())
        #expect(byPath.conditions.judgmentPoint == .request)
        let hits = RuleHitCounter()
        let decision = atConnect(snapshot(byPath), hits: hits)
        #expect(decision.matches == RuleMatchSummary(revision: 7, ruleIDs: [], total: 0))
        #expect(decision.annotations.isEmpty)
        #expect(hits.connectCount(byPath.id) == 0 && hits.snapshot().isEmpty)
    }

    @Test func ruleWithoutConnectCapableActionIsNotEvaluated() {
        let headers = rule(setHeader)
        let hits = RuleHitCounter()
        let decision = atConnect(snapshot(headers), hits: hits)
        #expect(decision.matches == RuleMatchSummary(revision: 7, ruleIDs: [], total: 0))
        #expect(hits.connectCount(headers.id) == 0 && hits.count(headers.id) == 0)
    }

    @Test func hostPortAndSchemeConditionsReadTheConnectTarget() {
        let all = rule(
            when: [
                row(.host, .hostPattern, "x.com"), row(.port, .equals, "443"), row(.scheme, .equals, "https"),
                row(.method, .equals, "CONNECT"),
            ], mark())
        // The URL of a CONNECT line is its origin with no path (default port left out).
        let byURL = rule(when: [row(.url, .equals, "https://x.com")], comment())
        let decision = atConnect(snapshot(all, byURL))
        #expect(decision.matches.outcomes == [outcome(all.id, .applied), outcome(byURL.id, .applied)])
        // Another host or port: neither matches.
        let other = atConnect(snapshot(all, byURL), target: connectTarget(host: "y.com", port: 8443))
        #expect(other.matches.outcomes.isEmpty)
        #expect(other.annotations.isEmpty)
    }

    @Test func clientAppRowUnknownRecordsAppUnknown() {
        let byApp = rule(when: [row(.clientApp, .equals, "Safari", name: "name")], close())
        let decision = atConnect(snapshot(byApp), facts: ExchangeFacts(app: .unknown))
        #expect(decision.disposition == .proceed)
        #expect(decision.matches.outcomes == [outcome(byApp.id, .appUnknown)])
        // Control: a known app answers.
        let safari = ClientApp(pid: 42, name: "Safari")
        let known = atConnect(snapshot(byApp), facts: ExchangeFacts(app: .known(safari)))
        #expect(known.disposition == .close(.graceful, ruleID: byApp.id))
    }

    @Test func clientIPCondition() {
        let local = rule(when: [row(.clientIP, .startsWith, "192.168.")], mark())
        #expect(atConnect(snapshot(local), facts: ExchangeFacts(clientIP: "192.168.1.20")).annotations.count == 1)
        #expect(atConnect(snapshot(local), facts: ExchangeFacts(clientIP: "10.0.0.1")).annotations.isEmpty)
    }

    @Test func occurrenceRangeApplies() {
        let second = rule(occurrence: .times(2...2), close())
        let hits = RuleHitCounter()
        let first = atConnect(snapshot(second), hits: hits)
        #expect(first.disposition == .proceed)
        #expect(first.matches.outcomes == [outcome(second.id, .occurrenceSkipped)])
        let next = atConnect(snapshot(second), hits: hits)
        #expect(next.disposition == .close(.graceful, ruleID: second.id))
        #expect(hits.connectCount(second.id) == 2)
        // The CONNECT point counts apart from the request point (R4 T7 ruling).
        #expect(hits.count(second.id) == 0)
    }

    @Test func connectDoesNotShiftTheRequestOccurrence() throws {
        let firstOnly = rule(occurrence: .times(1...1), mark())
        let hits = RuleHitCounter()
        #expect(atConnect(snapshot(firstOnly), hits: hits).annotations == [flowMark(rule: firstOnly)])
        #expect(atConnect(snapshot(firstOnly), hits: hits).matches.outcomes == [outcome(firstOnly.id, .occurrenceSkipped)])
        // The request inside the tunnel is still the rule's first occurrence there.
        let request = try RuleEvaluator.request(
            .request(
                HTTPMessageTarget(scheme: "https", host: "x.com", port: 443, method: "GET", pathAndQuery: "/"),
                headers: []),
            snapshot: snapshot(firstOnly), hits: hits, cache: calmCache())
        #expect(request.annotations == [flowMark(rule: firstOnly)])
        #expect(hits.count(firstOnly.id) == 1)
        #expect(hits.connectCount(firstOnly.id) == 2)
        // Resetting a rule clears both counts.
        hits.reset(firstOnly.id)
        #expect(hits.count(firstOnly.id) == 0 && hits.connectCount(firstOnly.id) == 0)
    }

    @Test func skippedByToolConsumesNoHit() {
        let second = rule(occurrence: .times(2...2), noDecrypt, returnTunnel)
        let hits = RuleHitCounter()
        let tunnelled = atConnect(snapshot(second), tool: .tunnel, hits: hits)
        #expect(tunnelled.matches.outcomes == [outcome(second.id, .skippedByTool, 0), outcome(second.id, .skippedByTool, 1)])
        #expect(hits.connectCount(second.id) == 0)
        // The first CONNECT the tools let the rule act on is its first hit.
        #expect(atConnect(snapshot(second), tool: .decrypt, hits: hits).matches.outcomes == [
            outcome(second.id, .occurrenceSkipped)
        ])
        #expect(atConnect(snapshot(second), tool: .decrypt, hits: hits).disposition == .noDecrypt)
        // A rule with an action the tool does not skip still counts.
        let marking = rule(noDecrypt, mark())
        _ = atConnect(snapshot(marking), tool: .tunnel, hits: hits)
        #expect(hits.connectCount(marking.id) == 1)
    }

    @Test func decisionCanBeBuiltByHand() {
        let decision = ConnectRuleDecision(matches: RuleMatchSummary(revision: 1, ruleIDs: [], total: 0))
        #expect(decision.disposition == .proceed && decision.annotations.isEmpty && decision.finalStop == nil)
    }

    @Test func patternAllowanceShared() throws {
        let byRegex = rule(when: [row(.host, .regex, "x\\.com")], mark())
        // The CONNECT point's match takes 5 ms of a 4 ms allowance; nothing is left for the request point.
        let clock = ScriptedClock([0, 5])
        let allowance = RegexAllowance(total: .milliseconds(4), clock: { clock.read() })
        let decision = atConnect(snapshot(byRegex), allowance: allowance)
        #expect(decision.annotations == [flowMark(rule: byRegex)])
        #expect(allowance.remaining == .zero)
        let later = rule(when: [row(.host, .regex, "x\\.com"), row(.path, .equals, "/")], mark())
        let request = try RuleEvaluator.request(
            .request(
                HTTPMessageTarget(scheme: "https", host: "x.com", port: 443, method: "GET", pathAndQuery: "/"),
                headers: []),
            snapshot: snapshot(later), allowance: allowance, cache: calmCache())
        #expect(request.matches.outcomes == [outcome(later.id, .patternTimedOut)])
    }

    @Test func disabledRuleAndGroupSkipped() {
        let group = RuleGroup(name: "off", enabled: false)
        let disabled = rule(enabled: false, close())
        let grouped = rule(groupID: group.id, close())
        let hits = RuleHitCounter()
        let decision = atConnect(snapshot(disabled, grouped, groups: [group]), hits: hits)
        #expect(decision.disposition == .proceed)
        #expect(decision.matches.outcomes.isEmpty)
        #expect(hits.connectCount(disabled.id) == 0 && hits.connectCount(grouped.id) == 0)
    }

    @Test func laterRuleReadsEarlierComment() {
        let writer = rule(comment("tagged", .set))
        let reader = rule(when: [row(.comment, .equals, "tagged")], close())
        let decision = atConnect(snapshot(writer, reader))
        #expect(decision.disposition == .close(.graceful, ruleID: reader.id))
        // Without the writer the reader does not match.
        #expect(atConnect(snapshot(reader)).disposition == .proceed)
    }

    @Test func requestHeaderRowIsUnknownAtConnect() {
        // Validation keeps header rows out of P0 rules; such a row makes the rule judged at the request.
        let byHeader = rule(when: [row(.requestHeader, .equals, "1", name: "X")], close())
        #expect(byHeader.conditions.judgmentPoint == .request)
        #expect(atConnect(snapshot(byHeader)).matches.outcomes.isEmpty)
    }
}
