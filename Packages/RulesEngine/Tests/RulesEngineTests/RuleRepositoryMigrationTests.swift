import Darwin
import FlowStore
import Foundation
import Testing

@testable import RulesEngine

// Rules 2.0 R1, Task 7: `rules.json` schema 4, the one-time migration of schema 1…3 files (backup first,
// then an atomic write), and saves that always write schema 4 (spec 5.1, 5.6.1; plan D10–D14).

private struct Stack {
    var root: URL
    var limits: RulesLimits
    var configDir: URL { root.appendingPathComponent("config") }
    var assetsDir: URL { root.appendingPathComponent("assets") }
    var configFile: URL { configDir.appendingPathComponent("rules.json") }
    var assets: ManagedAssetStore
    var repository: RuleRepository

    init(
        root: URL, limits: RulesLimits = RulesLimits(),
        fault: @escaping @Sendable (RuleRepository.Stage) throws -> Void = { _ in }
    ) {
        self.root = root
        self.limits = limits
        let budgets = OwnedFileBudgets(limits: limits, freeDiskBytes: ample)
        assets = ManagedAssetStore(directory: root.appendingPathComponent("assets"), limits: limits, budgets: budgets)
        repository = RuleRepository(
            directory: root.appendingPathComponent("config"), assets: assets, limits: limits, fault: fault)
    }

    func write(_ data: Data) throws {
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        writeFile(configFile, data)
    }

    func stored() throws -> Data { try Data(contentsOf: configFile) }

    func storedText() throws -> String { try String(contentsOf: configFile, encoding: .utf8) }

    func storedJSON() throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: stored()) as? [String: Any])
    }

    /// Migration backups, oldest name first.
    func backups() -> [String] {
        names(in: configDir).filter { $0.hasPrefix("rules.v") && $0.contains("-backup-") }.sorted()
    }

    func importAsset(_ name: String, _ data: Data = randomData(100)) async throws -> ManagedAsset {
        let source = writeFile(root.appendingPathComponent(name), data)
        return try await assets.importFile(source, displayName: name)
    }
}

/// The shape every schema 1…3 file had: synthesized keys, written sorted like the old repository did.
private struct LegacyFile: Encodable {
    var schemaVersion: Int
    var revision: UInt64
    var rules: [LegacyRule]
    var assets: [ManagedAsset]
}

private func legacyFile(schema: Int, revision: UInt64, rules: [LegacyRule], assets: [ManagedAsset] = []) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(LegacyFile(schemaVersion: schema, revision: revision, rules: rules, assets: assets))
}

private func uuid(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", number))!
}

private func headerRule(
    _ number: Int, order: Int = 0, host: String? = "a.test", enabled: Bool = true, name: String = "header"
) -> LegacyRule {
    LegacyRule(
        id: uuid(number), name: name, enabled: enabled, order: order, matcher: RuleMatcher(hostPattern: host),
        action: .editHeaders(direction: .response, operations: [.set(name: "X-Test", value: "1")]))
}

private func localRule(_ number: Int, asset: UUID, order: Int = 0, host: String? = "a.test", enabled: Bool = true) -> LegacyRule {
    LegacyRule(
        id: uuid(number), name: "local", enabled: enabled, order: order, matcher: RuleMatcher(hostPattern: host),
        action: .mapLocal(MapLocalAction(assetID: asset, headers: [])))
}

private let fixedAsset = ManagedAsset(
    id: uuid(0xA55E7), size: 5, displayName: "a.json", importedAt: Date(timeIntervalSinceReferenceDate: 0))

/// `rules.v<schema>-backup-<yyyyMMddTHHmmssZ>-<UUID>.json` (spec 5.6.1 plus D12's UUID suffix).
private func isBackupName(_ name: String, schema: Int) -> Bool {
    name.range(
        of: #"^rules\.v\#(schema)-backup-[0-9]{8}T[0-9]{6}Z-[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\.json$"#,
        options: .regularExpression) != nil
}

/// A 2.0 rule the old model cannot state: a request header edit and a status rewrite.
private func multiActionRule(_ number: Int, groupID: UUID? = nil, order: Int = 0) -> Rule {
    Rule(
        id: uuid(number), name: "multi", groupID: groupID, order: order,
        conditions: ConditionGroup(rows: [ConditionRow(field: .host, op: .hostPattern, value: "a.test")]),
        actions: [
            RuleAction(.editHeaders(direction: .request, operations: [.set(name: "X-A", value: "1")])),
            RuleAction(.rewriteStatus(RewriteStatusAction(status: 201))),
        ])
}

@Suite struct RuleRepositoryMigrationTests {
    // MARK: migration

    @Test func schema3FileMigratesToSchema4WithByteExactBackup() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        let status = LegacyRule(
            id: uuid(1), name: "status", enabled: false, order: 2, matcher: RuleMatcher(hostPattern: "a.test"),
            action: .rewriteStatus(RewriteStatusAction(status: 404)))
        let body = LegacyRule(
            id: uuid(2), name: "body", enabled: true, order: 1, matcher: RuleMatcher(hostPattern: "a.test"),
            action: .rewriteBody(direction: .response, BodyRewriteAction(find: "foo", replacement: "bar")))
        let late = headerRule(3, order: 1)
        // Array order is not evaluation order: (order, array position) gives body, late, status.
        let original = try legacyFile(schema: 3, revision: 7, rules: [status, body, late])
        try stack.write(original)

