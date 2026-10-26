import FlowStore
import Foundation

/// What one Execute run reads besides the flows and the rules.
public struct ExecuteEnvironment: Sendable {
    public var assets: ManagedAssetStore
    public var limits: RulesLimits
    /// A fresh one per run (D13), so a pattern Execute switches off never switches off a live rule.
    public var cache: PatternCache
    public var timeZone: TimeZone
    /// `store.makeManagedBody` in the app; tests pass a closure over `.memory`.
    public var makeBody: @Sendable (Data) -> BodyRef
    /// The regular-expression allowance of one flow, shared by all of its points (D8). Tests script its clock.
    var makeAllowance: @Sendable () -> RegexAllowance = { RegexAllowance() }

    public init(
        assets: ManagedAssetStore, limits: RulesLimits = RulesLimits(), cache: PatternCache = PatternCache(),
        timeZone: TimeZone = .current, makeBody: @escaping @Sendable (Data) -> BodyRef
    ) {
        self.assets = assets
        self.limits = limits
        self.cache = cache
        self.timeZone = timeZone
        self.makeBody = makeBody
    }
}

/// A response a rule produced for a captured flow (D9): a returned file or directory entry, a local 404 / 405, a
/// handwritten or preset response. Only the headers the rules decide; no transport fields.
struct LocalResponse: Sendable, Equatable {
    var status: Int
    var reason: String?
    var headers: [HeaderField]
    var body: Data
}

/// One flow through the evaluation points (D8), up to and including the merged outcomes; no overlay yet.
struct ExecuteEvaluation: Sendable {
    var flowID: Int
    var skipped: ExecuteFlowResult.Skip?
    var originals: FlowOriginals?
    /// Nil for a tunnel or a rejected request. After a directory fell back to the network its route is the
    /// one the request goes on with (`carry.remote ?? .original`).
    var request: RequestRuleDecision?
    var response: ResponseRuleDecision?
    /// A response a rule produced (D9).
    var local: LocalResponse?
    /// P0 / P1, P2, P3 in order.
    var annotations: [FlowAnnotation] = []
    /// Merged and relabelled (D3, D12); nil when no rule left a record.
    var matches: RuleMatchSummary?
    var notApplicable = 0

    init(flowID: Int) {
        self.flowID = flowID
    }
}

/// Runs the rules over captured flows offline (spec 4.5, 6.8): the same evaluator as live traffic, point by
/// point, on the original records, with every fact already known. Nothing here touches the network, the hit
/// counts or the store.
public enum ExecuteEngine {
    /// Compiles the run's rule patterns into `cache` once.
    public static func prepare(_ snapshot: RuleSnapshot, cache: PatternCache) {
        for rule in snapshot.evaluationOrder { rule.preparePatterns(in: cache) }
    }

    /// One captured flow through the rules. Throws only `CancellationError`.
    public static func run(_ flow: Flow, snapshot: RuleSnapshot, environment: ExecuteEnvironment) async throws
        -> ExecuteFlowResult
    {
        let evaluation = try await evaluate(flow, snapshot: snapshot, environment: environment)
        let built = try await ExecuteOverlayBuilder.build(evaluation, snapshot: snapshot, environment: environment)
        return ExecuteFlowResult(
            flowID: evaluation.flowID, skipped: evaluation.skipped, matches: built.matches,
            annotations: evaluation.annotations, overlay: built.overlay, notApplicableActions: evaluation.notApplicable)
    }

