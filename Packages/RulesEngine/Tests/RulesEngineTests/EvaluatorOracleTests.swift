import FlowStore
import Foundation
import Testing

@testable import RulesEngine

/// The old evaluator (frozen in `Oracle/LegacyRuleEvaluatorOracle.swift`) against the new one on
/// migrated rules, at the request point and at the response point. Outside the three intended changes
/// of spec 5.6.3 the results must be identical; the intended changes, and the two pinned differences
/// outside them, are asserted one by one.
@Suite("EvaluatorOracle")
struct EvaluatorOracleTests {
    @Test func scenarioListIsBroadAndNotVacuous() {
        let scenarios = OracleScenarios.requestScenarios
        #expect(scenarios.count >= 20)
        #expect(Set(scenarios.map(\.name)).count == scenarios.count)

        let results = scenarios.map { scenario in OracleRequestResult { try scenario.legacyRequest() } }
        var routes: Set<String> = []
        var failures = 0
        var withOutcomes = 0
        var codes: Set<String> = []
        for result in results {
            if let matches = result.matches, !matches.outcomes.isEmpty { withOutcomes += 1 }
            for outcome in result.matches?.outcomes ?? [] { codes.insert(outcome.code.rawValue) }
            switch result {
            case .decided(_, let route, _, _, _):
                switch route {
                case .original: routes.insert("original")
                case .remote: routes.insert("remote")
                case .local: routes.insert("local")
                case .localDirectory: routes.insert("directory")
                case .generated, .close: Issue.record("legacy evaluator cannot produce an R4 route")
                }
            case .failed: failures += 1
            case .unexpected: Issue.record("legacy evaluator threw something else")
            }
        }
        #expect(routes == ["original", "remote", "local", "directory"])
        #expect(failures >= 3)
        #expect(withOutcomes >= 15)
        let required: Set<String> = [
            "applied", "rejected", "unsupportedUpgradeAction", "patternTimedOut", "patternDisabled",
            "bodySkippedNotText", "bodySkippedTooLarge", "bodySkippedBreakpoint", "bodySkippedLocalRoute",
        ]
        #expect(required.isSubset(of: codes), "missing: \(required.subtracting(codes))")
    }

    @Test(arguments: OracleScenarios.requestScenarios)
    func requestDecisionsMatchTheLegacyEvaluator(_ scenario: OracleScenario) {
        let legacy = OracleRequestResult { try scenario.legacyRequest() }
        let next = OracleRequestResult { try scenario.migratedRequest() }
        #expect(legacy == next)
        if case .unexpected(let error) = next { Issue.record("new evaluator: \(error)") }
    }

    @Test func responseScenarioListIsBroadAndNotVacuous() {
        let scenarios = OracleScenarios.responseScenarios
        #expect(scenarios.count >= 20)
        #expect(Set(scenarios.map(\.name)).count == scenarios.count)

        let results = scenarios.map { scenario in OracleResponseResult { try scenario.legacyResponse() } }
        var failures = 0
        var withOutcomes = 0
        var statusRewrites = 0
        var codes: Set<String> = []
        for result in results {
            if let matches = result.matches, !matches.outcomes.isEmpty { withOutcomes += 1 }
            for outcome in result.matches?.outcomes ?? [] { codes.insert(outcome.code.rawValue) }
            if result.statusRewrite != nil { statusRewrites += 1 }
            switch result {
            case .decided: break
            case .failed: failures += 1
            case .unexpected: Issue.record("legacy evaluator threw something else")
            }
        }
        #expect(failures >= 3)
        #expect(withOutcomes >= 18)
        #expect(statusRewrites >= 3)
        #expect(scenarios.contains { $0.isLocalResponse })
        #expect(scenarios.filter(\.requestWasUpgradeCandidate).count >= 2)
        let required: Set<String> = [
            "applied", "rejected", "unsupportedUpgradeAction", "statusSkippedLocal", "patternTimedOut",
            "patternDisabled", "bodySkippedNoBody", "bodySkippedNotText", "bodySkippedTooLarge",
            "bodySkippedBreakpoint",
        ]
        #expect(required.isSubset(of: codes), "missing: \(required.subtracting(codes))")
    }

