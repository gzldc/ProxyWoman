import Foundation

/// Which asynchronous facts the enabled rules of a snapshot need before they can be judged.
public struct SnapshotRequirements: Sendable, Equatable {
    public var requestBody = false
    public var responseBody = false
    public var clientApp = false
    public var completion = false
    /// An enabled rule runs at the CONNECT point (`Rule.runsAtConnect`).
    public var connect = false
    /// A rule that runs at the CONNECT point reads the client app, so the CONNECT waits for it (D13).
    public var connectClientApp = false
    public var isEmpty: Bool { !requestBody && !responseBody && !clientApp && !completion && !connect }
}

extension RuleSnapshot {
    /// Whether an enabled rule needs an asynchronous fact: only worked out once, and kept on the
    /// snapshot value, like `evaluationOrder`.
    public var requirements: SnapshotRequirements {
        orderCache.requirements {
            var result = SnapshotRequirements()
            for rule in evaluationOrder {
                if rule.runsAtConnect {
                    result.connect = true
                    if rule.conditions.rows.contains(where: { $0.field == .clientApp }) { result.connectClientApp = true }
                }
                // A rule of connect-only actions is judged at the CONNECT point alone.
                if rule.isConnectOnlyRule { continue }
                for row in rule.conditions.rows {
                    switch row.field {
                    case .requestBody: result.requestBody = true
                    case .responseBody: result.responseBody = true
                    case .clientApp: result.clientApp = true
                    default: break
                    }
                }
                if rule.conditions.judgmentPoint == .completion { result.completion = true }
            }
            return result
        }
    }
}
