import FlowStore
import Foundation

/// What the request point of an exchange leaves for its response point.
public struct RuleCarry: Sendable, Equatable {
    /// The request target once every request-point action ran (a Map Remote moved it). The response
    /// point's conditions read it.
    public var target: HTTPMessageTarget
    /// Rules that matched at the request point and still have response-side actions to run, in
    /// evaluation order. Their conditions are not evaluated again.
    public var pending: [PendingRule]
    /// Where a final action ran, if one did. Nothing after it runs, at this point or a later one.
    public var finalStop: FinalStop?
    /// The Map Remote route the request point composed (D16), nil when none ran. It stays when a Return
    /// File (directory) action then took the route, so a directory without the file sends the request on
    /// where the Map Remote sent it (D15).
    public var remote: MapRemoteAction?
    /// The request headers once every request-point action ran; the later points' conditions read them.
    public var requestHeaders: [HeaderField]
    /// The peeked request body once the request-point body rewrites ran on it; the later points' body
    /// rows read it.
    public var requestBody: BodyPeek

    public struct PendingRule: Sendable, Equatable {
        /// The rule's index in `RuleSnapshot.evaluationOrder`.
        public var position: Int
        public var ruleID: UUID
        /// The response-side actions still to run, by their index in the rule, in order.
        public var actionIndices: [Int]

        public init(position: Int, ruleID: UUID, actionIndices: [Int]) {
            self.position = position
            self.ruleID = ruleID
            self.actionIndices = actionIndices
        }
    }

    public struct FinalStop: Sendable, Equatable {
        /// The rule's index in `RuleSnapshot.evaluationOrder`.
        public var position: Int
        /// The final action's index in the rule.
        public var actionIndex: Int

        public init(position: Int, actionIndex: Int) {
            self.position = position
            self.actionIndex = actionIndex
        }
    }

    public init(
        target: HTTPMessageTarget, pending: [PendingRule] = [], finalStop: FinalStop? = nil,
        remote: MapRemoteAction? = nil, requestHeaders: [HeaderField] = [], requestBody: BodyPeek = .notCollected
    ) {
        self.target = target
        self.pending = pending
        self.finalStop = finalStop
        self.remote = remote
        self.requestHeaders = requestHeaders
        self.requestBody = requestBody
    }
}

