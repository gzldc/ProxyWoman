import Darwin
import FlowStore
import Foundation
import os
import Testing
@testable import RulesEngine

private struct Stack {
    var root: URL
    var configDir: URL { root.appendingPathComponent("config") }
    var assetsDir: URL { root.appendingPathComponent("assets") }
    var configFile: URL { configDir.appendingPathComponent("rules.json") }
    var budgets: OwnedFileBudgets
    var assets: ManagedAssetStore
    var repository: RuleRepository

    init(root: URL, limits: RulesLimits = RulesLimits(), fault: @escaping @Sendable (RuleRepository.Stage) throws -> Void = { _ in }) {
        self.root = root
        budgets = OwnedFileBudgets(limits: limits, freeDiskBytes: ample)
        assets = ManagedAssetStore(directory: root.appendingPathComponent("assets"), limits: limits, budgets: budgets)
        repository = RuleRepository(
            directory: root.appendingPathComponent("config"), assets: assets, limits: limits, fault: fault)
    }

    func importAsset(_ name: String, _ data: Data = randomData(1_000)) async throws -> ManagedAsset {
        let source = writeFile(root.appendingPathComponent(name), data)
        return try await assets.importFile(source, displayName: name)
    }
}

private func headerRule(_ name: String = "h") -> Rule {
    Rule(id: UUID(), name: name, enabled: true, order: 0, matcher: RuleMatcher(hostPattern: "example.com"),
         action: .editHeaders(direction: .request, operations: [.set(name: "X-Test", value: "1")]))
}

private func localRule(_ asset: ManagedAsset) -> Rule {
    Rule(id: UUID(), name: "local", enabled: true, order: 0, matcher: RuleMatcher(hostPattern: "example.com"),
         action: .mapLocal(MapLocalAction(assetID: asset.id, headers: [HeaderField(name: "Content-Type", value: "text/plain")])))
}

private func attempt(_ body: @Sendable () async throws -> RuleSnapshot) async -> Result<RuleSnapshot, Error> {
    do { return .success(try await body()) } catch { return .failure(error) }
}

/// A failure injected into the storage path at one stage.
struct InjectedFault: Sendable {
    var stage: RuleRepository.Stage
    var error: OwnedFileError
}

