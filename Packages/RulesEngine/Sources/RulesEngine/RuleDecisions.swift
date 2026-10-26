import Foundation
import FlowStore

public enum RuleRoute: Sendable, Equatable {
    case original
    // `.generated` and `.close` come from a final action (D8, D9): nothing at the request point runs after
    // them. The response point of a generated response runs with `isLocalResponse`; a closed exchange
    // has no response point.
    case remote(MapRemoteAction)
    case local(MapLocalAction)
    case localDirectory(DirectoryRoute)
    case generated(GeneratedResponse)
    case close(CloseMode, ruleID: UUID)
}

public struct DirectoryRoute: Sendable, Equatable {
    public var action: MapLocalDirectoryAction
    public var subpath: DirectorySubpath
    public var method: String

    public init(action: MapLocalDirectoryAction, subpath: DirectorySubpath, method: String) {
        self.action = action
        self.subpath = subpath
        self.method = method
    }
}

public struct RequestRuleDecision: Sendable, Equatable {
    /// The original request head with every matching header edit applied. The target is the
    /// original one: a Map Remote route is applied by the executor from `route`.
    public var effectiveHead: HTTPMessageHead
    public var route: RuleRoute
    public var breakpoint: BreakpointPauseMode?
    public var matches: RuleMatchSummary
    /// Body find-and-replace steps that passed the message-level checks, in rule order. Empty means
    /// nothing is collected. Their outcomes in `matches` are provisional (`applied`) until the
    /// executor has seen the body.
    public var bodyRewrites: [BodyRewriteStep] = []
    /// A header edit or a route (Map Remote, Return File, a generated response) was applied.
    /// Breakpoints and closing the connection do not count; body rewrites are settled once the body
    /// is seen.
    public var rulesModified: Bool = false
    /// What the response point of the same exchange needs. Nil only for a decision built outside
    /// `RuleEvaluator` (the frozen oracle of the old evaluator in the tests).
    public var carry: RuleCarry? = nil
    /// What the rules judged at the request point did to the flow's record, in the order they ran.
    /// Never part of `rulesModified`.
    public var annotations: [FlowAnnotation] = []
    /// Milliseconds the exchange waits before it goes on, the sum of every delay action (capped).
    public var delayMilliseconds: Int = 0
}

/// What a rule judged at the response does instead of forwarding the origin's response (spec 12.7: Return File,
/// manual and predefined responses, closing the connection). The origin response is discarded.
public struct ResponseReplacement: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case file(MapLocalAction)
        case generated(GeneratedResponse)
        /// Closes the client connection; the response head never reaches the client.
        case close(CloseMode)
    }

    public var kind: Kind
    public var ruleID: UUID
    /// The action's position in its rule, set as for outcomes (nil for a single-action rule).
    public var actionIndex: Int?

    public init(_ kind: Kind, ruleID: UUID, actionIndex: Int?) {
        self.kind = kind
        self.ruleID = ruleID
        self.actionIndex = actionIndex
    }

    /// The route that produces the replacement's response; nil for a close.
    public var route: RuleRoute? {
        switch kind {
        case .file(let action): .local(action)
        case .generated(let response): .generated(response)
        case .close: nil
        }
    }
}

extension RuleOutcomeCode {
    /// A Return File / manual / predefined action of a rule judged at the response could not replace the response:
    /// the proxy had already produced it itself (a Return File of the request point).
    public static let responseAlreadyLocal = RuleOutcomeCode(rawValue: "responseAlreadyLocal")!
}

public struct ResponseRuleDecision: Sendable, Equatable {
    public var effectiveHead: HTTPMessageHead
    public var breakpoint: BreakpointPauseMode?
    public var matches: RuleMatchSummary
    public var bodyRewrites: [BodyRewriteStep] = []
    /// The status the status rules asked for; `effectiveHead` already carries it. The rules run in
    /// order, so the last one wins.
    public var statusRewrite: Int?
    /// The reason phrase the winning status rule wrote, nil for the conventional one.
    public var statusReason: String? = nil
    /// A header edit or a status rewrite was applied.
    public var rulesModified: Bool = false
    /// What the rules judged at the response point did to the flow's record, in the order they ran.
    public var annotations: [FlowAnnotation] = []
    /// Request-side actions of rules judged at the response that can change the recorded request, in the order they
    /// ran. The request itself is already gone; the executor applies them to the record
    /// (`RecordedRequestEditing`). Empty unless such a rule matched.
    public var recordedRequestActions: [RecordedRequestAction] = []
    /// A Return File, manual or predefined response, or a close of a rule judged at the response: it answers in
    /// place of the origin's response (which is discarded) or closes the client connection. A response breakpoint
    /// and the body rewrites of the same exchange do not apply to it.
    public var replacement: ResponseReplacement? = nil
    /// Milliseconds the response head is held back, the sum of every delay action of rules judged at the response (capped).
    public var delayMilliseconds: Int = 0
    /// What the completion point needs: the final response and where a final action stopped the rules.
    public var carry: ResponseCarry

