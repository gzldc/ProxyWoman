import Foundation

/// What a pack holds, validated and ready to show. Asset bytes stay compressed in the archive until
/// `assetData` inflates one on demand.
public struct RulePackPreview: Sendable {
    public struct AssetEntry: Sendable, Equatable {
        public var id: UUID
        /// Display only: stripped of path separators and control characters; never used to locate a file.
        public var displayName: String
        public var size: Int64
        /// The archive entry (`assets/<uuid>`), generated from `id`.
        public var entryName: String
    }

    public var manifest: RulePackManifest
    public var groups: [RuleGroup]
    public var rules: [Rule]
    /// Only the files some rule returns.
    public var assets: [AssetEntry]
    /// Files the pack lists that no rule returns; they are not imported.
    public var ignoredAssetCount: Int
    private let archive: ZipArchive?

    public var totalAssetBytes: Int64 { assets.reduce(0) { $0 + $1.size } }

    init(
        manifest: RulePackManifest, groups: [RuleGroup], rules: [Rule], assets: [AssetEntry],
        ignoredAssetCount: Int, archive: ZipArchive?
    ) {
        self.manifest = manifest
        self.groups = groups
        self.rules = rules
        self.assets = assets
        self.ignoredAssetCount = ignoredAssetCount
        self.archive = archive
    }

    /// Inflates one file. The result is exactly the declared size or this throws.
    public func assetData(_ entry: AssetEntry) throws -> Data {
        guard let archive else { throw RulePackError.missingAsset }
        let data: Data
        do { data = try archive.contents(of: entry.entryName) } catch let error as ZipError {
            throw RulePackError(error)
        }
        guard Int64(data.count) == entry.size else { throw RulePackError.assetMismatch }
        return data
    }
}

/// Reads a `.pwrules` pack from untrusted bytes. Pure: nothing is written, no store is touched, nothing runs.
public enum RulePackReader {
    private static let manifestName = "manifest.json"
    private static let rulesName = "rules.json"
    private static let assetPrefix = "assets/"

    private struct VersionProbe: Decodable {
        var format: String
        var schema: Int
        var rulesSchema: Int
    }

