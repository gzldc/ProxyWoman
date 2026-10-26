import Foundation
import MCPWire
import Testing
import os

@testable import MCPKit

// MARK: - Helpers shared by the socket server suites

/// A short scratch directory under /tmp (`sockaddr_un.sun_path` holds 104 bytes).
final class SocketScratch {
    let root: URL

    init() throws {
        root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("mks-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        #expect(chmod(root.path, 0o700) == 0)
    }

    deinit {
        // Restore permissions a test may have narrowed or widened, then delete everything.
        _ = chmod(root.path, 0o700)
        try? FileManager.default.removeItem(at: root)
    }

    /// The standard-layout directory (not created yet).
    var standard: URL { root.appendingPathComponent("MCP", isDirectory: true) }
}

/// Mode bits and type of a path, without following a final symlink.
func lstatInfo(_ path: String) -> stat? {
    var info = stat()
    return lstat(path, &info) == 0 ? info : nil
}

func fileType(_ path: String) -> mode_t? { lstatInfo(path).map { $0.st_mode & S_IFMT } }
func permissions(_ path: String) -> mode_t? { lstatInfo(path).map { $0.st_mode & 0o7777 } }

/// A blocking POSIX client. Every wait is a `poll` bounded by a timeout, never a sleep.
final class TestClient {
    enum Read: Equatable {
        case line(String)
        case eof
        case timeout
    }

    let fd: Int32
    private var pending = Data()

    init(path: String) throws {
        fd = try UnixSocket.connect(path: path)
    }

    /// Takes over a descriptor that is not a socket connection (for example the read end of a pipe); it is
    /// closed with the client.
    init(adopting descriptor: Int32) {
        fd = descriptor
    }

    deinit { close(fd) }

    @discardableResult func send(_ text: String) -> Bool { UnixSocket.writeAll(fd, Data(text.utf8)) }
    @discardableResult func sendLine(_ text: String) -> Bool { send(text + "\n") }

    @discardableResult func sendHello(token: String, protocolVersion: Int = 1, client: String = "tests") -> Bool {
        var line = MCPHello(token: token, client: client, protocolVersion: protocolVersion).line()
        line.append(0x0A)
        return UnixSocket.writeAll(fd, line)
    }

    /// Ends the request direction; the server sees EOF.
    func halfClose() { shutdown(fd, SHUT_WR) }

    /// Reads into `pending`. False on EOF/reset, nil on timeout.
    private func fill(until deadline: ContinuousClock.Instant) -> Bool? {
        while true {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { return nil }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(clamping: Int((remaining / .milliseconds(1)).rounded(.up))))
            if ready < 0 {
                if errno == EINTR { continue }
                return false
            }
            if ready == 0 { continue }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return false  // ECONNRESET counts as closed
            }
            if count == 0 { return false }
            pending.append(contentsOf: buffer[0..<count])
            return true
        }
    }

    func readLine(timeout: Duration = .seconds(10)) -> Read {
        let deadline = ContinuousClock.now + timeout
        while true {
            if let newline = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                pending = Data(pending[pending.index(after: newline)...])
                return .line(line)
            }
            switch fill(until: deadline) {
            case nil: return .timeout
            case false?: return .eof
            case true?: continue
            }
        }
    }

    /// The next line parsed as JSON; records an issue and returns nil otherwise.
    func readJSON(timeout: Duration = .seconds(10), sourceLocation: SourceLocation = #_sourceLocation)
        -> JSONValue?
    {
        let read = readLine(timeout: timeout)
        guard case .line(let text) = read else {
            Issue.record("expected a line, got \(read)", sourceLocation: sourceLocation)
            return nil
        }
        guard let value = try? JSONValue.parse(Data(text.utf8)) else {
            Issue.record("not JSON: \(text)", sourceLocation: sourceLocation)
            return nil
        }
        return value
    }

    /// Every byte until the server closes; nil when it did not close within `timeout`.
    func readToEOF(timeout: Duration = .seconds(10)) -> Data? {
        let deadline = ContinuousClock.now + timeout
        while true {
            switch fill(until: deadline) {
            case nil: return nil
            case false?:
                defer { pending = Data() }
                return pending
            case true?: continue
            }
        }
    }
}

