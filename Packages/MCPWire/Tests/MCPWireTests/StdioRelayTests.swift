import Foundation
import Testing

@testable import MCPWire

// MARK: - Support

/// Reads newline-delimited lines from a file descriptor with a hard timeout (poll, no sleeping).
private final class LineReader: @unchecked Sendable {  // used from the test thread only after setup; fd read is serialized by `lock`
    enum Result: Equatable {
        case line(Data)
        case eof
        case timeout
    }

    private let fd: Int32
    private let lock = NSLock()
    private var framer = LineFramer(maxLineBytes: 8 * 1024 * 1024)
    private var queued: [Data] = []
    private var reachedEOF = false

    init(fd: Int32) { self.fd = fd }

    func next(timeout: TimeInterval = 10) -> Result {
        lock.lock()
        defer { lock.unlock() }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        while true {
            if !queued.isEmpty { return .line(queued.removeFirst()) }
            if reachedEOF { return .eof }
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= deadline { return .timeout }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let milliseconds = Int32(min((deadline - now) / 1_000_000 + 1, 1000))
            let ready = poll(&descriptor, 1, milliseconds)
            if ready < 0 {
                if errno == EINTR { continue }
                return .eof
            }
            if ready == 0 { continue }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                reachedEOF = true
                continue
            }
            if count == 0 {
                reachedEOF = true
                continue
            }
            for event in framer.append(Data(buffer[0..<count])) {
                if case .line(let line) = event { queued.append(line) }
            }
        }
    }

    /// Next line, or a recorded test failure.
    func line(timeout: TimeInterval = 10, sourceLocation: SourceLocation = #_sourceLocation) -> Data {
        switch next(timeout: timeout) {
        case .line(let data): return data
        case .eof:
            Issue.record("unexpected EOF", sourceLocation: sourceLocation)
        case .timeout:
            Issue.record("timed out waiting for a line", sourceLocation: sourceLocation)
        }
        return Data()
    }

    func json(timeout: TimeInterval = 10, sourceLocation: SourceLocation = #_sourceLocation) -> JSONValue {
        let data = line(timeout: timeout, sourceLocation: sourceLocation)
        return (try? JSONValue.parse(data)) ?? .null
    }
}

/// The test's end of a relay connection: reads what the relay sent, answers like the app would.
private final class FakeServer: @unchecked Sendable {  // fd is only touched by the test thread
    let fd: Int32
    let reader: LineReader
    init(fd: Int32) {
        self.fd = fd
        reader = LineReader(fd: fd)
    }
    deinit { close(fd) }

    func send(_ line: String) {
        #expect(UnixSocket.writeAll(fd, Data((line + "\n").utf8)))
    }

