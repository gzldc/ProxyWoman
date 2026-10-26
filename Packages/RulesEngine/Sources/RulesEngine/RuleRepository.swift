import Darwin
import Foundation
import os

/// Why a stored configuration could not be loaded. The file is left exactly as it is.
public enum RuleConfigurationProblem: String, Sendable, Equatable {
    case corrupt
    case unsupportedSchema
    case tooLarge
    case unreadable
    /// A schema 1…3 file could not be backed up or its schema 4 replacement could not be written. The
    /// old file is untouched; loading again retries. No reset is offered (it would clear every rule).
    case migrationFailed

    /// Whether the user may be offered a reset (back the file up, start empty). Not when the file is
    /// fine and only this version cannot use it: a failed migration (retry instead) or a file made by
    /// another version (`unsupportedSchema`), which a reset would clear for that version too.
    public var allowsReset: Bool {
        switch self {
        case .corrupt, .tooLarge, .unreadable: true
        case .unsupportedSchema, .migrationFailed: false
        }
    }
}

public enum RuleRepositoryError: Error, Sendable, Equatable {
    /// Another save published first; `current` is what is saved now. The caller's draft is untouched.
    case conflict(current: RuleSnapshot)
    /// The stored configuration is unreadable; rules stay at the last valid revision and saving is
    /// refused so the file is never overwritten automatically.
    case unavailable(RuleConfigurationProblem)
    /// `load()` has not succeeded yet, so the stored file was never read and must not be replaced.
    case notLoaded
    /// A rule failed its checks (`index` is its position), or the list as a whole did (the rule count:
    /// the first position over the cap; the group tree: 0).
    case invalidRule(index: Int, RuleValidationError)
    case unknownAsset(UUID)
    case configurationTooLarge
    /// The next revision would be `UInt64.max`, which a later load rejects.
    case revisionExhausted
    /// Writing failed; nothing was published and the previous file is intact.
    case storage(OwnedFileError)
    /// A reset was asked for while the stored configuration loads fine; nothing was changed.
    case configurationReadable
    /// The unreadable file could not be backed up, so it was not replaced; nothing was published.
    case backupFailed(OwnedFileError)
}

/// The result of replacing an unreadable configuration with an empty one.
public struct RuleConfigurationReset: Sendable, Equatable {
    /// The durable, published empty configuration.
    public var snapshot: RuleSnapshot
    /// File name (in the configuration directory) of the byte-exact backup of the unreadable file;
    /// nil when no file existed any more when the reset ran.
    public var backupName: String?

    public init(snapshot: RuleSnapshot, backupName: String?) {
        self.snapshot = snapshot
        self.backupName = backupName
    }
}

