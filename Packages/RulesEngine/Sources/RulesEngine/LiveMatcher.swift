import FlowStore
import Foundation

/// What a live count found over the captured flows (D21).
public struct LiveMatchReport: Sendable, Equatable {
    public var matchedIDs: [Int]
    /// The flows looked at, including those that were skipped.
    public var scanned: Int
    /// Always 0 now: sessions in flight are judged on what has arrived (kept for the report's shape).
    public var skippedInProgress: Int
    /// Flows with a body the count could not read (on disk, over the cap or cut short); a body row of
    /// the conditions was unknown for them.
    public var skippedLargeBodies: Int

    /// The two skips together (the "跳过 K 条" of the result sentence).
    public var skipped: Int { skippedInProgress + skippedLargeBodies }

    public init(matchedIDs: [Int] = [], scanned: Int = 0, skippedInProgress: Int = 0, skippedLargeBodies: Int = 0) {
        self.matchedIDs = matchedIDs
        self.scanned = scanned
        self.skippedInProgress = skippedInProgress
        self.skippedLargeBodies = skippedLargeBodies
    }
}

/// Counts the captured flows a condition group would have matched (spec §6.2, D21). It runs the same
/// `ConditionEvaluator` as live traffic over the original messages of each finished flow, so it says what a
/// rule would select, not what earlier rules left of it. Synchronous and pure; the caller keeps it off the
/// main actor and cancels it through `isCancelled`.
public enum LiveMatcher {
    /// How many flows are judged between two looks at `isCancelled`.
    static let cancellationStride = 64

    /// `flows` are already `recentFlows` (hidden ones excluded). Tunnels are not judged (no rule sees one
    /// before R4, D18); `occurrence` is ignored. A flow whose regular expression runs out of time does not match.
    /// `openWebSocketFlowIDs` are flows whose upgraded WebSocket session is still open: their 101 exchange is over
    /// but the session is not, so they read as unfinished (state "opened"; duration and response size unknown).
    public static func evaluate(
        _ conditions: ConditionGroup, over flows: [Flow], facts timeZone: TimeZone = .current,
        limits: RulesLimits = RulesLimits(), cache: PatternCache = PatternCache(),
        openWebSocketFlowIDs: Set<Int> = [],
        isCancelled: @Sendable () -> Bool = { false }
    ) -> LiveMatchReport {
        var report = LiveMatchReport()
        let needs = BodyNeeds(conditions)
        for (index, flow) in flows.enumerated() {
            if index > 0, index % cancellationStride == 0, isCancelled() { break }
            report.scanned += 1
            if flow.state == .tunnel { continue }
            guard let prepared = input(
                for: flow, needs: needs, timeZone: timeZone, limits: limits,
                webSocketOpen: openWebSocketFlowIDs.contains(flow.id))
            else {
                report.skippedInProgress += 1
                continue
            }
            if prepared.skippedLargeBody { report.skippedLargeBodies += 1 }
            let verdict = ConditionEvaluator.evaluate(
                conditions, prepared.input, allowance: RegexAllowance(), cache: cache, limits: limits)
            if verdict.result == .matched { report.matchedIDs.append(flow.id) }
        }
        return report
    }

    /// Which bodies the conditions read; a body nobody reads is never loaded.
    struct BodyNeeds {
        var request = false
        var response = false

        init(_ conditions: ConditionGroup) {
            request = conditions.rows.contains { $0.field == .requestBody }
            response = conditions.rows.contains { $0.field == .responseBody }
        }
    }

    struct Prepared {
        var input: ConditionInput
        /// A body the conditions read was on disk, over the cap or cut short.
        var skippedLargeBody: Bool
    }

    /// One flow as the condition evaluator reads it: the client's original request and the origin's original
    /// response (D21), the legacy projection for flows recorded without boundaries. A session still in flight is
    /// judged on what has arrived: rows needing the rest (status, bodies, duration) are unknown, so they do not match.
    /// Only what is in memory is read (D21): a spilled body is `bodySkippedOnDisk`.
    static func input(
        for flow: Flow, needs: BodyNeeds, timeZone: TimeZone, limits: RulesLimits, webSocketOpen: Bool = false
    ) -> Prepared? {
        var originals = FlowOriginals.inFlight(flow, timeZone: timeZone)
        // The HTTP exchange of an upgrade ends with the 101; the session it opened is what is still going.
        if webSocketOpen { originals.isFinished = false }
        guard let target = originals.request.target else { return nil }
        var requestBody = BodyPeek.notCollected
        var responseBody = BodyPeek.notCollected
        if needs.request {
            requestBody = originals.request.body.peek(headers: originals.request.headers, allowDisk: false, limits: limits)
        }
        if needs.response, let response = originals.response {
            responseBody = response.body.peek(headers: response.headers, allowDisk: false, limits: limits)
        }
        var skipped = false
        for peek in [requestBody, responseBody] {
            if case .skipped(let code) = peek,
               code == .bodySkippedOnDisk || code == .bodyTooLarge
                || (code == .bodySkippedStreaming && originals.isFinished) { skipped = true }
        }
        var response: (status: Int, headers: [HeaderField])?
        if let message = originals.response, let status = message.status { response = (status, message.headers) }
        let input = ConditionInput(
            target: target, requestHeaders: originals.request.headers, response: response, facts: originals.facts,
            completion: originals.isFinished ? originals.completion : nil, requestBody: requestBody, responseBody: responseBody)
        return Prepared(input: input, skippedLargeBody: skipped)
    }
}