/// A real server bound in a scratch directory, with sessions built from fake tools.
final class ServerHarness {
    let directory: URL
    let server: MCPSocketServer
    let audit = MCPAuditLog()
    private let sessions = OSAllocatedUnfairLock(initialState: 0)

    var sessionCount: Int { sessions.withLock { $0 } }
    var socketPath: String { MCPPaths.socketURL(in: directory).path }
    var handshakePath: String { MCPPaths.handshakeURL(in: directory).path }

    init(
        directory: URL, createsDirectory: Bool = true,
        tools: [any MCPTool] = [FakeTool(name: "list_things")],
        configure: (inout MCPSocketServer.Configuration) -> Void = { _ in },
        peerCheck: @escaping @Sendable (Int32) -> Bool = MCPSocketServer.peerIsCurrentUser,
        makeToken: @escaping @Sendable () throws -> String = MCPToken.generate,
        calls: SocketCalls = SocketCalls()
    ) {
        self.directory = directory
        var configuration = MCPSocketServer.Configuration(
            directory: directory, createsDirectory: createsDirectory)
        configure(&configuration)
        let runner = MCPToolRunner(tools: tools, policy: MCPPolicyProvider(enabledSettings()), audit: audit)
        let counter = sessions
        server = MCPSocketServer(
            configuration: configuration,
            makeSession: {
                counter.withLock { $0 += 1 }
                return MCPSession(runner: runner, app: MCPAppInfo(name: "ProxyWoman", version: "9.9"))
            },
            peerCheck: peerCheck, makeToken: makeToken, calls: calls)
    }

    deinit { server.stop() }

    func client() throws -> TestClient { try TestClient(path: socketPath) }

    /// A client that has completed the hello.
    func authenticatedClient(sourceLocation: SourceLocation = #_sourceLocation) throws -> TestClient {
        let client = try client()
        #expect(client.sendHello(token: server.token), sourceLocation: sourceLocation)
        #expect(client.readLine() == .line(#"{"ok":true}"#), sourceLocation: sourceLocation)
        return client
    }
}

func ping(_ id: Int) -> String { #"{"jsonrpc":"2.0","id":\#(id),"method":"ping"}"# }

func callTool(_ id: Int, _ name: String) -> String {
    #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(name)","arguments":{}}}"#
}

/// Lets a tool handler wait until its task is cancelled, with no polling.
final class CancellationGate: Sendable {
    private struct State: Sendable {
        var continuation: CheckedContinuation<Void, Never>?
        var cancelled = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func waitForCancellation() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { state -> Bool in
                    if state.cancelled { return true }
                    state.continuation = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
                state.cancelled = true
                defer { state.continuation = nil }
                return state.continuation
            }
            continuation?.resume()
        }
    }
}

