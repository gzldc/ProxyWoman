import Foundation
import os

/// The shapes of `rules.json` (spec 5.1, 5.6.1). Every save writes schema 4; schemas 1…3 are only read,
/// to be migrated. Pure: the repository does the file I/O and runs this on its file runner.
enum RuleStorage {
    static let currentSchema = 4
    /// Schema 1: literal matchers only. Schema 2 adds wildcard/regex matchers and directory maps.
    /// Schema 3 adds body and status rewrites.
    static let legacySchemas: ClosedRange<Int> = 1...3

    /// A schema 4 file: `{schemaVersion, revision, groups, rules, assets, templatesInstalled,
    /// migrationNotice}`, keys sorted, `migrationNotice` only when there is one.
    struct Configuration: Codable, Equatable, Sendable {
        var schemaVersion: Int
        var revision: UInt64
        var groups: [RuleGroup]
        var rules: [Rule]
        /// The managed copies the Return File actions reference (records, so a restart can adopt them
        /// before the orphan sweep).
        var assets: [ManagedAsset]
        var templatesInstalled: Bool
        var migrationNotice: MigrationNotice?
        /// Optional, and left out of the file while nil, so a file that never had them keeps its bytes.
        var templatesVersion: Int?
        var templatesGroupID: UUID?

        init(snapshot: RuleSnapshot, assets: [ManagedAsset]) {
            schemaVersion = RuleStorage.currentSchema
            revision = snapshot.revision
            groups = snapshot.groups
            rules = snapshot.rules
            self.assets = assets
            templatesInstalled = snapshot.templatesInstalled
            migrationNotice = snapshot.migrationNotice
            templatesVersion = snapshot.templatesVersion
            templatesGroupID = snapshot.templatesGroupID
        }

        var snapshot: RuleSnapshot {
            RuleSnapshot(
                revision: revision, groups: groups, rules: rules, templatesInstalled: templatesInstalled,
                migrationNotice: migrationNotice, templatesVersion: templatesVersion, templatesGroupID: templatesGroupID)
        }
    }

    /// What a stored file holds.
    enum Contents: Sendable {
        case current(Configuration)
        /// A schema 1…3 file, migrated in memory. `encoded` replaces the file once the original bytes
        /// are backed up.
        case migrated(Configuration, encoded: Data, fromSchema: Int)
    }

    private struct SchemaProbe: Decodable { var schemaVersion: Int }

    /// The shape schemas 1…3 shared.
    private struct LegacyConfiguration: Decodable {
        var schemaVersion: Int
        var revision: UInt64
        var rules: [LegacyRule]
        var assets: [ManagedAsset]
    }

    /// Decodes and checks a stored file; an older schema comes back migrated. Throws a
    /// `RuleConfigurationProblem`: `corrupt` for text that is not JSON, or JSON of a known schema that
    /// fails its checks; `unsupportedSchema` for another schema, and for schema 4 JSON that does not decode.
    static func read(_ data: Data, limits: RulesLimits) throws -> Contents {
        let decoder = JSONDecoder()
        guard let probe = try? decoder.decode(SchemaProbe.self, from: data) else { throw RuleConfigurationProblem.corrupt }
        if probe.schemaVersion == currentSchema {
            // Valid JSON that says schema 4 but does not decode here was most likely written by a newer
            // version (later phases add stored cases inside schema 4): it is unsupported, left alone and
            // never reset. Text that is not JSON at all (the probe failed above) is damaged.
            guard let configuration = try? decoder.decode(Configuration.self, from: data) else {
                throw RuleConfigurationProblem.unsupportedSchema
            }
            try check(configuration, limits: limits)
            return .current(configuration)
        }
        guard legacySchemas.contains(probe.schemaVersion) else { throw RuleConfigurationProblem.unsupportedSchema }
        guard let legacy = try? decoder.decode(LegacyConfiguration.self, from: data) else {
            throw RuleConfigurationProblem.corrupt
        }
        return try migrate(legacy, limits: limits)
    }