    /// D8: skips, then P0 for a tunnel row, else P1, the local response (D9), P2 and P3, then the merged
    /// outcomes with the offline relabelling. Throws only `CancellationError`.
    static func evaluate(_ flow: Flow, snapshot: RuleSnapshot, environment: ExecuteEnvironment) async throws
        -> ExecuteEvaluation
    {
        try Task.checkCancellation()
        var evaluation = ExecuteEvaluation(flowID: flow.id)
        guard flow.state != .inProgress, let originals = FlowOriginals.of(flow, timeZone: environment.timeZone) else {
            evaluation.skipped = .inProgress
            return evaluation
        }
        guard !flow.isHidden else {
            evaluation.skipped = .hidden
            return evaluation
        }
        evaluation.originals = originals
        var facts = originals.facts
        facts.comment = ExecuteWriter.baseline(of: flow).comment
        let run = PointsRun(entering: facts, allowance: environment.makeAllowance())
        var summaries: [RuleMatchSummary?] = []

        if originals.isTunnel || originals.request.target?.method.uppercased() == "CONNECT" {
            // P0 alone, as live: its disposition is ignored and nothing after it runs (R3 D18).
            let decision = RuleEvaluator.connect(
                target: HTTPMessageTarget(
                    scheme: "https", host: flow.host, port: flow.port, method: "CONNECT", pathAndQuery: ""),
                snapshot: snapshot, tool: connectTool(of: flow, rules: snapshot.rules), hits: nil, facts: facts, allowance: run.allowance,
                limits: environment.limits, cache: environment.cache)
            evaluation.annotations = decision.annotations
            summaries.append(decision.matches)
            return finish(evaluation, summaries: summaries, snapshot: snapshot)
        }

        // P1.
        let requestHead = originals.request.head
        var requestPeek = BodyPeek.notCollected
        if snapshot.requirements.requestBody {
            requestPeek = originals.request.body.peek(
                headers: originals.request.headers, allowDisk: true, limits: environment.limits)
            try Task.checkCancellation()
        }
        var request: RequestRuleDecision
        do {
            request = try RuleEvaluator.request(
                requestHead, snapshot: snapshot, hits: nil, facts: facts, allowance: run.allowance,
                limits: environment.limits, cache: environment.cache, requestBody: requestPeek, offline: true)
        } catch let rejected as RuleEvaluationError {
            // Rejected: its records and the annotations that ran stay; no response point (D8 ②).
            evaluation.annotations += rejected.annotations
            summaries.append(rejected.matches)
            return completeAfterRejectedRequest(
                evaluation, originals: originals, run: run, summaries: summaries, snapshot: snapshot,
                environment: environment)
        } catch is HTTPMutationError {
            // Only a head that is not a request (never, from `FlowOriginals`): rejected before any rule ran.
            return completeAfterRejectedRequest(
                evaluation, originals: originals, run: run, summaries: summaries, snapshot: snapshot,
                environment: environment)
        }
        evaluation.annotations += request.annotations
        try Task.checkCancellation()

        // The response the response point sees (D8 ③).
        var responseHead: HTTPMessageHead?
        var responsePeek = BodyPeek.notCollected
        var isLocalResponse = false
        func useOriginalResponse() {
            guard let original = originals.response else { return }
            responseHead = original.head
            if snapshot.requirements.responseBody {
                responsePeek = original.body.peek(
                    headers: original.headers, allowDisk: true, limits: environment.limits)
            }
        }
        switch request.route {
        case .original, .remote:
            useOriginalResponse()
        case .local, .localDirectory, .generated:
            switch try await resolveLocal(
                route: request.route, decision: request, snapshot: snapshot, environment: environment) {
            case .response(let local):
                evaluation.local = local
                responseHead = .response(status: local.status, reason: local.reason, headers: local.headers)
                isLocalResponse = true
                if snapshot.requirements.responseBody { responsePeek = peek(local, limits: environment.limits) }
            case .fallBackToNetwork:
                // As live `networkFallback`: the request goes on as the request point left it.
                request.route = request.carry?.remote.map(RuleRoute.remote) ?? .original
                useOriginalResponse()
            case .rejected(let ruleID, let actionIndex):
                request.matches = rejecting(request.matches, ruleID: ruleID, actionIndex: actionIndex)
            }
        case .close:
            break
        }
        try Task.checkCancellation()
        summaries.append(request.matches)
        evaluation.request = request

        // P2.
        if let responseHead {
            do {
                let decided = try RuleEvaluator.response(
                    responseHead, after: request, snapshot: snapshot,
                    requestWasUpgradeCandidate: HTTPMutationValidator.isUpgradeCandidate(originals.request.headers),
                    isLocalResponse: isLocalResponse, hits: nil, facts: run.facts(after: evaluation.annotations),
                    allowance: run.allowance, limits: environment.limits, cache: environment.cache,
                    responseBody: responsePeek, offline: true)
                var response = decided
                // A rule judged here may answer in place of the original response (spec 12.7).
                if let route = response.replacement?.route {
                    var shim = request
                    shim.carry?.finalStop = response.carry.finalStop
                    switch try await resolveLocal(route: route, decision: shim, snapshot: snapshot, environment: environment) {
                    case .response(let local):
                        evaluation.local = local
                        response.effectiveHead = .response(status: local.status, reason: local.reason, headers: local.headers)
                    case .rejected(let ruleID, let actionIndex):
                        response.matches = rejecting(response.matches, ruleID: ruleID, actionIndex: actionIndex)
                    case .fallBackToNetwork: break
                    }
                }
                evaluation.response = response
                evaluation.annotations += response.annotations
                summaries.append(response.matches)
            } catch let rejected as RuleEvaluationError {
                evaluation.annotations += rejected.annotations
                summaries.append(rejected.matches)
            } catch is HTTPMutationError {
                // Only a head that is not a response (never, from `FlowOriginals` or `LocalResponse`).
            }
        }

        // P3.
        let completion = RuleEvaluator.completion(
            after: request, response: evaluation.response, snapshot: snapshot,
            facts: run.facts(after: evaluation.annotations), completion: originals.completion, hits: nil,
            allowance: run.allowance, cache: environment.cache)
        evaluation.annotations += completion.annotations
        summaries.append(completion.matches)
        return finish(evaluation, summaries: summaries, snapshot: snapshot)
    }

