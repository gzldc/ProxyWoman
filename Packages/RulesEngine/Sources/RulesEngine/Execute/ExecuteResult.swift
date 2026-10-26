import FlowStore
import Foundation

/// What one Execute evaluation decided for one flow, before anything is written to the store.
public struct ExecuteFlowResult: Sendable, Equatable {
    public enum Skip: Sendable, Equatable { case inProgress, hidden }

    public var flowID: Int
    public var skipped: Skip?
    /// Merged P0/P1/P2/P3 outcomes after D12 (nil: no rule left any record).
    public var matches: RuleMatchSummary?
    /// In the order the rules ran; marks carry `.rule(id:name:)` here, the writer turns them into `.execute`.
    public var annotations: [FlowAnnotation]
    public var overlay: ExecuteOverlay?
    /// Outcomes relabelled `notApplicableOffline` (for the summary).
    public var notApplicableActions: Int

    public init(
        flowID: Int, skipped: Skip? = nil, matches: RuleMatchSummary? = nil, annotations: [FlowAnnotation] = [],
        overlay: ExecuteOverlay? = nil, notApplicableActions: Int = 0
    ) {
        self.flowID = flowID
        self.skipped = skipped
        self.matches = matches
        self.annotations = annotations
        self.overlay = overlay
        self.notApplicableActions = notApplicableActions
    }
}
