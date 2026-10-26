import Foundation
import Testing
@testable import RulesEngine

private struct Fixture {
    let root: URL
    let store: ManagedAssetStore
    let limits: RulesLimits

    init(limits: RulesLimits = RulesLimits()) {
        root = makeTempDirectory()
        self.limits = limits
        store = ManagedAssetStore(
            directory: root.appendingPathComponent("assets"), limits: limits,
            budgets: OwnedFileBudgets(limits: limits, freeDiskBytes: ample))
    }

    func cleanup() { removeTree(root) }

    func asset(_ bytes: Data, name: String = "body.json") async throws -> ManagedAsset {
        let file = writeFile(root.appendingPathComponent(UUID().uuidString), bytes)
        return try await store.importFile(file, displayName: name)
    }

    func export(_ groups: [RuleGroup], _ rules: [Rule], _ selection: Set<UUID>? = nil, appVersion: String = "1.2.3",
                now: Date = Date(timeIntervalSince1970: 1_800_000_000)) async throws -> RulePackExport {
        try await RulePackExporter.export(
            groups: groups, rules: rules, selection: selection, assets: store, limits: limits,
            appVersion: appVersion, now: now)
    }
}

private func plainRule(_ name: String, group: UUID? = nil, enabled: Bool = true, note: String? = nil) -> Rule {
    Rule(name: name, enabled: enabled, groupID: group, actions: [RuleAction(.hide)], note: note)
}

private func fileRule(_ name: String, asset: UUID, group: UUID? = nil) -> Rule {
    Rule(name: name, groupID: group, actions: [RuleAction(.returnFile(MapLocalAction(assetID: asset, headers: [])))])
}

private func directoryRule(_ name: String) -> Rule {
    Rule(name: name, actions: [RuleAction(.returnDirectory(
        MapLocalDirectoryAction(bookmark: Data([1, 2, 3]), displayName: "site"), pathPrefix: "/"))])
}

private func open(_ export: RulePackExport) throws -> ZipArchive {
    try ZipArchive.open(export.data, limits: RulesLimits(), entryLimit: { _ in 10_000_000 })
}

private func content(_ export: RulePackExport) throws -> RulePackContent {
    try JSONDecoder().decode(RulePackContent.self, from: try open(export).contents(of: "rules.json"))
}

@Suite struct RulePackExporterTests {
    @Test func exportAllRoundTripsThroughTheZipReader() async throws {
        let f = Fixture(); defer { f.cleanup() }
        let bytes = randomData(1000)
        let a = try await f.asset(bytes, name: "a.bin")
        let group = RuleGroup(name: "G")
        let rules = [plainRule("one", group: group.id), fileRule("two", asset: a.id)]
        let result = try await f.export([group], rules)

        let archive = try open(result)
        #expect(Set(archive.entries.map(\.name)) == ["manifest.json", "rules.json", "assets/" + a.id.uuidString.lowercased()])
        let manifest = try JSONDecoder().decode(RulePackManifest.self, from: archive.contents(of: "manifest.json"))
        #expect(manifest.format == "proxywoman-rules" && manifest.schema == 1 && manifest.rulesSchema == 4)
        #expect(manifest.app == "ProxyWoman" && manifest.appVersion == "1.2.3")
        #expect(manifest.groupCount == 1 && manifest.ruleCount == 2 && manifest.assetCount == 1)
        #expect(manifest.exportedAt == "2027-01-15T08:00:00Z")
        let packed = try content(result)
        #expect(packed.groups == [group] && packed.rules == rules)
        #expect(packed.assets == [.init(id: a.id, displayName: "a.bin", size: 1000)])
        #expect(try archive.contents(of: "assets/" + a.id.uuidString.lowercased()) == bytes)
        #expect(result.ruleCount == 2 && result.groupCount == 1 && result.skipped.isEmpty)
    }

    @Test func selectedRuleBecomesTheRootOfThePack() async throws {
        let f = Fixture(); defer { f.cleanup() }
        let group = RuleGroup(name: "G")
        let inside = plainRule("in", group: group.id)
        let other = plainRule("other", group: group.id)
        let result = try await f.export([group], [inside, other], [inside.id])
        let packed = try content(result)
        #expect(packed.groups.isEmpty)
        #expect(packed.rules.map(\.id) == [inside.id])
        #expect(packed.rules[0].groupID == nil)
    }

    @Test func selectedGroupBringsItsWholeSubtree() async throws {
        let f = Fixture(); defer { f.cleanup() }
        let top = RuleGroup(name: "top")
        let child = RuleGroup(name: "child", parentID: top.id)
        let grandchild = RuleGroup(name: "grand", parentID: child.id)
        let sibling = RuleGroup(name: "sibling")
        let rules = [plainRule("a", group: top.id), plainRule("b", group: grandchild.id), plainRule("c", group: sibling.id)]
        let result = try await f.export([top, child, grandchild, sibling], rules, [top.id])
        let packed = try content(result)
        #expect(Set(packed.groups.map(\.id)) == [top.id, child.id, grandchild.id])
        #expect(Set(packed.rules.map(\.name)) == ["a", "b"])
        #expect(packed.groups.first { $0.id == child.id }?.parentID == top.id)
    }

