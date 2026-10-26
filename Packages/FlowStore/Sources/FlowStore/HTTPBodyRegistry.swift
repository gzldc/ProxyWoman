import Foundation
import os

/// Opaque identity of one store-owned captured body.
public struct HTTPBodyID: Hashable, Sendable {
    let rawValue: UUID
    init() { rawValue = UUID() }
}

/// Opaque reference to a body the store itself created and registered. It carries identity and
/// the immutable size only: no file URL and no raw bytes. Equality is registry identity + id.
/// Holding a handle never keeps a removed body alive; reads simply fail once it is revoked.
public struct HTTPBodyHandle: Sendable, Equatable {
    public let id: HTTPBodyID
    public let size: Int
    /// Immutable storage metadata only; exposes no file path, performs no I/O, and does not
    /// guarantee the body is still live or keep it alive after removal.
    public let isOnDisk: Bool
    let registry: HTTPBodyRegistry
    /// Shared by every copy; abandons the producer claim when the last copy dies unaccepted.
    private let producer: HTTPBodyProducerClaim

    init(id: HTTPBodyID, size: Int, isOnDisk: Bool, registry: HTTPBodyRegistry) {
        self.id = id
        self.size = size
        self.isOnDisk = isOnDisk
        self.registry = registry
        producer = HTTPBodyProducerClaim(registry: registry, id: id)
    }

    public static func == (lhs: HTTPBodyHandle, rhs: HTTPBodyHandle) -> Bool {
        lhs.id == rhs.id && lhs.registry === rhs.registry
    }
}

/// Safety net for a finished body that is dropped before any store accepted it.
final class HTTPBodyProducerClaim: Sendable {
    let registry: HTTPBodyRegistry
    let id: HTTPBodyID

    init(registry: HTTPBodyRegistry, id: HTTPBodyID) {
        self.registry = registry
        self.id = id
    }

    deinit { HTTPBodyRegistry.discard(registry.abandonProducer(id)) }
}

public enum HTTPBodyError: Error, Equatable {
    /// The body was removed from the store (or never accepted by it): the record was cleared.
    case revoked
    case cancelled
    case invalidRange
    case unreadable

    /// True when the record was cleared, as opposed to an I/O error.
    public var isRevoked: Bool { self == .revoked }
}

/// Ownership table for captured HTTP bodies. Only files created through `registerCreatedFile`
/// can ever be unlinked by the store; ownership is never inferred from a path or extension.
///
/// Lock order: `FlowStore.state` may call into the registry, never the other way round.
/// Registry operations do no disk I/O; they hand back `Reclaim` tickets that the caller
/// unlinks after every lock is released.
final class HTTPBodyRegistry: Sendable {
    /// A file that is no longer owned or read by anyone and may now be unlinked.
    struct Reclaim: Sendable {
        let url: URL
    }

    enum RetainOutcome: Equatable {
        /// Dead, foreign or unknown body: nothing is charged and nothing is owned.
        case rejected
        /// First flow reference: the caller charges the unique retained bytes once.
        case first
        case alias
    }

    struct ReleaseOutcome {
        /// The last flow reference went away: the caller discharges the unique bytes.
        var unreferenced = false
        var reclaim: Reclaim?
    }

    struct OwnershipSnapshot: Equatable {
        var retainedBodies = 0
        var retainedMemoryBytes = 0
        var retainedDiskBytes = 0
        var producerClaims = 0
        var readers = 0
        var cells = 0
    }

    enum Storage {
        case memory(Data)
        case file(URL)
    }

    private struct Cell {
        var storage: Storage
        var size: Int
        var flowReferences: [Int: Int] = [:]
        var producerClaim = true
        var readers = 0
        var isLive: Bool { producerClaim || !flowReferences.isEmpty }
    }

