import FlowStore
import Foundation

public struct NetworkProfile: Sendable, Equatable, Hashable, Codable {
    /// Kilobits per second, decimal. nil means unlimited.
    public var downloadKbps: Int?
    /// Kilobits per second, decimal. nil means unlimited.
    public var uploadKbps: Int?
    /// Added to each direction separately.
    public var latencyMs: Int
    /// Loss is simulated as retransmission delay; no bytes are dropped. 100 means offline.
    public var lossPercent: Double

    public init(downloadKbps: Int?, uploadKbps: Int?, latencyMs: Int, lossPercent: Double) {
        self.downloadKbps = downloadKbps
        self.uploadKbps = uploadKbps
        self.latencyMs = latencyMs
        self.lossPercent = lossPercent
    }

    public var isOffline: Bool { lossPercent >= 100 }

    public var problem: NetworkProfileProblem? {
        if let downloadKbps, !(1...1_000_000).contains(downloadKbps) { return .downloadOutOfRange }
        if let uploadKbps, !(1...1_000_000).contains(uploadKbps) { return .uploadOutOfRange }
        if !(0...10_000).contains(latencyMs) { return .latencyOutOfRange }
        if !(0.0...100.0).contains(lossPercent) { return .lossOutOfRange }
        return nil
    }

    private enum CodingKeys: String, CodingKey { case downloadKbps, uploadKbps, latencyMs, lossPercent }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        downloadKbps = try container.decodeIfPresent(Int.self, forKey: .downloadKbps)
        uploadKbps = try container.decodeIfPresent(Int.self, forKey: .uploadKbps)
        latencyMs = try container.decodeIfPresent(Int.self, forKey: .latencyMs) ?? 0
        lossPercent = try container.decodeIfPresent(Double.self, forKey: .lossPercent) ?? 0
    }
}

public enum NetworkProfileProblem: String, Sendable, Equatable {
    case downloadOutOfRange, uploadOutOfRange, latencyOutOfRange, lossOutOfRange
}

public enum NetworkPreset: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case offline, veryBad, slow, medium, edge, threeG, lte, wifi, wifiAC

    /// Fixed representative values (spec 5.3). Latency is per direction. Offline has no bandwidth
    /// or latency, so it uses unlimited bandwidth and zero latency.
    public var profile: NetworkProfile {
        switch self {
        case .offline: NetworkProfile(downloadKbps: nil, uploadKbps: nil, latencyMs: 0, lossPercent: 100)
        case .veryBad: NetworkProfile(downloadKbps: 500, uploadKbps: 500, latencyMs: 500, lossPercent: 10)
        case .slow: NetworkProfile(downloadKbps: 5000, uploadKbps: 5000, latencyMs: 100, lossPercent: 1)
        case .medium: NetworkProfile(downloadKbps: 10000, uploadKbps: 10000, latencyMs: 50, lossPercent: 0)
        case .edge: NetworkProfile(downloadKbps: 240, uploadKbps: 200, latencyMs: 400, lossPercent: 0)
        case .threeG: NetworkProfile(downloadKbps: 780, uploadKbps: 300, latencyMs: 100, lossPercent: 0)
        case .lte: NetworkProfile(downloadKbps: 40000, uploadKbps: 8000, latencyMs: 50, lossPercent: 0)
        case .wifi: NetworkProfile(downloadKbps: 30000, uploadKbps: 20000, latencyMs: 10, lossPercent: 0)
        case .wifiAC: NetworkProfile(downloadKbps: 200000, uploadKbps: 80000, latencyMs: 5, lossPercent: 0)
        }
    }
}

public enum NetworkSelection: Sendable, Equatable, Hashable, Codable {
    case preset(NetworkPreset)
    case custom(NetworkProfile)

    public var profile: NetworkProfile {
        switch self {
        case .preset(let preset): preset.profile
        case .custom(let profile): profile
        }
    }

    /// Machine-readable label: `preset.<case>` or `custom`.
    public var label: String {
        switch self {
        case .preset(let preset): "preset.\(preset.rawValue)"
        case .custom: "custom"
        }
    }
}

public struct HostNetworkRule: Sendable, Equatable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var enabled: Bool
    /// Exact host or `*.example.com`, with `HostPattern` semantics.
    public var hostPattern: String
    public var port: Int?
    public var selection: NetworkSelection

    public init(
        id: UUID = UUID(), enabled: Bool = true, hostPattern: String, port: Int? = nil, selection: NetworkSelection
    ) {
        self.id = id
        self.enabled = enabled
        self.hostPattern = hostPattern
        self.port = port
        self.selection = selection
    }
}

public struct ResolvedCondition: Sendable, Equatable {
    public var selection: NetworkSelection
    /// The host rule that matched; nil when the global selection applied.
    public var ruleID: UUID?

    public var profile: NetworkProfile { selection.profile }
    public var label: String { selection.label }
}

public struct NetworkConditions: Sendable, Equatable, Codable {
    public var enabled = false
    public var global: NetworkSelection?
    public var hostRules: [HostNetworkRule] = []

    public init() {}

    private enum CodingKeys: String, CodingKey { case enabled, global, hostRules }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        global = try container.decodeIfPresent(NetworkSelection.self, forKey: .global)
        hostRules = try container.decodeIfPresent([HostNetworkRule].self, forKey: .hostRules) ?? []
    }

    /// The first enabled host rule whose host (and port, if set) matches wins; otherwise the global
    /// selection applies. Returns nil when the master switch is off or nothing applies.
    public func resolve(host: String, port: Int) -> ResolvedCondition? {
        guard enabled else { return nil }
        let target = HTTPMessageTarget(scheme: "https", host: host, port: port, method: "GET", pathAndQuery: "/")
        if let rule = hostRules.first(where: { rule in
            rule.enabled
                && RuleMatcher(hostPattern: rule.hostPattern, port: rule.port).matches(target, status: nil)
        }) {
            return ResolvedCondition(selection: rule.selection, ruleID: rule.id)
        }
        return global.map { ResolvedCondition(selection: $0, ruleID: nil) }
    }

    public var isActive: Bool {
        enabled && (global != nil || hostRules.contains { $0.enabled })
    }
}
