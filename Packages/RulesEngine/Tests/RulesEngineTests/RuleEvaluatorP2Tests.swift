import FlowStore
import Foundation
import Testing

@testable import RulesEngine

/// `/(a|aa)+c` never finishes on this path under the stepping clock.
private let slowPathRegex = "/(a|aa)+c"
private let slowPath = "/" + String(repeating: "a", count: 60) + "b"

private func target(
    host: String = "a.test", scheme: String = "https", port: Int = 443, method: String = "GET",
    path: String = "/v1/items?a=1"
) -> HTTPMessageTarget {
    HTTPMessageTarget(scheme: scheme, host: host, port: port, method: method, pathAndQuery: path)
}

private func request(_ target: HTTPMessageTarget = target(), headers: [HeaderField] = []) -> HTTPMessageHead {
    .request(target, headers: headers)
}

private func response(_ status: Int = 200, reason: String? = "OK", headers: [HeaderField] = []) -> HTTPMessageHead {
    .response(status: status, reason: reason, headers: headers)
}

private let upgradeHeaders = [
    HeaderField(name: "Connection", value: "Upgrade"), HeaderField(name: "Upgrade", value: "websocket"),
    HeaderField(name: "Sec-WebSocket-Key", value: "k"),
]

private let switchingHeaders = [
    HeaderField(name: "Connection", value: "Upgrade"), HeaderField(name: "Upgrade", value: "websocket"),
]

private let textHeaders = [HeaderField(name: "Content-Type", value: "text/plain")]

// MARK: conditions

private func host(_ value: String) -> ConditionRow { ConditionRow(field: .host, op: .hostPattern, value: value) }
private func status(_ value: String) -> ConditionRow { ConditionRow(field: .statusCode, op: .inRange, value: value) }
private func pathRegex(_ value: String) -> ConditionRow {
    ConditionRow(field: .pathAndQuery, op: .regexWhole, value: value, caseSensitive: true)
}

// MARK: actions (response side unless told otherwise)

private let localFile = MapLocalAction(assetID: UUID(uuidString: "00000000-0000-0000-0000-00000000F11E")!, headers: [])

private func setHeader(
    _ name: String, _ value: String, on direction: HTTPMessageDirection = .response, final: Bool = false
) -> RuleAction {
    RuleAction(.editHeaders(direction: direction, operations: [.set(name: name, value: value)]), isFinal: final)
}

private func appendHeader(_ name: String, _ value: String) -> RuleAction {
    RuleAction(.editHeaders(direction: .response, operations: [.append(name: name, value: value)]))
}

private func pause(
    _ direction: HTTPMessageDirection = .response, _ mode: BreakpointPauseMode = .headers, final: Bool = false
) -> RuleAction {
    RuleAction(.breakpoint(direction: direction, mode: mode), isFinal: final)
}

private func rewriteStatus(_ status: Int, includeLocal: Bool = false, final: Bool = false) -> RuleAction {
    RuleAction(
        .rewriteStatus(RewriteStatusAction(status: status, includeLocalResponses: includeLocal)), isFinal: final)
}

private func body(_ find: String = "a") -> BodyRewriteAction { BodyRewriteAction(find: find, replacement: "z") }

private func rewriteBody(find: String = "a", final: Bool = false) -> RuleAction {
    RuleAction(.rewriteBody(direction: .response, body(find)), isFinal: final)
}

private func returnFile() -> RuleAction { RuleAction(.returnFile(localFile)) }

private func mapRemote(_ host: String) -> RuleAction {
    RuleAction(
        .mapRemote(
            MapRemoteAction(targetScheme: "https", targetHost: host, targetPort: 443, path: .preserve)))
}

// MARK: rules and evaluation

private func rule(
    id: UUID = UUID(), enabled: Bool = true, when rows: [ConditionRow] = [], occurrence: Occurrence = .any,
    _ actions: RuleAction...
) -> Rule {
    Rule(
        id: id, name: "r", enabled: enabled, order: 0,
        conditions: ConditionGroup(mode: .all, occurrence: occurrence, rows: rows), actions: actions)
}

/// Rules are evaluated in the order given (they all have order 0).
private func snapshot(_ rules: Rule...) -> RuleSnapshot {
    RuleSnapshot(revision: 7, rules: rules)
}

private func calmCache() -> PatternCache { PatternCache(budget: RegexBudget(clock: { .zero })) }

/// One exchange: the request point, then the response point with what the request point carried.
/// Like ProxyCore, the upgrade flag of the response point comes from the client's request headers.
private func evaluate(
    _ requestHead: HTTPMessageHead = request(), _ responseHead: HTTPMessageHead = response(),
    _ snapshot: RuleSnapshot, isLocalResponse: Bool = false, hits: RuleHitCounter? = nil,
    cache: PatternCache = calmCache()
) throws -> (request: RequestRuleDecision, response: ResponseRuleDecision) {
    let p1 = try RuleEvaluator.request(requestHead, snapshot: snapshot, hits: hits, cache: cache)
    let p2 = try RuleEvaluator.response(
        responseHead, after: p1, snapshot: snapshot,
        requestWasUpgradeCandidate: HTTPMutationValidator.isUpgradeCandidate(requestHead.headers),
        isLocalResponse: isLocalResponse, hits: hits, cache: cache)
    return (p1, p2)
}

private func outcome(_ id: UUID, _ code: RuleOutcomeCode, _ index: Int? = nil) -> RuleOutcome {
    RuleOutcome(ruleID: id, code: code, actionIndex: index)
}

private func pending(_ position: Int, _ id: UUID, _ indices: [Int]) -> RuleCarry.PendingRule {
    RuleCarry.PendingRule(position: position, ruleID: id, actionIndices: indices)
}

