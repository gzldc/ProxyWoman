import Darwin
import Foundation
import RulesEngine
import os

/// A stable, directory-specific flock shared by independent runtimes and processes. The marker
/// is never removed: unlinking it could let another opener lock a different inode. Crash recovery
/// relies on the kernel releasing the descriptor lock, not on stale PID/metadata guesses.
/// Acquire and release run only on the server's existing file executor.
final class SpoolDirectoryOwner: Sendable {
    static let markerName = ".proxywoman-spool-owner"
    private let descriptor: OSAllocatedUnfairLock<Int32>

    private init(descriptor: Int32) { self.descriptor = OSAllocatedUnfairLock(initialState: descriptor) }

    static func acquire(directory: URL, createMissing: Bool) throws -> SpoolDirectoryOwner {
        let directoryFD = try openDirectory(directory, createMissing: createMissing)
        defer { close(directoryFD) }
        let fd = openat(directoryFD, markerName, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw OwnedFileError(.ioFailure, errno: errno) }
        do {
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw OwnedFileError(.ioFailure, errno: errno) }
            guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
                  info.st_mode & 0o777 == 0o600, info.st_nlink == 1 else { throw OwnedFileError(.notRegularFile) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw OwnedFileError(.ioFailure, errno: errno) }
            return SpoolDirectoryOwner(descriptor: fd)
        } catch { close(fd); throw error }
    }

    /// No chmod of existing components; each component is opened relative to its checked parent.
    /// Root/system-owned ancestors are allowed, while the dedicated directory must be ours/0700.
    private static func openDirectory(_ directory: URL, createMissing: Bool) throws -> Int32 {
        let components = directory.pathComponents
        guard components.first == "/", components.count > 1,
              components.dropFirst().allSatisfy({ $0 != "." && $0 != ".." }) else { throw OwnedFileError(.invalidName) }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw OwnedFileError(.ioFailure, errno: errno) }
        do {
            var names = Array(components.dropFirst())
            // macOS's one concrete system alias; never canonicalize caller-controlled ancestors.
            let systemVar = try names.first == "var" && isSystemVarAlias(rootFD: fd)
            if systemVar { names.replaceSubrange(0...0, with: ["private", "var"]) }
            for (index, name) in names.enumerated() {
                var child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if child < 0, errno == ENOENT, createMissing, !(systemVar && index < 2) {
                    if mkdirat(fd, name, 0o700) != 0, errno != EEXIST { throw OwnedFileError(.ioFailure, errno: errno) }
                    child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard child >= 0 else { throw OwnedFileError(.ioFailure, errno: errno) }
                close(fd); fd = child
                var info = stat()
                guard fstat(fd, &info) == 0 else { throw OwnedFileError(.ioFailure, errno: errno) }
                guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() || info.st_uid == 0 else {
                    throw OwnedFileError(.notRegularFile)
                }
                if systemVar && index < 2 && info.st_uid != 0 { throw OwnedFileError(.notRegularFile) }
                if index == names.count - 1 {
                    guard info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else { throw OwnedFileError(.notRegularFile) }
                }
            }
            return fd
        } catch { close(fd); throw error }
    }

    private static func isSystemVarAlias(rootFD: Int32) throws -> Bool {
        var info = stat()
        guard fstatat(rootFD, "var", &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw OwnedFileError(.ioFailure, errno: errno) }
        guard info.st_mode & S_IFMT == S_IFLNK else { return false }
        guard info.st_uid == 0 else { throw OwnedFileError(.notRegularFile) }
        var bytes = [UInt8](repeating: 0, count: 256)
        let count = bytes.withUnsafeMutableBytes { readlinkat(rootFD, "var", $0.baseAddress!, $0.count) }
        guard count > 0, count < bytes.count else { throw OwnedFileError(.notRegularFile) }
        let target = String(decoding: bytes.prefix(count), as: UTF8.self)
        guard target == "private/var" || target == "/private/var" else { throw OwnedFileError(.notRegularFile) }
        return true
    }

    /// Called after the runtime's pins (including unlink callbacks) have drained, before pool stop.
    func release() {
        let fd = descriptor.withLock { value in defer { value = -1 }; return value }
        if fd >= 0 { close(fd) }
    }
}