    public static func inspect(_ data: Data, limits: RulesLimits) throws -> RulePackPreview {
        // 1. The archive. Unknown names get a zero byte allowance, so they cannot carry content either.
        let archive: ZipArchive
        do {
            archive = try ZipArchive.open(data, limits: limits) { name in
                switch name {
                case manifestName: limits.packManifestBytes
                case rulesName: limits.configBytes
                default: assetID(fromEntry: name) != nil ? limits.packAssetBytes : 0
                }
            }
        } catch let error as ZipError {
            throw RulePackError(error, limits: limits)
        }

        // 2. Exactly manifest.json, rules.json and assets/<uuid>.
        var names = Set<String>()
        for entry in archive.entries {
            guard entry.name == manifestName || entry.name == rulesName || assetID(fromEntry: entry.name) != nil else {
                throw RulePackError.unexpectedEntry
            }
            guard names.insert(entry.name).inserted else { throw RulePackError.duplicateEntry }
        }
        guard names.contains(manifestName), names.contains(rulesName) else { throw RulePackError.notThisFormat }

        // 3. Manifest and version.
        let manifestData = try contents(archive, manifestName, limits)
        let manifest = try decodeManifest(manifestData)

        // 4. Rules.
        let contentData = try contents(archive, rulesName, limits)
        let content: RulePackContent
        do { content = try JSONDecoder().decode(RulePackContent.self, from: contentData) } catch {
            throw RulePackError.undecodableContent
        }

        // Before any rule is validated (each one may compile regexes), so a huge list costs nothing.
        guard content.rules.count <= limits.ruleCount else {
            throw RulePackError.tooManyRules(have: content.rules.count, limit: limits.ruleCount)
        }
        for (index, rule) in content.rules.enumerated() {
            do { try rule.validate(limits: limits) } catch { throw RulePackError.invalidRule(index: index) }
            if (rule.note?.utf8.count ?? 0) > limits.fieldBytes { throw RulePackError.invalidRule(index: index) }
        }
        guard content.groups.allSatisfy({ $0.name.utf8.count <= limits.fieldBytes }) else {
            throw RulePackError.invalidStructure
        }
        // Depth is not refused here: the import lifts groups that would go too deep.
        var structural = limits
        structural.groupDepth = .max
        do {
            try RuleSnapshot(revision: 0, groups: content.groups, rules: content.rules)
                .validateStructure(limits: structural, enforcingRuleCount: false)
        } catch { throw RulePackError.invalidStructure }
        guard content.groups.count <= limits.packGroups else { throw RulePackError.invalidStructure }

        // 5. Files.
        var referenced = Set<UUID>()
        for rule in content.rules {
            for action in rule.actions {
                switch action.kind {
                case .returnDirectory: throw RulePackError.directoryMapping
                case .returnFile(let file): referenced.insert(file.assetID)
                default: break
                }
            }
        }
        var records: [UUID: RulePackContent.AssetRecord] = [:]
        for record in content.assets {
            guard records.updateValue(record, forKey: record.id) == nil else { throw RulePackError.invalidStructure }
        }
        // Every file entry must be listed, so nothing rides along unexplained.
        let entrySizes = Dictionary(uniqueKeysWithValues: archive.entries.map { ($0.name, $0.size) })
        for name in names {
            if let id = assetID(fromEntry: name), records[id] == nil { throw RulePackError.unexpectedEntry }
        }
        var assets: [RulePackPreview.AssetEntry] = []
        for id in referenced.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let record = records[id], let size = entrySizes[entryName(id)] else {
                throw RulePackError.missingAsset
            }
            guard record.size == Int64(size) else { throw RulePackError.assetMismatch }
            guard size <= limits.packAssetBytes else { throw RulePackError.assetTooLarge(limit: limits.packAssetBytes) }
            assets.append(RulePackPreview.AssetEntry(
                id: id, displayName: sanitizedDisplayName(record.displayName, limits: limits), size: record.size,
                entryName: entryName(id)))
        }
        let ignored = records.keys.filter { !referenced.contains($0) }.count
        return RulePackPreview(
            manifest: manifest, groups: content.groups, rules: content.rules, assets: assets,
            ignoredAssetCount: ignored, archive: archive)
    }

    /// The size is checked against the cap before a single byte is read.
    public static func inspect(fileAt url: URL, limits: RulesLimits) throws -> RulePackPreview {
        if url.pathExtension.lowercased() == "farx" { throw RulePackError.farxUnsupported }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            attributes[.type] as? FileAttributeType == .typeRegular, let size = attributes[.size] as? NSNumber
        else { throw RulePackError.readFailed }
        guard size.int64Value <= Int64(limits.packFileBytes) else {
            throw RulePackError.tooLarge(limit: limits.packFileBytes)
        }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw RulePackError.readFailed }
        return try inspect(data, limits: limits)
    }

    // MARK: pieces

    private static func contents(_ archive: ZipArchive, _ name: String, _ limits: RulesLimits) throws -> Data {
        do { return try archive.contents(of: name) } catch let error as ZipError {
            throw RulePackError(error, limits: limits)
        }
    }

    private static func decodeManifest(_ data: Data) throws -> RulePackManifest {
        guard let probe = try? JSONDecoder().decode(VersionProbe.self, from: data),
            probe.format == RulePackManifest.format
        else { throw RulePackError.notThisFormat }
        if probe.schema > RulePackManifest.currentSchema { throw RulePackError.newerVersion(probe.schema) }
        if probe.rulesSchema > RulePackManifest.currentRulesSchema { throw RulePackError.newerVersion(probe.rulesSchema) }
        guard probe.schema >= RulePackManifest.currentSchema, probe.rulesSchema >= RulePackManifest.currentRulesSchema,
            let manifest = try? JSONDecoder().decode(RulePackManifest.self, from: data)
        else { throw RulePackError.notThisFormat }
        return manifest
    }

    private static func entryName(_ id: UUID) -> String { assetPrefix + id.uuidString.lowercased() }

    /// The id of an `assets/<lowercase uuid>` entry name, nil for anything else.
    private static func assetID(fromEntry name: String) -> UUID? { RulePackReader.assetEntryID(name) }

    /// The one parse of an `assets/<lowercase uuid>` entry name (also used to class a too-big entry).
    static func assetEntryID(_ name: String) -> UUID? {
        guard name.hasPrefix(assetPrefix), let id = UUID(uuidString: String(name.dropFirst(assetPrefix.count))),
            assetPrefix + id.uuidString.lowercased() == name
        else { return nil }
        return id
    }

    /// For display only: no path separators, no control or invisible-format characters, at most `fieldBytes`.
    static func sanitizedDisplayName(_ name: String, limits: RulesLimits) -> String {
        var result = String.UnicodeScalarView()
        var bytes = 0
        for scalar in name.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .unassigned, .privateUse: continue
            default: break
            }
            if scalar == "/" || scalar == "\\" { continue }
            let width = String(scalar).utf8.count
            guard bytes + width <= limits.fieldBytes else { break }
            result.append(scalar)
            bytes += width
        }
        return String(result).trimmingCharacters(in: .whitespaces)
    }
}
