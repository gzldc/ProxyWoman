import Foundation

/// Blocking AF_UNIX stream helpers shared by the stdio helper and the app-side server.
public enum UnixSocket {
    public enum Failure: Error, Equatable {
        case pathTooLong
        case connectFailed(Int32)
        case listenFailed(Int32)
        case bindFailed(Int32)
    }

    /// Builds a `sockaddr_un` for `path`. Throws `.pathTooLong` when the UTF-8 length exceeds
    /// `MCPPaths.maxSocketPathBytes` (103, leaving room for the NUL in the 104-byte `sun_path`).
    public static func address(for path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8)
        guard bytes.count <= MCPPaths.maxSocketPathBytes else { throw Failure.pathTooLong }
        // An embedded NUL would silently truncate the path.
        guard !bytes.contains(0) else { throw Failure.connectFailed(EINVAL) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            for (index, byte) in bytes.enumerated() { destination[index] = byte }
            destination[bytes.count] = 0
        }
        return address
    }

    /// Connects a blocking stream socket to `path`. The descriptor is close-on-exec and never raises
    /// SIGPIPE. The caller owns the descriptor.
    public static func connect(path: String) throws -> Int32 {
        var address = try address(for: path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.connectFailed(errno) }
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            let code = errno
            close(fd)
            throw Failure.connectFailed(code)
        }
        var on: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            let code = errno
            close(fd)
            throw Failure.connectFailed(code)
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw Failure.connectFailed(code)
        }
        return fd
    }

    /// Writes all of `data`, looping over partial writes and retrying on EINTR. A non-blocking
    /// descriptor that would block is waited on with `poll`. Returns false on any other error
    /// (EPIPE, ECONNRESET, EBADF...). The descriptor should not raise SIGPIPE (`SO_NOSIGPIPE`).
    public static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, base + offset, raw.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                        let ready = poll(&descriptor, 1, -1)
                        if ready < 0 && errno != EINTR { return false }
                        continue
                    }
                }
                return false
            }
            return true
        }
    }
}
