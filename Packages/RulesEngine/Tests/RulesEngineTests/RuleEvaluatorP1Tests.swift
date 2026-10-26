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

private let upgradeHeaders = [
    HeaderField(name: "Connection", value: "Upgrade"), HeaderField(name: "Upgrade", value: "websocket"),
    HeaderField(name: "Sec-WebSocket-Key", value: "k"),
]

private let textHeaders = [HeaderField(name: "Content-Type", value: "text/plain")]

// MARK: conditions

private func host(_ value: String) -> ConditionRow { ConditionRow(field: .host, op: .hostPattern, value: value) }
private func status(_ value: String) -> ConditionRow { ConditionRow(field: .statusCode, op: .inRange, value: value) }
private func pathRegex(_ value: String) -> ConditionRow {
    ConditionRow(field: .pathAndQuery, op: .regexWhole, value: value, caseSensitive: true)
}

// MARK: actions

private let localFile = MapLocalAction(assetID: UUID(uuidString: "00000000-0000-0000-0000-00000000F11E")!, headers: [])
private let directoryAction = MapLocalDirectoryAction(bookmark: Data([1]), displayName: "site")

private func setHeader(
    _ name: String, _ value: String, on direction: HTTPMessageDirection = .request, final: Bool = false
) -> RuleAction {
    RuleAction(.editHeaders(direction: direction, operations: [.set(name: name, value: value)]), isFinal: final)
}

private func appendHeader(_ name: String, _ value: String) -> RuleAction {
    RuleAction(.editHeaders(direction: .request, operations: [.append(name: name, value: value)]))
}

private func pause(
    _ direction: HTTPMessageDirection = .request, _ mode: BreakpointPauseMode = .headers, final: Bool = false
) -> RuleAction {
    RuleAction(.breakpoint(direction: direction, mode: mode), isFinal: final)
}

private func remote(
    _ host: String, scheme: String = "https", port: Int = 443, path: RemotePathPolicy = .preserve,
    preserve: Bool = false
) -> MapRemoteAction {
    MapRemoteAction(targetScheme: scheme, targetHost: host, targetPort: port, path: path, preserveCredentials: preserve)
}

private func mapRemote(_ host: String, port: Int = 443, path: RemotePathPolicy = .preserve) -> RuleAction {
    RuleAction(.mapRemote(remote(host, port: port, path: path)))
}

private func returnFile() -> RuleAction { RuleAction(.returnFile(localFile)) }

private func returnDirectory(prefix: String = "/files/") -> RuleAction {
    RuleAction(.returnDirectory(directoryAction, pathPrefix: prefix))
}

private func rewriteStatus(_ status: Int) -> RuleAction {
    RuleAction(.rewriteStatus(RewriteStatusAction(status: status)))
}

private func body(_ find: String = "a") -> BodyRewriteAction { BodyRewriteAction(find: find, replacement: "z") }

private func rewriteBody(
    _ direction: HTTPMessageDirection = .request, find: String = "a", final: Bool = false
) -> RuleAction {
    RuleAction(.rewriteBody(direction: direction, body(find)), isFinal: final)
}

// MARK: rules and evaluation

private func rule(
    id: UUID = UUID(), enabled: Bool = true, group: UUID? = nil, when rows: [ConditionRow] = [],
    occurrence: Occurrence = .any, _ actions: RuleAction...
) -> Rule {
    Rule(
        id: id, name: "r", enabled: enabled, groupID: group, order: 0,
        conditions: ConditionGroup(mode: .all, occurrence: occurrence, rows: rows), actions: actions)
}

/// Rules are evaluated in the order given (they all have order 0).
private func snapshot(_ rules: Rule..., groups: [RuleGroup] = []) -> RuleSnapshot {
    RuleSnapshot(revision: 7, groups: groups, rules: rules)
}

private func evaluate(
    _ head: HTTPMessageHead, _ snapshot: RuleSnapshot, hits: RuleHitCounter? = nil,
    cache: PatternCache = PatternCache(budget: RegexBudget(clock: { .zero }))
) throws -> RequestRuleDecision {
    try RuleEvaluator.request(head, snapshot: snapshot, hits: hits, cache: cache)
}

private func outcome(_ id: UUID, _ code: RuleOutcomeCode, _ index: Int? = nil) -> RuleOutcome {
    RuleOutcome(ruleID: id, code: code, actionIndex: index)
}

private func pending(_ position: Int, _ id: UUID, _ indices: [Int]) -> RuleCarry.PendingRule {
    RuleCarry.PendingRule(position: position, ruleID: id, actionIndices: indices)
}

private func stop(_ position: Int, _ index: Int) -> RuleCarry.FinalStop {
    RuleCarry.FinalStop(position: position, actionIndex: index)
}

