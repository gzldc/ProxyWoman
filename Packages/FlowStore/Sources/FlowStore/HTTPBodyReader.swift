import Foundation
import os

/// A refcounted, close-once reader over one body. Reads are bounded to 65,536 bytes, run on a
/// private serial queue outside every store/registry lock, and fail once the lease is cancelled
/// or the underlying managed body has been removed from the store. A read that is already in
/// progress may settle; the file and the registry reader slot are released afterwards.
public final class HTTPBodyReadLease: Sendable {
    public static let maxReadBytes = 65_536

    enum Source: Sendable {
        case memory(Data)
        case file(Int32)
    }

    private struct State {
        var cancelled = false
        var closed = false
        var inFlight = 0
    }

    public let size: Int
    private let source: Source
    private let owner: (registry: HTTPBodyRegistry, id: HTTPBodyID)?
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "proxywoman.body-read")

    init(size: Int, source: Source, owner: (registry: HTTPBodyRegistry, id: HTTPBodyID)?) {
        self.size = size
        self.source = source
        self.owner = owner
    }

    deinit { finish() }

    /// Reads up to `maxBytes` (clamped to 65,536) at `offset`; empty at end of body.
    public func read(offset: Int, maxBytes: Int) async throws -> Data {
        try Task.checkCancellation()
        // Fail fast: a queued read never waits behind a blocked one just to learn it was revoked.
        try checkAvailable()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try self.readChunk(offset: offset, maxBytes: maxBytes) })
            }
        }
    }

    /// Idempotent. New reads fail at once; resources are released when none is in flight.
    public func cancel() {
        if state.withLock({ state in
            state.cancelled = true
            return state.inFlight == 0 && !state.closed
        }) { finish() }
    }

    /// Synchronous backend shared by the async API and the legacy `BodyRef.load` paths.
    func readChunk(offset: Int, maxBytes: Int) throws -> Data {
        guard offset >= 0, offset <= size else { throw HTTPBodyError.invalidRange }
        try begin()
        defer { end() }
        owner?.registry.readHook.withLock { $0 }?()
        let count = min(max(0, maxBytes), Self.maxReadBytes, size - offset)
        guard count > 0 else { return Data() }
        switch source {
        case .memory(let data):
            let start = data.startIndex + offset
            return Data(data[start..<start + count])
        case .file(let descriptor):
            return try Self.pread(descriptor, offset: offset, count: count)
        }
    }

    private func checkAvailable() throws {
        try state.withLock { state in
            guard !state.cancelled, !state.closed else { throw HTTPBodyError.cancelled }
            if let owner, !owner.registry.isLive(owner.id) { throw HTTPBodyError.revoked }
        }
    }

    private func begin() throws {
        try state.withLock { state in
            guard !state.cancelled, !state.closed else { throw HTTPBodyError.cancelled }
            if let owner, !owner.registry.isLive(owner.id) { throw HTTPBodyError.revoked }
            state.inFlight += 1
        }
    }

    private func end() {
        if state.withLock({ state in
            state.inFlight -= 1
            return state.cancelled && state.inFlight == 0 && !state.closed
        }) { finish() }
    }

    private func finish() {
        guard state.withLock({ state in
            defer { state.closed = true }
            return !state.closed
        }) else { return }
        if case .file(let descriptor) = source { close(descriptor) }
        if let owner { HTTPBodyRegistry.discard(owner.registry.releaseReader(owner.id)) }
    }

    private static func pread(_ descriptor: Int32, offset: Int, count: Int) throws -> Data {
        var data = Data(count: count)
        var done = 0
        while done < count {
            let n = data.withUnsafeMutableBytes { buffer in
                Darwin.pread(descriptor, buffer.baseAddress! + done, count - done, off_t(offset + done))
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw HTTPBodyError.unreadable
            }
            if n == 0 { throw HTTPBodyError.unreadable }
            done += n
        }
        return data
    }

    static func openBorrowedFile(_ url: URL) throws -> Int32 {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC) }
        guard descriptor >= 0 else { throw HTTPBodyError.unreadable }
        return descriptor
    }
}

extension HTTPBodyRegistry {
    func acquire(_ handle: HTTPBodyHandle) throws -> HTTPBodyReadLease {
        let grant = try acquireReader(handle)
        switch grant.storage {
        case .memory(let data):
            return HTTPBodyReadLease(size: grant.size, source: .memory(data), owner: (self, handle.id))
        case .file(let url):
            do {
                let descriptor = try HTTPBodyReadLease.openBorrowedFile(url)
                return HTTPBodyReadLease(size: grant.size, source: .file(descriptor), owner: (self, handle.id))
            } catch {
                HTTPBodyRegistry.discard(releaseReader(handle.id))
                throw error
            }
        }
    }
}

extension HTTPBodyHandle {
    /// Bounded range read through a revocable lease, in bounded chunks.
    func load(offset: Int, maxBytes: Int) throws -> Data {
        let lease = try registry.acquire(self)
        defer { lease.cancel() }
        let wanted = max(0, min(maxBytes, size - offset))
        var data = Data()
        data.reserveCapacity(wanted)
        while data.count < wanted {
            let chunk = try lease.readChunk(offset: offset + data.count, maxBytes: wanted - data.count)
            guard !chunk.isEmpty else { throw HTTPBodyError.unreadable }
            data.append(chunk)
        }
        return data
    }

    /// Legacy synchronous whole-body read, in bounded chunks.
    func load(maxBytes: Int) throws -> (data: Data, isTruncated: Bool) {
        let limit = max(0, maxBytes)
        let lease = try registry.acquire(self)
        defer { lease.cancel() }
        let wanted = min(size, limit)
        var data = Data()
        data.reserveCapacity(wanted)
        while data.count < wanted {
            let chunk = try lease.readChunk(offset: data.count, maxBytes: wanted - data.count)
            guard !chunk.isEmpty else { throw HTTPBodyError.unreadable }
            data.append(chunk)
        }
        return (data, size > limit)
    }
}