        let snapshot = try await stack.repository.load()
        #expect(snapshot.schemaVersion == 4)
        #expect(snapshot.revision == 8)
        #expect(snapshot.rules.map(\.id) == [body.id, late.id, status.id])
        #expect(snapshot.rules.map(\.order) == [0, 1, 2])
        #expect(snapshot.rules.allSatisfy { $0.groupID == nil })
        #expect(snapshot.groups.isEmpty)
        #expect(!snapshot.templatesInstalled)
        #expect(snapshot.migrationNotice == nil)  // a body rewrite changes nothing a later condition reads
        var expected = [body, late, status].map(Rule.init(migrating:))
        for index in expected.indices { expected[index].order = index }
        #expect(snapshot.rules == expected)
        #expect(stack.repository.provider.current() == snapshot)

        let backups = stack.backups()
        #expect(backups.count == 1)
        let backup = try #require(backups.first)
        #expect(isBackupName(backup, schema: 3), "\(backup)")
        let backupFile = stack.configDir.appendingPathComponent(backup)
        #expect(try Data(contentsOf: backupFile) == original)
        #expect(mode(of: backupFile) == 0o600)
        #expect(mode(of: stack.configFile) == 0o600)
        #expect(names(in: stack.configDir) == ["rules.json", backup])  // no temp file left behind

        let json = try stack.storedJSON()
        #expect(json["schemaVersion"] as? Int == 4)
        #expect(json["revision"] as? Int == 8)
        #expect(Set(json.keys) == ["schemaVersion", "revision", "groups", "rules", "assets", "templatesInstalled"])

