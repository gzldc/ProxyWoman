import FlowStore
import Foundation

@testable import RulesEngine

/// Builders shared by the Execute tests.
enum ExecuteFixtures {
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    /// A finished exchange with `downstreamRequest` and `upstreamResponse` boundaries; the legacy fields are
    /// filled too. A nil `status` leaves the flow without a response.
    static func flow(
        _ id: Int = 1, method: String = "GET", host: String = "a.test", path: String = "/",
        requestHeaders: [HeaderField] = [], requestBody: Data? = nil, status: Int? = 200,
        responseHeaders: [HeaderField] = [], responseBody: Data? = nil, state: FlowState = .completed,
        comment: String? = nil
    ) -> Flow {
        var flow = Flow(id: id, startedAt: epoch, scheme: "https", method: method, host: host, port: 443, path: path)
        flow.state = state
        flow.comment = comment
        flow.requestHeaders = requestHeaders
        flow.requestBody = requestBody.map(BodyRef.memory)
        flow.statusCode = status
        flow.responseHeaders = responseHeaders
        flow.responseBody = responseBody.map(BodyRef.memory)
        if state != .inProgress { flow.completedAt = epoch.addingTimeInterval(0.25) }

        let target = HTTPMessageTarget(scheme: "https", host: host, port: 443, method: method, pathAndQuery: path)
        flow.messages[.downstreamRequest] = HTTPMessageSnapshot(
            boundary: .downstreamRequest, head: .request(target, headers: requestHeaders),
            body: requestBody.map { HTTPBodySlice(ref: .memory($0), offset: 0, count: $0.count) },
            bodyState: .complete, observedBytes: UInt64(requestBody?.count ?? 0), transferState: .finished)
        if let status {
            flow.messages[.upstreamResponse] = HTTPMessageSnapshot(
                boundary: .upstreamResponse, head: .response(status: status, reason: nil, headers: responseHeaders),
                body: responseBody.map { HTTPBodySlice(ref: .memory($0), offset: 0, count: $0.count) },
                bodyState: .complete, observedBytes: UInt64(responseBody?.count ?? 0), transferState: .finished)
        }
        return flow
    }

    /// A CONNECT tunnel row: no messages, no response.
    static func tunnel(_ id: Int, host: String) -> Flow {
        var flow = Flow(id: id, startedAt: epoch, scheme: "https", method: "CONNECT", host: host, port: 443, path: "")
        flow.state = .tunnel
        flow.completedAt = epoch.addingTimeInterval(0.1)
        return flow
    }

    static func rule(_ name: String, rows: [ConditionRow] = [], _ actions: ActionKind..., final: Bool = false) -> Rule {
        Rule(
            name: name, conditions: ConditionGroup(mode: .all, rows: rows),
            actions: actions.map { RuleAction($0, isFinal: final) })
    }

    static func snapshot(_ rules: Rule...) -> RuleSnapshot {
        var ordered = rules
        for index in ordered.indices { ordered[index].order = index }
        return RuleSnapshot(revision: 1, rules: ordered)
    }
}

extension ExecuteFixtures {
    /// An Execute environment over `assets` (a fresh, empty store when nil) whose bodies are plain memory. The
    /// fresh store's directory is never created: a store only makes it on import, and nothing imports into it.
    static func environment(assets: ManagedAssetStore? = nil, limits: RulesLimits = RulesLimits()) -> ExecuteEnvironment {
        let store = assets ?? ManagedAssetStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("pw-execute-\(UUID().uuidString)"),
            limits: limits, budgets: OwnedFileBudgets(limits: limits))
        return ExecuteEnvironment(
            assets: store, limits: limits, cache: PatternCache(budget: RegexBudget(clock: { .zero })),
            timeZone: TimeZone(identifier: "UTC")!, makeBody: { .memory($0) })
    }
}
