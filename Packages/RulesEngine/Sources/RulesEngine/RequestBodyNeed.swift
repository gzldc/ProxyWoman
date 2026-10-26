import FlowStore
import Foundation

extension RuleEvaluator {
    /// The request-body pre-pass (D12, T11 review I1): whether any rule that reads the request body
    /// could match this request, judged on its head alone. Only then is the body held for a peek; any
    /// other request streams exactly as without such rules.
    ///
    /// Each enabled rule with a request-body row (judged at any point: a later point reads the body the
    /// request point peeked) is asked `ConditionEvaluator.mayMatch` on the original head and `facts`.
    /// Rows the head cannot answer count as possibly true. A rule above it that may match and could change
    /// what request rows read (header edits, Map Remote, Return File / Directory, a comment) makes every
    /// body rule below it count as possible. Occurrence ranges and final actions are ignored, which only
    /// errs towards true.
    public static func requestMayNeedBody(
        _ original: HTTPMessageHead, snapshot: RuleSnapshot, facts: ExchangeFacts, cache: PatternCache = .shared
    ) -> Bool {
        guard case .request(let target, let headers) = original else { return false }
        let input = ConditionInput(target: target, requestHeaders: headers, facts: facts)
        var changed = false
        for rule in snapshot.evaluationOrder {
            if rule.conditions.rows.contains(where: { $0.field == .requestBody }) {
                if changed || ConditionEvaluator.mayMatch(rule.conditions, input, cache: cache) { return true }
            } else if !changed, changesRequestReads(rule) || modifiesMessage(rule),
                      ConditionEvaluator.mayMatch(rule.conditions, input, cache: cache) {
                changed = true
            }
        }
        return false
    }

    /// Actions that change what a later row reads, whatever the rule's judgment point (the change carries to
    /// every later point): those that set the "rules modified" fact when applied (`PointRun.perform`: header
    /// edits of either direction, the routing actions and a status rewrite) and a comment, which a later
    /// `comment` row reads. A rule above that may match makes every body rule below it possible.
    private static func modifiesMessage(_ rule: Rule) -> Bool {
        rule.actions.contains { action in
            switch action.kind {
            case .editHeaders, .returnFile, .returnDirectory, .mapRemote, .rewriteStatus, .comment: true
            default: false
            }
        }
    }

    /// A request-point rule whose actions change what later request rows read.
    private static func changesRequestReads(_ rule: Rule) -> Bool {
        guard rule.conditions.judgmentPoint < .response else { return false }
        return rule.actions.contains { action in
            switch action.kind {
            case .editHeaders(let direction, _): direction == .request
            case .mapRemote, .returnFile, .returnDirectory, .comment: true
            default: false
            }
        }
    }

    /// The response-body pre-pass (T12): whether any rule that reads the response body could match
    /// this response, judged on its head, the request as the request point left it and `facts`. Only
    /// then is the response held for a peek. Like `requestMayNeedBody`: rows the head cannot answer
    /// (body, regular-expression and completion rows) count as possibly true, and a rule above that
    /// may match and could change what response rows read (a response header edit, a status rewrite, a
    /// comment, or any request-point rule with response-side actions pending) makes every body rule
    /// below it possible. A request decision of another snapshot answers false: the evaluator itself
    /// then runs nothing.
    public static func responseMayNeedBody(
        _ original: HTTPMessageHead, after request: RequestRuleDecision, snapshot: RuleSnapshot, facts: ExchangeFacts,
        cache: PatternCache = .shared
    ) -> Bool {
        guard case .response(let status, _, let headers) = original else { return false }
        let rules = snapshot.evaluationOrder
        guard let carry = carry(of: request, revision: snapshot.revision, rules: rules) else { return false }
        // As the evaluator enters the response point: what the request point modified counts.
        var facts = facts
        facts.rulesModified = facts.rulesModified || request.rulesModified
        let input = ConditionInput(
            target: carry.target, requestHeaders: carry.requestHeaders, response: (status, headers), facts: facts,
            requestBody: carry.requestBody)
        let pending = Set(carry.pending.map(\.position))
        var changed = false
        for (position, rule) in rules.enumerated() {
            if rule.conditions.rows.contains(where: { $0.field == .responseBody }) {
                if changed || ConditionEvaluator.mayMatch(rule.conditions, input, cache: cache, through: .response) { return true }
            } else if !changed {
                changed = pending.contains(position)
                    || ((changesResponseReads(rule) || modifiesMessage(rule))
                        && ConditionEvaluator.mayMatch(rule.conditions, input, cache: cache, through: .response))
            }
        }
        return false
    }

    /// A response-point rule whose actions change what later response rows read.
    private static func changesResponseReads(_ rule: Rule) -> Bool {
        guard rule.conditions.judgmentPoint == .response else { return false }
        return rule.actions.contains { action in
            switch action.kind {
            case .editHeaders(let direction, _): direction == .response
            case .rewriteStatus, .comment: true
            default: false
            }
        }
    }
}