/// Pure, deterministic rule evaluation.
///
/// Rules run in `RuleSnapshot.evaluationOrder` on a current message, so each rule's conditions
/// read the exchange as the higher-priority rules left it: after a Map Remote, a lower rule that names
/// the old host no longer matches, and a second Map Remote continues from the first one's target; after
/// a status rewrite, a lower status range reads the new status. Header edits are checked against the
/// headers as they arrived and pile up on the current ones. A final action (Return File, or one the
/// user made final) ends the exchange's evaluation: the rest of its rule and every lower-priority rule
/// stay silent, at this point and the later ones. A rule's conditions are evaluated once; its own
/// actions never make it evaluate again.
public enum RuleEvaluator {
    /// The request point. A rule judged at the response (it has a response condition) waits for the
    /// response point and leaves no trace here. Every other rule is judged here: it runs its
    /// request-side actions here and leaves its response-side ones in `carry`, whose outcomes are
    /// recorded where they run. `hits` counts every rule whose conditions matched and applies its
    /// occurrence range; without a counter the occurrence range is ignored. `facts` is what is known
    /// about the exchange as the point is entered; `allowance` is the exchange's regular-expression time,
    /// shared with its later points.
    public static func request(
        _ original: HTTPMessageHead, snapshot: RuleSnapshot, hits: RuleHitCounter? = nil,
        facts: ExchangeFacts = ExchangeFacts(), allowance: RegexAllowance = RegexAllowance(),
        limits: RulesLimits = RulesLimits(), cache: PatternCache = .shared, requestBody: BodyPeek = .notCollected,
        offline: Bool = false
    ) throws -> RequestRuleDecision {
        guard case .request(let originalTarget, let originalHeaders) = original else {
            throw HTTPMutationError(code: .messageKindMismatch, field: .message)
        }
        let upgrade = HTTPMutationValidator.isUpgradeCandidate(originalHeaders)
        let rules = snapshot.evaluationOrder
        var run = PointRun(
            direction: .request, originalHeaders: originalHeaders, upgrade: upgrade, lastPosition: rules.count - 1,
            facts: facts)
        run.peek = requestBody
        run.offline = offline
        let context = EditContext(allowance: allowance, cache: cache, limits: limits)
        run.context = context
        var target = originalTarget
        var route = RuleRoute.original
        var remoteRoute: MapRemoteAction?
        var pending: [RuleCarry.PendingRule] = []

        do {
            for (position, rule) in rules.enumerated() {
                guard run.finalStop == nil else { break }
                guard !rule.isConnectOnlyRule, rule.conditions.judgmentPoint < .response,
                    run.matched(rule, allowance: allowance, cache: cache, limits: limits, input: { run in
                        ConditionInput(
                            target: target, requestHeaders: run.headers, facts: run.currentFacts,
                            requestBody: run.peek)
                    }),
                    Self.occurs(rule, hits: hits, position: position, log: &run.log)
                else { continue }
                let waiting = try run.perform(rule, at: position, indices: Array(rule.actions.indices)) { kind, _ in
                    switch kind {
                    case .returnFile(let file):
                        if upgrade { return .unsupportedUpgradeAction }
                        route = .local(file)
                    case .returnDirectory(let directory, let prefix):
                        if upgrade { return .unsupportedUpgradeAction }
                        route = .localDirectory(
                            DirectoryRoute(
                                action: directory, subpath: Self.subpath(target.pathAndQuery, prefix: prefix),
                                method: target.method))
                    case .mapRemote(let remote):
                        if upgrade { return .unsupportedUpgradeAction }
                        // Only a final action takes the route local and nothing runs after it, so
                        // the route is still `.original` or `.remote(remoteRoute)` here.
                        let composed = remoteRoute.map { $0.followed(by: remote) } ?? remote
                        remoteRoute = composed
                        route = .remote(composed)
                        target = remote.target(applyingTo: target)
                    case .editHeaders, .breakpoint, .rewriteBody, .rewriteStatus, .mark, .comment, .hide:
                        return nil  // Unreachable: shared, response-side, or an annotation.
                    case .modifyURL, .modifyQuery:
                        if upgrade { return .unsupportedUpgradeAction }
                        // Executed as a Map Remote of the edited target (D3): same route, same carry.
                        switch try Self.editedTarget(kind, from: target, context) {
                        case .failed(let code): return code
                        case .unchanged: break
                        case .moved(let remote):
                            let composed = remoteRoute.map { $0.followed(by: remote) } ?? remote
                            remoteRoute = composed
                            route = .remote(composed)
                            target = remote.target(applyingTo: target)
                        }
                    case .returnHandwritten(let handwritten):
                        if upgrade { return .unsupportedUpgradeAction }
                        route = .generated(try Self.generated(handwritten, limits: limits))
                    case .returnPreset(let preset):
                        if upgrade { return .unsupportedUpgradeAction }
                        route = .generated(try Self.generated(preset))
                    case .closeConnection(let mode):
                        route = .close(mode, ruleID: rule.id)
                    case .editCookies, .delay, .returnConnectTunnel, .noDecrypt, .magicString:
                        return nil  // Unreachable: cookies and delays run in `perform`; P0 alone runs the rest.
                    }
                    return .applied
                }
                if !waiting.isEmpty {
                    pending.append(RuleCarry.PendingRule(position: position, ruleID: rule.id, actionIndices: waiting))
                }
            }
            var localRoute = false
            switch route {
            // Nothing goes upstream, so no request body is rewritten on its way there.
            case .local, .localDirectory, .generated, .close: localRoute = true
            case .original, .remote: break
            }
            let bodyRewrites = try run.settle(response: nil, localRoute: localRoute, limits: limits)
            return RequestRuleDecision(
                effectiveHead: .request(originalTarget, headers: run.headers), route: route,
                breakpoint: run.breakpoint, matches: run.summary(revision: snapshot.revision),
                bodyRewrites: bodyRewrites, rulesModified: run.modified,
                carry: RuleCarry(
                    target: target, pending: pending, finalStop: run.finalStop, remote: remoteRoute,
                    requestHeaders: run.headers,
                    requestBody: run.settledPeek(limits: limits, cache: cache)),
                annotations: run.annotations, delayMilliseconds: run.delayMilliseconds)
        } catch let mutation as HTTPMutationError {
            throw run.failure(mutation, revision: snapshot.revision)
        }
    }

    /// The response point of the exchange whose request point decided `request` (same snapshot). The
    /// rules read the request as the request point left it (`carry.target`) and the status as the
    /// rules above them left it. A rule judged at the request point runs only the response-side
    /// actions it left pending, without evaluating its conditions again; a rule judged at the response
    /// is evaluated here (hits, occurrence range and pattern problems as at the request point) and runs
    /// all its actions. Nothing at or below the request point's final action runs, except the stopped
    /// rule's own response-side actions that came before its final one.
    ///
    /// `requestWasUpgradeCandidate` keeps an exchange that asked to switch protocols out of
    /// breakpoints and status rewrites even when the origin answers with a plain failure.
    /// `isLocalResponse` marks a response the proxy produced itself (Return File); only status
    /// rewrites that opted in touch its status.
    ///
    /// `request` must come from `request(_:snapshot:...)` on this same snapshot. Anything else (no
    /// carry, another revision, or pending work naming a rule or action this snapshot does not have
    /// there) is a programming error: debug builds stop at an assertion; release builds run no rule
    /// and return the response untouched, with no records and no hits counted.
    public static func response(
        _ original: HTTPMessageHead, after request: RequestRuleDecision, snapshot: RuleSnapshot,
        requestWasUpgradeCandidate: Bool = false, isLocalResponse: Bool = false, hits: RuleHitCounter? = nil,
        facts: ExchangeFacts = ExchangeFacts(), allowance: RegexAllowance = RegexAllowance(),
        limits: RulesLimits = RulesLimits(), cache: PatternCache = .shared, responseBody: BodyPeek = .notCollected,
        offline: Bool = false
    ) throws -> ResponseRuleDecision {
        try response(
            original, after: request, snapshot: snapshot, requestWasUpgradeCandidate: requestWasUpgradeCandidate,
            isLocalResponse: isLocalResponse, hits: hits, facts: facts, allowance: allowance, limits: limits,
            cache: cache, responseBody: responseBody, offline: offline
        ) { assertionFailure($0) }
    }

