import Darwin
import FlowStore
import Foundation
import os
import Testing

@testable import RulesEngine

// R8F3 T1: `RuleRepository.installDefaultTemplates` puts the built-in template tree at the bottom of the root
// once per version, disabled, in one save, and remembers the version and the top group (`templatesVersion`,
// `templatesGroupID`). A deleted tree is not made again (ruling R8F3-2).

private struct Stack {
    var root: URL
    var configDir: URL { root.appendingPathComponent("config") }
    var configFile: URL { configDir.appendingPathComponent("rules.json") }
    var assets: ManagedAssetStore
    var repository: RuleRepository

    init(
        root: URL, limits: RulesLimits = RulesLimits(),
        fault: @escaping @Sendable (RuleRepository.Stage) throws -> Void = { _ in }
    ) {
        self.root = root
        let budgets = OwnedFileBudgets(limits: limits, freeDiskBytes: ample)
        assets = ManagedAssetStore(directory: root.appendingPathComponent("assets"), limits: limits, budgets: budgets)
        repository = RuleRepository(
            directory: root.appendingPathComponent("config"), assets: assets, limits: limits, fault: fault)
    }

    func stored() throws -> Data { try Data(contentsOf: configFile) }
    func storedJSON() throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: stored()) as? [String: Any])
    }
}

private func userRule(_ name: String, order: Int, groupID: UUID? = nil) -> Rule {
    Rule(
        id: UUID(), name: name, enabled: true, groupID: groupID, order: order,
        conditions: ConditionGroup(rows: [ConditionRow(field: .host, op: .equals, value: "user.test")]),
        actions: [RuleAction(.editHeaders(direction: .request, operations: [.set(name: "X-User", value: "1")]))])
}

private final class WriteCounter: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: 0)
    var count: Int { state.withLock { $0 } }
    func bump() { state.withLock { $0 += 1 } }
}

private func uuid(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", number))!
}

private func defaultSet() -> DefaultTemplateSet {
    DefaultTemplateCatalog.build(groupName: { "G\($0.rawValue)" }, ruleName: { "R\($0.rawValue)" })
}

private let legacyTexts = LegacyTemplateTexts(
    groupName: "Old Templates", name: { "Old \($0.rawValue)" }, note: { "note \($0.rawValue)" })

/// The first-generation group exactly as the earlier build installed it.
private func legacyGroup(order: Int) -> (RuleGroup, [Rule]) {
    let group = RuleGroup(id: UUID(), name: legacyTexts.groupName, enabled: false, parentID: nil, order: order)
    let rules = RuleTemplate.allCases.enumerated().map { index, template in
        RuleTemplateCatalog.rule(
            template, name: legacyTexts.names[template]!, note: legacyTexts.notes[template]!, order: index, groupID: group.id)
    }
    return (group, rules)
}

@Suite struct RuleRepositoryTemplatesTests {
    /// A loaded stack holding `count` user rules at root orders 0..<count and one user group at order `count`.
    private func seeded(
        _ root: URL, count: Int = 3, limits: RulesLimits = RulesLimits(),
        fault: @escaping @Sendable (RuleRepository.Stage) throws -> Void = { _ in }
    ) async throws -> (Stack, RuleSnapshot) {
        let stack = Stack(root: root, limits: limits, fault: fault)
        _ = try await stack.repository.load()
        let userGroup = RuleGroup(id: UUID(), name: "Mine", order: count)
        let rules = (0..<count).map { userRule("U\($0)", order: $0) } + [userRule("InGroup", order: 0, groupID: userGroup.id)]
        let saved = try await stack.repository.save(groups: [userGroup], rules: rules, expectedRevision: 0)
        return (stack, saved)
    }

    private func install(
        _ stack: Stack, _ set: DefaultTemplateSet = defaultSet(), legacy: LegacyTemplateTexts? = nil, at revision: UInt64
    ) async throws -> RuleSnapshot {
        try await stack.repository.installDefaultTemplates(set, legacy: legacy, expectedRevision: revision)
    }

