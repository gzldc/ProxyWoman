import FlowStore

extension RuleOutcomeCode {
    /// The rule's final action (Return File, or an action the user made final) ran: the rule's later
    /// actions and every lower-priority rule stay silent for this exchange. Always names the action.
    /// Recorded only when something was cut off.
    public static let finalStop = RuleOutcomeCode(rawValue: "finalStop")!
    /// The action did not run because an earlier action of the same rule was final. Always names the action.
    public static let skippedAfterFinal = RuleOutcomeCode(rawValue: "skippedAfterFinal")!
    /// The rule's conditions matched, but this hit is outside the rule's occurrence range, so none of
    /// its actions ran. About the whole rule, so it names no action.
    public static let occurrenceSkipped = RuleOutcomeCode(rawValue: "occurrenceSkipped")!
}