    /// `response(_:after:...)` with the reaction to a request decision of another snapshot passed in,
    /// so tests reach the release-build fallback without tripping the assertion.
    static func response(
        _ original: HTTPMessageHead, after request: RequestRuleDecision, snapshot: RuleSnapshot,
        requestWasUpgradeCandidate: Bool = false, isLocalResponse: Bool = false, hits: RuleHitCounter? = nil,
        facts: ExchangeFacts = ExchangeFacts(), allowance: RegexAllowance = RegexAllowance(),
        limits: RulesLimits = RulesLimits(), cache: PatternCache = .shared, responseBody: BodyPeek = .notCollected,
        offline: Bool = false, onMismatch: (String) -> Void
    ) throws -> ResponseRuleDecision {
        guard case .response(let originalStatus, let reason, let originalHeaders) = original else {
            throw HTTPMutationError(code: .messageKindMismatch, field: .message)
        }
        let rules = snapshot.evaluationOrder
        guard let carry = Self.carry(of: request, revision: snapshot.revision, rules: rules) else {
            onMismatch("the response point needs the request decision RuleEvaluator.request made on this snapshot")
            return ResponseRuleDecision(
                effectiveHead: original, breakpoint: nil,
                matches: RuleMatchSummary(revision: snapshot.revision, ruleIDs: [], total: 0))
        }
        let upgrade =
            requestWasUpgradeCandidate || originalStatus == 101
            || HTTPMutationValidator.isUpgradeCandidate(originalHeaders)
        // The request point's final action already cut every rule below its own.
        let stop = carry.finalStop
        let reachable = min(stop?.position ?? rules.count - 1, rules.count - 1)
        // What the request point changed was changed before this point.
        var entering = facts
        entering.rulesModified = facts.rulesModified || request.rulesModified
        var run = PointRun(
            direction: .response, originalHeaders: originalHeaders, upgrade: upgrade, lastPosition: reachable,
            facts: entering)
        run.peek = responseBody
        run.offline = offline
        run.recordsRequestActions = true
        run.context = EditContext(allowance: allowance, cache: cache, limits: limits)
        var pending: [Int: RuleCarry.PendingRule] = [:]
        for entry in carry.pending where pending[entry.position] == nil { pending[entry.position] = entry }
        var status = originalStatus
        var statusRewrite: Int?
        var statusReason: String?
        var replacement: ResponseReplacement?

        do {
            for (position, rule) in rules.enumerated() {
                guard run.finalStop == nil, position <= reachable else { break }
                let indices: [Int]
                if let entry = pending[position] {
                    indices = entry.actionIndices.filter { index in
                        stop.map { $0.position != position || index < $0.actionIndex } ?? true
                    }
                } else if !rule.isConnectOnlyRule, rule.conditions.judgmentPoint == .response,
                    position != stop?.position,
                    run.matched(rule, allowance: allowance, cache: cache, limits: limits, input: { run in
                        ConditionInput(
                            target: carry.target, requestHeaders: carry.requestHeaders,
                            response: (status, run.headers), facts: run.currentFacts,
                            requestBody: carry.requestBody, responseBody: run.peek)
                    }),
                    Self.occurs(rule, hits: hits, position: position, log: &run.log)
                {
                    // Request-side actions of a rule judged here cannot reach the origin: `perform` records
                    // them on the request's record or skips them (spec R8F2-6).
                    indices = Array(rule.actions.indices)
                } else {
                    continue
                }
                _ = try run.perform(rule, at: position, indices: indices) { kind, label in
                    let replaced: ResponseReplacement.Kind
                    switch kind {
                    case .rewriteStatus(let rewrite):
                        if upgrade { return .unsupportedUpgradeAction }
                        if isLocalResponse && !rewrite.includeLocalResponses { return .statusSkippedLocal }
                        status = rewrite.status
                        statusRewrite = rewrite.status
                        statusReason = rewrite.reason
                        return .applied
                    // A rule judged here answers (or closes) in place of the origin's response (spec 12.7). The
                    // proxy's own response (a Return File of the request point) cannot be replaced again.
                    case .returnFile(let file):
                        if upgrade { return .unsupportedUpgradeAction }
                        if isLocalResponse { return .responseAlreadyLocal }
                        replaced = .file(file)
                    case .returnHandwritten(let handwritten):
                        if upgrade { return .unsupportedUpgradeAction }
                        if isLocalResponse { return .responseAlreadyLocal }
                        replaced = .generated(try Self.generated(handwritten, limits: limits))
                    case .returnPreset(let preset):
                        if upgrade { return .unsupportedUpgradeAction }
                        if isLocalResponse { return .responseAlreadyLocal }
                        replaced = .generated(try Self.generated(preset))
                    case .closeConnection(let mode):
                        replaced = .close(mode)
                    default:
                        return nil  // Unreachable: shared, or a request-side action `perform` records.
                    }
                    replacement = ResponseReplacement(replaced, ruleID: rule.id, actionIndex: label)
                    return .applied
                }
            }
            // Nothing of the origin's response is left to pause on or to rewrite.
            if replacement != nil { run.breakpoint = nil }
            let bodyRewrites = try run.settle(
                response: ResponseFacts(status: status, requestMethod: carry.target.method),
                localRoute: replacement != nil, limits: limits)
            return ResponseRuleDecision(
                effectiveHead: .response(
                    status: status, reason: statusRewrite == nil ? reason : statusReason, headers: run.headers),
                breakpoint: run.breakpoint, matches: run.summary(revision: snapshot.revision),
                bodyRewrites: bodyRewrites, statusRewrite: statusRewrite, statusReason: statusReason,
                rulesModified: run.modified,
                annotations: run.annotations, recordedRequestActions: run.recordedRequestActions,
                replacement: replacement, delayMilliseconds: run.delayMilliseconds,
                carry: Self.responseCarry(
                    finalStop: run.finalStop ?? stop, status: status, headers: run.headers,
                    body: run.settledPeek(limits: limits, cache: cache), replacement: replacement, limits: limits))
        } catch let mutation as HTTPMutationError {
            throw run.failure(mutation, revision: snapshot.revision)
        }
    }