    @Test(arguments: OracleScenarios.responseScenarios)
    func responseDecisionsMatchTheLegacyEvaluator(_ scenario: OracleResponseScenario) {
        // The request point the response point builds on is the same too, and it did not fail.
        let legacyRequest = OracleRequestResult { try scenario.requestPoint.legacyRequest() }
        #expect(legacyRequest == OracleRequestResult { try scenario.requestPoint.migratedRequest() })
        if case .decided = legacyRequest {} else { Issue.record("the request point must decide: \(legacyRequest)") }

        let legacy = OracleResponseResult { try scenario.legacyResponse() }
        let next = OracleResponseResult { try scenario.migratedResponse() }
        #expect(legacy == next)
        if case .unexpected(let error) = next { Issue.record("new evaluator: \(error)") }
    }

    // MARK: intended differences (spec 5.6.3)

    /// Class 1. Old: the lower rule still runs after Map Local. New: Map Local is final.
    @Test func classOneMapLocalThenLowerRule() throws {
        let (higher, lower, scenario) = OracleScenarios.classOneMapLocalThenLowerRule()
        let legacy = try scenario.legacyRequest()
        let next = try scenario.migratedRequest()
        #expect(OracleRequestResult { legacy } != OracleRequestResult { next })

        #expect(legacy.route == .local(OracleScenarios.localFile))
        #expect(legacy.effectiveHead.headers.values(for: "X-Lower") == ["1"])
        #expect(legacy.matches.ruleIDs == [higher.id, lower.id])
        #expect(
            legacy.matches.outcomes == [
                RuleOutcome(ruleID: higher.id, code: .applied), RuleOutcome(ruleID: lower.id, code: .applied),
            ])