    @Test func ancestorsOfASelectedGroupAreNotExported() async throws {
        let f = Fixture(); defer { f.cleanup() }
        let top = RuleGroup(name: "top")
        let child = RuleGroup(name: "child", parentID: top.id)
        let result = try await f.export([top, child], [plainRule("x", group: child.id)], [child.id])
        let packed = try content(result)
        #expect(packed.groups.map(\.id) == [child.id])
        #expect(packed.groups[0].parentID == nil)
        #expect(packed.rules[0].groupID == child.id)
    }

    @Test func enabledStateAndNotesSurvive() async throws {
        let f = Fixture(); defer { f.cleanup() }
        let group = RuleGroup(name: "off", enabled: false)
        let rules = [plainRule("off", group: group.id, enabled: false, note: "keep me"), plainRule("on", note: nil)]
        let packed = try content(try await f.export([group], rules))
        #expect(packed.groups[0].enabled == false)
        #expect(packed.rules.map(\.enabled) == [false, true])
        #expect(packed.rules[0].note == "keep me")
    }

    @Test func unselectedRulesAndTheirAssetsAreNotIncluded() async throws {
        let f = Fixture(); defer { f.cleanup() }
        let kept = try await f.asset(randomData(10), name: "kept")
        let dropped = try await f.asset(randomData(10), name: "dropped")
        let a = fileRule("a", asset: kept.id), b = fileRule("b", asset: dropped.id)
        let result = try await f.export([], [a, b], [a.id])
        let archive = try open(result)
        #expect(Set(archive.entries.map(\.name)) == ["manifest.json", "rules.json", "assets/" + kept.id.uuidString.lowercased()])
        #expect(try content(result).assets.map(\.id) == [kept.id])
    }

    @Test func directoryMappingRulesAreSkippedOnExport() async throws {
        let f = Fixture(); defer { f.cleanup() }
        let dir = directoryRule("dir"), plain = plainRule("plain")
        let result = try await f.export([], [dir, plain])
        #expect(result.skipped == [SkippedRule(ruleID: dir.id, name: "dir", reason: .directoryMapping)])
        #expect(try content(result).rules.map(\.id) == [plain.id])
        #expect(result.ruleCount == 1)
    }

    @Test func unavailableAssetSkipsOnlyThatRule() async throws {
        let f = Fixture(); defer { f.cleanup() }
        let good = try await f.asset(randomData(10))
        let ghost = fileRule("ghost", asset: UUID())
        let ok = fileRule("ok", asset: good.id)
        let result = try await f.export([], [ghost, ok])
        #expect(result.skipped == [SkippedRule(ruleID: ghost.id, name: "ghost", reason: .assetUnavailable)])
        #expect(try content(result).rules.map(\.id) == [ok.id])
    }

    @Test func assetOverTheCapIsSkipped() async throws {
        let f = Fixture(limits: RulesLimits(packAssetBytes: 100)); defer { f.cleanup() }
        let big = try await f.asset(randomData(101)), small = try await f.asset(randomData(100))
        let bigRule = fileRule("big", asset: big.id), smallRule = fileRule("small", asset: small.id)
        let result = try await f.export([], [bigRule, smallRule])
        #expect(result.skipped == [SkippedRule(ruleID: bigRule.id, name: "big", reason: .assetTooLarge)])
        let packed = try content(result)
        #expect(packed.rules.map(\.id) == [smallRule.id] && packed.assets.map(\.id) == [small.id])
    }