private func expectFailure(
    _ mutation: HTTPMutationError, ruleIDs: [UUID], outcomes: [RuleOutcome],
    sourceLocation: SourceLocation = #_sourceLocation, _ operation: () throws -> RequestRuleDecision
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

@Suite("RuleEvaluatorP1")
struct RuleEvaluatorP1Tests {
    @Test func emptySnapshotReturnsTheOriginalRequestUntouched() throws {
        let head = request(headers: [HeaderField(name: "Accept", value: "*/*")])
        let hits = RuleHitCounter()
        let off = RuleGroup(name: "off", enabled: false)
        let nothingEnabled = snapshot(
            rule(enabled: false, setHeader("X", "1")), rule(group: off.id, returnFile()), groups: [off])
        for rules in [snapshot(), nothingEnabled] {
            let decision = try evaluate(head, rules, hits: hits)
            #expect(decision.effectiveHead == head)
            #expect(decision.route == .original)
            #expect(decision.breakpoint == nil)
            #expect(decision.bodyRewrites.isEmpty)
            #expect(!decision.matches.hasRecords)
            #expect(decision.matches.revision == 7)
            #expect(decision.rulesModified == false)
            let carry = try #require(decision.carry)
            #expect(carry == RuleCarry(target: target(), pending: [], finalStop: nil, requestHeaders: head.headers))
        }
        #expect(hits.snapshot().isEmpty)
    }

    @Test func wrongMessageKindFails() {
        #expect(throws: HTTPMutationError(code: .messageKindMismatch, field: .message)) {
            try RuleEvaluator.request(.response(status: 200, reason: nil, headers: []), snapshot: snapshot())
        }
    }

    /// D17 says edits are validated against the client's original headers. With today's validator that
    /// cannot be told apart from validating against the current ones: the guarded set comes only from
    /// `Connection` / `Upgrade`, which no edit may touch, so both give the same answer. This test pins
    /// what is observable: edits pile up in rule order, and a field the client's `Connection` nominates
    /// stays protected for every later rule.
    @Test func headerEditsRunInRuleOrderAndValidateAgainstTheOriginalHeaders() throws {
        let original = request(headers: [
            HeaderField(name: "Connection", value: "X-Hop"), HeaderField(name: "X-Hop", value: "1"),
            HeaderField(name: "Accept", value: "*/*"),
        ])
        let first = rule(
            RuleAction(
                .editHeaders(
                    direction: .request,
                    operations: [.set(name: "X-A", value: "first"), .append(name: "x-b", value: "1")])))
        let second = rule(setHeader("X-A", "second"))
        let decision = try evaluate(original, snapshot(first, second))
        #expect(decision.effectiveHead.headers.values(for: "X-A") == ["second"])
        #expect(decision.effectiveHead.headers.values(for: "X-B") == ["1"])
        #expect(decision.effectiveHead.headers.values(for: "X-Hop") == ["1"])
        #expect(decision.matches.ruleIDs == [first.id, second.id])
        #expect(decision.matches.outcomes == [outcome(first.id, .applied), outcome(second.id, .applied)])
        #expect(decision.route == .original)
        #expect(decision.breakpoint == nil)

        // The field the client's Connection header nominates stays off limits to every later rule,
        // whatever earlier rules did to the message.
        let nominated = rule(setHeader("X-Hop", "2"))
        expectFailure(
            HTTPMutationError(code: .nominatedHeader, field: .header(name: "X-Hop")),
            ruleIDs: [first.id, second.id, nominated.id],
            outcomes: [outcome(first.id, .applied), outcome(second.id, .applied), outcome(nominated.id, .rejected)]
        ) { try evaluate(original, snapshot(first, second, nominated)) }
    }

    @Test func mapRemoteUpdatesTheCurrentTargetForLaterRules() throws {
        let a = rule(mapRemote("b.test"))
        let b = rule(when: [host("a.test")], setHeader("X-B", "1"))
        let c = rule(when: [host("b.test")], setHeader("X-C", "1"))
        let decision = try evaluate(request(target(host: "a.test")), snapshot(a, b, c))
        #expect(decision.route == .remote(remote("b.test")))
        #expect(decision.effectiveHead.headers.values(for: "X-B").isEmpty)
        #expect(decision.effectiveHead.headers.values(for: "X-C") == ["1"])
        #expect(decision.matches.ruleIDs == [a.id, c.id])
        #expect(decision.matches.outcomes == [outcome(a.id, .applied), outcome(c.id, .applied)])
        #expect(decision.carry?.target == target(host: "b.test"))
        // The effective head keeps the client's target: the executor applies the route.
        #expect(
            decision.effectiveHead == request(target(host: "a.test"), headers: [HeaderField(name: "X-C", value: "1")]))
    }

    @Test func mapLocalIsFinalAndTruncatesLowerRules() throws {
        for final in [returnFile(), returnDirectory()] {
            let hits = RuleHitCounter()
            let a = rule(setHeader("X-A", "1"))
            let b = rule(final)
            let c = rule(setHeader("X-C", "1"))
            let decision = try evaluate(request(target(path: "/files/x")), snapshot(a, b, c), hits: hits)
            #expect(
                decision.matches.outcomes == [
                    outcome(a.id, .applied), outcome(b.id, .applied), outcome(b.id, .finalStop, 0),
                ])
            #expect(decision.matches.ruleIDs == [a.id, b.id])
            #expect(decision.matches.total == 2)
            #expect(decision.effectiveHead.headers.values(for: "X-A") == ["1"])
            #expect(decision.effectiveHead.headers.values(for: "X-C").isEmpty)
            #expect(decision.carry?.finalStop == stop(1, 0))
            #expect(hits.snapshot() == [a.id: 1, b.id: 1])
            switch decision.route {
            case .local(let action): #expect(action == localFile)
            case .localDirectory(let route):
                #expect(route == DirectoryRoute(action: directoryAction, subpath: .safe(["x"]), method: "GET"))
            case .original, .remote, .generated, .close: Issue.record("expected a local route, got \(decision.route)")
            }
        }
    }

    @Test func finalStopIsOmittedWhenNothingFollows() throws {
        let only = rule(returnFile())
        let disabledAfter = rule(enabled: false, setHeader("X", "1"))
        let decision = try evaluate(request(), snapshot(only, disabledAfter))
        #expect(decision.matches.outcomes == [outcome(only.id, .applied)])
        #expect(decision.carry?.finalStop == stop(0, 0))
        #expect(decision.route == .local(localFile))

        // A ticked final action as the last action of the last rule truncates nothing either.
        let ticked = rule(setHeader("X-A", "1"), pause(final: true))
        let tickedDecision = try evaluate(request(), snapshot(ticked))
        #expect(tickedDecision.matches.outcomes == [outcome(ticked.id, .applied, 0), outcome(ticked.id, .applied, 1)])
        #expect(tickedDecision.carry?.finalStop == stop(0, 1))
    }

    @Test func finalFlagStopsRemainingActionsOfTheSameRule() throws {
        let hits = RuleHitCounter()
        let r = rule(setHeader("X-A", "1"), pause(.request, .headers, final: true), mapRemote("b.test"))
        let decision = try evaluate(request(), snapshot(r), hits: hits)
        #expect(
            decision.matches.outcomes == [
                outcome(r.id, .applied, 0), outcome(r.id, .applied, 1), outcome(r.id, .finalStop, 1),
                outcome(r.id, .skippedAfterFinal, 2),
            ])
        #expect(decision.route == .original)
        #expect(decision.breakpoint == .headers)
        #expect(decision.effectiveHead.headers.values(for: "X-A") == ["1"])
        #expect(decision.matches.ruleIDs == [r.id])
        #expect(
            decision.carry
                == RuleCarry(
                    target: target(), pending: [], finalStop: stop(0, 1),
                    requestHeaders: [HeaderField(name: "X-A", value: "1")]))
        #expect(hits.count(r.id) == 1)
    }

    @Test func responseSideActionsBeforeAFinalActionStayPending() throws {
        let r = rule(rewriteStatus(500), returnFile())
        let decision = try evaluate(request(), snapshot(r))
        #expect(decision.carry?.pending == [pending(0, r.id, [0])])
        #expect(decision.carry?.finalStop == stop(0, 1))
        #expect(decision.matches.outcomes == [outcome(r.id, .applied, 1)])

        // Response-side actions after the final one are cut at once; lower rules never run.
        let higher = rule(setHeader("X-H", "1", on: .response))
        let mixed = rule(rewriteStatus(500), returnFile(), setHeader("X-R", "1", on: .response))
        let lower = rule(setHeader("X-L", "1", on: .response))
        let second = try evaluate(request(), snapshot(higher, mixed, lower))
        #expect(second.carry?.pending == [pending(0, higher.id, [0]), pending(1, mixed.id, [0])])
        #expect(second.carry?.finalStop == stop(1, 1))
        #expect(
            second.matches.outcomes == [
                outcome(mixed.id, .applied, 1), outcome(mixed.id, .finalStop, 1),
                outcome(mixed.id, .skippedAfterFinal, 2),
            ])
        #expect(second.matches.ruleIDs == [mixed.id])
    }

    @Test func upgradeRequestSkipsMapLocalAndItIsNotFinal() throws {
        let hits = RuleHitCounter()
        let local = rule(returnFile())
        let directory = rule(returnDirectory(prefix: "/"))
        let moved = rule(mapRemote("b.test"))
        let paused = rule(pause(final: true))
        let edit = rule(setHeader("X-T", "1"))
        let decision = try evaluate(
            request(headers: upgradeHeaders), snapshot(local, directory, moved, paused, edit), hits: hits)
        #expect(decision.route == .original)
        #expect(decision.breakpoint == nil)
        #expect(decision.effectiveHead.headers.values(for: "X-T") == ["1"])
        #expect(
            decision.matches.outcomes == [
                outcome(local.id, .unsupportedUpgradeAction), outcome(directory.id, .unsupportedUpgradeAction),
                outcome(moved.id, .unsupportedUpgradeAction), outcome(paused.id, .unsupportedUpgradeAction),
                outcome(edit.id, .applied),
            ])
        #expect(
            decision.carry
                == RuleCarry(
                    target: target(), pending: [], finalStop: nil,
                    requestHeaders: upgradeHeaders + [HeaderField(name: "X-T", value: "1")]))
        #expect(hits.count(edit.id) == 1)

        // A ticked body rewrite cannot run on an upgrade either, so it does not stop the rules below it.
        let bodyRule = rule(rewriteBody(final: true))
        let after = rule(setHeader("X-After", "1"))
        let bodyDecision = try evaluate(request(headers: upgradeHeaders + textHeaders), snapshot(bodyRule, after))
        #expect(
            bodyDecision.matches.outcomes == [
                outcome(bodyRule.id, .unsupportedUpgradeAction), outcome(after.id, .applied),
            ])
        #expect(bodyDecision.bodyRewrites.isEmpty)
        #expect(bodyDecision.carry?.finalStop == nil)
    }

    /// A body rewrite the user made final is final as soon as it is a candidate (on a request that is
    /// not an upgrade): the message-level checks that may replace its outcome with a skip run after
    /// every rule, so lower rules are already cut by then (Task 4 ruling).
    @Test func tickedFinalBodyRewriteIsFinalEvenWhenTheBodyIsSkipped() throws {
        let final = rule(rewriteBody(final: true))
        let lower = rule(setHeader("X-Lower", "1"))
        let text = try evaluate(request(headers: textHeaders), snapshot(final, lower))
        #expect(text.matches.outcomes == [outcome(final.id, .applied), outcome(final.id, .finalStop, 0)])
        #expect(text.bodyRewrites == [BodyRewriteStep(ruleID: final.id, action: body())])
        #expect(text.carry?.finalStop == stop(0, 0))
        #expect(text.effectiveHead.headers.values(for: "X-Lower").isEmpty)

        let image = [HeaderField(name: "Content-Type", value: "image/png")]
        let skipped = try evaluate(request(headers: image), snapshot(final, lower))
        #expect(skipped.matches.outcomes == [outcome(final.id, .bodySkippedNotText), outcome(final.id, .finalStop, 0)])
        #expect(skipped.bodyRewrites.isEmpty)
        #expect(skipped.carry?.finalStop == stop(0, 0))
        #expect(skipped.effectiveHead.headers.values(for: "X-Lower").isEmpty)
    }

    @Test func secondMapRemoteReadsTheFirstOnesUrl() throws {
        let first = rule(mapRemote("b.test", path: .replace("/first")))
        let second = rule(when: [host("b.test")], mapRemote("c.test", port: 8443))
        let decision = try evaluate(request(target(host: "a.test")), snapshot(first, second))
        #expect(decision.route == .remote(remote("c.test", port: 8443, path: .replace("/first"))))
        #expect(decision.carry?.target == target(host: "c.test", port: 8443, path: "/first"))
        #expect(decision.matches.outcomes == [outcome(first.id, .applied), outcome(second.id, .applied)])

        // A third hop with its own path: the last replacement wins, and the route still is one action.
        let third = rule(when: [host("c.test")], mapRemote("d.test", path: .replace("/third?x=1")))
        let chained = try evaluate(request(target(host: "a.test")), snapshot(first, second, third))
        #expect(chained.route == .remote(remote("d.test", path: .replace("/third?x=1"))))
        #expect(chained.carry?.target == target(host: "d.test", path: "/third?x=1"))
        #expect(chained.matches.ruleIDs == [first.id, second.id, third.id])

        // A rule that still names the first host no longer matches after the first hop.
        let stale = rule(when: [host("a.test")], mapRemote("e.test"))
        let staleDecision = try evaluate(request(target(host: "a.test")), snapshot(first, stale))
        #expect(staleDecision.route == .remote(remote("b.test", path: .replace("/first"))))
        #expect(staleDecision.matches.ruleIDs == [first.id])
    }

    @Test func composedRoutePreservesCredentialsOnlyIfEveryHopDoes() throws {
        func composed(_ first: MapRemoteAction, _ second: MapRemoteAction) throws -> MapRemoteAction? {
            let decision = try evaluate(
                request(), snapshot(rule(RuleAction(.mapRemote(first))), rule(RuleAction(.mapRemote(second)))))
            guard case .remote(let route) = decision.route else { return nil }
            return route
        }
        let cases: [(first: MapRemoteAction, second: MapRemoteAction, preserved: Bool)] = [
            (remote("b.test", preserve: true), remote("c.test", preserve: true), true),
            (remote("b.test", preserve: true), remote("c.test", preserve: false), false),
            (remote("b.test", preserve: false), remote("c.test", preserve: true), false),
            (remote("b.test", preserve: false), remote("c.test", preserve: false), false),
            // The second hop stays on the first one's origin (only the path changes): nothing new to protect.
            (remote("b.test", preserve: true), remote("b.test", path: .replace("/x"), preserve: false), true),
            (remote("b.test", preserve: true), remote("B.TEST", scheme: "HTTPS", preserve: false), true),
            (remote("[::1]", port: 8443, preserve: true), remote("::1", port: 8443, preserve: false), true),
            (remote("b.test", preserve: false), remote("b.test", path: .replace("/x"), preserve: true), false),
            // Another port or scheme is another origin.
            (remote("b.test", preserve: true), remote("b.test", port: 8443, preserve: false), false),
            (remote("b.test", preserve: true), remote("b.test", scheme: "http", preserve: false), false),
        ]
        for (first, second, preserved) in cases {
            let route = try #require(try composed(first, second))
            #expect(route.preserveCredentials == preserved, "\(first) then \(second)")
            #expect(route.targetHost == second.targetHost)
            #expect(route.targetScheme == second.targetScheme)
            #expect(route.targetPort == second.targetPort)
        }
    }

    @Test func remoteTargetLowercasesAndDropsIPv6Brackets() {
        let original = target(host: "a.test", method: "PATCH", path: "/v1?q=1")
        #expect(
            remote("[::1]", scheme: "HTTPS", port: 8443).target(applyingTo: original)
                == HTTPMessageTarget(scheme: "https", host: "::1", port: 8443, method: "PATCH", pathAndQuery: "/v1?q=1")
        )
        #expect(
            remote("Example.TEST", port: 80, path: .replace("/z")).target(applyingTo: original)
                == HTTPMessageTarget(
                    scheme: "https", host: "example.test", port: 80, method: "PATCH", pathAndQuery: "/z"))
    }

    @Test func directoryRouteResolvesAgainstTheCurrentPath() throws {
        let moved = rule(mapRemote("b.test", path: .replace("/files/a/b.txt?x=1")))
        let directory = rule(returnDirectory(prefix: "/files/"))
        let decision = try evaluate(request(target(method: "HEAD", path: "/other")), snapshot(moved, directory))
        #expect(
            decision.route
                == .localDirectory(
                    DirectoryRoute(action: directoryAction, subpath: .safe(["a", "b.txt"]), method: "HEAD")))
        #expect(decision.matches.outcomes == [outcome(moved.id, .applied), outcome(directory.id, .applied)])

        // A prefix that is not `/…/` (only a stale or hand-edited snapshot has one) fails closed.
        for prefix in ["", "files/", "/files"] {
            let broken = try evaluate(
                request(target(path: "/files/a")), snapshot(rule(returnDirectory(prefix: prefix))))
            #expect(
                broken.route
                    == .localDirectory(DirectoryRoute(action: directoryAction, subpath: .unsafe, method: "GET")))
        }
    }

    /// A directory without the file falls back to the network as the request point left the request,
    /// so the carry keeps the composed Map Remote even after a return action took the route (D15).
    @Test func carryKeepsTheComposedRemoteWhenAReturnActionTakesTheRoute() throws {
        let first = rule(mapRemote("b.test", path: .replace("/files/a")))
        let second = rule(when: [host("b.test")], mapRemote("c.test", port: 8443))
        let directory = rule(returnDirectory(prefix: "/files/"))
        let decision = try evaluate(request(target(host: "a.test")), snapshot(first, second, directory))
        guard case .localDirectory = decision.route else {
            Issue.record("expected a directory route, got \(decision.route)")
            return
        }
        #expect(decision.carry?.remote == remote("c.test", port: 8443, path: .replace("/files/a")))
        #expect(decision.carry?.target == target(host: "c.test", port: 8443, path: "/files/a"))

        // The route itself carries the same composed action when nothing else takes it.
        let mapped = try evaluate(request(target(host: "a.test")), snapshot(first, second))
        #expect(mapped.route == .remote(try #require(mapped.carry?.remote)))
        // No Map Remote ran: nothing to fall back to.
        let local = try evaluate(request(target(path: "/files/x")), snapshot(directory))
        #expect(local.carry?.remote == nil)
    }

    @Test func statusRangedRulesWaitForP2() throws {
        let hits = RuleHitCounter()
        let ranged = rule(when: [status("500-599")], setHeader("X-S", "1", on: .response))
        let rangedWithHost = rule(when: [host("a.test"), status("200-299")], pause(.response))
        let decision = try evaluate(request(), snapshot(ranged, rangedWithHost), hits: hits)
        #expect(!decision.matches.hasRecords)
        #expect(decision.carry == RuleCarry(target: target(), pending: [], finalStop: nil))
        #expect(hits.snapshot().isEmpty)
    }

    @Test func occurrenceRangeRunsActionsOnlyOnKthToMthHit() throws {
        let hits = RuleHitCounter()
        let counted = rule(occurrence: .times(2...3), setHeader("X-O", "1"))
        let firstOnly = rule(occurrence: .times(1...1), setHeader("X-M", "1"), pause())
        let expected: [[RuleOutcome]] = [
            [
                outcome(counted.id, .occurrenceSkipped), outcome(firstOnly.id, .applied, 0),
                outcome(firstOnly.id, .applied, 1),
            ],
            [outcome(counted.id, .applied), outcome(firstOnly.id, .occurrenceSkipped)],
            [outcome(counted.id, .applied), outcome(firstOnly.id, .occurrenceSkipped)],
            [outcome(counted.id, .occurrenceSkipped), outcome(firstOnly.id, .occurrenceSkipped)],
        ]
        for (call, outcomes) in expected.enumerated() {
            let decision = try evaluate(request(), snapshot(counted, firstOnly), hits: hits)
            #expect(decision.matches.outcomes == outcomes, "hit \(call + 1)")
            #expect(decision.matches.ruleIDs == [counted.id, firstOnly.id], "hit \(call + 1)")
            #expect(decision.effectiveHead.headers.values(for: "X-O") == ((1...2).contains(call) ? ["1"] : []))
            #expect(decision.breakpoint == (call == 0 ? .headers : nil))
        }
        #expect(hits.snapshot() == [counted.id: 4, firstOnly.id: 4])

        // A skipped occurrence leaves nothing for the response point either.
        let responseOnly = rule(occurrence: .times(1...1), setHeader("X-R", "1", on: .response))
        let first = try evaluate(request(), snapshot(responseOnly), hits: hits)
        #expect(first.carry?.pending == [pending(0, responseOnly.id, [0])])
        #expect(!first.matches.hasRecords)
        let second = try evaluate(request(), snapshot(responseOnly), hits: hits)
        #expect(second.carry?.pending.isEmpty == true)
        #expect(second.matches.outcomes == [outcome(responseOnly.id, .occurrenceSkipped)])
        #expect(second.matches.ruleIDs == [responseOnly.id])
    }

    @Test func occurrenceIsIgnoredWithoutACounter() throws {
        let r = rule(occurrence: .times(5...6), setHeader("X-O", "1"))
        for _ in 0..<3 {
            let decision = try evaluate(request(), snapshot(r))
            #expect(decision.matches.outcomes == [outcome(r.id, .applied)])
            #expect(decision.effectiveHead.headers.values(for: "X-O") == ["1"])
        }
    }

    @Test func disabledRulesAndDisabledGroupsNeverRun() throws {
        let hits = RuleHitCounter()
        let off = RuleGroup(name: "off", enabled: false, order: 1)
        let on = RuleGroup(name: "on", enabled: true, order: 2)
        let nested = RuleGroup(name: "nested", enabled: true, parentID: off.id)
        let disabledRule = rule(enabled: false, returnFile())
        let inOff = rule(group: off.id, mapRemote("b.test"))
        let inNested = rule(group: nested.id, pause())
        let inOn = rule(group: on.id, setHeader("X-On", "1"))
        let disabledInOn = rule(enabled: false, group: on.id, setHeader("X-Off", "1"))
        let decision = try evaluate(
            request(), snapshot(disabledRule, inOff, inNested, inOn, disabledInOn, groups: [off, on, nested]),
            hits: hits)
        #expect(decision.route == .original)
        #expect(decision.breakpoint == nil)
        #expect(decision.effectiveHead.headers.values(for: "X-On") == ["1"])
        #expect(decision.effectiveHead.headers.values(for: "X-Off").isEmpty)
        #expect(decision.matches.ruleIDs == [inOn.id])
        #expect(decision.matches.outcomes == [outcome(inOn.id, .applied)])
        #expect(hits.snapshot() == [inOn.id: 1])
    }

    @Test func rejectedEditThrowsEvaluationErrorWithRejectedOutcome() {
        // The rule whose own edit fails is rejected; earlier rules keep their outcomes.
        let ok = rule(setHeader("X-Ok", "1"))
        let paused = rule(pause())
        let bad = rule(setHeader("Content-Length", "1"))
        let never = rule(setHeader("X-Never", "1"))
        expectFailure(
            HTTPMutationError(code: .protectedHeader, field: .header(name: "Content-Length")),
            ruleIDs: [ok.id, paused.id, bad.id],
            outcomes: [outcome(ok.id, .applied), outcome(paused.id, .applied), outcome(bad.id, .rejected)]
        ) { try evaluate(request(), snapshot(ok, paused, bad, never)) }

        // In a rule with several actions only the failing action is rejected, with its position.
        let multi = rule(pause(), setHeader("Content-Length", "1"), setHeader("X-Never", "1"))
        expectFailure(
            HTTPMutationError(code: .protectedHeader, field: .header(name: "Content-Length")),
            ruleIDs: [multi.id], outcomes: [outcome(multi.id, .applied, 0), outcome(multi.id, .rejected, 1)]
        ) { try evaluate(request(), snapshot(multi)) }

        // A combined block over the limit: every edit that built it is rejected, nothing else.
        let big = String(repeating: "v", count: 8_000)
        let edits = (0..<9).map { rule(appendHeader("X-\($0)", big)) }
        let tail = rule(pause())
        expectFailure(
            HTTPMutationError(code: .headerBlockTooLarge, field: .headers),
            ruleIDs: edits.map(\.id) + [tail.id],
            outcomes: edits.map { outcome($0.id, .rejected) } + [outcome(tail.id, .applied)]
        ) { try evaluate(request(), RuleSnapshot(revision: 7, rules: edits + [tail])) }

        let mixed = (0..<9).map { rule(pause(), appendHeader("X-\($0)", big)) }
        expectFailure(
            HTTPMutationError(code: .headerBlockTooLarge, field: .headers),
            ruleIDs: mixed.map(\.id),
            outcomes: mixed.flatMap { [outcome($0.id, .applied, 0), outcome($0.id, .rejected, 1)] }
        ) { try evaluate(request(), RuleSnapshot(revision: 7, rules: mixed)) }

        // The protected handshake of an upgrade request.
        let handshake = rule(setHeader("Sec-WebSocket-Key", "z"))
        expectFailure(
            HTTPMutationError(code: .protectedHeader, field: .header(name: "Sec-WebSocket-Key")),
            ruleIDs: [handshake.id], outcomes: [outcome(handshake.id, .rejected)]
        ) { try evaluate(request(headers: upgradeHeaders), snapshot(handshake)) }
    }

    @Test func multiActionRulesLabelOutcomesWithActionIndex() throws {
        let r = rule(
            setHeader("X-A", "1"), pause(.request, .fullBody), mapRemote("b.test"), setHeader("X-R", "1", on: .response)
        )
        let decision = try evaluate(request(), snapshot(r))
        #expect(
            decision.matches.outcomes == [
                outcome(r.id, .applied, 0), outcome(r.id, .applied, 1), outcome(r.id, .applied, 2),
            ])
        #expect(decision.carry?.pending == [pending(0, r.id, [3])])
        #expect(decision.matches.ruleIDs == [r.id])

        let upgraded = try evaluate(request(headers: upgradeHeaders), snapshot(r))
        #expect(
            upgraded.matches.outcomes == [
                outcome(r.id, .applied, 0), outcome(r.id, .unsupportedUpgradeAction, 1),
                outcome(r.id, .unsupportedUpgradeAction, 2),
            ])
    }

    @Test func singleActionRulesHaveNilActionIndex() throws {
        let rules = [rule(setHeader("X", "1")), rule(mapRemote("b.test")), rule(rewriteBody()), rule(pause(.response))]
        let decision = try evaluate(request(headers: textHeaders), RuleSnapshot(revision: 7, rules: rules))
        #expect(decision.matches.outcomes == rules.prefix(3).map { outcome($0.id, .applied) })
        #expect(decision.bodyRewrites.map(\.actionIndex) == [nil])

        // A breakpoint makes the body rule stand aside; every outcome still names no action.
        let paused = try evaluate(
            request(headers: textHeaders), RuleSnapshot(revision: 7, rules: rules + [rule(pause())]))
        #expect(paused.matches.outcomes.map(\.code) == [.applied, .applied, .bodySkippedBreakpoint, .applied])
        #expect(paused.matches.outcomes.allSatisfy { $0.actionIndex == nil })

        let upgrade = rule(returnFile())
        let upgraded = try evaluate(request(headers: upgradeHeaders), snapshot(upgrade))
        #expect(upgraded.matches.outcomes == [outcome(upgrade.id, .unsupportedUpgradeAction)])
    }

    @Test func bodyStepsCarryActionIndexOnlyForMultiActionRules() throws {
        let single = rule(rewriteBody(find: "a"))
        let multi = rule(pause(.response), rewriteBody(find: "b"))
        let decision = try evaluate(request(headers: textHeaders), snapshot(single, multi))
        #expect(
            decision.bodyRewrites == [
                BodyRewriteStep(ruleID: single.id, action: body("a")),
                BodyRewriteStep(ruleID: multi.id, actionIndex: 1, action: body("b")),
            ])
        #expect(decision.matches.outcomes == [outcome(single.id, .applied), outcome(multi.id, .applied, 1)])
        #expect(decision.carry?.pending == [pending(1, multi.id, [0])])
        #expect(decision.rulesModified == false)

        // A message-level skip keeps the position on the outcome.
        let image = [HeaderField(name: "Content-Type", value: "image/png")]
        let skipped = try evaluate(request(headers: image), snapshot(single, multi))
        #expect(skipped.bodyRewrites.isEmpty)
        #expect(
            skipped.matches.outcomes == [
                outcome(single.id, .bodySkippedNotText), outcome(multi.id, .bodySkippedNotText, 1),
            ])
    }

    @Test func regexTimeoutProblemsAreAppendedAfterOtherOutcomes() throws {
        let cache = PatternCache(budget: StepClock().budget)
        let hits = RuleHitCounter()
        let slow = rule(when: [pathRegex(slowPathRegex)], setHeader("X-Slow", "1"))
        let edit = rule(setHeader("X-E", "1"))
        let head = request(target(path: slowPath))
        let decision = try evaluate(head, snapshot(slow, edit), hits: hits, cache: cache)
        #expect(decision.matches.outcomes == [outcome(edit.id, .applied), outcome(slow.id, .patternTimedOut)])
        #expect(decision.matches.ruleIDs == [edit.id])
        #expect(decision.matches.total == 1)
        #expect(decision.effectiveHead.headers.values(for: "X-Slow").isEmpty)
        #expect(hits.count(slow.id) == 0)

        // Three timeouts in a row switch the pattern off; it is then reported as disabled.
        for _ in 0..<2 { _ = try evaluate(head, snapshot(slow, edit), cache: cache) }
        let disabled = try evaluate(head, snapshot(slow, edit), cache: cache)
        #expect(disabled.matches.outcomes == [outcome(edit.id, .applied), outcome(slow.id, .patternDisabled)])
        #expect(hits.count(slow.id) == 0)
    }

    @Test func responseOnlyRuleIsNotListedAtP1() throws {
        let hits = RuleHitCounter()
        let r = rule(setHeader("X-R", "1", on: .response), pause(.response), rewriteStatus(404))
        let decision = try evaluate(request(), snapshot(r), hits: hits)
        #expect(!decision.matches.hasRecords)
        #expect(decision.matches.ruleIDs.isEmpty)
        #expect(decision.effectiveHead == request())
        #expect(decision.breakpoint == nil)
        #expect(decision.carry?.pending == [pending(0, r.id, [0, 1, 2])])
        #expect(hits.count(r.id) == 1)
    }

    @Test func rulesModifiedCountsOnlyChangingActions() throws {
        func modified(_ rules: Rule..., headers: [HeaderField] = []) throws -> Bool {
            try evaluate(request(headers: headers), RuleSnapshot(revision: 7, rules: rules)).rulesModified
        }
        #expect(try !modified(rule(pause())))
        #expect(try modified(rule(setHeader("X", "1"))))
        #expect(try modified(rule(mapRemote("b.test"))))
        #expect(try modified(rule(returnFile())))
        #expect(try modified(rule(returnDirectory())))
        #expect(try modified(rule(pause(), setHeader("X", "1"))))
        // An applied header edit counts even when the result happens to equal the original.
        #expect(try modified(rule(setHeader("Accept", "*/*")), headers: [HeaderField(name: "Accept", value: "*/*")]))
        // Settled by the session once the body is seen.
        #expect(try !modified(rule(rewriteBody()), headers: textHeaders))
        // Runs at the response point.
        #expect(try !modified(rule(setHeader("X", "1", on: .response))))
        // Skipped on an upgrade, not matched, or cut by a final action.
        #expect(try !modified(rule(returnFile()), rule(mapRemote("b.test")), headers: upgradeHeaders))
        #expect(try !modified(rule(when: [host("elsewhere.test")], setHeader("X", "1"))))
        #expect(try !modified(rule(pause(final: true), setHeader("X", "1"))))
    }

    @Test func unrelatedExchangesDoNotTouchTheCounter() throws {
        let hits = RuleHitCounter()
        let r = rule(when: [host("b.test")], setHeader("X", "1"))
        _ = try evaluate(request(target(host: "a.test")), snapshot(r), hits: hits)
        _ = try evaluate(request(target(host: "c.test")), snapshot(r), hits: hits)
        #expect(hits.snapshot().isEmpty)
        _ = try evaluate(request(target(host: "b.test")), snapshot(r), hits: hits)
        #expect(hits.snapshot() == [r.id: 1])

        // Rules below a final action are not evaluated, so they are not counted either.
        let local = rule(returnFile())
        let lower = rule(setHeader("Y", "1"))
        _ = try evaluate(request(), snapshot(local, lower), hits: hits)
        #expect(hits.snapshot() == [r.id: 1, local.id: 1])
    }
}