    /// What the completion point reads of the response. After a replacement it is what the client got, not the origin's
    /// answer: a Return's status, headers and body (a file's body is not read: unknown). A close leaves the origin's
    /// facts, nothing reached the client either way.
    static func responseCarry(
        finalStop: RuleCarry.FinalStop?, status: Int, headers: [HeaderField], body: BodyPeek,
        replacement: ResponseReplacement?, limits: RulesLimits
    ) -> ResponseCarry {
        switch replacement?.kind {
        case .generated(let generated):
            return ResponseCarry(
                finalStop: finalStop, status: generated.status, headers: generated.clientHeaders,
                body: BodyPeek.decode(generated.body, headers: generated.headers, limits: limits))
        case .file(let file):
            return ResponseCarry(finalStop: finalStop, status: file.status, headers: file.headers, body: .notCollected)
        case .close, nil:
            return ResponseCarry(finalStop: finalStop, status: status, headers: headers, body: body)
        }
    }

    /// The completion point: only the rules judged at completion (a row reads the duration, the
    /// response size or the session state) are evaluated, in priority order, above the first final
    /// action of the request or response point; they only mark, comment and hide (validation keeps every
    /// other action out; a snapshot that skipped it runs only those here). Their conditions read the
    /// request as the request point left it, the response as the response point left it (`response` is
    /// nil when there was none: failed, cancelled or closed, so its rows are unknown), `facts` and
    /// `completion`. A hide is final and cuts the completion rules below it. `matches` holds this point's
    /// outcomes only. `request` and `response` must come from this same snapshot; otherwise debug builds
    /// stop at an assertion and release builds run nothing.
    public static func completion(
        after request: RequestRuleDecision, response: ResponseRuleDecision?, snapshot: RuleSnapshot,
        facts: ExchangeFacts, completion: CompletionFacts, hits: RuleHitCounter? = nil,
        allowance: RegexAllowance = RegexAllowance(), cache: PatternCache = .shared
    ) -> CompletionRuleDecision {
        Self.completion(
            after: request, response: response, snapshot: snapshot, facts: facts, completion: completion, hits: hits,
            allowance: allowance, cache: cache
        ) { assertionFailure($0) }
    }

    /// The completion point of an exchange whose request point was rejected (no decision exists): its
    /// request-side rows read `original` as it was presented, nothing is pending and no final action
    /// cut anything, and there is no response (its rows are unknown).
    public static func completion(
        afterRejectedRequest original: HTTPMessageHead, snapshot: RuleSnapshot,
        facts: ExchangeFacts, completion: CompletionFacts, hits: RuleHitCounter? = nil,
        allowance: RegexAllowance = RegexAllowance(), cache: PatternCache = .shared
    ) -> CompletionRuleDecision {
        guard case .request(let target, let headers) = original else {
            assertionFailure("a request head")
            return CompletionRuleDecision(matches: RuleMatchSummary(revision: snapshot.revision, ruleIDs: [], total: 0))
        }
        let request = RequestRuleDecision(
            effectiveHead: original, route: .original, breakpoint: nil,
            matches: RuleMatchSummary(revision: snapshot.revision, ruleIDs: [], total: 0),
            carry: RuleCarry(target: target, requestHeaders: headers))
        return Self.completion(
            after: request, response: nil, snapshot: snapshot, facts: facts, completion: completion, hits: hits,
            allowance: allowance, cache: cache)
    }

