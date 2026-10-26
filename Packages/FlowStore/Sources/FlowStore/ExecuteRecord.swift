import Foundation

/// Session-only message versions an Execute run produced offline. Never exported and never
/// persisted; the original record (`messages`, legacy fields) is untouched.
public struct ExecuteOverlay: Sendable, Equatable {
    /// Boundary `.upstreamRequest`; nil when Execute left the request as it was.
    public var request: HTTPMessageSnapshot?
    /// Boundary `.downstreamResponse`; nil when Execute left the response as it was.
    public var response: HTTPMessageSnapshot?
    /// True when `response` is a whole response a rule returned (file, text, preset) in place of the origin's.
    public var responseIsLocal: Bool

    public init(request: HTTPMessageSnapshot? = nil, response: HTTPMessageSnapshot? = nil, responseIsLocal: Bool = false) {
        self.request = request
        self.response = response
        self.responseIsLocal = responseIsLocal
    }

    public var isEmpty: Bool { request == nil && response == nil }
}

/// The three annotation fields Execute may write.
public struct ExecuteFieldValues: Sendable, Equatable {
    public var ruleMark: FlowMark?
    public var comment: String?
    public var isHidden: Bool

    public init(ruleMark: FlowMark? = nil, comment: String? = nil, isHidden: Bool = false) {
        self.ruleMark = ruleMark
        self.comment = comment
        self.isHidden = isHidden
    }
}

/// What the last Execute run did to a flow: enough to rerun idempotently and to undo.
public struct ExecuteRecord: Sendable, Equatable {
    public var runID: UUID
    public var executedAt: Date
    public var matches: RuleMatchSummary
    /// Field values before Execute wrote anything.
    public var baseline: ExecuteFieldValues
    /// Field values Execute wrote.
    public var written: ExecuteFieldValues

    public init(
        runID: UUID, executedAt: Date, matches: RuleMatchSummary,
        baseline: ExecuteFieldValues, written: ExecuteFieldValues
    ) {
        self.runID = runID
        self.executedAt = executedAt
        self.matches = matches
        self.baseline = baseline
        self.written = written
    }
}