// MARK: conditions on the current message (Rules 2.0 R3)

private func requestHeaderIs(_ name: String, _ value: String) -> ConditionRow {
    ConditionRow(field: .requestHeader, name: name, op: .equals, value: value)
}

private func comment(_ text: String) -> RuleAction { RuleAction(.comment(CommentAction(mode: .append, text: text))) }

extension RuleEvaluatorP1Tests {
    @Test func laterRuleReadsEarlierHeaderEdit() throws {
        let edit = rule(setHeader("X-A", "1"))
        let reader = rule(when: [requestHeaderIs("X-A", "1")], setHeader("X-B", "1"))
        let decision = try evaluate(request(), snapshot(edit, reader))
        #expect(decision.effectiveHead.headers.values(for: "X-B") == ["1"])
        #expect(decision.matches.ruleIDs == [edit.id, reader.id])
        // Without the edit above it, the header is not there.
        let alone = try evaluate(request(), snapshot(reader))
        #expect(alone.effectiveHead.headers.values(for: "X-B").isEmpty)
    }

    @Test func laterRuleReadsEarlierMapRemoteHost() throws {
        let move = rule(mapRemote("b.test"))
        let newHost = rule(when: [ConditionRow(field: .host, op: .equals, value: "b.test")], setHeader("X-New", "1"))
        let oldHost = rule(when: [ConditionRow(field: .host, op: .equals, value: "a.test")], setHeader("X-Old", "1"))
        let decision = try evaluate(request(), snapshot(move, newHost, oldHost))
        #expect(decision.effectiveHead.headers.values(for: "X-New") == ["1"])
        #expect(decision.effectiveHead.headers.values(for: "X-Old").isEmpty)
        #expect(decision.carry?.target.host == "b.test")
    }

