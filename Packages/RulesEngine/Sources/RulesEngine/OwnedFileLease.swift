import Darwin
import Foundation
import os

/// A typed owned-file failure with a stable code; `errno` is diagnostic only.
public struct OwnedFileError: Error, Equatable, Sendable {
    public enum Code: String, Sendable, Equatable {
        /// The source is a directory, symlink, FIFO, socket or device.
        case notRegularFile
        /// The source's identity, size or modification time changed while it was copied.
        case sourceChanged
        /// Fewer bytes than the descriptor reported could be read.
        case shortRead
        /// The single-file or single-body limit.
        case fileTooLarge
        /// A service-wide budget is exhausted.
        case capacityExceeded
        /// Writing would leave less than the free-disk floor.
        case insufficientDiskSpace
        case ioFailure
        case cancelled
        case unknownAsset
        /// A known asset whose private copy is missing, damaged or unreadable.
        case assetUnavailable
        /// Another read or append is still in flight on the same source.
        case operationInFlight
        /// A chunk bigger than `ioChunkBytes`.
        case chunkTooLarge
        /// The body ended with a different length than announced.
        case lengthMismatch
        case invalidName
    }

    public var code: Code
    public var errno: Int32?

    public init(_ code: Code, errno: Int32? = nil) {
        self.code = code
        self.errno = errno
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.code == rhs.code }
}

/// Runs blocking file work off every event loop, actor and state lock. `active` is false when the
/// executor is shutting down; the work must then fail without touching the file.
package typealias OwnedFileRunner = @Sendable (@escaping @Sendable (_ active: Bool) -> Void) -> Void

extension OwnedFiles {
    /// Awaits one blocking job on `runner`.
    package static func run<T: Sendable>(
        on runner: OwnedFileRunner, _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            runner { active in
                guard active else { return continuation.resume(throwing: OwnedFileError(.cancelled)) }
                continuation.resume(with: Result { try body() })
            }
        }
    }
}

package enum OwnedFileRunners {
    /// One serial queue: file work of its owner never runs concurrently or unbounded.
    package static func serialQueue(label: String) -> OwnedFileRunner {
        let queue = DispatchQueue(label: label, qos: .utility)
        return { work in queue.async { work(true) } }
    }
}

/// Identity of an opened regular file, taken from its descriptor.
package struct RegularFileIdentity: Sendable, Equatable {
    var device: Int32
    var inode: UInt64
    package var size: Int64
    var modifiedSeconds: Int
    var modifiedNanoseconds: Int
}

