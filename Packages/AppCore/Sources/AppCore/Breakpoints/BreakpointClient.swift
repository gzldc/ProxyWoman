import FlowStore
import Foundation
import RulesEngine

/// Identifies one paused message for a command. A stale token (ticket ended, newer generation)
/// is answered `invalid` or `expired` by the proxy; it can never act on another ticket.
public struct BreakpointTicketToken: Hashable, Sendable {
    public var id: UUID
    public var generation: UInt64
    public var revision: UInt64

    public init(id: UUID, generation: UInt64, revision: UInt64) {
        self.id = id
        self.generation = generation
        self.revision = revision
    }
}

public enum BreakpointTicketPhase: String, Sendable, Equatable {
    /// Paused at the head; the body has not been read and would stream unchanged.
    case pausedHeaders
    case collectingBody
    /// The whole body was read and can be edited or kept.
    case pausedBody
    /// Continued; the ticket is about to disappear.
    case forwarding
    /// Cancelled, expired or failed; the ticket is about to disappear.
    case ended
}

/// A Foundation-only copy of one paused message. Deadlines are wall-clock dates converted from
/// the proxy's monotonic deadline when the copy was taken.
public struct BreakpointTicketSnapshot: Sendable, Identifiable, Equatable {
    public var token: BreakpointTicketToken
    /// The flow this exchange is recorded as; nil while recording is paused (not listed as a flow).
    public var flowID: Int?
    public var direction: HTTPMessageDirection
    public var originalHead: HTTPMessageHead
    /// The head as it would be sent now (after Header/Map rules); the editor starts from it.
    public var effectiveHead: HTTPMessageHead
    /// A Map Local request: its target and method cannot change.
    public var isLocalRoute: Bool
    public var isCompose: Bool
    public var mode: BreakpointPauseMode
    public var phase: BreakpointTicketPhase
    public var matchedAt: Date
    public var deadline: Date
    public var matchedRuleIDs: [UUID]
    public var matchedRuleCount: Int
    /// Exact length of a collected body.
    public var bodyLength: Int64?
    /// The announced length exceeds the collection limit: the body can only stream unchanged.
    public var bodyTooLargeToCollect: Bool

    public var id: UUID { token.id }

    public init(
        token: BreakpointTicketToken, flowID: Int?, direction: HTTPMessageDirection, originalHead: HTTPMessageHead,
        effectiveHead: HTTPMessageHead, isLocalRoute: Bool, isCompose: Bool, mode: BreakpointPauseMode,
        phase: BreakpointTicketPhase, matchedAt: Date, deadline: Date, matchedRuleIDs: [UUID], matchedRuleCount: Int,
        bodyLength: Int64?, bodyTooLargeToCollect: Bool
    ) {
        self.token = token
        self.flowID = flowID
        self.direction = direction
        self.originalHead = originalHead
        self.effectiveHead = effectiveHead
        self.isLocalRoute = isLocalRoute
        self.isCompose = isCompose
        self.mode = mode
        self.phase = phase
        self.matchedAt = matchedAt
        self.deadline = deadline
        self.matchedRuleIDs = matchedRuleIDs
        self.matchedRuleCount = matchedRuleCount
        self.bodyLength = bodyLength
        self.bodyTooLargeToCollect = bodyTooLargeToCollect
    }

    /// The request target when this is a request pause; responses carry only their own head.
    public var requestTarget: HTTPMessageTarget? {
        if case .request(let target, _) = effectiveHead { target } else { nil }
    }

    public var status: Int? {
        if case .response(let status, _, _) = effectiveHead { status } else { nil }
    }
}

/// A file the proxy copied into its own private spool for one paused message. The UI never reads
/// the file: it only holds this handle until Continue.
public struct BreakpointImportedBody: Sendable, Equatable {
    public var id: UUID
    public var size: Int64
    /// The picked file's name, for display only (no path).
    public var fileName: String

    public init(id: UUID, size: Int64, fileName: String) {
        self.id = id
        self.size = size
        self.fileName = fileName
    }
}

public enum BreakpointBodyReplacement: Sendable, Equatable {
    case unchanged
    case replace(Data)
    /// The body imported by `BreakpointClient.replaceBodyFromFile` for the same ticket.
    case file(BreakpointImportedBody)
}

public struct BreakpointClientEdit: Sendable, Equatable {
    public var head: HTTPMessageHead
    public var body: BreakpointBodyReplacement
    public var encodingChoice: BodyEncodingChoice

    public init(head: HTTPMessageHead, body: BreakpointBodyReplacement, encodingChoice: BodyEncodingChoice) {
        self.head = head
        self.body = body
        self.encodingChoice = encodingChoice
    }
}

public enum BreakpointClientCommand: Sendable, Equatable {
    case `continue`(BreakpointTicketToken, BreakpointClientEdit)
    case cancel(BreakpointTicketToken)
    /// Read the whole body of a headers-only pause so it can be edited.
    case collectBody(BreakpointTicketToken)
}

public enum BreakpointClientResult: Sendable, Equatable {
    case accepted
    /// The deadline passed: the exchange was ended, nothing was sent.
    case expired
    /// Rejected (stale token, invalid edit, ticket already ended); a live ticket keeps waiting.
    case invalid
    case unsupported
}

/// At most `maxBytes` from the start of a collected body.
public struct BreakpointBodyPreview: Sendable, Equatable {
    public var data: Data
    public var totalLength: Int64

    public init(data: Data, totalLength: Int64) {
        self.data = data
        self.totalLength = totalLength
    }

    public var isComplete: Bool { Int64(data.count) >= totalLength }
}

/// The breakpoint operations the UI may use. The App implements it over the proxy's coordinator;
/// nothing here depends on the proxy engine.
public protocol BreakpointClient: Sendable {
    func tickets() async -> [BreakpointTicketSnapshot]
    /// A revision notification per change. The app keeps exactly one subscriber (`BreakpointQueueModel`).
    func changes() -> AsyncStream<UInt64>
    func loadBody(_ token: BreakpointTicketToken, maxBytes: Int) async throws -> BreakpointBodyPreview
    func perform(_ command: BreakpointClientCommand) async -> BreakpointClientResult
    /// Copies `url` (a regular file within the body limit) into the proxy's private spool for this
    /// collected-body pause, streaming off the main actor. A newer import replaces an older one.
    func replaceBodyFromFile(_ token: BreakpointTicketToken, url: URL) async throws -> BreakpointImportedBody
    /// Turns pausing of new messages on or off; `cancelExisting` also ends every paused message.
    func setAdmission(enabled: Bool, cancelExisting: Bool) async
    /// Ends the paused messages of these flows, as clearing the flows does.
    func cancelTickets(forFlows flowIDs: Set<Int>) async
}
