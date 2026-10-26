import Foundation

public struct MCPHandshake: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var pid: Int32
    public var socketPath: String
    public var token: String
    public var startedAt: Date

    public init(version: Int, pid: Int32, socketPath: String, token: String, startedAt: Date) {
        self.version = version
        self.pid = pid
        self.socketPath = socketPath
        self.token = token
        self.startedAt = startedAt
    }
}

public enum MCPPaths {
    public static let handshakeFileName = "mcp-handshake.json"
    public static let socketFileName = "mcp.sock"
    /// `sockaddr_un.sun_path` holds 104 bytes on Darwin including the terminating NUL.
    public static let maxSocketPathBytes = 103

    /// `<Application Support>/<appName>/MCP`
    public static func standardDirectory(applicationSupport: URL, appName: String) -> URL {
        applicationSupport
            .appendingPathComponent(appName, isDirectory: true)
            .appendingPathComponent("MCP", isDirectory: true)
    }

    /// Isolated mode keeps everything directly in the isolated root.
    public static func isolatedDirectory(root: URL) -> URL { root }

    public static func handshakeURL(in directory: URL) -> URL {
        directory.appendingPathComponent(handshakeFileName, isDirectory: false)
    }

    public static func socketURL(in directory: URL) -> URL {
        directory.appendingPathComponent(socketFileName, isDirectory: false)
    }

    /// True when the path fits `sun_path`. Checks both the UTF-8 length of `url.path` and the file
    /// system representation (which can be longer after Unicode normalization).
    public static func fitsSocketPath(_ url: URL) -> Bool {
        guard url.path.utf8.count <= maxSocketPathBytes else { return false }
        let representationLength = url.withUnsafeFileSystemRepresentation { pointer in
            pointer.map { strlen($0) } ?? Int.max
        }
        return representationLength <= maxSocketPathBytes
    }
}

public enum HandshakeFile {
    public enum Failure: Error, Equatable {
        case missing
        /// Owned by another user, or not readable by this user.
        case notOwnedByUser
        case tooPermissive
        case tooLarge
        /// Not a regular file (symlink, directory, FIFO...), unparsable, or an invalid token.
        case malformed
        case unsupportedVersion
    }

    static let maxFileBytes = 4096

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func posixError(_ code: Int32 = errno) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    /// Writes via a same-directory temp file (`O_CREAT|O_EXCL`, 0600), fsync, then `rename` over the
    /// destination, so a reader sees either the old or the new file. A missing directory is created
    /// with mode 0700; an existing directory's permissions are never changed.
    public static func write(_ handshake: MCPHandshake, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            // Do not depend on the umask or on which levels the attributes applied to.
            guard chmod(directory.path, 0o700) == 0 else { throw posixError() }
        }

        let payload = try makeEncoder().encode(handshake)
        let temp = directory.appendingPathComponent(".\(MCPPaths.handshakeFileName).\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError() }
        var committed = false
        defer {
            if !committed { unlink(temp.path) }
        }
        do {
            guard fchmod(fd, 0o600) == 0 else { throw posixError() }
            try payload.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw posixError()
                    }
                    offset += written
                }
            }
            guard fsync(fd) == 0 else { throw posixError() }
        } catch {
            close(fd)
            throw error
        }
        guard close(fd) == 0 else { throw posixError() }
        guard rename(temp.path, url.path) == 0 else { throw posixError() }
        committed = true
    }

    /// Validates and decodes a handshake file. Requires: a regular file reached without following a
    /// symlink, owned by the effective user, no group/other permission bits, at most 4096 bytes,
    /// version 1, and a 64-character lowercase-hex token.
    public static func read(at url: URL) throws -> MCPHandshake {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            switch errno {
            case ENOENT, ENOTDIR: throw Failure.missing
            case EACCES, EPERM: throw Failure.notOwnedByUser
            default: throw Failure.malformed  // includes ELOOP for a symlink
            }
        }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Failure.malformed }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw Failure.malformed }
        guard info.st_uid == geteuid() else { throw Failure.notOwnedByUser }
        guard (info.st_mode & 0o077) == 0 else { throw Failure.tooPermissive }
        guard info.st_size <= off_t(maxFileBytes) else { throw Failure.tooLarge }

        // Read at most one byte past the limit so a file that grew after fstat is still caught.
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 1024)
        while data.count <= maxFileBytes {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw Failure.malformed
            }
            if count == 0 { break }
            data.append(chunk, count: count)
        }
        guard data.count <= maxFileBytes else { throw Failure.tooLarge }

        struct VersionProbe: Decodable { var version: Int }
        let probe: VersionProbe
        do {
            probe = try JSONDecoder().decode(VersionProbe.self, from: data)
        } catch {
            throw Failure.malformed
        }
        guard probe.version == MCPHandshake.currentVersion else { throw Failure.unsupportedVersion }

        let handshake: MCPHandshake
        do {
            handshake = try makeDecoder().decode(MCPHandshake.self, from: data)
        } catch {
            throw Failure.malformed
        }
        guard isValidToken(handshake.token) else { throw Failure.malformed }
        return handshake
    }

    /// Removes the file; a missing file is not an error.
    public static func remove(at url: URL) {
        unlink(url.path)
    }

    private static func isValidToken(_ token: String) -> Bool {
        let bytes = token.utf8
        guard bytes.count == 64 else { return false }
        return bytes.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }
}