    private let cells = OSAllocatedUnfairLock(initialState: [HTTPBodyID: Cell]())
    /// Test seam: runs inside a started read, outside every lock.
    let readHook = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)

    // MARK: Producer side

    /// An exclusively created capture file. Owned by the producer until a store accepts it.
    func registerCreatedFile(_ url: URL) -> HTTPBodyID {
        let id = HTTPBodyID()
        cells.withLock { $0[id] = Cell(storage: .file(url), size: 0) }
        return id
    }

    func registerMemory(_ data: Data) -> HTTPBodyHandle {
        let id = HTTPBodyID()
        cells.withLock { $0[id] = Cell(storage: .memory(data), size: data.count) }
        return HTTPBodyHandle(id: id, size: data.count, isOnDisk: false, registry: self)
    }

    /// Fixes the final size of a created file and hands out its handle (producer claim stays).
    func seal(_ id: HTTPBodyID, size: Int) -> HTTPBodyHandle? {
        let sealed = cells.withLock { cells -> Bool in
            guard cells[id] != nil else { return false }
            cells[id]?.size = size
            return true
        }
        return sealed ? HTTPBodyHandle(id: id, size: size, isOnDisk: true, registry: self) : nil
    }

    /// Releases the producer claim (idempotent). Deletes the body unless a flow still owns it.
    func abandonProducer(_ id: HTTPBodyID) -> Reclaim? {
        cells.withLock { cells in
            guard var cell = cells[id], cell.producerClaim else { return nil }
            cell.producerClaim = false
            cells[id] = cell
            return Self.settle(id, &cells)
        }
    }

    // MARK: Flow ownership

    /// Store acceptance. Consumes the producer claim; a dead body cannot be re-owned.
    func retainForFlow(_ handle: HTTPBodyHandle, flowID: Int) -> RetainOutcome {
        guard handle.registry === self else { return .rejected }
        return cells.withLock { cells in
            guard var cell = cells[handle.id], cell.isLive else { return .rejected }
            let outcome: RetainOutcome = cell.flowReferences.isEmpty ? .first : .alias
            cell.flowReferences[flowID, default: 0] += 1
            cell.producerClaim = false
            cells[handle.id] = cell
            return outcome
        }
    }

    func releaseForFlow(_ handle: HTTPBodyHandle, flowID: Int) -> ReleaseOutcome {
        guard handle.registry === self else { return ReleaseOutcome() }
        return cells.withLock { cells in
            guard var cell = cells[handle.id], let count = cell.flowReferences[flowID], count > 0 else {
                return ReleaseOutcome()
            }
            cell.flowReferences[flowID] = count > 1 ? count - 1 : nil
            cells[handle.id] = cell
            return ReleaseOutcome(unreferenced: cell.flowReferences.isEmpty, reclaim: Self.settle(handle.id, &cells))
        }
    }

    // MARK: Readers

    struct ReaderGrant {
        let storage: Storage
        let size: Int
    }

    func acquireReader(_ handle: HTTPBodyHandle) throws -> ReaderGrant {
        guard handle.registry === self else { throw HTTPBodyError.revoked }
        return try cells.withLock { cells in
            guard var cell = cells[handle.id], cell.isLive else { throw HTTPBodyError.revoked }
            cell.readers += 1
            cells[handle.id] = cell
            return ReaderGrant(storage: cell.storage, size: cell.size)
        }
    }

    func isLive(_ id: HTTPBodyID) -> Bool {
        cells.withLock { $0[id]?.isLive ?? false }
    }

    func releaseReader(_ id: HTTPBodyID) -> Reclaim? {
        cells.withLock { cells in
            guard var cell = cells[id], cell.readers > 0 else { return nil }
            cell.readers -= 1
            cells[id] = cell
            return Self.settle(id, &cells)
        }
    }

    // MARK: Inspection

    func snapshot() -> OwnershipSnapshot {
        cells.withLock { cells in
            var result = OwnershipSnapshot()
            result.cells = cells.count
            for cell in cells.values {
                if !cell.flowReferences.isEmpty {
                    result.retainedBodies += 1
                    if case .memory = cell.storage { result.retainedMemoryBytes += cell.size } else {
                        result.retainedDiskBytes += cell.size
                    }
                }
                if cell.producerClaim { result.producerClaims += 1 }
                result.readers += cell.readers
            }
            return result
        }
    }

    /// Test inspection only: the path a registered body lives at.
    func fileURL(for handle: HTTPBodyHandle) -> URL? {
        cells.withLock { cells in
            if case .file(let url)? = cells[handle.id]?.storage { url } else { nil }
        }
    }

    // MARK: Helpers

    /// Drops a body nobody owns or reads; returns the file to unlink once no lock is held.
    private static func settle(_ id: HTTPBodyID, _ cells: inout [HTTPBodyID: Cell]) -> Reclaim? {
        guard let cell = cells[id], !cell.isLive, cell.readers == 0 else { return nil }
        cells[id] = nil
        if case .file(let url) = cell.storage { return Reclaim(url: url) }
        return nil
    }

    /// `unlink(2)` on the exact registered path: it never follows a symlink at the final component
    /// and never recurses into a directory.
    static func discard(_ reclaim: Reclaim?) {
        if let reclaim { _ = reclaim.url.path.withCString { Darwin.unlink($0) } }
    }

    static func discard(_ reclaims: [Reclaim]) {
        reclaims.forEach { discard($0) }
    }
}
