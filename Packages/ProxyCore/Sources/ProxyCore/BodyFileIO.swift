import Darwin
import FlowStore
import Foundation
import NIOCore
import NIOPosix
import RulesEngine
import os

/// Which owner and budget an exact (never truncated) body belongs to.
public enum ExactBodyCategory: Sendable, Equatable {
    case breakpoint
    case compose

    var budget: OwnedFileBudgetCategory {
        switch self {
        case .breakpoint: .breakpoint
        case .compose: .compose
        }
    }

    /// The single-body limit (`breakpointBodyBytes` / `composeBodyBytes`).
    func bodyLimit(_ limits: RulesLimits) -> Int64 {
        switch self {
        case .breakpoint: Int64(limits.breakpointBodyBytes)
        case .compose: Int64(limits.composeBodyBytes)
        }
    }
}

/// A complete, immutable body held in a private file. Only a full, exactly counted body becomes a
/// source; a truncated capture prefix never does. Reads are bounded to 65,536 bytes, one at a time.
/// When the source is cancelled (or dropped) and no read is in flight, its file is unlinked and its
/// spool reservation returned.
public struct ExactBodySource: Sendable {
    public let size: Int64
    public let trailers: [HeaderField]
    let lease: OwnedFileLease

    public func read(offset: Int64, maxBytes: Int) async throws -> Data {
        try await lease.read(offset: offset, maxBytes: min(maxBytes, 65_536))
    }

    public func cancel() {
        lease.cancel()
    }
}

/// Test seams for the blocking file work.
package struct BodyFileIOHooks: Sendable {
    /// Runs on the file pool before each spool write.
    package var sourceReleased: (@Sendable () -> Void)?
    package var beforeFinish: (@Sendable () -> Void)?
    package var beforeRead: (@Sendable () -> Void)?
    package var beforeWrite: (@Sendable () -> Void)?
    /// Runs on the import queue after each imported chunk (bytes copied so far).
    package var afterImportChunk: (@Sendable (Int64) -> Void)?

    package init(beforeWrite: (@Sendable () -> Void)? = nil, sourceReleased: (@Sendable () -> Void)? = nil, beforeFinish: (@Sendable () -> Void)? = nil, beforeRead: (@Sendable () -> Void)? = nil, afterImportChunk: (@Sendable (Int64) -> Void)? = nil) {
        self.sourceReleased = sourceReleased; self.beforeFinish = beforeFinish; self.beforeRead = beforeRead
        self.beforeWrite = beforeWrite
        self.afterImportChunk = afterImportChunk
    }
}

/// Exact body files of one event loop's exchanges. Every blocking call runs on the dedicated,
/// bounded file thread pool, never on the event loop or under a state lock. All instances share the
/// one service-wide `OwnedFileBudgets`; nothing here creates a new quota.
public final class BodyFileIO: Sendable {
    public let eventLoop: EventLoop
    let directory: URL
    let budgets: OwnedFileBudgets
    let limits: RulesLimits
    let pool: NIOThreadPool
    let runner: OwnedFileRunner
    /// Whole-file imports run on their own serial queue so a long copy never occupies a pool thread
    /// that spool writes and source reads need.
    let importRunner: OwnedFileRunner
    let hooks: BodyFileIOHooks
    let runtime: BreakpointBodyRuntime?

    public convenience init(
        directory: URL, eventLoop: EventLoop, budgets: OwnedFileBudgets, limits: RulesLimits, threadPool: NIOThreadPool
    ) {
        self.init(directory: directory, eventLoop: eventLoop, budgets: budgets, limits: limits, threadPool: threadPool, hooks: .init())
    }

    package init(
        directory: URL, eventLoop: EventLoop, budgets: OwnedFileBudgets, limits: RulesLimits, threadPool: NIOThreadPool,
        hooks: BodyFileIOHooks, runtime: BreakpointBodyRuntime? = nil
    ) {
        self.runtime = runtime
        self.directory = directory
        self.eventLoop = eventLoop
        self.budgets = budgets
        self.limits = limits
        self.pool = threadPool
        self.hooks = hooks
        self.importRunner = OwnedFileRunners.serialQueue(label: "proxywoman.body-import")
        self.runner = { work in
            threadPool.submit { state in
                switch state {
                case .active: work(true)
                case .cancelled: work(false)
                }
            }
        }
    }

    /// Copies a user-chosen regular file into a private exact body. The caller's security scope (App
    /// picker wrapper) must enclose this whole awaited call. Symlinks, FIFOs, devices and
    /// directories are refused; a size/mtime/identity change or a short read fails the import.
    public func importRegularFile(source: URL, limit: Int64, category: ExactBodyCategory) async throws -> ExactBodySource {
        let pin = try runtime?.pin()
        var transferred = false
        defer { if !transferred { pin?.release() } }
        let runner = self.importRunner
        let identity = try await OwnedFiles.run(on: runner) { try RegularFileCopy.inspect(source) }
        guard identity.size <= min(limit, category.bodyLimit(limits)) else { throw OwnedFileError(.fileTooLarge) }
        let reservation = try budgets.reserve(category: category.budget, bytes: identity.size)
        let id = UUID()
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let copy = RegularFileCopy(
            source: source, directory: directory, tempName: Self.tempName(id), finalName: Self.finalName(id),
            chunkBytes: limits.ioChunkBytes, budgets: budgets, isCancelled: { cancelled.withLock { $0 } },
            afterChunk: hooks.afterImportChunk)
        let opened: (descriptor: Int32, identity: RegularFileIdentity)
        do {
            let directory = self.directory
            opened = try await withTaskCancellationHandler {
                try await OwnedFiles.run(on: runner) {
                    try copy.run(expected: identity)
                    do {
                        return try OwnedFiles.openOwned(Self.finalName(id), in: directory)
                    } catch {
                        OwnedFiles.unlinkOwned(Self.finalName(id), in: directory)
                        throw error
                    }
                }
            } onCancel: {
                cancelled.withLock { $0 = true }
            }
        } catch {
            reservation.release()
            throw error
        }
        transferred = true
        return makeSource(id: id, size: identity.size, trailers: [], descriptor: opened.descriptor, reservation: reservation, pin: pin)
    }