/// An async barrier that ignores cancellation: waiters resume only when the test opens it.
final class AsyncBarrier: Sendable {
    private struct State: Sendable {
        var opened = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state -> Bool in
                if state.opened { return true }
                state.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.opened = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

// MARK: - Behaviour

// Serialized: each test blocks its (cooperative) thread in poll() while the server's sessions need
// the pool, so only one test of this suite holds a thread at a time.
@Suite(.serialized) struct MCPSocketServerTests {
    @Test func startCreatesSocket0600AndHandshake0600InDirectory0700() throws {
        let scratch = try SocketScratch()
        let h = ServerHarness(directory: scratch.standard)
        #expect(!h.server.isRunning)
        try h.server.start()
        #expect(h.server.isRunning)

        #expect(fileType(h.directory.path) == S_IFDIR)
        #expect(permissions(h.directory.path) == 0o700)

        let socketInfo = try #require(lstatInfo(h.socketPath))
        #expect(socketInfo.st_mode & S_IFMT == S_IFSOCK)
        #expect(socketInfo.st_mode & 0o7777 == 0o600)
        #expect(socketInfo.st_uid == geteuid())

        let handshakeInfo = try #require(lstatInfo(h.handshakePath))
        #expect(handshakeInfo.st_mode & S_IFMT == S_IFREG)
        #expect(handshakeInfo.st_mode & 0o7777 == 0o600)

        let handshake = try HandshakeFile.read(at: MCPPaths.handshakeURL(in: h.directory))
        #expect(handshake.version == MCPHandshake.currentVersion)
        #expect(handshake.pid == getpid())
        #expect(handshake.socketPath == h.socketPath)
        #expect(handshake.token == h.server.token)
        #expect(handshake.token.utf8.count == 64)

        // Only our two files: no staging directory or temp file is left behind.
        let names = try FileManager.default.contentsOfDirectory(atPath: h.directory.path).sorted()
        #expect(names == [MCPPaths.handshakeFileName, MCPPaths.socketFileName])
        h.server.stop()
    }