private func expectFailure(
    _ mutation: HTTPMutationError, ruleIDs: [UUID], outcomes: [RuleOutcome],
    sourceLocation: SourceLocation = #_sourceLocation, _ operation: () throws -> ResponseRuleDecision
) {
    do {
        _ = try operation()
        Issue.record("expected a rule evaluation failure", sourceLocation: sourceLocation)
    } catch let error as RuleEvaluationError {
        #expect(error.mutation == mutation, sourceLocation: sourceLocation)
        #expect(error.matches.ruleIDs == ruleIDs, sourceLocation: sourceLocation)
        #expect(error.matches.total == ruleIDs.count, sourceLocation: sourceLocation)
        #expect(error.matches.outcomes == outcomes, sourceLocation: sourceLocation)
    } catch {
        Issue.record("unexpected error: \(error)", sourceLocation: sourceLocation)
    }
}

@Suite("RuleEvaluatorP2")
struct RuleEvaluatorP2Tests {
    @Test func emptySnapshotLeavesTheResponseUntouched() throws {
        let head = response(200, reason: "OK", headers: [HeaderField(name: "Server", value: "x")])
        let requestOnly = rule(setHeader("X", "1", on: .request))
        for rules in [snapshot(), snapshot(rule(enabled: false, setHeader("X", "1"))), snapshot(requestOnly)] {
            let (_, decision) = try evaluate(request(), head, rules)
            #expect(decision.effectiveHead == head)
            #expect(decision.breakpoint == nil)
            #expect(decision.bodyRewrites.isEmpty)
            #expect(decision.statusRewrite == nil)
            #expect(!decision.matches.hasRecords)
            #expect(decision.matches.revision == 7)
            #expect(decision.rulesModified == false)
        }
    }

