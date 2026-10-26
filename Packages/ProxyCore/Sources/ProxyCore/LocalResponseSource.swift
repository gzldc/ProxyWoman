import FlowStore
import Foundation
import RulesEngine
import os

/// An owned, immutable representation. State is lock-confined; neither file I/O nor test hooks
/// run under that lock. Async work uses ManagedAssetStore/OwnedFileLease's existing file executor.
/// The exchange owns the single prepare/read task and all transport state on its event loop.
final class LocalResponseSource: Sendable {
    struct Prepared: Sendable {
        let head: HTTPMessageHead
        let length: Int64
    }

    /// Narrow observation/fault barriers for tests. They never replace the real lease or executor.
    struct Hooks: Sendable {
        var beforePrepare: (@Sendable (UUID) async throws -> Void)? = nil
        var beforeRead: (@Sendable (UUID, Int64) async throws -> Void)? = nil
        var afterRead: (@Sendable (UUID, Int) -> Void)? = nil
        /// Runs off the event loop after a Map Local directory resolution returned and before the
        /// exchange sees it; the exchange still owns (and must release) any lease in it.
        var afterDirectoryResolve: (@Sendable (DirectoryResolution) async -> Void)? = nil
    }

    private struct State {
        var cancelled = false
        var inFlight = false
        var lease: OwnedFileLease?
        var offset: Int64 = 0
    }

    /// What the response is generated from.
    private enum Representation: Sendable {
        /// A managed Map Local asset, leased by `prepare()`.
        case asset(MapLocalAction, ManagedAssetStore)
        /// A file already opened by a Map Local directory resolution; the source owns its lease.
        case preResolved(status: Int, headers: [HeaderField], size: Int64)
        /// No representation at all: a zero-length body (directory 404/405).
        case empty(status: Int, headers: [HeaderField])
        /// A rule's handwritten or preset response, body in memory (D17): no file, no lease.
        case generated(GeneratedResponse)
    }

    private let state: OSAllocatedUnfairLock<State>
    private let representation: Representation
    /// The identity passed to the hooks: the asset ID, the lease ID or a fresh one.
    private let representationID: UUID
    private let limits: RulesLimits
    private let hooks: Hooks?

    init(action: MapLocalAction, assets: ManagedAssetStore, limits: RulesLimits = .init(), hooks: Hooks? = nil) {
        self.state = OSAllocatedUnfairLock(initialState: State())
        self.representation = .asset(action, assets)
        self.representationID = action.assetID
        self.limits = limits
        self.hooks = hooks
    }

    /// Takes ownership of `lease` at once: cancelling (or dropping) this source releases it, even
    /// if `prepare()` never runs.
    init(preResolved lease: OwnedFileLease, status: Int, headers: [HeaderField], limits: RulesLimits = .init(), hooks: Hooks? = nil) {
        self.state = OSAllocatedUnfairLock(initialState: State(lease: lease))
        self.representation = .preResolved(status: status, headers: headers, size: lease.size)
        self.representationID = lease.id
        self.limits = limits
        self.hooks = hooks
    }

    /// A response with an empty body and no file behind it.
    init(emptyStatus status: Int, headers: [HeaderField], limits: RulesLimits = .init(), hooks: Hooks? = nil) {
        self.state = OSAllocatedUnfairLock(initialState: State())
        self.representation = .empty(status: status, headers: headers)
        self.representationID = UUID()
        self.limits = limits
        self.hooks = hooks
    }

    /// A rule's handwritten or preset response. Its body is already in memory (at most the handwritten
    /// response limit); nothing is leased and no asset is involved.
    init(generated response: GeneratedResponse, limits: RulesLimits = .init(), hooks: Hooks? = nil) {
        self.state = OSAllocatedUnfairLock(initialState: State())
        self.representation = .generated(response)
        self.representationID = UUID()
        self.limits = limits
        self.hooks = hooks
    }

    /// A rule-generated response: recorded without an asset, yet projected like one.
    var isGenerated: Bool {
        if case .generated = representation { return true }
        return false
    }

    deinit { cancel() }