    @Test func handshakeFileWrittenOnlyAfterListening() throws {
        struct NoRandom: Error {}
        let scratch = try SocketScratch()

        // The token is made after listen; a failure there must leave neither file behind.
        let failing = ServerHarness(directory: scratch.standard, makeToken: { throw NoRandom() })
        #expect(throws: MCPSocketServer.StartFailure.tokenFailed) { try failing.server.start() }
        #expect(!failing.server.isRunning)
        #expect(fileType(failing.handshakePath) == nil)
        #expect(fileType(failing.socketPath) == nil)

        // An unsafe socket path fails before anything is written.
        let blocked = try SocketScratch()
        let blockedHarness = ServerHarness(directory: blocked.standard)
        try FileManager.default.createDirectory(
            at: blocked.standard, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data("x".utf8).write(to: URL(fileURLWithPath: blockedHarness.socketPath))
        #expect(throws: MCPSocketServer.StartFailure.directoryUnsafe) { try blockedHarness.server.start() }
        #expect(fileType(blockedHarness.handshakePath) == nil)

        // Once the handshake is visible, the socket it names already accepts the token.
        let h = ServerHarness(directory: scratch.standard)
        try h.server.start()
        let handshake = try HandshakeFile.read(at: MCPPaths.handshakeURL(in: h.directory))
        let client = try TestClient(path: handshake.socketPath)
        #expect(client.sendHello(token: handshake.token))
        #expect(client.readLine() == .line(#"{"ok":true}"#))
    }

    @Test func validHelloThenToolsListRoundTrip() throws {
        let scratch = try SocketScratch()
        let tool = FakeTool(name: "list_things")
        let h = ServerHarness(directory: scratch.standard, tools: [tool])
        try h.server.start()
        let client = try h.authenticatedClient()

        #expect(client.sendLine(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))
        let list = try #require(client.readJSON())
        #expect(list["id"] == .int(1))
        let names = list["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
        #expect(names == ["list_things"])

        #expect(client.sendLine(callTool(2, "list_things")))
        let call = try #require(client.readJSON())
        #expect(call["id"] == .int(2))
        #expect(call["result"]?["isError"] == .bool(false))
        #expect(tool.callCount == 1)
        #expect(h.sessionCount == 1)
    }

    @Test func helloAndFirstRequestInOneWriteAreBothHandled() throws {
        let scratch = try SocketScratch()
        let h = ServerHarness(directory: scratch.standard)
        try h.server.start()
        let client = try h.client()
        var bytes = MCPHello(token: h.server.token, client: "tests", protocolVersion: 1).line()
        bytes.append(contentsOf: Data(("\n" + ping(7) + "\n").utf8))
        #expect(UnixSocket.writeAll(client.fd, bytes))
        #expect(client.readLine() == .line(#"{"ok":true}"#))
        #expect(client.readJSON()?["id"] == .int(7))
    }

    @Test func unterminatedFinalLineIsNeverExecuted() throws {
        // StdioRelay re-sends a line whose write failed on a fresh connection; that is only safe because
        // a partial line that reaches the server before EOF is dropped, never run.
        let scratch = try SocketScratch()
        let tool = FakeTool(name: "list_things")
        let h = ServerHarness(directory: scratch.standard, tools: [tool])
        try h.server.start()
        let client = try h.authenticatedClient()

        #expect(client.sendLine(ping(1)))
        #expect(client.readJSON()?["id"] == .int(1))

        #expect(client.send(callTool(2, "list_things")))  // no newline
        client.halfClose()
        #expect(client.readToEOF() == Data())  // closed with no reply
        #expect(tool.callCount == 0)
        #expect(h.server.waitForConnectionCount(0, timeout: .seconds(10)))
    }

    @Test func oversizeLineGetsInvalidRequestAndConnectionSurvives() throws {
        let scratch = try SocketScratch()
        let h = ServerHarness(directory: scratch.standard, configure: { $0.maxLineBytes = 1024 })
        try h.server.start()
        let client = try h.authenticatedClient()

        // Sent in pieces, so the framer sees the overflow across several reads.
        #expect(client.send(String(repeating: "a", count: 700)))
        #expect(client.send(String(repeating: "b", count: 700)))
        #expect(client.send(String(repeating: "c", count: 700) + "\n"))
        let error = try #require(client.readJSON())
        #expect(error["error"]?["code"] == .int(-32600))
        #expect(error["id"] == .null)

        #expect(client.sendLine(ping(2)))
        #expect(client.readJSON()?["id"] == .int(2))
        #expect(h.server.connectionCount == 1)
    }

    @Test func responsesStayInRequestOrder() throws {
        let scratch = try SocketScratch()
        // Every other request awaits a few hops on the pool, so a concurrent server would reorder them.
        let slow = FakeTool(name: "slow_thing") { _, _ in
            for _ in 0..<20 { await Task.yield() }
            return .object([:])
        }
        let h = ServerHarness(directory: scratch.standard, tools: [slow])
        try h.server.start()
        let client = try h.authenticatedClient()

        var burst = ""
        for id in 1...20 { burst += (id.isMultiple(of: 2) ? ping(id) : callTool(id, "slow_thing")) + "\n" }
        #expect(client.send(burst))
        var ids: [Int] = []
        for _ in 1...20 { ids.append(client.readJSON()?["id"]?.intValue ?? -1) }
        #expect(ids == Array(1...20))
        #expect(slow.callCount == 10)
    }

    @Test func twoConnectionsAreIndependentSessions() throws {
        let scratch = try SocketScratch()
        let h = ServerHarness(directory: scratch.standard)
        try h.server.start()
        let alpha = try h.authenticatedClient()
        let beta = try h.authenticatedClient()
        #expect(h.server.connectionCount == 2)

        func initialize(_ name: String) -> String {
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"\#(name)","version":"1"}}}"#
        }
        #expect(alpha.sendLine(initialize("alpha")))
        #expect(beta.sendLine(initialize("beta")))
        #expect(alpha.readJSON()?["id"] == .int(1))
        #expect(beta.readJSON()?["id"] == .int(1))

        #expect(beta.sendLine(callTool(2, "list_things")))
        #expect(beta.readJSON()?["id"] == .int(2))
        #expect(alpha.sendLine(callTool(2, "list_things")))
        #expect(alpha.readJSON()?["id"] == .int(2))

        #expect(h.sessionCount == 2)
        let clients = h.audit.snapshot().map(\.client)
        #expect(Set(clients) == ["alpha 1", "beta 1"])
    }

