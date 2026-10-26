import FlowStore
import Foundation

public struct TrafficFilterEntry: Sendable, Equatable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var enabled: Bool
    public var matcher: RuleMatcher

    public init(id: UUID = UUID(), enabled: Bool = true, matcher: RuleMatcher) {
        self.id = id
        self.enabled = enabled
        self.matcher = matcher
    }
}

public enum BlockDisplayMode: String, Sendable, Equatable, Codable, CaseIterable {
    case show, hide
}

/// A typed policy failure. `index` is the entry's position in `list`; nil for list-level failures.
public struct TrafficPolicyError: Error, Equatable, Sendable {
    public enum List: Sendable, Equatable { case allow, block, hostRules, global }
    public enum Code: String, Sendable, Equatable {
        case invalidHostPattern, invalidPort, invalidMethod, invalidPath, invalidScheme
        case unsupportedField, tooManyEntries, invalidProfile, duplicateID
        /// A wildcard or regular expression that is invalid or too complex.
        case invalidPattern
    }

    public var list: List
    public var index: Int?
    public var code: Code

    public init(list: List, index: Int?, code: Code) {
        self.list = list
        self.index = index
        self.code = code
    }
}

/// Everything the Allow list, Block list, No Caching and Network Conditions tools need at runtime.
/// With every feature off or empty `affectsExchanges` is false and the proxy takes its original path.
public struct TrafficPolicy: Sendable, Equatable, Codable {
    public static let maxEntries = 256

    public var allowEnabled = false
    public var allowEntries: [TrafficFilterEntry] = []
    public var blockEnabled = false
    public var blockMode: BlockDisplayMode = .show
    public var blockEntries: [TrafficFilterEntry] = []
    public var noCaching = false
    public var conditions = NetworkConditions()

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case allowEnabled, allowEntries, blockEnabled, blockMode, blockEntries, noCaching, conditions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        allowEnabled = try container.decodeIfPresent(Bool.self, forKey: .allowEnabled) ?? false
        allowEntries = try container.decodeIfPresent([TrafficFilterEntry].self, forKey: .allowEntries) ?? []
        blockEnabled = try container.decodeIfPresent(Bool.self, forKey: .blockEnabled) ?? false
        blockMode = try container.decodeIfPresent(BlockDisplayMode.self, forKey: .blockMode) ?? .show
        blockEntries = try container.decodeIfPresent([TrafficFilterEntry].self, forKey: .blockEntries) ?? []
        noCaching = try container.decodeIfPresent(Bool.self, forKey: .noCaching) ?? false
        conditions = try container.decodeIfPresent(NetworkConditions.self, forKey: .conditions) ?? NetworkConditions()
    }

    /// Switched on with at least one enabled entry.
    public var allowActive: Bool { allowEnabled && allowEntries.contains { $0.enabled } }
    public var blockActive: Bool { blockEnabled && blockEntries.contains { $0.enabled } }
    public var affectsExchanges: Bool { allowActive || blockActive || noCaching }

    public func validate() throws {
        var seen = Set<UUID>()
        func checkID(_ id: UUID, _ list: TrafficPolicyError.List, _ index: Int) throws {
            guard seen.insert(id).inserted else {
                throw TrafficPolicyError(list: list, index: index, code: .duplicateID)
            }
        }
        try Self.validate(allowEntries, list: .allow, checkID: checkID)
        try Self.validate(blockEntries, list: .block, checkID: checkID)

        if let global = conditions.global, global.profile.problem != nil {
            throw TrafficPolicyError(list: .global, index: nil, code: .invalidProfile)
        }
        guard conditions.hostRules.count <= Self.maxEntries else {
            throw TrafficPolicyError(list: .hostRules, index: nil, code: .tooManyEntries)
        }
        for (index, rule) in conditions.hostRules.enumerated() {
            try checkID(rule.id, .hostRules, index)
            func fail(_ code: TrafficPolicyError.Code) -> TrafficPolicyError {
                TrafficPolicyError(list: .hostRules, index: index, code: code)
            }
            guard rule.hostPattern.utf8.count <= RulesLimits().fieldBytes,
                HostPattern.normalizedUserPattern(rule.hostPattern) != nil
            else { throw fail(.invalidHostPattern) }
            if let port = rule.port, !(1...65_535).contains(port) { throw fail(.invalidPort) }
            if rule.selection.profile.problem != nil { throw fail(.invalidProfile) }
        }
    }

    private static func validate(
        _ entries: [TrafficFilterEntry], list: TrafficPolicyError.List,
        checkID: (UUID, TrafficPolicyError.List, Int) throws -> Void
    ) throws {
        guard entries.count <= maxEntries else {
            throw TrafficPolicyError(list: list, index: nil, code: .tooManyEntries)
        }
        for (index, entry) in entries.enumerated() {
            try checkID(entry.id, list, index)
            let matcher = entry.matcher
            func fail(_ code: TrafficPolicyError.Code) -> TrafficPolicyError {
                TrafficPolicyError(list: list, index: index, code: code)
            }
            if matcher.statusRange != nil { throw fail(.unsupportedField) }
            if list == .allow, matcher.scheme != nil || matcher.method != nil || matcher.path != .any {
                throw fail(.unsupportedField)
            }
            do {
                try matcher.validate()
            } catch let error as RuleValidationError {
                throw fail(code(for: error))
            }
        }
    }

    private static func code(for error: RuleValidationError) -> TrafficPolicyError.Code {
        switch error.code {
        case .invalidScheme: .invalidScheme
        case .invalidHostPattern: .invalidHostPattern
        case .invalidPort: .invalidPort
        case .invalidMethod: .invalidMethod
        case .invalidPath: .invalidPath
        case .invalidWildcard, .invalidRegex, .regexTooComplex: .invalidPattern
        case .fieldTooLong:
            switch error.field {
            case .method: .invalidMethod
            case .path: .invalidPath
            case .scheme: .invalidScheme
            default: .invalidHostPattern
            }
        default: .unsupportedField
        }
    }
}