    @Test func laterRuleReadsEarlierCommentAction() throws {
        let note = rule(comment("slow"))
        let reader = rule(
            when: [ConditionRow(field: .comment, op: .contains, value: "slow")], setHeader("X-Slow", "1"))
        let decision = try evaluate(request(), snapshot(note, reader))
        #expect(decision.effectiveHead.headers.values(for: "X-Slow") == ["1"])
        // The comment the flow came with is read too, and the rules above add to it.
        let both = rule(
            when: [ConditionRow(field: .comment, op: .equals, value: "user slow")], setHeader("X-Both", "1"))
        let withUser = try RuleEvaluator.request(
            request(), snapshot: snapshot(note, both), facts: ExchangeFacts(comment: "user"),
            cache: PatternCache(budget: RegexBudget(clock: { .zero })))
        #expect(withUser.effectiveHead.headers.values(for: "X-Both") == ["1"])
    }

    @Test func rulesModifiedConditionSeesAnEarlierHeaderEdit() throws {
        let wasModified = [ConditionRow(field: .rulesModified, op: .equals, value: "true")]
        let edit = rule(setHeader("X-A", "1"))
        let pausing = rule(pause())
        let reader = rule(when: wasModified, setHeader("X-Seen", "1"))
        #expect(try evaluate(request(), snapshot(edit, reader)).effectiveHead.headers.values(for: "X-Seen") == ["1"])
        // A breakpoint is not a modification; the reader above the edit reads the message before it.
        #expect(try evaluate(request(), snapshot(pausing, reader)).effectiveHead.headers.values(for: "X-Seen").isEmpty)
        #expect(try evaluate(request(), snapshot(reader, edit)).effectiveHead.headers.values(for: "X-Seen").isEmpty)
        // What the flow already carried counts.
        let carried = try RuleEvaluator.request(
            request(), snapshot: snapshot(reader), facts: ExchangeFacts(rulesModified: true),
            cache: PatternCache(budget: RegexBudget(clock: { .zero })))
        #expect(carried.effectiveHead.headers.values(for: "X-Seen") == ["1"])
    }

