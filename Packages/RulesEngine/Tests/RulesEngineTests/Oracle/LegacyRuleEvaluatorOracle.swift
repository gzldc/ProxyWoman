// FROZEN ORACLE. Do not edit.
//
// A verbatim copy of `RuleEvaluator` as it was before Rules 2.0 (RulesEngine/RuleEvaluator.swift at
// 72995a7), with only the type names changed: the evaluator is `LegacyRuleEvaluator` and the old
// model it reads is `LegacyRuleSnapshot` / `LegacyRule` / `LegacyRuleAction`. The decision and outcome
// types it builds are the module's own, so its results compare field by field with `RuleEvaluator`'s
// (EvaluatorOracleTests). The production copy was deleted in Task 13; this one stays as the reference
// for "behaves like before" (spec 5.6.5).

import Foundation
import FlowStore
@testable import RulesEngine

/// Pure, deterministic rule evaluation. Request rules match the original request; response rules
/// match the same original request and the response before any rule touched it. A rewrite never
/// triggers another match.
public enum LegacyRuleEvaluator {
    public static func request(
        _ original: HTTPMessageHead, snapshot: LegacyRuleSnapshot, limits: RulesLimits = RulesLimits(),
        cache: PatternCache = .shared
    ) throws -> RequestRuleDecision {
        guard case .request(let target, let originalHeaders) = original else {
            throw HTTPMutationError(code: .messageKindMismatch, field: .message)
        }
        let upgrade = HTTPMutationValidator.isUpgradeCandidate(originalHeaders)
        var headers = originalHeaders
        var route = RuleRoute.original
        var breakpoint: BreakpointPauseMode?
        var ids: [UUID] = []
        var edits: Set<UUID> = []
        var outcomes: [RuleOutcome] = []
        var patternProblems: [RuleOutcome] = []
        var bodyCandidates: [BodyCandidate] = []

        do {
            for rule in snapshot.orderedEnabledRules where rule.action.direction == .request
                && Self.matched(rule, target, status: nil, cache: cache, problems: &patternProblems) {
                ids.append(rule.id)
                var code = RuleOutcomeCode.applied
                switch rule.action {
                case .editHeaders(_, let operations):
                    edits.insert(rule.id)
                    try HTTPMutationValidator.validateEdits(operations, originalHeaders: originalHeaders, upgradeCandidate: upgrade)
                    headers = headers.applying(operations)
                case .mapLocal(let local):
                    if upgrade { code = .unsupportedUpgradeAction }
                    else if case .original = route { route = .local(local) }
                    else { code = .shadowed }
                case .mapLocalDirectory(let directory):
                    if upgrade { code = .unsupportedUpgradeAction }
                    else if case .original = route {
                        // Validation requires a prefix path; any other matcher (a stale or hand-edited
                        // snapshot) has no directory prefix to resolve against, so it fails closed.
                        let subpath: DirectorySubpath
                        if case .prefix(let prefix) = rule.matcher.path {
                            subpath = DirectorySubpath.resolve(pathAndQuery: target.pathAndQuery, prefix: prefix)
                        } else {
                            subpath = .unsafe
                        }
                        route = .localDirectory(DirectoryRoute(
                            action: directory,
                            subpath: subpath,
                            method: target.method))
                    }
                    else { code = .shadowed }
                case .mapRemote(let remote):
                    if upgrade { code = .unsupportedUpgradeAction }
                    else if case .original = route { route = .remote(remote) }
                    else { code = .shadowed }
                case .breakpoint(_, let mode):
                    if upgrade { code = .unsupportedUpgradeAction } else { breakpoint = merged(breakpoint, mode) }
                case .rewriteBody(_, let body):
                    // Provisional: the message-level checks below need the final headers and route.
                    bodyCandidates.append(BodyCandidate(step: BodyRewriteStep(ruleID: rule.id, action: body), outcomeIndex: outcomes.count))
                case .rewriteStatus:
                    continue  // Unreachable: status rewrites run on responses.
                }
                outcomes.append(RuleOutcome(ruleID: rule.id, code: code))
            }
            var localRoute = false
            switch route {
            case .local, .localDirectory: localRoute = true
            case .original, .remote, .generated, .close: break
            }
            let skip = bodyCandidates.isEmpty ? nil : bodySkip(
                headers: headers, response: nil, upgrade: upgrade, breakpoint: breakpoint != nil,
                localRoute: localRoute, limits: limits)
            let bodyRewrites = Self.resolve(bodyCandidates, skip: skip, outcomes: &outcomes)
            if headers != originalHeaders {
                try HTTPMutationValidator.validateBlock(headers, trailers: false, limits: limits)
            }
            return RequestRuleDecision(
                effectiveHead: .request(target, headers: headers), route: route, breakpoint: breakpoint,
                matches: RuleMatchSummary(
                    revision: snapshot.revision, ruleIDs: ids, total: ids.count, outcomes: outcomes + patternProblems),
                bodyRewrites: bodyRewrites)
        } catch let mutation as HTTPMutationError {
            throw RuleEvaluationError(mutation: mutation, matches: RuleMatchSummary(
                revision: snapshot.revision, ruleIDs: ids, total: ids.count,
                outcomes: rejected(outcomes, ids: ids, edits: edits) + patternProblems))
        }
    }