    @Test func wrongMessageKindFailsAtP2() throws {
        let p1 = try RuleEvaluator.request(request(), snapshot: snapshot())
        #expect(throws: HTTPMutationError(code: .messageKindMismatch, field: .message)) {
            try RuleEvaluator.response(request(), after: p1, snapshot: snapshot())
        }
    }

    @Test func responseRulesReadTheRequestAfterEveryP1Action() throws {
        let move = rule(mapRemote("b.test"))
        let oldHost = rule(when: [host("a.test")], setHeader("X-Old", "1"))
        let newHost = rule(when: [host("b.test")], setHeader("X-New", "1"))
        let (p1, p2) = try evaluate(request(target(host: "a.test")), response(), snapshot(move, oldHost, newHost))
        #expect(p1.carry?.pending == [pending(2, newHost.id, [0])])
        #expect(p2.effectiveHead.headers.values(for: "X-Old").isEmpty)
        #expect(p2.effectiveHead.headers.values(for: "X-New") == ["1"])
        #expect(p2.matches.ruleIDs == [newHost.id])
        #expect(p2.matches.outcomes == [outcome(newHost.id, .applied)])

        // A rule judged at the response point reads the same, moved request.
        let oldRanged = rule(when: [host("a.test"), status("200-299")], setHeader("X-Old-Ranged", "1"))
        let newRanged = rule(when: [host("b.test"), status("200-299")], setHeader("X-New-Ranged", "1"))
        let (_, ranged) = try evaluate(
            request(target(host: "a.test")), response(), snapshot(move, oldRanged, newRanged))
        #expect(ranged.matches.outcomes == [outcome(newRanged.id, .applied)])
        #expect(ranged.effectiveHead.headers.values(for: "X-New-Ranged") == ["1"])
        #expect(ranged.effectiveHead.headers.values(for: "X-Old-Ranged").isEmpty)
    }

    @Test func statusRangeReadsTheStatusAfterEarlierRewrites() throws {
        let toError = rule(rewriteStatus(500))
        let errors = rule(when: [status("500-599")], setHeader("X-Error", "1"))
        let successes = rule(when: [status("200-299")], setHeader("X-Ok", "1"))
        let (_, decision) = try evaluate(request(), response(200), snapshot(toError, errors, successes))
        #expect(decision.statusRewrite == 500)
        #expect(
            decision.effectiveHead
                == .response(status: 500, reason: nil, headers: [HeaderField(name: "X-Error", value: "1")]))
        #expect(decision.matches.outcomes == [outcome(toError.id, .applied), outcome(errors.id, .applied)])
        #expect(decision.matches.ruleIDs == [toError.id, errors.id])

        // A ranged rule above the rewrite still reads the status as it arrived.
        let (_, above) = try evaluate(request(), response(200), snapshot(successes, toError, errors))
        #expect(
            above.matches.outcomes == [
                outcome(successes.id, .applied), outcome(toError.id, .applied), outcome(errors.id, .applied),
            ])
        #expect(above.effectiveHead.headers.values(for: "X-Ok") == ["1"])
        #expect(above.effectiveHead.headers.values(for: "X-Error") == ["1"])
    }

    @Test func secondStatusRewriteOverridesTheFirst() throws {
        let first = rule(rewriteStatus(500))
        let second = rule(rewriteStatus(404))
        let (_, decision) = try evaluate(request(), response(200), snapshot(first, second))
        #expect(decision.matches.outcomes == [outcome(first.id, .applied), outcome(second.id, .applied)])
        #expect(decision.statusRewrite == 404)
        #expect(decision.effectiveHead == .response(status: 404, reason: nil, headers: []))

        // Each rewrite reads what the one before it left.
        let onlyAfterFirst = rule(when: [status("500-500")], rewriteStatus(503))
        let (_, chained) = try evaluate(request(), response(200), snapshot(first, onlyAfterFirst))
        #expect(chained.statusRewrite == 503)
        #expect(chained.matches.outcomes == [outcome(first.id, .applied), outcome(onlyAfterFirst.id, .applied)])
    }

    @Test func statusRewriteIsSkippedForALocalResponseUnlessIncluded() throws {
        let skipped = rule(rewriteStatus(500))
        let reader = rule(when: [status("200-299")], setHeader("X-Still-200", "1"))
        let (_, local) = try evaluate(
            request(), response(200, reason: "OK"), snapshot(skipped, reader), isLocalResponse: true)
        #expect(local.matches.outcomes == [outcome(skipped.id, .statusSkippedLocal), outcome(reader.id, .applied)])
        #expect(local.statusRewrite == nil)
        #expect(
            local.effectiveHead
                == .response(status: 200, reason: "OK", headers: [HeaderField(name: "X-Still-200", value: "1")]))

        let included = rule(rewriteStatus(503, includeLocal: true))
        let (_, opted) = try evaluate(
            request(), response(200), snapshot(skipped, included, reader), isLocalResponse: true)
        #expect(opted.matches.outcomes == [outcome(skipped.id, .statusSkippedLocal), outcome(included.id, .applied)])
        #expect(opted.statusRewrite == 503)
        #expect(opted.effectiveHead == .response(status: 503, reason: nil, headers: []))

        // From the origin the same rule applies, and the ranged rule then reads 500.
        let (_, origin) = try evaluate(request(), response(200), snapshot(skipped, reader))
        #expect(origin.matches.outcomes == [outcome(skipped.id, .applied)])
        #expect(origin.statusRewrite == 500)

        // A skipped rewrite ran nothing, so even ticked final it stops nothing.
        let tickedSkipped = rule(rewriteStatus(500, final: true))
        let (_, notFinal) = try evaluate(
            request(), response(200), snapshot(tickedSkipped, reader), isLocalResponse: true)
        #expect(
            notFinal.matches.outcomes == [
                outcome(tickedSkipped.id, .statusSkippedLocal), outcome(reader.id, .applied),
            ])
    }

    @Test func higherPriorityResponseRulesRunOnTheLocalResponseButLowerOnesDoNot() throws {
        let hits = RuleHitCounter()
        let higher = rule(setHeader("X-A", "1"))
        let local = rule(returnFile())
        let lower = rule(setHeader("X-C", "1"))
        let (p1, p2) = try evaluate(
            request(), response(200), snapshot(higher, local, lower), isLocalResponse: true, hits: hits)
        #expect(p1.matches.outcomes == [outcome(local.id, .applied), outcome(local.id, .finalStop, 0)])
        #expect(p2.matches.outcomes == [outcome(higher.id, .applied)])
        #expect(p2.matches.ruleIDs == [higher.id])
        #expect(p2.effectiveHead.headers.values(for: "X-A") == ["1"])
        #expect(p2.effectiveHead.headers.values(for: "X-C").isEmpty)
        #expect(hits.snapshot() == [higher.id: 1, local.id: 1])

        // A lower rule judged at the response point is not even evaluated.
        let ranged = rule(when: [status("200-299")], setHeader("X-R", "1"))
        let (_, decision) = try evaluate(
            request(), response(200), snapshot(higher, local, ranged), isLocalResponse: true, hits: hits)
        #expect(decision.matches.outcomes == [outcome(higher.id, .applied)])
        #expect(hits.count(ranged.id) == 0)
    }

    @Test func responseActionsBeforeAFinalActionRunAndLaterOnesAreSkippedAfterFinal() throws {
        let r = rule(rewriteStatus(500, includeLocal: true), returnFile(), setHeader("X-After", "1"))
        let (p1, p2) = try evaluate(request(), response(200), snapshot(r), isLocalResponse: true)
        #expect(
            p1.matches.outcomes == [
                outcome(r.id, .applied, 1), outcome(r.id, .finalStop, 1), outcome(r.id, .skippedAfterFinal, 2),
            ])
        #expect(p1.carry?.pending == [pending(0, r.id, [0])])
        #expect(p2.matches.outcomes == [outcome(r.id, .applied, 0)])
        #expect(p2.matches.ruleIDs == [r.id])
        #expect(p2.statusRewrite == 500)
        #expect(p2.effectiveHead.headers.values(for: "X-After").isEmpty)
    }

    @Test func finalFlaggedResponseActionStopsLowerPendingWork() throws {
        let hits = RuleHitCounter()
        let first = rule(setHeader("X-1", "1"), setHeader("X-Final", "1", final: true), pause(), rewriteStatus(500))
        let pendingLower = rule(setHeader("X-Lower", "1"))
        let rangedLower = rule(when: [status("200-299")], setHeader("X-Ranged", "1"))
        let (p1, p2) = try evaluate(
            request(), response(200), snapshot(first, pendingLower, rangedLower), hits: hits)
        #expect(p1.carry?.pending == [pending(0, first.id, [0, 1, 2, 3]), pending(1, pendingLower.id, [0])])
        #expect(p1.carry?.finalStop == nil)
        #expect(
            p2.matches.outcomes == [
                outcome(first.id, .applied, 0), outcome(first.id, .applied, 1), outcome(first.id, .finalStop, 1),
                outcome(first.id, .skippedAfterFinal, 2), outcome(first.id, .skippedAfterFinal, 3),
            ])
        #expect(p2.matches.ruleIDs == [first.id])
        #expect(p2.breakpoint == nil)
        #expect(p2.statusRewrite == nil)
        #expect(p2.effectiveHead.headers.values(for: "X-Final") == ["1"])
        #expect(p2.effectiveHead.headers.values(for: "X-Lower").isEmpty)
        #expect(p2.effectiveHead.headers.values(for: "X-Ranged").isEmpty)
        // The pending rule was counted where it was judged; the ranged one was never evaluated.
        #expect(hits.snapshot() == [first.id: 1, pendingLower.id: 1])

        // A rule judged at the response point can stop the rules below it too.
        let rangedFinal = rule(when: [status("200-299")], setHeader("X-RF", "1", final: true))
        let (_, decision) = try evaluate(request(), response(200), snapshot(rangedFinal, pendingLower))
        #expect(
            decision.matches.outcomes == [outcome(rangedFinal.id, .applied), outcome(rangedFinal.id, .finalStop, 0)])
        #expect(decision.effectiveHead.headers.values(for: "X-Lower").isEmpty)
    }

    /// A response-side final action fires at the response point, after the request point already ran
    /// the request-side actions that follow it in the rule and in lower rules. It cannot undo those:
    /// it only stops the response-side work still to come (spec 5.5.4: nothing after it in execution
    /// order runs).
    @Test func finalResponseActionDoesNotStopRequestActionsThatAlreadyRan() throws {
        let r = rule(setHeader("X-Final", "1", final: true), setHeader("X-Req", "1", on: .request))
        let lower = rule(setHeader("X-L", "1", on: .request), setHeader("X-LR", "1"))
        let (p1, p2) = try evaluate(request(), response(200), snapshot(r, lower))
        #expect(p1.matches.outcomes == [outcome(r.id, .applied, 1), outcome(lower.id, .applied, 0)])
        #expect(p1.effectiveHead.headers.values(for: "X-Req") == ["1"])
        #expect(p1.effectiveHead.headers.values(for: "X-L") == ["1"])
        #expect(p1.carry?.finalStop == nil)
        #expect(p1.carry?.pending == [pending(0, r.id, [0]), pending(1, lower.id, [1])])
        // The request action after the final one ran at P1, so it is not reported as skipped.
        #expect(p2.matches.outcomes == [outcome(r.id, .applied, 0), outcome(r.id, .finalStop, 0)])
        #expect(p2.effectiveHead.headers.values(for: "X-Final") == ["1"])
        #expect(p2.effectiveHead.headers.values(for: "X-LR").isEmpty)
    }

    @Test func finalStopAtP2IsRecordedOnlyWhenItCutsSomething() throws {
        // Nothing follows: no record.
        let alone = rule(setHeader("X", "1", final: true))
        let (_, single) = try evaluate(request(), response(200), snapshot(alone))
        #expect(single.matches.outcomes == [outcome(alone.id, .applied)])

        // The rule already stopped everything below it at the request point; its earlier response
        // action, final as well, cuts nothing new.
        let stopped = rule(rewriteStatus(500, includeLocal: true, final: true), returnFile())
        let below = rule(setHeader("X-Below", "1"))
        let (p1, p2) = try evaluate(request(), response(200), snapshot(stopped, below), isLocalResponse: true)
        #expect(p1.carry?.finalStop == RuleCarry.FinalStop(position: 0, actionIndex: 1))
        #expect(p1.matches.outcomes == [outcome(stopped.id, .applied, 1), outcome(stopped.id, .finalStop, 1)])
        #expect(p2.matches.outcomes == [outcome(stopped.id, .applied, 0)])
        #expect(p2.statusRewrite == 500)

        // A later pending action of the same rule is cut.
        let twoPending = rule(rewriteStatus(500, includeLocal: true, final: true), setHeader("X-2", "1"), returnFile())
        let (_, cut) = try evaluate(request(), response(200), snapshot(twoPending), isLocalResponse: true)
        #expect(
            cut.matches.outcomes == [
                outcome(twoPending.id, .applied, 0), outcome(twoPending.id, .finalStop, 0),
                outcome(twoPending.id, .skippedAfterFinal, 1),
            ])
        #expect(cut.effectiveHead.headers.values(for: "X-2").isEmpty)

        // As at the request point, a ticked body rewrite is final as a candidate, even when the
        // message-level checks then skip it.
        let finalBody = rule(rewriteBody(final: true))
        let below2 = rule(setHeader("X-Below", "1"))
        let (_, noBody) = try evaluate(request(), response(204, headers: textHeaders), snapshot(finalBody, below2))
        #expect(
            noBody.matches.outcomes == [
                outcome(finalBody.id, .bodySkippedNoBody), outcome(finalBody.id, .finalStop, 0),
            ])
        #expect(noBody.effectiveHead.headers.values(for: "X-Below").isEmpty)
    }

    /// The response point trusts the carry: rules past the request point's stop never run, and the
    /// stopped rule itself only runs its response actions from before the final one.
    @Test func carryBoundaryLimitsTheStoppedRule() throws {
        let stopped = rule(setHeader("X-0", "1"), returnFile(), setHeader("X-2", "1"))
        let below = rule(setHeader("X-Below", "1"))
        let rules = snapshot(stopped, below)
        let handBuilt = RequestRuleDecision(
            effectiveHead: request(), route: .local(localFile), breakpoint: nil,
            matches: RuleMatchSummary(revision: 7, ruleIDs: [], total: 0),
            carry: RuleCarry(
                target: target(), pending: [pending(0, stopped.id, [0, 2]), pending(1, below.id, [0])],
                finalStop: RuleCarry.FinalStop(position: 0, actionIndex: 1)))
        let decision = try RuleEvaluator.response(
            response(200), after: handBuilt, snapshot: rules, isLocalResponse: true, cache: calmCache())
        #expect(decision.matches.outcomes == [outcome(stopped.id, .applied, 0)])
        #expect(decision.effectiveHead.headers == [HeaderField(name: "X-0", value: "1")])
    }

    /// A request decision of another snapshot (another revision, or pending work that names rules or
    /// actions this snapshot does not have at those places) is a programming error. Debug builds stop
    /// at an assertion in the public entry; the internal entry takes that reaction as a parameter, so
    /// the release-build fallback is reached here: nothing runs, nothing is recorded or counted.
    @Test func requestDecisionOfAnotherSnapshotRunsNothing() throws {
        let edit = rule(setHeader("X", "1"))
        let ranged = rule(when: [status("200-299")], setHeader("Y", "1"))
        let rules = snapshot(edit, ranged)
        let head = response(200, reason: "OK", headers: [HeaderField(name: "Server", value: "s")])
        let p1 = try RuleEvaluator.request(request(), snapshot: rules, cache: calmCache())
        let otherRevision = RuleSnapshot(revision: 8, rules: [edit, ranged])
        let otherRulesSameRevision = snapshot(ranged, edit)
        let shortRule = Rule(id: edit.id, name: "r", actions: [])
        let missingAction = snapshot(shortRule, ranged)
        for other in [otherRevision, otherRulesSameRevision, missingAction] {
            var reported: [String] = []
            let hits = RuleHitCounter()
            let decision = try RuleEvaluator.response(
                head, after: p1, snapshot: other, hits: hits, cache: calmCache()
            ) { reported.append($0) }
            #expect(reported.count == 1)
            #expect(
                decision
                    == ResponseRuleDecision(
                        effectiveHead: head, breakpoint: nil,
                        matches: RuleMatchSummary(revision: other.revision, ruleIDs: [], total: 0)))
            #expect(hits.snapshot().isEmpty)
        }

        // The decision of this snapshot passes the check.
        var reported: [String] = []
        let decision = try RuleEvaluator.response(head, after: p1, snapshot: rules, cache: calmCache()) {
            reported.append($0)
        }
        #expect(reported.isEmpty)
        #expect(decision.matches.outcomes == [outcome(edit.id, .applied), outcome(ranged.id, .applied)])
    }

    @Test func requestDecisionWithoutCarryRunsNothing() throws {
        let rules = snapshot(rule(setHeader("X", "1")), rule(when: [status("200-299")], setHeader("Y", "1")))
        let head = response(200)
        var withoutCarry = try RuleEvaluator.request(request(), snapshot: rules, cache: calmCache())
        withoutCarry.carry = nil
        var reported: [String] = []
        let hits = RuleHitCounter()
        let decision = try RuleEvaluator.response(
            head, after: withoutCarry, snapshot: rules, hits: hits, cache: calmCache()
        ) { reported.append($0) }
        #expect(reported.count == 1)
        #expect(
            decision
                == ResponseRuleDecision(
                    effectiveHead: head, breakpoint: nil, matches: RuleMatchSummary(revision: 7, ruleIDs: [], total: 0))
        )
        #expect(hits.snapshot().isEmpty)
        // A response head is still required first.
        #expect(throws: HTTPMutationError(code: .messageKindMismatch, field: .message)) {
            try RuleEvaluator.response(request(), after: withoutCarry, snapshot: rules) { _ in }
        }
    }

    @Test func p1JudgedResponseRuleIsNotReevaluatedAtP2() throws {
        let hits = RuleHitCounter()
        let cors = rule(when: [host("a.test")], setHeader("X-Cors", "1"))
        let move = rule(mapRemote("b.test"))
        let (p1, p2) = try evaluate(request(target(host: "a.test")), response(), snapshot(cors, move), hits: hits)
        #expect(p1.carry?.target.host == "b.test")
        #expect(p1.carry?.pending == [pending(0, cors.id, [0])])
        // Judged at the request point on a.test; the request now goes to b.test, and it still runs.
        #expect(p2.matches.outcomes == [outcome(cors.id, .applied)])
        #expect(p2.effectiveHead.headers.values(for: "X-Cors") == ["1"])
        #expect(hits.snapshot() == [cors.id: 1, move.id: 1])

        // An occurrence range is applied once, at the request point.
        let once = rule(occurrence: .times(1...1), setHeader("X-Once", "1"))
        let (_, first) = try evaluate(request(), response(), snapshot(once), hits: hits)
        #expect(first.matches.outcomes == [outcome(once.id, .applied)])
        let (secondP1, second) = try evaluate(request(), response(), snapshot(once), hits: hits)
        #expect(secondP1.matches.outcomes == [outcome(once.id, .occurrenceSkipped)])
        #expect(!second.matches.hasRecords)
        #expect(hits.count(once.id) == 2)
    }

    @Test func p2JudgedRuleCountsAHitAtP2AndHonoursOccurrence() throws {
        let hits = RuleHitCounter()
        let r = rule(when: [status("500-599")], occurrence: .times(2...2), setHeader("X-Second", "1"))
        let (missP1, miss) = try evaluate(request(), response(200), snapshot(r), hits: hits)
        #expect(!missP1.matches.hasRecords)
        #expect(!miss.matches.hasRecords)
        #expect(hits.count(r.id) == 0)

        let expected: [[RuleOutcome]] = [
            [outcome(r.id, .occurrenceSkipped)], [outcome(r.id, .applied)], [outcome(r.id, .occurrenceSkipped)],
        ]
        for (call, outcomes) in expected.enumerated() {
            let (p1, p2) = try evaluate(request(), response(503), snapshot(r), hits: hits)
            #expect(!p1.matches.hasRecords, "hit \(call + 1)")
            #expect(hits.count(r.id) == call + 1)
            #expect(p2.matches.outcomes == outcomes, "hit \(call + 1)")
            #expect(p2.matches.ruleIDs == [r.id], "hit \(call + 1)")
            #expect(p2.effectiveHead.headers.values(for: "X-Second") == (call == 1 ? ["1"] : []))
        }

        // Without a counter the occurrence range is ignored.
        let (_, free) = try evaluate(request(), response(503), snapshot(r))
        #expect(free.matches.outcomes == [outcome(r.id, .applied)])
    }

    @Test func upgradeResponseSkipsBreakpointAndStatusRewrite() throws {
        let paused = rule(pause(.response, .fullBody))
        let statusRule = rule(rewriteStatus(500, includeLocal: true))
        let edit = rule(setHeader("X-T", "1"))
        let bodyRule = rule(rewriteBody())
        let switching = response(101, reason: "Switching Protocols", headers: switchingHeaders)
        let (_, decision) = try evaluate(
            request(headers: upgradeHeaders), switching, snapshot(paused, statusRule, edit, bodyRule))
        #expect(
            decision.matches.outcomes == [
                outcome(paused.id, .unsupportedUpgradeAction), outcome(statusRule.id, .unsupportedUpgradeAction),
                outcome(edit.id, .applied), outcome(bodyRule.id, .unsupportedUpgradeAction),
            ])
        #expect(decision.breakpoint == nil)
        #expect(decision.statusRewrite == nil)
        #expect(decision.bodyRewrites.isEmpty)
        #expect(
            decision.effectiveHead
                == .response(
                    status: 101, reason: "Switching Protocols",
                    headers: switchingHeaders + [HeaderField(name: "X-T", value: "1")]))

        // The same for an upgrade request answered with a plain failure, and for a response that
        // offers an upgrade on its own.
        let offered = [HeaderField(name: "Connection", value: "Upgrade"), HeaderField(name: "Upgrade", value: "h2c")]
        let exchanges = [
            (request(headers: upgradeHeaders), response(400)), (request(), response(200, headers: offered)),
        ]
        for (requestHead, responseHead) in exchanges {
            let (_, other) = try evaluate(requestHead, responseHead, snapshot(paused, statusRule))
            #expect(other.matches.outcomes.map(\.code) == [.unsupportedUpgradeAction, .unsupportedUpgradeAction])
            #expect(other.breakpoint == nil)
            #expect(other.statusRewrite == nil)
        }

        // A ticked breakpoint that cannot run on an upgrade does not stop the rules below it.
        let finalPause = rule(pause(final: true))
        let after = rule(setHeader("X-After", "1"))
        let (_, notFinal) = try evaluate(request(headers: upgradeHeaders), switching, snapshot(finalPause, after))
        #expect(
            notFinal.matches.outcomes == [
                outcome(finalPause.id, .unsupportedUpgradeAction), outcome(after.id, .applied),
            ])
    }

    @Test func bodyRulesUseTheRewrittenStatusForNoBodyChecks() throws {
        let to204 = rule(rewriteStatus(204))
        let bodyRule = rule(rewriteBody())
        let (_, decision) = try evaluate(request(), response(200, headers: textHeaders), snapshot(to204, bodyRule))
        #expect(decision.matches.outcomes == [outcome(to204.id, .applied), outcome(bodyRule.id, .bodySkippedNoBody)])
        #expect(decision.bodyRewrites.isEmpty)

        // The check reads the final status even when the body rule ran before the rewrite.
        let (_, before) = try evaluate(request(), response(200, headers: textHeaders), snapshot(bodyRule, to204))
        #expect(before.matches.outcomes == [outcome(bodyRule.id, .bodySkippedNoBody), outcome(to204.id, .applied)])

        // Rewritten from a status without a body to one with a body: the body is collected.
        let to200 = rule(rewriteStatus(200))
        let (_, back) = try evaluate(request(), response(204, headers: textHeaders), snapshot(to200, bodyRule))
        #expect(back.bodyRewrites == [BodyRewriteStep(ruleID: bodyRule.id, action: body())])
        #expect(back.matches.outcomes == [outcome(to200.id, .applied), outcome(bodyRule.id, .applied)])

        // A response to HEAD never has a body.
        let (_, head) = try evaluate(
            request(target(method: "HEAD")), response(200, headers: textHeaders), snapshot(bodyRule))
        #expect(head.matches.outcomes == [outcome(bodyRule.id, .bodySkippedNoBody)])
    }

    @Test func rejectedResponseEditRecordsRejected() throws {
        // The rule whose own edit fails is rejected; earlier rules keep their outcomes.
        let ok = rule(setHeader("X-Ok", "1"))
        let statusRule = rule(rewriteStatus(500))
        let bad = rule(setHeader("Content-Length", "1"))
        let never = rule(setHeader("X-Never", "1"))
        expectFailure(
            HTTPMutationError(code: .protectedHeader, field: .header(name: "Content-Length")),
            ruleIDs: [ok.id, statusRule.id, bad.id],
            outcomes: [outcome(ok.id, .applied), outcome(statusRule.id, .applied), outcome(bad.id, .rejected)]
        ) { try evaluate(request(), response(), snapshot(ok, statusRule, bad, never)).response }

        // In a rule with several actions only the failing action is rejected, with its position; a
        // rule judged at the response point fails the same way.
        let multi = rule(pause(), setHeader("Content-Length", "1"), setHeader("X-Never", "1"))
        expectFailure(
            HTTPMutationError(code: .protectedHeader, field: .header(name: "Content-Length")),
            ruleIDs: [multi.id], outcomes: [outcome(multi.id, .applied, 0), outcome(multi.id, .rejected, 1)]
        ) { try evaluate(request(), response(), snapshot(multi)).response }
        let ranged = rule(when: [status("200-299")], setHeader("Transfer-Encoding", "chunked"))
        expectFailure(
            HTTPMutationError(code: .protectedHeader, field: .header(name: "Transfer-Encoding")),
            ruleIDs: [ranged.id], outcomes: [outcome(ranged.id, .rejected)]
        ) { try evaluate(request(), response(), snapshot(ranged)).response }

        // A combined block over the limit: every edit that built it is rejected, nothing else.
        let big = String(repeating: "v", count: 8_000)
        let edits = (0..<9).map { rule(appendHeader("X-\($0)", big)) }
        let tail = rule(rewriteStatus(500))
        expectFailure(
            HTTPMutationError(code: .headerBlockTooLarge, field: .headers),
            ruleIDs: edits.map(\.id) + [tail.id],
            outcomes: edits.map { outcome($0.id, .rejected) } + [outcome(tail.id, .applied)]
        ) { try evaluate(request(), response(), RuleSnapshot(revision: 7, rules: edits + [tail])).response }

        // The handshake fields stay protected on any answer to an upgrade request.
        let handshake = rule(setHeader("Sec-WebSocket-Accept", "z"))
        expectFailure(
            HTTPMutationError(code: .protectedHeader, field: .header(name: "Sec-WebSocket-Accept")),
            ruleIDs: [handshake.id], outcomes: [outcome(handshake.id, .rejected)]
        ) { try evaluate(request(headers: upgradeHeaders), response(400), snapshot(handshake)).response }
        // Contrast: without the upgrade request the same edit is allowed (and counts as a change).
        #expect(try evaluate(request(), response(400), snapshot(handshake)).response.rulesModified)
    }

    @Test func patternTimeoutAtP2IsReported() throws {
        let cache = PatternCache(budget: StepClock().budget)
        let hits = RuleHitCounter()
        let slow = rule(when: [status("200-299"), pathRegex(slowPathRegex)], setHeader("X-Slow", "1"))
        let edit = rule(when: [status("200-299")], setHeader("X-E", "1"))
        let head = request(target(path: slowPath))
        let (p1, p2) = try evaluate(head, response(200), snapshot(slow, edit), hits: hits, cache: cache)
        #expect(!p1.matches.hasRecords)
        #expect(p2.matches.outcomes == [outcome(edit.id, .applied), outcome(slow.id, .patternTimedOut)])
        #expect(p2.matches.ruleIDs == [edit.id])
        #expect(p2.matches.total == 1)
        #expect(p2.effectiveHead.headers.values(for: "X-Slow").isEmpty)
        #expect(hits.count(slow.id) == 0)

        // The status row runs first: outside the range the pattern never runs.
        let (_, other) = try evaluate(head, response(500), snapshot(slow), cache: cache)
        #expect(!other.matches.hasRecords)
        #expect(try cache.regex(slowPathRegex, caseInsensitive: false).timeoutCount == 1)

        // Three timeouts in a row switch the pattern off; it is then reported as disabled.
        for _ in 0..<2 { _ = try evaluate(head, response(200), snapshot(slow, edit), cache: cache) }
        let (_, disabled) = try evaluate(head, response(200), snapshot(slow, edit), cache: cache)
        #expect(disabled.matches.outcomes == [outcome(edit.id, .applied), outcome(slow.id, .patternDisabled)])
    }

    @Test func singleActionRulesHaveNilActionIndexAtP2() throws {
        let rules = [
            rule(setHeader("X", "1")), rule(rewriteStatus(500)), rule(pause()),
            rule(when: [status("500-599")], setHeader("Y", "1")),
        ]
        let (_, decision) = try evaluate(request(), response(200), RuleSnapshot(revision: 7, rules: rules))
        #expect(decision.matches.outcomes == rules.map { outcome($0.id, .applied) })

        let bodyRule = rule(rewriteBody())
        let (_, collected) = try evaluate(request(), response(200, headers: textHeaders), snapshot(bodyRule))
        #expect(collected.bodyRewrites.map(\.actionIndex) == [nil])
        #expect(collected.matches.outcomes == [outcome(bodyRule.id, .applied)])

        // A breakpoint makes the body rule stand aside; the outcome still names no action.
        let paused = rule(pause())
        let (_, skipped) = try evaluate(request(), response(200, headers: textHeaders), snapshot(bodyRule, paused))
        #expect(
            skipped.matches.outcomes == [outcome(bodyRule.id, .bodySkippedBreakpoint), outcome(paused.id, .applied)])

        // Rules with several actions name each one.
        let multi = rule(setHeader("X", "1"), rewriteBody())
        let (_, labelled) = try evaluate(request(), response(200, headers: textHeaders), snapshot(multi))
        #expect(labelled.bodyRewrites == [BodyRewriteStep(ruleID: multi.id, actionIndex: 1, action: body())])
        #expect(labelled.matches.outcomes == [outcome(multi.id, .applied, 0), outcome(multi.id, .applied, 1)])
        let (_, labelledSkip) = try evaluate(request(), response(204, headers: textHeaders), snapshot(multi))
        #expect(
            labelledSkip.matches.outcomes == [outcome(multi.id, .applied, 0), outcome(multi.id, .bodySkippedNoBody, 1)])
    }

    @Test func rulesModifiedFollowsHeaderAndStatusEdits() throws {
        func modified(
            _ rules: Rule..., response head: HTTPMessageHead = response(200), local: Bool = false
        ) throws -> Bool {
            try evaluate(request(), head, RuleSnapshot(revision: 7, rules: rules), isLocalResponse: local)
                .response.rulesModified
        }
        #expect(try !modified(rule(pause())))
        #expect(try modified(rule(setHeader("X", "1"))))
        #expect(try modified(rule(rewriteStatus(500))))
        #expect(try modified(rule(rewriteStatus(500, includeLocal: true)), local: true))
        #expect(try modified(rule(pause(), setHeader("X", "1"))))
        // Skipped for a local response, or on an upgrade.
        #expect(try !modified(rule(rewriteStatus(500)), local: true))
        #expect(try !modified(rule(rewriteStatus(500)), response: response(101, headers: switchingHeaders)))
        // Settled by the session once the body is seen.
        #expect(try !modified(rule(rewriteBody()), response: response(200, headers: textHeaders)))
        // Not matched, cut by a final action, or work of the request point.
        #expect(try !modified(rule(when: [status("500-599")], setHeader("X", "1"))))
        #expect(try !modified(rule(pause(final: true), setHeader("X", "1"))))
        #expect(try !modified(rule(setHeader("X", "1", on: .request))))
    }
}