    /// The tools' decision the row was captured under (controller ruling over D8: fidelity to live). A tunnel row
    /// with no applied no-decrypt / connect-tunnel / close outcome was tunnelled by the tools (`.tunnel`, so
    /// connect-only actions are `skippedByTool` and cut nothing, as live); one whose rule did that re-fires (`.decrypt`).
    static func connectTool(of flow: Flow, rules: [Rule]) -> ConnectToolDecision {
        guard let outcomes = flow.provenance.ruleMatches?.outcomes, !outcomes.isEmpty else { return .tunnel }
        let byID = Dictionary(rules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ruleDecided = outcomes.contains { outcome in
            guard outcome.code == .applied, let rule = byID[outcome.ruleID] else { return false }
            let index = outcome.actionIndex ?? (rule.actions.count == 1 ? 0 : -1)
            guard rule.actions.indices.contains(index) else { return false }
            switch rule.actions[index].expandingMagicString().kind {
            case .noDecrypt, .returnConnectTunnel, .closeConnection: return true
            default: return false
            }
        }
        return ruleDecided ? .decrypt : .tunnel
    }

    /// P3 after a rejected request point, then the merged outcomes.
    private static func completeAfterRejectedRequest(
        _ evaluation: ExecuteEvaluation, originals: FlowOriginals, run: PointsRun, summaries: [RuleMatchSummary?],
        snapshot: RuleSnapshot, environment: ExecuteEnvironment
    ) -> ExecuteEvaluation {
        var evaluation = evaluation
        var summaries = summaries
        let completion = RuleEvaluator.completion(
            afterRejectedRequest: originals.request.head, snapshot: snapshot,
            facts: run.facts(after: evaluation.annotations), completion: originals.completion, hits: nil,
            allowance: run.allowance, cache: environment.cache)
        evaluation.annotations += completion.annotations
        summaries.append(completion.matches)
        return finish(evaluation, summaries: summaries, snapshot: snapshot)
    }

    /// What every point of one flow shares: the facts as the flow entered, and the regular-expression allowance.
    private struct PointsRun {
        var entering: ExchangeFacts
        var allowance: RegexAllowance

        /// The facts a later point enters with: the baseline comment with the earlier points' comment actions
        /// applied (as `ExchangeRuleSession`).
        func facts(after annotations: [FlowAnnotation]) -> ExchangeFacts {
            var facts = entering
            facts.comment = annotations.reduce(entering.comment) { comment, annotation in
                if case .comment(let action) = annotation { return action.applying(to: comment) }
                return comment
            }
            return facts
        }
    }

    /// Merges the points' records (each rule once, outcomes in order) and relabels what needs a connection.
    private static func finish(_ evaluation: ExecuteEvaluation, summaries: [RuleMatchSummary?], snapshot: RuleSnapshot)
        -> ExecuteEvaluation
    {
        var evaluation = evaluation
        guard let merged = ExecuteOutcomes.merge(summaries, revision: snapshot.revision) else { return evaluation }
        let relabelled = ExecuteOutcomes.relabelOffline(merged, rules: snapshot.rules)
        evaluation.matches = relabelled.summary
        evaluation.notApplicable = relabelled.notApplicable
        return evaluation
    }

    /// The local response body as a body row reads it (the same caps as a captured body).
    private static func peek(_ local: LocalResponse, limits: RulesLimits) -> BodyPeek {
        guard local.body.count <= limits.conditionBodyBytes else { return .skipped(.bodyTooLarge) }
        return BodyPeek.decode(local.body, headers: local.headers, limits: limits)
    }

    /// The local route's action that could not produce its response: its `applied` outcome becomes `rejected`.
    private static func rejecting(_ summary: RuleMatchSummary, ruleID: UUID, actionIndex: Int?) -> RuleMatchSummary {
        var summary = summary
        if let index = summary.outcomes.firstIndex(where: {
            $0.ruleID == ruleID && $0.actionIndex == actionIndex && $0.code == .applied
        }) {
            summary.outcomes[index].code = .rejected
        }
        return summary
    }
}