@Suite struct RuleRepositoryTests {
    @Test func missingConfigurationStartsEmptyAtRevisionZero() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        // Saving before the stored file was ever read could replace it blindly.
        await #expect(throws: RuleRepositoryError.notLoaded) {
            _ = try await stack.repository.save(groups: [], rules: [headerRule()], expectedRevision: 0)
        }
        let snapshot = try await stack.repository.load()
        #expect(snapshot == RuleSnapshot(revision: 0, rules: []))
        #expect(stack.repository.provider.current() == snapshot)
    }

    @Test func savePublishesOnlyAfterTheFileIsDurablyInPlace() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        _ = try await stack.repository.load()
        let rule = headerRule()
        let saved = try await stack.repository.save(groups: [], rules: [rule], expectedRevision: 0)
        #expect(saved.revision == 1)
        #expect(stack.repository.provider.current() == saved)
        #expect(mode(of: stack.configDir) == 0o700)
        #expect(mode(of: stack.configFile) == 0o600)
        #expect(names(in: stack.configDir) == ["rules.json"])

        // A new process sees the same revision.
        let reloaded = try await Stack(root: root).repository.load()
        #expect(reloaded == saved)
    }

    @Test func twoEditorsSavingTheSameRevisionGetOneSuccessAndOneConflict() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        _ = try await stack.repository.load()
        let draftA = [headerRule("a")], draftB = [headerRule("b")]
        let repository = stack.repository
        async let first = attempt { try await repository.save(groups: [], rules: draftA, expectedRevision: 0) }
        async let second = attempt { try await repository.save(groups: [], rules: draftB, expectedRevision: 0) }
        let results = await [first, second]

        let successes = results.compactMap { try? $0.get() }
        #expect(successes.count == 1)
        let winner = try #require(successes.first)
        #expect(winner.revision == 1)
        let loser = results.firstIndex { (try? $0.get()) == nil }!
        #expect(throws: RuleRepositoryError.conflict(current: winner)) { try results[loser].get() }
        #expect(stack.repository.provider.current() == winner)

        // The losing editor still has its draft and saves it against the revision it now sees.
        let losingDraft = loser == 0 ? draftA : draftB
        let resaved = try await stack.repository.save(groups: [], rules: losingDraft, expectedRevision: winner.revision)
        #expect(resaved.revision == 2)
        #expect(resaved.rules == losingDraft)
    }

    @Test(arguments: [
        InjectedFault(stage: .write, error: OwnedFileError(.insufficientDiskSpace, errno: ENOSPC)),
        InjectedFault(stage: .sync, error: OwnedFileError(.ioFailure, errno: EIO)),
        InjectedFault(stage: .rename, error: OwnedFileError(.ioFailure, errno: EIO)),
    ])
    func failedWriteKeepsOldRevisionConfigurationAndAssets(_ fault: InjectedFault) async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let armed = LockedFlag()
        let stack = Stack(root: root, fault: { stage in
            if stage == fault.stage, armed.value { throw fault.error }
        })
        _ = try await stack.repository.load()
        let oldAsset = try await stack.importAsset("old.bin")
        let old = try await stack.repository.save(groups: [], rules: [localRule(oldAsset)], expectedRevision: 0)
        let oldBytes = try Data(contentsOf: stack.configFile)
        let newAsset = try await stack.importAsset("new.bin")

        armed.value = true
        await #expect(throws: RuleRepositoryError.storage(fault.error)) {
            _ = try await stack.repository.save(groups: [], rules: [localRule(newAsset)], expectedRevision: old.revision)
        }
        #expect(stack.repository.provider.current().revision == old.revision)
        #expect(stack.repository.provider.current() == old)
        #expect(try Data(contentsOf: stack.configFile) == oldBytes)
        #expect(names(in: stack.configDir) == ["rules.json"])  // no temp file left behind
        #expect(names(in: stack.assetsDir) == [oldAsset.id.uuidString + ".asset", newAsset.id.uuidString + ".asset"])
        let lease = try await stack.assets.lease(oldAsset.id)
        lease.cancel()

        // The draft (with its fresh import) is still saveable once the disk recovers.
        armed.value = false
        let saved = try await stack.repository.save(groups: [], rules: [localRule(newAsset)], expectedRevision: old.revision)
        #expect(saved.revision == old.revision + 1)
        try await waitUntil("old asset reclaimed") {
            names(in: stack.assetsDir) == [newAsset.id.uuidString + ".asset"]
        }
    }

    @Test func configurationRenamedBeforeReferenceCommitKeepsItsAssetsAcrossRestart() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let first = Stack(root: root)
        _ = try await first.repository.load()
        let referenced = try await first.importAsset("ref.bin")
        let orphan = try await first.importAsset("orphan.bin")
        _ = try await first.repository.save(groups: [], rules: [localRule(referenced)], expectedRevision: 0)
        // The state a crash right after the rename leaves on disk: the new rules.json plus every
        // imported copy (reference commits are in memory only), and a stale temp file.
        writeFile(first.configDir.appendingPathComponent(".rules-\(UUID().uuidString)"), Data("partial".utf8))
        let userFile = writeFile(first.assetsDir.appendingPathComponent("notes.txt"), Data("mine".utf8))
        let lookalike = writeFile(first.assetsDir.appendingPathComponent("not-a-uuid.asset"), Data("mine".utf8))

        let restarted = Stack(root: root)
        let snapshot = try await restarted.repository.load()
        #expect(snapshot.revision == 1)
        let lease = try await restarted.assets.lease(referenced.id)
        #expect(lease.size == referenced.size)
        lease.cancel()
        #expect(await restarted.assets.asset(referenced.id) == referenced)
        #expect(await restarted.assets.asset(orphan.id) == nil)
        #expect(names(in: restarted.assetsDir) == [referenced.id.uuidString + ".asset", "notes.txt", "not-a-uuid.asset"])
        #expect(names(in: restarted.configDir) == ["rules.json"])
        #expect(FileManager.default.fileExists(atPath: userFile.path))
        #expect(FileManager.default.fileExists(atPath: lookalike.path))
    }

    @Test func referencedAssetsThatCannotBeOpenedAreNeverSweptAndDoNotBlockSaves() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let first = Stack(root: root)
        _ = try await first.repository.load()
        let locked = try await first.importAsset("locked.bin")
        let resized = try await first.importAsset("resized.bin")
        let saved = try await first.repository.save(groups: [], rules: [localRule(locked), localRule(resized)], expectedRevision: 0)
        let lockedFile = first.assetsDir.appendingPathComponent(locked.id.uuidString + ".asset")
        let resizedFile = first.assetsDir.appendingPathComponent(resized.id.uuidString + ".asset")
        #expect(chmod(lockedFile.path, 0) == 0)
        defer { chmod(lockedFile.path, 0o600) }
        writeFile(resizedFile, Data("short".utf8))

        let restarted = Stack(root: root)
        _ = try await restarted.repository.load()
        #expect(names(in: restarted.assetsDir) == [lockedFile.lastPathComponent, resizedFile.lastPathComponent])
        await #expect(throws: OwnedFileError(.assetUnavailable)) { _ = try await restarted.assets.lease(locked.id) }
        await #expect(throws: OwnedFileError(.assetUnavailable)) { _ = try await restarted.assets.lease(resized.id) }
        // An unrelated edit still saves while the damaged references stay in place.
        let edited = try await restarted.repository.save(groups: [], rules: saved.rules + [headerRule()], expectedRevision: saved.revision)
        #expect(edited.revision == saved.revision + 1)
        #expect(names(in: restarted.assetsDir) == [lockedFile.lastPathComponent, resizedFile.lastPathComponent])
    }

    @Test func revisionsNeverReachTheMaximum() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        try FileManager.default.createDirectory(at: stack.configDir, withIntermediateDirectories: true)
        writeFile(stack.configFile, Data(#"{"schemaVersion":1,"revision":18446744073709551615,"rules":[],"assets":[]}"#.utf8))
        await #expect(throws: RuleRepositoryError.unavailable(.corrupt)) { _ = try await stack.repository.load() }
        // A schema 4 file one below the maximum still loads, but nothing can be saved over it. (An older
        // file there is corrupt: its migration would take the next revision.)
        writeFile(stack.configFile, Data(#"{"assets":[],"groups":[],"revision":18446744073709551614,"rules":[],"schemaVersion":4,"templatesInstalled":false}"#.utf8))
        let loaded = try await Stack(root: root).repository.load()
        #expect(loaded.revision == UInt64.max - 1)
        let repository = Stack(root: root).repository
        _ = try await repository.load()
        await #expect(throws: RuleRepositoryError.revisionExhausted) {
            _ = try await repository.save(groups: [], rules: [], expectedRevision: UInt64.max - 1)
        }
    }

    @Test func sweepsSkipDirectoriesThatAreNotPrivate() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        try FileManager.default.createDirectory(at: stack.configDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stack.assetsDir, withIntermediateDirectories: true)
        #expect(chmod(stack.configDir.path, 0o755) == 0 && chmod(stack.assetsDir.path, 0o755) == 0)
        let temp = writeFile(stack.configDir.appendingPathComponent(".rules-\(UUID().uuidString)"), Data("x".utf8))
        let asset = writeFile(stack.assetsDir.appendingPathComponent(UUID().uuidString + ".asset"), Data("x".utf8))
        _ = try await stack.repository.load()
        #expect(FileManager.default.fileExists(atPath: temp.path))
        #expect(FileManager.default.fileExists(atPath: asset.path))
    }

    @Test(arguments: [
        ("{not json", RuleConfigurationProblem.corrupt),
        (#"{"schemaVersion":5,"revision":9,"rules":[],"assets":[]}"#, .unsupportedSchema),
        // Valid JSON that says schema 4 but this version cannot decode: made by another version (later
        // phases add stored cases inside schema 4), so it is left alone and never offered a reset.
        (#"{"schemaVersion":4,"revision":9,"rules":[],"assets":[]}"#, .unsupportedSchema),
        // Not JSON any more (cut off): damaged, whatever it said.
        (#"{"schemaVersion":4,"revision":9,"groups":[],"rules":["#, .corrupt),
        (#"{"schemaVersion":4"#, .corrupt),
        (#"{"schemaVersion":1,"revision":3,"rules":[{"id":"00000000-0000-0000-0000-000000000001","name":"x","enabled":true,"order":0,"matcher":{"path":{"any":{}}},"action":{"mapLocal":{"_0":{"assetID":"../../etc/passwd","status":200,"headers":[]}}}}],"assets":[]}"#, .corrupt),
        (#"{"schemaVersion":1,"revision":3,"rules":[{"id":"00000000-0000-0000-0000-000000000001","name":"x","enabled":true,"order":0,"matcher":{"path":{"any":{}}},"action":{"mapLocal":{"_0":{"assetID":"00000000-0000-0000-0000-000000000002","status":200,"headers":[]}}}}],"assets":[]}"#, .corrupt),
    ])
    func unreadableConfigurationIsNeverOverwrittenOrSwept(_ contents: String, _ problem: RuleConfigurationProblem) async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let first = Stack(root: root)
        _ = try await first.repository.load()
        let unreferenced = try await first.importAsset("a.bin")
        try FileManager.default.createDirectory(at: first.configDir, withIntermediateDirectories: true)
        writeFile(first.configFile, Data(contents.utf8))

        let restarted = Stack(root: root)
        await #expect(throws: RuleRepositoryError.unavailable(problem)) { _ = try await restarted.repository.load() }
        #expect(restarted.repository.provider.current() == RuleSnapshot(revision: 0, rules: []))
        await #expect(throws: RuleRepositoryError.unavailable(problem)) {
            _ = try await restarted.repository.save(groups: [], rules: [headerRule()], expectedRevision: 0)
        }
        #expect(try String(contentsOf: restarted.configFile, encoding: .utf8) == contents)
        // References are unknown, so nothing is swept.
        #expect(names(in: restarted.assetsDir) == [unreferenced.id.uuidString + ".asset"])
    }

    @Test func failedReloadKeepsTheLastValidRevisionPublished() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        _ = try await stack.repository.load()
        let saved = try await stack.repository.save(groups: [], rules: [headerRule()], expectedRevision: 0)
        writeFile(stack.configFile, Data("garbage".utf8))
        await #expect(throws: RuleRepositoryError.unavailable(.corrupt)) { _ = try await stack.repository.load() }
        #expect(stack.repository.provider.current() == saved)
    }

    @Test func oversizedOrSymlinkedConfigurationIsUnavailable() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let small = Stack(root: root, limits: RulesLimits(configBytes: 64))
        try FileManager.default.createDirectory(at: small.configDir, withIntermediateDirectories: true)
        writeFile(small.configFile, Data(repeating: 0x20, count: 65))
        await #expect(throws: RuleRepositoryError.unavailable(.tooLarge)) { _ = try await small.repository.load() }

        let other = writeFile(root.appendingPathComponent("elsewhere.json"), Data("{}".utf8))
        try FileManager.default.removeItem(at: small.configFile)
        try FileManager.default.createSymbolicLink(at: small.configFile, withDestinationURL: other)
        await #expect(throws: RuleRepositoryError.unavailable(.unreadable)) { _ = try await Stack(root: root).repository.load() }
        #expect(try String(contentsOf: other, encoding: .utf8) == "{}")
    }

    @Test func invalidRulesUnknownAssetsAndOversizedSavesPublishNothing() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root, limits: RulesLimits(configBytes: 700))
        _ = try await stack.repository.load()

        var bad = headerRule()
        bad.conditions.rows = [ConditionRow(field: .port, op: .equals, value: "0")]
        await #expect(throws: RuleRepositoryError.invalidRule(index: 0, RuleValidationError(code: .invalidPort, field: .port))) {
            _ = try await stack.repository.save(groups: [], rules: [bad], expectedRevision: 0)
        }
        let ghost = ManagedAsset(id: UUID(), size: 1, displayName: "g", importedAt: Date())
        await #expect(throws: RuleRepositoryError.unknownAsset(ghost.id)) {
            _ = try await stack.repository.save(groups: [], rules: [localRule(ghost)], expectedRevision: 0)
        }
        await #expect(throws: RuleRepositoryError.configurationTooLarge) {
            _ = try await stack.repository.save(groups: [], rules: (0..<10).map { headerRule("rule \($0)") }, expectedRevision: 0)
        }
        #expect(stack.repository.provider.current().revision == 0)
        #expect(!FileManager.default.fileExists(atPath: stack.configFile.path))
    }
}


