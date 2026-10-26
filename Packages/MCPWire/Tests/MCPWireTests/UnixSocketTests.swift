import Foundation
import Testing

@testable import MCPWire

@Suite struct UnixSocketTests {
    private final class Scratch {
        let root: URL
        init() throws {
            // Keep the path short: sockaddr_un.sun_path holds 104 bytes.
            root = URL(fileURLWithPath: "/tmp", isDirectory: true)
                .appendingPathComponent("mw-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        deinit { try? FileManager.default.removeItem(at: root) }
    }

    @Test func rejectsOverlongPath() {
        let fits = "/" + String(repeating: "a", count: 102)
        #expect(fits.utf8.count == 103)
        #expect(throws: Never.self) { try UnixSocket.address(for: fits) }

        let tooLong = fits + "a"
        #expect(throws: UnixSocket.Failure.pathTooLong) { try UnixSocket.address(for: tooLong) }
        #expect(throws: UnixSocket.Failure.pathTooLong) { try UnixSocket.connect(path: tooLong) }
    }

    @Test func addressCarriesFamilyAndPath() throws {
        var address = try UnixSocket.address(for: "/tmp/x.sock")
        #expect(address.sun_family == sa_family_t(AF_UNIX))
        let path = withUnsafePointer(to: &address.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: 104) { String(cString: $0) }
        }
        #expect(path == "/tmp/x.sock")
    }

    @Test func connectToListeningSocketAndWriteAll() throws {
        let scratch = try Scratch()
        let path = scratch.root.appendingPathComponent("s.sock").path

        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(server >= 0)
        defer { close(server) }
        var address = try UnixSocket.address(for: path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(bound == 0)
        #expect(listen(server, 1) == 0)

        let client = try UnixSocket.connect(path: path)
        defer { close(client) }
        #expect((fcntl(client, F_GETFD) & FD_CLOEXEC) != 0)
        var noSigPipe: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        #expect(getsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, &length) == 0)
        #expect(noSigPipe != 0)

        let accepted = accept(server, nil, nil)
        #expect(accepted >= 0)
        defer { close(accepted) }

        // Larger than the default socket buffer so writeAll has to loop over partial writes while the
        // reader drains concurrently.
        let payload = Data((0..<600_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let collected = Collector()
        let done = DispatchSemaphore(value: 0)
        let reader = Thread {
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(accepted, $0.baseAddress, $0.count) }
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { break }
                collected.append(Data(buffer[0..<count]))
            }
            done.signal()
        }
        reader.start()

        #expect(UnixSocket.writeAll(client, payload))
        shutdown(client, SHUT_WR)
        #expect(done.wait(timeout: .now() + 10) == .success)
        #expect(collected.data == payload)
    }

    @Test func writeAllReportsFailureOnClosedPeer() throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        var on: Int32 = 1
        setsockopt(fds[0], SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        close(fds[1])
        defer { close(fds[0]) }
        #expect(!UnixSocket.writeAll(fds[0], Data("x".utf8)))
    }

    @Test func connectFailureIsReported() throws {
        let scratch = try Scratch()
        let missing = scratch.root.appendingPathComponent("nobody.sock").path
        #expect(throws: UnixSocket.Failure.connectFailed(ENOENT)) { try UnixSocket.connect(path: missing) }

        // A socket file nobody listens on is refused.
        let stale = scratch.root.appendingPathComponent("stale.sock").path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try UnixSocket.address(for: stale)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(bound == 0)
        close(fd)
        #expect(throws: UnixSocket.Failure.connectFailed(ECONNREFUSED)) { try UnixSocket.connect(path: stale) }
    }

    /// Lock-protected byte sink shared with the reader thread.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()
        func append(_ data: Data) { lock.withLock { storage.append(data) } }
        var data: Data { lock.withLock { storage } }
    }
}