/// Low-level descriptor primitives shared by managed assets and ProxyCore body files. Nothing here
/// accepts a path that the owner did not construct itself, except `openRegularSource` (read-only).
package enum OwnedFiles {
    /// Creates (or tightens) a private 0700 directory that is a real directory, not a symlink.
    package static func preparePrivateDirectory(_ directory: URL) throws {
        let path = directory.path
        if mkdir(path, 0o700) != 0, errno != EEXIST { throw OwnedFileError(.ioFailure, errno: errno) }
        var info = stat()
        guard lstat(path, &info) == 0 else { throw OwnedFileError(.ioFailure, errno: errno) }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { throw OwnedFileError(.notRegularFile) }
        if info.st_mode & 0o777 != 0o700, chmod(path, 0o700) != 0 { throw OwnedFileError(.ioFailure, errno: errno) }
    }

    /// Opens a user-chosen file read-only without following a final symlink and without blocking on
    /// a FIFO, then confirms through `fstat` that the descriptor is a regular file.
    package static func openRegularSource(_ url: URL) throws -> (descriptor: Int32, identity: RegularFileIdentity) {
        let descriptor = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard descriptor >= 0 else {
            throw errno == ELOOP ? OwnedFileError(.notRegularFile) : OwnedFileError(.ioFailure, errno: errno)
        }
        do {
            let identity = try identity(of: descriptor)
            return (descriptor, identity)
        } catch {
            close(descriptor)
            throw error
        }
    }

    package static func identity(of descriptor: Int32) throws -> RegularFileIdentity {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw OwnedFileError(.ioFailure, errno: errno) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw OwnedFileError(.notRegularFile) }
        return RegularFileIdentity(
            device: info.st_dev, inode: info.st_ino, size: Int64(info.st_size),
            modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec)
    }

    /// `O_CREAT | O_EXCL | O_NOFOLLOW`, mode 0600, as a direct child of an owner directory.
    package static func createExclusive(_ name: String, in directory: URL) throws -> Int32 {
        try checkName(name)
        let path = directory.appendingPathComponent(name).path
        let descriptor = path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) }
        guard descriptor >= 0 else { throw OwnedFileError(.ioFailure, errno: errno) }
        return descriptor
    }

    /// Opens an owner-named file for reading, refusing symlinks and anything not regular.
    package static func openOwned(_ name: String, in directory: URL) throws -> (descriptor: Int32, identity: RegularFileIdentity) {
        try checkName(name)
        return try openRegularSource(directory.appendingPathComponent(name))
    }

    package static func writeAll(_ descriptor: Int32, _ bytes: UnsafeRawBufferPointer) throws {
        var done = 0
        while done < bytes.count {
            let n = write(descriptor, bytes.baseAddress! + done, bytes.count - done)
            if n < 0 {
                if errno == EINTR { continue }
                throw OwnedFileError(errno == ENOSPC ? .insufficientDiskSpace : .ioFailure, errno: errno)
            }
            done += n
        }
    }

    /// Reads exactly `count` bytes at `offset`; a short read is an error, never a smaller success.
    package static func preadExact(_ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer, offset: Int64) throws {
        var done = 0
        while done < buffer.count {
            let n = pread(descriptor, buffer.baseAddress! + done, buffer.count - done, off_t(offset) + off_t(done))
            if n < 0 {
                if errno == EINTR { continue }
                throw OwnedFileError(.ioFailure, errno: errno)
            }
            if n == 0 { throw OwnedFileError(.shortRead) }
            done += n
        }
    }

    /// `full`: `F_FULLFSYNC` (flushes the drive cache) for durable commits, falling back to `fsync`
    /// where the file system does not support it. Transient spools use plain `fsync`.
    package static func sync(_ descriptor: Int32, full: Bool = false) throws {
        if full, fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        guard fsync(descriptor) == 0 else { throw OwnedFileError(.ioFailure, errno: errno) }
    }

    package static func syncDirectory(_ directory: URL, full: Bool = false) throws {
        let descriptor = directory.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
        guard descriptor >= 0 else { throw OwnedFileError(.ioFailure, errno: errno) }
        defer { close(descriptor) }
        try sync(descriptor, full: full)
    }

    /// True when `directory` is a real directory (not a symlink), owned by this user, mode 0700.
    package static func isPrivateDirectory(_ directory: URL) -> Bool {
        var info = stat()
        guard lstat(directory.path, &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid() && info.st_mode & 0o777 == 0o700
    }

    /// Startup sweep of an owner directory: unlinks only names `isOwnedName` accepts that are not
    /// in `keep` and are regular files owned by this user. Does nothing unless the directory itself
    /// is verified private first; never follows symlinks or recurses.
    package static func sweep(_ directory: URL, keep: Set<String> = [], isOwnedName: (String) -> Bool) {
        guard isPrivateDirectory(directory),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where !keep.contains(name) && isOwnedName(name) {
            var info = stat()
            guard lstat(directory.appendingPathComponent(name).path, &info) == 0,
                  info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { continue }
            unlinkOwned(name, in: directory)
        }
    }

    /// `prefix + canonical UUID + suffix`, exactly.
    package static func isUUIDName(_ name: String, prefix: String = "", suffix: String = "") -> Bool {
        guard name.hasPrefix(prefix), name.hasSuffix(suffix), name.count > prefix.count + suffix.count else { return false }
        let stem = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        return UUID(uuidString: stem)?.uuidString == stem
    }

    /// Atomically replaces `to` with `from`, both owner-named direct children of `directory`.
    package static func rename(_ from: String, to: String, in directory: URL) throws {
        try checkName(from)
        try checkName(to)
        let result = directory.appendingPathComponent(from).path.withCString { source in
            directory.appendingPathComponent(to).path.withCString { Darwin.rename(source, $0) }
        }
        guard result == 0 else { throw OwnedFileError(.ioFailure, errno: errno) }
    }

    /// `unlink(2)` of an owner-named direct child; never follows a symlink, never recurses.
    package static func unlinkOwned(_ name: String, in directory: URL) {
        guard (try? checkName(name)) != nil else { return }
        _ = directory.appendingPathComponent(name).path.withCString { unlink($0) }
    }

    /// Owner names are single path components made of letters, digits, `-`, `_` and `.`,
    /// never `.`/`..`; a caller can never smuggle a path through them.
    private static func checkName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
              name.utf8.allSatisfy({ $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: ".")
                  || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0)
                  || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0) })
        else { throw OwnedFileError(.invalidName) }
    }
}