// MARK: reset of an unreadable configuration (T9a-GPT-R34)

private func backups(in directory: URL) -> [String] {
    names(in: directory).filter { $0.hasPrefix("rules.corrupt-") && $0.hasSuffix(".json") }.sorted()
}

extension RuleRepositoryTests {
    @Test func resetBacksUpEveryOriginalByteThenCommitsAnEmptyConfiguration() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let first = Stack(root: root)
        _ = try await first.repository.load()
        let draftImport = try await first.importAsset("draft.bin")
        try FileManager.default.createDirectory(at: first.configDir, withIntermediateDirectories: true)
        var corrupt = Data("{\"schemaVersion\":1,\"revision\":7,\"rules\":[".utf8)
        corrupt.append(randomData(3_000))
        writeFile(first.configFile, corrupt)
        let unrelated = writeFile(first.configDir.appendingPathComponent("notes.txt"), Data("mine".utf8))

        let stack = Stack(root: root)
        await #expect(throws: RuleRepositoryError.unavailable(.corrupt)) { _ = try await stack.repository.load() }
        let reset = try await stack.repository.resetUnreadableConfiguration()

        #expect(reset.snapshot == RuleSnapshot(revision: 1, rules: []))
        // Templates come back after a reset, as on a fresh install (R8F3-9).
        #expect(reset.snapshot.templatesVersion == nil)
        #expect(stack.repository.provider.current() == reset.snapshot)
        let backupName = try #require(reset.backupName)
        #expect(backups(in: stack.configDir) == [backupName])
        #expect(backupName.hasPrefix("rules.corrupt-") && backupName.hasSuffix(".json"))
        let backup = stack.configDir.appendingPathComponent(backupName)
        #expect(try Data(contentsOf: backup) == corrupt)
        #expect(mode(of: backup) == 0o600)
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        // The reset deletes no asset file (the backup may still name it); only a later load sweeps.
        #expect(names(in: stack.assetsDir) == [draftImport.id.uuidString + ".asset"])

