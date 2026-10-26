import FlowStore
import Foundation
import NIOCore
import NIOHTTP1
import OSLog
import RulesEngine

/// Per-exchange overrides of the ordinary proxy behaviour (Compose sends use `retry: .never`).
struct HTTPExecutionPolicy {
    var rulesEnabled: Bool
    var retry: HTTPRetryPolicy
    /// The target was chosen explicitly (Compose), not read from a client's proxy request: like a
    /// Map Remote target, it must never be one of this proxy's own listener endpoints.
    var rejectsListener: Bool
    /// The flow is recorded even while capture recording is paused (an explicit Compose send).
    var recordsWhilePaused: Bool
    /// The client side is a virtual endpoint (Compose): its messages are recorded as the
    /// `composeSubmitted` / `composeDelivered` boundaries, never as downstream wire messages.
    var virtualClient: Bool
    /// Only http/1.1 is offered upstream, on connections kept apart from automatic ones.
    var http1Only: Bool

    init(rulesEnabled: Bool = true, retry: HTTPRetryPolicy = .existingProxyPolicy, rejectsListener: Bool = false,
         recordsWhilePaused: Bool = false, virtualClient: Bool = false, http1Only: Bool = false) {
        self.rulesEnabled = rulesEnabled
        self.retry = retry
        self.rejectsListener = rejectsListener
        self.recordsWhilePaused = recordsWhilePaused
        self.virtualClient = virtualClient
        self.http1Only = http1Only
    }
}

enum HTTPRetryPolicy {
    /// The reviewed HTTP/1 stale-connection replay of small, complete, idempotent requests.
    case existingProxyPolicy
    /// No implicit replay at all.
    case never
}

/// What execution continues with once the request rules (and, later, a breakpoint) decided.
enum ExchangeRuleContinuation {
    /// Forward `head` (the effective target and fields) with the client's body, or with `body`.
    case network(head: HTTPMessageHead, body: ExactBodySource?)
    /// Answer with a Map Local response instead of the network.
    case local(MapLocalAction)
    /// Answer from a mapped directory. Nothing is claimed until the file is resolved, so a missing
    /// file may still continue on the network with the untouched upload (spec section 4).
    case localDirectory(DirectoryRoute)
    /// Answer with a handwritten or preset response (D17): the local response pipeline, then the response point.
    case generated(GeneratedResponse)
    /// Close the connection (or the HTTP/2 stream) without a response (D15); `ruleName` names the closing rule.
    case close(RulesEngine.CloseMode, ruleName: String)
}

/// A rule could not be carried out: the exchange ends with one local failure carrying `code`.
struct ExchangeRuleFailure: Error, Equatable {
    let code: HTTPLocalFailureCode
    let message: String

    static func rejected(_ error: HTTPMutationError) -> Self {
        Self(code: .ruleRejected, message: HTTPLocalFailureText.ruleRejected(code: error.code.rawValue))
    }
    static func unsupported(_ action: String) -> Self {
        Self(code: .ruleActionUnsupported, message: HTTPLocalFailureText.ruleActionUnsupported(action: action))
    }
    static func selfTarget(_ authority: String) -> Self {
        Self(code: .ruleSelfTarget, message: HTTPLocalFailureText.ruleSelfTarget(authority: authority))
    }
}

