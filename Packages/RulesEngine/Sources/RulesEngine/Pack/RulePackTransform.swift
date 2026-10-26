import Foundation

/// What importing a pack will add: fresh ids throughout, one disabled wrapper group at the top of the root,
/// and everything the pack held inside it. Existing rules and groups appear unchanged.
public struct RulePackImportPlan: Sendable, Equatable {
    public struct PlannedAsset: Sendable, Equatable {
        public var newID: UUID
        public var oldID: UUID
        public var displayName: String
        public var size: Int64
        public var entryName: String
    }

    public var wrapper: RuleGroup
    /// Existing groups first (unchanged), then the wrapper, then the imported ones.
    public var groups: [RuleGroup]
    /// Existing rules first (unchanged, except the root `order` shift), then the imported ones.
    public var rules: [Rule]
    public var assets: [PlannedAsset]
    /// The wrapper is not counted.
    public var importedRuleCount: Int
    public var importedGroupCount: Int
    public var liftedGroupCount: Int
    /// Rules that held a breakpoint and were switched off because breakpoints are not live.
    public var breakpointRuleCount: Int
    public var ignoredAssetCount: Int
}

/// Turns an inspected pack into the rule list that results from importing it. Pure.
public enum RulePackTransform {
    public static func plan(
        _ preview: RulePackPreview, into existing: RuleSnapshot, wrapperName: String, limits: RulesLimits,
        breakpointsLive: Bool
    ) throws -> RulePackImportPlan {
        try plan(
            preview, into: existing, wrapperName: wrapperName, limits: limits, breakpointsLive: breakpointsLive,
            idGenerator: UUID.init)
    }

    static func plan(
        _ preview: RulePackPreview, into existing: RuleSnapshot, wrapperName: String, limits: RulesLimits,
        breakpointsLive: Bool, idGenerator: () -> UUID
    ) throws -> RulePackImportPlan {
        let have = existing.rules.count + preview.rules.count
        let cap = max(limits.ruleCount, existing.rules.count)
        if have > cap { throw RulePackError.tooManyRules(have: have, limit: limits.ruleCount) }

        // Fresh ids, never one already used by the existing list.
        var taken = Set(existing.groups.map(\.id)).union(existing.rules.map(\.id))
        func freshID() -> UUID {
            while true {
                let id = idGenerator()
                if taken.insert(id).inserted { return id }
            }
        }
        let wrapperID = freshID()
        var groupMap: [UUID: UUID] = [:]
        for group in preview.groups { groupMap[group.id] = freshID() }
        var ruleIDs: [UUID] = []
        for _ in preview.rules { ruleIDs.append(freshID()) }
        var assetMap: [UUID: UUID] = [:]
        var assets: [RulePackImportPlan.PlannedAsset] = []
        for entry in preview.assets {
            let newID = freshID()
            assetMap[entry.id] = newID
            assets.append(
                .init(
                    newID: newID, oldID: entry.id, displayName: entry.displayName, size: entry.size,
                    entryName: entry.entryName))
        }

        // Depth: the wrapper takes one level, so the pack may use groupDepth - 1.
        let maxPackDepth = limits.groupDepth - 1
        if maxPackDepth < 1, !preview.groups.isEmpty { throw RulePackError.invalidStructure }
        let oldByID = Dictionary(preview.groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var effectiveParent: [UUID: UUID?] = [:]  // old id -> old id of the (possibly lifted) parent
        var effectiveDepth: [UUID: Int] = [:]
        var lifted = 0
        func resolve(_ id: UUID, _ trail: Set<UUID>) throws {
            if effectiveDepth[id] != nil { return }
            guard let group = oldByID[id], !trail.contains(id) else { throw RulePackError.invalidStructure }
            var parent = group.parentID
            if let p = parent { try resolve(p, trail.union([id])) }
            let original = parent
            // Walk up until the parent leaves room for this group.
            while let p = parent, effectiveDepth[p]! >= maxPackDepth { parent = effectiveParent[p]! }
            if parent != original { lifted += 1 }
            effectiveParent[id] = parent
            effectiveDepth[id] = (parent.map { effectiveDepth[$0]! } ?? 0) + 1
        }
        for group in preview.groups { try resolve(group.id, []) }

        // Children of each new parent (nil = wrapper), ordered by (order, position, rules before groups).
        struct Child {
            var order: Int
            var isGroup: Bool
            var index: Int
        }
        var children: [UUID?: [Child]] = [:]
        for (index, group) in preview.groups.enumerated() {
            children[effectiveParent[group.id]!, default: []].append(.init(order: group.order, isGroup: true, index: index))
        }
        for (index, rule) in preview.rules.enumerated() {
            if let g = rule.groupID, oldByID[g] == nil { throw RulePackError.invalidStructure }
            children[rule.groupID, default: []].append(.init(order: rule.order, isGroup: false, index: index))
        }
        var newOrder: [Bool: [Int: Int]] = [true: [:], false: [:]]
        for (_, list) in children {
            let sorted = list.sorted {
                if $0.order != $1.order { return $0.order < $1.order }
                if $0.index != $1.index { return $0.index < $1.index }
                return !$0.isGroup && $1.isGroup
            }
            for (position, child) in sorted.enumerated() { newOrder[child.isGroup]![child.index] = position }
        }

        var groups: [RuleGroup] = preview.groups.enumerated().map { index, group in
            var copy = group
            copy.id = groupMap[group.id]!
            copy.parentID = effectiveParent[group.id]!.map { groupMap[$0]! } ?? wrapperID
            copy.order = newOrder[true]![index]!
            return copy
        }
        var breakpointRules = 0
        var rules: [Rule] = try preview.rules.enumerated().map { index, rule in
            var copy = rule
            copy.id = ruleIDs[index]
            copy.groupID = rule.groupID.map { groupMap[$0]! } ?? wrapperID
            copy.order = newOrder[false]![index]!
            for (i, action) in copy.actions.enumerated() {
                if case .returnFile(var file) = action.kind {
                    guard let mapped = assetMap[file.assetID] else { throw RulePackError.missingAsset }
                    file.assetID = mapped
                    copy.actions[i].kind = .returnFile(file)
                }
            }
            if !breakpointsLive, copy.enabled,
                copy.actions.contains(where: { if case .breakpoint = $0.kind { true } else { false } })
            {
                copy.enabled = false
                breakpointRules += 1
            }
            return copy
        }

        let wrapper = RuleGroup(id: wrapperID, name: wrapperName, enabled: false, parentID: nil, order: 0)
        let shiftedGroups = existing.groups.map { group -> RuleGroup in
            var copy = group
            if copy.parentID == nil { copy.order += 1 }
            return copy
        }
        let shiftedRules = existing.rules.map { rule -> Rule in
            var copy = rule
            if copy.groupID == nil { copy.order += 1 }
            return copy
        }
        groups = shiftedGroups + [wrapper] + groups
        rules = shiftedRules + rules

        let result = RuleSnapshot(revision: existing.revision, groups: groups, rules: rules)
        do { try result.validateStructure(limits: limits, enforcingRuleCount: false) } catch {
            throw RulePackError.invalidStructure
        }
        return RulePackImportPlan(
            wrapper: wrapper, groups: groups, rules: rules, assets: assets, importedRuleCount: preview.rules.count,
            importedGroupCount: preview.groups.count, liftedGroupCount: lifted, breakpointRuleCount: breakpointRules,
            ignoredAssetCount: preview.ignoredAssetCount)
    }
}