    @Test func peerCloseRemovesConnection() throws {
        let scratch = try SocketScratch()
        let h = ServerHarness(directory: scratch.standard)
        try h.server.start()
        var client: TestClient? = try h.authenticatedClient()
        #expect(h.server.connectionCount == 1)
        client = nil  // closes the descriptor
        #expect(client == nil)
        #expect(h.server.waitForConnectionCount(0, timeout: .seconds(10)))
    }

    @Test func stopClosesConnectionsAndRemovesFiles() throws {
        let scratch = try SocketScratch()
        let h = ServerHarness(directory: scratch.standard)
        try h.server.start()
        let first = try h.authenticatedClient()
        let second = try h.authenticatedClient()
        let unauthenticated = try h.client()  // still inside its hello window
        #expect(h.server.waitForConnectionCount(3, timeout: .seconds(10)))

        h.server.stop()
        #expect(!h.server.isRunning)
        #expect(h.server.connectionCount == 0)
        #expect(first.readToEOF() == Data())
        #expect(second.readToEOF() == Data())
        #expect(unauthenticated.readToEOF() == Data())
        #expect(fileType(h.socketPath) == nil)
        #expect(fileType(h.handshakePath) == nil)
        #expect(fileType(h.directory.path) == S_IFDIR)
        #expect(throws: (any Error).self) { try h.client() }

        h.server.stop()  // idempotent
    }

    @Test func restartUsesNewToken() throws {
        let scratch = try SocketScratch()
        let h = ServerHarness(directory: scratch.standard)
        try h.server.start()
        let firstToken = h.server.token
        h.server.stop()
        #expect(h.server.token.isEmpty)

        try h.server.start()
        let secondToken = h.server.token
        #expect(secondToken != firstToken)
        #expect(try HandshakeFile.read(at: MCPPaths.handshakeURL(in: h.directory)).token == secondToken)

        let stale = try h.client()
        #expect(stale.sendHello(token: firstToken))
        #expect(stale.readToEOF() == Data())
        _ = try h.authenticatedClient()
    }

    @Test func startTwiceOnOneInstanceIsAlreadyRunning() throws {
        let scratch = try SocketScratch()
        let h = ServerHarness(directory: scratch.standard)
        try h.server.start()
        let token = h.server.token
        #expect(throws: MCPSocketServer.StartFailure.alreadyRunning) { try h.server.start() }
        #expect(h.server.token == token)
        _ = try h.authenticatedClient()
    }

