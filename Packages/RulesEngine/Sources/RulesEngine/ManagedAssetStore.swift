import Darwin
import Foundation
import os

/// One immutable private copy of a user-chosen file. Only these fields are persisted (in the rule
/// configuration); a user path never is.
public struct ManagedAsset: Sendable, Equatable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var size: Int64
    public var displayName: String
    public var importedAt: Date

    public init(id: UUID, size: Int64, displayName: String, importedAt: Date) {
        self.id = id
        self.size = size
        self.displayName = displayName
        self.importedAt = importedAt
    }
}

/// Owns the private Map Local asset directory. Files are created only by this store, named
/// `<UUID>.asset` in a 0700 directory with mode 0600, and published by temp file + rename. An asset
/// is kept while the persisted configuration references it, a save transaction has pinned it, it
/// is a fresh import the editor has not yet saved or discarded, or a lease still reads it.
public actor ManagedAssetStore {
    private struct Entry {
        var asset: ManagedAsset
        /// Charged to the shared asset budget for as long as the copy exists.
        var reservation: OwnedFileReservation
        var leases = 0
        /// Imported in this session and not yet referenced by any saved configuration.
        var draft: Bool
    }

    private static let assetSuffix = ".asset"
    private static let tempPrefix = ".import-"

    private let directory: URL
    private let limits: RulesLimits
    private let budgets: OwnedFileBudgets
    nonisolated package var bodyBudgets: OwnedFileBudgets { budgets }
    /// Opens, lease reads and unlinks: short jobs only.
    private let runner: OwnedFileRunner
    /// Whole-file import copies, so a long import never delays a live Map Local read.
    private let importRunner: OwnedFileRunner
    private let afterChunk: (@Sendable (Int64) -> Void)?
    /// Map Local directory reads: their own serial queue, sharing this store's I/O budget.
    private let mappedDirectories: MappedDirectoryResolver
    private var entries: [UUID: Entry] = [:]
    private var persisted: Set<UUID> = []
    private var pending: [UUID: Set<UUID>] = [:]

    public init(directory: URL, limits: RulesLimits, budgets: OwnedFileBudgets) {
        self.init(directory: directory, limits: limits, budgets: budgets, afterChunk: nil)
    }

    /// `afterChunk` is a test seam called on the file executor after each copied chunk.
    package init(directory: URL, limits: RulesLimits, budgets: OwnedFileBudgets, afterChunk: (@Sendable (Int64) -> Void)?) {
        self.directory = directory
        self.limits = limits
        self.budgets = budgets
        self.runner = OwnedFileRunners.serialQueue(label: "proxywoman.managed-assets")
        self.importRunner = OwnedFileRunners.serialQueue(label: "proxywoman.managed-assets.import")
        self.afterChunk = afterChunk
        self.mappedDirectories = MappedDirectoryResolver(limits: limits, budgets: budgets)
    }

    /// The one directory resolver of this store (spec F11: its own serial file queue, no caching).
    public nonisolated func directoryResolver() -> MappedDirectoryResolver { mappedDirectories }

    // MARK: import

    /// Copies a regular file into a new private asset. The security scope (if any) is the caller's:
    /// it must enclose this whole awaited call. Cancelling the calling task stops the copy; a failed
    /// or cancelled import leaves no file and no reservation behind. The user's file is only read.
    public func importFile(_ source: URL, displayName: String) async throws -> ManagedAsset {
        guard displayName.utf8.count <= limits.fieldBytes else { throw OwnedFileError(.invalidName) }
        let runner = self.importRunner
        let identity = try await OwnedFiles.run(on: runner) { try RegularFileCopy.inspect(source) }
        guard identity.size <= Int64(limits.assetFileBytes) else { throw OwnedFileError(.fileTooLarge) }
        let reservation = try budgets.reserve(category: .asset, bytes: identity.size)
        let id = UUID()
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let copy = RegularFileCopy(
            source: source, directory: directory, tempName: Self.tempPrefix + id.uuidString,
            finalName: Self.fileName(id), chunkBytes: limits.ioChunkBytes, budgets: budgets,
            isCancelled: { cancelled.withLock { $0 } }, afterChunk: afterChunk)
        do {
            // The reservation is returned only after the copy job itself has finished.
            try await withTaskCancellationHandler {
                try await OwnedFiles.run(on: runner) { try copy.run(expected: identity) }
            } onCancel: {
                cancelled.withLock { $0 = true }
            }
        } catch {
            reservation.release()
            throw error
        }
        let asset = ManagedAsset(id: id, size: identity.size, displayName: displayName, importedAt: Date())
        entries[id] = Entry(asset: asset, reservation: reservation, draft: true)
        return asset
    }

    /// Copies `expectedSize` bytes produced by `read` into a new private asset, in chunks of at most
    /// `ioChunkBytes`; no more than one chunk is ever in memory. `read(offset, maxBytes)` answers at
    /// most `maxBytes` and must not return empty before `expectedSize` bytes were delivered (that is
    /// a `shortRead`) nor more than asked (`lengthMismatch`). The size and the budgets are checked
    /// before the first read; a failed or cancelled import leaves no file and no reservation.
    public func importStream(
        expectedSize: Int64, displayName: String,
        read: @escaping @Sendable (_ offset: Int64, _ maxBytes: Int) async throws -> Data
    ) async throws -> ManagedAsset {
        guard displayName.utf8.count <= limits.fieldBytes else { throw OwnedFileError(.invalidName) }
        guard expectedSize >= 0 else { throw OwnedFileError(.lengthMismatch) }
        guard expectedSize <= Int64(limits.assetFileBytes) else { throw OwnedFileError(.fileTooLarge) }
        let reservation = try budgets.reserve(category: .asset, bytes: expectedSize)
        let id = UUID()
        let runner = self.importRunner
        let directory = self.directory, budgets = self.budgets, afterChunk = self.afterChunk
        let tempName = Self.tempPrefix + id.uuidString, finalName = Self.fileName(id)
        let chunk = max(1, limits.ioChunkBytes)
        // The temp file's descriptor, closed exactly once whichever way the import ends.
        let output = OSAllocatedUnfairLock<Int32?>(initialState: nil)
        do {
            let descriptor = try await OwnedFiles.run(on: runner) {
                try OwnedFiles.preparePrivateDirectory(directory)
                let descriptor = try OwnedFiles.createExclusive(tempName, in: directory)
                output.withLock { $0 = descriptor }
                return descriptor
            }
            var copied: Int64 = 0
            while copied < expectedSize {
                if Task.isCancelled { throw OwnedFileError(.cancelled) }
                let wanted = Int(min(Int64(chunk), expectedSize - copied))
                let data = try await read(copied, wanted)
                if Task.isCancelled { throw OwnedFileError(.cancelled) }
                guard !data.isEmpty else { throw OwnedFileError(.shortRead) }
                guard data.count <= wanted else { throw OwnedFileError(.lengthMismatch) }
                let total = copied + Int64(data.count)
                try await OwnedFiles.run(on: runner) {
                    let buffer = try budgets.reserve(category: .io, bytes: Int64(data.count))
                    defer { buffer.release() }
                    try budgets.ensureFreeDisk(in: directory, adding: Int64(data.count))
                    try data.withUnsafeBytes { try OwnedFiles.writeAll(descriptor, $0) }
                    afterChunk?(total)
                }
                copied = total
            }
            if Task.isCancelled { throw OwnedFileError(.cancelled) }
            try await OwnedFiles.run(on: runner) {
                try OwnedFiles.sync(descriptor, full: true)
                if let open = output.withLock({ state -> Int32? in defer { state = nil }; return state }) { close(open) }
                try OwnedFiles.rename(tempName, to: finalName, in: directory)
                try? OwnedFiles.syncDirectory(directory, full: true)
            }
        } catch {
            // The temp file goes before the reservation is returned.
            _ = try? await OwnedFiles.run(on: runner) {
                if let open = output.withLock({ state -> Int32? in defer { state = nil }; return state }) { close(open) }
                OwnedFiles.unlinkOwned(tempName, in: directory)
            }
            reservation.release()
            throw error
        }
        let asset = ManagedAsset(id: id, size: expectedSize, displayName: displayName, importedAt: Date())
        entries[id] = Entry(asset: asset, reservation: reservation, draft: true)
        return asset
    }

    /// Explicit import cancellation: deletes fresh imports that no saved configuration or pending
    /// save references. Persisted or pinned assets are left untouched; leased ones go on last release.
    public func discardImports(_ ids: Set<UUID>) async {
        for id in ids where entries[id]?.draft == true {
            entries[id]?.draft = false
            await reclaimIfUnused(id)
        }
    }

    public func asset(_ id: UUID) -> ManagedAsset? {
        entries[id]?.asset
    }

    // MARK: leases

    /// Opens the private copy for reading. Fails with `unknownAsset` for an ID this store does not
    /// own and `assetUnavailable` when the copy is missing or damaged.
    public func lease(_ id: UUID) async throws -> OwnedFileLease {
        guard entries[id] != nil else { throw OwnedFileError(.unknownAsset) }
        entries[id]?.leases += 1
        let name = Self.fileName(id), directory = self.directory
        let opened: (descriptor: Int32, identity: RegularFileIdentity)
        do {
            opened = try await OwnedFiles.run(on: runner) { try OwnedFiles.openOwned(name, in: directory) }
        } catch {
            await releaseLease(id)
            throw OwnedFileError(.assetUnavailable)
        }
        guard let size = entries[id]?.asset.size, opened.identity.size == size else {
            close(opened.descriptor)
            await releaseLease(id)
            throw OwnedFileError(.assetUnavailable)
        }
        return OwnedFileLease(
            id: id, size: size, descriptor: opened.descriptor, chunkBytes: limits.ioChunkBytes,
            budgets: budgets, runner: runner,
            onRelease: { [weak self] in
                guard let self else { return }
                Task { await self.releaseLease(id) }
            })
    }

    private func releaseLease(_ id: UUID) async {
        guard let leases = entries[id]?.leases, leases > 0 else { return }
        entries[id]?.leases = leases - 1
        await reclaimIfUnused(id)
    }

    // MARK: reference transaction

    /// Pins every requested asset before the configuration that references them is written.
    /// Throws `unknownAsset` (pinning nothing) if any ID is not owned by this store.
    public func prepareReferences(_ ids: Set<UUID>) async throws -> UUID {
        guard ids.allSatisfy({ entries[$0] != nil }) else { throw OwnedFileError(.unknownAsset) }
        let token = UUID()
        pending[token] = ids
        return token
    }

    /// The configuration is durable: its references become the persisted set and every asset no
    /// longer referenced is reclaimed (after its last lease).
    public func commitReferences(_ token: UUID) async {
        guard let ids = pending.removeValue(forKey: token) else { return }
        let previous = persisted
        persisted = ids
        for id in ids { entries[id]?.draft = false }
        for id in previous.subtracting(ids) { await reclaimIfUnused(id) }
    }

    /// The save failed: only this transaction's pins go; persisted references and fresh imports stay.
    public func rollbackReferences(_ token: UUID) async {
        guard let ids = pending.removeValue(forKey: token) else { return }
        for id in ids { await reclaimIfUnused(id) }
    }

    // MARK: launch

    /// Adopts every asset a loaded configuration references, before any orphan sweep. A record
    /// whose copy is missing, unreadable or of another size stays known (persisted, never swept,
    /// still accepted by saves) but every lease fails with `assetUnavailable`.
    func restorePersisted(_ assets: [ManagedAsset]) async {
        let directory = self.directory
        let names = assets.map { (asset: $0, name: Self.fileName($0.id)) }
        let intact: Set<UUID> = (try? await OwnedFiles.run(on: runner) {
            Set(names.compactMap { item -> UUID? in
                guard let opened = try? OwnedFiles.openOwned(item.name, in: directory) else { return nil }
                close(opened.descriptor)
                return opened.identity.size == item.asset.size ? item.asset.id : nil
            })
        }) ?? []
        for asset in assets where entries[asset.id] == nil {
            // Already on disk: charge it so the store total stays truthful, even above capacity.
            let reservation = budgets.reserveExisting(category: .asset, bytes: intact.contains(asset.id) ? asset.size : 0)
            entries[asset.id] = Entry(asset: asset, reservation: reservation, draft: false)
        }
        persisted = Set(assets.map(\.id))
    }

    /// Startup sweep: deletes only files this store names (`<UUID>.asset`, `.import-<UUID>`) that are
    /// regular, owned by this user and not known, inside a verified private directory. Anything
    /// else in the directory is never touched.
    func sweepOrphans() async {
        let known = Set(entries.keys.map(Self.fileName))
        let directory = self.directory
        _ = try? await OwnedFiles.run(on: runner) {
            OwnedFiles.sweep(directory, keep: known) {
                OwnedFiles.isUUIDName($0, suffix: Self.assetSuffix) || OwnedFiles.isUUIDName($0, prefix: Self.tempPrefix)
            }
        }
    }

    // MARK: reclaim

    private func reclaimIfUnused(_ id: UUID) async {
        guard let entry = entries[id], !entry.draft, entry.leases == 0, !persisted.contains(id),
              !pending.values.contains(where: { $0.contains(id) }) else { return }
        entries[id] = nil
        let name = Self.fileName(id), directory = self.directory
        _ = try? await OwnedFiles.run(on: runner) { OwnedFiles.unlinkOwned(name, in: directory) }
        entry.reservation.release()
    }

    static func fileName(_ id: UUID) -> String { id.uuidString + assetSuffix }
}