    @Test func ruleDoesNotReEvaluateItsOwnConditionsAfterItsActions() throws {
        let absent = [ConditionRow(field: .requestHeader, name: "X-A", op: .isEmpty)]
        let first = rule(when: absent, setHeader("X-A", "1"), setHeader("X-B", "1"))
        let second = rule(when: absent, setHeader("X-C", "1"))
        let decision = try evaluate(request(), snapshot(first, second))
        // Both actions of the rule run though the first one makes its condition false.
        #expect(decision.matches.outcomes == [outcome(first.id, .applied, 0), outcome(first.id, .applied, 1)])
        #expect(decision.effectiveHead.headers.values(for: "X-B") == ["1"])
        // The rule below reads the header the rule above added.
        #expect(decision.effectiveHead.headers.values(for: "X-C").isEmpty)
    }

    @Test func unknownNotesAreRecordedOnceAsRuleOutcomes() throws {
        let unknownApp = Rule(
            name: "app", order: 0,
            conditions: ConditionGroup(
                mode: .any,
                rows: [
                    ConditionRow(field: .clientApp, name: "name", op: .equals, value: "Safari"),
                    ConditionRow(field: .clientApp, name: "pid", op: .equals, value: "1"),
                ]), actions: [setHeader("X-App", "1")])
        let edit = rule(setHeader("X-E", "1"))
        let hits = RuleHitCounter()
        let decision = try RuleEvaluator.request(
            request(), snapshot: snapshot(unknownApp, edit), hits: hits, facts: ExchangeFacts(app: .unknown),
            cache: PatternCache(budget: RegexBudget(clock: { .zero })))
        #expect(decision.matches.outcomes == [outcome(edit.id, .applied), outcome(unknownApp.id, .appUnknown)])
        #expect(decision.matches.ruleIDs == [edit.id])
        #expect(decision.effectiveHead.headers.values(for: "X-App").isEmpty)
        #expect(hits.count(unknownApp.id) == 0)
        // A virtual client has no app: the row is unknown without a note.
        let virtual = try RuleEvaluator.request(
            request(), snapshot: snapshot(unknownApp), facts: ExchangeFacts(app: .notApplicable),
            cache: PatternCache(budget: RegexBudget(clock: { .zero })))
        #expect(!virtual.matches.hasRecords)
    }