        #expect(next.route == .local(OracleScenarios.localFile))
        #expect(next.effectiveHead.headers.values(for: "X-Lower").isEmpty)
        #expect(next.matches.ruleIDs == [higher.id])
        #expect(
            next.matches.outcomes == [
                RuleOutcome(ruleID: higher.id, code: .applied),
                RuleOutcome(ruleID: higher.id, code: .finalStop, actionIndex: 0),
            ])
    }

    /// Class 2. Old: the lower rule matches the original host. New: it reads the remapped request.
    @Test func classTwoMapRemoteThenLowerHostRule() throws {
        let (higher, lower, scenario) = OracleScenarios.classTwoMapRemoteThenLowerHostRule()
        let legacy = try scenario.legacyRequest()
        let next = try scenario.migratedRequest()
        #expect(OracleRequestResult { legacy } != OracleRequestResult { next })

        #expect(legacy.route == .remote(OracleScenarios.remote("b.test")))
        #expect(legacy.effectiveHead.headers.values(for: "X-Lower") == ["1"])
        #expect(legacy.matches.ruleIDs == [higher.id, lower.id])

        #expect(next.route == .remote(OracleScenarios.remote("b.test")))
        #expect(next.effectiveHead.headers.values(for: "X-Lower").isEmpty)
        #expect(next.matches.ruleIDs == [higher.id])
        #expect(next.matches.outcomes == [RuleOutcome(ruleID: higher.id, code: .applied)])
        #expect(next.carry?.target.host == "b.test")
    }

    /// Class 3. Old: the first Map Remote wins and the second is `shadowed`. New: both run, one after the other.
    @Test func classThreeTwoMapRemotes() throws {
        let (higher, lower, scenario) = OracleScenarios.classThreeTwoMapRemotes()
        let legacy = try scenario.legacyRequest()
        let next = try scenario.migratedRequest()
        #expect(OracleRequestResult { legacy } != OracleRequestResult { next })

        #expect(legacy.route == .remote(OracleScenarios.remote("b.test", path: .replace("/first"))))
        #expect(legacy.matches.outcomes.map(\.code) == [.applied, .shadowed])

        #expect(next.route == .remote(OracleScenarios.remote("c.test", port: 8443, path: .replace("/first"))))
        #expect(
            next.matches.outcomes == [
                RuleOutcome(ruleID: higher.id, code: .applied), RuleOutcome(ruleID: lower.id, code: .applied),
            ])
        #expect(next.carry?.target == OracleScenarios.target(host: "c.test").with(port: 8443, path: "/first"))
    }

    /// Class 3. Old: Map Remote wins and Map Local is `shadowed`. New: Map Local runs after it and is final.
    @Test func classThreeMapRemoteThenMapLocal() throws {
        let (higher, lower, scenario) = OracleScenarios.classThreeMapRemoteThenMapLocal()
        let legacy = try scenario.legacyRequest()
        let next = try scenario.migratedRequest()
        #expect(OracleRequestResult { legacy } != OracleRequestResult { next })

        #expect(legacy.route == .remote(OracleScenarios.remote("b.test")))
        #expect(legacy.matches.outcomes.map(\.code) == [.applied, .shadowed])

        #expect(next.route == .local(OracleScenarios.localFile))
        #expect(
            next.matches.outcomes == [
                RuleOutcome(ruleID: higher.id, code: .applied), RuleOutcome(ruleID: lower.id, code: .applied),
            ])
    }

    /// Class 1 at the response point. Old: response rules run on the Map Local response whatever their
    /// priority. New: rules below the final Map Local stay silent at the response point too.
    @Test func classOneLocalResponseLowerHeaderRule() throws {
        let (higher, lower, scenario) = OracleScenarios.classOneLocalResponseLowerHeaderRule()
        let legacy = try scenario.legacyResponse()
        let next = try scenario.migratedResponse()
        #expect(OracleResponseResult { legacy } != OracleResponseResult { next })

        #expect(legacy.effectiveHead.headers.values(for: "X-Lower") == ["1"])
        #expect(legacy.matches.ruleIDs == [lower.id])
        #expect(legacy.matches.outcomes == [RuleOutcome(ruleID: lower.id, code: .applied)])

        #expect(next.effectiveHead == scenario.response)
        #expect(!next.matches.hasRecords)
        let request = try scenario.requestPoint.migratedRequest()
        #expect(request.carry?.finalStop == RuleCarry.FinalStop(position: 0, actionIndex: 0))
        #expect(request.matches.outcomes.last == RuleOutcome(ruleID: higher.id, code: .finalStop, actionIndex: 0))
    }

    /// Class 2 at the response point. Old: a status range reads the status as it arrived. New: it reads
    /// the status a higher rule rewrote.
    @Test func classTwoStatusThenRangeRule() throws {
        let (higher, lower, scenario) = OracleScenarios.classTwoStatusThenRangeRule()
        let legacy = try scenario.legacyResponse()
        let next = try scenario.migratedResponse()
        #expect(OracleResponseResult { legacy } != OracleResponseResult { next })

        #expect(legacy.statusRewrite == 500)
        #expect(legacy.effectiveHead.headers.values(for: "X-Error").isEmpty)
        #expect(legacy.matches.outcomes == [RuleOutcome(ruleID: higher.id, code: .applied)])

        #expect(next.statusRewrite == 500)
        #expect(next.effectiveHead.headers.values(for: "X-Error") == ["1"])
        #expect(next.matches.ruleIDs == [higher.id, lower.id])
        #expect(
            next.matches.outcomes == [
                RuleOutcome(ruleID: higher.id, code: .applied), RuleOutcome(ruleID: lower.id, code: .applied),
            ])
    }

    /// Class 2 at the response point. Old: a response rule naming the original host still matches after
    /// Map Remote. New: it reads the remapped request and stays silent.
    @Test func classTwoMapRemoteThenResponseRuleOnTheOldHost() throws {
        let (_, lower, scenario) = OracleScenarios.classTwoMapRemoteThenResponseRuleOnTheOldHost()
        let legacy = try scenario.legacyResponse()
        let next = try scenario.migratedResponse()
        #expect(OracleResponseResult { legacy } != OracleResponseResult { next })

        #expect(legacy.effectiveHead.headers.values(for: "X-Cors") == ["1"])
        #expect(legacy.matches.outcomes == [RuleOutcome(ruleID: lower.id, code: .applied)])

        #expect(next.effectiveHead == scenario.response)
        #expect(!next.matches.hasRecords)
    }

    /// Class 3 at the response point. Old: the first status rewrite wins and the second is `shadowed`.
    /// New: both run, and the second one's status is the one sent.
    @Test func classThreeTwoStatusRewrites() throws {
        let (higher, lower, scenario) = OracleScenarios.classThreeTwoStatusRewrites()
        let legacy = try scenario.legacyResponse()
        let next = try scenario.migratedResponse()
        #expect(OracleResponseResult { legacy } != OracleResponseResult { next })

        #expect(legacy.statusRewrite == 500)
        #expect(
            legacy.matches.outcomes == [
                RuleOutcome(ruleID: higher.id, code: .applied), RuleOutcome(ruleID: lower.id, code: .shadowed),
            ])

        #expect(next.statusRewrite == 404)
        #expect(next.effectiveHead == .response(status: 404, reason: nil, headers: []))
        #expect(
            next.matches.outcomes == [
                RuleOutcome(ruleID: higher.id, code: .applied), RuleOutcome(ruleID: lower.id, code: .applied),
            ])
    }

    /// Class 2, extended (controller ruling: spec 5.5.2 as written, "P2 reads the final request, all P1
    /// actions executed"): a response-judged rule ABOVE a lower-priority URL changer. Old: the rule
    /// matched the original request at the response. New: the response point reads the request after
    /// every request-point action, including the lower rule's Map Remote, so the higher rule's host no
    /// longer matches. Task 6's MigrationAnalyzer lists this pair.
    @Test func classTwoExtensionResponseJudgedRuleAboveALowerURLChanger() throws {
        let (higher, lower, scenario) = OracleScenarios.classTwoExtensionResponseJudgedRuleAboveALowerURLChanger()
        let legacy = try scenario.legacyResponse()
        let next = try scenario.migratedResponse()
        #expect(OracleResponseResult { legacy } != OracleResponseResult { next })

        // The request point is the same: the higher rule waits for the response, the lower one moves the request.
        let legacyRequest = try scenario.requestPoint.legacyRequest()
        let migratedRequest = try scenario.requestPoint.migratedRequest()
        #expect(OracleRequestResult { legacyRequest } == OracleRequestResult { migratedRequest })
        #expect(migratedRequest.route == .remote(OracleScenarios.remote("b.test")))
        #expect(migratedRequest.matches.outcomes == [RuleOutcome(ruleID: lower.id, code: .applied)])
        #expect(migratedRequest.carry?.target.host == "b.test")

        #expect(legacy.effectiveHead.headers.values(for: "X-Error-Origin") == ["a"])
        #expect(legacy.matches.ruleIDs == [higher.id])
        #expect(legacy.matches.outcomes == [RuleOutcome(ruleID: higher.id, code: .applied)])

        #expect(next.effectiveHead == scenario.response)
        #expect(!next.matches.hasRecords)
    }

    // MARK: differences outside spec 5.6.3, pinned (same traffic bytes, different diagnostics)

    /// D18: a group runs its cheap rows before its regular-expression rows. The old matcher ran the host
    /// regular expression before the path, so a host pattern that timed out (or was switched off) was
    /// reported even when the path would not have matched; the new evaluator stops at the path and never
    /// runs the pattern. Head, route and breakpoint are the same; the outcome list and the breaker count differ.
    @Test func differenceCheapRowsRunBeforeAHostRegex() throws {
        let rule = OracleScenarios.rule(
            RuleMatcher(hostPattern: OracleScenarios.slowHostRegex, path: .exact("/elsewhere"), hostSyntax: .regex),
            .mapRemote(OracleScenarios.remote("b.test")))
        let head = OracleScenarios.get(host: OracleScenarios.slowHost)
        let legacySnapshot = LegacyRuleSnapshot(revision: 11, rules: [rule])
        let migratedSnapshot = RuleSnapshot(revision: 11, rules: [Rule(migrating: rule)])

        // Timed out.
        let legacyCache = OracleScenarios.steppingCache()
        let migratedCache = OracleScenarios.steppingCache()
        let legacy = try LegacyRuleEvaluator.request(head, snapshot: legacySnapshot, cache: legacyCache)
        let next = try RuleEvaluator.request(head, snapshot: migratedSnapshot, cache: migratedCache)
        #expect(legacy.matches.outcomes == [RuleOutcome(ruleID: rule.id, code: .patternTimedOut)])
        #expect(next.matches.outcomes.isEmpty)
        #expect(try legacyCache.regex(OracleScenarios.slowHostRegex, caseInsensitive: true).timeoutCount == 1)
        #expect(try migratedCache.regex(OracleScenarios.slowHostRegex, caseInsensitive: true).timeoutCount == 0)
        #expect(legacy.effectiveHead == next.effectiveHead)
        #expect(legacy.route == .original)
        #expect(next.route == .original)
        #expect(legacy.breakpoint == next.breakpoint)

        // Switched off.
        let disabled = {
            OracleScenarios.disabledCache(
                OracleScenarios.slowHostRegex, caseInsensitive: true, slowInput: OracleScenarios.slowHost)
        }
        let legacyOff = try LegacyRuleEvaluator.request(head, snapshot: legacySnapshot, cache: disabled())
        let migratedOff = try RuleEvaluator.request(head, snapshot: migratedSnapshot, cache: disabled())
        #expect(legacyOff.matches.outcomes == [RuleOutcome(ruleID: rule.id, code: .patternDisabled)])
        #expect(migratedOff.matches.outcomes.isEmpty)
        #expect(legacyOff.effectiveHead == migratedOff.effectiveHead)
        #expect(legacyOff.route == migratedOff.route)

        // Where the path does match, both report the problem the same way.
        let matchingPath = OracleScenarios.rule(
            RuleMatcher(hostPattern: OracleScenarios.slowHostRegex, path: .prefix("/v1/"), hostSyntax: .regex),
            .mapRemote(OracleScenarios.remote("b.test")))
        let scenario = OracleScenario(
            "hostRegexBehindAMatchingPath", request: head, cache: OracleScenarios.steppingCache, [matchingPath])
        #expect(
            OracleRequestResult { try scenario.legacyRequest() } == OracleRequestResult { try scenario.migratedRequest() })
    }

    /// A response rule whose conditions are known at the request is judged at the request point (spec
    /// 5.5.8). When its regular expression times out there, the request decision now carries
    /// `patternTimedOut`; the old evaluator ran response rules only when the response arrived, so its
    /// request decision had nothing (and a flow without a response never mentioned the rule) and its
    /// response decision reported the timeout. Ruled acceptable in Task 4 (diagnostics only).
    @Test func differenceResponseRuleRegexProblemIsReportedAtTheRequestPoint() throws {
        let rule = OracleScenarios.rule(
            RuleMatcher(path: .regex(OracleScenarios.slowPathRegex)),
            OracleScenarios.edit(.response, .append(name: "X-R", value: "1")))
        let head = OracleScenarios.get(path: OracleScenarios.slowPath)
        let legacyCache = OracleScenarios.steppingCache()
        let migratedCache = OracleScenarios.steppingCache()
        let legacy = try LegacyRuleEvaluator.request(
            head, snapshot: LegacyRuleSnapshot(revision: 11, rules: [rule]), cache: legacyCache)
        let next = try RuleEvaluator.request(
            head, snapshot: RuleSnapshot(revision: 11, rules: [Rule(migrating: rule)]), cache: migratedCache)
        #expect(legacy.matches.outcomes.isEmpty)
        #expect(next.matches.outcomes == [RuleOutcome(ruleID: rule.id, code: .patternTimedOut)])
        #expect(next.matches.ruleIDs.isEmpty)
        #expect(next.carry?.pending.isEmpty == true)
        #expect(try legacyCache.regex(OracleScenarios.slowPathRegex, caseInsensitive: false).timeoutCount == 0)
        #expect(try migratedCache.regex(OracleScenarios.slowPathRegex, caseInsensitive: false).timeoutCount == 1)
        #expect(legacy.effectiveHead == next.effectiveHead)
        #expect(legacy.route == next.route)

        // At the response point it is the other way round: the old evaluator reports the problem
        // there, the new one has nothing left to say (the rule did not match at the request point).
        let response = OracleScenarios.response()
        let target = try #require(head.requestTarget)
        let legacyResponse = try LegacyRuleEvaluator.response(
            response, request: target, snapshot: LegacyRuleSnapshot(revision: 11, rules: [rule]), cache: legacyCache)
        let migratedResponse = try RuleEvaluator.response(
            response, after: next, snapshot: RuleSnapshot(revision: 11, rules: [Rule(migrating: rule)]),
            cache: migratedCache)
        #expect(legacyResponse.matches.outcomes == [RuleOutcome(ruleID: rule.id, code: .patternTimedOut)])
        #expect(!migratedResponse.matches.hasRecords)
        #expect(legacyResponse.effectiveHead == migratedResponse.effectiveHead)
        #expect(try legacyCache.regex(OracleScenarios.slowPathRegex, caseInsensitive: false).timeoutCount == 1)
        #expect(try migratedCache.regex(OracleScenarios.slowPathRegex, caseInsensitive: false).timeoutCount == 1)
    }
}

extension HTTPMessageTarget {
    fileprivate func with(port: Int, path: String) -> HTTPMessageTarget {
        HTTPMessageTarget(scheme: scheme, host: host, port: port, method: method, pathAndQuery: path)
    }
}

extension HTTPMessageHead {
    fileprivate var requestTarget: HTTPMessageTarget? {
        if case .request(let target, _) = self { return target }
        return nil
    }
}
