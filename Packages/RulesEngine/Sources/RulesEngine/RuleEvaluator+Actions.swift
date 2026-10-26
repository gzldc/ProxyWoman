import FlowStore
import Foundation

/// What the URL, query and cookie edits of one evaluation point need: the exchange's regular-expression
/// time and compiled patterns, and the caps.
struct EditContext: Sendable {
    var allowance = RegexAllowance()
    var cache = PatternCache.shared
    var limits = RulesLimits()
}

extension ActionKind {
    /// Whether the action can reject the exchange: a URL or query edit whose result is not a valid
    /// target, or a response that cannot be built (only a snapshot that skipped validation has one).
    var canBeRejected: Bool {
        switch self {
        case .modifyURL, .modifyQuery, .returnHandwritten, .returnPreset: true
        default: false
        }
    }

    /// Whether the action, once applied, counts as a modification of the traffic (spec 5.7). Closing
    /// the connection sends nothing in its place, so it does not (D9).
    var countsAsModification: Bool {
        if case .closeConnection = self { return false }
        return true
    }
}

extension RuleEvaluator {
    /// What a URL or query edit did to the current target.
    enum TargetEdit {
        /// The edit cannot run (regular-expression problem); the outcome code says why.
        case failed(RuleOutcomeCode?)
        /// The target stays as it is.
        case unchanged
        /// The edit as the Map Remote that sends the request there (D3).
        case moved(MapRemoteAction)
    }

    /// The URL or query edit `kind` applied to `target`. A result that is not a valid target throws
    /// (the exchange is rejected, as for a Map Remote); a regular-expression problem means the action
    /// does not run, and input over the field cap leaves no outcome at all (nil code).
    static func editedTarget(_ kind: ActionKind, from target: HTTPMessageTarget, _ context: EditContext) throws
        -> TargetEdit
    {
        let edited: HTTPMessageTarget
        let preserveCredentials: Bool
        switch kind {
        case .modifyURL(let action):
            preserveCredentials = action.preserveCredentials
            switch URLEditing.apply(
                action, to: target, allowance: context.allowance, cache: context.cache, limits: context.limits) {
            case .success(let moved): edited = moved
            case .failure(.invalidResult): throw HTTPMutationError(code: .invalidPath, field: .path)
            case .failure(.patternTimedOut): return .failed(.patternTimedOut)
            case .failure(.patternDisabled): return .failed(.patternDisabled)
            case .failure(.inputTooLarge): return .failed(nil)
            }
        case .modifyQuery(let action):
            // The origin stays, so the credentials stay with it.
            preserveCredentials = false
            var changed = target
            let result = QueryEditing.apply(
                action.operations, to: target.pathAndQuery, allowance: context.allowance, cache: context.cache)
            if let problem = result.patternProblem { return .failed(problem) }
            changed.pathAndQuery = result.pathAndQuery
            edited = changed
        default:
            return .unchanged
        }
        let remote = MapRemoteAction(
            targetScheme: edited.scheme, targetHost: edited.host, targetPort: edited.port,
            path: .replace(edited.pathAndQuery), preserveCredentials: preserveCredentials)
        return remote.target(applyingTo: target) == target ? .unchanged : .moved(remote)
    }
}

extension RuleEvaluator {
    /// The response a Return Handwritten action sends. Text that does not parse throws: the exchange is
    /// rejected (D9).
    static func generated(_ handwritten: HandwrittenResponse, limits: RulesLimits) throws -> GeneratedResponse {
        switch handwritten.parse(limits: limits) {
        case .success(let parsed): return parsed.response
        case .failure(let error):
            switch error {
            case .empty, .invalidStatusLine, .unsupportedVersion, .invalidStatus:
                throw HTTPMutationError(code: .invalidStatus, field: .status)
            case .invalidHeader: throw HTTPMutationError(code: .invalidHeaderName, field: .headers)
            case .forbiddenHeader(let name): throw HTTPMutationError(code: .protectedHeader, field: .header(name: name))
            case .tooLarge, .bodyNotAllowed: throw HTTPMutationError(code: .invalidFraming, field: .body)
            }
        }
    }

    /// The response a Return Preset action sends. A preset that cannot be built throws: the exchange
    /// is rejected (D9).
    static func generated(_ preset: PresetResponse) throws -> GeneratedResponse {
        switch preset.build() {
        case .success(let response): return response
        case .failure(.locationRequired), .failure(.invalidLocation):
            throw HTTPMutationError(code: .invalidHeaderValue, field: .headerValue(name: "Location"))
        case .failure(.invalidField): throw HTTPMutationError(code: .invalidHeaderValue, field: .headers)
        }
    }
}

extension RuleEvaluator.PointRun {
    /// Edits the headers of this point's message. The old three methods always count as a
    /// modification; the others only when a header really changed. A look-up edit that touched no
    /// field is `editNoMatch`; a regular-expression problem skips only that edit and is listed with
    /// the pattern problems (and the sentence for it replaces the no-match one).
    mutating func editHeaders(_ operations: [HeaderEdit], ruleID: UUID, label: Int?) -> RuleOutcomeCode {
        let result = headers.applying(operations, allowance: context.allowance, cache: context.cache)
        headers = result.headers
        if let problem = result.patternProblem {
            patternProblems.append(RuleOutcome(ruleID: ruleID, code: problem, actionIndex: label))
        }
        if result.changed || operations.contains(where: \.isLegacyMethod) { modified = true }
        return result.matchedNothing && result.patternProblem == nil ? .editNoMatch : .applied
    }

    /// Edits the cookies of this point's message. The edit always counts as applied and as a
    /// modification, even when nothing changed (as a header edit does); a regular-expression problem
    /// skips only that edit and is listed with the pattern problems.
    mutating func editCookies(_ operations: [CookieEdit], ruleID: UUID, label: Int?) -> RuleOutcomeCode {
        let result =
            direction == .request
            ? CookieEditing.applyToRequest(
                operations, headers: headers, allowance: context.allowance, cache: context.cache)
            : CookieEditing.applyToResponse(
                operations, headers: headers, allowance: context.allowance, cache: context.cache)
        headers = result.headers
        if let problem = result.patternProblem {
            patternProblems.append(RuleOutcome(ruleID: ruleID, code: problem, actionIndex: label))
        }
        edits.insert(RuleOutcome(ruleID: ruleID, code: .applied, actionIndex: label))
        modified = true
        return .applied
    }

    /// Adds a delay to the exchange's total; the total never passes `limits.delayMillisecondsMax`, and
    /// the first action that is cut off says so once. A delay is not a modification of the traffic.
    mutating func addDelay(_ milliseconds: Int, ruleID: UUID, label: Int?) -> RuleOutcomeCode {
        let cap = context.limits.delayMillisecondsMax
        let (sum, overflow) = delayMilliseconds.addingReportingOverflow(max(milliseconds, 0))
        if overflow || sum > cap {
            delayMilliseconds = cap
            if !delayWasCapped {
                delayWasCapped = true
                patternProblems.append(RuleOutcome(ruleID: ruleID, code: .delayCapped, actionIndex: label))
            }
        } else {
            delayMilliseconds = sum
        }
        return .applied
    }
}