    @Test func carryHoldsTheRequestHeadersAsP1LeftThem() throws {
        let headers = [HeaderField(name: "Accept", value: "*/*")]
        let decision = try evaluate(request(headers: headers), snapshot(rule(setHeader("X-A", "1"))))
        #expect(decision.carry?.requestHeaders == headers + [HeaderField(name: "X-A", value: "1")])
        #expect(decision.carry?.requestHeaders == decision.effectiveHead.headers)
    }

    // MARK: offline switch (R6 D3)

    @Test func offlineBreakpointDoesNotSkipTheBodyRewrite() throws {
        let pauser = rule(pause())
        let rewriter = rule(rewriteBody())
        let snap = snapshot(pauser, rewriter)
        let live = try RuleEvaluator.request(
            request(headers: textHeaders), snapshot: snap, cache: PatternCache(budget: RegexBudget(clock: { .zero })),
            offline: false)
        #expect(live.breakpoint != nil)
        #expect(live.bodyRewrites.isEmpty)
        #expect(live.matches.outcomes == [outcome(pauser.id, .applied), outcome(rewriter.id, .bodySkippedBreakpoint)])

        let offline = try RuleEvaluator.request(
            request(headers: textHeaders), snapshot: snap, cache: PatternCache(budget: RegexBudget(clock: { .zero })),
            offline: true)
        #expect(offline.breakpoint == nil)
        #expect(offline.bodyRewrites.map(\.ruleID) == [rewriter.id])
        #expect(offline.matches.outcomes == [outcome(pauser.id, .applied), outcome(rewriter.id, .applied)])
    }

