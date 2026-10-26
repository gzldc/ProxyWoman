import FlowStore
import Foundation
import Testing

@testable import RulesEngine

private func target(host: String = "a.test", path: String = "/v1/items") -> HTTPMessageTarget {
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

// MARK: conditions and actions

private func host(_ value: String) -> ConditionRow { ConditionRow(field: .host, op: .hostPattern, value: value) }
/// One status code, as the editor writes a range of one.
private func status(_ code: Int) -> ConditionRow {
    ConditionRow(field: .statusCode, op: .inRange, value: "\(code)-\(code)")
}

private let red = "#FF3B30"
private let blue = "#007AFF"

private func mark(_ background: String = red, text: String? = nil) -> RuleAction {
    RuleAction(.mark(MarkAction(background: background, text: text)))
}

private func comment(_ text: String = "note", mode: CommentAction.Mode = .append) -> RuleAction {
    RuleAction(.comment(CommentAction(mode: mode, text: text)))
}

private let hide = RuleAction(.hide)

private func setHeader(_ name: String, _ value: String, on direction: HTTPMessageDirection = .request) -> RuleAction {
    RuleAction(.editHeaders(direction: direction, operations: [.set(name: name, value: value)]))
}

private func rule(
    id: UUID = UUID(), name: String = "r", when rows: [ConditionRow] = [], occurrence: Occurrence = .any,
    _ actions: RuleAction...
) -> Rule {
    Rule(
        id: id, name: name, enabled: true, groupID: nil, order: 0,
        conditions: ConditionGroup(mode: .all, occurrence: occurrence, rows: rows), actions: actions)
}

/// Rules are evaluated in the order given (they all have order 0).
private func snapshot(_ rules: Rule...) -> RuleSnapshot { RuleSnapshot(revision: 7, rules: rules) }

private func calmCache() -> PatternCache { PatternCache(budget: RegexBudget(clock: { .zero })) }

private func requestPoint(
    _ head: HTTPMessageHead = request(), _ snapshot: RuleSnapshot, hits: RuleHitCounter? = nil
) throws -> RequestRuleDecision {
    try RuleEvaluator.request(head, snapshot: snapshot, hits: hits, cache: calmCache())
}

/// One exchange: the request point, then the response point with what the request point carried.
private func evaluate(
    _ requestHead: HTTPMessageHead = request(), _ responseHead: HTTPMessageHead = response(),
    _ snapshot: RuleSnapshot, isLocalResponse: Bool = false, hits: RuleHitCounter? = nil
) throws -> (request: RequestRuleDecision, response: ResponseRuleDecision) {
    let p1 = try requestPoint(requestHead, snapshot, hits: hits)
    let p2 = try RuleEvaluator.response(
        responseHead, after: p1, snapshot: snapshot,
        requestWasUpgradeCandidate: HTTPMutationValidator.isUpgradeCandidate(requestHead.headers),
        isLocalResponse: isLocalResponse, hits: hits, cache: calmCache())
    return (p1, p2)
}

private func outcome(_ id: UUID, _ code: RuleOutcomeCode, _ index: Int? = nil) -> RuleOutcome {
    RuleOutcome(ruleID: id, code: code, actionIndex: index)
}

private func pending(_ position: Int, _ id: UUID, _ indices: [Int]) -> RuleCarry.PendingRule {
    RuleCarry.PendingRule(position: position, ruleID: id, actionIndices: indices)
}

private func flowMark(_ background: String = red, text: String? = nil, rule: Rule) -> FlowAnnotation {
    .mark(FlowMark(background: background, text: text, source: .rule(id: rule.id, name: rule.name))!)
}

@Suite("RuleEvaluatorAnnotation")
struct RuleEvaluatorAnnotationTests {
    @Test func markRunsAtTheRequestPointForARequestJudgedRule() throws {
        let marking = rule(name: "Slow API", when: [host("a.test")], mark(text: "slow"))
        let head = request()
        let decision = try requestPoint(head, snapshot(marking))
        #expect(decision.annotations == [flowMark(text: "slow", rule: marking)])
        #expect(decision.matches.outcomes == [outcome(marking.id, .applied)])
        #expect(decision.matches.ruleIDs == [marking.id])
        #expect(decision.rulesModified == false)
        #expect(decision.effectiveHead == head)
        #expect(decision.carry?.pending == [])
    }

    @Test func markWaitsForTheResponseWhenTheRuleHasAStatusRow() throws {
        let marking = rule(when: [status(404)], mark())
        let notFound = try evaluate(request(), response(404), snapshot(marking))
        #expect(notFound.request.annotations == [])
        #expect(notFound.request.matches.outcomes == [])
        #expect(notFound.request.matches.ruleIDs == [])
        #expect(notFound.request.carry?.pending == [])
        #expect(notFound.response.annotations == [flowMark(rule: marking)])
        #expect(notFound.response.matches.outcomes == [outcome(marking.id, .applied)])

        let ok = try evaluate(request(), response(200), snapshot(marking))
        #expect(ok.request.annotations == [])
        #expect(ok.response.annotations == [])
        #expect(ok.response.matches.outcomes == [])
    }

    @Test func colourlessMarkWithStopTickStopsLowerRulesAndIsRecorded() throws {
        for colour in [MarkAction.unchangedColor, MarkAction.defaultColor] {
            let stopping = rule(
                name: "stop", RuleAction(.mark(MarkAction(background: colour)), isFinal: true))
            let below = rule(name: "below", comment("never"))
            let decision = try requestPoint(request(), snapshot(stopping, below))
            // "Default" clears an earlier colour (one annotation); "unchanged" adds nothing.
            #expect(decision.annotations == (colour == MarkAction.defaultColor ? [.resetMark(background: true, foreground: true)] : []))
            #expect(decision.matches.ruleIDs == [stopping.id])
            #expect(decision.matches.outcomes == [outcome(stopping.id, .applied), outcome(stopping.id, .finalStop, 0)])
        }
    }

    @Test func colourlessMarkWithoutStopIsRecordedAndLowerRulesRun() throws {
        let plain = rule(name: "plain", mark(MarkAction.unchangedColor))
        let below = rule(name: "below", comment("seen"))
        let decision = try requestPoint(request(), snapshot(plain, below))
        #expect(decision.annotations == [.comment(CommentAction(mode: .append, text: "seen"))])
        #expect(decision.matches.outcomes == [outcome(plain.id, .applied), outcome(below.id, .applied)])
    }

    @Test func annotationsAreRecordedInRuleOrder() throws {
        let first = rule(name: "first", mark(red))
        let middle = rule(comment("seen"))
        let last = rule(name: "last", mark(blue))
        let decision = try requestPoint(request(), snapshot(first, middle, last))
        #expect(
            decision.annotations == [
                flowMark(red, rule: first), .comment(CommentAction(mode: .append, text: "seen")),
                flowMark(blue, rule: last),
            ])
        #expect(
            decision.matches.outcomes == [
                outcome(first.id, .applied), outcome(middle.id, .applied), outcome(last.id, .applied),
            ])
    }

    @Test func hideIsFinalAndCutsLowerRulesAtBothPoints() throws {
        let hiding = rule(hide)
        let requestEdit = rule(setHeader("X-Req", "1"))
        let responseEdit = rule(setHeader("X-Res", "1", on: .response))
        let head = request()
        let responseHead = response(200)
        let result = try evaluate(head, responseHead, snapshot(hiding, requestEdit, responseEdit))
        #expect(result.request.annotations == [.hide])
        #expect(result.request.effectiveHead == head)
        #expect(result.request.matches.outcomes == [outcome(hiding.id, .applied), outcome(hiding.id, .finalStop, 0)])
        #expect(result.request.carry?.pending == [])
        #expect(result.request.carry?.finalStop == RuleCarry.FinalStop(position: 0, actionIndex: 0))
        #expect(result.response.annotations == [])
        #expect(result.response.effectiveHead == responseHead)
        #expect(result.response.matches.outcomes == [])
    }

    @Test func statusJudgedHideCutsALowerResponseRule() throws {
        let hiding = rule(when: [status(404)], hide)
        let responseEdit = rule(setHeader("X-Res", "1", on: .response))
        let responseHead = response(404)
        let result = try evaluate(request(), responseHead, snapshot(hiding, responseEdit))
        // The hide waits for the status, so the request point only carries the lower rule's edit.
        #expect(result.request.annotations == [])
        #expect(result.request.carry?.pending == [pending(1, responseEdit.id, [0])])
        #expect(result.response.annotations == [.hide])
        #expect(result.response.effectiveHead == responseHead)
        #expect(result.response.matches.outcomes == [outcome(hiding.id, .applied), outcome(hiding.id, .finalStop, 0)])
        #expect(result.response.rulesModified == false)

        // Control: a response the hide does not judge leaves the lower rule's edit applied.
        let other = try evaluate(request(), response(200), snapshot(hiding, responseEdit))
        #expect(other.response.annotations == [])
        #expect(other.response.matches.outcomes == [outcome(responseEdit.id, .applied)])
        #expect(other.response.effectiveHead.headers.contains { $0.name == "X-Res" })
    }

    @Test func hideOfTheLowestRuleRecordsNoFinalStop() throws {
        let edit = rule(setHeader("X-Req", "1"))
        let hiding = rule(hide)
        let decision = try requestPoint(request(), snapshot(edit, hiding))
        #expect(decision.annotations == [.hide])
        #expect(decision.matches.outcomes == [outcome(edit.id, .applied), outcome(hiding.id, .applied)])
        #expect(decision.carry?.finalStop == RuleCarry.FinalStop(position: 1, actionIndex: 0))
    }

    @Test func higherPriorityPendingRuleStillRunsAfterAHide() throws {
        let marking = rule(when: [status(404)], mark())
        let hiding = rule(hide)
        let result = try evaluate(request(), response(404), snapshot(marking, hiding))
        #expect(result.request.annotations == [.hide])
        #expect(result.request.matches.outcomes == [outcome(hiding.id, .applied)])
        #expect(result.response.annotations == [flowMark(rule: marking)])
        #expect(result.response.matches.outcomes == [outcome(marking.id, .applied)])
    }

    @Test func annotationsAfterAFinalActionOfTheSameRuleAreSkipped() throws {
        let both = rule(hide, mark())
        let decision = try requestPoint(request(), snapshot(both))
        #expect(decision.annotations == [.hide])
        #expect(
            decision.matches.outcomes == [
                outcome(both.id, .applied, 0), outcome(both.id, .finalStop, 0), outcome(both.id, .skippedAfterFinal, 1),
            ])
    }

    @Test func annotationsBeforeAFinalHideStayApplied() throws {
        let both = rule(mark(), hide)
        let decision = try requestPoint(request(), snapshot(both))
        #expect(decision.annotations == [flowMark(rule: both), .hide])
        #expect(decision.matches.outcomes == [outcome(both.id, .applied, 0), outcome(both.id, .applied, 1)])
    }

    @Test func annotationsAreNotPendingResponseWork() throws {
        let mixed = rule(mark(), setHeader("X-Res", "1", on: .response))
        let result = try evaluate(request(), response(200), snapshot(mixed))
        #expect(result.request.annotations == [flowMark(rule: mixed)])
        #expect(result.request.matches.outcomes == [outcome(mixed.id, .applied, 0)])
        #expect(result.request.carry?.pending == [pending(0, mixed.id, [1])])
        #expect(result.response.annotations == [])
        #expect(result.response.matches.outcomes == [outcome(mixed.id, .applied, 1)])
        #expect(result.response.effectiveHead.headers == [HeaderField(name: "X-Res", value: "1")])
    }

    @Test func rejectedEditStillReportsEarlierAnnotations() {
        let marking = rule(mark())
        let bad = rule(setHeader("Content-Length", "1"))
        let never = rule(comment())
        do {
            _ = try requestPoint(request(), snapshot(marking, bad, never))
            Issue.record("expected a rule evaluation failure")
        } catch let error as RuleEvaluationError {
            #expect(error.mutation == HTTPMutationError(code: .protectedHeader, field: .header(name: "Content-Length")))
            #expect(error.annotations == [flowMark(rule: marking)])
            #expect(error.matches.ruleIDs == [marking.id, bad.id])
            #expect(error.matches.outcomes == [outcome(marking.id, .applied), outcome(bad.id, .rejected)])
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func rejectedResponseEditStillReportsEarlierAnnotations() throws {
        let marking = rule(when: [status(200)], mark())
        let bad = rule(when: [status(200)], setHeader("Content-Length", "1", on: .response))
        let rules = snapshot(marking, bad)
        let p1 = try requestPoint(request(), rules)
        do {
            _ = try RuleEvaluator.response(response(200), after: p1, snapshot: rules, cache: calmCache())
            Issue.record("expected a rule evaluation failure")
        } catch let error as RuleEvaluationError {
            #expect(error.annotations == [flowMark(rule: marking)])
            #expect(error.matches.outcomes == [outcome(marking.id, .applied), outcome(bad.id, .rejected)])
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func occurrenceRangeAppliesToAnnotations() throws {
        let secondOnly = rule(occurrence: .times(2...2), mark())
        let rules = snapshot(secondOnly)
        let hits = RuleHitCounter()
        let first = try requestPoint(request(), rules, hits: hits)
        #expect(first.annotations == [])
        #expect(first.matches.outcomes == [outcome(secondOnly.id, .occurrenceSkipped)])
        let second = try requestPoint(request(), rules, hits: hits)
        #expect(second.annotations == [flowMark(rule: secondOnly)])
        #expect(second.matches.outcomes == [outcome(secondOnly.id, .applied)])
    }

    @Test func upgradeRequestRunsAnnotationsNormally() throws {
        let all = rule(mark(), comment(), hide)
        let decision = try requestPoint(request(headers: upgradeHeaders), snapshot(all))
        #expect(decision.annotations == [flowMark(rule: all), .comment(CommentAction(text: "note")), .hide])
        #expect(
            decision.matches.outcomes == [
                outcome(all.id, .applied, 0), outcome(all.id, .applied, 1), outcome(all.id, .applied, 2),
            ])

        // At the response point of an upgrade too.
        let late = rule(when: [status(101)], mark(), comment(), hide)
        let result = try evaluate(request(headers: upgradeHeaders), response(101), snapshot(late))
        #expect(result.response.annotations == [flowMark(rule: late), .comment(CommentAction(text: "note")), .hide])
        #expect(
            result.response.matches.outcomes == [
                outcome(late.id, .applied, 0), outcome(late.id, .applied, 1), outcome(late.id, .applied, 2),
            ])
    }

    @Test func annotationsNeverMarkTheExchangeAsModified() throws {
        let early = rule(mark(), comment(), hide)
        let requestSide = try evaluate(request(), response(200), snapshot(early))
        #expect(requestSide.request.rulesModified == false)
        #expect(requestSide.response.rulesModified == false)

        let late = rule(when: [status(200)], mark(), comment(), hide)
        let responseSide = try evaluate(request(), response(200), snapshot(late))
        #expect(responseSide.response.annotations.count == 3)
        #expect(responseSide.request.rulesModified == false)
        #expect(responseSide.response.rulesModified == false)
    }

    @Test func singleActionRuleHasNilActionIndexAndMultiActionIsLabelled() throws {
        let single = rule(comment())
        let multi = rule(comment("a"), comment("b"))
        let decision = try requestPoint(request(), snapshot(single, multi))
        #expect(
            decision.matches.outcomes == [
                outcome(single.id, .applied), outcome(multi.id, .applied, 0), outcome(multi.id, .applied, 1),
            ])
    }

    @Test func localResponseRunsResponseJudgedAnnotations() throws {
        let marking = rule(when: [status(200)], mark())
        let result = try evaluate(request(), response(200), snapshot(marking), isLocalResponse: true)
        #expect(result.response.annotations == [flowMark(rule: marking)])
        #expect(result.response.matches.outcomes == [outcome(marking.id, .applied)])
    }

    @Test func legacyKindsNeverProduceAnnotations() throws {
        let file = MapLocalAction(assetID: UUID(), headers: [])
        let directory = MapLocalDirectoryAction(bookmark: Data([1]), displayName: "site")
        let kinds: [ActionKind] = [
            .returnFile(file),
            .returnDirectory(directory, pathPrefix: "/files/"),
            .mapRemote(
                MapRemoteAction(
                    targetScheme: "https", targetHost: "b.test", targetPort: 443, path: .preserve,
                    preserveCredentials: false)),
            .editHeaders(direction: .request, operations: [.set(name: "X", value: "1")]),
            .breakpoint(direction: .request, mode: .headers),
            .rewriteBody(direction: .request, BodyRewriteAction(find: "a", replacement: "z")),
            .rewriteStatus(RewriteStatusAction(status: 201)),
        ]
        for kind in kinds {
            let result = try evaluate(request(), response(200), snapshot(rule(RuleAction(kind))))
            #expect(result.request.annotations == [], "\(kind)")
            #expect(result.response.annotations == [], "\(kind)")
        }
    }

    @Test func mismatchedCarryReturnsNoAnnotations() throws {
        let late = rule(when: [status(200)], mark())
        let rules = snapshot(late)
        let p1 = try requestPoint(request(), rules)
        let other = RuleSnapshot(revision: 8, rules: [late])
        var reported: [String] = []
        let decision = try RuleEvaluator.response(response(200), after: p1, snapshot: other, cache: calmCache()) {
            reported.append($0)
        }
        #expect(reported.count == 1)
        #expect(decision.annotations == [])
        #expect(decision.matches.outcomes == [])
    }

    @Test func invalidMarkColourInAnUnvalidatedSnapshotIsSkippedWithoutFailing() throws {
        let broken = rule(mark("red"), comment("kept"))
        let next = rule(mark(blue))
        let decision = try requestPoint(request(), snapshot(broken, next))
        #expect(decision.annotations == [.comment(CommentAction(text: "kept")), flowMark(blue, rule: next)])
        #expect(decision.matches.outcomes == [outcome(broken.id, .applied, 1), outcome(next.id, .applied)])

        let alone = rule(RuleAction(.mark(MarkAction(background: red, foreground: "#12"))))
        let silent = try requestPoint(request(), snapshot(alone))
        #expect(silent.annotations == [])
        #expect(silent.matches.outcomes == [])
        #expect(silent.matches.ruleIDs == [])
    }
}