    /// `completion(after:...)` with the reaction to decisions of another snapshot passed in, for tests.
    static func completion(
        after request: RequestRuleDecision, response: ResponseRuleDecision?, snapshot: RuleSnapshot,
        facts: ExchangeFacts, completion: CompletionFacts, hits: RuleHitCounter? = nil,
        allowance: RegexAllowance = RegexAllowance(), cache: PatternCache = .shared, onMismatch: (String) -> Void
    ) -> CompletionRuleDecision {
        let rules = snapshot.evaluationOrder
        guard let carry = Self.carry(of: request, revision: snapshot.revision, rules: rules),
            response.map({ $0.matches.revision == snapshot.revision }) ?? true
        else {
            onMismatch("the completion point needs the decisions RuleEvaluator made on this snapshot")
            return CompletionRuleDecision(matches: RuleMatchSummary(revision: snapshot.revision, ruleIDs: [], total: 0))
        }
        // The rule of a final action was judged at an earlier point; everything below it is cut.
        let stops = [carry.finalStop?.position, response?.carry.finalStop?.position].compactMap { $0 }
        let end = min(stops.min() ?? rules.count, rules.count)
        var entering = facts
        entering.rulesModified = facts.rulesModified || request.rulesModified || (response?.rulesModified ?? false)
        var run = PointRun(
            direction: .response, originalHeaders: [], upgrade: false, lastPosition: end - 1, facts: entering)
        let responseHead = response.map { (status: $0.carry.status, headers: $0.carry.headers) }
        for (position, rule) in rules.enumerated() {
            guard run.finalStop == nil, position < end else { break }
            guard !rule.isConnectOnlyRule, rule.conditions.judgmentPoint == .completion,
                run.matched(rule, allowance: allowance, cache: cache, limits: RulesLimits(), input: { run in
                    ConditionInput(
                        target: carry.target, requestHeaders: carry.requestHeaders, response: responseHead,
                        facts: run.currentFacts, completion: completion, requestBody: carry.requestBody,
                        responseBody: response?.carry.body ?? .notCollected, bodyRegexLimit: completionBodyRegexLimit)
                }),
                Self.occurs(rule, hits: hits, position: position, log: &run.log)
            else { continue }
            let indices = rule.actions.indices.filter { rule.actions[$0].kind.isAnnotation }
            do {
                _ = try run.perform(rule, at: position, indices: indices) { _, _ in nil }
            } catch {
                assertionFailure("annotations never fail: \(error)")
            }
        }
        return CompletionRuleDecision(matches: run.summary(revision: snapshot.revision), annotations: run.annotations)
    }

    /// Ruling (R3 T11 review, M2): the completion point runs synchronously on the event loop (D15), so
    /// a body regular expression there gets at most this much per match, not the 5 s body budget; a
    /// timeout is the usual `patternTimedOut` problem and not a strike against the pattern.
    static let completionBodyRegexLimit = Duration.milliseconds(2)

    /// The carry of a request decision made on this snapshot: same revision, and every pending entry
    /// names the rule at its position and actions that rule has. Nil for anything else.
    static func carry(of request: RequestRuleDecision, revision: UInt64, rules: [Rule]) -> RuleCarry? {
        guard let carry = request.carry, request.matches.revision == revision else { return nil }
        let consistent = carry.pending.allSatisfy { entry in
            rules.indices.contains(entry.position) && rules[entry.position].id == entry.ruleID
                && entry.actionIndices.allSatisfy(rules[entry.position].actions.indices.contains)
        }
        return consistent ? carry : nil
    }

    // MARK: helpers shared by the evaluation points

    /// One evaluation point at work: the current headers, breakpoint and body candidates the rules so
    /// far left, the outcomes, and where a final action stopped it. The point keeps the rest of its
    /// current message (the request target and route, or the status) itself.
    struct PointRun {
        /// The message this point runs actions on.
        let direction: HTTPMessageDirection
        /// The headers as they arrived; every header edit is validated against them (D17).
        let originalHeaders: [HeaderField]
        let upgrade: Bool
        /// The last evaluation-order position this point can reach; a final action above it cuts the
        /// rules in between.
        let lastPosition: Int
        var headers: [HeaderField]
        var breakpoint: BreakpointPauseMode?
        /// Execute runs without a connection to pause (D3): a breakpoint then sets nothing.
        var offline = false
        var log = OutcomeLog()
        var patternProblems: [RuleOutcome] = []
        var bodyCandidates: [BodyCandidate] = []
        /// The peeked body of this point's direction as the candidates so far leave it (D12); the other
        /// direction's body is the carry's.
        var peek: BodyPeek = .notCollected
        private var peekRewrites = 0
        /// The applied outcome of every header edit, for `rejected`.
        var edits: Set<RuleOutcome> = []
        /// The rejected outcome of the header edit being validated, while it is.
        var failingEdit: (outcome: RuleOutcome, position: Int)?
        var finalStop: RuleCarry.FinalStop?
        /// A header edit or a route / status action was applied (spec 5.7); breakpoints and annotations
        /// never count and body rewrites are settled once the body is seen.
        var modified = false
        /// What the rules run here did to the flow's record, in the order they ran.
        var annotations: [FlowAnnotation] = []
        /// What was known as the point was entered (D17).
        let enteringFacts: ExchangeFacts
        /// The flow's comment with the comment actions run here so far applied.
        var currentComment: String?
        /// What the URL, query and cookie edits need to run (regular-expression time, caps).
        var context = EditContext()
        /// Milliseconds of the delay actions run here, capped at `limits.delayMillisecondsMax` (D16).
        var delayMilliseconds = 0
        var delayWasCapped = false
        /// The response point only: a request-side action of a rule judged here is recorded, not run.
        var recordsRequestActions = false
        /// The request-side actions that can change the recorded request, in the order they ran.
        var recordedRequestActions: [RecordedRequestAction] = []

