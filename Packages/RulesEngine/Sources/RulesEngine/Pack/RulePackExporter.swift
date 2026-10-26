import Foundation

public struct SkippedRule: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        /// A Return Directory rule holds a bookmark that means nothing on another machine.
        case directoryMapping
        /// A returned file's private copy is missing or unreadable.
        case assetUnavailable
        /// A returned file is bigger than one pack asset may be.
        case assetTooLarge
        /// The note is longer than a pack may carry (the reader would refuse the whole pack).
        case noteTooLong
    }

    public var ruleID: UUID
    public var name: String
    public var reason: Reason

    public init(ruleID: UUID, name: String, reason: Reason) {
        self.ruleID = ruleID
        self.name = name
        self.reason = reason
    }
}

public struct RulePackExport: Sendable {
    public var data: Data
    public var skipped: [SkippedRule]
    public var ruleCount: Int
    public var groupCount: Int
}

/// Builds a `.pwrules` pack. Pure with respect to the rule store: it reads rules handed to it and leases
/// managed files one at a time; it never changes either. Equal input gives equal bytes.
public enum RulePackExporter {
    public static func export(
        groups: [RuleGroup], rules: [Rule], selection: Set<UUID>?, assets: ManagedAssetStore, limits: RulesLimits,
        appVersion: String, now: Date
    ) async throws -> RulePackExport {
        let (chosenGroups, chosenRules) = choose(groups: groups, rules: rules, selection: selection)
        let exportedGroupIDs = Set(chosenGroups.map(\.id))

        var skipped: [SkippedRule] = []
        var keptRules: [Rule] = []
        var records: [UUID: RulePackContent.AssetRecord] = [:]
        var payloads: [UUID: Data] = [:]
        var expanded = 0
        // The reader refuses names over the cap; never write a pack this app could not open.
        guard chosenGroups.allSatisfy({ $0.name.utf8.count <= limits.fieldBytes }) else {
            throw RulePackError.exportTooLarge
        }

        for var rule in chosenRules {
            try Task.checkCancellation()
            if rule.actions.contains(where: { if case .returnDirectory = $0.kind { true } else { false } }) {
                skipped.append(SkippedRule(ruleID: rule.id, name: rule.name, reason: .directoryMapping))
                continue
            }
            if (rule.note?.utf8.count ?? 0) > limits.fieldBytes {
                skipped.append(SkippedRule(ruleID: rule.id, name: rule.name, reason: .noteTooLong))
                continue
            }
            var failure: SkippedRule.Reason?
            for id in referencedAssets(rule) where payloads[id] == nil {
                switch try await load(id, assets: assets, limits: limits, expanded: expanded) {
                case .success(let loaded):
                    records[id] = RulePackContent.AssetRecord(
                        id: id, displayName: loaded.displayName, size: Int64(loaded.data.count))
                    payloads[id] = loaded.data
                    expanded += loaded.data.count
                case .failure(let reason):
                    failure = reason
                }
                if failure != nil { break }
            }
            if let failure {
                skipped.append(SkippedRule(ruleID: rule.id, name: rule.name, reason: failure))
                continue
            }
            if let groupID = rule.groupID, !exportedGroupIDs.contains(groupID) { rule.groupID = nil }
            keptRules.append(rule)
        }

        // A file read for a rule that was skipped afterwards is not part of the pack.
        let used = Set(keptRules.flatMap { referencedAssets($0) })
        for id in payloads.keys where !used.contains(id) {
            expanded -= payloads[id]?.count ?? 0
            payloads[id] = nil
            records[id] = nil
        }

        guard !chosenGroups.isEmpty || !keptRules.isEmpty else { throw RulePackError.nothingToExport }

        let sortedIDs = used.sorted { entryName($0) < entryName($1) }
        // The reader refuses more entries than this; never write a pack this app could not open.
        guard 2 + sortedIDs.count <= limits.packEntries else { throw RulePackError.exportTooLarge }
        let content = RulePackContent(
            groups: chosenGroups, rules: keptRules, assets: sortedIDs.compactMap { records[$0] })
        let manifest = RulePackManifest(
            rulesSchema: RuleStorage.currentSchema, appVersion: appVersion, exportedAt: timestamp(now), groupCount: chosenGroups.count,
            ruleCount: keptRules.count, assetCount: sortedIDs.count)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let manifestData = try encoder.encode(manifest)
        let contentData = try encoder.encode(content)
        expanded += manifestData.count + contentData.count
        guard expanded <= limits.packExpandedBytes else { throw RulePackError.exportTooLarge }

        var entries = [
            ZipEntryInput(name: "manifest.json", data: manifestData),
            ZipEntryInput(name: "rules.json", data: contentData),
        ]
        for id in sortedIDs {
            guard let data = payloads[id] else { continue }
            entries.append(ZipEntryInput(name: entryName(id), data: data))
        }
        let data: Data
        do { data = try ZipWriter.write(entries) } catch ZipError.entryTooLarge { throw RulePackError.exportTooLarge }
        guard data.count <= limits.packFileBytes else { throw RulePackError.exportTooLarge }
        return RulePackExport(data: data, skipped: skipped, ruleCount: keptRules.count, groupCount: chosenGroups.count)
    }