/// Copies an opened regular file into a new owner temp file, chunk by chunk. Runs synchronously on
/// the caller's file executor. No atomic snapshot of the source is promised: the descriptor identity,
/// size and modification time are checked before and after, and any change or short read fails.
package struct RegularFileCopy {
    package var source: URL
    package var directory: URL
    package var tempName: String
    package var finalName: String
    package var chunkBytes: Int
    package var budgets: OwnedFileBudgets
    package var isCancelled: @Sendable () -> Bool
    /// Test seam after each chunk (bytes copied so far).
    package var afterChunk: (@Sendable (Int64) -> Void)?

    package init(
        source: URL, directory: URL, tempName: String, finalName: String, chunkBytes: Int,
        budgets: OwnedFileBudgets, isCancelled: @escaping @Sendable () -> Bool, afterChunk: (@Sendable (Int64) -> Void)? = nil
    ) {
        self.source = source
        self.directory = directory
        self.tempName = tempName
        self.finalName = finalName
        self.chunkBytes = chunkBytes
        self.budgets = budgets
        self.isCancelled = isCancelled
        self.afterChunk = afterChunk
    }

    /// Opens the source and checks it before any reservation is made by the caller.
    package static func inspect(_ source: URL) throws -> RegularFileIdentity {
        let opened = try OwnedFiles.openRegularSource(source)
        close(opened.descriptor)
        return opened.identity
    }

    /// Copies exactly `expected.size` bytes and publishes `finalName` by rename. On failure the temp
    /// file is unlinked before returning, so the caller may release its reservation.
    package func run(expected: RegularFileIdentity) throws {
        let opened = try OwnedFiles.openRegularSource(source)
        defer { close(opened.descriptor) }
        guard opened.identity == expected else { throw OwnedFileError(.sourceChanged) }
        try OwnedFiles.preparePrivateDirectory(directory)
        let output = try OwnedFiles.createExclusive(tempName, in: directory)
        var published = false
        defer {
            close(output)
            if !published { OwnedFiles.unlinkOwned(tempName, in: directory) }
        }
        let chunk = max(1, chunkBytes)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunk, alignment: 16)
        defer { buffer.deallocate() }
        var copied: Int64 = 0
        while copied < expected.size {
            guard !isCancelled() else { throw OwnedFileError(.cancelled) }
            let count = Int(min(Int64(chunk), expected.size - copied))
            let reservation = try budgets.reserve(category: .io, bytes: Int64(count))
            defer { reservation.release() }
            try budgets.ensureFreeDisk(in: directory, adding: Int64(count))
            let slice = UnsafeMutableRawBufferPointer(rebasing: buffer[0..<count])
            try OwnedFiles.preadExact(opened.descriptor, into: slice, offset: copied)
            try OwnedFiles.writeAll(output, UnsafeRawBufferPointer(slice))
            copied += Int64(count)
            afterChunk?(copied)
        }
        // A file that grew past the announced size is a change, not a prefix to keep.
        var probe: UInt8 = 0
        let extra = pread(opened.descriptor, &probe, 1, off_t(copied))
        guard extra == 0, try OwnedFiles.identity(of: opened.descriptor) == expected else {
            throw OwnedFileError(.sourceChanged)
        }
        guard !isCancelled() else { throw OwnedFileError(.cancelled) }
        try OwnedFiles.sync(output, full: true)
        try OwnedFiles.rename(tempName, to: finalName, in: directory)
        published = true
        try? OwnedFiles.syncDirectory(directory, full: true)
    }
}