    static func encode(_ configuration: Configuration) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(configuration)
    }

    /// The managed copies the rules' Return File actions reference.
    static func referencedAssets(_ rules: [Rule]) -> Set<UUID> {
        var referenced: Set<UUID> = []
        for rule in rules {
            for action in rule.actions {
                if case .returnFile(let file) = action.kind { referenced.insert(file.assetID) }
            }
        }
        return referenced
    }

    // MARK: checks

    /// What a schema 4 file must satisfy to load. The rule count is not checked: the cap only
    /// constrains growth (D14).
    private static func check(_ configuration: Configuration, limits: RulesLimits) throws {
        // `.max` could never be followed by another revision.
        guard configuration.revision < UInt64.max,
            configuration.rules.allSatisfy({ (try? $0.validate(limits: limits)) != nil }),
            (try? configuration.snapshot.validateStructure(limits: limits, enforcingRuleCount: false)) != nil,
            referencedAssets(configuration.rules).isSubset(of: Set(configuration.assets.map(\.id))),
            assetsAreSound(configuration.assets, limits: limits),
            (configuration.migrationNotice?.omittedPairCount ?? 0) >= 0
        else { throw RuleConfigurationProblem.corrupt }
    }

    private static func assetsAreSound(_ assets: [ManagedAsset], limits: RulesLimits) -> Bool {
        assets.allSatisfy { $0.size >= 0 && $0.displayName.utf8.count <= limits.fieldBytes }
            && Set(assets.map(\.id)).count == assets.count
    }

    // MARK: migration

    /// Spec 5.6.1 with D11–D14: the old checks first (a file the old version refused is corrupt), then
    /// every rule, sorted by (order, array position) and renumbered 0…n−1, becomes a root rule; the
    /// pairs whose behaviour changes become the notice (only when there is one); the revision goes up
    /// by one. The result must pass the schema 4 checks and fit `configBytes`, so the file written can
    /// always be read back; one that cannot is corrupt or too large, and nothing is written.
    private static func migrate(_ legacy: LegacyConfiguration, limits: RulesLimits) throws -> Contents {
        // The migrated revision must itself be followable by a save.
        guard legacy.revision < UInt64.max - 1,
            legacy.rules.allSatisfy({ (try? $0.validate(limits: limits)) != nil }),
            assetsAreSound(legacy.assets, limits: limits)
        else { throw RuleConfigurationProblem.corrupt }
        var mapped: Set<UUID> = []
        for rule in legacy.rules {
            if case .mapLocal(let local) = rule.action { mapped.insert(local.assetID) }
        }
        guard mapped.isSubset(of: Set(legacy.assets.map(\.id))) else { throw RuleConfigurationProblem.corrupt }

        // The analysis reads its input as the old evaluation order.
        let ordered = legacy.rules.enumerated()
            .sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }
            .map(\.element)
        var selection = NoticePairSelection(limit: limits.migrationNoticePairs)
        MigrationAnalyzer.forEachPair(in: ordered) { selection.add($0) }

        let rules = ordered.enumerated().map { position, rule in
            var migrated = Rule(migrating: rule)
            migrated.order = position
            return migrated
        }
        let snapshot = RuleSnapshot(revision: legacy.revision + 1, rules: rules)
        var configuration = Configuration(snapshot: snapshot, assets: legacy.assets)
        try check(configuration, limits: limits)
        let encoded = try fit(&configuration, selection: selection, fromSchema: legacy.schemaVersion, limits: limits)
        try verifyReadBack(encoded, limits: limits)
        return .migrated(configuration, encoded: encoded, fromSchema: legacy.schemaVersion)
    }

    private static let log = Logger(subsystem: "ProxyWoman", category: "RulesEngine")

    /// The bytes about to replace the user's file (after its backup) must be a file a load accepts: they are
    /// decoded back and run through the checks a load runs. Anything else is a failed migration, found
    /// before the first irreversible step, so nothing is backed up or written.
    static func verifyReadBack(_ encoded: Data, limits: RulesLimits) throws {
        guard let decoded = try? JSONDecoder().decode(Configuration.self, from: encoded),
            (try? check(decoded, limits: limits)) != nil
        else {
            log.error("the migrated rules did not read back; nothing was written")
            throw RuleConfigurationProblem.migrationFailed
        }
    }

    /// Adds the notice and encodes. While the file would pass `configBytes`, more pairs are left out
    /// (and counted), so the notice can never make the migrated file unreadable; when the rules alone do
    /// not fit, the file is too large.
    private static func fit(
        _ configuration: inout Configuration, selection: NoticePairSelection, fromSchema: Int, limits: RulesLimits
    ) throws -> Data {
        var selection = selection
        while true {
            configuration.migrationNotice =
                selection.total == 0
                ? nil
                : MigrationNotice(
                    report: MigrationReport(pairs: selection.listed), migratedFromSchema: fromSchema,
                    acknowledged: false, omittedPairCount: selection.omitted)
            let data: Data
            do { data = try encode(configuration) } catch { throw RuleConfigurationProblem.corrupt }
            if data.count <= limits.configBytes { return data }
            let listed = selection.listed
            guard let sample = listed.first else { throw RuleConfigurationProblem.tooLarge }
            // A listed pair takes its encoding and a comma; drop enough at once, then check again.
            let perPair = (try? JSONEncoder().encode(sample).count + 1) ?? 1
            let excess = data.count - limits.configBytes
            selection = selection.keeping(atMost: max(0, listed.count - max(1, (excess + perPair - 1) / perPair)))
        }
    }
}

/// Which of the analysis's pairs a stored notice lists when there are more than `limit`. First, for every
/// lower rule and class, the pair with the highest-priority rule above it, so every affected rule is
/// named at least once; then the other pairs in report order. The listed pairs keep report order; the
/// rest are counted. Holds at most `limit` pairs, whatever the number of pairs fed in.
struct NoticePairSelection {
    private struct Named: Hashable {
        var lowerRuleID: UUID
        var changeClass: MigrationChangeClass
    }

    let limit: Int
    /// Pairs fed in.
    private(set) var total = 0
    private var firsts: [(sequence: Int, pair: MigrationPair)] = []
    private var others: [(sequence: Int, pair: MigrationPair)] = []
    private var named = Set<Named>()

    init(limit: Int) { self.limit = max(0, limit) }

    /// Pairs must come in report order (higher rule, lower rule, class).
    mutating func add(_ pair: MigrationPair) {
        let sequence = total
        total += 1
        if named.insert(Named(lowerRuleID: pair.lowerRuleID, changeClass: pair.changeClass)).inserted {
            guard firsts.count < limit else { return }
            firsts.append((sequence, pair))
            if firsts.count + others.count > limit { others.removeLast() }
        } else if firsts.count + others.count < limit {
            others.append((sequence, pair))
        }
    }

    var listed: [MigrationPair] {
        (firsts + others).sorted { $0.sequence < $1.sequence }.map(\.pair)
    }

    var omitted: Int { total - firsts.count - others.count }

    /// The same choice over the listed pairs with a smaller limit; pairs left out now are counted too.
    func keeping(atMost smaller: Int) -> NoticePairSelection {
        var narrower = NoticePairSelection(limit: min(limit, smaller))
        for pair in listed { narrower.add(pair) }
        narrower.total = total
        return narrower
    }
}