/// Crash-safe persistence of the rule list. One serial transaction gate spans every await of a
/// load or save, so actor reentrancy can never interleave two saves or two reference commits.
/// A save prepares asset pins, writes a private temp file, fsyncs, renames over `rules.json`,
/// publishes the new snapshot and only then commits asset references.
///
/// The file is schema 4 (spec 5.1). A schema 1…3 file is migrated by the load that finds it: the
/// original bytes are first copied to `rules.v<schema>-backup-<UTC time>-<UUID>.json`, then the
/// schema 4 file replaces it atomically (spec 5.6.1, D12).
public actor RuleRepository {
    /// Test seam for injected storage failures.
    package enum Stage: Sendable, Equatable { case write, sync, rename, backup }

    static let fileName = "rules.json"
    private static let tempPrefix = ".rules-"
    private static let backupPrefix = "rules.corrupt-"

    public nonisolated let provider: RuleSnapshotProvider
    private let directory: URL
    private let assets: ManagedAssetStore
    private let limits: RulesLimits
    private let runner: OwnedFileRunner
    private let fault: @Sendable (Stage) throws -> Void
    private var current: RuleSnapshot
    /// The asset records the stored file lists, written again when only the notice changes.
    private var storedAssets: [ManagedAsset] = []
    /// Set while the stored file could not be loaded; saving is refused until a load succeeds.
    private var problem: RuleConfigurationProblem?
    private var loaded = false
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(directory: URL, assets: ManagedAssetStore, limits: RulesLimits) {
        self.init(directory: directory, assets: assets, limits: limits, fault: { _ in })
    }

    package init(directory: URL, assets: ManagedAssetStore, limits: RulesLimits, fault: @escaping @Sendable (Stage) throws -> Void) {
        self.directory = directory
        self.assets = assets
        self.limits = limits
        self.fault = fault
        self.runner = OwnedFileRunners.serialQueue(label: "proxywoman.rule-repository")
        self.current = RuleSnapshot(revision: 0, rules: [])
        self.provider = RuleSnapshotProvider(current)
    }

    // MARK: load

    /// Loads `rules.json` (absent: empty revision 0), migrating a schema 1…3 file, adopts its asset
    /// references, then sweeps owned orphan assets. On any problem the file is left untouched, the last
    /// valid snapshot stays published (at launch: empty, rules disabled), no asset is swept and saving
    /// is refused. A failed migration leaves the old file and any completed backup; loading again
    /// retries with a new backup.
    public func load() async throws -> RuleSnapshot {
        await enter()
        defer { leave() }
        return try await loadLocked()
    }

    private func loadLocked() async throws -> RuleSnapshot {
        let directory = self.directory, limits = self.limits
        let found: (contents: RuleStorage.Contents, identity: RegularFileIdentity)?
        do {
            // Reading, decoding and the (quadratic) migration analysis all run off the actor.
            found = try await OwnedFiles.run(on: runner) {
                guard let file = try Self.readConfiguration(in: directory, limit: limits.configBytes) else { return nil }
                return (try RuleStorage.read(file.data, limits: limits), file.identity)
            }
        } catch let problem as RuleConfigurationProblem {
            self.problem = problem
            throw RuleRepositoryError.unavailable(problem)
        }
        guard let found else {
            return await adopt(RuleStorage.Configuration(snapshot: RuleSnapshot(revision: 0, rules: []), assets: []))
        }
        switch found.contents {
        case .current(let configuration):
            return await adopt(configuration)
        case .migrated(let configuration, let encoded, let fromSchema):
            do {
                try await backUpForMigration(from: fromSchema, expected: found.identity)
                try await write(encoded)
            } catch {
                // The banner only says it failed; the cause (kind only, never rule content or paths) goes to the log.
                Self.log.error("rule migration from schema \(fromSchema) failed: \(Self.migrationFailureKind(error), privacy: .public)")
                problem = .migrationFailed
                throw RuleRepositoryError.unavailable(.migrationFailed)
            }
            return await adopt(configuration)
        }
    }

    private static let log = Logger(subsystem: "ProxyWoman", category: "RulesEngine")

    /// What went wrong, in words that are safe to log: the file error's kind and errno, or the error's type
    /// name. Never the error's own description, which may carry a path or a rule's text.
    package static func migrationFailureKind(_ error: any Error) -> String {
        func describe(_ error: OwnedFileError) -> String {
            error.errno.map { "\(error.code.rawValue) errno=\($0)" } ?? error.code.rawValue
        }
        switch error {
        case let error as OwnedFileError: return describe(error)
        case RuleRepositoryError.storage(let error): return "storage " + describe(error)
        default: return String(describing: type(of: error))
        }
    }

    /// Makes a durably stored configuration the published one.
    private func adopt(_ configuration: RuleStorage.Configuration) async -> RuleSnapshot {
        await assets.restorePersisted(configuration.assets)
        await assets.sweepOrphans()
        await sweepTempFiles()
        problem = nil
        loaded = true
        current = configuration.snapshot
        storedAssets = configuration.assets
        provider.publish(current)
        return current
    }

    /// The bytes of `rules.json` and the identity they were read from, or nil when there is none.
    /// Runs on the repository's file runner.
    private static func readConfiguration(in directory: URL, limit: Int) throws -> (data: Data, identity: RegularFileIdentity)? {
        let opened: (descriptor: Int32, identity: RegularFileIdentity)
        do {
            opened = try OwnedFiles.openOwned(fileName, in: directory)
        } catch let error as OwnedFileError where error.errno == ENOENT {
            return nil
        } catch {
            throw RuleConfigurationProblem.unreadable
        }
        defer { close(opened.descriptor) }
        guard opened.identity.size <= Int64(limit) else { throw RuleConfigurationProblem.tooLarge }
        var data = Data(count: Int(opened.identity.size))
        do {
            try data.withUnsafeMutableBytes { try OwnedFiles.preadExact(opened.descriptor, into: $0, offset: 0) }
        } catch {
            throw RuleConfigurationProblem.unreadable
        }
        return (data, opened.identity)
    }

    /// Copies the file a migration read, byte for byte, to `rules.v<schema>-backup-<UTC>-<UUID>.json`
    /// (exclusive create, bounded chunks, the copy budgets). A file that is no longer the one read, or is
    /// gone, fails the migration.
    private func backUpForMigration(from schema: Int, expected: RegularFileIdentity) async throws {
        let name = "rules.v\(schema)-backup-" + Self.backupStamp(Date()) + "-" + UUID().uuidString + ".json"
        let directory = self.directory, fault = self.fault, budgets = assets.bodyBudgets
        let chunkBytes = limits.ioChunkBytes
        let backedUp = try await OwnedFiles.run(on: runner) {
            try Self.backUpConfiguration(
                in: directory, as: name, chunkBytes: chunkBytes, budgets: budgets, expected: expected, fault: fault)
        }
        guard backedUp else { throw OwnedFileError(.sourceChanged) }
    }

    // MARK: save

    /// Saves `groups` and `rules` as the next revision if `expectedRevision` is still current, keeping
    /// the stored notice and template flag. Publishes only after the new file has been durably renamed
    /// into place; any failure publishes nothing. The rule count may not grow past the larger of
    /// `limits.ruleCount` and the stored count (D14).
    public func save(groups: [RuleGroup], rules: [Rule], expectedRevision: UInt64) async throws -> RuleSnapshot {
        await enter()
        defer { leave() }
        try checkSaveable(expectedRevision: expectedRevision)
        return try await commit(groups: groups, rules: rules)
    }

    private func checkSaveable(expectedRevision: UInt64) throws {
        if let problem { throw RuleRepositoryError.unavailable(problem) }
        guard loaded else { throw RuleRepositoryError.notLoaded }
        guard expectedRevision == current.revision else {
            throw RuleRepositoryError.conflict(current: current)
        }
        guard current.revision < UInt64.max - 1 else { throw RuleRepositoryError.revisionExhausted }
    }

    /// What a template install records in the snapshot it saves.
    private struct TemplateMark {
        var version: Int
        var groupID: UUID?
    }

    private func commit(groups: [RuleGroup], rules: [Rule], templates: TemplateMark? = nil) async throws -> RuleSnapshot {
        for (index, rule) in rules.enumerated() {
            do { try rule.validate(limits: limits) } catch let error as RuleValidationError {
                throw RuleRepositoryError.invalidRule(index: index, error)
            }
        }
        let next = RuleSnapshot(
            revision: current.revision + 1, groups: groups, rules: rules,
            templatesInstalled: current.templatesInstalled || templates != nil,
            migrationNotice: current.migrationNotice,
            templatesVersion: templates?.version ?? current.templatesVersion,
            templatesGroupID: templates.map(\.groupID) ?? current.templatesGroupID)
        let cap = max(limits.ruleCount, current.rules.count)
        do {
            try next.validateStructure(limits: limits, enforcingRuleCount: rules.count > cap)
        } catch let error as RuleValidationError {
            throw RuleRepositoryError.invalidRule(index: error.code == .tooManyRules ? cap : 0, error)
        }
        let referenced = RuleStorage.referencedAssets(rules)
        let token: UUID
        do {
            token = try await assets.prepareReferences(referenced)
        } catch {
            for id in referenced.sorted(by: { $0.uuidString < $1.uuidString }) {
                if await assets.asset(id) == nil { throw RuleRepositoryError.unknownAsset(id) }
            }
            throw error
        }
        do {
            var records: [ManagedAsset] = []
            for id in referenced.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard let asset = await assets.asset(id) else { throw RuleRepositoryError.unknownAsset(id) }
                records.append(asset)
            }
            let data = try RuleStorage.encode(RuleStorage.Configuration(snapshot: next, assets: records))
            guard data.count <= limits.configBytes else { throw RuleRepositoryError.configurationTooLarge }
            try await write(data)
            current = next
            storedAssets = records
            provider.publish(next)
            await assets.commitReferences(token)
            return next
        } catch {
            await assets.rollbackReferences(token)
            throw error
        }
    }

    /// Adds the built-in template set once per version. The stored `templatesVersion` at or above
    /// `set.version`: the current snapshot, nothing written (so a deleted group is never made again).
    /// Otherwise one save: the set's files are imported as managed assets, the top group goes at the bottom
    /// of the root with its subgroups and rules, `templatesVersion` and `templatesGroupID` are recorded and
    /// `templatesInstalled` is set. A group of the first template generation that is still exactly as it
    /// was installed (`legacy`, ruling R8F3-3) is removed in the same save and the new group takes its
    /// place; an edited one stays and the new group is added after everything. If the set would not fit
    /// (rule cap, file size, an invalid rule), only the version is recorded, so it is not tried again.
    /// Same gate, conflict and unavailable rules as `save`.
    public func installDefaultTemplates(
        _ set: DefaultTemplateSet, legacy: LegacyTemplateTexts? = nil, expectedRevision: UInt64
    ) async throws -> RuleSnapshot {
        await enter()
        defer { leave() }
        try checkSaveable(expectedRevision: expectedRevision)
        if let stored = current.templatesVersion, stored >= set.version { return current }

        let replaced = legacy.map {
            Set(RuleTemplateCatalog.untouchedLegacyGroupIDs(groups: current.groups, rules: current.rules, texts: $0))
        } ?? []
        let keptGroups = current.groups.filter { !replaced.contains($0.id) }
        let keptRules = current.rules.filter { rule in rule.groupID.map { !replaced.contains($0) } ?? true }
        let rootOrders = keptGroups.filter { $0.parentID == nil }.map(\.order) + keptRules.filter { $0.groupID == nil }.map(\.order)
        let replacedOrder = current.groups.filter { replaced.contains($0.id) }.map(\.order).min()
        let rootOrder = replacedOrder ?? ((rootOrders.max() ?? -1) + 1)

        // The files first: a rule that needs one is left out when it cannot be imported.
        var importedIDs: [UUID: UUID] = [:]
        for asset in set.assets {
            let data = asset.data
            if let imported = try? await assets.importStream(
                expectedSize: Int64(data.count), displayName: asset.displayName,
                read: { offset, maxBytes in
                    let start = Int(offset)
                    return data.subdata(in: start..<min(data.count, start + maxBytes))
                })
            {
                importedIDs[asset.placeholderID] = imported.id
            }
        }
        func resolved(_ rule: Rule) -> Rule? {
            var rule = rule
            for index in rule.actions.indices {
                if case .returnFile(var file) = rule.actions[index].kind, set.assets.contains(where: { $0.placeholderID == file.assetID }) {
                    guard let id = importedIDs[file.assetID] else { return nil }
                    file.assetID = id
                    rule.actions[index].kind = .returnFile(file)
                }
            }
            return rule
        }
        let addedRules = set.rules.compactMap(resolved)
        var addedGroups = set.groups
        for index in addedGroups.indices where addedGroups[index].id == set.rootGroupID {
            addedGroups[index].parentID = nil
            addedGroups[index].order = rootOrder
        }

        let candidate = RuleSnapshot(
            revision: current.revision, groups: keptGroups + addedGroups, rules: keptRules + addedRules)
        let cap = max(limits.ruleCount, current.rules.count)
        let fits = keptRules.count + addedRules.count <= cap
            && addedRules.allSatisfy { (try? $0.validate(limits: limits)) != nil }
            && (try? candidate.validateStructure(limits: limits, enforcingRuleCount: false)) != nil
        let imports = Set(importedIDs.values)
        if fits {
            do {
                return try await commit(
                    groups: candidate.groups, rules: candidate.rules,
                    templates: TemplateMark(version: set.version, groupID: set.rootGroupID))
            } catch RuleRepositoryError.configurationTooLarge {
                // The templates do not fit the file size cap: only the version is recorded.
            } catch {
                await assets.discardImports(imports)
                throw error
            }
        }
        await assets.discardImports(imports)
        return try await commit(
            groups: current.groups, rules: current.rules, templates: TemplateMark(version: set.version, groupID: nil))
    }

    /// Marks the stored upgrade notice as read. Only that flag changes: the revision stays (an open
    /// draft must not conflict, D11), the snapshot is published again. Without an unread notice nothing
    /// is written.
    public func acknowledgeMigrationNotice() async throws -> RuleSnapshot {
        await enter()
        defer { leave() }
        if let problem { throw RuleRepositoryError.unavailable(problem) }
        guard loaded else { throw RuleRepositoryError.notLoaded }
        guard var notice = current.migrationNotice, !notice.acknowledged else { return current }
        notice.acknowledged = true
        var next = current
        next.migrationNotice = notice
        let data = try RuleStorage.encode(RuleStorage.Configuration(snapshot: next, assets: storedAssets))
        guard data.count <= limits.configBytes else { throw RuleRepositoryError.configurationTooLarge }
        try await write(data)
        current = next
        provider.publish(next)
        return next
    }

    private func write(_ data: Data) async throws {
        let directory = self.directory, fault = self.fault
        let temp = Self.tempPrefix + UUID().uuidString
        do {
            try await OwnedFiles.run(on: runner) {
                try OwnedFiles.preparePrivateDirectory(directory)
                let descriptor = try OwnedFiles.createExclusive(temp, in: directory)
                var renamed = false
                defer {
                    close(descriptor)
                    if !renamed { OwnedFiles.unlinkOwned(temp, in: directory) }
                }
                try fault(.write)
                try data.withUnsafeBytes { try OwnedFiles.writeAll(descriptor, $0) }
                try fault(.sync)
                try OwnedFiles.sync(descriptor, full: true)
                try fault(.rename)
                try OwnedFiles.rename(temp, to: Self.fileName, in: directory)
                renamed = true
                // The rename is the commit point; a failed directory sync cannot undo it.
                try? OwnedFiles.syncDirectory(directory, full: true)
            }
        } catch let error as OwnedFileError {
            throw RuleRepositoryError.storage(error)
        }
    }

    // MARK: reset

    /// Explicit repair of a configuration the last load could not read. Under the transaction gate
    /// it first copies every byte of `rules.json` into a new exclusive owner file
    /// `rules.corrupt-<UTC time>-<UUID>.json` (bounded chunks, never following a symlink, owner's
    /// regular files only), then durably writes an empty configuration as the next revision and
    /// publishes it. If the backup fails nothing else happens; if the write fails the old file and
    /// the completed backup both stay and nothing is published. Backups are never deleted, and no
    /// asset file is swept here: the next successful load does that.
    ///
    /// The empty configuration has no `templatesVersion`, so the built-in templates are installed again at the next
    /// launch, as on a fresh install (R8F3-9).
    ///
    /// A failed migration is not reset (that would clear every rule while the old file is fine):
    /// `unavailable(.migrationFailed)`, and loading again is the way to retry. Nor is a file made by
    /// another version: `unavailable(.unsupportedSchema)`, nothing is backed up or written.
    public func resetUnreadableConfiguration() async throws -> RuleConfigurationReset {
        await enter()
        defer { leave() }
        guard let problem else { throw loaded ? RuleRepositoryError.configurationReadable : .notLoaded }
        guard problem.allowsReset else { throw RuleRepositoryError.unavailable(problem) }
        guard current.revision < UInt64.max - 1 else { throw RuleRepositoryError.revisionExhausted }
        let backupName = Self.backupPrefix + Self.backupStamp(Date()) + "-" + UUID().uuidString + ".json"
        let directory = self.directory, fault = self.fault, budgets = assets.bodyBudgets
        let chunkBytes = limits.ioChunkBytes
        let backedUp: Bool
        do {
            backedUp = try await OwnedFiles.run(on: runner) {
                try Self.backUpConfiguration(
                    in: directory, as: backupName, chunkBytes: chunkBytes, budgets: budgets, expected: nil, fault: fault)
            }
        } catch let error as OwnedFileError {
            throw RuleRepositoryError.backupFailed(error)
        }
        let next = RuleSnapshot(revision: current.revision + 1, rules: [])
        try await write(try RuleStorage.encode(RuleStorage.Configuration(snapshot: next, assets: [])))
        // The empty configuration references nothing; fresh imports of this session stay drafts.
        await assets.restorePersisted([])
        self.problem = nil
        loaded = true
        current = next
        storedAssets = []
        provider.publish(next)
        return RuleConfigurationReset(snapshot: next, backupName: backedUp ? backupName : nil)
    }

    /// Copies `rules.json` byte for byte into the exclusive file `name`. Returns false when there is
    /// no `rules.json`. With `expected`, a file that is not the one read then (another identity) is
    /// not copied (`sourceChanged`). Runs on the repository's file runner.
    private static func backUpConfiguration(
        in directory: URL, as name: String, chunkBytes: Int, budgets: OwnedFileBudgets,
        expected: RegularFileIdentity?, fault: @Sendable (Stage) throws -> Void
    ) throws -> Bool {
        let source: (descriptor: Int32, identity: RegularFileIdentity)
        do {
            source = try OwnedFiles.openOwned(fileName, in: directory)
        } catch let error as OwnedFileError where error.errno == ENOENT {
            return false
        }
        defer { close(source.descriptor) }
        if let expected, source.identity != expected { throw OwnedFileError(.sourceChanged) }
        var info = stat()
        guard fstat(source.descriptor, &info) == 0 else { throw OwnedFileError(.ioFailure, errno: errno) }
        guard info.st_uid == getuid() else { throw OwnedFileError(.notRegularFile) }
        let output = try OwnedFiles.createExclusive(name, in: directory)
        var kept = false
        defer {
            close(output)
            if !kept { OwnedFiles.unlinkOwned(name, in: directory) }
        }
        let chunk = max(1, chunkBytes)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunk, alignment: 16)
        defer { buffer.deallocate() }
        var copied: Int64 = 0
        while copied < source.identity.size {
            let count = Int(min(Int64(chunk), source.identity.size - copied))
            let reservation = try budgets.reserve(category: .io, bytes: Int64(count))
            defer { reservation.release() }
            try budgets.ensureFreeDisk(in: directory, adding: Int64(count))
            let slice = UnsafeMutableRawBufferPointer(rebasing: buffer[0..<count])
            try OwnedFiles.preadExact(source.descriptor, into: slice, offset: copied)
            try OwnedFiles.writeAll(output, UnsafeRawBufferPointer(slice))
            copied += Int64(count)
        }
        // A file that changed while it was copied is not what the user saw fail.
        var probe: UInt8 = 0
        guard pread(source.descriptor, &probe, 1, off_t(copied)) == 0,
              try OwnedFiles.identity(of: source.descriptor) == source.identity
        else { throw OwnedFileError(.sourceChanged) }
        try fault(.backup)
        try OwnedFiles.sync(output, full: true)
        kept = true
        try? OwnedFiles.syncDirectory(directory, full: true)
        return true
    }

    /// `20261021T101530Z`: sortable, and only characters owner names allow.
    private static func backupStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    // MARK: helpers

    private func sweepTempFiles() async {
        let directory = self.directory
        _ = try? await OwnedFiles.run(on: runner) {
            OwnedFiles.sweep(directory) { OwnedFiles.isUUIDName($0, prefix: Self.tempPrefix) }
        }
    }

    /// The serial transaction gate: FIFO, held across awaits.
    private func enter() async {
        guard busy else { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func leave() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

extension RuleConfigurationProblem: Error {}
