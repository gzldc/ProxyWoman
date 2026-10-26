import FlowStore
import Foundation

/// Writes an Execute result into a flow's record: mark, comment, visibility, overlay and the
/// Execute record. Pure field arithmetic on `ExecuteFieldValues`; never touches the manual mark,
/// provenance or `rulesModified`.
public enum ExecuteWriter {
    /// What the flow's mark, comment and visibility were before any Execute (D6): a field still at
    /// the value the last run wrote goes back to that run's baseline, one the user changed since
    /// is its own new baseline.
    public static func baseline(of flow: Flow) -> ExecuteFieldValues {
        let current = ExecuteFieldValues(ruleMark: flow.ruleMark, comment: flow.comment, isHidden: flow.isHidden)
        guard let record = flow.execute else { return current }
        return restored(current, record: record)
    }

    public static func apply(_ result: ExecuteFlowResult, runID: UUID, at date: Date = .now, to flow: inout Flow) {
        guard result.skipped == nil else { return }
        if result.matches == nil && result.annotations.isEmpty && result.overlay == nil {
            guard flow.execute != nil else { return }
            let base = baseline(of: flow)
            write(base, to: &flow)
            flow.executeOverlay = nil
            flow.execute = nil
            return
        }
        let base = baseline(of: flow)
        var values = base
        for annotation in result.annotations {
            switch annotation {
            case .mark(var mark):
                if case .rule(let id, let name) = mark.source {
                    mark.source = .execute(runID: runID, ruleID: id, ruleName: name)
                }
                values.ruleMark = mark
            case .resetMark(let background, let foreground):
                values.ruleMark = FlowMark.reset(values.ruleMark, background: background, foreground: foreground)
            case .comment(let action):
                values.comment = action.applying(to: values.comment)
            case .hide:
                values.isHidden = true
            }
        }
        write(values, to: &flow)
        flow.executeOverlay = result.overlay
        flow.execute = ExecuteRecord(
            runID: runID, executedAt: date,
            matches: result.matches ?? RuleMatchSummary(revision: 0, ruleIDs: [], total: 0),
            baseline: base, written: values)
    }

    /// false when there was nothing to undo (no record, or `onlyRun` names another run).
    @discardableResult
    public static func undo(_ flow: inout Flow, onlyRun: UUID? = nil) -> Bool {
        guard let record = flow.execute else { return false }
        if let onlyRun, record.runID != onlyRun { return false }
        write(baseline(of: flow), to: &flow)
        flow.executeOverlay = nil
        flow.execute = nil
        return true
    }

    private static func restored(_ current: ExecuteFieldValues, record: ExecuteRecord) -> ExecuteFieldValues {
        ExecuteFieldValues(
            ruleMark: current.ruleMark == record.written.ruleMark ? record.baseline.ruleMark : current.ruleMark,
            comment: current.comment == record.written.comment ? record.baseline.comment : current.comment,
            isHidden: current.isHidden == record.written.isHidden ? record.baseline.isHidden : current.isHidden)
    }

    private static func write(_ values: ExecuteFieldValues, to flow: inout Flow) {
        flow.ruleMark = values.ruleMark
        flow.comment = values.comment
        flow.isHidden = values.isHidden
    }
}