    @Test func stopWhileClientsBusyDoesNotDeadlock() throws {
        let scratch = try SocketScratch()
        let started = DispatchSemaphore(value: 0)
        // Runs until its task is cancelled: stop() must cancel in-flight calls, not wait on them forever.
        let blocking = FakeTool(name: "blocking_thing") { _, _ in
            started.signal()
            await CancellationGate().waitForCancellation()
            return .object([:])
        }
        let h = ServerHarness(directory: scratch.standard, tools: [blocking])
        try h.server.start()

        var clients: [TestClient] = []
        for _ in 0..<3 {
            let client = try h.authenticatedClient()
            var burst = callTool(1, "blocking_thing") + "\n"
            for id in 2...50 { burst += ping(id) + "\n" }
            #expect(client.send(burst))
            clients.append(client)
        }
        // A fourth client floods pings and never reads: the server's replies fill the socket buffer, so the
        // server blocks in write and the flood blocks in write too (on its own thread).
        let flooder = try h.authenticatedClient()
        let flooderFD = flooder.fd
        let floodDone = DispatchSemaphore(value: 0)
        let floodThread = Thread {
            _ = UnixSocket.writeAll(flooderFD, Data(String(repeating: ping(9) + "\n", count: 20_000).utf8))
            floodDone.signal()
        }
        floodThread.start()
        for _ in 0..<3 { #expect(started.wait(timeout: .now() + 10) == .success) }

        let stopped = DispatchSemaphore(value: 0)
        let server = h.server
        let stopper = Thread {
            server.stop()
            stopped.signal()
        }
        stopper.start()
        guard stopped.wait(timeout: .now() + 20) == .success else {
            // stop() is stuck: keep the harness alive (its deinit would call stop() again and hang the
            // run) so this failure is reported instead of a hung test process.
            _ = Unmanaged.passRetained(h)
            Issue.record("stop() did not return while clients were busy")
            return
        }
        for client in clients { #expect(client.readToEOF() != nil) }
        #expect(floodDone.wait(timeout: .now() + 20) == .success)
        #expect(flooder.readToEOF() != nil)
        #expect(!h.server.isRunning)
    }

    @Test func beginStopReturnsPromptlyWhileAToolIgnoresCancellation() throws {
        let scratch = try SocketScratch()
        let started = DispatchSemaphore(value: 0)
        let barrier = AsyncBarrier()
        let stubborn = FakeTool(name: "stubborn_thing") { _, _ in
            started.signal()
            await barrier.wait()  // does not end on cancellation
            return .object([:])
        }
        let h = ServerHarness(directory: scratch.standard, tools: [stubborn])
        try h.server.start()
        let client = try h.authenticatedClient()
        #expect(client.sendLine(callTool(1, "stubborn_thing")))
        #expect(started.wait(timeout: .now() + 10) == .success)

        // beginStop is what a main-actor caller uses: it must not wait for the stuck call.
        let begun = DispatchSemaphore(value: 0)
        let server = h.server
        Thread {
            server.beginStop()
            begun.signal()
        }.start()
        guard begun.wait(timeout: .now() + 10) == .success else {
            _ = Unmanaged.passRetained(h)  // a stuck stop would hang the harness deinit
            barrier.open()
            Issue.record("beginStop() blocked on an in-flight call")
            return
        }
        #expect(!h.server.isRunning)
        #expect(fileType(h.socketPath) == nil)
        #expect(fileType(h.handshakePath) == nil)
        #expect(client.readToEOF() == Data())  // shut down although its call still runs

        // The joiner waits for the stuck call...
        let joined = DispatchSemaphore(value: 0)
        Thread {
            server.waitUntilStopped()
            joined.signal()
        }.start()
        #expect(joined.wait(timeout: .now() + .milliseconds(200)) == .timedOut)

        // ...while a new start is already possible.
        try h.server.start()
        let fresh = try h.authenticatedClient()
        #expect(fresh.sendLine(ping(2)))
        #expect(fresh.readJSON()?["id"] == .int(2))

        barrier.open()
        #expect(joined.wait(timeout: .now() + 10) == .success)
        #expect(stubborn.callCount == 1)
    }

    @Test func deinitStopsTheServer() throws {
        let scratch = try SocketScratch()
        let directory = scratch.standard
        let socketPath = MCPPaths.socketURL(in: directory).path
        weak var weakServer: MCPSocketServer?
        let client: TestClient
        do {
            let runner = MCPToolRunner(
                tools: [FakeTool(name: "list_things")], policy: MCPPolicyProvider(enabledSettings()),
                audit: MCPAuditLog())
            let server = MCPSocketServer(
                configuration: .init(directory: directory, createsDirectory: true),
                makeSession: { MCPSession(runner: runner, app: MCPAppInfo(name: "ProxyWoman", version: "9.9")) })
            try server.start()
            weakServer = server
            client = try TestClient(path: socketPath)
            #expect(client.sendHello(token: server.token))
            #expect(client.readLine() == .line(#"{"ok":true}"#))
            #expect(client.sendLine(ping(1)))
            #expect(client.readJSON()?["id"] == .int(1))
        }
        // Connection threads hold no strong reference to the server, so the last release ran deinit, which
        // stopped it: the connection is closed and the files are gone.
        #expect(weakServer == nil)
        #expect(client.readToEOF() == Data())
        #expect(fileType(socketPath) == nil)
        #expect(fileType(MCPPaths.handshakeURL(in: directory).path) == nil)
    }
}