    @Test func offlineBreakpointStillCountsAsFinalWhenTicked() throws {
        let pauser = rule(pause(final: true))
        let lower = rule(setHeader("X-Low", "1"))
        let decision = try RuleEvaluator.request(
            request(), snapshot: snapshot(pauser, lower), cache: PatternCache(budget: RegexBudget(clock: { .zero })),
            offline: true)
        #expect(decision.breakpoint == nil)
        #expect(decision.matches.outcomes == [outcome(pauser.id, .applied), outcome(pauser.id, .finalStop, 0)])
        #expect(decision.matches.ruleIDs == [pauser.id])
        #expect(decision.effectiveHead.headers.values(for: "X-Low").isEmpty)
        #expect(decision.carry?.finalStop == stop(0, 0))
    }

    @Test func offlineDefaultIsByteIdentical() throws {
        let snap = snapshot(rule(setHeader("X-A", "1")), rule(pause()), rule(rewriteBody()), rule(mapRemote("b.test")))
        func run(_ offline: Bool?) throws -> RequestRuleDecision {
            let cache = PatternCache(budget: RegexBudget(clock: { .zero }))
            if let offline {
                return try RuleEvaluator.request(
                    request(headers: textHeaders), snapshot: snap, cache: cache, offline: offline)
            }
            return try RuleEvaluator.request(request(headers: textHeaders), snapshot: snap, cache: cache)
        }
        let implicit = try run(nil)
        let explicit = try run(false)
        #expect(implicit == explicit)
    }
}
