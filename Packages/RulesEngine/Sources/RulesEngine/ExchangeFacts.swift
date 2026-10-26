import FlowStore
import Foundation

/// What is known about an exchange besides its messages, as the proxy hands it to the evaluator (D10,
/// D17). Nil means "not known": a row reading it cannot be answered (spec §5.5.5).
public struct ExchangeFacts: Sendable, Equatable {
    public enum AppLookup: Sendable, Equatable {
        case known(ClientApp)
        /// The lookup did not answer in time (`appUnknown`).
        case unknown
        /// There is no app to look up: the virtual client of Compose and Repeat.
        case notApplicable
    }

    public var clientIP: String?
    public var remoteIP: String?
    public var clientHTTPVersion: HTTPWireVersion?
    public var upstreamHTTPVersion: HTTPWireVersion?
    /// Canonical text, `TLS 1.0` … `TLS 1.3` (D7).
    public var clientTLSVersion: String?
    public var upstreamTLSVersion: String?
    /// The origin's certificate; only for https once the upstream handshake completed (D9).
    public var certificate: CertificateSummary?
    public var app: AppLookup
    public var requestStartedAt: Date
    /// The zone of the request time and date fields; the user's own zone outside tests, like validation.
    public var timeZone: TimeZone
    /// The flow's comment as the evaluation point is entered (the user's or an earlier point's).
    public var comment: String?
    /// Whether a rule changed the exchange before this evaluation point.
    public var rulesModified: Bool
    /// Whether the exchange is held at a breakpoint right now (the live count reads it as "paused").
    public var isPausedAtBreakpoint: Bool

    public init(
        clientIP: String? = nil, remoteIP: String? = nil, clientHTTPVersion: HTTPWireVersion? = nil,
        upstreamHTTPVersion: HTTPWireVersion? = nil, clientTLSVersion: String? = nil,
        upstreamTLSVersion: String? = nil, certificate: CertificateSummary? = nil, app: AppLookup = .notApplicable,
        requestStartedAt: Date = .now, timeZone: TimeZone = .current, comment: String? = nil,
        rulesModified: Bool = false, isPausedAtBreakpoint: Bool = false
    ) {
        self.clientIP = clientIP
        self.remoteIP = remoteIP
        self.clientHTTPVersion = clientHTTPVersion
        self.upstreamHTTPVersion = upstreamHTTPVersion
        self.clientTLSVersion = clientTLSVersion
        self.upstreamTLSVersion = upstreamTLSVersion
        self.certificate = certificate
        self.app = app
        self.requestStartedAt = requestStartedAt
        self.timeZone = timeZone
        self.comment = comment
        self.rulesModified = rulesModified
        self.isPausedAtBreakpoint = isPausedAtBreakpoint
    }
}

/// What is known once an exchange finished: what the completion point's rows read (D14).
public struct CompletionFacts: Sendable, Equatable {
    public enum SessionState: String, Sendable {
        case completed, failed
        /// A CONNECT tunnel; no rule sees one before R4 (D18).
        case tunnel
    }

    public var state: SessionState
    /// The whole exchange, as the list's duration column measures it: finished minus started, to the
    /// nearest millisecond.
    public var durationMilliseconds: Int
    /// The response bytes that actually came over the wire; nil when there was no response.
    public var responseWireBytes: Int?

    public init(state: SessionState, durationMilliseconds: Int, responseWireBytes: Int?) {
        self.state = state
        self.durationMilliseconds = durationMilliseconds
        self.responseWireBytes = responseWireBytes
    }
}

/// The current message one condition group is judged against: the request as the rules above left it
/// and, from the response point on, the response as they left it.
public struct ConditionInput: Sendable {
    /// The current request target (an earlier Map Remote moved it).
    public var target: HTTPMessageTarget
    /// The current request headers (earlier header edits applied).
    public var requestHeaders: [HeaderField]
    /// Nil while the request is judged, or when there is no response at all.
    public var response: (status: Int, headers: [HeaderField])?
    public var facts: ExchangeFacts
    /// Nil before the completion point: its rows are then unknown (they never get there, a rule that
    /// has one is judged at completion).
    public var completion: CompletionFacts?
    /// What the body rows read: the peeked request / response body, as the rules above left it.
    public var requestBody: BodyPeek
    public var responseBody: BodyPeek
    /// A cap on one body regular expression's time below the body budget, for a point that runs on the
    /// event loop (the completion point); nil: the body budget alone.
    public var bodyRegexLimit: Duration?

    public init(
        target: HTTPMessageTarget, requestHeaders: [HeaderField] = [],
        response: (status: Int, headers: [HeaderField])? = nil, facts: ExchangeFacts = ExchangeFacts(),
        completion: CompletionFacts? = nil, requestBody: BodyPeek = .notCollected,
        responseBody: BodyPeek = .notCollected, bodyRegexLimit: Duration? = nil
    ) {
        self.target = target
        self.requestHeaders = requestHeaders
        self.response = response
        self.facts = facts
        self.completion = completion
        self.requestBody = requestBody
        self.responseBody = responseBody
        self.bodyRegexLimit = bodyRegexLimit
    }
}

/// The answer of a condition group, and why rows it looked at could not answer.
public struct ConditionVerdict: Sendable, Equatable {
    public var result: RuleMatchResult
    /// The outcome codes of rows that were evaluated and could not be answered (`unknownSize`,
    /// `appUnknown`, …), each once, in the order they came up. Empty when the group matched.
    public var notes: [RuleOutcomeCode]

    public init(result: RuleMatchResult, notes: [RuleOutcomeCode] = []) {
        self.result = result
        self.notes = notes
    }
}

extension RuleOutcomeCode {
    /// A size condition of the rule could not be judged: the message's size is not known (no
    /// `Content-Length`, or a chunked body).
    public static let unknownSize = RuleOutcomeCode(rawValue: "unknownSize")!
    /// An app condition of the rule could not be judged: the app that sent the request was not found in time.
    public static let appUnknown = RuleOutcomeCode(rawValue: "appUnknown")!
}