    func sendOK() { send(#"{"ok":true}"#) }

    func closeConnection() { shutdown(fd, SHUT_RDWR) }
}

private final class Counter: @unchecked Sendable {  // lock-protected
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

private final class LogSink: @unchecked Sendable {  // lock-protected
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ message: String) { lock.withLock { storage.append(message) } }
    var messages: [String] { lock.withLock { storage } }
}

private final class ServerQueue: @unchecked Sendable {  // lock-protected
    private let lock = NSLock()
    private let available = DispatchSemaphore(value: 0)
    private var servers: [FakeServer] = []
    func publish(_ server: FakeServer) {
        lock.withLock { servers.append(server) }
        available.signal()
    }
    func take(timeout: TimeInterval = 10) -> FakeServer? {
        guard available.wait(timeout: .now() + timeout) == .success else { return nil }
        return lock.withLock { servers.removeFirst() }
    }
}

private final class ResultBox: @unchecked Sendable {  // lock-protected
    private let lock = NSLock()
    private var stored: Int32?
    func set(_ value: Int32) { lock.withLock { stored = value } }
    var value: Int32? { lock.withLock { stored } }
}

private final class ServerBox: @unchecked Sendable {  // written once before the semaphore is signalled
    var server: FakeServer?
}

private final class LineBox: @unchecked Sendable {  // lock-protected
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private var stored = Data()
    func set(_ data: Data) {
        lock.withLock { stored = data }
        ready.signal()
    }
    func wait() -> Data {
        guard ready.wait(timeout: .now() + 10) == .success else { return Data() }
        return lock.withLock { stored }
    }
}

private enum ConnectBehavior: Sendable {
    case socketpair
    case refuse
}

private final class Harness: @unchecked Sendable {  // all mutable parts are lock-protected or thread-confined
    let directory: URL
    let handshakeURL: URL
    let stdinWrite: Int32
    let stdinRead: Int32
    let stdoutRead: Int32
    let stdoutWrite: Int32
    let stdout: LineReader
    let logs = LogSink()
    let connects = Counter()
    let servers = ServerQueue()
    let paths = LogSink()
    private let behavior: ConnectBehavior
    private let finished = DispatchSemaphore(value: 0)
    private let result = ResultBox()
    private var stdinWriteOpen = true
    private var stdoutReadOpen = true
    private var stdoutWriteOpen = true

    static let token1 = String(repeating: "a1", count: 32)
    static let token2 = String(repeating: "b2", count: 32)

    init(behavior: ConnectBehavior = .socketpair, writeHandshake: Bool = true, token: String = Harness.token1) throws {
        self.behavior = behavior
        directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("sr-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        handshakeURL = MCPPaths.handshakeURL(in: directory)
        var inPipe: [Int32] = [0, 0]
        var outPipe: [Int32] = [0, 0]
        #expect(pipe(&inPipe) == 0)
        #expect(pipe(&outPipe) == 0)
        stdinRead = inPipe[0]
        stdinWrite = inPipe[1]
        stdoutRead = outPipe[0]
        stdoutWrite = outPipe[1]
        stdout = LineReader(fd: outPipe[0])
        if writeHandshake { try self.writeHandshake(token: token) }
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
        closeStdin()
        closeStdoutReader()
        close(stdinRead)
        closeStdoutWriter()
    }

    func writeHandshake(token: String) throws {
        try HandshakeFile.write(
            MCPHandshake(
                version: MCPHandshake.currentVersion, pid: 1, socketPath: "/unused/mcp.sock",
                token: token, startedAt: Date(timeIntervalSince1970: 1_700_000_000)),
            to: handshakeURL)
    }

    /// Tests default to a short EOF drain so an unanswered request does not hold up the exit.
    func start(
        helloTimeoutMilliseconds: Int32 = 3000, drainTimeoutMilliseconds: Int32 = 200,
        forwardWrite: (@Sendable (Int32, Data) -> Bool)? = nil
    ) {
        let behavior = behavior
        let connects = connects
        let servers = servers
        let paths = paths
        var relay = StdioRelay(
            handshakeURL: handshakeURL, input: stdinRead, output: stdoutWrite,
            log: { [logs] message in logs.append(message) },
            connect: { path in
                connects.increment()
                paths.append(path)
                switch behavior {
                case .refuse:
                    throw UnixSocket.Failure.connectFailed(ECONNREFUSED)
                case .socketpair:
                    var fds: [Int32] = [0, 0]
                    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
                        throw UnixSocket.Failure.connectFailed(errno)
                    }
                    servers.publish(FakeServer(fd: fds[1]))
                    return fds[0]
                }
            },
            helloTimeoutMilliseconds: helloTimeoutMilliseconds,
            drainTimeoutMilliseconds: drainTimeoutMilliseconds)
        if let forwardWrite { relay.forwardWrite = forwardWrite }
        let relay2 = relay
        let result = result
        let finished = finished
        let thread = Thread {
            result.set(relay2.run())
            finished.signal()
        }
        thread.start()
    }

    /// Blocks until `run()` returned; nil on timeout.
    func exitStatus(timeout: TimeInterval = 10) -> Int32? {
        guard finished.wait(timeout: .now() + timeout) == .success else { return nil }
        return result.value
    }

    func send(_ line: String) {
        sendRaw(Data((line + "\n").utf8))
    }

    func sendRaw(_ data: Data) {
        #expect(UnixSocket.writeAll(stdinWrite, data))
    }

    func closeStdin() {
        guard stdinWriteOpen else { return }
        stdinWriteOpen = false
        close(stdinWrite)
    }

    func closeStdoutWriter() {
        guard stdoutWriteOpen else { return }
        stdoutWriteOpen = false
        close(stdoutWrite)
    }

    func closeStdoutReader() {
        guard stdoutReadOpen else { return }
        stdoutReadOpen = false
        close(stdoutRead)
    }

    /// Takes the next connection the relay made, reads its hello and answers `{"ok":true}`.
    func acceptAndHandshake(sourceLocation: SourceLocation = #_sourceLocation) -> (server: FakeServer, hello: MCPHello?) {
        guard let server = servers.take() else {
            Issue.record("relay never connected", sourceLocation: sourceLocation)
            return (FakeServer(fd: dup(0)), nil)
        }
        let hello = MCPHello.parse(line: server.reader.line(sourceLocation: sourceLocation))
        server.sendOK()
        return (server, hello)
    }
}

private let request1 = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
private let appDownMessage = "ProxyWoman is not running, or MCP is not enabled in ProxyWoman Settings."

private func errorInfo(_ value: JSONValue) -> (id: JSONValue?, code: Int?, message: String?) {
    (value["id"], value["error"]?["code"]?.intValue, value["error"]?["message"]?.stringValue)
}

// MARK: - Tests

@Suite struct StdioRelayTests {
    @Test func forwardsRequestAndResponseVerbatim() throws {
        let harness = try Harness()
        harness.start()
        // Odd spacing and key order must survive untouched.
        let request = #"{ "method":"tools/list",  "id": 1, "jsonrpc":"2.0" }"#
        harness.send(request)
        let (server, _) = harness.acceptAndHandshake()
        #expect(server.reader.line() == Data(request.utf8))

        let response = #"{"result":{"tools":[]},   "id":1,"jsonrpc":"2.0"}"#
        server.send(response)
        #expect(harness.stdout.line() == Data(response.utf8))

        // A server-initiated line with no pending request is passed through as well.
        let note = #"{"jsonrpc":"2.0","method":"notifications/message","params":{}}"#
        server.send(note)
        #expect(harness.stdout.line() == Data(note.utf8))

        // Notifications go through verbatim too, and the connection is reused.
        let notification = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
        harness.send(notification)
        #expect(server.reader.line() == Data(notification.utf8))
        #expect(harness.connects.count == 1)

        harness.closeStdin()
        #expect(harness.exitStatus() == 0)
    }

    @Test func invalidLineIsForwardedVerbatimWhenConnected() throws {
        let harness = try Harness()
        harness.start()
        harness.send(request1)
        let (server, _) = harness.acceptAndHandshake()
        _ = server.reader.line()
        harness.send("[1,2,3]")
        #expect(server.reader.line() == Data("[1,2,3]".utf8))
        harness.closeStdin()
        #expect(harness.exitStatus() == 0)
    }

    @Test func sendsHelloFirstWithTokenFromHandshake() throws {
        let harness = try Harness()
        harness.start()
        harness.send(request1)
        guard let server = harness.servers.take() else {
            Issue.record("relay never connected")
            return
        }
        // The very first line on the connection is the hello, before any request.
        let first = server.reader.line()
        let hello = MCPHello.parse(line: first)
        #expect(hello == MCPHello(token: Harness.token1, client: "proxywoman-mcp", protocolVersion: 1))
        #expect(harness.paths.messages == ["/unused/mcp.sock"])

        // The request is held back until the server accepted the hello.
        #expect(server.reader.next(timeout: 0.2) == .timeout)
        server.sendOK()
        #expect(server.reader.line() == Data(request1.utf8))
        harness.closeStdin()
        #expect(harness.exitStatus() == 0)
    }

    @Test func appDownAnswersRequestWithErrorAndNotificationIsDropped() throws {
        let harness = try Harness(behavior: .refuse)
        harness.start()
        harness.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        harness.send(#"{"jsonrpc":"2.0","id":"abc","method":"tools/list"}"#)
        harness.send(#"{"jsonrpc":"2.0","id":8,"method":"ping"}"#)

        // The notification produced nothing, so the first reply is for "abc", then 8.
        let first = errorInfo(harness.stdout.json())
        #expect(first.id == .string("abc"))
        #expect(first.code == -32000)
        #expect(first.message == appDownMessage)
        let second = errorInfo(harness.stdout.json())
        #expect(second.id == .int(8))
        #expect(second.code == -32000)

        // The relay did not exit and retries on every line.
        #expect(harness.connects.count == 3)
        harness.closeStdin()
        #expect(harness.exitStatus() == 0)
        harness.closeStdoutReader()
    }

    @Test func missingHandshakeAnswersWithAppUnavailableAndNeverConnects() throws {
        let harness = try Harness(writeHandshake: false)
        harness.start()
        harness.send(request1)
        let reply = errorInfo(harness.stdout.json())
        #expect(reply.id == .int(1))
        #expect(reply.message == appDownMessage)
        #expect(harness.connects.count == 0)

        // Once the app starts, the next line connects without restarting the relay.
        try harness.writeHandshake(token: Harness.token1)
        harness.send(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)
        let (server, _) = harness.acceptAndHandshake()
        #expect(server.reader.line() == Data(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#.utf8))
        harness.closeStdin()
        #expect(harness.exitStatus() == 0)
    }

    @Test func reconnectsAfterServerClosesAndRereadsHandshake() throws {
        let harness = try Harness()
        harness.start()
        harness.send(request1)
        let (first, hello1) = harness.acceptAndHandshake()
        #expect(hello1?.token == Harness.token1)
        #expect(first.reader.line() == Data(request1.utf8))
        let response = #"{"jsonrpc":"2.0","id":1,"result":{}}"#
        first.send(response)
        #expect(harness.stdout.line() == Data(response.utf8))

        // The app restarts: the old connection closes and the handshake carries a new token.
        first.closeConnection()
        try harness.writeHandshake(token: Harness.token2)

        let request2 = #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#
        harness.send(request2)
        let (second, hello2) = harness.acceptAndHandshake()
        #expect(hello2?.token == Harness.token2)
        #expect(second.reader.line() == Data(request2.utf8))
        second.send(#"{"jsonrpc":"2.0","id":2,"result":{}}"#)
        #expect(errorInfo(harness.stdout.json()).id == .int(2))
        #expect(harness.connects.count == 2)

        harness.closeStdin()
        #expect(harness.exitStatus() == 0)
    }

    @Test func pendingRequestsFailWhenServerClosesMidFlight() throws {
        let harness = try Harness()
        harness.start()
        harness.send(#"{"jsonrpc":"2.0","id":1,"method":"a"}"#)
        let (server, _) = harness.acceptAndHandshake()
        harness.send(#"{"jsonrpc":"2.0","id":"two","method":"b"}"#)
        harness.send(#"{"jsonrpc":"2.0","id":3,"method":"c"}"#)
        harness.send(#"{"jsonrpc":"2.0","method":"notifications/x"}"#)
        for _ in 0..<4 { _ = server.reader.line() }

        // Only id 2 is answered; the rest are in flight when the server goes away.
        let answered = #"{"jsonrpc":"2.0","id":"two","result":{}}"#
        server.send(answered)
        #expect(harness.stdout.line() == Data(answered.utf8))
        server.closeConnection()

        let first = errorInfo(harness.stdout.json())
        let second = errorInfo(harness.stdout.json())
        #expect(first.id == .int(1) && second.id == .int(3))
        #expect(first.code == -32000 && second.code == -32000)
        #expect(first.message == "ProxyWoman closed the connection.")
        #expect(second.message == "ProxyWoman closed the connection.")
        // Nothing else (no error for the answered request or the notification).
        #expect(harness.stdout.next(timeout: 0.2) == .timeout)

        harness.closeStdin()
        #expect(harness.exitStatus() == 0)
    }

    @Test func badHandshakePermissionsRefuseToConnect() throws {
        let harness = try Harness()
        #expect(chmod(harness.handshakeURL.path, 0o644) == 0)
        harness.start()
        harness.send(request1)
        let reply = errorInfo(harness.stdout.json())
        #expect(reply.id == .int(1))
        #expect(reply.code == -32000)
        #expect(reply.message?.contains("tooPermissive") == true)
        #expect(harness.connects.count == 0)

        // Fixing the permissions recovers on the next line.
        #expect(chmod(harness.handshakeURL.path, 0o600) == 0)
        harness.send(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)
        let (server, hello) = harness.acceptAndHandshake()
        #expect(hello?.token == Harness.token1)
        _ = server
        harness.closeStdin()
        #expect(harness.exitStatus() == 0)
    }

    @Test func helloTimeoutAndRejectionAnswerWithAppUnavailable() throws {
        let harness = try Harness()
        harness.start(helloTimeoutMilliseconds: 200)
        harness.send(request1)
        // The server accepts but never answers the hello.
        guard let silent = harness.servers.take() else {
            Issue.record("relay never connected")
            return
        }
        _ = silent.reader.line()
        let timedOut = errorInfo(harness.stdout.json())
        #expect(timedOut.id == .int(1))
        #expect(timedOut.message == appDownMessage)
        // The relay gave up on that connection.
        #expect(silent.reader.next() == .eof)

        // A server that answers anything but {"ok":true} is refused as well.
        harness.send(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)
        guard let rejecting = harness.servers.take() else {
            Issue.record("relay never reconnected")
            return
        }
        _ = rejecting.reader.line()
        rejecting.send(#"{"ok":false}"#)
        let rejected = errorInfo(harness.stdout.json())
        #expect(rejected.id == .int(2))
        #expect(rejected.message == appDownMessage)
        #expect(harness.connects.count == 2)

        harness.closeStdin()
        #expect(harness.exitStatus() == 0)
    }

    @Test func overlongInputLineIsRejected() throws {
        let harness = try Harness(behavior: .refuse)
        harness.start()
        // 1 MiB + 10 bytes on one line, then a normal request on the next.
        let big = Data(repeating: 0x61, count: 1_048_576 + 10)
        harness.sendRaw(big + Data("\n".utf8))
        let reply = harness.stdout.json()
        let info = errorInfo(reply)
        #expect(info.id == .null)
        #expect(info.code == -32600)
        // The oversized line never reached the connect path.
        #expect(harness.connects.count == 0)

        harness.send(request1)
        let next = errorInfo(harness.stdout.json())
        #expect(next.id == .int(1))
        #expect(next.code == -32000)

        harness.closeStdin()
        #expect(harness.exitStatus() == 0)
    }

    @Test func overlongInputLineIsNeverForwardedWhenConnected() throws {
        let harness = try Harness()
        harness.start()
        harness.send(request1)
        let (server, _) = harness.acceptAndHandshake()
        _ = server.reader.line()

        harness.sendRaw(Data(repeating: 0x62, count: 1_048_576 + 1) + Data("\n".utf8))
        #expect(errorInfo(harness.stdout.json()).code == -32600)
        let after = #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#
        harness.send(after)
        // The next thing the server sees is the following request, not the oversized line.
        #expect(server.reader.line() == Data(after.utf8))
        harness.closeStdin()
        #expect(harness.exitStatus() == 0)
    }

    @Test func eofClosesAndReturnsZero() throws {
        let harness = try Harness()
        harness.start()
        harness.send(request1)
        let (server, _) = harness.acceptAndHandshake()
        _ = server.reader.line()

        harness.closeStdin()
        #expect(harness.exitStatus() == 0)
        // The socket was closed: the server sees EOF.
        #expect(server.reader.next() == .eof)
    }

    @Test func eofWithoutAnyConnectionReturnsZero() throws {
        let harness = try Harness()
        harness.start()
        harness.closeStdin()
        #expect(harness.exitStatus() == 0)
        #expect(harness.connects.count == 0)
    }

    @Test func stdoutCarriesOnlyProtocolLines() throws {
        let harness = try Harness(behavior: .refuse)
        harness.start()
        harness.send(request1)
        harness.send("not json at all")
        harness.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        harness.send(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)
        harness.closeStdin()
        #expect(harness.exitStatus() == 0)
        harness.closeStdoutWriter()  // the relay is done; let the reader see EOF

        var lines: [Data] = []
        while case .line(let line) = harness.stdout.next(timeout: 5) { lines.append(line) }
        #expect(lines.count == 3)
        for line in lines {
            let value = try JSONValue.parse(line)
            #expect(value["jsonrpc"]?.stringValue == "2.0")
            #expect(value["error"] != nil)
        }
        // Diagnostics went to the log callback instead.
        #expect(!harness.logs.messages.isEmpty)
        #expect(harness.logs.messages.allSatisfy { !$0.contains("\n") })
        // The handshake token never appears in diagnostics.
        #expect(harness.logs.messages.allSatisfy { !$0.contains(Harness.token1) })
    }

    @Test func closedStdoutReturnsOneWithoutCrashing() throws {
        let harness = try Harness(behavior: .refuse)
        harness.closeStdoutReader()  // the client went away; the next write hits EPIPE
        harness.start()
        harness.send(request1)
        #expect(harness.exitStatus() == 1)
    }

    @Test func closedStdoutWhileForwardingReturnsOne() throws {
        let harness = try Harness()
        harness.start()
        harness.send(request1)
        let (server, _) = harness.acceptAndHandshake()
        _ = server.reader.line()
        harness.closeStdoutReader()
        // The response cannot be delivered: the reader thread notices and the relay stops even though
        // stdin is still open.
        server.send(#"{"jsonrpc":"2.0","id":1,"result":{}}"#)
        #expect(harness.exitStatus() == 1)
    }

    // MARK: EOF drain

    @Test func eofWaitsForPendingAnswerBeforeClosing() throws {
        let harness = try Harness()
        harness.start(drainTimeoutMilliseconds: 10_000)
        harness.send(request1)
        let (server, _) = harness.acceptAndHandshake()
        _ = server.reader.line()

        // The client is done writing; the answer still has to reach stdout.
        harness.closeStdin()
        let response = #"{"jsonrpc":"2.0","id":1,"result":{}}"#
        server.send(response)
        #expect(harness.stdout.line() == Data(response.utf8))
        #expect(harness.exitStatus() == 0)
        #expect(server.reader.next() == .eof)
    }

    @Test func eofDrainIsBounded() throws {
        let harness = try Harness()
        harness.start(drainTimeoutMilliseconds: 100)
        harness.send(request1)
        let (server, _) = harness.acceptAndHandshake()
        _ = server.reader.line()
        harness.closeStdin()
        // The server never answers: the relay gives up after the bound, closes and returns 0.
        #expect(harness.exitStatus() == 0)
        #expect(server.reader.next() == .eof)
    }

    @Test func eofDrainEndsWhenServerClosesInstead() throws {
        let harness = try Harness()
        harness.start(drainTimeoutMilliseconds: 10_000)
        harness.send(request1)
        let (server, _) = harness.acceptAndHandshake()
        _ = server.reader.line()
        harness.closeStdin()
        server.closeConnection()
        // The pending request is failed (and the drain released) rather than waiting for the bound.
        #expect(errorInfo(harness.stdout.json()).message == "ProxyWoman closed the connection.")
        #expect(harness.exitStatus() == 0)
    }

    // MARK: Write-failure retry

    @Test func failedForwardWriteRetriesOnceOnAFreshConnection() throws {
        let harness = try Harness()
        let calls = Counter()
        harness.start(forwardWrite: { fd, data in
            calls.increment()
            // First attempt: pretend the socket died before the line was written.
            return calls.count == 1 ? false : UnixSocket.writeAll(fd, data)
        })
        harness.send(request1)
        let (first, hello1) = harness.acceptAndHandshake()
        #expect(hello1?.token == Harness.token1)
        let (second, hello2) = harness.acceptAndHandshake()
        #expect(hello2?.token == Harness.token1)

        // Exactly one delivery, on the second connection; the first only ever saw its hello.
        #expect(second.reader.line() == Data(request1.utf8))
        #expect(first.reader.next() == .eof)
        #expect(harness.connects.count == 2)
        #expect(calls.count == 2)

        let response = #"{"jsonrpc":"2.0","id":1,"result":{}}"#
        second.send(response)
        #expect(harness.stdout.line() == Data(response.utf8))
        // No duplicate or error reply.
        #expect(harness.stdout.next(timeout: 0.2) == .timeout)
        harness.closeStdin()
        #expect(harness.exitStatus() == 0)
    }

    @Test func failedForwardWriteIsNotRetriedWhenReaderAlreadyFailedTheID() throws {
        let harness = try Harness()
        let serverReady = DispatchSemaphore(value: 0)
        let serverBox = ServerBox()
        let reply = LineBox()
        let calls = Counter()
        harness.start(forwardWrite: { fd, data in
            calls.increment()
            guard calls.count == 1 else { return UnixSocket.writeAll(fd, data) }
            // The app drops the connection and the reader answers the pending id before this write
            // is reported as failed.
            guard serverReady.wait(timeout: .now() + 10) == .success, let server = serverBox.server else {
                return false
            }
            server.closeConnection()
            reply.set(harness.stdout.line())
            return false
        })
        harness.send(request1)
        let (server, _) = harness.acceptAndHandshake()
        serverBox.server = server
        serverReady.signal()

        // Wait for the reply the hook captured, then make sure nothing else follows.
        harness.send(#"{"jsonrpc":"2.0","method":"notifications/ping"}"#)  // main thread is busy in the hook until the reply is out
        let info = errorInfo((try? JSONValue.parse(reply.wait())) ?? .null)
        #expect(info.id == .int(1))
        #expect(info.message == "ProxyWoman closed the connection.")
        #expect(harness.stdout.next(timeout: 0.2) == .timeout)
        // No retry for the answered request; the notification afterwards reconnects normally.
        let (third, _) = harness.acceptAndHandshake()
        #expect(harness.connects.count == 2)
        _ = third
        harness.closeStdin()
        #expect(harness.exitStatus() == 0)
    }

    // MARK: Client responses

    @Test func clientResponsesPassThroughWithoutBeingTracked() throws {
        let harness = try Harness()
        harness.start()
        harness.send(request1)
        let (server, _) = harness.acceptAndHandshake()
        _ = server.reader.line()
        server.send(#"{"jsonrpc":"2.0","id":1,"result":{}}"#)
        _ = harness.stdout.line()

        let clientReply = #"{"jsonrpc":"2.0","id":99,"result":{"ok":true}}"#
        harness.send(clientReply)
        #expect(server.reader.line() == Data(clientReply.utf8))
        // Not pending: closing the server produces no error reply for id 99.
        server.closeConnection()
        #expect(harness.stdout.next(timeout: 0.2) == .timeout)
        harness.closeStdin()
        #expect(harness.exitStatus() == 0)
    }

    @Test func clientResponsesAreDroppedSilentlyWhenAppIsDown() throws {
        let harness = try Harness(behavior: .refuse)
        harness.start()
        harness.send(#"{"jsonrpc":"2.0","id":5,"result":{}}"#)
        harness.send(#"{"jsonrpc":"2.0","id":6,"error":{"code":-1,"message":"x"}}"#)
        harness.send(request1)
        // The only reply is for the request.
        #expect(errorInfo(harness.stdout.json()).id == .int(1))
        harness.closeStdin()
        #expect(harness.exitStatus() == 0)
    }
}
