import FlowStore
import Foundation

extension RuleOutcomeCode {
    /// A request-side action of a rule judged at the response was applied to the recorded request only; the
    /// request that went to the origin is unchanged (spec R8F2-6).
    public static let requestActionVisibleOnly = RuleOutcomeCode(rawValue: "requestActionVisibleOnly")!
    /// A request-side action of a rule judged at the response cannot act on a record (breakpoint, tunnel, map remote,
    /// directory, body rewrite) and was skipped. Return File / manual / predefined response, close and delay are not
    /// among them: they run at the response point itself (`ResponseRuleDecision.replacement`).
    public static let requestActionSkippedAtResponse = RuleOutcomeCode(rawValue: "requestActionSkippedAtResponse")!
}

/// One request-side action of a rule judged at the response, to be applied to the recorded request.
public struct RecordedRequestAction: Sendable, Equatable {
    public var ruleID: UUID
    /// Position of the action in its rule.
    public var actionIndex: Int
    public var kind: ActionKind

    public init(ruleID: UUID, actionIndex: Int, kind: ActionKind) {
        self.ruleID = ruleID
        self.actionIndex = actionIndex
        self.kind = kind
    }
}

/// Request-side actions of a response-judged rule act on the recorded copy of the request (what the session list
/// and inspector show), never on the bytes already sent upstream. Pure, so live traffic and Execute share it.
public enum RecordedRequestEditing {
    /// Whether the action can change a recorded request: header, cookie, URL and query edits. A body rewrite is
    /// not applied to a record (the captured request body is a finished stream), nor is anything that needs the
    /// connection: breakpoint, map remote, directory, tunnel. Return, close and delay are not request-side here at all.
    public static func appliesToRecord(_ kind: ActionKind) -> Bool {
        switch kind {
        case .editHeaders(.request, _), .editCookies(.request, _), .modifyURL, .modifyQuery: true
        default: false
        }
    }

    /// `head` (a request) with `actions` applied in order. An edit that cannot be carried out (a regular-expression
    /// problem, a result that is not a valid target) leaves the record as it was. Header edits are not checked
    /// against the protected headers: nothing is sent.
    public static func apply(
        _ actions: [RecordedRequestAction], to head: HTTPMessageHead, allowance: RegexAllowance = RegexAllowance(),
        cache: PatternCache = .shared, limits: RulesLimits = RulesLimits()
    ) -> HTTPMessageHead {
        guard case .request(var target, var headers) = head, !actions.isEmpty else { return head }
        let context = EditContext(allowance: allowance, cache: cache, limits: limits)
        for action in actions {
            switch action.kind {
            case .editHeaders(.request, let operations):
                headers = headers.applying(operations, allowance: allowance, cache: cache).headers
            case .editCookies(.request, let operations):
                headers = CookieEditing.applyToRequest(operations, headers: headers, allowance: allowance, cache: cache)
                    .headers
            case .modifyURL, .modifyQuery:
                if case .moved(let remote)? = try? RuleEvaluator.editedTarget(action.kind, from: target, context) {
                    target = remote.target(applyingTo: target)
                }
            default:
                continue
            }
        }
        return .request(target, headers: headers)
    }
}