// MARK: conditions on the current message (Rules 2.0 R3)

private func both(
    _ requestHead: HTTPMessageHead = request(), _ responseHead: HTTPMessageHead = response(), _ snapshot: RuleSnapshot,
    facts: ExchangeFacts = ExchangeFacts()
) throws -> (request: RequestRuleDecision, response: ResponseRuleDecision) {
    let p1 = try RuleEvaluator.request(requestHead, snapshot: snapshot, facts: facts, cache: calmCache())
    let p2 = try RuleEvaluator.response(responseHead, after: p1, snapshot: snapshot, facts: facts, cache: calmCache())
    return (p1, p2)
}

private func statusIs(_ value: String) -> ConditionRow { ConditionRow(field: .statusCode, op: .equals, value: value) }

extension RuleEvaluatorP2Tests {
    @Test func responseJudgedRuleReadsResponseHeaders() throws {
        let reader = rule(
            when: [ConditionRow(field: .responseHeader, name: "server", op: .startsWith, value: "nginx")],
            setHeader("X-Seen", "1"))
        let served = response(200, headers: [HeaderField(name: "Server", value: "nginx/1.25")])
        let (_, p2) = try both(request(), served, snapshot(reader))
        #expect(p2.effectiveHead.headers.values(for: "X-Seen") == ["1"])
        let (_, other) = try both(request(), response(200), snapshot(reader))
        #expect(other.effectiveHead.headers.values(for: "X-Seen").isEmpty)
        // A response header a rule above added is read by the rules below it.
        let add = rule(when: [statusIs("200")], setHeader("X-Origin", "edge"))
        let below = rule(
            when: [ConditionRow(field: .responseHeader, name: "X-Origin", op: .equals, value: "edge")],
            setHeader("X-Below", "1"))
        let (_, edited) = try both(request(), response(200), snapshot(add, below))
        #expect(edited.effectiveHead.headers.values(for: "X-Below") == ["1"])
    }

