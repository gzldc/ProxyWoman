import FlowStore
import Foundation

extension Rule {
    /// Whether the CONNECT point (P0) evaluates the rule: it is judged there and has an action that can
    /// run there (D11). `SnapshotRequirements.connect` uses the same test.
    var runsAtConnect: Bool {
        conditions.judgmentPoint == .connect && actions.contains { $0.kind.canRunAtConnect }
    }

    /// Every action runs only at the CONNECT point: the request, response and completion points do not
    /// judge the rule at all (no hit, no occurrence, no condition problems).
    var isConnectOnlyRule: Bool {
        !actions.isEmpty && actions.allSatisfy { $0.kind.isConnectOnly }
    }
}

extension RuleEvaluator {
    /// The CONNECT point (P0, spec 5.5.2): runs once per CONNECT line the tools let through to the rules,
    /// before the proxy decrypts or tunnels it. Only rules judged at the CONNECT that have an action able to
    /// run there are evaluated, and only those actions run (the rest neither runs nor records anything).
    /// Their rows read `target` (scheme, host, port, method `CONNECT`, no path) and `facts`; nothing
    /// else is known.
    ///
    /// Closing the connection, not decrypting and returning the CONNECT tunnel are final, as are a hide
    /// and an action the user made final: nothing after them runs here. When the tools already chose a
    /// tunnel, not decrypting and returning the tunnel are `skippedByTool` and stop nothing (D12).
    /// `hits` counts the CONNECT point's hits apart from the request point's (`recordConnectHit`), and a
    /// rule whose every action the tool skipped is no hit; `allowance` is the exchange's
    /// regular-expression time.
    public static func connect(
        target: HTTPMessageTarget, snapshot: RuleSnapshot, tool: ConnectToolDecision, hits: RuleHitCounter? = nil,
        facts: ExchangeFacts = ExchangeFacts(), allowance: RegexAllowance = RegexAllowance(),
        limits: RulesLimits = RulesLimits(), cache: PatternCache = .shared
    ) -> ConnectRuleDecision {
        let rules = snapshot.evaluationOrder
        // The last rule this point can cut; a stop is recorded only when it cut something (R1 D8).
        let lastPosition = rules.lastIndex(where: \.runsAtConnect) ?? -1
        var run = ConnectRun(tool: tool, facts: facts, lastPosition: lastPosition)
        for (position, rule) in rules.enumerated() {
            guard run.finalStop == nil else { break }
            guard rule.runsAtConnect else { continue }
            let verdict = judge(rule, allowance: allowance, cache: cache, limits: limits) {
                ConditionInput(target: target, facts: run.currentFacts)
            }
            run.problems += verdict.problems
            guard verdict.matched else { continue }
            // A rule the tools leave nothing to do (every action skipped by the tool) is not a hit.
            let indices = rule.actions.indices.filter { rule.actions[$0].kind.canRunAtConnect }
            let skippedByTool = tool == .tunnel && indices.allSatisfy { rule.actions[$0].kind.isConnectOnly }
            guard skippedByTool || connectOccurs(rule, hits: hits, position: position, log: &run.log) else {
                continue
            }
            run.perform(rule, at: position, indices: indices)
        }
        return ConnectRuleDecision(
            disposition: run.disposition,
            matches: run.log.summary(revision: snapshot.revision, problems: run.problems),
            annotations: run.annotations, finalStop: run.finalStop)
    }

    /// `occurs` on the CONNECT point's own hit count (R4 T7 ruling): a CONNECT never shifts a rule's
    /// occurrence window at the requests inside it.
    private static func connectOccurs(_ rule: Rule, hits: RuleHitCounter?, position: Int, log: inout OutcomeLog)
        -> Bool
    {
        guard let hits else { return true }
        let count = hits.recordConnectHit(rule.id)
        guard case .times(let range) = rule.conditions.occurrence, !range.contains(count) else { return true }
        log.record(RuleOutcome(ruleID: rule.id, code: .occurrenceSkipped), at: position)
        return false
    }

    /// The CONNECT point at work. A thin copy of the final-action and annotation parts of
    /// `PointRun.perform`; it has no headers, body, route or modification to keep.
    private struct ConnectRun {
        let tool: ConnectToolDecision
        let enteringFacts: ExchangeFacts
        let lastPosition: Int
        var log = OutcomeLog()
        var problems: [RuleOutcome] = []
        var annotations: [FlowAnnotation] = []
        var currentComment: String?
        var finalStop: RuleCarry.FinalStop?
        var disposition = ConnectRuleDecision.Disposition.proceed

        init(tool: ConnectToolDecision, facts: ExchangeFacts, lastPosition: Int) {
            self.tool = tool
            self.enteringFacts = facts
            self.lastPosition = lastPosition
            self.currentComment = facts.comment
        }

        /// The facts the next rule reads: the comment as the rules above left it.
        var currentFacts: ExchangeFacts {
            var facts = enteringFacts
            facts.comment = currentComment
            return facts
        }

        /// Runs the rule's actions at `indices` (those that can run at the CONNECT), in order, and records
        /// an outcome for each.
        mutating func perform(_ rule: Rule, at position: Int, indices: [Int]) {
            let labelled = rule.actions.count > 1
            for (offset, index) in indices.enumerated() {
                let action = rule.actions[index]
                let label = labelled ? index : nil
                if finalStop != nil {
                    log.record(RuleOutcome(ruleID: rule.id, code: .skippedAfterFinal, actionIndex: index), at: position)
                    continue
                }
                var code = RuleOutcomeCode.applied
                switch action.kind {
                case .mark(let mark):
                    // "Unchanged" carries no colour and "default" clears one (above): the action still counts (its outcome
                    // and its stop tick). A colour that is not valid (only a snapshot that skipped validation has one)
                    // is skipped as a whole.
                    if let flowMark = mark.flowMark(ruleID: rule.id, ruleName: rule.name) {
                        annotations.append(.mark(flowMark))
                    } else if let reset = mark.colorReset {
                        // "Default" is the one colour that does something without being a colour: it clears.
                        annotations.append(.resetMark(background: reset.background, foreground: reset.foreground))
                    } else if !MarkAction.isNoColorChoice(mark.background) {
                        continue
                    }
                case .comment(let comment):
                    if MagicStringAction.isInert(comment) { break }
                    annotations.append(.comment(comment))
                    currentComment = comment.applying(to: currentComment)
                case .hide:
                    annotations.append(.hide)
                case .closeConnection(let mode):
                    disposition = .close(mode, ruleID: rule.id)
                case .noDecrypt:
                    if tool == .tunnel { code = .skippedByTool } else { disposition = .noDecrypt }
                case .returnConnectTunnel:
                    // Decryption goes on as the tools decided; the action only cuts the rules below it.
                    if tool == .tunnel { code = .skippedByTool }
                case .returnFile, .returnDirectory, .mapRemote, .editHeaders, .breakpoint, .rewriteBody, .rewriteStatus,
                    .modifyURL, .modifyQuery, .editCookies, .delay, .returnHandwritten, .returnPreset, .magicString:
                    assertionFailure("only actions that can run at the CONNECT reach here")
                    continue
                }
                log.record(RuleOutcome(ruleID: rule.id, code: code, actionIndex: label), at: position)
                if action.isFinalEffective, code == .applied {
                    finalStop = RuleCarry.FinalStop(position: position, actionIndex: index)
                    if offset < indices.count - 1 || position < lastPosition {
                        log.record(RuleOutcome(ruleID: rule.id, code: .finalStop, actionIndex: index), at: position)
                    }
                }
            }
        }
    }
}
