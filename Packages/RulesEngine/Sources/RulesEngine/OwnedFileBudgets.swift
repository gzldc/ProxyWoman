import Darwin
import Foundation
import os

/// Independent capacity classes of owned files. Each has its own service-wide cap; they never
/// borrow from each other or from the Flow capture budgets.
public enum OwnedFileBudgetCategory: String, Sendable, Hashable, CaseIterable {
    /// Persistent managed Map Local assets (`assetStoreBytes`).
    case asset
    /// Transient exact breakpoint body spools (`breakpointSpoolBytes`).
    case breakpoint
    /// Transient Compose body snapshots (`composeSpoolBytes`).
    case compose
    /// In-flight file read/write buffers (`ioBufferBytes`).
    case io
    /// In-flight breakpoint editor replacement values, including queued commands.
    case editor
}

/// One service-wide set of owned-file budgets, shared by the asset store and every body file I/O
/// instance. Reservations are taken before any byte is copied and returned only once the I/O they
/// cover has actually settled.
public final class OwnedFileBudgets: Sendable {
    package struct Snapshot: Sendable, Equatable {
        package var bytes: [OwnedFileBudgetCategory: Int64]
        /// Highest concurrent reservation seen per category.
        package var peak: [OwnedFileBudgetCategory: Int64]
        package var reservedBytes: Int64 { bytes.values.reduce(0, +) }
    }

    private struct State {
        var bytes: [OwnedFileBudgetCategory: Int64] = [:]
        var peak: [OwnedFileBudgetCategory: Int64] = [:]
    }

    private let capacities: [OwnedFileBudgetCategory: Int64]
    private let minimumFreeDiskBytes: Int64
    private let freeDiskBytes: @Sendable (URL) -> Int64?
    private let state = OSAllocatedUnfairLock(initialState: State())

    public convenience init(limits: RulesLimits) {
        self.init(limits: limits, freeDiskBytes: OwnedFileBudgets.volumeFreeBytes)
    }

    /// `freeDiskBytes` reports the free space of the volume holding a directory (nil: unknown).
    package init(limits: RulesLimits, freeDiskBytes: @escaping @Sendable (URL) -> Int64?) {
        capacities = [
            .asset: Int64(max(0, limits.assetStoreBytes)),
            .breakpoint: Int64(max(0, limits.breakpointSpoolBytes)),
            .compose: Int64(max(0, limits.composeSpoolBytes)),
            .io: Int64(max(0, limits.ioBufferBytes)),
            .editor: Int64(max(0, limits.editorMemoryBytes)),
        ]
        minimumFreeDiskBytes = Int64(max(0, limits.minimumFreeDiskBytes))
        self.freeDiskBytes = freeDiskBytes
    }

    /// Reserves `bytes` in `category` or throws `capacityExceeded` without changing anything.
    public func reserve(category: OwnedFileBudgetCategory, bytes: Int64) throws -> OwnedFileReservation {
        try take(category, bytes)
        return OwnedFileReservation(budgets: self, category: category, bytes: bytes)
    }

    /// Charges bytes that already exist on disk (adopted at launch), even beyond capacity, so later
    /// reservations see the true total.
    func reserveExisting(category: OwnedFileBudgetCategory, bytes: Int64) -> OwnedFileReservation {
        let bytes = max(0, bytes)
        state.withLock { state in
            let next = (state.bytes[category] ?? 0).addingReportingOverflow(bytes)
            state.bytes[category] = next.overflow ? Int64.max : next.partialValue
            state.peak[category] = max(state.peak[category] ?? 0, state.bytes[category] ?? 0)
        }
        return OwnedFileReservation(budgets: self, category: category, bytes: bytes)
    }

    package func snapshot() -> Snapshot {
        state.withLock { Snapshot(bytes: $0.bytes.filter { $0.value != 0 }, peak: $0.peak) }
    }

    /// Fails when writing `bytes` more into `directory` would leave less than the free-disk floor.
    /// Called before every chunk written by an import or spool.
    package func ensureFreeDisk(in directory: URL, adding bytes: Int64) throws {
        guard let free = freeDiskBytes(directory) else { throw OwnedFileError(.ioFailure) }
        let (after, overflow) = free.subtractingReportingOverflow(max(0, bytes))
        guard !overflow, after >= minimumFreeDiskBytes else { throw OwnedFileError(.insufficientDiskSpace) }
    }

    func take(_ category: OwnedFileBudgetCategory, _ bytes: Int64) throws {
        guard bytes >= 0 else { throw OwnedFileError(.capacityExceeded) }
        let capacity = capacities[category] ?? 0
        try state.withLock { state in
            let current = state.bytes[category] ?? 0
            let (next, overflow) = current.addingReportingOverflow(bytes)
            guard !overflow, next <= capacity else { throw OwnedFileError(.capacityExceeded) }
            state.bytes[category] = next
            state.peak[category] = max(state.peak[category] ?? 0, next)
        }
    }

    func give(_ category: OwnedFileBudgetCategory, _ bytes: Int64) {
        state.withLock { state in
            let current = state.bytes[category] ?? 0
            precondition(bytes >= 0 && bytes <= current, "owned file budget released more than reserved")
            state.bytes[category] = current - bytes
        }
    }

    private static func volumeFreeBytes(_ directory: URL) -> Int64? {
        var info = statfs()
        guard directory.path.withCString({ statfs($0, &info) }) == 0 else { return nil }
        let (free, overflow) = Int64(info.f_bavail).multipliedReportingOverflow(by: Int64(info.f_bsize))
        return overflow ? Int64.max : free
    }
}

/// A held amount of one budget. Release is idempotent and also happens on deinit; a reservation
/// may grow while it is held (unknown-length spools).
public final class OwnedFileReservation: Sendable {
    public let category: OwnedFileBudgetCategory
    private let budgets: OwnedFileBudgets
    private let held: OSAllocatedUnfairLock<Int64?>

    init(budgets: OwnedFileBudgets, category: OwnedFileBudgetCategory, bytes: Int64) {
        self.budgets = budgets
        self.category = category
        self.held = OSAllocatedUnfairLock(initialState: bytes)
    }

    deinit { release() }

    public var bytes: Int64 { held.withLock { $0 ?? 0 } }

    /// Reserves `bytes` more in the same category; throws without change at capacity or after release.
    public func extend(by bytes: Int64) throws {
        try held.withLock { held in
            guard let current = held else { throw OwnedFileError(.cancelled) }
            try budgets.take(category, bytes)
            held = current + bytes
        }
    }

    public func release() {
        guard let bytes = held.withLock({ held -> Int64? in
            defer { held = nil }
            return held
        }) else { return }
        budgets.give(category, bytes)
    }
}
