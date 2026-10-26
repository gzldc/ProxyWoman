import Foundation
import os

public struct RuleGroup: Identifiable, Codable, Sendable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    /// `nil` is the root.
    public var parentID: UUID?
    /// Position among the siblings; rules and subgroups share one number space.
    public var order: Int

    public init(id: UUID = UUID(), name: String, enabled: Bool = true, parentID: UUID? = nil, order: Int = 0) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.parentID = parentID
        self.order = order
    }
}

/// A rule: conditions that select exchanges and the actions it then performs.
public struct Rule: Identifiable, Codable, Sendable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    /// `nil` is the root.
    public var groupID: UUID?
    /// Position among the siblings; rules and subgroups share one number space.
    public var order: Int
    public var conditions: ConditionGroup
    public var actions: [RuleAction]
    public var note: String?

    public init(
        id: UUID = UUID(), name: String, enabled: Bool = true, groupID: UUID? = nil, order: Int = 0,
        conditions: ConditionGroup = ConditionGroup(), actions: [RuleAction], note: String? = nil
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.groupID = groupID
        self.order = order
        self.conditions = conditions
        self.actions = actions
        self.note = note
    }
}

/// How an upgrade can change what a rule set does.
public enum MigrationChangeClass: Int, Codable, Sendable {
    /// A final action now stops the lower-priority rule.
    case finalAction = 1
    /// The lower-priority rule now sees what the higher one changed.
    case laterSeesEarlier = 2
    /// Rules that rewrite the same target now all run in sequence: two status rewrites (the lower
    /// one's status wins), or a Map Remote followed by another Map Remote (it continues from the
    /// first one's target) or by a Map Local (file or directory). Before, the first that could act won
    /// and the others were shadowed.
    case sequentialRewrite = 3
}

/// One affected pair of migrated rules. The sentence shown to the user is built from the class when
/// it is displayed, so the file holds no text.
public struct MigrationPair: Codable, Sendable, Equatable, Hashable {
    public var changeClass: MigrationChangeClass
    public var higherRuleID: UUID
    public var lowerRuleID: UUID

    public init(changeClass: MigrationChangeClass, higherRuleID: UUID, lowerRuleID: UUID) {
        self.changeClass = changeClass
        self.higherRuleID = higherRuleID
        self.lowerRuleID = lowerRuleID
    }
}

public struct MigrationReport: Codable, Sendable, Equatable {
    public var pairs: [MigrationPair]
    public var isEmpty: Bool { pairs.isEmpty }

    public init(pairs: [MigrationPair]) { self.pairs = pairs }
}

public struct MigrationNotice: Codable, Sendable, Equatable {
    public var report: MigrationReport
    public var migratedFromSchema: Int
    public var acknowledged: Bool
    /// Affected pairs the notice does not list. The analysis is quadratic, so the stored list is capped
    /// (`RulesLimits.migrationNoticePairs`, and whatever keeps the file within `configBytes`); every
    /// affected lower rule is listed with its highest-priority cause before any second cause is.
    public var omittedPairCount: Int

    public init(report: MigrationReport, migratedFromSchema: Int, acknowledged: Bool = false, omittedPairCount: Int = 0) {
        self.report = report
        self.migratedFromSchema = migratedFromSchema
        self.acknowledged = acknowledged
        self.omittedPairCount = omittedPairCount
    }

    private enum CodingKeys: String, CodingKey {
        case report, migratedFromSchema, acknowledged, omittedPairCount
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        report = try container.decode(MigrationReport.self, forKey: .report)
        migratedFromSchema = try container.decode(Int.self, forKey: .migratedFromSchema)
        acknowledged = try container.decode(Bool.self, forKey: .acknowledged)
        omittedPairCount = try container.decodeIfPresent(Int.self, forKey: .omittedPairCount) ?? 0
    }
}