        // Saving works again, and a restart reads the durable empty configuration.
        let saved = try await stack.repository.save(groups: [], rules: [headerRule()], expectedRevision: 1)
        #expect(saved.revision == 2)
        #expect(try await Stack(root: root).repository.load() == saved)
        #expect(try Data(contentsOf: backup) == corrupt)
    }

    @Test func resetCopiesAnOversizedFileInBoundedChunks() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let limits = RulesLimits(configBytes: 64, ioChunkBytes: 7)
        let stack = Stack(root: root, limits: limits)
        try FileManager.default.createDirectory(at: stack.configDir, withIntermediateDirectories: true)
        let original = randomData(1_000)
        writeFile(stack.configFile, original)
        await #expect(throws: RuleRepositoryError.unavailable(.tooLarge)) { _ = try await stack.repository.load() }
        let reset = try await stack.repository.resetUnreadableConfiguration()
        let backupName = try #require(reset.backupName)
        #expect(try Data(contentsOf: stack.configDir.appendingPathComponent(backupName)) == original)
        #expect(stack.repository.provider.current().revision == 1)
        #expect(stack.budgets.snapshot().bytes[.io, default: 0] == 0)
    }

    @Test func resetRefusesAConfigurationThatWasNeverReadOrIsReadable() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        await #expect(throws: RuleRepositoryError.notLoaded) { _ = try await stack.repository.resetUnreadableConfiguration() }
        _ = try await stack.repository.load()
        let saved = try await stack.repository.save(groups: [], rules: [headerRule()], expectedRevision: 0)
        let bytes = try Data(contentsOf: stack.configFile)
        await #expect(throws: RuleRepositoryError.configurationReadable) {
            _ = try await stack.repository.resetUnreadableConfiguration()
        }
        #expect(try Data(contentsOf: stack.configFile) == bytes)
        #expect(stack.repository.provider.current() == saved)
        #expect(backups(in: stack.configDir).isEmpty)
    }

    @Test func failedBackupLeavesTheFileThePublishedRulesAndTheProblemUnchanged() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let armed = LockedFlag()
        let stack = Stack(root: root, fault: { stage in
            if stage == .backup, armed.value { throw OwnedFileError(.insufficientDiskSpace, errno: ENOSPC) }
        })
        _ = try await stack.repository.load()
        let saved = try await stack.repository.save(groups: [], rules: [headerRule()], expectedRevision: 0)
        writeFile(stack.configFile, Data("garbage".utf8))
        await #expect(throws: RuleRepositoryError.unavailable(.corrupt)) { _ = try await stack.repository.load() }

        armed.value = true
        await #expect(throws: RuleRepositoryError.backupFailed(OwnedFileError(.insufficientDiskSpace))) {
            _ = try await stack.repository.resetUnreadableConfiguration()
        }
        #expect(names(in: stack.configDir) == ["rules.json"])  // no partial backup left behind
        #expect(try String(contentsOf: stack.configFile, encoding: .utf8) == "garbage")
        #expect(stack.repository.provider.current() == saved)
        await #expect(throws: RuleRepositoryError.unavailable(.corrupt)) {
            _ = try await stack.repository.save(groups: [], rules: [], expectedRevision: saved.revision)
        }

        armed.value = false
        let reset = try await stack.repository.resetUnreadableConfiguration()
        #expect(reset.snapshot == RuleSnapshot(revision: saved.revision + 1, rules: []))
        #expect(stack.repository.provider.current() == reset.snapshot)
    }

    @Test(arguments: [RuleRepository.Stage.write, .sync, .rename])
    func failedEmptyConfigurationWriteKeepsTheOldFileAndTheCompletedBackup(_ stage: RuleRepository.Stage) async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let armed = LockedFlag()
        let stack = Stack(root: root, fault: { current in
            if current == stage, armed.value { throw OwnedFileError(.ioFailure, errno: EIO) }
        })
        try FileManager.default.createDirectory(at: stack.configDir, withIntermediateDirectories: true)
        writeFile(stack.configFile, Data("{not json".utf8))
        await #expect(throws: RuleRepositoryError.unavailable(.corrupt)) { _ = try await stack.repository.load() }

        armed.value = true
        await #expect(throws: RuleRepositoryError.storage(OwnedFileError(.ioFailure))) {
            _ = try await stack.repository.resetUnreadableConfiguration()
        }
        #expect(try String(contentsOf: stack.configFile, encoding: .utf8) == "{not json")
        let kept = backups(in: stack.configDir)
        #expect(kept.count == 1)
        if let name = kept.first {
            #expect(try String(contentsOf: stack.configDir.appendingPathComponent(name), encoding: .utf8) == "{not json")
        }
        #expect(names(in: stack.configDir) == Set(["rules.json"] + kept))  // no temp file left behind
        #expect(stack.repository.provider.current() == RuleSnapshot(revision: 0, rules: []))
        await #expect(throws: RuleRepositoryError.unavailable(.corrupt)) {
            _ = try await stack.repository.save(groups: [], rules: [], expectedRevision: 0)
        }

        // A retry makes a second, separate backup; the first one is preserved.
        armed.value = false
        let reset = try await stack.repository.resetUnreadableConfiguration()
        #expect(backups(in: stack.configDir).count == 2)
        #expect(backups(in: stack.configDir).contains(try #require(reset.backupName)))
        #expect(Set(kept).isSubset(of: Set(backups(in: stack.configDir))))
    }

    @Test func resetNeverFollowsASymlinkedConfiguration() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        try FileManager.default.createDirectory(at: stack.configDir, withIntermediateDirectories: true)
        let other = writeFile(root.appendingPathComponent("elsewhere.json"), Data("user data".utf8))
        try FileManager.default.createSymbolicLink(at: stack.configFile, withDestinationURL: other)
        await #expect(throws: RuleRepositoryError.unavailable(.unreadable)) { _ = try await stack.repository.load() }
        await #expect(throws: RuleRepositoryError.backupFailed(OwnedFileError(.notRegularFile))) {
            _ = try await stack.repository.resetUnreadableConfiguration()
        }
        #expect(try String(contentsOf: other, encoding: .utf8) == "user data")
        let link = try FileManager.default.destinationOfSymbolicLink(atPath: stack.configFile.path)
        #expect(link == other.path)
        #expect(backups(in: stack.configDir).isEmpty)
        #expect(stack.repository.provider.current() == RuleSnapshot(revision: 0, rules: []))
    }

    @Test func resetOfAConfigurationThatDisappearedWritesAnEmptyOneWithoutABackup() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        try FileManager.default.createDirectory(at: stack.configDir, withIntermediateDirectories: true)
        writeFile(stack.configFile, Data("[]".utf8))
        await #expect(throws: RuleRepositoryError.unavailable(.corrupt)) { _ = try await stack.repository.load() }
        try FileManager.default.removeItem(at: stack.configFile)
        let reset = try await stack.repository.resetUnreadableConfiguration()
        #expect(reset.backupName == nil)
        #expect(reset.snapshot.revision == 1)
        #expect(names(in: stack.configDir) == ["rules.json"])
    }
}

/// A flag the fault closure reads on the repository's file executor.
final class LockedFlag: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    var value: Bool {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}