    // MARK: selection

    /// The exported groups and rules. A selected group brings its whole subtree; ancestors never come along; a
    /// selected rule is exported alone; a group or rule whose parent is not exported becomes a root item.
    private static func choose(
        groups: [RuleGroup], rules: [Rule], selection: Set<UUID>?
    ) -> ([RuleGroup], [Rule]) {
        guard let selection else {
            return (groups.map(detach(known: Set(groups.map(\.id)))), rules)
        }
        var children: [UUID: [UUID]] = [:]
        for group in groups { if let parent = group.parentID { children[parent, default: []].append(group.id) } }
        var included = Set<UUID>()
        var stack = groups.map(\.id).filter(selection.contains)
        while let id = stack.popLast() {
            guard included.insert(id).inserted else { continue }
            stack.append(contentsOf: children[id] ?? [])
        }
        let chosenGroups = groups.filter { included.contains($0.id) }.map(detach(known: included))
        let chosenRules = rules.filter { selection.contains($0.id) || ($0.groupID.map(included.contains) ?? false) }
        return (chosenGroups, chosenRules)
    }

    private static func detach(known: Set<UUID>) -> (RuleGroup) -> RuleGroup {
        { group in
            var group = group
            if let parent = group.parentID, !known.contains(parent) { group.parentID = nil }
            return group
        }
    }

    // MARK: files

    private enum Loaded {
        case success((displayName: String, data: Data))
        case failure(SkippedRule.Reason)
    }

    private static func load(
        _ id: UUID, assets: ManagedAssetStore, limits: RulesLimits, expanded: Int
    ) async throws -> Loaded {
        guard let asset = await assets.asset(id) else { return .failure(.assetUnavailable) }
        guard asset.size >= 0, asset.size <= Int64(limits.packAssetBytes) else { return .failure(.assetTooLarge) }
        // The whole export fails rather than reading a file that cannot fit anyway.
        guard expanded + Int(asset.size) <= limits.packExpandedBytes else { throw RulePackError.exportTooLarge }
        let lease: OwnedFileLease
        do { lease = try await assets.lease(id) } catch { return .failure(.assetUnavailable) }
        defer { lease.cancel() }
        guard lease.size == asset.size else { return .failure(.assetUnavailable) }
        var data = Data()
        data.reserveCapacity(Int(asset.size))
        do {
            while Int64(data.count) < asset.size {
                try Task.checkCancellation()
                let chunk = try await lease.read(offset: Int64(data.count), maxBytes: limits.ioChunkBytes)
                guard !chunk.isEmpty else { return .failure(.assetUnavailable) }
                data.append(chunk)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failure(.assetUnavailable)
        }
        guard Int64(data.count) == asset.size else { return .failure(.assetUnavailable) }
        return .success((asset.displayName, data))
    }

    private static func referencedAssets(_ rule: Rule) -> [UUID] {
        var ids: [UUID] = []
        for action in rule.actions {
            if case .returnFile(let file) = action.kind, !ids.contains(file.assetID) { ids.append(file.assetID) }
        }
        return ids
    }

    private static func entryName(_ id: UUID) -> String { "assets/" + id.uuidString.lowercased() }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return formatter.string(from: date)
    }
}