    @Test func installOnlyOnce() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let writes = WriteCounter()
        let (stack, saved) = try await seeded(root, fault: { if $0 == .write { writes.bump() } })
        let installed = try await install(stack, at: saved.revision)
        let before = writes.count
        let bytes = try stack.stored()
        let again = try await install(stack, at: installed.revision)
        #expect(again == installed)
        #expect(writes.count == before)
        #expect(try stack.stored() == bytes)
    }

    @Test func installAddsTheTreeDisabledAtTheBottomAndRecordsVersionAndGroup() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let (stack, saved) = try await seeded(root)
        let set = defaultSet()
        let installed = try await install(stack, set, at: saved.revision)
        #expect(installed.revision == saved.revision + 1)
        #expect(installed.templatesInstalled)
        #expect(installed.templatesVersion == DefaultTemplateCatalog.currentVersion)
        #expect(installed.templatesGroupID == set.rootGroupID)
        #expect(stack.repository.provider.current() == installed)
        let top = try #require(installed.groups.first { $0.id == set.rootGroupID })
        // Root orders held 0…2 (rules) and 3 (user group).
        #expect(top.order == 4 && top.parentID == nil && !top.enabled)
        #expect(installed.groups.count == saved.groups.count + 9)
        let added = installed.rules.dropFirst(saved.rules.count)
        #expect(added.count == 28)
        // The user's own data is carried over untouched.
        #expect(installed.rules.prefix(saved.rules.count).elementsEqual(saved.rules))
        #expect(installed.groups.prefix(saved.groups.count).elementsEqual(saved.groups))
        let json = try stack.storedJSON()
        #expect(json["templatesVersion"] as? Int == 1)
        #expect(json["templatesGroupID"] as? String == set.rootGroupID.uuidString)
        #expect(try await Stack(root: root).repository.load() == installed)
        try RuleSnapshot(revision: 1, groups: installed.groups, rules: installed.rules).validateStructure(limits: RulesLimits())
    }

    @Test func theReturnFileRuleGetsARealManagedAsset() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        _ = try await stack.repository.load()
        let installed = try await install(stack, at: 0)
        let rule = try #require(installed.rules.first { $0.id == DefaultTemplateCatalog.ruleID(.fileReturnResponse) })
        guard case .returnFile(let file) = rule.actions[0].kind else { Issue.record("not a file"); return }
        #expect(file.assetID != DefaultTemplateCatalog.exampleFilePlaceholderID)
        let asset = try #require(await stack.assets.asset(file.assetID))
        #expect(asset.displayName == "example.dat" && asset.size == Int64(DefaultTemplateRules.exampleFileText.utf8.count))
        // It survives a restart (the file keeps its record).
        let restarted = Stack(root: root)
        let loaded = try await restarted.repository.load()
        #expect(loaded == installed)
        #expect(await restarted.assets.asset(file.assetID) != nil)
        #expect((try storedAssets(stack)).count == 1)
    }

    private func storedAssets(_ stack: Stack) throws -> [Any] {
        try #require(try stack.storedJSON()["assets"] as? [Any])
    }

    @Test func installOnAnEmptyRootStartsAtOrderZero() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        _ = try await stack.repository.load()
        let installed = try await install(stack, at: 0)
        #expect(installed.revision == 1)
        #expect(installed.groups.first { $0.parentID == nil }?.order == 0)
    }

    @Test func installDoesNotChangeExistingPriorities() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let (stack, saved) = try await seeded(root, count: 5)
        let before = saved.evaluationOrder
        let installed = try await install(stack, at: saved.revision)
        let after = installed.evaluationOrder
        #expect(Array(after.prefix(before.count)) == before)
        #expect(after.count == before.count)  // the top group is disabled, so none of the templates runs
    }

    @Test func aDeletedTreeIsNotRecreated() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let (stack, saved) = try await seeded(root)
        let installed = try await install(stack, at: saved.revision)
        let removed = try await stack.repository.save(
            groups: saved.groups, rules: saved.rules, expectedRevision: installed.revision)
        #expect(removed.templatesVersion == 1 && removed.templatesGroupID == installed.templatesGroupID)
        let again = try await install(stack, at: removed.revision)
        #expect(again == removed)
        #expect(again.groups == saved.groups && again.rules == saved.rules)
        // And after a restart.
        let restarted = Stack(root: root)
        let loaded = try await restarted.repository.load()
        #expect(try await install(restarted, at: loaded.revision) == loaded)
    }

    @Test func aNewerVersionInstallsAgainAndAnOlderStoredOneIsPassedOver() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let (stack, saved) = try await seeded(root)
        var set = defaultSet()
        let installed = try await install(stack, set, at: saved.revision)
        set.version = 2
        // A group of the same ids cannot be added twice: a later version brings its own ids; here it is
        // enough that a higher version is not skipped by the gate.
        set.groups = [RuleGroup(id: UUID(), name: "V2", enabled: false)]
        set.rootGroupID = set.groups[0].id
        set.rules = []
        set.assets = []
        let next = try await install(stack, set, at: installed.revision)
        #expect(next.templatesVersion == 2 && next.templatesGroupID == set.rootGroupID)
        #expect(next.groups.count == installed.groups.count + 1)
    }

    @Test func aRoundOneUserWithTheFlagButNoVersionGetsItOnce() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        try FileManager.default.createDirectory(at: stack.configDir, withIntermediateDirectories: true)
        let fixture = try Data(contentsOf: RulesFileByteIdenticalR6Tests.r5FixtureURL)
        var object = try #require(try JSONSerialization.jsonObject(with: fixture) as? [String: Any])
        object["templatesInstalled"] = true
        writeFile(stack.configFile, try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
        let loaded = try await stack.repository.load()
        #expect(loaded.templatesInstalled && loaded.templatesVersion == nil)
        let installed = try await install(stack, at: loaded.revision)
        #expect(installed.templatesVersion == 1 && installed.groups.count == loaded.groups.count + 9)
        #expect(try await install(stack, at: installed.revision) == installed)
    }

    // MARK: the first-generation group (R8F3-3)

    @Test func anUntouchedFirstGenerationGroupIsReplacedInPlace() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        _ = try await stack.repository.load()
        let (old, oldRules) = legacyGroup(order: 1)
        let mine = userRule("mine", order: 0)
        let saved = try await stack.repository.save(groups: [old], rules: [mine] + oldRules, expectedRevision: 0)
        let set = defaultSet()
        let installed = try await install(stack, set, legacy: legacyTexts, at: saved.revision)
        #expect(!installed.groups.contains { $0.id == old.id })
        #expect(installed.rules.allSatisfy { $0.groupID != old.id })
        #expect(installed.rules.contains { $0.id == mine.id })
        let top = try #require(installed.groups.first { $0.id == set.rootGroupID })
        #expect(top.order == 1, "the new tree takes the place of the old group")
        #expect(installed.groups.count == 9 && installed.rules.count == 1 + 28)
    }

    @Test func aChangedFirstGenerationGroupStaysAndTheNewTreeComesAfter() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let edits: [(String, @Sendable (inout RuleGroup, inout [Rule]) -> Void)] = [
            ("renamed rule", { _, rules in rules[3].name = "changed" }),
            ("enabled rule", { _, rules in rules[0].enabled = true }),
            ("edited action", { _, rules in rules[2].actions = [RuleAction(.hide)] }),
            ("enabled group", { group, _ in group.enabled = true }),
            ("renamed group", { group, _ in group.name = "Mine" }),
            ("extra rule", { group, rules in rules.append(userRule("extra", order: 15, groupID: group.id)) }),
            ("removed rule", { _, rules in rules.removeLast() }),
            ("note changed", { _, rules in rules[1].note = "mine" }),
        ]
        for (label, edit) in edits {
            let dir = root.appendingPathComponent(label.replacingOccurrences(of: " ", with: "-"))
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let stack = Stack(root: dir)
            _ = try await stack.repository.load()
            var (old, oldRules) = legacyGroup(order: 0)
            edit(&old, &oldRules)
            let saved = try await stack.repository.save(groups: [old], rules: oldRules, expectedRevision: 0)
            let set = defaultSet()
            let installed = try await install(stack, set, legacy: legacyTexts, at: saved.revision)
            #expect(installed.groups.contains { $0.id == old.id }, "\(label)")
            #expect(installed.rules.filter { $0.groupID == old.id }.count == oldRules.count, "\(label)")
            #expect(installed.groups.first { $0.id == set.rootGroupID }?.order == 1, "\(label)")
            #expect(installed.groups.count == 10, "\(label)")
        }
    }

    @Test func aSubgroupInsideTheFirstGenerationGroupKeepsIt() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        _ = try await stack.repository.load()
        let (old, oldRules) = legacyGroup(order: 0)
        let child = RuleGroup(id: UUID(), name: "child", parentID: old.id, order: 15)
        let saved = try await stack.repository.save(groups: [old, child], rules: oldRules, expectedRevision: 0)
        let installed = try await install(stack, legacy: legacyTexts, at: saved.revision)
        #expect(installed.groups.contains { $0.id == old.id } && installed.groups.contains { $0.id == child.id })
    }

    @Test func withoutTheOldTextsNothingIsReplaced() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        _ = try await stack.repository.load()
        let (old, oldRules) = legacyGroup(order: 0)
        let saved = try await stack.repository.save(groups: [old], rules: oldRules, expectedRevision: 0)
        let installed = try await install(stack, legacy: nil, at: saved.revision)
        #expect(installed.groups.contains { $0.id == old.id } && installed.groups.count == 10)
    }

    // MARK: limits and failures

    @Test func skipsWhenItWouldExceedTheRuleCap() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        _ = try await stack.repository.load()
        let full = (0..<490).map { userRule("U\($0)", order: $0) }
        let saved = try await stack.repository.save(groups: [], rules: full, expectedRevision: 0)
        let result = try await install(stack, at: saved.revision)
        #expect(result.templatesInstalled && result.templatesVersion == 1 && result.templatesGroupID == nil)
        #expect(result.revision == saved.revision + 1)
        #expect(result.rules == saved.rules && result.groups == saved.groups)
        #expect(try await install(stack, at: result.revision) == result, "not tried again")
    }

    @Test func aStoredFileLargerThanTheCapIsNotGrownButIsMarked() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let small = RulesLimits(ruleCount: 4)
        let stack = Stack(root: root, limits: small)
        _ = try await stack.repository.load()
        let saved = try await stack.repository.save(
            groups: [], rules: (0..<4).map { userRule("U\($0)", order: $0) }, expectedRevision: 0)
        let result = try await install(stack, at: saved.revision)
        #expect(result.templatesVersion == 1 && result.rules == saved.rules && result.groups.isEmpty)
    }

    @Test func aTemplateThatDoesNotValidateOnlyRecordsTheVersion() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let (stack, saved) = try await seeded(root)
        var set = defaultSet()
        set.rules[3].actions = []
        let result = try await install(stack, set, at: saved.revision)
        #expect(result.templatesVersion == 1 && result.templatesGroupID == nil)
        #expect(result.rules == saved.rules && result.groups == saved.groups)
    }

    @Test func staleRevisionThrowsConflict() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let (stack, saved) = try await seeded(root)
        let bytes = try stack.stored()
        let error = await #expect(throws: RuleRepositoryError.self) {
            _ = try await install(stack, at: saved.revision - 1)
        }
        #expect(error == .conflict(current: saved))
        #expect(try stack.stored() == bytes)
        #expect(stack.repository.provider.current().templatesVersion == nil)
    }

    @Test func unavailableConfigurationRefuses() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        try FileManager.default.createDirectory(at: stack.configDir, withIntermediateDirectories: true)
        writeFile(stack.configFile, Data("{ not json".utf8))
        await #expect(throws: RuleRepositoryError.unavailable(.corrupt)) { _ = try await stack.repository.load() }
        await #expect(throws: RuleRepositoryError.unavailable(.corrupt)) { _ = try await install(stack, at: 0) }
        #expect(try stack.stored() == Data("{ not json".utf8))
    }

    @Test func aNewerBuildsFileIsRefusedAndLeftAsItIs() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        try FileManager.default.createDirectory(at: stack.configDir, withIntermediateDirectories: true)
        let future = Data(#"{"assets":[],"revision":3,"rules":[],"schemaVersion":99}"#.utf8)
        writeFile(stack.configFile, future)
        await #expect(throws: RuleRepositoryError.unavailable(.unsupportedSchema)) { _ = try await stack.repository.load() }
        await #expect(throws: RuleRepositoryError.unavailable(.unsupportedSchema)) { _ = try await install(stack, at: 3) }
        #expect(try stack.stored() == future)
    }

    @Test func aFileTooSmallForTheTemplatesStillRecordsTheVersion() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let (first, saved) = try await seeded(root)
        let size = try first.stored().count
        // Room for the version, not for the template rules.
        let tight = Stack(root: root, limits: RulesLimits(configBytes: size + 160))
        _ = try await tight.repository.load()
        let result = try await install(tight, at: saved.revision)
        #expect(result.templatesVersion == 1 && result.templatesGroupID == nil)
        #expect(result.rules.count == saved.rules.count && result.groups.count == saved.groups.count)
        #expect(try tight.storedJSON()["templatesVersion"] as? Int == 1)
        // The imported file is not left behind.
        #expect((try storedAssets(tight)).isEmpty)
        #expect(await tight.assets.asset(DefaultTemplateCatalog.exampleFilePlaceholderID) == nil)
    }

    @Test func notLoadedRefuses() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        await #expect(throws: RuleRepositoryError.notLoaded) { _ = try await install(stack, at: 0) }
        #expect(!FileManager.default.fileExists(atPath: stack.configFile.path))
    }

    @Test func theTopGroupIsForcedToTheRootAtTheBottom() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let (stack, saved) = try await seeded(root)
        var set = defaultSet()
        set.groups[0].parentID = saved.groups[0].id
        set.groups[0].order = -5
        let installed = try await install(stack, set, at: saved.revision)
        let top = try #require(installed.groups.first { $0.id == set.rootGroupID })
        #expect(top.parentID == nil && !top.enabled && top.order == 4)
    }

    @Test func ordinarySaveKeepsTheVersionAndOmitsItWhenAbsent() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let (stack, saved) = try await seeded(root)
        #expect(saved.templatesVersion == nil)
        let json = try stack.storedJSON()
        #expect(json["templatesVersion"] == nil && json["templatesGroupID"] == nil)
        let installed = try await install(stack, at: saved.revision)
        let after = try await stack.repository.save(
            groups: installed.groups, rules: installed.rules, expectedRevision: installed.revision)
        #expect(after.templatesVersion == 1 && after.templatesGroupID == installed.templatesGroupID)
    }

    @Test func saveBytesAreUnchangedForAnOrdinarySave() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        try FileManager.default.createDirectory(at: stack.configDir, withIntermediateDirectories: true)
        let fixture = try Data(contentsOf: RulesFileByteIdenticalR6Tests.r5FixtureURL)
        writeFile(stack.configFile, fixture)
        let loaded = try await stack.repository.load()
        let saved = try await stack.repository.save(
            groups: loaded.groups, rules: loaded.rules, expectedRevision: loaded.revision)
        var expected = try #require(try JSONSerialization.jsonObject(with: fixture) as? [String: Any])
        expected["revision"] = saved.revision
        #expect(NSDictionary(dictionary: try stack.storedJSON()).isEqual(to: expected))
        let reencoded = try RuleStorage.encode(RuleStorage.Configuration(snapshot: saved, assets: []))
        #expect(try stack.stored() == reencoded)
        #expect(!saved.templatesInstalled && saved.templatesVersion == nil)
    }

    @Test func migratedFileCanReceiveTemplatesAndKeepsItsNotice() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        try FileManager.default.createDirectory(at: stack.configDir, withIntermediateDirectories: true)
        let asset = ManagedAsset(
            id: uuid(0xA55E7), size: 5, displayName: "a.json", importedAt: Date(timeIntervalSinceReferenceDate: 0))
        let lower = LegacyRule(
            id: uuid(1), name: "header", enabled: true, order: 1, matcher: RuleMatcher(hostPattern: "a.test"),
            action: .editHeaders(direction: .response, operations: [.set(name: "X-Test", value: "1")]))
        let higher = LegacyRule(
            id: uuid(2), name: "local", enabled: true, order: 0, matcher: RuleMatcher(hostPattern: "a.test"),
            action: .mapLocal(MapLocalAction(assetID: asset.id, headers: [])))
        struct LegacyFile: Encodable {
            var schemaVersion: Int, revision: UInt64, rules: [LegacyRule], assets: [ManagedAsset]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        writeFile(
            stack.configFile,
            try encoder.encode(LegacyFile(schemaVersion: 3, revision: 1, rules: [lower, higher], assets: [asset])))
        let migrated = try await stack.repository.load()
        let notice = try #require(migrated.migrationNotice)
        let installed = try await install(stack, at: migrated.revision)
        #expect(installed.templatesInstalled && installed.migrationNotice == notice)
        #expect(installed.evaluationOrder.map(\.id) == migrated.evaluationOrder.map(\.id))
        #expect(try await Stack(root: root).repository.load().migrationNotice == notice)
    }

    @Test func failedWriteRecordsNothingAndLeavesNoAssetBehind() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let armed = LockedFlag()
        let failure = OwnedFileError(.ioFailure, errno: EIO)
        let (stack, saved) = try await seeded(root, fault: { stage in
            if stage == .rename, armed.value { throw failure }
        })
        let bytes = try stack.stored()
        armed.value = true
        await #expect(throws: RuleRepositoryError.storage(failure)) { _ = try await install(stack, at: saved.revision) }
        #expect(stack.repository.provider.current() == saved)
        #expect(stack.repository.provider.current().templatesVersion == nil)
        #expect(try stack.stored() == bytes)
        #expect(names(in: stack.configDir) == ["rules.json"])
        armed.value = false
        let retried = try await install(stack, at: saved.revision)
        #expect(retried.templatesVersion == 1 && retried.revision == saved.revision + 1)
    }
}
