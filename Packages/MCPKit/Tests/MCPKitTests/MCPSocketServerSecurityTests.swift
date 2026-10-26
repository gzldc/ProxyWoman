import Foundation
import MCPWire
import Testing
import os

@testable import MCPKit

/// Binds a socket at `path` and closes it without listening: what a crashed instance leaves behind.
private func leaveStaleSocket(at path: String) throws {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    #expect(fd >= 0)
    defer { close(fd) }
    var address = try UnixSocket.address(for: path)
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    #expect(bound == 0)
}

private func makeDirectory(_ url: URL, mode: mode_t) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    #expect(chmod(url.path, mode) == 0)
}

// Serialized for the same reason as MCPSocketServerTests: tests block their thread in poll().
@Suite(.serialized) struct MCPSocketServerSecurityTests {
    // MARK: Hello

    @Test func wrongTokenIsClosedWithoutReply() throws {
        let scratch = try SocketScratch()
        let h = ServerHarness(directory: scratch.standard)
        try h.server.start()

        let wrong = try h.client()
        #expect(wrong.sendHello(token: String(repeating: "0", count: 64)))
        #expect(wrong.readToEOF() == Data())

        // A prefix of the real token, and the real token with a request appended, change nothing.
        let prefix = try h.client()
        #expect(prefix.sendHello(token: String(h.server.token.prefix(63))))
        #expect(prefix.readToEOF() == Data())

        // A request instead of a hello is never executed.
        let tool = try h.client()
        #expect(tool.sendLine(callTool(1, "list_things")))
        #expect(tool.readToEOF() == Data())

        #expect(h.sessionCount == 0)
        #expect(h.audit.snapshot().isEmpty)
    }

    @Test func missingHelloTimesOut() throws {
        let scratch = try SocketScratch()
        let h = ServerHarness(directory: scratch.standard, configure: { $0.helloTimeout = .milliseconds(400) })
        try h.server.start()
        // The hello deadline starts at accept, which is after this instant: EOF can never come earlier
        // than 400 ms from here.
        let begin = ContinuousClock.now
        let silent = try h.client()
        #expect(silent.readLine(timeout: .milliseconds(200)) == .timeout)  // still open at about half time
        #expect(silent.send("{"))  // a probe write is still accepted
        // The 400 ms bound is the behaviour under test; the 10 s bound only keeps a failure from hanging.
        #expect(silent.readToEOF(timeout: .seconds(10)) == Data())
        #expect(ContinuousClock.now - begin >= .milliseconds(400))

        // A client that trickles an unterminated hello is cut off by the same deadline.
        let slow = try h.client()
        #expect(slow.send(#"{"hello":{"token":""#))
        #expect(slow.readToEOF(timeout: .seconds(10)) == Data())
        #expect(h.server.waitForConnectionCount(0, timeout: .seconds(10)))
    }

    @Test func lateHelloWithinTimeoutIsAccepted() throws {
        let scratch = try SocketScratch()
        let h = ServerHarness(directory: scratch.standard, configure: { $0.helloTimeout = .seconds(5) })
        try h.server.start()
        let client = try h.client()
        let hello = String(decoding: MCPHello(token: h.server.token, client: "late", protocolVersion: 1).line(), as: UTF8.self)
        let half = hello.index(hello.startIndex, offsetBy: hello.count / 2)
        #expect(client.send(String(hello[..<half])))
        #expect(client.readLine(timeout: .milliseconds(150)) == .timeout)  // waiting, not refused
        #expect(client.sendLine(String(hello[half...])))
        #expect(client.readLine() == .line(#"{"ok":true}"#))
        #expect(client.sendLine(ping(1)))
        #expect(client.readJSON()?["id"] == .int(1))
    }

    @Test func authenticatedIdleConnectionOutlivesHelloTimeout() throws {
        let scratch = try SocketScratch()
        let h = ServerHarness(directory: scratch.standard, configure: { $0.helloTimeout = .milliseconds(200) })
        try h.server.start()
        let client = try h.authenticatedClient()
        #expect(client.readLine(timeout: .milliseconds(600)) == .timeout)  // three hello timeouts, still open
        #expect(client.sendLine(ping(1)))
        #expect(client.readJSON()?["id"] == .int(1))
    }

