import FlowStore
import Foundation

/// Why an action of a saved rule will not do what its card suggests (spec 12.6).
/// A rule with such an action is still valid and saves; the editor shows the reason on the card.
public enum ActionExecutionWarning: Sendable, Equatable, Hashable, CaseIterable {
    /// 1: the rule is judged at the response, so a request-side action cannot reach the origin; it only changes the
    /// recorded request (or is skipped when it cannot be applied to a record).
    case requestActionVisibleOnly
    /// 2: the rule may be judged at the request or at the response. Kept for the editor's sake; no rule produces it today.
    case matchPointUncertain
    /// 3: a request-side action sits after a response-side one in a rule judged at the request, so the card order
    /// suggests a sequence the exchange does not follow.
    case requestActionAfterResponseAction
    /// 4: Do Not Decrypt only works when every condition is one of all sessions, URL, host, scheme, client IP or process.
    case noDecryptNeedsSimpleConditions
    /// 5: a rule can return only one manual response; this one is never used.
    case multipleManualResponses
    /// Error: an earlier action ended the rule's evaluation, so this one never runs.
    case afterFinalAction

    public var isError: Bool { self == .afterFinalAction }
}

/// The checks that keep a rule saveable but flag what will not run as written.
public enum RuleValidation {
    /// Per action index, the warnings and errors of `rule`'s actions in a stable order (the case order of
    /// `ActionExecutionWarning`). An action without any is absent from the result. Pure: it reads only the rule.
    public static func executionWarnings(_ rule: Rule) -> [Int: [ActionExecutionWarning]] {
        let point = rule.conditions.judgmentPoint
        let actions = rule.actions.map { $0.expandingMagicString() }
        var found: [Int: Set<ActionExecutionWarning>] = [:]
        func add(_ warning: ActionExecutionWarning, at index: Int) { found[index, default: []].insert(warning) }

        // At or after the response the request is gone: a request-side action there neither runs on the wire nor ends anything.
        func isRequestSide(_ action: RuleAction) -> Bool { action.kind.direction == .request && !action.kind.isAnnotation }
        let requestSideIsRecordOnly = point >= .response

        var ended = false
        var seenResponseAction = false
        var manualResponses = 0
        for (index, action) in actions.enumerated() {
            if ended { add(.afterFinalAction, at: index) }
            if requestSideIsRecordOnly, isRequestSide(action) { add(.requestActionVisibleOnly, at: index) }
            if !requestSideIsRecordOnly, isRequestSide(action), seenResponseAction {
                add(.requestActionAfterResponseAction, at: index)
            }
            if action.kind.direction == .response { seenResponseAction = true }
            if case .returnHandwritten = action.kind {
                manualResponses += 1
                if manualResponses > 1 { add(.multipleManualResponses, at: index) }
            }
            if case .noDecrypt = action.kind, !rule.conditionsAllowNoDecrypt { add(.noDecryptNeedsSimpleConditions, at: index) }
            // A request-side action of a response-judged rule is skipped or recorded, never final.
            if action.isFinalEffective, !(requestSideIsRecordOnly && isRequestSide(action)) { ended = true }
        }
        // A Do Not Decrypt card that cannot work already says so (4); the "only visible here" line (1) would be noise.
        for (index, set) in found where set.contains(.noDecryptNeedsSimpleConditions) {
            found[index]?.remove(.requestActionVisibleOnly)
        }
        let order = ActionExecutionWarning.allCases
        return found.mapValues { set in order.filter(set.contains) }
    }
}

extension Rule {
    /// Whether every condition row is one a Do Not Decrypt rule can be judged on: all sessions, URL, host, scheme,
    /// client IP, or the process by name or without a key (spec 12.6 item 4).
    fileprivate var conditionsAllowNoDecrypt: Bool {
        conditions.rows.allSatisfy { row in
            switch row.field {
            case .allSessions, .url, .host, .scheme, .clientIP: true
            case .clientApp: (row.name ?? "").isEmpty
            default: false
            }
        }
    }
}
