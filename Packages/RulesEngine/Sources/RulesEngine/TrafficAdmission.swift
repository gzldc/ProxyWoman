import FlowStore
import Foundation

/// What the proxy does with one request (or CONNECT) under the current `TrafficPolicy`.
public struct TrafficAdmission: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        case forward
        case block(entryID: UUID)
    }

    public var action: Action
    /// The exchange appears in the flow list.
    public var records: Bool
    /// Map Local/Remote, header edit and breakpoint rules run.
    public var appliesRules: Bool
    public var appliesNoCaching: Bool

    public init(action: Action, records: Bool, appliesRules: Bool, appliesNoCaching: Bool) {
        self.action = action
        self.records = records
        self.appliesRules = appliesRules
        self.appliesNoCaching = appliesNoCaching
    }

    /// The decision when every feature is off.
    public static let unchanged = TrafficAdmission(
        action: .forward, records: true, appliesRules: true, appliesNoCaching: false)
}

extension TrafficPolicy {
    /// Block beats an Allow miss, which beats the normal path. An explicit send (Compose, Repeat)
    /// ignores an Allow miss and the hide mode but is still blocked.
    public func admission(request target: HTTPMessageTarget, explicitSend: Bool) -> TrafficAdmission {
        decide(target, explicitSend: explicitSend, hostLevelBlockOnly: false)
    }

    /// CONNECT-level decision: only host/port block entries can stop a tunnel before its requests
    /// are seen.
    public func admission(connectHost host: String, port: Int) -> TrafficAdmission {
        let target = HTTPMessageTarget(scheme: "https", host: host, port: port, method: "CONNECT", pathAndQuery: "/")
        return decide(target, explicitSend: false, hostLevelBlockOnly: true)
    }

    private func decide(_ target: HTTPMessageTarget, explicitSend: Bool, hostLevelBlockOnly: Bool) -> TrafficAdmission {
        let blocked = blockActive
            ? blockEntries.first { entry in
                guard entry.enabled else { return false }
                if hostLevelBlockOnly {
                    let matcher = entry.matcher
                    guard matcher.method == nil, matcher.path == .any, matcher.statusRange == nil,
                        matcher.scheme.map({ $0.lowercased() == "https" }) ?? true
                    else { return false }
                }
                return entry.matcher.matches(target, status: nil)
            }
            : nil
        let allowed = !allowActive || explicitSend
            || allowEntries.contains { $0.enabled && $0.matcher.matches(target, status: nil) }
        if let blocked {
            return TrafficAdmission(
                action: .block(entryID: blocked.id), records: (blockMode == .show || explicitSend) && allowed,
                appliesRules: false, appliesNoCaching: false)
        }
        guard allowed else {
            return TrafficAdmission(action: .forward, records: false, appliesRules: false, appliesNoCaching: false)
        }
        return TrafficAdmission(action: .forward, records: true, appliesRules: true, appliesNoCaching: noCaching)
    }
}
