import Foundation

public enum CertKitError: Error, Equatable, Sendable {
    case invalidHost(String)
    /// The CA files on disk are unusable (corrupt, incomplete, or the key does not match the
    /// certificate). They are never regenerated automatically: doing so would silently invalidate
    /// a root the user has already trusted.
    case corruptStore(String)
    case ioFailure(String)
}

/// Persists the root CA certificate and private key as PEM files in a directory.
public struct CAStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `root-ca.pem`: shown in Finder and usable with `curl --cacert`.
    public var certificateURL: URL { directory.appendingPathComponent("root-ca.pem") }
    var privateKeyURL: URL { directory.appendingPathComponent("root-ca-key.pem") }

    /// Returns nil when neither file exists; throws when only one exists or a file is unreadable.
    public func load() throws -> (certificatePEM: String, privateKeyPEM: String)? {
        let fm = FileManager.default
        let hasCert = fm.fileExists(atPath: certificateURL.path)
        let hasKey = fm.fileExists(atPath: privateKeyURL.path)
        switch (hasCert, hasKey) {
        case (false, false):
            return nil
        case (true, true):
            do {
                return (
                    try String(contentsOf: certificateURL, encoding: .utf8),
                    try String(contentsOf: privateKeyURL, encoding: .utf8)
                )
            } catch {
                throw CertKitError.corruptStore("cannot read CA files: \(error)")
            }
        default:
            throw CertKitError.corruptStore(
                "only one of \(certificateURL.lastPathComponent) and \(privateKeyURL.lastPathComponent) exists in \(directory.path)"
            )
        }
    }

    /// Writes both files, creating the directory (0700) if needed. Each file is created with its
    /// final permissions (key 0600, certificate 0644) and moved into place atomically.
    public func save(certificatePEM: String, privateKeyPEM: String) throws {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            throw CertKitError.ioFailure("cannot create \(directory.path): \(error)")
        }
        try write(Data(privateKeyPEM.utf8), to: privateKeyURL, mode: 0o600)
        try write(Data(certificatePEM.utf8), to: certificateURL, mode: 0o644)
    }

    private func write(_ data: Data, to url: URL, mode: mode_t) throws {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, mode)
        guard fd >= 0 else {
            throw CertKitError.ioFailure("cannot create \(tmp.path): errno \(errno)")
        }
        do {
            defer { close(fd) }
            // umask may have stripped bits from `mode`; fix it on the fd before any data is written.
            guard fchmod(fd, mode) == 0 else { throw CertKitError.ioFailure("fchmod: errno \(errno)") }
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw CertKitError.ioFailure("write: errno \(errno)")
                    }
                    offset += n
                }
            }
            guard fsync(fd) == 0 else { throw CertKitError.ioFailure("fsync: errno \(errno)") }
        } catch {
            unlink(tmp.path)
            throw error
        }
        guard rename(tmp.path, url.path) == 0 else {
            unlink(tmp.path)
            throw CertKitError.ioFailure("rename to \(url.path): errno \(errno)")
        }
    }
}