    /// `requestWasUpgradeCandidate` keeps an exchange that asked to switch protocols out of
    /// breakpoints even when the origin answers with a plain failure. `isLocalResponse` marks a
    /// response the proxy produced itself (Map Local); only status rewrites that opted in touch it.
    public static func response(
        _ original: HTTPMessageHead, request target: HTTPMessageTarget, snapshot: LegacyRuleSnapshot,
        requestWasUpgradeCandidate: Bool = false, isLocalResponse: Bool = false, limits: RulesLimits = RulesLimits(),
        cache: PatternCache = .shared
    ) throws -> ResponseRuleDecision {
        guard case .response(let status, let reason, let originalHeaders) = original else {
            throw HTTPMutationError(code: .messageKindMismatch, field: .message)
        }
        let upgrade = requestWasUpgradeCandidate || status == 101 || HTTPMutationValidator.isUpgradeCandidate(originalHeaders)
        var headers = originalHeaders
        var breakpoint: BreakpointPauseMode?
        var ids: [UUID] = []
        var edits: Set<UUID> = []
        var outcomes: [RuleOutcome] = []
        var patternProblems: [RuleOutcome] = []
        var bodyCandidates: [BodyCandidate] = []
        var statusRewrite: Int?

        do {
            for rule in snapshot.orderedEnabledRules where rule.action.direction == .response
                && Self.matched(rule, target, status: status, cache: cache, problems: &patternProblems) {
                ids.append(rule.id)
                var code = RuleOutcomeCode.applied
                switch rule.action {
                case .editHeaders(_, let operations):
                    edits.insert(rule.id)
                    try HTTPMutationValidator.validateEdits(operations, originalHeaders: originalHeaders, upgradeCandidate: upgrade)
                    headers = headers.applying(operations)
                case .breakpoint(_, let mode):
                    if upgrade { code = .unsupportedUpgradeAction } else { breakpoint = merged(breakpoint, mode) }
                case .mapLocal, .mapLocalDirectory, .mapRemote:
                    continue  // Unreachable: map actions run on requests.
                case .rewriteBody(_, let body):
                    bodyCandidates.append(BodyCandidate(step: BodyRewriteStep(ruleID: rule.id, action: body), outcomeIndex: outcomes.count))
                case .rewriteStatus(let rewrite):
                    // The first rule that can act wins; a rule skipped for a local response does not shadow later ones.
                    if upgrade { code = .unsupportedUpgradeAction }
                    else if isLocalResponse && !rewrite.includeLocalResponses { code = .statusSkippedLocal }
                    else if statusRewrite == nil { statusRewrite = rewrite.status }
                    else { code = .shadowed }
                }
                outcomes.append(RuleOutcome(ruleID: rule.id, code: code))
            }
            let skip = bodyCandidates.isEmpty ? nil : bodySkip(
                headers: headers, response: ResponseFacts(status: statusRewrite ?? status, requestMethod: target.method),
                upgrade: upgrade, breakpoint: breakpoint != nil, localRoute: false, limits: limits)
            let bodyRewrites = Self.resolve(bodyCandidates, skip: skip, outcomes: &outcomes)
            if headers != originalHeaders {
                try HTTPMutationValidator.validateBlock(headers, trailers: false, limits: limits)
            }
            return ResponseRuleDecision(
                effectiveHead: .response(status: statusRewrite ?? status, reason: statusRewrite == nil ? reason : nil, headers: headers),
                breakpoint: breakpoint,
                matches: RuleMatchSummary(
                    revision: snapshot.revision, ruleIDs: ids, total: ids.count, outcomes: outcomes + patternProblems),
                bodyRewrites: bodyRewrites, statusRewrite: statusRewrite)
        } catch let mutation as HTTPMutationError {
            throw RuleEvaluationError(mutation: mutation, matches: RuleMatchSummary(
                revision: snapshot.revision, ruleIDs: ids, total: ids.count,
                outcomes: rejected(outcomes, ids: ids, edits: edits) + patternProblems))
        }
    }