    @Test func responseJudgedRuleReadsRequestHeadersAsP1Left() throws {
        let edit = rule(setHeader("X-A", "1", on: .request))
        let reader = rule(
            when: [statusIs("200"), ConditionRow(field: .requestHeader, name: "X-A", op: .equals, value: "1")],
            setHeader("X-Saw-A", "1"))
        let (p1, p2) = try both(request(), response(200), snapshot(edit, reader))
        #expect(p1.carry?.requestHeaders == [HeaderField(name: "X-A", value: "1")])
        #expect(p2.effectiveHead.headers.values(for: "X-Saw-A") == ["1"])
    }

    @Test func laterRuleReadsEarlierStatusRewrite() throws {
        let rewrite = rule(rewriteStatus(500))
        let reads500 = rule(when: [statusIs("500")], setHeader("X-500", "1"))
        let reads200 = rule(when: [statusIs("200")], setHeader("X-200", "1"))
        let (_, p2) = try both(request(), response(200), snapshot(rewrite, reads500, reads200))
        #expect(p2.effectiveHead.headers.values(for: "X-500") == ["1"])
        #expect(p2.effectiveHead.headers.values(for: "X-200").isEmpty)
    }

    @Test func responseRulesReadTheRequestTargetAsP1LeftIt() throws {
        let move = rule(mapRemote("b.test"))
        let reader = rule(
            when: [statusIs("200"), ConditionRow(field: .url, op: .startsWith, value: "https://b.test/")],
            setHeader("X-B", "1"))
        let (_, p2) = try both(request(), response(200), snapshot(move, reader))
        #expect(p2.effectiveHead.headers.values(for: "X-B") == ["1"])
    }