    func prepare() async throws -> Prepared {
        try await withTaskCancellationHandler {
            try beginOperation()
            defer { endOperation() }
            try await hooks?.beforePrepare?(representationID)
            try checkCancellation()
            switch representation {
            case .asset(let action, let assets):
                let lease = try await assets.lease(action.assetID)
                do {
                    let head = HTTPMessageHead.response(status: action.status, reason: nil, headers: action.headers)
                    try HTTPMutationValidator.validate(head: head, body: .init(length: lease.size, complete: true, changed: false), limits: limits)
                    try state.withLock { state in
                        guard !state.cancelled else { throw OwnedFileError(.cancelled) }
                        guard state.lease == nil else { throw OwnedFileError(.operationInFlight) }
                        state.lease = lease
                    }
                    return Prepared(head: head, length: lease.size)
                } catch {
                    lease.cancel()
                    throw error
                }
            case .preResolved(let status, let headers, let size):
                // A failure here reaches the exchange, which cancels this source and so the lease.
                let head = HTTPMessageHead.response(status: status, reason: nil, headers: headers)
                try HTTPMutationValidator.validate(head: head, body: .init(length: size, complete: true, changed: false), limits: limits)
                try state.withLock { state in
                    guard !state.cancelled, state.lease != nil else { throw OwnedFileError(.cancelled) }
                }
                return Prepared(head: head, length: size)
            case .empty(let status, let headers):
                let head = HTTPMessageHead.response(status: status, reason: nil, headers: headers)
                try HTTPMutationValidator.validate(head: head, body: .init(length: 0, complete: true, changed: false), limits: limits)
                return Prepared(head: head, length: 0)
            case .generated(let response):
                let head = HTTPMessageHead.response(status: response.status, reason: response.reason, headers: response.headers)
                let length = Int64(response.body.count)
                try HTTPMutationValidator.validate(head: head, body: .init(length: length, complete: true, changed: false), limits: limits)
                return Prepared(head: head, length: length)
            }
        } onCancel: { self.cancel() }
    }

    /// nil only at the representation's exact end. A smaller store-configured chunk is valid;
    /// a genuine short read is reported by OwnedFileLease and must never be swallowed.
    func readNext() async throws -> Data? {
        try await withTaskCancellationHandler {
            try beginOperation()
            defer { endOperation() }
            if case .empty = representation { return nil }
            if case .generated(let response) = representation { return try await nextGenerated(response.body) }
            let (lease, offset) = try state.withLock { state -> (OwnedFileLease, Int64) in
                guard let lease = state.lease else { throw OwnedFileError(.assetUnavailable) }
                return (lease, state.offset)
            }
            guard offset < lease.size else { return nil }
            try await hooks?.beforeRead?(representationID, offset)
            try checkCancellation()
            let bytes = try await lease.read(offset: offset, maxBytes: min(65_536, max(1, limits.ioChunkBytes)))
            hooks?.afterRead?(representationID, bytes.count)
            guard !bytes.isEmpty, Int64(bytes.count) <= lease.size - offset else { throw OwnedFileError(.shortRead) }
            try state.withLock { state in
                guard !state.cancelled else { throw OwnedFileError(.cancelled) }
                state.offset += Int64(bytes.count)
            }
            return bytes
        } onCancel: { self.cancel() }
    }

    /// Cancels immediately; the lease defers descriptor release until any actual I/O settles.
    /// A prepare that returns its lease later observes cancelled and releases it itself.
    func cancel() {
        let lease = state.withLock { state in
            state.cancelled = true
            defer { state.lease = nil }
            return state.lease
        }
        lease?.cancel()
    }

    /// The next chunk of an in-memory body, nil at its end.
    private func nextGenerated(_ body: Data) async throws -> Data? {
        let offset = state.withLock { $0.offset }
        guard offset < Int64(body.count) else { return nil }
        try await hooks?.beforeRead?(representationID, offset)
        try checkCancellation()
        let start = body.startIndex + Int(offset)
        let bytes = body[start..<min(body.endIndex, start + min(65_536, max(1, limits.ioChunkBytes)))]
        hooks?.afterRead?(representationID, bytes.count)
        try state.withLock { state in
            guard !state.cancelled else { throw OwnedFileError(.cancelled) }
            state.offset += Int64(bytes.count)
        }
        return Data(bytes)
    }

    private func beginOperation() throws {
        try state.withLock { state in
            guard !state.cancelled else { throw OwnedFileError(.cancelled) }
            guard !state.inFlight else { throw OwnedFileError(.operationInFlight) }
            state.inFlight = true
        }
    }
    private func endOperation() { state.withLock { $0.inFlight = false } }
    private func checkCancellation() throws {
        try Task.checkCancellation()
        if state.withLock({ $0.cancelled }) { throw OwnedFileError(.cancelled) }
    }
}