    private struct BodyCandidate {
        var step: BodyRewriteStep
        /// Position of the rule's provisional outcome in `outcomes`.
        var outcomeIndex: Int
    }

    private struct ResponseFacts {
        var status: Int
        var requestMethod: String
    }

    /// Why no body rule of this message can run, from the message alone (the effective headers,
    /// status and route). Nil: the executor collects the body. The checks are ordered so the most
    /// specific reason wins; an unknown length is never a reason (the collector enforces the cap).
    private static func bodySkip(
        headers: [HeaderField], response: ResponseFacts?, upgrade: Bool, breakpoint: Bool, localRoute: Bool,
        limits: RulesLimits
    ) -> RuleOutcomeCode? {
        if upgrade { return .unsupportedUpgradeAction }
        if breakpoint { return .bodySkippedBreakpoint }
        if localRoute { return .bodySkippedLocalRoute }
        let lengths = headers.values(for: "content-length").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }
        if let response {
            let noStatusBody = (100...199).contains(response.status) || response.status == 204 || response.status == 304
            if response.requestMethod.uppercased() == "HEAD" || noStatusBody
                || lengths.first.flatMap({ Int($0) }) == 0 { return .bodySkippedNoBody }
        }
        guard BodyTextCodec.isTextLike(contentType: headers.values(for: "content-type").first) else {
            return .bodySkippedNotText
        }
        // Digits that do not fit an Int are larger than any cap.
        if lengths.contains(where: { Int($0).map { $0 > limits.rewriteBodyBytes } ?? true }) { return .bodySkippedTooLarge }
        return nil
    }

    /// Applies the message-level verdict to every body candidate: the steps to run, or each rule's
    /// provisional outcome replaced by the skip code.
    private static func resolve(
        _ candidates: [BodyCandidate], skip: RuleOutcomeCode?, outcomes: inout [RuleOutcome]
    ) -> [BodyRewriteStep] {
        guard let skip else { return candidates.map(\.step) }
        for candidate in candidates {
            outcomes[candidate.outcomeIndex] = RuleOutcome(ruleID: candidate.step.ruleID, code: skip)
        }
        return []
    }

    /// Whether the rule matched. A rule whose regular expression timed out or is disabled did not
    /// match, but it is recorded in `problems` so the flow can say why the rule stayed silent.
    private static func matched(
        _ rule: LegacyRule, _ target: HTTPMessageTarget, status: Int?, cache: PatternCache,
        problems: inout [RuleOutcome]
    ) -> Bool {
        switch rule.matcher.evaluate(target, status: status, cache: cache) {
        case .matched: return true
        case .noMatch: return false
        case .patternTimedOut:
            problems.append(RuleOutcome(ruleID: rule.id, code: .patternTimedOut))
            return false
        case .patternDisabled:
            problems.append(RuleOutcome(ruleID: rule.id, code: .patternDisabled))
            return false
        }
    }

    /// A failed evaluation never reports an edit as applied: the rule whose own edit failed is
    /// `.rejected` (earlier rules keep their outcome); when the combined block failed after every
    /// edit validated on its own, all header-edit rules that built it are `.rejected`.
    private static func rejected(_ outcomes: [RuleOutcome], ids: [UUID], edits: Set<UUID>) -> [RuleOutcome] {
        if let failing = ids.last, outcomes.count < ids.count {
            return outcomes + [RuleOutcome(ruleID: failing, code: .rejected)]
        }
        return outcomes.map { outcome in
            edits.contains(outcome.ruleID) && outcome.code == .applied ? RuleOutcome(ruleID: outcome.ruleID, code: .rejected) : outcome
        }
    }

    private static func merged(_ current: BreakpointPauseMode?, _ mode: BreakpointPauseMode) -> BreakpointPauseMode {
        current == .fullBody || mode == .fullBody ? .fullBody : .headers
    }
}