    @Test func helloLineIsCappedAtExactly4KiB() throws {
        let scratch = try SocketScratch()
        let h = ServerHarness(directory: scratch.standard)
        try h.server.start()
        func hello(length: Int) -> Data {
            let base = MCPHello(token: h.server.token, client: "", protocolVersion: 1).line().count
            var line = MCPHello(
                token: h.server.token, client: String(repeating: "a", count: length - base), protocolVersion: 1
            ).line()
            #expect(line.count == length)
            line.append(0x0A)
            return line
        }
        let fits = try h.client()
        #expect(UnixSocket.writeAll(fits.fd, hello(length: MCPSocketServer.maxHelloBytes)))
        #expect(fits.readLine() == .line(#"{"ok":true}"#))

        let over = try h.client()
        #expect(UnixSocket.writeAll(over.fd, hello(length: MCPSocketServer.maxHelloBytes + 1)))
        #expect(over.readToEOF() == Data())
    }

    @Test func garbageHelloIsClosed() throws {
        let scratch = try SocketScratch()
        let h = ServerHarness(directory: scratch.standard)
        try h.server.start()
        let token = h.server.token

        let lines = [
            "not json",
            "{}",
            #"{"hello":"nope"}"#,
            #"{"token":"\#(token)","client":"x","protocolVersion":1}"#,
            #"{"hello":{"token":"\#(token)","client":"x"}}"#,
            #"{"hello":{"token":"\#(token)","client":"x","protocolVersion":"1"}}"#,
            #"{"hello":{"token":"\#(token)","client":"x","protocolVersion":2}}"#,
            #"{"hello":{"token":"\#(token)","client":"x","protocolVersion":0}}"#,
        ]
        for line in lines {
            let client = try h.client()
            #expect(client.sendLine(line))
            #expect(client.readToEOF() == Data(), "\(line)")
        }

        // An oversized hello (no newline in the first 4 KiB) is refused without waiting for the timeout.
        let huge = try h.client()
        // The server closes as soon as it has read more than 4 KiB without a newline, so the rest of the 9000
        // bytes may already meet a closed socket (EPIPE/ECONNRESET): whether the write succeeds is a race.
        _ = huge.send(#"{"hello":{"client":""# + String(repeating: "a", count: 9000))
        #expect(huge.readToEOF() == Data())
        #expect(h.sessionCount == 0)
    }

    @Test func peerUIDMismatchIsRejected() throws {
        let scratch = try SocketScratch()
        let h = ServerHarness(directory: scratch.standard, peerCheck: { _ in false })
        try h.server.start()
        let client = try h.client()
        _ = client.sendHello(token: h.server.token)  // may already fail with EPIPE
        #expect(client.readToEOF() == Data())
        #expect(h.sessionCount == 0)
        #expect(h.server.waitForConnectionCount(0, timeout: .seconds(10)))
    }

    @Test func defaultPeerCheckComparesEffectiveUID() throws {
        var pair: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer {
            close(pair[0])
            close(pair[1])
        }
        #expect(MCPSocketServer.peerIsCurrentUser(pair[0]))
        #expect(!MCPSocketServer.peerIsCurrentUser(-1))
    }

    @Test func connectionLimitRejectsNinth() throws {
        let scratch = try SocketScratch()
        // A long hello timeout, so an EOF below can only come from the limit.
        let h = ServerHarness(directory: scratch.standard, configure: { $0.helloTimeout = .seconds(60) })
        try h.server.start()

        var clients: [TestClient] = []
        for _ in 0..<8 { clients.append(try h.authenticatedClient()) }
        #expect(h.server.connectionCount == 8)

        let silentNinth = try h.client()  // sends nothing at all
        #expect(silentNinth.readToEOF() == Data())
        let ninth = try h.client()
        _ = ninth.sendHello(token: h.server.token)
        #expect(ninth.readToEOF() == Data())
        #expect(h.server.connectionCount == 8)
        #expect(h.sessionCount == 8)

        clients.removeLast()
        #expect(h.server.waitForConnectionCount(7, timeout: .seconds(10)))
        let replacement = try h.authenticatedClient()
        #expect(replacement.sendLine(ping(1)))
        #expect(replacement.readJSON()?["id"] == .int(1))
    }

    @Test func connectionLimitCountsClientsStillInHello() throws {
        let scratch = try SocketScratch()
        let h = ServerHarness(directory: scratch.standard, configure: {
            $0.maxConnections = 2
            $0.helloTimeout = .seconds(60)
        })
        try h.server.start()
        let idleA = try h.client()
        let idleB = try h.client()
        #expect(h.server.waitForConnectionCount(2, timeout: .seconds(10)))
        let third = try h.client()  // silent too: closed by the limit, not by the 60 s hello timeout
        #expect(third.readToEOF() == Data())
        _ = (idleA, idleB)
    }

    // MARK: Socket path

    @Test func staleSocketIsReplaced() throws {
        let scratch = try SocketScratch()
        try makeDirectory(scratch.standard, mode: 0o700)
        let socketPath = MCPPaths.socketURL(in: scratch.standard).path
        try leaveStaleSocket(at: socketPath)
        #expect(fileType(socketPath) == S_IFSOCK)
        #expect(throws: (any Error).self) { try TestClient(path: socketPath) }  // nobody listens

        let h = ServerHarness(directory: scratch.standard)
        try h.server.start()
        let client = try h.authenticatedClient()
        #expect(client.sendLine(ping(1)))
        #expect(client.readJSON()?["id"] == .int(1))
    }

    @Test func regularFileAtSocketPathIsNeverDeleted() throws {
        let scratch = try SocketScratch()
        try makeDirectory(scratch.standard, mode: 0o700)
        let socketURL = MCPPaths.socketURL(in: scratch.standard)
        let h = ServerHarness(directory: scratch.standard)

        try Data("keep me".utf8).write(to: socketURL)
        #expect(throws: MCPSocketServer.StartFailure.directoryUnsafe) { try h.server.start() }
        #expect(try Data(contentsOf: socketURL) == Data("keep me".utf8))

        // A symlink (even to a live-looking target) and a directory are refused and left alone too.
        #expect(unlink(socketURL.path) == 0)
        let target = scratch.root.appendingPathComponent("target")
        try Data("target".utf8).write(to: target)
        #expect(symlink(target.path, socketURL.path) == 0)
        #expect(throws: MCPSocketServer.StartFailure.directoryUnsafe) { try h.server.start() }
        #expect(fileType(socketURL.path) == S_IFLNK)
        #expect(try Data(contentsOf: target) == Data("target".utf8))

        #expect(unlink(socketURL.path) == 0)
        #expect(mkdir(socketURL.path, 0o700) == 0)
        #expect(throws: MCPSocketServer.StartFailure.directoryUnsafe) { try h.server.start() }
        #expect(fileType(socketURL.path) == S_IFDIR)
        #expect(fileType(h.handshakePath) == nil)
        #expect(!h.server.isRunning)
    }

    @Test func liveInstanceYieldsAlreadyRunning() throws {
        let scratch = try SocketScratch()
        let first = ServerHarness(directory: scratch.standard)
        try first.server.start()
        let token = first.server.token

        do {
            let second = ServerHarness(directory: scratch.standard)
            #expect(throws: MCPSocketServer.StartFailure.alreadyRunning) { try second.server.start() }
            #expect(!second.server.isRunning)
        }  // the failed instance is stopped and released here; it must not remove the live files

        #expect(fileType(first.socketPath) == S_IFSOCK)
        #expect(try HandshakeFile.read(at: MCPPaths.handshakeURL(in: first.directory)).token == token)
        let client = try first.authenticatedClient()
        #expect(client.sendLine(ping(1)))
        #expect(client.readJSON()?["id"] == .int(1))
    }

    @Test func overlongDirectoryPathFailsWithPathTooLong() throws {
        let scratch = try SocketScratch()
        // <root>/<long>/mcp.sock is longer than 103 bytes.
        let long = scratch.root.appendingPathComponent(String(repeating: "d", count: 100), isDirectory: true)
        #expect(MCPPaths.socketURL(in: long).path.utf8.count > MCPPaths.maxSocketPathBytes)
        let h = ServerHarness(directory: long)
        #expect(throws: MCPSocketServer.StartFailure.pathTooLong) { try h.server.start() }
        #expect(fileType(long.path) == nil)  // nothing was created

        let isolated = ServerHarness(directory: long, createsDirectory: false)
        try makeDirectory(long, mode: 0o700)
        #expect(throws: MCPSocketServer.StartFailure.pathTooLong) { try isolated.server.start() }
    }

    @Test func sharedIsolatedRootStagesTheBindInAPrivateDirectory() throws {
        // A 0755 isolated root lets other users reach its entries, so the socket is bound inside a private
        // staging directory and moved into place; the root's own mode is left as the user set it.
        let scratch = try SocketScratch()
        let root = scratch.root.appendingPathComponent("iso", isDirectory: true)
        try makeDirectory(root, mode: 0o755)
        let h = ServerHarness(directory: root, createsDirectory: false)
        try h.server.start()
        #expect(permissions(root.path) == 0o755)
        #expect(fileType(h.socketPath) == S_IFSOCK)
        #expect(permissions(h.socketPath) == 0o600)
        #expect(permissions(h.handshakePath) == 0o600)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        #expect(names == [MCPPaths.handshakeFileName, MCPPaths.socketFileName])
        let client = try h.authenticatedClient()
        #expect(client.sendLine(ping(1)))
        #expect(client.readJSON()?["id"] == .int(1))
        h.server.stop()
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func sharedRootWhoseStagingPathDoesNotFitFailsClosed() throws {
        let scratch = try SocketScratch()
        // The final socket path fits (103 bytes) but the staged one would not.
        let used = scratch.root.path.utf8.count + 1 + 1 + MCPPaths.socketFileName.utf8.count
        let name = String(repeating: "s", count: MCPPaths.maxSocketPathBytes - used)
        let root = scratch.root.appendingPathComponent(name, isDirectory: true)
        #expect(MCPPaths.socketURL(in: root).path.utf8.count == MCPPaths.maxSocketPathBytes)
        try makeDirectory(root, mode: 0o755)
        let h = ServerHarness(directory: root, createsDirectory: false)
        #expect(throws: MCPSocketServer.StartFailure.pathTooLong) { try h.server.start() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)

        // The same length in a private directory binds directly.
        #expect(chmod(root.path, 0o700) == 0)
        try h.server.start()
        _ = try h.authenticatedClient()
    }

    // MARK: Directory

    @Test func groupWritableDirectoryIsRejected() throws {
        for mode: mode_t in [0o770, 0o702, 0o777] {
            let scratch = try SocketScratch()
            try makeDirectory(scratch.standard, mode: mode)
            let standard = ServerHarness(directory: scratch.standard)
            #expect(throws: MCPSocketServer.StartFailure.directoryUnsafe) { try standard.server.start() }
            let isolated = ServerHarness(directory: scratch.standard, createsDirectory: false)
            #expect(throws: MCPSocketServer.StartFailure.directoryUnsafe) { try isolated.server.start() }
            #expect(permissions(scratch.standard.path) == mode)  // never "fixed" by widening or narrowing
            #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.standard.path).isEmpty)
        }
    }

    @Test func existingStandardDirectoryIsTightenedTo0700() throws {
        let scratch = try SocketScratch()
        try makeDirectory(scratch.standard, mode: 0o755)
        let h = ServerHarness(directory: scratch.standard)
        try h.server.start()
        #expect(permissions(scratch.standard.path) == 0o700)
    }

    @Test func symlinkedDirectoryIsRejected() throws {
        let scratch = try SocketScratch()
        let real = scratch.root.appendingPathComponent("real", isDirectory: true)
        try makeDirectory(real, mode: 0o700)
        let link = scratch.root.appendingPathComponent("link", isDirectory: true)
        #expect(symlink(real.path, link.path) == 0)

        let standard = ServerHarness(directory: link)
        #expect(throws: MCPSocketServer.StartFailure.directoryUnsafe) { try standard.server.start() }
        let isolated = ServerHarness(directory: link, createsDirectory: false)
        #expect(throws: MCPSocketServer.StartFailure.directoryUnsafe) { try isolated.server.start() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: real.path).isEmpty)
    }

    @Test func missingIsolatedRootIsNotCreated() throws {
        let scratch = try SocketScratch()
        let h = ServerHarness(directory: scratch.standard, createsDirectory: false)
        #expect(throws: MCPSocketServer.StartFailure.directoryUnsafe) { try h.server.start() }
        #expect(fileType(scratch.standard.path) == nil)
    }

    @Test func fileAtDirectoryPathIsRejected() throws {
        let scratch = try SocketScratch()
        try Data("x".utf8).write(to: scratch.standard)
        let h = ServerHarness(directory: scratch.standard)
        #expect(throws: MCPSocketServer.StartFailure.directoryUnsafe) { try h.server.start() }
        #expect(fileType(scratch.standard.path) == S_IFREG)
    }

    @Test func staleHandshakeTempFilesAreSwept() throws {
        let scratch = try SocketScratch()
        try makeDirectory(scratch.standard, mode: 0o700)
        let directory = scratch.standard
        let stale = directory.appendingPathComponent(".mcp-handshake.json.\(UUID().uuidString).tmp")
        try Data(#"{"token":"secret"}"#.utf8).write(to: stale)
        #expect(chmod(stale.path, 0o600) == 0)
        // Not ours to remove: a directory with a matching name, and unrelated files.
        let lookalikeDirectory = directory.appendingPathComponent(".mcp-handshake.json.dir.tmp")
        #expect(mkdir(lookalikeDirectory.path, 0o700) == 0)
        let unrelated = directory.appendingPathComponent("notes.tmp")
        try Data("keep".utf8).write(to: unrelated)
        let almost = directory.appendingPathComponent(".mcp-handshake.json.tmp.keep")
        try Data("keep".utf8).write(to: almost)

        let h = ServerHarness(directory: directory)
        try h.server.start()
        #expect(fileType(stale.path) == nil)
        #expect(fileType(lookalikeDirectory.path) == S_IFDIR)
        #expect(fileType(unrelated.path) == S_IFREG)
        #expect(fileType(almost.path) == S_IFREG)
    }

    @Test func liveInstanceKeepsItsTempFiles() throws {
        // The sweep runs only once the directory is ours: a refused start touches nothing.
        let scratch = try SocketScratch()
        let first = ServerHarness(directory: scratch.standard)
        try first.server.start()
        let temp = scratch.standard.appendingPathComponent(".mcp-handshake.json.\(UUID().uuidString).tmp")
        try Data("x".utf8).write(to: temp)
        let second = ServerHarness(directory: scratch.standard)
        #expect(throws: MCPSocketServer.StartFailure.alreadyRunning) { try second.server.start() }
        #expect(fileType(temp.path) == S_IFREG)
    }

    // MARK: Failure paths

    @Test func probeErrorsOtherThanRefusedNeverDeleteTheSocket() throws {
        let scratch = try SocketScratch()
        try makeDirectory(scratch.standard, mode: 0o700)
        let socketPath = MCPPaths.socketURL(in: scratch.standard).path
        try leaveStaleSocket(at: socketPath)
        let identity = try #require(lstatInfo(socketPath)).st_ino

        let cases: [(Int32, MCPSocketServer.StartFailure)] = [
            (EMFILE, .bindFailed(EMFILE)),
            (EACCES, .bindFailed(EACCES)),
            (EINTR, .bindFailed(EINTR)),
            (EAGAIN, .alreadyRunning),  // a live listener whose backlog is full
            (ETIMEDOUT, .alreadyRunning),
        ]
        for (code, expected) in cases {
            var calls = SocketCalls()
            calls.connect = { _ in throw UnixSocket.Failure.connectFailed(code) }
            let h = ServerHarness(directory: scratch.standard, calls: calls)
            #expect(throws: expected) { try h.server.start() }
            #expect(lstatInfo(socketPath)?.st_ino == identity, "errno \(code)")
            #expect(fileType(h.handshakePath) == nil)
        }

        // Only a definite refusal means stale.
        var refused = SocketCalls()
        refused.connect = { _ in throw UnixSocket.Failure.connectFailed(ECONNREFUSED) }
        let h = ServerHarness(directory: scratch.standard, calls: refused)
        try h.server.start()
        #expect(lstatInfo(socketPath)?.st_ino != identity)
        _ = try h.authenticatedClient()
    }

    @Test func bindFailureLeavesNothingAndRestoresUmask() throws {
        for shared in [false, true] {
            let scratch = try SocketScratch()
            let directory = scratch.root.appendingPathComponent("d", isDirectory: true)
            try makeDirectory(directory, mode: shared ? 0o755 : 0o700)
            let maskDuringBind = OSAllocatedUnfairLock<mode_t?>(initialState: nil)
            var calls = SocketCalls()
            calls.bind = { _, _ in
                let mask = umask(0)  // bind runs under the server's umask lock: read and restore
                umask(mask)
                maskDuringBind.withLock { $0 = mask }
                return EADDRINUSE
            }
            let before = MCPSocketServer.currentUmask()
            let h = ServerHarness(directory: directory, createsDirectory: false, calls: calls)
            #expect(throws: MCPSocketServer.StartFailure.bindFailed(EADDRINUSE)) { try h.server.start() }
            #expect(maskDuringBind.withLock { $0 } == 0o077)
            #expect(MCPSocketServer.currentUmask() == before)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
            #expect(!h.server.isRunning)
        }
    }

    @Test func umaskIsRestoredAfterSuccessAndAfterALaterFailure() throws {
        struct NoRandom: Error {}
        let before = MCPSocketServer.currentUmask()
        let scratch = try SocketScratch()
        let h = ServerHarness(directory: scratch.standard)
        try h.server.start()
        #expect(MCPSocketServer.currentUmask() == before)
        h.server.stop()

        let failing = ServerHarness(directory: scratch.standard, makeToken: { throw NoRandom() })
        #expect(throws: MCPSocketServer.StartFailure.tokenFailed) { try failing.server.start() }
        #expect(MCPSocketServer.currentUmask() == before)
    }

    @Test func handshakeWriteFailureIsReportedAndCleanedUp() throws {
        let scratch = try SocketScratch()
        try makeDirectory(scratch.standard, mode: 0o700)
        let h = ServerHarness(directory: scratch.standard)
        // A directory where the handshake goes: the final rename fails with EISDIR.
        #expect(mkdir(h.handshakePath, 0o700) == 0)
        #expect(throws: MCPSocketServer.StartFailure.handshakeFailed(EISDIR)) { try h.server.start() }
        #expect(!h.server.isRunning)
        #expect(fileType(h.socketPath) == nil)
        #expect(fileType(h.handshakePath) == S_IFDIR)  // not ours to remove
        let names = try FileManager.default.contentsOfDirectory(atPath: scratch.standard.path)
        #expect(names == [MCPPaths.handshakeFileName])  // no temp file left

        #expect(rmdir(h.handshakePath) == 0)
        try h.server.start()
        _ = try h.authenticatedClient()
    }

    @Test func directoryCreationErrorsKeepTheirErrno() throws {
        let scratch = try SocketScratch()
        #expect(chmod(scratch.root.path, 0o500) == 0)  // restored by SocketScratch.deinit
        let direct = ServerHarness(directory: scratch.standard)
        #expect(throws: MCPSocketServer.StartFailure.directoryFailed(EACCES)) { try direct.server.start() }
        let nested = ServerHarness(
            directory: scratch.root.appendingPathComponent("a/MCP", isDirectory: true))
        #expect(throws: MCPSocketServer.StartFailure.directoryFailed(EACCES)) { try nested.server.start() }
    }

    @Test func acceptLoopDeathMarksTheServerStopped() throws {
        let scratch = try SocketScratch()
        var calls = SocketCalls()
        calls.accept = { _ in (-1, EBADF) }
        let h = ServerHarness(directory: scratch.standard, calls: calls)
        try h.server.start()
        #expect(h.server.isRunning)

        let client = try h.client()  // queued in the backlog; the failing accept ends the loop
        #expect(client.readToEOF() != nil)  // the listener was closed after the run shut down
        #expect(!h.server.isRunning)
        #expect(h.server.token.isEmpty)
        #expect(fileType(h.socketPath) == nil)
        #expect(fileType(h.handshakePath) == nil)

        // A dead run does not block a new start.
        try h.server.start()
        #expect(h.server.isRunning)
        h.server.stop()
    }

    // MARK: Source scan

    @Test func noTCPListener() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MCPKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // MCPKit
            .appendingPathComponent("Sources/MCPKit/MCPSocketServer.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        #expect(text.contains("AF_UNIX"))
        for forbidden in ["AF_INET", "PF_INET", "INADDR", "sockaddr_in", "print(", "NSLog", "FileHandle.standardOutput"] {
            #expect(!text.contains(forbidden), "\(forbidden)")
        }
    }
}
