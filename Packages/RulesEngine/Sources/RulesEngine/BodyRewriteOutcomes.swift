import FlowStore

extension RuleOutcomeCode {
    /// The find text did not occur in the body.
    public static let bodyNoMatch = RuleOutcomeCode(rawValue: "bodyNoMatch")!
    /// The body (or its decoded or rewritten text) is over the rewrite size limit; it went through unchanged.
    public static let bodySkippedTooLarge = RuleOutcomeCode(rawValue: "bodySkippedTooLarge")!
    /// The Content-Type is not text, or is a streaming type; the body went through unchanged.
    public static let bodySkippedNotText = RuleOutcomeCode(rawValue: "bodySkippedNotText")!
    /// Unknown or corrupt Content-Encoding, unsupported charset, invalid bytes, or a result the charset cannot hold.
    public static let bodySkippedUndecodable = RuleOutcomeCode(rawValue: "bodySkippedUndecodable")!
    /// A breakpoint owns the message, so automatic rewriting stood aside.
    public static let bodySkippedBreakpoint = RuleOutcomeCode(rawValue: "bodySkippedBreakpoint")!
    /// The message is answered locally (Map Local), so there is no origin body to rewrite.
    public static let bodySkippedLocalRoute = RuleOutcomeCode(rawValue: "bodySkippedLocalRoute")!
    /// The message has no body.
    public static let bodySkippedNoBody = RuleOutcomeCode(rawValue: "bodySkippedNoBody")!
    /// The body could not be collected (for example the size is unknown and the source was unreadable).
    public static let bodySkippedUnavailable = RuleOutcomeCode(rawValue: "bodySkippedUnavailable")!
    /// The rewrite memory budget was in use by other rewrites, so this body was not rewritten; the
    /// complete original went through unchanged.
    public static let bodySkippedBusy = RuleOutcomeCode(rawValue: "bodySkippedBusy")!
    /// The exchange ended (for example the client disconnected) before the rewrite finished, so
    /// nothing was forwarded.
    public static let bodySkippedAborted = RuleOutcomeCode(rawValue: "bodySkippedAborted")!
    /// A status rewrite was skipped because the response is local.
    public static let statusSkippedLocal = RuleOutcomeCode(rawValue: "statusSkippedLocal")!
}