        init(
            direction: HTTPMessageDirection, originalHeaders: [HeaderField], upgrade: Bool, lastPosition: Int,
            facts: ExchangeFacts
        ) {
            self.direction = direction
            self.originalHeaders = originalHeaders
            self.upgrade = upgrade
            self.lastPosition = lastPosition
            self.headers = originalHeaders
            self.enteringFacts = facts
            self.currentComment = facts.comment
        }

        /// Whether the rule matched, with what it could not answer recorded in `patternProblems`. `input`
        /// builds the current message from this run, only when the rule has rows to read it.
        /// The peek with every body candidate so far applied. The candidates are provisional: `settle` may
        /// later drop them (a breakpoint, a local route), in which case the executor leaves the body as it
        /// was, but rules in this run already read it rewritten (spec 5.5.5).
        mutating func settledPeek(limits: RulesLimits, cache: PatternCache) -> BodyPeek {
            if peekRewrites < bodyCandidates.count {
                peek = peek.applying(bodyCandidates[peekRewrites...].map(\.step), limits: limits, cache: cache)
                peekRewrites = bodyCandidates.count
            }
            return peek
        }

        mutating func matched(
            _ rule: Rule, allowance: RegexAllowance, cache: PatternCache, limits: RulesLimits,
            input: (PointRun) -> ConditionInput
        ) -> Bool {
            // The body rewrites of the rules above, in order, before this rule reads the body (spec 5.5.5).
            _ = settledPeek(limits: limits, cache: cache)
            let verdict = RuleEvaluator.judge(rule, allowance: allowance, cache: cache, limits: limits) { input(self) }
            patternProblems += verdict.problems
            return verdict.matched
        }

        /// The facts the next rule's conditions read: "modified" and the comment as the rules above left them.
        var currentFacts: ExchangeFacts {
            var facts = enteringFacts
            facts.rulesModified = facts.rulesModified || modified
            facts.comment = currentComment
            return facts
        }

        /// Runs the actions of a matched rule at `indices`, in order, and records an outcome for each.
        /// Header edits, breakpoints and body rewrites run here; the point's own kinds (routes at the
        /// request, status rewrites at the response) run in `pointAction`, which returns the outcome
        /// code, or nil for a kind this point never runs. An action for the other message waits for
        /// the response point (returned) or, at the response point, never runs. An annotation runs at
        /// whichever point `indices` hands it to: the rule's judgment point (D4). It never counts as a
        /// modification; a mark whose colour is not valid (only a snapshot that skipped validation has
        /// one) does nothing and records nothing.
        ///
        /// An applied action that is final stops the run: the rest of `indices` is
        /// `skippedAfterFinal`, and `finalStop` is recorded when that cut something (a later action
        /// of the rule, or a rule below it this point can still reach; D8).
        mutating func perform(
            _ rule: Rule, at position: Int, indices: [Int],
            pointAction: (ActionKind, _ label: Int?) throws -> RuleOutcomeCode?
        ) throws -> [Int] {
            let labelled = rule.actions.count > 1
            var waiting: [Int] = []
            for (offset, index) in indices.enumerated() {
                let action = rule.actions[index]
                let label = labelled ? index : nil
                // Only the CONNECT point runs these: elsewhere no outcome, no stop (D10).
                if action.kind.isConnectOnly { continue }
                if finalStop != nil {
                    log.record(RuleOutcome(ruleID: rule.id, code: .skippedAfterFinal, actionIndex: index), at: position)
                    continue
                }
                guard action.kind.direction == direction || action.kind.direction == nil else {
                    if direction == .request { waiting.append(index) }
                    if recordsRequestActions, action.kind.direction == .request {
                        // The request has been sent: the action edits its record or is skipped, and never
                        // ends the evaluation (a skipped final action cuts nothing).
                        let applies = RecordedRequestEditing.appliesToRecord(action.kind)
                        if applies {
                            recordedRequestActions.append(
                                RecordedRequestAction(ruleID: rule.id, actionIndex: index, kind: action.kind))
                        }
                        log.record(
                            RuleOutcome(
                                ruleID: rule.id, code: applies ? .requestActionVisibleOnly : .requestActionSkippedAtResponse,
                                actionIndex: label),
                            at: position)
                    }
                    continue
                }
                var code = RuleOutcomeCode.applied
                var canEnd = true
                switch action.kind {
                case .editHeaders(_, let operations):
                    failingEdit = (RuleOutcome(ruleID: rule.id, code: .rejected, actionIndex: label), position)
                    try HTTPMutationValidator.validateEdits(
                        operations, originalHeaders: originalHeaders, upgradeCandidate: upgrade)
                    failingEdit = nil
                    code = editHeaders(operations, ruleID: rule.id, label: label)
                    edits.insert(RuleOutcome(ruleID: rule.id, code: code, actionIndex: label))
                case .breakpoint(_, let mode):
                    if upgrade { code = .unsupportedUpgradeAction } else if !offline { breakpoint = merged(breakpoint, mode) }
                case .rewriteBody(_, let body):
                    // Provisional: the message-level checks in `settle` need the final message. An
                    // upgrade always skips it there, so then it cannot end the evaluation.
                    bodyCandidates.append(
                        BodyCandidate(
                            step: BodyRewriteStep(ruleID: rule.id, actionIndex: label, action: body),
                            outcomeIndex: log.outcomes.count))
                    canEnd = !upgrade
                case .mark(let mark):
                    // "Unchanged" carries no colour and "default" clears one (above): the action still counts (its outcome
                    // and its stop tick). A colour that is not valid (only a snapshot that skipped validation has one)
                    // is skipped as a whole.
                    if let flowMark = mark.flowMark(ruleID: rule.id, ruleName: rule.name) {
                        annotations.append(.mark(flowMark))
                    } else if let reset = mark.colorReset {
                        // "Default" is the one colour that does something without being a colour: it clears.
                        annotations.append(.resetMark(background: reset.background, foreground: reset.foreground))
                    } else if !MarkAction.isNoColorChoice(mark.background) {
                        continue
                    }
                case .comment(let comment):
                    if MagicStringAction.isInert(comment) { break }
                    annotations.append(.comment(comment))
                    currentComment = comment.applying(to: currentComment)
                case .hide:
                    annotations.append(.hide)
                case .editCookies(_, let operations):
                    code = editCookies(operations, ruleID: rule.id, label: label)
                case .delay(let milliseconds):
                    code = addDelay(milliseconds, ruleID: rule.id, label: label)
                case .returnFile, .returnDirectory, .mapRemote, .rewriteStatus, .modifyURL, .modifyQuery,
                    .returnHandwritten, .returnPreset, .closeConnection, .returnConnectTunnel, .noDecrypt, .magicString:
                    if action.kind.canBeRejected {
                        failingEdit = (RuleOutcome(ruleID: rule.id, code: .rejected, actionIndex: label), position)
                    }
                    let pointResult = try pointAction(action.kind, label)
                    failingEdit = nil
                    guard let pointCode = pointResult else { continue }
                    code = pointCode
                    if code == .applied, action.kind.countsAsModification { modified = true }
                }
                log.record(RuleOutcome(ruleID: rule.id, code: code, actionIndex: label), at: position)
                if action.isFinalEffective, code == .applied, canEnd {
                    finalStop = RuleCarry.FinalStop(position: position, actionIndex: index)
                    // Recorded only when the stop cut something off (D8).
                    if offset < indices.count - 1 || position < lastPosition {
                        log.record(RuleOutcome(ruleID: rule.id, code: .finalStop, actionIndex: index), at: position)
                    }
                }
            }
            return waiting
        }

