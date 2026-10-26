import FlowStore
import Foundation

/// One frozen Compose send, in Foundation types only. `url` is already in its wire form (see
/// `ComposeDraft.outgoingRequest`); headers go out in this order, duplicates included.
public struct ComposeOutgoingRequest: Sendable, Equatable {
    /// Identifies the send for `cancel` and in the recorded flow; new for every Send.
    public var id: UUID
    public var method: String
    public var url: String
    public var headers: [HeaderField]
    public var body: Data
    /// A managed file sent as the body instead of `body` (which is then empty); streamed, not loaded.
    public var bodyAsset: ComposeBodyFile?
    public var sourceFlowID: Int?
    public var applyRules: Bool
    public var timeoutSeconds: Int
    public var http1Only: Bool
    /// Set by a repeat run; recorded with the flow.
    public var repeatTag: RepeatRunTag?

    public init(id: UUID, method: String, url: String, headers: [HeaderField], body: Data, sourceFlowID: Int?,
                applyRules: Bool, timeoutSeconds: Int, http1Only: Bool, repeatTag: RepeatRunTag? = nil,
                bodyAsset: ComposeBodyFile? = nil) {
        self.id = id
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.sourceFlowID = sourceFlowID
        self.applyRules = applyRules
        self.timeoutSeconds = timeoutSeconds
        self.http1Only = http1Only
        self.repeatTag = repeatTag
        self.bodyAsset = bodyAsset
    }
}

/// A delivered response head and the body bytes kept in memory (`truncated` when more arrived).
public struct ComposeResponseSnapshot: Sendable, Equatable {
    public var status: Int
    public var reason: String
    public var headers: [HeaderField]
    public var body: Data
    /// Every body byte received, kept or not.
    public var bodyBytes: UInt64
    public var truncated: Bool
    public var trailers: [HeaderField]

    public init(status: Int, reason: String, headers: [HeaderField], body: Data, bodyBytes: UInt64, truncated: Bool,
                trailers: [HeaderField]) {
        self.status = status
        self.reason = reason
        self.headers = headers
        self.body = body
        self.bodyBytes = bodyBytes
        self.truncated = truncated
        self.trailers = trailers
    }
}

public struct ComposeOutcomeFailure: Sendable, Equatable {
    /// A stable machine code (`compose.cancelled`, `upstream.unreachable`, …); never free text.
    public var code: String
    /// Localized, complete sentence.
    public var message: String
    /// True when the send ended because it was cancelled (the bridge sets it from the client's own
    /// cancellation code), so callers never compare machine codes to tell a cancel from a failure.
    public var isCancellation: Bool

    public init(code: String, message: String, isCancellation: Bool = false) {
        self.code = code
        self.message = message
        self.isCancellation = isCancellation
    }
}

/// What the origin can have seen of a send.
public enum ComposeDeliveryState: Sendable, Equatable {
    case notSent
    /// The request head was handed to the upstream connection but no response head came back.
    case unknown
    case answered
}

/// The final result of one send: exactly one of `response` and `failure`. A failure after a
/// response head arrived keeps what came in `partialResponse`, which is never a complete response.
public struct ComposeOutcome: Sendable, Equatable {
    public var flowID: Int?
    public var response: ComposeResponseSnapshot?
    public var failure: ComposeOutcomeFailure?
    public var partialResponse: ComposeResponseSnapshot?
    public var delivery: ComposeDeliveryState

    public init(flowID: Int?, response: ComposeResponseSnapshot? = nil, failure: ComposeOutcomeFailure? = nil,
                partialResponse: ComposeResponseSnapshot? = nil, delivery: ComposeDeliveryState) {
        self.flowID = flowID
        self.response = response
        self.failure = failure
        self.partialResponse = partialResponse
        self.delivery = delivery
    }
}

/// The Foundation-only facade the Compose window sends through; the App bridges it to the
/// proxy server. `send` returns once the send ended; `cancel` only asks — the outcome of the
/// send (which may still be a complete response) is the answer.
public protocol ComposeClient: AnyObject, Sendable {
    func send(_ request: ComposeOutgoingRequest) async -> ComposeOutcome
    func cancel(_ id: UUID)
}