/// An immutable, versioned rule set; one exchange uses one snapshot from request head to response.
public struct RuleSnapshot: Codable, Sendable, Equatable {
    /// Always 4 for a snapshot built by this type.
    public var schemaVersion: Int
    public var revision: UInt64
    public var groups: [RuleGroup] { didSet { orderCache = EvaluationOrderCache() } }
    public var rules: [Rule] { didSet { orderCache = EvaluationOrderCache() } }
    public var templatesInstalled: Bool
    public var migrationNotice: MigrationNotice?
    /// The version of the built-in template set last installed (or passed over because it did not fit); nil
    /// on a file that never got one. Not written when nil.
    public var templatesVersion: Int?
    /// The top group of the installed template set; nil when none was added. Not written when nil.
    public var templatesGroupID: UUID?
    /// Shared by the copies of an unchanged snapshot; a change to `rules` or `groups` replaces it. Not
    /// part of the snapshot's value or its stored form.
    private(set) var orderCache = EvaluationOrderCache()

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, revision, groups, rules, templatesInstalled, migrationNotice, templatesVersion, templatesGroupID
    }

    public init(
        revision: UInt64, groups: [RuleGroup] = [], rules: [Rule], templatesInstalled: Bool = false,
        migrationNotice: MigrationNotice? = nil, templatesVersion: Int? = nil, templatesGroupID: UUID? = nil
    ) {
        self.templatesVersion = templatesVersion
        self.templatesGroupID = templatesGroupID
        self.schemaVersion = 4
        self.revision = revision
        self.groups = groups
        self.rules = rules
        self.templatesInstalled = templatesInstalled
        self.migrationNotice = migrationNotice
    }

    /// Enabled rules in evaluation order: the tree depth-first; siblings (rules and subgroups share
    /// `order`) by `order`, a rule before a subgroup on a tie, then by array position. A disabled
    /// group takes its whole subtree with it. Anything not reachable from the root (a rule whose
    /// group is missing, a parent cycle) is not evaluated, and a group id listed twice is entered
    /// once, so bad data can neither loop nor repeat a rule. Worked out once per snapshot value (the
    /// provider does it when it publishes), not once per exchange.
    public var evaluationOrder: [Rule] {
        orderCache.order(computeEvaluationOrder)
    }

    /// Whether an enabled rule judged before the response carries a "hide" action. Worked out once
    /// per snapshot value, like `evaluationOrder`.
    public var canHideAtRequestPoint: Bool {
        orderCache.canHide { evaluationOrder.contains { $0.conditions.judgmentPoint < .response && $0.actions.contains { $0.kind == .hide } } }
    }

    private func computeEvaluationOrder() -> [Rule] {
        enum Node {
            case rule(Rule)
            case group(RuleGroup)
        }
        struct Entry {
            var order: Int
            var isGroup: Bool
            var position: Int
            var node: Node
        }

        var childrenByParent: [UUID?: [Entry]] = [:]
        for (position, rule) in rules.enumerated() where rule.enabled {
            childrenByParent[rule.groupID, default: []].append(
                Entry(order: rule.order, isGroup: false, position: position, node: .rule(rule)))
        }
        for (position, group) in groups.enumerated() where group.enabled {
            childrenByParent[group.parentID, default: []].append(
                Entry(order: group.order, isGroup: true, position: position, node: .group(group)))
        }
        func children(of parent: UUID?) -> [Entry] {
            (childrenByParent[parent] ?? []).sorted {
                ($0.order, $0.isGroup ? 1 : 0, $0.position) < ($1.order, $1.isGroup ? 1 : 0, $1.position)
            }
        }

        var result: [Rule] = []
        var entered = Set<UUID>()
        var stack: [(entries: [Entry], next: Int)] = [(children(of: nil), 0)]
        while let top = stack.indices.last {
            guard stack[top].next < stack[top].entries.count else {
                stack.removeLast()
                continue
            }
            let entry = stack[top].entries[stack[top].next]
            stack[top].next += 1
            switch entry.node {
            case .rule(let rule):
                result.append(rule.expandingMagicStrings())
            case .group(let group):
                if entered.insert(group.id).inserted { stack.append((children(of: group.id), 0)) }
            }
        }
        return result
    }
}

/// Remembers a snapshot's evaluation order once it has been worked out, so the exchanges of one
/// published snapshot do not each walk and sort the tree again. Locked; only the copy of the result
/// runs under the lock. Equal to every other cache, so it never makes two snapshots differ.
struct EvaluationOrderCache: Sendable, Equatable {
    private final class Storage: Sendable {
        let order = OSAllocatedUnfairLock<[Rule]?>(initialState: nil)
        let canHide = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        let requirements = OSAllocatedUnfairLock<SnapshotRequirements?>(initialState: nil)
    }

    private let storage = Storage()

    func order(_ compute: () -> [Rule]) -> [Rule] {
        if let cached = storage.order.withLock({ $0 }) { return cached }
        let computed = compute()
        storage.order.withLock { if $0 == nil { $0 = computed } }
        return computed
    }

    func canHide(_ compute: () -> Bool) -> Bool {
        if let cached = storage.canHide.withLock({ $0 }) { return cached }
        let computed = compute()
        storage.canHide.withLock { if $0 == nil { $0 = computed } }
        return computed
    }

    func requirements(_ compute: () -> SnapshotRequirements) -> SnapshotRequirements {
        if let cached = storage.requirements.withLock({ $0 }) { return cached }
        let computed = compute()
        storage.requirements.withLock { if $0 == nil { $0 = computed } }
        return computed
    }

    static func == (lhs: Self, rhs: Self) -> Bool { true }
}
