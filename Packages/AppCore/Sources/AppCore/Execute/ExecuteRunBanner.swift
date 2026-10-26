import Foundation
import Localization

/// The strip at the top of the main window that tells how the latest Execute run is going (spec §5).
public struct ExecuteRunBanner: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case running(done: Int, total: Int)
        case finished(runID: UUID, considered: Int, modified: Int)
        case cancelled(runID: UUID, considered: Int, modified: Int)
    }

    public var state: State
    public var canUndo: Bool

    /// The result and its details exist only once the run is over.
    public var canShowDetails: Bool {
        if case .running = state { false } else { true }
    }

    /// Nothing while idle, and nothing for a finished run the user already closed.
    public static func of(phase: ExecuteRunner.Phase, canUndo: Bool, dismissedRunID: UUID?) -> ExecuteRunBanner? {
        switch phase {
        case .idle:
            return nil
        case .running(let done, let total):
            return ExecuteRunBanner(state: .running(done: done, total: total), canUndo: false)
        case .finished(let summary):
            guard summary.runID != dismissedRunID else { return nil }
            let state: State =
                summary.wasCancelled
                ? .cancelled(runID: summary.runID, considered: summary.considered, modified: summary.modifiedFlows)
                : .finished(runID: summary.runID, considered: summary.considered, modified: summary.modifiedFlows)
            return ExecuteRunBanner(state: state, canUndo: canUndo)
        }
    }

    public func text(localizer: Localizer = L10n.localizer) -> String {
        switch state {
        case .running(let done, let total):
            localizer.format("execute.runBanner.running", arguments: [done, total])
        case .finished(_, let considered, let modified):
            localizer.format("execute.runBanner.finished", arguments: [considered, modified])
        case .cancelled(_, let considered, let modified):
            localizer.format("execute.runBanner.cancelled", arguments: [considered, modified])
        }
    }
}

/// Why `ExecuteRunner.runNow` did nothing; shown as a transient notice so a click never fails silently.
public enum ExecuteNotStartedReason: Equatable, Sendable {
    case running, noRules, noFlows

    /// nil: the run can start.
    public static func of(phase: ExecuteRunner.Phase, ruleCount: Int, flowCount: Int) -> ExecuteNotStartedReason? {
        if case .running = phase { return .running }
        if ruleCount == 0 { return .noRules }
        return flowCount == 0 ? .noFlows : nil
    }

    public func text(localizer: Localizer = L10n.localizer) -> String {
        switch self {
        case .running: localizer.string("execute.runNow.busy")
        case .noRules: localizer.string("execute.runNow.noRules")
        case .noFlows: localizer.string("execute.runNow.noFlows")
        }
    }
}