        /// Settles the body candidates against the final message (`response` nil at the request) and
        /// checks the combined header block. Returns the body steps to run.
        mutating func settle(response: ResponseFacts?, localRoute: Bool, limits: RulesLimits) throws
            -> [BodyRewriteStep]
        {
            let skip =
                bodyCandidates.isEmpty
                ? nil
                : bodySkip(
                    headers: headers, response: response, upgrade: upgrade, breakpoint: breakpoint != nil,
                    localRoute: localRoute, limits: limits)
            let steps = resolve(bodyCandidates, skip: skip, outcomes: &log.outcomes)
            if headers != originalHeaders {
                try HTTPMutationValidator.validateBlock(headers, trailers: false, limits: limits)
            }
            return steps
        }

        func summary(revision: UInt64) -> RuleMatchSummary {
            log.summary(revision: revision, problems: patternProblems)
        }

        func failure(_ mutation: HTTPMutationError, revision: UInt64) -> RuleEvaluationError {
            RuleEvaluationError(
                mutation: mutation,
                matches: rejected(log, failing: failingEdit, edits: edits).summary(
                    revision: revision, problems: patternProblems),
                annotations: annotations)
        }
    }

    /// Outcomes in the order they happened, and the rules they name in the order each first appeared.
    struct OutcomeLog {
        var outcomes: [RuleOutcome] = []
        private(set) var ruleIDs: [UUID] = []
        /// The evaluation-order position of the rule listed last.
        private var listed: Int?

        /// A rule enters `ruleIDs` with its first outcome.
        mutating func record(_ outcome: RuleOutcome, at position: Int) {
            if listed != position {
                ruleIDs.append(outcome.ruleID)
                listed = position
            }
            outcomes.append(outcome)
        }

        /// Pattern problems go last, as they always did.
        func summary(revision: UInt64, problems: [RuleOutcome]) -> RuleMatchSummary {
            RuleMatchSummary(revision: revision, ruleIDs: ruleIDs, total: ruleIDs.count, outcomes: outcomes + problems)
        }
    }

    struct BodyCandidate {
        var step: BodyRewriteStep
        /// Position of the action's provisional outcome in `outcomes`.
        var outcomeIndex: Int
    }

    struct ResponseFacts {
        var status: Int
        var requestMethod: String
    }