    /// Without a `carry`, the final response is `effectiveHead` and no final action ran.
    init(
        effectiveHead: HTTPMessageHead, breakpoint: BreakpointPauseMode?, matches: RuleMatchSummary,
        bodyRewrites: [BodyRewriteStep] = [], statusRewrite: Int? = nil, statusReason: String? = nil,
        rulesModified: Bool = false, annotations: [FlowAnnotation] = [],
        recordedRequestActions: [RecordedRequestAction] = [], replacement: ResponseReplacement? = nil,
        delayMilliseconds: Int = 0, carry: ResponseCarry? = nil
    ) {
        self.effectiveHead = effectiveHead
        self.breakpoint = breakpoint
        self.matches = matches
        self.bodyRewrites = bodyRewrites
        self.statusRewrite = statusRewrite
        self.statusReason = statusReason
        self.rulesModified = rulesModified
        self.annotations = annotations
        self.recordedRequestActions = recordedRequestActions
        self.replacement = replacement
        self.delayMilliseconds = delayMilliseconds
        self.carry = carry ?? ResponseCarry(finalStop: nil, head: effectiveHead)
    }
}

/// What the response point of an exchange leaves for its completion point (D14).
public struct ResponseCarry: Sendable, Equatable {
    /// Where a final action stopped the rules, at the request point or the response point. Nothing at
    /// or below it is judged at completion.
    public var finalStop: RuleCarry.FinalStop?
    /// The response status and headers once every response-point action ran.
    public var status: Int
    public var headers: [HeaderField]
    /// The peeked response body once the response-point body rewrites ran on it; the completion
    /// point's body rows read it.
    public var body: BodyPeek

    public init(finalStop: RuleCarry.FinalStop?, status: Int, headers: [HeaderField], body: BodyPeek = .notCollected) {
        self.finalStop = finalStop
        self.status = status
        self.headers = headers
        self.body = body
    }

    init(finalStop: RuleCarry.FinalStop?, head: HTTPMessageHead) {
        var status = 0
        if case .response(let code, _, _) = head { status = code }
        self.init(finalStop: finalStop, status: status, headers: head.headers)
    }
}

/// What the completion point decided: only its own rules' outcomes (the caller adds them to the flow's
/// provenance) and their annotations. It never touches the exchange's transport.
public struct CompletionRuleDecision: Sendable, Equatable {
    public var matches: RuleMatchSummary
    /// What the rules judged at completion did to the flow's record, in the order they ran.
    public var annotations: [FlowAnnotation]

    public init(matches: RuleMatchSummary, annotations: [FlowAnnotation] = []) {
        self.matches = matches
        self.annotations = annotations
    }
}

extension RuleOutcomeCode {
    /// A later Map rule that lost to the first one. Only flows recorded by earlier versions carry it.
    public static let shadowed = RuleOutcomeCode(rawValue: "shadowed")!
    /// A regular expression of the rule ran out of time on this message, so the rule did not match.
    public static let patternTimedOut = RuleOutcomeCode(rawValue: "patternTimedOut")!
    /// A regular expression of the rule is switched off after repeated timeouts; the rule cannot
    /// match until it is saved again.
    public static let patternDisabled = RuleOutcomeCode(rawValue: "patternDisabled")!
}

/// A mutation failure together with the rules evaluated up to and including the failing rule.
public struct RuleEvaluationError: Error, Equatable, Sendable {
    public let mutation: HTTPMutationError
    public let matches: RuleMatchSummary
    /// The annotations that ran at this point before the failure; their outcomes stay `applied`.
    public let annotations: [FlowAnnotation]

    public init(mutation: HTTPMutationError, matches: RuleMatchSummary, annotations: [FlowAnnotation] = []) {
        self.mutation = mutation
        self.matches = matches
        self.annotations = annotations
    }
}

/// What the tools (block list, allow list, SSL decryption list) already decided about a CONNECT before
/// the rules see it (D12): the rules can only keep a decrypted host out of decryption.
public enum ConnectToolDecision: Sendable { case decrypt, tunnel }

/// What the CONNECT point (P0) decided (D11). Its outcomes and annotations belong to the CONNECT's own
/// row, if it has one (D14); the requests inside a decrypted tunnel are evaluated from the start.
public struct ConnectRuleDecision: Sendable, Equatable {
    public enum Disposition: Sendable, Equatable {
        /// Go on as the tools decided.
        case proceed
        /// Do not decrypt: open a plain tunnel instead.
        case noDecrypt
        /// Close the client connection.
        case close(CloseMode, ruleID: UUID)
    }

    public var disposition: Disposition
    public var matches: RuleMatchSummary
    /// What the rules did to the CONNECT's record, in the order they ran.
    public var annotations: [FlowAnnotation]
    /// Where a final action stopped the CONNECT point, if one did.
    public var finalStop: RuleCarry.FinalStop?

    public init(
        disposition: Disposition = .proceed, matches: RuleMatchSummary, annotations: [FlowAnnotation] = [],
        finalStop: RuleCarry.FinalStop? = nil
    ) {
        self.disposition = disposition
        self.matches = matches
        self.annotations = annotations
        self.finalStop = finalStop
    }
}