        // A restart reads the schema 4 file as it is: no second migration, no second backup.
        let restarted = Stack(root: root)
        #expect(try await restarted.repository.load() == snapshot)
        #expect(restarted.backups() == backups)
    }

    @Test func schema1And2FilesMigrate() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let v1 = Stack(root: root)
        let v1Text = #"{"assets":[],"revision":4,"rules":["# + goldenLiteralRuleJSON + #"],"schemaVersion":1}"#
        try v1.write(Data(v1Text.utf8))
        let fromV1 = try await v1.repository.load()
        var golden = Rule(migrating: goldenLiteralRule)
        golden.order = 0
        #expect(fromV1.revision == 5 && fromV1.rules == [golden])
        #expect(v1.backups().count == 1 && isBackupName(v1.backups()[0], schema: 1))
        #expect(try Data(contentsOf: v1.configDir.appendingPathComponent(v1.backups()[0])) == Data(v1Text.utf8))
        #expect(v1.repository.provider.current().rules == fromV1.rules)

        let other = makeTempDirectory(); defer { removeTree(other) }
        let v2 = Stack(root: other)
        let advanced = #"{"action":{"breakpoint":{"direction":"request","mode":"headers"}},"enabled":true,"id":"00000000-0000-0000-0000-0000000000B2","matcher":{"hostPattern":"(a|b)\\.example\\.com","hostSyntax":"regex","path":{"wildcard":{"_0":"\/api\/*"}}},"name":"advanced","order":0}"#
        let v2Text = #"{"assets":[],"revision":2,"rules":["# + advanced + #"],"schemaVersion":2}"#
        try v2.write(Data(v2Text.utf8))
        let fromV2 = try await v2.repository.load()
        let advancedRule = LegacyRule(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!, name: "advanced", enabled: true, order: 0,
            matcher: RuleMatcher(hostPattern: #"(a|b)\.example\.com"#, path: .wildcard("/api/*"), hostSyntax: .regex),
            action: .breakpoint(direction: .request, mode: .headers))
        #expect(fromV2.revision == 3 && fromV2.rules == [Rule(migrating: advancedRule)])
        #expect(v2.backups().count == 1 && isBackupName(v2.backups()[0], schema: 2))
        #expect(try Data(contentsOf: v2.configDir.appendingPathComponent(v2.backups()[0])) == Data(v2Text.utf8))
    }

    @Test func noticeStoredWhenAPairExists() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        // The Map Local is stored after the lower-priority header rule but runs first (order 0): the
        // analysis must see the rules in evaluation order to find the pair.
        let lower = headerRule(1, order: 1)
        let higher = localRule(2, asset: fixedAsset.id, order: 0)
        try stack.write(try legacyFile(schema: 3, revision: 1, rules: [lower, higher], assets: [fixedAsset]))

        let snapshot = try await stack.repository.load()
        let notice = try #require(snapshot.migrationNotice)
        #expect(notice.report.pairs == [MigrationPair(changeClass: .finalAction, higherRuleID: higher.id, lowerRuleID: lower.id)])
        #expect(!notice.acknowledged)
        #expect(notice.migratedFromSchema == 3)
        #expect(notice.omittedPairCount == 0)
        #expect(snapshot.rules.map(\.id) == [higher.id, lower.id])
        // Stored, so a restart still shows it.
        #expect(try await Stack(root: root).repository.load().migrationNotice == notice)
    }

    @Test func noNoticeWhenNoPairOrNoRules() async throws {
        let cases: [[LegacyRule]] = [
            [],
            [headerRule(1), headerRule(2, order: 1)],
            // D13: a disabled rule has no behaviour that could change.
            [localRule(1, asset: fixedAsset.id, enabled: false), headerRule(2, order: 1)],
            [localRule(1, asset: fixedAsset.id), headerRule(2, order: 1, enabled: false)],
            // Provably disjoint hosts.
            [localRule(1, asset: fixedAsset.id, host: "a.test"), headerRule(2, order: 1, host: "b.test")],
        ]
        for rules in cases {
            let root = makeTempDirectory(); defer { removeTree(root) }
            let stack = Stack(root: root)
            try stack.write(try legacyFile(schema: 3, revision: 3, rules: rules, assets: [fixedAsset]))
            let snapshot = try await stack.repository.load()
            #expect(snapshot.revision == 4)
            #expect(snapshot.rules.count == rules.count)
            #expect(snapshot.migrationNotice == nil)
            #expect(try stack.storedJSON()["migrationNotice"] == nil)
            #expect(stack.backups().count == 1)
        }
    }

    @Test func migratedFileGoldenShowsEverySchema4Key() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        let higher = localRule(1, asset: fixedAsset.id)
        let lower = headerRule(2, order: 1)
        try stack.write(try legacyFile(schema: 3, revision: 6, rules: [higher, lower], assets: [fixedAsset]))
        _ = try await stack.repository.load()
        let golden = #"{"assets":[{"displayName":"a.json","id":"00000000-0000-0000-0000-0000000A55E7","importedAt":0,"size":5}],"groups":[],"migrationNotice":{"acknowledged":false,"migratedFromSchema":3,"omittedPairCount":0,"report":{"pairs":[{"changeClass":1,"higherRuleID":"00000000-0000-0000-0000-000000000001","lowerRuleID":"00000000-0000-0000-0000-000000000002"}]}},"revision":7,"rules":[{"actions":[{"isFinal":false,"kind":{"returnFile":{"_0":{"assetID":"00000000-0000-0000-0000-0000000A55E7","headers":[],"status":200}}}}],"conditions":{"mode":"all","occurrence":{"any":{}},"rows":[{"caseSensitive":false,"field":"host","op":"hostPattern","value":"a.test"}]},"enabled":true,"id":"00000000-0000-0000-0000-000000000001","name":"local","order":0},{"actions":[{"isFinal":false,"kind":{"editHeaders":{"direction":"response","operations":[{"set":{"name":"X-Test","value":"1"}}]}}}],"conditions":{"mode":"all","occurrence":{"any":{}},"rows":[{"caseSensitive":false,"field":"host","op":"hostPattern","value":"a.test"}]},"enabled":true,"id":"00000000-0000-0000-0000-000000000002","name":"header","order":1}],"schemaVersion":4,"templatesInstalled":false}"#
        #expect(try stack.storedText() == golden)
        // The Return File's asset stays referenced (spec 5.1 `assets`): the record is adopted, nothing swept.
        #expect(await stack.assets.asset(fixedAsset.id) == fixedAsset)
    }

    @Test func schema4FileLoadsWithoutBackup() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let first = Stack(root: root)
        _ = try await first.repository.load()
        let saved = try await first.repository.save(
            groups: [], rules: [Rule(migrating: headerRule(1))], expectedRevision: 0)
        let restarted = Stack(root: root)
        #expect(try await restarted.repository.load() == saved)
        #expect(names(in: restarted.configDir) == ["rules.json"])
    }

    @Test func schema5IsUnsupportedAndLeftUntouched() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        let text = #"{"assets":[],"groups":[],"revision":9,"rules":[],"schemaVersion":5,"templatesInstalled":false}"#
        try stack.write(Data(text.utf8))
        await #expect(throws: RuleRepositoryError.unavailable(.unsupportedSchema)) {
            _ = try await stack.repository.load()
        }
        #expect(try stack.storedText() == text)
        #expect(names(in: stack.configDir) == ["rules.json"])
        await #expect(throws: RuleRepositoryError.unavailable(.unsupportedSchema)) {
            _ = try await stack.repository.save(groups: [], rules: [], expectedRevision: 0)
        }
    }

    /// Ruling (phase review I2): a file that says schema 4 and is valid JSON but does not decode here (a
    /// later phase added a stored case inside schema 4) is unsupported, not corrupt: untouched, saving
    /// refused, and no reset, which would clear rules a newer version still reads. A cut-off file is
    /// still corrupt and can be reset (backed up first).
    @Test func schema4ThatDoesNotDecodeIsUnsupportedAndNeverReset() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let writer = Stack(root: root)
        _ = try await writer.repository.load()
        _ = try await writer.repository.save(groups: [], rules: [Rule(migrating: headerRule(1))], expectedRevision: 0)
        // The same file with a case of action this version has never heard of.
        let future = try writer.storedText().replacingOccurrences(of: "editHeaders", with: "quantumLeap")
        #expect(future.contains("quantumLeap"))
        try writer.write(Data(future.utf8))

        let stack = Stack(root: root)
        await #expect(throws: RuleRepositoryError.unavailable(.unsupportedSchema)) { _ = try await stack.repository.load() }
        await #expect(throws: RuleRepositoryError.unavailable(.unsupportedSchema)) {
            _ = try await stack.repository.save(groups: [], rules: [], expectedRevision: 0)
        }
        await #expect(throws: RuleRepositoryError.unavailable(.unsupportedSchema)) {
            _ = try await stack.repository.resetUnreadableConfiguration()
        }
        #expect(try stack.storedText() == future)
        #expect(names(in: stack.configDir) == ["rules.json"], "no backup, nothing replaced")

        // Valid JSON of schema 4 that lacks the keys this version stores is the same case.
        let missingKeys = Stack(root: makeTempDirectory())
        defer { removeTree(missingKeys.root) }
        let text = #"{"assets":[],"revision":3,"rules":[],"schemaVersion":4}"#
        try missingKeys.write(Data(text.utf8))
        await #expect(throws: RuleRepositoryError.unavailable(.unsupportedSchema)) {
            _ = try await missingKeys.repository.load()
        }
        #expect(try missingKeys.storedText() == text)
    }

    @Test func schema5IsNeverReset() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        let text = #"{"assets":[],"groups":[],"revision":9,"rules":[],"schemaVersion":5,"templatesInstalled":false}"#
        try stack.write(Data(text.utf8))
        await #expect(throws: RuleRepositoryError.unavailable(.unsupportedSchema)) { _ = try await stack.repository.load() }
        await #expect(throws: RuleRepositoryError.unavailable(.unsupportedSchema)) {
            _ = try await stack.repository.resetUnreadableConfiguration()
        }
        #expect(try stack.storedText() == text)
        #expect(names(in: stack.configDir) == ["rules.json"])
    }

    @Test func cutOffSchema4FileIsCorruptAndResetBacksItUp() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        let text = #"{"assets":[],"groups":[],"revision":9,"rules":[{"actions":"#
        try stack.write(Data(text.utf8))
        await #expect(throws: RuleRepositoryError.unavailable(.corrupt)) { _ = try await stack.repository.load() }
        let reset = try await stack.repository.resetUnreadableConfiguration()
        #expect(try Data(contentsOf: stack.configDir.appendingPathComponent(try #require(reset.backupName))) == Data(text.utf8))
        #expect(reset.snapshot.rules.isEmpty)
    }

    // MARK: nothing irreversible before the result reads back (phase review MF3)

    /// The migrated file replaces the user's file after its backup; it must be one a load accepts. The
    /// bytes are decoded back and run through the checks a load runs, and a failure there is a failed
    /// migration (old file untouched, retry offered), not a file nobody can read.
    @Test func migratedBytesMustReadBackThroughTheLoadChecks() throws {
        let limits = RulesLimits()
        let good = RuleStorage.Configuration(
            snapshot: RuleSnapshot(revision: 5, rules: [Rule(migrating: headerRule(1))]), assets: [])
        try RuleStorage.verifyReadBack(try RuleStorage.encode(good), limits: limits)

        // Not the file that was meant to be written: cut off, a rule in a group that does not exist, a
        // revision no save could follow.
        let encoded = try RuleStorage.encode(good)
        var unknownGroup = good
        unknownGroup.rules[0].groupID = uuid(99)
        var exhausted = good
        exhausted.revision = UInt64.max
        for bad in [
            encoded.prefix(encoded.count / 2), Data(),
            try RuleStorage.encode(unknownGroup), try RuleStorage.encode(exhausted),
        ] {
            #expect(throws: RuleConfigurationProblem.migrationFailed) {
                try RuleStorage.verifyReadBack(Data(bad), limits: limits)
            }
        }
    }

    // MARK: the cause of a failed migration is logged without content (phase review MF2)

    @Test func migrationFailureIsDescribedByKindOnly() {
        #expect(
            RuleRepository.migrationFailureKind(OwnedFileError(.insufficientDiskSpace, errno: ENOSPC))
                == "insufficientDiskSpace errno=\(ENOSPC)")
        #expect(
            RuleRepository.migrationFailureKind(RuleRepositoryError.storage(OwnedFileError(.ioFailure, errno: EIO)))
                == "storage ioFailure errno=\(EIO)")
        #expect(RuleRepository.migrationFailureKind(OwnedFileError(.sourceChanged)) == "sourceChanged")
        struct Secret: Error, CustomStringConvertible { var description: String { "/Users/someone/rules.json" } }
        #expect(RuleRepository.migrationFailureKind(Secret()).contains("someone") == false)
        #expect(RuleRepository.migrationFailureKind(Secret()) == "Secret")
    }

    @Test func truncatedAndCorruptFilesStayUnavailable() async throws {
        let valid = try legacyFile(schema: 3, revision: 2, rules: [headerRule(1), headerRule(2, order: 1)])
        let emptyFind = LegacyRule(
            id: uuid(3), name: "body", enabled: true, order: 0, matcher: RuleMatcher(),
            action: .rewriteBody(direction: .response, BodyRewriteAction(find: "", replacement: "x")))
        let rowJSON = #"{"caseSensitive":false,"field":"host","op":"hostPattern","value":"a.test"}"#
        let actionJSON = #"{"isFinal":false,"kind":{"breakpoint":{"direction":"request","mode":"headers"}}}"#
        func schema4(rules: String, groups: String = "[]") -> Data {
            Data(#"{"assets":[],"groups":\#(groups),"revision":3,"rules":\#(rules),"schemaVersion":4,"templatesInstalled":false}"#.utf8)
        }
        let unknownGroup = #"[{"actions":[\#(actionJSON)],"conditions":{"mode":"all","occurrence":{"any":{}},"rows":[\#(rowJSON)]},"enabled":true,"groupID":"00000000-0000-0000-0000-000000000099","id":"00000000-0000-0000-0000-000000000001","name":"x","order":0}]"#
        let noActions = #"[{"actions":[],"conditions":{"mode":"all","occurrence":{"any":{}},"rows":[]},"enabled":true,"id":"00000000-0000-0000-0000-000000000001","name":"x","order":0}]"#
        let duplicateIDs = #"[{"actions":[\#(actionJSON)],"conditions":{"mode":"all","occurrence":{"any":{}},"rows":[]},"enabled":true,"id":"00000000-0000-0000-0000-000000000001","name":"x","order":0},{"actions":[\#(actionJSON)],"conditions":{"mode":"all","occurrence":{"any":{}},"rows":[]},"enabled":true,"id":"00000000-0000-0000-0000-000000000001","name":"y","order":1}]"#
        let contents: [Data] = [
            valid.prefix(valid.count / 2),
            try legacyFile(schema: 3, revision: 2, rules: [emptyFind]),
            // An old file whose rules share an id would fail the schema 4 checks once migrated.
            try legacyFile(schema: 3, revision: 2, rules: [headerRule(1), headerRule(1, order: 1)]),
            // The migrated revision would be the maximum, which no later save could follow.
            try legacyFile(schema: 1, revision: UInt64.max - 1, rules: []),
            schema4(rules: unknownGroup),
            schema4(rules: noActions),
            schema4(rules: duplicateIDs),
        ]
        for data in contents {
            let root = makeTempDirectory(); defer { removeTree(root) }
            let stack = Stack(root: root)
            try stack.write(data)
            await #expect(throws: RuleRepositoryError.unavailable(.corrupt)) { _ = try await stack.repository.load() }
            #expect(try stack.stored() == data)
            #expect(names(in: stack.configDir) == ["rules.json"])
            #expect(stack.repository.provider.current() == RuleSnapshot(revision: 0, rules: []))
            await #expect(throws: RuleRepositoryError.unavailable(.corrupt)) {
                _ = try await stack.repository.save(groups: [], rules: [], expectedRevision: 0)
            }
        }
    }

    @Test func oversizedFileIsTooLarge() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let original = try legacyFile(schema: 3, revision: 2, rules: (0..<5).map { headerRule($0, order: $0) })
        let stack = Stack(root: root, limits: RulesLimits(configBytes: original.count - 1))
        try stack.write(original)
        await #expect(throws: RuleRepositoryError.unavailable(.tooLarge)) { _ = try await stack.repository.load() }
        #expect(try stack.stored() == original)
        #expect(names(in: stack.configDir) == ["rules.json"])
    }

    /// Ruling (Task 7): a schema 4 file is larger than the old file it replaces. When the migrated rules
    /// alone would not fit `configBytes`, nothing is backed up or written (the result could never be read
    /// back): the file is too large, and the explicit reset (which backs it up) stays available.
    @Test func migrationThatCannotFitIsTooLargeAndWritesNothing() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let original = try legacyFile(schema: 3, revision: 2, rules: (0..<5).map { headerRule($0, order: $0) })
        let stack = Stack(root: root, limits: RulesLimits(configBytes: original.count))
        try stack.write(original)
        await #expect(throws: RuleRepositoryError.unavailable(.tooLarge)) { _ = try await stack.repository.load() }
        #expect(try stack.stored() == original)
        #expect(names(in: stack.configDir) == ["rules.json"])
        let reset = try await stack.repository.resetUnreadableConfiguration()
        #expect(try Data(contentsOf: stack.configDir.appendingPathComponent(try #require(reset.backupName))) == original)
    }

    // MARK: the notice is bounded (Task 7 ruling)

    /// Ruling (Task 7): the analysis is quadratic, so the stored list is capped at
    /// `RulesLimits.migrationNoticePairs`. Every affected lower rule (per class) is listed with its
    /// highest-priority cause before any second cause, and the pairs left out are counted, never dropped
    /// silently.
    @Test func cappedNoticeNamesEveryAffectedRuleFirstAndCountsTheRest() async throws {
        let r1 = localRule(1, asset: fixedAsset.id, order: 0, host: "a.test")
        let r2 = localRule(2, asset: fixedAsset.id, order: 1, host: "*.test")
        let l1 = headerRule(3, order: 2, host: "a.test")
        let l2 = headerRule(4, order: 3, host: "b.test")
        let full = MigrationAnalyzer.report(for: [r1, r2, l1, l2]).pairs
        func pair(_ higher: LegacyRule, _ lower: LegacyRule) -> MigrationPair {
            MigrationPair(changeClass: .finalAction, higherRuleID: higher.id, lowerRuleID: lower.id)
        }
        #expect(full == [pair(r1, r2), pair(r1, l1), pair(r2, l1), pair(r2, l2)])

        for (cap, listed) in [(3, [pair(r1, r2), pair(r1, l1), pair(r2, l2)]), (2, [pair(r1, r2), pair(r1, l1)]), (4, full)] {
            let root = makeTempDirectory(); defer { removeTree(root) }
            let stack = Stack(root: root, limits: RulesLimits(migrationNoticePairs: cap))
            try stack.write(try legacyFile(schema: 3, revision: 1, rules: [r1, r2, l1, l2], assets: [fixedAsset]))
            let notice = try #require(try await stack.repository.load().migrationNotice)
            #expect(notice.report.pairs == listed, "cap \(cap)")
            #expect(notice.omittedPairCount == full.count - listed.count, "cap \(cap)")
        }
    }

    /// Ruling (Task 7): the notice never makes the migrated file unreadable. When rules plus the capped
    /// notice would pass `configBytes`, more pairs are left out (and counted) until the file fits.
    @Test func noticeShrinksSoTheMigratedFileStaysReadable() async throws {
        let rules = [localRule(1, asset: fixedAsset.id, host: nil)] + (2..<12).map { headerRule($0, order: $0) }
        let original = try legacyFile(schema: 3, revision: 1, rules: rules, assets: [fixedAsset])
        let roomy = makeTempDirectory(); defer { removeTree(roomy) }
        let reference = Stack(root: roomy)
        try reference.write(original)
        let full = try #require(try await reference.repository.load().migrationNotice)
        #expect(full.report.pairs.count == 10 && full.omittedPairCount == 0)
        let fullSize = try reference.stored().count

        let root = makeTempDirectory(); defer { removeTree(root) }
        let limits = RulesLimits(configBytes: fullSize - 300)
        let stack = Stack(root: root, limits: limits)
        try stack.write(original)
        let notice = try #require(try await stack.repository.load().migrationNotice)
        #expect(notice.report.pairs.count < full.report.pairs.count)
        #expect(notice.report.pairs == Array(full.report.pairs.prefix(notice.report.pairs.count)))
        #expect(notice.report.pairs.count + notice.omittedPairCount == full.report.pairs.count)
        #expect(try stack.stored().count <= limits.configBytes)
        #expect(try await Stack(root: root, limits: limits).repository.load().migrationNotice == notice)
    }

    // MARK: failures

    @Test func backupFailureLeavesFileUntouched() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root, fault: { stage in
            if stage == .backup { throw OwnedFileError(.insufficientDiskSpace, errno: ENOSPC) }
        })
        let original = try legacyFile(schema: 3, revision: 4, rules: [headerRule(1)])
        try stack.write(original)
        await #expect(throws: RuleRepositoryError.unavailable(.migrationFailed)) { _ = try await stack.repository.load() }
        #expect(try stack.stored() == original)
        #expect(names(in: stack.configDir) == ["rules.json"])  // no partial backup left behind
        #expect(stack.repository.provider.current() == RuleSnapshot(revision: 0, rules: []))
        await #expect(throws: RuleRepositoryError.unavailable(.migrationFailed)) {
            _ = try await stack.repository.save(groups: [], rules: [], expectedRevision: 0)
        }
        await #expect(throws: RuleRepositoryError.unavailable(.migrationFailed)) {
            _ = try await stack.repository.acknowledgeMigrationNotice()
        }
        #expect(try stack.stored() == original)
    }

    @Test(arguments: [RuleRepository.Stage.write, .sync, .rename])
    func writeFailureAfterBackupKeepsTheOldFile(_ stage: RuleRepository.Stage) async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root, fault: { current in
            if current == stage { throw OwnedFileError(.ioFailure, errno: EIO) }
        })
        let original = try legacyFile(schema: 2, revision: 4, rules: [headerRule(1)])
        try stack.write(original)
        await #expect(throws: RuleRepositoryError.unavailable(.migrationFailed)) { _ = try await stack.repository.load() }
        #expect(try stack.stored() == original)
        let backups = stack.backups()
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: stack.configDir.appendingPathComponent(try #require(backups.first))) == original)
        #expect(names(in: stack.configDir) == Set(["rules.json"] + backups))  // no temp file left behind
        #expect(stack.repository.provider.current() == RuleSnapshot(revision: 0, rules: []))
        await #expect(throws: RuleRepositoryError.unavailable(.migrationFailed)) {
            _ = try await stack.repository.save(groups: [], rules: [], expectedRevision: 0)
        }
    }

    @Test func crashBetweenBackupAndWriteMigratesAgain() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let original = try legacyFile(schema: 3, revision: 4, rules: [headerRule(1)])
        let crashing = Stack(root: root, fault: { stage in
            if stage == .write { throw OwnedFileError(.ioFailure, errno: EIO) }
        })
        try crashing.write(original)
        await #expect(throws: RuleRepositoryError.unavailable(.migrationFailed)) { _ = try await crashing.repository.load() }
        let first = crashing.backups()
        #expect(first.count == 1)

        // The next launch finds the old file again and migrates it, with a second backup of its own.
        let restarted = Stack(root: root)
        let snapshot = try await restarted.repository.load()
        #expect(snapshot.revision == 5 && snapshot.rules.map(\.id) == [uuid(1)])
        let backups = restarted.backups()
        #expect(backups.count == 2)
        #expect(Set(first).isSubset(of: Set(backups)))
        for name in backups {
            #expect(try Data(contentsOf: restarted.configDir.appendingPathComponent(name)) == original)
        }
        #expect(try restarted.storedJSON()["schemaVersion"] as? Int == 4)
    }

    @Test func retryAfterFailureSucceeds() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let armed = LockedFlag()
        armed.value = true
        let stack = Stack(root: root, fault: { stage in
            if stage == .backup, armed.value { throw OwnedFileError(.insufficientDiskSpace, errno: ENOSPC) }
        })
        let original = try legacyFile(schema: 3, revision: 4, rules: [headerRule(1)])
        try stack.write(original)
        await #expect(throws: RuleRepositoryError.unavailable(.migrationFailed)) { _ = try await stack.repository.load() }

        armed.value = false
        let snapshot = try await stack.repository.load()
        #expect(snapshot.revision == 5)
        #expect(stack.backups().count == 1)
        #expect(names(in: stack.configDir) == Set(["rules.json"] + stack.backups()))
        let saved = try await stack.repository.save(groups: [], rules: snapshot.rules, expectedRevision: 5)
        #expect(saved.revision == 6)
    }

    @Test func resetRefusedWhileMigrationFailed() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let armed = LockedFlag()
        armed.value = true
        let stack = Stack(root: root, fault: { stage in
            if stage == .backup, armed.value { throw OwnedFileError(.insufficientDiskSpace, errno: ENOSPC) }
        })
        let original = try legacyFile(schema: 3, revision: 4, rules: [headerRule(1)])
        try stack.write(original)
        await #expect(throws: RuleRepositoryError.unavailable(.migrationFailed)) { _ = try await stack.repository.load() }
        // A reset would clear every rule; only retrying the migration is offered (spec 5.6.1).
        armed.value = false
        await #expect(throws: RuleRepositoryError.unavailable(.migrationFailed)) {
            _ = try await stack.repository.resetUnreadableConfiguration()
        }
        #expect(try stack.stored() == original)
        #expect(names(in: stack.configDir) == ["rules.json"])
    }

    // MARK: saving

    @Test func ruleCapOnlyConstrainsGrowth() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        let many = (0..<520).map { LegacyRule(
            id: UUID(), name: "r\($0)", enabled: true, order: $0, matcher: RuleMatcher(hostPattern: "a.test"),
            action: .editHeaders(direction: .request, operations: [.set(name: "X", value: "\($0)")])) }
        try stack.write(try legacyFile(schema: 1, revision: 1, rules: many))
        let migrated = try await stack.repository.load()
        #expect(migrated.rules.count == 520)
        #expect(try await Stack(root: root).repository.load().rules.count == 520)

        let same = try await stack.repository.save(groups: [], rules: migrated.rules, expectedRevision: migrated.revision)
        #expect(same.rules.count == 520)
        let grown = same.rules + [Rule(migrating: headerRule(9_999))]
        await #expect(throws: RuleRepositoryError.invalidRule(
            index: 520, RuleValidationError(code: .tooManyRules, field: .group))) {
            _ = try await stack.repository.save(groups: [], rules: grown, expectedRevision: same.revision)
        }

        // An injected, smaller cap: an older file of 3 still loads and saves; growth past the larger of
        // the cap and the stored count is refused, and a shrunk list cannot grow back past the cap.
        let small = makeTempDirectory(); defer { removeTree(small) }
        let capped = Stack(root: small, limits: RulesLimits(ruleCount: 2))
        try capped.write(try legacyFile(schema: 3, revision: 1, rules: (1...3).map { headerRule($0, order: $0) }))
        let three = try await capped.repository.load()
        let kept = try await capped.repository.save(groups: [], rules: three.rules, expectedRevision: three.revision)
        await #expect(throws: RuleRepositoryError.invalidRule(
            index: 3, RuleValidationError(code: .tooManyRules, field: .group))) {
            _ = try await capped.repository.save(
                groups: [], rules: kept.rules + [Rule(migrating: headerRule(4))], expectedRevision: kept.revision)
        }
        let two = try await capped.repository.save(
            groups: [], rules: Array(kept.rules.prefix(2)), expectedRevision: kept.revision)
        await #expect(throws: RuleRepositoryError.invalidRule(
            index: 2, RuleValidationError(code: .tooManyRules, field: .group))) {
            _ = try await capped.repository.save(groups: [], rules: three.rules, expectedRevision: two.revision)
        }
    }

    @Test func savesAlwaysWriteSchema4() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        _ = try await stack.repository.load()
        let saved = try await stack.repository.save(
            groups: [], rules: [Rule(migrating: goldenLiteralRule)], expectedRevision: 0)
        #expect(saved.rules == [Rule(migrating: goldenLiteralRule)])
        let golden = #"{"assets":[],"groups":[],"revision":1,"rules":[{"actions":[{"isFinal":false,"kind":{"editHeaders":{"direction":"request","operations":[{"set":{"name":"X-Test","value":"1"}}]}}}],"conditions":{"mode":"all","occurrence":{"any":{}},"rows":[{"caseSensitive":false,"field":"scheme","op":"equals","value":"https"},{"caseSensitive":false,"field":"host","op":"hostPattern","value":"*.example.com"},{"caseSensitive":false,"field":"port","op":"equals","value":"443"},{"caseSensitive":true,"field":"method","op":"equals","value":"GET"},{"caseSensitive":true,"field":"pathAndQuery","op":"startsWith","value":"\/api\/"}]},"enabled":true,"id":"00000000-0000-0000-0000-0000000000A1","name":"golden","order":3}],"schemaVersion":4,"templatesInstalled":false}"#
        #expect(try stack.storedText() == golden)

        // An empty list is schema 4 too.
        _ = try await stack.repository.save(groups: [], rules: [], expectedRevision: 1)
        #expect(try stack.storedText()
            == #"{"assets":[],"groups":[],"revision":2,"rules":[],"schemaVersion":4,"templatesInstalled":false}"#)

        // And so is the empty configuration a reset writes.
        let other = makeTempDirectory(); defer { removeTree(other) }
        let broken = Stack(root: other)
        try broken.write(Data("{not json".utf8))
        await #expect(throws: RuleRepositoryError.unavailable(.corrupt)) { _ = try await broken.repository.load() }
        _ = try await broken.repository.resetUnreadableConfiguration()
        #expect(try broken.storedText()
            == #"{"assets":[],"groups":[],"revision":1,"rules":[],"schemaVersion":4,"templatesInstalled":false}"#)
    }

    @Test func saveAcceptsGroupsAndMultiActionRules() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        _ = try await stack.repository.load()
        let outer = RuleGroup(id: uuid(100), name: "outer", order: 1)
        let inner = RuleGroup(id: uuid(101), name: "inner", parentID: outer.id, order: 0)
        let anyMode = Rule(
            id: uuid(2), name: "any", order: 0,
            conditions: ConditionGroup(mode: .any, rows: [
                ConditionRow(field: .host, op: .hostPattern, value: "a.test"),
                ConditionRow(field: .host, op: .hostPattern, value: "b.test"),
            ]),
            actions: [RuleAction(.breakpoint(direction: .request, mode: .headers), isFinal: true)], note: "note")
        let rules = [multiActionRule(1, groupID: inner.id), anyMode]
        let saved = try await stack.repository.save(groups: [outer, inner], rules: rules, expectedRevision: 0)
        #expect(saved.revision == 1 && saved.groups == [outer, inner] && saved.rules == rules)
        #expect(saved.evaluationOrder.map(\.id) == [anyMode.id, uuid(1)])
        #expect(stack.repository.provider.current() == saved)
        #expect(try await Stack(root: root).repository.load() == saved)
    }

    @Test func saveRejectsInvalidStructure() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        _ = try await stack.repository.load()
        let kept = try await stack.repository.save(
            groups: [], rules: [Rule(migrating: headerRule(1))], expectedRevision: 0)
        let bytes = try stack.stored()
        let g1 = RuleGroup(id: uuid(101), name: "1")
        let g2 = RuleGroup(id: uuid(102), name: "2", parentID: g1.id)
        let g3 = RuleGroup(id: uuid(103), name: "3", parentID: g2.id)
        let g4 = RuleGroup(id: uuid(104), name: "4", parentID: g3.id)
        let orphanParent = RuleGroup(id: uuid(105), name: "orphan", parentID: uuid(999))
        let loopA = RuleGroup(id: uuid(106), name: "a", parentID: uuid(107))
        let loopB = RuleGroup(id: uuid(107), name: "b", parentID: uuid(106))
        let rule = Rule(migrating: headerRule(2))
        var noActions = Rule(migrating: headerRule(3))
        noActions.actions = []
        let cases: [([RuleGroup], [Rule], RuleRepositoryError)] = [
            ([g1, g2, g3, g4], [rule], .invalidRule(index: 0, RuleValidationError(code: .groupTooDeep, field: .group))),
            ([orphanParent], [rule], .invalidRule(index: 0, RuleValidationError(code: .unknownGroup, field: .group))),
            ([loopA, loopB], [rule], .invalidRule(index: 0, RuleValidationError(code: .groupCycle, field: .group))),
            ([], [rule, noActions], .invalidRule(index: 1, RuleValidationError(code: .noActions, field: .action(index: 0)))),
        ]
        for (groups, rules, error) in cases {
            await #expect(throws: error) {
                _ = try await stack.repository.save(groups: groups, rules: rules, expectedRevision: kept.revision)
            }
        }
        #expect(try stack.stored() == bytes)
        #expect(stack.repository.provider.current() == kept)
    }

    @Test func returnFileAssetsArePinnedAndSweptLikeBefore() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let first = Stack(root: root)
        _ = try await first.repository.load()
        let used = try await first.importAsset("used.bin")
        let orphan = try await first.importAsset("orphan.bin")
        let returnFile = Rule(migrating: localRule(1, asset: used.id))
        let directory = Rule(migrating: LegacyRule(
            id: uuid(2), name: "dir", enabled: true, order: 1, matcher: RuleMatcher(path: .prefix("/site/")),
            action: .mapLocalDirectory(MapLocalDirectoryAction(bookmark: Data([1]), displayName: "site"))))
        let saved = try await first.repository.save(groups: [], rules: [returnFile, directory], expectedRevision: 0)
        // The file lists exactly the referenced copy (a directory pins nothing).
        let listed = try #require(try first.storedJSON()["assets"] as? [[String: Any]])
        #expect(listed.map { $0["id"] as? String } == [used.id.uuidString])

        // A restart adopts the referenced copy and sweeps the orphan import.
        let restarted = Stack(root: root)
        #expect(try await restarted.repository.load() == saved)
        #expect(await restarted.assets.asset(used.id) == used)
        #expect(await restarted.assets.asset(orphan.id) == nil)
        #expect(names(in: restarted.assetsDir) == [used.id.uuidString + ".asset"])

        // An unknown copy is refused before anything is written; dropping the rule reclaims the copy.
        await #expect(throws: RuleRepositoryError.unknownAsset(uuid(0xBAD))) {
            _ = try await restarted.repository.save(
                groups: [], rules: [Rule(migrating: localRule(3, asset: uuid(0xBAD)))], expectedRevision: saved.revision)
        }
        _ = try await restarted.repository.save(groups: [], rules: [directory], expectedRevision: saved.revision)
        #expect(names(in: restarted.assetsDir).isEmpty)
        #expect((try restarted.storedJSON()["assets"] as? [Any])?.isEmpty == true)
    }

    @Test func acknowledgeKeepsRevisionAndRulesAndPersists() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        try stack.write(try legacyFile(
            schema: 3, revision: 2, rules: [localRule(1, asset: fixedAsset.id), headerRule(2, order: 1)],
            assets: [fixedAsset]))
        let migrated = try await stack.repository.load()
        let notice = try #require(migrated.migrationNotice)
        #expect(!notice.acknowledged)

        let acknowledged = try await stack.repository.acknowledgeMigrationNotice()
        #expect(acknowledged.revision == migrated.revision)
        #expect(acknowledged.rules == migrated.rules && acknowledged.groups == migrated.groups)
        #expect(acknowledged.migrationNotice?.acknowledged == true)
        #expect(acknowledged.migrationNotice?.report == notice.report)
        #expect(stack.repository.provider.current() == acknowledged)
        let bytes = try stack.stored()
        #expect(try await Stack(root: root).repository.load() == acknowledged)
        #expect(await stack.assets.asset(fixedAsset.id) == fixedAsset)

        // Again: nothing to change, nothing written.
        #expect(try await stack.repository.acknowledgeMigrationNotice() == acknowledged)
        #expect(try stack.stored() == bytes)

        // A draft opened before the acknowledgement still saves (same revision), and keeps the notice.
        let saved = try await stack.repository.save(groups: [], rules: migrated.rules, expectedRevision: migrated.revision)
        #expect(saved.revision == migrated.revision + 1 && saved.migrationNotice == acknowledged.migrationNotice)

        // Without a notice there is nothing to acknowledge.
        let plain = makeTempDirectory(); defer { removeTree(plain) }
        let empty = Stack(root: plain)
        let none = try await empty.repository.load()
        #expect(try await empty.repository.acknowledgeMigrationNotice() == none)
        #expect(!FileManager.default.fileExists(atPath: empty.configFile.path))
    }

    @Test func conflictStillDetectedByRevision() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        _ = try await stack.repository.load()
        let repository = stack.repository
        let draftA = [Rule(migrating: headerRule(1))], draftB = [multiActionRule(2)]
        async let first = attemptNext { try await repository.save(groups: [], rules: draftA, expectedRevision: 0) }
        async let second = attemptNext { try await repository.save(groups: [], rules: draftB, expectedRevision: 0) }
        let results = await [first, second]
        let winners = results.compactMap { try? $0.get() }
        #expect(winners.count == 1)
        let winner = try #require(winners.first)
        let loser = try #require(results.firstIndex { (try? $0.get()) == nil })
        #expect(throws: RuleRepositoryError.conflict(current: winner)) { try results[loser].get() }
        #expect(stack.repository.provider.current() == winner)
        let rebased = try await repository.save(
            groups: [], rules: loser == 0 ? draftA : draftB, expectedRevision: winner.revision)
        #expect(rebased.revision == 2)
    }
}

private func attemptNext(_ body: @Sendable () async throws -> RuleSnapshot) async -> Result<RuleSnapshot, Error> {
    do { return .success(try await body()) } catch { return .failure(error) }
}