    /// Whether the rule matched the current message. A rule whose regular expression timed out or is
    /// disabled, or that has a row it could not answer (`unknownSize`, `appUnknown`, …), did not match,
    /// but its `problems` say why it stayed silent. A rule without rows matches every exchange, so the
    /// current message (`input`) is built only for a rule that has rows.
    static func judge(
        _ rule: Rule, allowance: RegexAllowance, cache: PatternCache, limits: RulesLimits = RulesLimits(),
        input: () -> ConditionInput
    ) -> (matched: Bool, problems: [RuleOutcome]) {
        guard !rule.conditions.rows.isEmpty else { return (true, []) }
        let verdict = rule.conditions.evaluate(input(), allowance: allowance, cache: cache, limits: limits)
        var problems: [RuleOutcome] = []
        switch verdict.result {
        case .matched: return (true, [])
        case .noMatch: break
        case .patternTimedOut: problems.append(RuleOutcome(ruleID: rule.id, code: .patternTimedOut))
        case .patternDisabled: problems.append(RuleOutcome(ruleID: rule.id, code: .patternDisabled))
        }
        problems += verdict.notes.map { RuleOutcome(ruleID: rule.id, code: $0) }
        return (false, problems)
    }

    /// Counts the hit of a matched rule and applies its occurrence range: outside the range nothing
    /// of the rule runs, and the rule says so once (`occurrenceSkipped`). Without a counter every hit
    /// counts as in range.
    private static func occurs(
        _ rule: Rule, hits: RuleHitCounter?, position: Int, log: inout OutcomeLog
    ) -> Bool {
        guard let hits else { return true }
        let count = hits.recordHit(rule.id)
        guard case .times(let range) = rule.conditions.occurrence, !range.contains(count) else { return true }
        log.record(RuleOutcome(ruleID: rule.id, code: .occurrenceSkipped), at: position)
        return false
    }

    /// The directory subpath under `prefix`. Validation requires a `/…/` prefix; any other one (a
    /// stale or hand-edited snapshot) has no directory to resolve against, so it fails closed.
    private static func subpath(_ pathAndQuery: String, prefix: String) -> DirectorySubpath {
        guard prefix.hasPrefix("/"), prefix.hasSuffix("/") else { return .unsafe }
        return DirectorySubpath.resolve(pathAndQuery: pathAndQuery, prefix: prefix)
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
                || lengths.first.flatMap({ Int($0) }) == 0
            {
                return .bodySkippedNoBody
            }
        }
        guard BodyTextCodec.isTextLike(contentType: headers.values(for: "content-type").first) else {
            return .bodySkippedNotText
        }
        // Digits that do not fit an Int are larger than any cap.
        if lengths.contains(where: { Int($0).map { $0 > limits.rewriteBodyBytes } ?? true }) {
            return .bodySkippedTooLarge
        }
        return nil
    }

    /// Applies the message-level verdict to every body candidate: the steps to run, or each action's
    /// provisional outcome replaced by the skip code.
    private static func resolve(
        _ candidates: [BodyCandidate], skip: RuleOutcomeCode?, outcomes: inout [RuleOutcome]
    ) -> [BodyRewriteStep] {
        guard let skip else { return candidates.map(\.step) }
        for candidate in candidates {
            outcomes[candidate.outcomeIndex] = RuleOutcome(
                ruleID: candidate.step.ruleID, code: skip, actionIndex: candidate.step.actionIndex)
        }
        return []
    }

    /// A failed evaluation never reports an edit as applied: the action whose own edit failed is
    /// `.rejected` (earlier outcomes stay); when the combined block failed after every edit validated
    /// on its own, every header edit that built it is `.rejected`. `edits` holds the applied outcome
    /// of each header edit.
    private static func rejected(
        _ log: OutcomeLog, failing: (outcome: RuleOutcome, position: Int)?, edits: Set<RuleOutcome>
    ) -> OutcomeLog {
        var log = log
        if let failing {
            log.record(failing.outcome, at: failing.position)
        } else {
            log.outcomes = log.outcomes.map { outcome in
                edits.contains(outcome)
                    ? RuleOutcome(ruleID: outcome.ruleID, code: .rejected, actionIndex: outcome.actionIndex) : outcome
            }
        }
        return log
    }

    private static func merged(_ current: BreakpointPauseMode?, _ mode: BreakpointPauseMode) -> BreakpointPauseMode {
        current == .fullBody || mode == .fullBody ? .fullBody : .headers
    }
}

extension MapRemoteAction {
    /// Two Map Remote actions that ran one after the other, as the one route the executor takes (D16):
    /// the later target; the later path if it replaces one, this one's otherwise; credentials kept only
    /// if this hop kept them and the later one keeps them too or stays on this one's origin.
    fileprivate func followed(by later: MapRemoteAction) -> MapRemoteAction {
        let combinedPath: RemotePathPolicy
        switch later.path {
        case .replace: combinedPath = later.path
        case .preserve: combinedPath = path
        }
        return MapRemoteAction(
            targetScheme: later.targetScheme, targetHost: later.targetHost, targetPort: later.targetPort,
            path: combinedPath,
            preserveCredentials: preserveCredentials && (later.preserveCredentials || hasSameOrigin(as: later)))
    }
}