/// The rules of one exchange: the snapshot frozen when its request head was admitted, used for the
/// request point and for the response point alike, so the response point always continues the
/// request point's decision (its carry). Each point is prepared exactly once. A rule's conditions read
/// the exchange as the higher-priority rules left it, and a final action silences everything below it
/// for the whole exchange (spec 5.5). An outcome names its action (`actionIndex`) when its rule has
/// several, and every per-action record here follows that name.
/// Confined to the exchange's event loop.
final class ExchangeRuleSession {
    let snapshot: RuleSnapshot
    /// The provider's hit counts, for occurrence ranges; nil ignores them.
    private let hits: RuleHitCounter?
    let originalRequest: HTTPMessageHead
    let originalTarget: HTTPMessageTarget
    private(set) var provenance: FlowProvenance
    private(set) var requestDecision: RequestRuleDecision?
    private var responseMatches: RuleMatchSummary?
    private(set) var responseDecision: ResponseRuleDecision?
    /// Body actions whose final outcome replaced the provisional one; each action is settled once.
    private var settledBodyActions: Set<ActionKey> = []
    private let upgradeCandidate: Bool
    private let factsSource: FactsSource
    /// The exchange's one regular-expression allowance, shared by both points (D11).
    let allowance: RegexAllowance
    /// The evaluation running off the event loop, if any.
    private var offLoopTask: Task<Void, Never>?
    /// The comment as the rules left it after the request point; nil until that point ran. A comment the
    /// user edits during the exchange is not seen again.
    private var commentAfterRequest: String??
    /// What the rules did to the flow's record since the last `drainAnnotations`.
    private var pendingAnnotations: [FlowAnnotation] = []
    /// The snapshot's rules by id, for the action an outcome names.
    private lazy var rulesByID = Dictionary(snapshot.evaluationOrder.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    init(snapshot: RuleSnapshot, hits: RuleHitCounter?, originalRequest: HTTPMessageHead, provenance: FlowProvenance,
         factsSource: FactsSource = FactsSource(), allowance: RegexAllowance = RegexAllowance()) {
        guard case .request(let target, let headers) = originalRequest else {
            preconditionFailure("a rule session starts from a request head")
        }
        self.snapshot = snapshot
        self.hits = hits
        self.originalRequest = originalRequest
        self.originalTarget = target
        self.provenance = provenance
        self.upgradeCandidate = HTTPMutationValidator.isUpgradeCandidate(headers)
        self.factsSource = factsSource
        self.allowance = allowance
    }

    /// Where the exchange reads what the proxy knows besides the messages. All closures run on the
    /// exchange's event loop.
    struct FactsSource {
        var clientIP: () -> String? = { nil }
        var remoteIP: () -> String? = { nil }
        var clientHTTPVersion: () -> HTTPWireVersion? = { nil }
        var upstreamHTTPVersion: () -> HTTPWireVersion? = { nil }
        var clientTLSVersion: () -> String? = { nil }
        var upstreamTLSVersion: () -> String? = { nil }
        var certificate: () -> CertificateSummary? = { nil }
        var app: () -> ExchangeFacts.AppLookup = { .notApplicable }
        var comment: () -> String? = { nil }
        var requestStartedAt = Date()
    }

    /// Whether an enabled rule has a comment row: only then is the flow's comment read.
    private lazy var readsComment = snapshot.evaluationOrder.contains { $0.conditions.rows.contains { $0.field == .comment } }

    /// The facts for the point about to be evaluated: the source's, the provenance's `rulesModified`
    /// as it is now, and the comment including what the request point's rules wrote. The comment and
    /// the client app are only read when a row needs them (the comment costs a store lock and a flow copy).
    func facts() -> ExchangeFacts {
        ExchangeFacts(
            clientIP: factsSource.clientIP(), remoteIP: factsSource.remoteIP(),
            clientHTTPVersion: factsSource.clientHTTPVersion(), upstreamHTTPVersion: factsSource.upstreamHTTPVersion(),
            clientTLSVersion: factsSource.clientTLSVersion(), upstreamTLSVersion: factsSource.upstreamTLSVersion(),
            certificate: factsSource.certificate(),
            app: snapshot.requirements.clientApp ? factsSource.app() : .notApplicable,
            requestStartedAt: factsSource.requestStartedAt,
            comment: readsComment ? commentAfterRequest ?? factsSource.comment() : nil, rulesModified: provenance.rulesModified)
    }

    private static let log = Logger(subsystem: "ProxyWoman", category: "Rules")
    private static let slowPoint = Duration.milliseconds(2)

    /// Runs `body` and notes (without any rule content) when evaluating a point took over 2 ms.
    private func timed<T>(_ point: String, _ body: () throws -> T) rethrows -> T {
        let clock = ContinuousClock()
        let start = clock.now
        defer {
            let elapsed = start.duration(to: clock.now)
            if elapsed > Self.slowPoint { Self.log.notice("rules \(point, privacy: .public) point took \(elapsed.description, privacy: .public)") }
        }
        return try body()
    }

    /// Takes the annotations collected so far (both points, success and rejection alike) and clears them.
    func drainAnnotations() -> [FlowAnnotation] {
        defer { pendingAnnotations.removeAll() }
        return pendingAnnotations
    }

    /// The request point: header edits in rule order, the composed route and the merged breakpoint.
    /// `limits` supplies the body rewrite cap the known-length check uses.
    func prepareRequest(limits: RulesLimits = RulesLimits()) throws -> RequestRuleDecision {
        precondition(requestDecision == nil, "request rules run exactly once")
        let entering = facts()
        return try commitRequest(entering: entering) {
            try timed("request") {
                try RuleEvaluator.request(originalRequest, snapshot: snapshot, hits: hits, facts: entering, allowance: allowance, limits: limits)
            }
        }
    }

    /// The request point of a snapshot with request body conditions (D13): the facts are read here, on
    /// the event loop, and the evaluator then runs in a `Task` with only Sendable inputs (the request
    /// head, snapshot, facts, `peek`, hit counter, allowance and `cache`), so a body regular expression
    /// never runs on the loop. The returned future completes on `loop`, where the decision is recorded
    /// exactly as `prepareRequest` records it; it fails with `ExchangeRuleFailure` like that method throws.
    func prepareRequestOffLoop(peek: BodyPeek, limits: RulesLimits, cache: PatternCache,
                               on loop: EventLoop) -> EventLoopFuture<RequestRuleDecision> {
        loop.preconditionInEventLoop()
        precondition(requestDecision == nil, "request rules run exactly once")
        let entering = facts()
        let original = originalRequest, snapshot = snapshot, hits = hits, allowance = allowance
        return offLoop(on: loop, {
            try RuleEvaluator.request(original, snapshot: snapshot, hits: hits, facts: entering, allowance: allowance,
                                      limits: limits, cache: cache, requestBody: peek)
        }, commit: { try self.commitRequest(entering: entering, $0) })
    }

    /// Runs `evaluate` in a task and hands its result to `commit` on `loop`. A task cancelled by
    /// `cancelOffLoop` before it started evaluates nothing; its future then fails.
    private func offLoop<T: Sendable>(on loop: EventLoop, _ evaluate: @escaping @Sendable () throws -> T,
                                      commit: @escaping (() throws -> T) throws -> T) -> EventLoopFuture<T> {
        let promise = loop.makePromise(of: T.self)
        offLoopTask = promise.completeWithTask {
            try Task.checkCancellation()
            return try evaluate()
        }
        let committed = loop.makePromise(of: T.self)
        promise.futureResult.assumeIsolated().whenComplete { result in
            self.offLoopTask = nil
            committed.completeWith(Result { try commit { try result.get() } })
        }
        return committed.futureResult
    }

    /// The exchange ended: an evaluation that has not started yet never will.
    func cancelOffLoop() {
        offLoopTask?.cancel()
        offLoopTask = nil
    }

    /// Records the request point's decision, or its rejection, on the event loop.
    private func commitRequest(entering: ExchangeFacts, _ evaluate: () throws -> RequestRuleDecision) throws -> RequestRuleDecision {
        do {
            let decision = try evaluate()
            requestDecision = decision
            if readsComment { commentAfterRequest = Self.comment(entering.comment, after: decision.annotations) }
            pendingAnnotations += decision.annotations
            if decision.matches.hasRecords { provenance.ruleMatches = decision.matches }
            if decision.rulesModified { provenance.rulesModified = true }
            return decision
        } catch let error as RuleEvaluationError {
            pendingAnnotations += error.annotations
            if error.matches.hasRecords { provenance.ruleMatches = error.matches }
            throw ExchangeRuleFailure.rejected(error.mutation)
        } catch let error as HTTPMutationError {
            throw ExchangeRuleFailure.rejected(error)
        }
    }

    /// The response point for the original final response head: response header edits, status
    /// rewrites, body steps and breakpoint, after the request decision on the same snapshot.
    /// `isLocalResponse` marks a response the proxy produced itself (Return File). `limits` supplies
    /// the body rewrite cap the known-length check uses.
    func prepareResponse(_ original: HTTPMessageHead, isLocalResponse: Bool = false,
                         limits: RulesLimits = RulesLimits()) throws -> ResponseRuleDecision {
        guard let request = requestDecision else { preconditionFailure("response rules follow the request rules") }
        guard responseMatches == nil else { throw ExchangeRuleFailure.unsupported("repeatedResponse") }
        let entering = facts()
        return try commitResponse {
            try timed("response") {
                try RuleEvaluator.response(
                    original, after: request, snapshot: snapshot, requestWasUpgradeCandidate: upgradeCandidate,
                    isLocalResponse: isLocalResponse, hits: hits, facts: entering, allowance: allowance, limits: limits)
            }
        }
    }

    /// The response point evaluated off the event loop, like `prepareRequestOffLoop` (D13). Ruling (T11
    /// review M2): it runs there whenever the request point peeked the request body, so a request-body
    /// regular expression judged at the response never runs on the loop, or a response body is peeked (`responseBody`).
    func prepareResponseOffLoop(_ original: HTTPMessageHead, isLocalResponse: Bool, limits: RulesLimits,
                                cache: PatternCache, responseBody: BodyPeek = .notCollected,
                                on loop: EventLoop) -> EventLoopFuture<ResponseRuleDecision> {
        loop.preconditionInEventLoop()
        guard let request = requestDecision else { preconditionFailure("response rules follow the request rules") }
        guard responseMatches == nil else { return loop.makeFailedFuture(ExchangeRuleFailure.unsupported("repeatedResponse")) }
        let entering = facts()
        let snapshot = snapshot, upgrade = upgradeCandidate, hits = hits, allowance = allowance
        return offLoop(on: loop, {
            try RuleEvaluator.response(
                original, after: request, snapshot: snapshot, requestWasUpgradeCandidate: upgrade,
                isLocalResponse: isLocalResponse, hits: hits, facts: entering, allowance: allowance, limits: limits, cache: cache,
                responseBody: responseBody)
        }, commit: { try self.commitResponse($0) })
    }

    /// Whether a rule that reads the response body could match this response (`requestMayNeedBody`'s
    /// counterpart): only then is the response held for a peek.
    func responseMayNeedBody(_ original: HTTPMessageHead, cache: PatternCache) -> Bool {
        guard snapshot.requirements.responseBody, let request = requestDecision else { return false }
        return RuleEvaluator.responseMayNeedBody(original, after: request, snapshot: snapshot, facts: facts(), cache: cache)
    }

    /// Records the response point's decision, or its rejection, on the event loop.
    private func commitResponse(_ evaluate: () throws -> ResponseRuleDecision) throws -> ResponseRuleDecision {
        do {
            let decision = try evaluate()
            responseDecision = decision
            pendingAnnotations += decision.annotations
            record(decision.matches)
            if decision.rulesModified { provenance.rulesModified = true }
            return decision
        } catch let error as RuleEvaluationError {
            pendingAnnotations += error.annotations
            record(error.matches)
            throw ExchangeRuleFailure.rejected(error.mutation)
        } catch let error as HTTPMutationError {
            throw ExchangeRuleFailure.rejected(error)
        }
    }

    /// The name of the rule `id` in this snapshot; its id stands in should it not be there.
    func ruleName(of id: UUID) -> String { rulesByID[id]?.name ?? id.uuidString }

    /// What the request decision continues with, before anything is acquired: the effective
    /// target and fields for the network, or the local route.
    func continuation(for decision: RequestRuleDecision) throws -> ExchangeRuleContinuation {
        switch decision.route {
        case .local(let local): return .local(local)
        case .localDirectory(let route): return .localDirectory(route)
        // The decision's route, never the carry's earlier Map Remote: nothing goes upstream.
        case .generated(let response): return .generated(response)
        // A snapshot always holds the rule its route names; the id stands in should it not.
        case .close(let mode, let ruleID): return .close(mode, ruleName: rulesByID[ruleID]?.name ?? ruleID.uuidString)
        case .original, .remote: break
        }
        // Map Remote's preserved path must be origin-form. OPTIONS * is otherwise legal,
        // but cannot be used as a remote routing path without an explicit replacement.
        if case .remote(let remote) = decision.route, case .preserve = remote.path,
           originalTarget.pathAndQuery == "*" {
            throw ExchangeRuleFailure.rejected(HTTPMutationError(code: .invalidPath, field: .path))
        }
        let target: HTTPMessageTarget
        do { target = try EffectiveRequestRoute.target(original: originalTarget, decision: decision) }
        catch let error as HTTPMutationError { throw ExchangeRuleFailure.rejected(error) }
        var preserveCredentials = false
        if case .remote(let remote) = decision.route { preserveCredentials = remote.preserveCredentials }
        let headers = EffectiveRequestRoute.sanitizedHeaders(decision.effectiveHead.headers, from: originalTarget, to: target,
                                                             preserveCredentials: preserveCredentials)
        return .network(head: .request(target, headers: headers), body: nil)
    }

    /// The request decision without its directory route: what a directory route whose file is missing
    /// continues with when its policy is `network`. The request goes on as the request point left it:
    /// every header edit still applies, a Map Remote that ran before the directory action still routes
    /// it, and the rules the directory action cut stay cut (D15).
    func networkFallback() throws -> ExchangeRuleContinuation {
        guard var decision = requestDecision else { preconditionFailure("a fallback follows the request rules") }
        decision.route = decision.carry?.remote.map(RuleRoute.remote) ?? .original
        return try continuation(for: decision)
    }

    /// The rule whose Return File (directory) action chose the route (the generated response's source,
    /// spec F10). Nil when the route is not a directory or that outcome was not recorded.
    var directoryRuleID: UUID? {
        guard let decision = requestDecision, case .localDirectory = decision.route else { return nil }
        return decision.matches.outcomes.first { outcome in
            guard outcome.code == .applied, case .returnDirectory? = action(of: outcome) else { return false }
            return true
        }?.ruleID
    }

    /// Adds `codes` (what became of the paused body) to each breakpoint action of `direction` that ran.
    func recordBodyOutcomes(_ codes: [RuleOutcomeCode], direction: HTTPMessageDirection) {
        guard let matches = direction == .request ? requestDecision?.matches : responseMatches,
              let summary = provenance.ruleMatches else { return }
        let breakpoints = matches.outcomes.filter { outcome in
            guard outcome.code == .applied, case .breakpoint(let side, _)? = action(of: outcome) else { return false }
            return side == direction
        }
        let additions = breakpoints.flatMap { breakpoint in
            codes.map { RuleOutcome(ruleID: breakpoint.ruleID, code: $0, actionIndex: breakpoint.actionIndex) }
        }
        provenance.ruleMatches = RuleMatchSummary(revision: summary.revision, ruleIDs: summary.ruleIDs, total: summary.total,
                                                  omitted: summary.omitted, outcomes: summary.outcomes + additions)
    }

    /// Replaces the provisional `applied` outcome of each body action that was collected for
    /// `direction` with what really happened to its body. Only actions the decision of that direction
    /// handed out are accepted, and each is settled once. A body that really was rewritten marks the
    /// exchange as modified by rules.
    func recordBodyRewriteOutcomes(_ outcomes: [RuleOutcome], direction: HTTPMessageDirection) {
        guard let summary = provenance.ruleMatches else { return }
        let steps = (direction == .request ? requestDecision?.bodyRewrites : responseDecision?.bodyRewrites) ?? []
        let expected = Set(steps.map { ActionKey(ruleID: $0.ruleID, actionIndex: $0.actionIndex) })
        var recorded = summary.outcomes
        for outcome in outcomes {
            let key = ActionKey(outcome)
            guard expected.contains(key), settledBodyActions.insert(key).inserted else { continue }
            if outcome.code == .applied { provenance.rulesModified = true }
            // Not found when the cap on recorded outcomes cut the action's entry.
            guard let index = recorded.firstIndex(where: { $0.code == .applied && ActionKey($0) == key }) else { continue }
            recorded[index] = outcome
        }
        provenance.ruleMatches = RuleMatchSummary(
            revision: summary.revision, ruleIDs: summary.ruleIDs, total: summary.total, omitted: summary.omitted,
            outcomes: recorded)
    }

    private static func comment(_ comment: String?, after annotations: [FlowAnnotation]) -> String? {
        annotations.reduce(comment) { comment, annotation in
            if case .comment(let action) = annotation { return action.applying(to: comment) }
            return comment
        }
    }

    /// The completion point: the annotations still pending from the earlier points plus those of the
    /// rules judged at completion, and the provenance with this point's outcomes merged in (nil when it
    /// had none). The comment those rules read is the stored one with the pending annotations applied.
    /// After a rejected request point the request-side rows read the request as it was presented.
    func completion(_ input: FlowCompletionInput) -> FlowCompletionOutput {
        var annotations = drainAnnotations()
        var entering = facts()
        if readsComment { entering.comment = Self.comment(factsSource.comment(), after: annotations) }
        let facts = entering
        let completion = CompletionFacts(
            state: input.state, durationMilliseconds: input.durationMilliseconds, responseWireBytes: input.responseWireBytes)
        let decision = timed("completion") {
            guard let request = requestDecision else {
                return RuleEvaluator.completion(
                    afterRejectedRequest: originalRequest, snapshot: snapshot, facts: facts, completion: completion,
                    hits: hits, allowance: allowance)
            }
            return RuleEvaluator.completion(
                after: request, response: responseDecision, snapshot: snapshot, facts: facts, completion: completion,
                hits: hits, allowance: allowance)
        }
        annotations += decision.annotations
        guard decision.matches.hasRecords else { return FlowCompletionOutput(annotations: annotations, provenance: nil) }
        merge(decision.matches)
        return FlowCompletionOutput(annotations: annotations, provenance: provenance)
    }

    /// Appends the response point's records to the request point's: outcomes in the order they
    /// happened, each rule listed once (where it first appeared) and counted once.
    private func record(_ response: RuleMatchSummary) {
        responseMatches = response
        merge(response)
    }

    private func merge(_ response: RuleMatchSummary) {
        guard response.hasRecords else { return }
        let request = provenance.ruleMatches
        let listed = Set(request?.ruleIDs ?? [])
        let added = response.ruleIDs.filter { !listed.contains($0) }
        provenance.ruleMatches = RuleMatchSummary(
            revision: snapshot.revision, ruleIDs: (request?.ruleIDs ?? []) + added,
            total: (request?.total ?? 0) + response.total - (response.ruleIDs.count - added.count),
            omitted: (request?.omitted ?? 0) + response.omitted,
            outcomes: (request?.outcomes ?? []) + response.outcomes)
    }

    /// The action `outcome` names: the one at its `actionIndex`, or the only action of a single-action
    /// rule. Nil for a rule-level outcome of a rule with several actions, or a rule this snapshot lacks.
    private func action(of outcome: RuleOutcome) -> ActionKind? {
        guard let rule = rulesByID[outcome.ruleID] else { return nil }
        let index = outcome.actionIndex ?? (rule.actions.count == 1 ? 0 : -1)
        return rule.actions.indices.contains(index) ? rule.actions[index].kind : nil
    }
}

/// One action of one rule as outcomes and body steps name it (`actionIndex` nil: a single-action rule).
private struct ActionKey: Hashable {
    var ruleID: UUID
    var actionIndex: Int?

    init(ruleID: UUID, actionIndex: Int?) {
        self.ruleID = ruleID
        self.actionIndex = actionIndex
    }

    init(_ outcome: RuleOutcome) {
        self.init(ruleID: outcome.ruleID, actionIndex: outcome.actionIndex)
    }
}

extension HTTPHeaders {
    init(fields: [HeaderField]) {
        self.init(fields.map { ($0.name, $0.value) })
    }

    var fields: [HeaderField] { map { HeaderField(name: $0.name, value: $0.value) } }
}