    @Test func totalOverTheExpandedCapFailsWholeExport() async throws {
        let f = Fixture(limits: RulesLimits(packExpandedBytes: 1500)); defer { f.cleanup() }
        let a = try await f.asset(randomData(800)), b = try await f.asset(randomData(800))
        await #expect(throws: RulePackError.exportTooLarge) {
            try await f.export([], [fileRule("a", asset: a.id), fileRule("b", asset: b.id)])
        }
    }

    @Test func emptySelectionThrowsNothingToExport() async throws {
        let f = Fixture(); defer { f.cleanup() }
        let rule = plainRule("r")
        await #expect(throws: RulePackError.nothingToExport) { try await f.export([], [rule], []) }
        await #expect(throws: RulePackError.nothingToExport) { try await f.export([], []) }
        let dir = directoryRule("only")
        await #expect(throws: RulePackError.nothingToExport) { try await f.export([], [dir]) }
    }

    @Test func equalInputGivesEqualPackBytes() async throws {
        let f = Fixture(); defer { f.cleanup() }
        let a = try await f.asset(randomData(5000)), b = try await f.asset(randomData(300))
        let group = RuleGroup(name: "G")
        let rules = [fileRule("a", asset: a.id, group: group.id), fileRule("b", asset: b.id), plainRule("p")]
        let first = try await f.export([group], rules)
        let second = try await f.export([group], rules)
        #expect(first.data == second.data)
    }

    @Test func exportDoesNotTouchStoreOrRevision() async throws {
        let f = Fixture(); defer { f.cleanup() }
        let a = try await f.asset(randomData(64))
        let before = names(in: f.root.appendingPathComponent("assets"))
        let rules = [fileRule("a", asset: a.id)]
        let copy = rules
        _ = try await f.export([], rules)
        #expect(rules == copy)
        #expect(names(in: f.root.appendingPathComponent("assets")) == before)
        #expect(await f.store.asset(a.id) == a)
    }

    @Test func packContainsNoMachinePathsOrRevisionOrNotice() async throws {
        let f = Fixture(); defer { f.cleanup() }
        let a = try await f.asset(randomData(64))
        let result = try await f.export([RuleGroup(name: "G")], [fileRule("a", asset: a.id), plainRule("p")])
        let archive = try open(result)
        let text = String(decoding: try archive.contents(of: "rules.json"), as: UTF8.self)
            + String(decoding: try archive.contents(of: "manifest.json"), as: UTF8.self)
        for forbidden in ["migrationNotice", "revision", "/Users/", NSHomeDirectory(), f.root.path, "templatesInstalled"] {
            #expect(!text.contains(forbidden), "\(forbidden)")
        }
    }

    @Test func tooManyEntriesFailsTheExport() async throws {
        let f = Fixture(limits: RulesLimits(packEntries: 3)); defer { f.cleanup() }
        let a = try await f.asset(randomData(10)), b = try await f.asset(randomData(10))
        await #expect(throws: RulePackError.exportTooLarge) {
            try await f.export([], [fileRule("a", asset: a.id), fileRule("b", asset: b.id)])
        }
        let ok = try await f.export([], [fileRule("a", asset: a.id)])
        #expect(try open(ok).entries.count == 3)
    }

    @Test func packBiggerThanTheFileCapFailsTheExport() async throws {
        let f = Fixture(limits: RulesLimits(packFileBytes: 600)); defer { f.cleanup() }
        let a = try await f.asset(randomData(2000))
        await #expect(throws: RulePackError.exportTooLarge) { try await f.export([], [fileRule("a", asset: a.id)]) }
    }

    @Test func manifestRulesSchemaMatchesTheStorageSchema() {
        #expect(RulePackManifest.currentRulesSchema == RuleStorage.currentSchema)
    }

    @Test func assetsAreOrderedByEntryName() async throws {
        let f = Fixture(); defer { f.cleanup() }
        var assets: [ManagedAsset] = []
        for _ in 0..<4 { assets.append(try await f.asset(randomData(20))) }
        let result = try await f.export([], assets.map { fileRule("r", asset: $0.id) })
        let assetNames = try open(result).entries.map(\.name).filter { $0.hasPrefix("assets/") }
        #expect(assetNames == assetNames.sorted() && assetNames.count == 4)
        #expect(try content(result).assets.map(\.id.uuidString) == assets.map(\.id.uuidString).sorted { $0.lowercased() < $1.lowercased() })
    }

    @Test func directoryRuleInsideAnExportedGroupLeavesTheGroupEmpty() async throws {
        let f = Fixture(); defer { f.cleanup() }
        let group = RuleGroup(name: "G")
        var dir = directoryRule("dir"); dir.groupID = group.id
        let result = try await f.export([group], [dir], [group.id])
        #expect(result.skipped.map(\.reason) == [.directoryMapping])
        let packed = try content(result)
        #expect(packed.groups == [group] && packed.rules.isEmpty)
    }

    @Test func aFileUsedTwiceIsStoredOnce() async throws {
        let f = Fixture(); defer { f.cleanup() }
        let a = try await f.asset(randomData(50))
        let both = Rule(name: "both", actions: [
            RuleAction(.returnFile(MapLocalAction(assetID: a.id, headers: []))),
            RuleAction(.returnFile(MapLocalAction(assetID: a.id, headers: []))),
        ])
        let result = try await f.export([], [both, fileRule("other", asset: a.id)])
        let archive = try open(result)
        #expect(archive.entries.filter { $0.name.hasPrefix("assets/") }.count == 1)
        #expect(try content(result).assets.count == 1)
        #expect(try JSONDecoder().decode(RulePackManifest.self, from: archive.contents(of: "manifest.json")).assetCount == 1)
    }

    @Test func aRuleWithAnOverLongNoteIsSkippedSoThePackAlwaysReimports() async throws {
        let f = Fixture(); defer { f.cleanup() }
        let long = plainRule("long", note: String(repeating: "n", count: f.limits.fieldBytes + 1))
        let ok = plainRule("ok", note: String(repeating: "n", count: f.limits.fieldBytes))
        let result = try await f.export([], [long, ok])
        #expect(result.skipped.map(\.reason) == [.noteTooLong])
        #expect(result.ruleCount == 1)
        _ = try RulePackReader.inspect(result.data, limits: f.limits)
    }

    @Test func anOverLongGroupNameFailsTheExport() async throws {
        let f = Fixture(); defer { f.cleanup() }
        let group = RuleGroup(name: String(repeating: "g", count: f.limits.fieldBytes + 1))
        await #expect(throws: RulePackError.exportTooLarge) { try await f.export([group], [plainRule("a")]) }
    }
}