    /// Best-effort standalone recovery. An active server owns this same lock throughout its run,
    /// so callers cannot sweep that server's files. This does not synchronize standalone spools.
    public func sweepOrphans() async {
        let directory = self.directory
        _ = try? await OwnedFiles.run(on: runner) {
            let owner = try SpoolDirectoryOwner.acquire(directory: directory, createMissing: false)
            defer { owner.release() }
            Self.sweepOwnedDirectory(directory)
        }
    }

    /// Startup owns the directory before sweeping or admitting any body work. The caller retains
    /// this lease until runtime drain, including failed binds and stop/restart cleanup.
    func prepareRun() async throws -> SpoolDirectoryOwner {
        let directory = self.directory
        return try await OwnedFiles.run(on: runner) {
            let owner = try SpoolDirectoryOwner.acquire(directory: directory, createMissing: true)
            Self.sweepOwnedDirectory(directory)
            return owner
        }
    }

    private static func sweepOwnedDirectory(_ directory: URL) {
        OwnedFiles.sweep(directory) {
            OwnedFiles.isUUIDName($0, prefix: ".spool-") || OwnedFiles.isUUIDName($0, suffix: ".body")
        }
    }

    /// Wraps a published private file; its release unlinks the file off-loop, then returns the budget.
    func makeSource(
        id: UUID, size: Int64, trailers: [HeaderField], descriptor: Int32, reservation: OwnedFileReservation, pin: BreakpointBodyRuntime.Pin? = nil
    ) -> ExactBodySource {
        let runner = self.runner, directory = self.directory, released = self.hooks.sourceReleased, beforeRead = self.hooks.beforeRead
        let lease = OwnedFileLease(
            id: id, size: size, descriptor: descriptor, chunkBytes: limits.ioChunkBytes, budgets: budgets,
            runner: { work in runner { active in
                if active { beforeRead?() }
                work(active)
            } },
            onRelease: {
                released?()
                runner { _ in
                    OwnedFiles.unlinkOwned(Self.finalName(id), in: directory)
                    reservation.release()
                    pin?.release()
                }
            })
        return ExactBodySource(size: size, trailers: trailers, lease: lease)
    }

    /// Runs blocking work on the file pool; the future completes on this instance's event loop.
    func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) -> EventLoopFuture<T> {
        pool.runIfActive(eventLoop: eventLoop, body)
    }

    static func tempName(_ id: UUID) -> String { ".spool-" + id.uuidString }
    static func finalName(_ id: UUID) -> String { id.uuidString + ".body" }
}

/// One server owner. A pin spans an entire spool/import/source lifetime, including secondary
/// unlink callbacks; draining never shuts the pool down between a write and its cleanup.
package final class BreakpointBodyRuntime: Sendable {
    let directory: URL
    let budgets: OwnedFileBudgets
    let limits: RulesLimits
    let hooks: BodyFileIOHooks
    private struct State {
        var accepting = true
        var pins = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    init(directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("ProxyWoman-Breakpoints-" + UUID().uuidString),
         budgets: OwnedFileBudgets, limits: RulesLimits, hooks: BodyFileIOHooks = .init()) {
        self.directory = directory; self.budgets = budgets; self.limits = limits; self.hooks = hooks
    }
    func makeIO(eventLoop: EventLoop, pool: NIOThreadPool) -> BodyFileIO {
        BodyFileIO(directory: directory, eventLoop: eventLoop, budgets: budgets, limits: limits,
                   threadPool: pool, hooks: hooks, runtime: self)
    }
    var activePins: Int { state.withLock { $0.pins } }
    func beginRun() { state.withLock { precondition($0.pins == 0); $0.accepting = true } }
    func pin() throws -> Pin {
        try state.withLock { state in
            guard state.accepting else { throw OwnedFileError(.cancelled) }
            state.pins += 1
        }
        return Pin(owner: self)
    }
    func drain() async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state in
                state.accepting = false
                if state.pins == 0 { return true }
                state.waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }
    private func release() {
        let waiters = state.withLock { state in
            precondition(state.pins > 0)
            state.pins -= 1
            guard state.pins == 0 else { return [CheckedContinuation<Void, Never>]() }
            defer { state.waiters.removeAll() }
            return state.waiters
        }
        waiters.forEach { $0.resume() }
    }
    final class Pin: Sendable {
        private let owner: BreakpointBodyRuntime
        private let released = OSAllocatedUnfairLock(initialState: false)
        init(owner: BreakpointBodyRuntime) { self.owner = owner }
        deinit { release() }
        func release() {
            if released.withLock({ value in defer { value = true }; return !value }) { owner.release() }
        }
    }
}
