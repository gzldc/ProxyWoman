import FlowStore
import Foundation
import Testing

@testable import RulesEngine

/// Rules 2.0 phase R7 adds no stored shape beyond the `templatesInstalled` flag (import and export never touch
/// the rules file's shape): the R5 / R6 fixtures load and save with the same bytes, installing the templates
/// changes nothing else, and the sample pack description builds a valid `.pwrules`.
@Suite struct RulesFileByteIdenticalR7Tests {
    private static let docs = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/fixtures/rules2")
    static let sampleURL = docs.appendingPathComponent("R7-sample.pwrules.json")

    private static func current(_ data: Data) throws -> RuleStorage.Configuration {
        guard case .current(let configuration) = try RuleStorage.read(data, limits: RulesLimits()) else {
            Issue.record("expected a schema 4 file")
            throw RuleConfigurationProblem.corrupt
        }
        return configuration
    }

    private static func canonical(_ data: Data) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: data)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    @Test func rulesFileRoundTripsByteForByte() throws {
        for url in [RulesFileByteIdenticalR6Tests.r5FixtureURL, RulesFileByteIdenticalR6Tests.executeFixtureURL] {
            let original = try Data(contentsOf: url)
            let encoded = try RuleStorage.encode(Self.current(original))
            #expect(try Self.canonical(encoded) == Self.canonical(original), "\(url.lastPathComponent)")
            #expect(try RuleStorage.encode(Self.current(encoded)) == encoded, "\(url.lastPathComponent)")
        }
    }

    @Test func templateInstallOnlyAddsItsOwnGroupsRulesAndVersionKeys() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let configDir = root.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let file = configDir.appendingPathComponent("rules.json")
        try Data(contentsOf: RulesFileByteIdenticalR6Tests.r5FixtureURL).write(to: file)

        let limits = RulesLimits()
        let assets = ManagedAssetStore(
            directory: root.appendingPathComponent("assets"), limits: limits,
            budgets: OwnedFileBudgets(limits: limits, freeDiskBytes: ample))
        let repository = RuleRepository(directory: configDir, assets: assets, limits: limits)
        let loaded = try await repository.load()
        let before = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(before["templatesInstalled"] as? Bool != true)
        #expect(before["templatesVersion"] == nil && before["templatesGroupID"] == nil)

        let set = DefaultTemplateCatalog.build(groupName: { "G\($0.rawValue)" }, ruleName: { "R\($0.rawValue)" })
        let installed = try await repository.installDefaultTemplates(set, expectedRevision: loaded.revision)
        #expect(installed.templatesInstalled)
        let after = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])

        #expect(after["revision"] as? UInt64 == loaded.revision + 1)
        #expect(after["templatesInstalled"] as? Bool == true)
        #expect(after["templatesVersion"] as? Int == 1)
        #expect(after["templatesGroupID"] as? String == set.rootGroupID.uuidString)
        let addedGroups = Set(set.groups.map(\.id.uuidString)), addedRules = Set(set.rules.map(\.id.uuidString))
        func items(_ object: [String: Any], _ key: String, dropping ids: Set<String>) throws -> [NSDictionary] {
            try #require(object[key] as? [[String: Any]]).filter { !ids.contains(($0["id"] as? String) ?? "") }.map { $0 as NSDictionary }
        }
        #expect(try items(after, "groups", dropping: addedGroups) == items(before, "groups", dropping: addedGroups))
        #expect(try items(after, "rules", dropping: addedRules) == items(before, "rules", dropping: addedRules))
        #expect((after["groups"] as? [[String: Any]])?.count == (before["groups"] as? [[String: Any]])!.count + 9)
        #expect((after["rules"] as? [[String: Any]])?.count == (before["rules"] as? [[String: Any]])!.count + 28)
        // Every other top-level key is identical, apart from the one managed file the Return File template needs.
        let others = Set(before.keys).union(after.keys)
            .subtracting(["revision", "templatesInstalled", "templatesVersion", "templatesGroupID", "groups", "rules", "assets"])
        for key in others {
            #expect((before[key] as? NSObject) == (after[key] as? NSObject), "\(key)")
        }
        let assetsBefore = try #require(before["assets"] as? [[String: Any]]), assetsAfter = try #require(after["assets"] as? [[String: Any]])
        #expect(assetsAfter.count == assetsBefore.count + 1)
    }

    // MARK: sample pack

    private static func id(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-0000000007%02d", number))!
    }
    static let sampleAssetID = id(70)
    static let sampleAssetBytes = Data("{\"hello\":\"r7\"}\n".utf8)

    private static func conditions(path: String) -> ConditionGroup {
        ConditionGroup(rows: [
            ConditionRow(field: .host, op: .equals, value: "r7.test"),
            ConditionRow(field: .path, op: .startsWith, value: path),
        ])
    }

    static let sampleGroups = [
        RuleGroup(id: id(90), name: "R7 outer group", order: 0),
        RuleGroup(id: id(91), name: "R7 inner group", parentID: id(90), order: 0),
    ]
    static let sampleRules: [Rule] = [
        Rule(
            id: id(1), name: "R7 preset 404", groupID: id(91), order: 0, conditions: conditions(path: "/missing"),
            actions: [RuleAction(.returnPreset(PresetResponse(preset: .notFound404)), isFinal: true)]),
        Rule(
            id: id(2), name: "R7 response edit", groupID: id(91), order: 1, conditions: conditions(path: "/api"),
            actions: [
                RuleAction(.editHeaders(direction: .response, operations: [.set(name: "X-R7-Response", value: "1")])),
                RuleAction(.rewriteStatus(RewriteStatusAction(status: 203))),
            ]),
        Rule(
            id: id(3), name: "R7 return file", groupID: id(90), order: 0, conditions: conditions(path: "/file"),
            actions: [RuleAction(.returnFile(MapLocalAction(
                assetID: sampleAssetID, status: 200, headers: [HeaderField(name: "Content-Type", value: "application/json")])))]),
        Rule(
            id: id(4), name: "R7 breakpoint", order: 0, conditions: conditions(path: "/pause"),
            actions: [RuleAction(.breakpoint(direction: .request, mode: .headers))]),
    ]

    private struct Description: Decodable {
        struct Asset: Decodable { var id: UUID; var displayName: String; var hex: String }
        var packName: String
        var groups: [RuleGroup]
        var rules: [Rule]
        var assets: [Asset]
    }

    private static func bytes(hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    /// Builds the pack the native acceptance imports from the desktop.
    private static func buildPack(from description: Description) throws -> Data {
        let records = try description.assets.map { asset in
            RulePackContent.AssetRecord(
                id: asset.id, displayName: asset.displayName,
                size: Int64(try #require(bytes(hex: asset.hex)).count))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let content = try encoder.encode(RulePackContent(groups: description.groups, rules: description.rules, assets: records))
        let manifest = try encoder.encode(RulePackManifest(
            appVersion: "sample", exportedAt: "2026-10-25T00:00:00Z", groupCount: description.groups.count,
            ruleCount: description.rules.count, assetCount: description.assets.count))
        var entries = [
            ZipEntryInput(name: "manifest.json", data: manifest),
            ZipEntryInput(name: "rules.json", data: content),
        ]
        for asset in description.assets {
            entries.append(ZipEntryInput(
                name: "assets/" + asset.id.uuidString.lowercased(), data: try #require(bytes(hex: asset.hex))))
        }
        return try ZipWriter.write(entries)
    }

    @Test func sampleDescriptionBuildsAValidPack() throws {
        let description = try JSONDecoder().decode(Description.self, from: Data(contentsOf: Self.sampleURL))
        #expect(description.packName == "R7-sample.pwrules")
        #expect(description.groups == Self.sampleGroups)
        #expect(description.rules == Self.sampleRules)
        #expect(description.assets.count == 1)
        #expect(Self.bytes(hex: description.assets[0].hex) == Self.sampleAssetBytes)

        let pack = try Self.buildPack(from: description)
        #expect(try Self.buildPack(from: description) == pack)  // deterministic
        let preview = try RulePackReader.inspect(pack, limits: RulesLimits())
        #expect(preview.groups.count == 2 && preview.rules.count == 4 && preview.assets.count == 1)
        #expect(try preview.assetData(preview.assets[0]) == Self.sampleAssetBytes)
        #expect(preview.ignoredAssetCount == 0)
        // Two group levels, a preset 404, response header + status edit, a returned file, a breakpoint.
        #expect(preview.groups.contains { $0.parentID != nil })
        func has(_ test: (ActionKind) -> Bool) -> Bool { preview.rules.contains { $0.actions.contains { test($0.kind) } } }
        #expect(has { if case .returnPreset = $0 { true } else { false } })
        #expect(has { if case .editHeaders(.response, _) = $0 { true } else { false } })
        #expect(has { if case .rewriteStatus = $0 { true } else { false } })
        #expect(has { if case .returnFile = $0 { true } else { false } })
        #expect(has { if case .breakpoint = $0 { true } else { false } })
    }
}