/// A read-only lease on one owned file. The descriptor stays open until the lease is cancelled
/// (or deinitialized) and no read is in flight; then the owner's release runs exactly once. Only
/// the owner that created the lease decides what that release does (for example unlinking its own
/// file); the holder can never delete anything.
public final class OwnedFileLease: Sendable {
    public let size: Int64
    /// Opaque identity of the leased file (an asset ID or a spool ID); never a path.
    public let id: UUID

    private struct State {
        var cancelled = false
        var closed = false
        var inFlight = false
    }

    private let descriptor: Int32
    private let chunkBytes: Int
    private let budgets: OwnedFileBudgets
    private let runner: OwnedFileRunner
    private let onRelease: @Sendable () -> Void
    private let state = OSAllocatedUnfairLock(initialState: State())

    package init(
        id: UUID, size: Int64, descriptor: Int32, chunkBytes: Int, budgets: OwnedFileBudgets,
        runner: @escaping OwnedFileRunner, onRelease: @escaping @Sendable () -> Void
    ) {
        self.id = id
        self.size = size
        self.descriptor = descriptor
        self.chunkBytes = max(1, chunkBytes)
        self.budgets = budgets
        self.runner = runner
        self.onRelease = onRelease
    }

    deinit { finish() }

    /// Reads up to `maxBytes` (at most `ioChunkBytes`) at `offset`; empty at the end. The read buffer
    /// is charged to the shared I/O budget until it is returned. One read at a time per lease.
    public func read(offset: Int64, maxBytes: Int) async throws -> Data {
        guard offset >= 0, offset <= size else { throw OwnedFileError(.ioFailure, errno: EINVAL) }
        let count = Int(min(Int64(max(0, min(maxBytes, chunkBytes))), size - offset))
        try state.withLock { state in
            guard !state.cancelled, !state.closed else { throw OwnedFileError(.cancelled) }
            guard !state.inFlight else { throw OwnedFileError(.operationInFlight) }
            state.inFlight = true
        }
        defer { end() }
        guard count > 0 else { return Data() }
        let reservation = try budgets.reserve(category: .io, bytes: Int64(count))
        defer { reservation.release() }
        let descriptor = self.descriptor
        return try await OwnedFiles.run(on: runner) {
            var data = Data(count: count)
            try data.withUnsafeMutableBytes { try OwnedFiles.preadExact(descriptor, into: $0, offset: offset) }
            return data
        }
    }

    /// Idempotent. New reads fail at once; the file is released once no read is in flight.
    public func cancel() {
        if state.withLock({ state in
            state.cancelled = true
            return !state.inFlight && !state.closed
        }) { finish() }
    }

    private func end() {
        if state.withLock({ state in
            state.inFlight = false
            return state.cancelled && !state.closed
        }) { finish() }
    }

    private func finish() {
        guard state.withLock({ state in
            defer { state.closed = true }
            return !state.closed
        }) else { return }
        close(descriptor)
        onRelease()
    }
}
