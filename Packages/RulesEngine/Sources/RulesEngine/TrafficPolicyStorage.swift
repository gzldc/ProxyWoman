import Foundation

/// How the traffic policy is stored in the settings so that an older build cannot lose entries.
///
/// An older build decodes the policy leniently: it ignores `hostSyntax`, reads a wildcard or regular
/// expression as a literal host, and when that fails to validate it falls back to the default
/// policy and later writes that default over everything. So the main value (the legacy key) only
/// ever holds what an older build understands: the policy without its wildcard and regular
/// expression entries. The whole policy lives in a second value (the extended key) that an older
/// build never reads or writes, wrapped with a `schemaVersion` so a future build can tell its own
/// data from ours.
///
/// Loading prefers the extended value. If something else changed the legacy value since (an older
/// build ran), its edits are kept and the advanced entries are added back; if the legacy value was
/// reset, the extended value wins whole. An extended value from a newer schema is never used
/// and never overwritten (`keepsExtended`).
public enum TrafficPolicyStorage {
    public static let schemaVersion = 2

    public struct Loaded: Sendable, Equatable {
        public var policy: TrafficPolicy
        /// The extended value is from a newer schema: leave it alone when saving.
        public var keepsExtended: Bool

        public init(policy: TrafficPolicy, keepsExtended: Bool) {
            self.policy = policy
            self.keepsExtended = keepsExtended
        }
    }

    public struct Encoded: Sendable, Equatable {
        /// The value for the legacy key: byte for byte what a build without advanced entries writes.
        public var legacy: Data?
        /// The value for the extended key; nil (remove the key) when no entry is advanced.
        public var extended: Data?
    }

    private struct Wrapper: Codable {
        var schemaVersion: Int
        var policy: TrafficPolicy
    }

    private struct VersionOnly: Decodable {
        var schemaVersion: Int
    }

    public static func encode(_ policy: TrafficPolicy) -> Encoded {
        let legacy = try? JSONEncoder().encode(policy.literalSubset)
        guard policy.hasAdvancedEntries else { return Encoded(legacy: legacy, extended: nil) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let extended = try? encoder.encode(Wrapper(schemaVersion: schemaVersion, policy: policy))
        return Encoded(legacy: legacy, extended: extended)
    }

    public static func load(legacy: Data?, extended: Data?) -> Loaded {
        let legacyPolicy = legacy.flatMap(readValid)
        guard let extended else { return Loaded(policy: legacyPolicy ?? TrafficPolicy(), keepsExtended: false) }
        if let version = try? JSONDecoder().decode(VersionOnly.self, from: extended), version.schemaVersion > schemaVersion {
            return Loaded(policy: legacyPolicy ?? TrafficPolicy(), keepsExtended: true)
        }
        guard let wrapper = try? JSONDecoder().decode(Wrapper.self, from: extended),
            wrapper.schemaVersion >= 1, (try? wrapper.policy.validate()) != nil
        else { return Loaded(policy: legacyPolicy ?? TrafficPolicy(), keepsExtended: false) }
        let full = wrapper.policy
        guard let legacyPolicy, legacyPolicy != TrafficPolicy() else { return Loaded(policy: full, keepsExtended: false) }
        if legacyPolicy == full.literalSubset { return Loaded(policy: full, keepsExtended: false) }
        // An older build edited the legacy value: keep its edits and add the advanced entries back.
        var merged = legacyPolicy
        merged.allowEntries += full.allowEntries.filter { $0.matcher.usesAdvancedSyntax }
        merged.blockEntries += full.blockEntries.filter { $0.matcher.usesAdvancedSyntax }
        guard (try? merged.validate()) != nil else { return Loaded(policy: legacyPolicy, keepsExtended: false) }
        return Loaded(policy: merged, keepsExtended: false)
    }

    private static func readValid(_ data: Data) -> TrafficPolicy? {
        guard let policy = try? JSONDecoder().decode(TrafficPolicy.self, from: data),
            (try? policy.validate()) != nil
        else { return nil }
        return policy
    }
}

extension TrafficPolicy {
    /// True when an Allow or Block entry uses wildcard or regular-expression syntax.
    public var hasAdvancedEntries: Bool {
        allowEntries.contains { $0.matcher.usesAdvancedSyntax } || blockEntries.contains { $0.matcher.usesAdvancedSyntax }
    }

    /// The policy without its advanced entries: what an older build can read.
    public var literalSubset: TrafficPolicy {
        var subset = self
        subset.allowEntries = allowEntries.filter { !$0.matcher.usesAdvancedSyntax }
        subset.blockEntries = blockEntries.filter { !$0.matcher.usesAdvancedSyntax }
        return subset
    }
}