    @Test func responseRulesSeeEarlierModificationsAndComments() throws {
        let wasModified = rule(
            when: [statusIs("200"), ConditionRow(field: .rulesModified, op: .equals, value: "true")],
            setHeader("X-Modified", "1"))
        // A request-point header edit counts as a modification at the response point.
        let (_, edited) = try both(request(), response(200), snapshot(rule(setHeader("X-A", "1", on: .request)), wasModified))
        #expect(edited.effectiveHead.headers.values(for: "X-Modified") == ["1"])
        let (_, untouched) = try both(request(), response(200), snapshot(wasModified))
        #expect(untouched.effectiveHead.headers.values(for: "X-Modified").isEmpty)
        // The comment the point was entered with, plus the comment actions of the response rules above.
        let note = rule(when: [statusIs("200")], RuleAction(.comment(CommentAction(mode: .append, text: "late"))))
        let reader = rule(
            when: [statusIs("200"), ConditionRow(field: .comment, op: .equals, value: "early late")],
            setHeader("X-Comment", "1"))
        let (_, commented) = try both(
            request(), response(200), snapshot(note, reader), facts: ExchangeFacts(comment: "early"))
        #expect(commented.effectiveHead.headers.values(for: "X-Comment") == ["1"])
    }

    @Test func responseUnknownNotesAreRecordedOnce() throws {
        let reader = Rule(
            name: "app", order: 0,
            conditions: ConditionGroup(
                mode: .none,
                rows: [statusIs("404"), ConditionRow(field: .clientApp, name: "name", op: .equals, value: "x")]),
            actions: [setHeader("X-App", "1")])
        let (p1, p2) = try both(request(), response(200), snapshot(reader), facts: ExchangeFacts(app: .unknown))
        #expect(!p1.matches.hasRecords)
        #expect(p2.matches.outcomes == [outcome(reader.id, .appUnknown)])
        #expect(p2.effectiveHead.headers.values(for: "X-App").isEmpty)
    }
}
