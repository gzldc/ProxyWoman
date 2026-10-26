import Foundation

/// Dumb stdio <-> Unix socket relay run by `proxywoman-mcp`.
///
/// Every stdin line is forwarded verbatim to the app's socket and every socket line verbatim to
/// stdout. Nothing but protocol lines is ever written to stdout; diagnostics go to `log`.
/// The socket is connected lazily (re-reading the handshake file each time), so an app restart does
/// not require restarting the AI client.
///
/// Threads: the caller's thread reads stdin; one dedicated `Thread` at a time reads the socket.
///
/// Timeouts: the app must acknowledge the hello within `helloTimeoutMilliseconds` (3 s by default);
/// when stdin reaches EOF while requests are still unanswered, `run()` waits for those answers for at
/// most `drainTimeoutMilliseconds` (5 s by default) before closing the socket.
public struct StdioRelay: Sendable {
    public static let appUnavailableMessage =
        "ProxyWoman is not running, or MCP is not enabled in ProxyWoman Settings."
    public static let connectionClosedMessage = "ProxyWoman closed the connection."
    public static let clientName = "proxywoman-mcp"
    /// Longest accepted stdin line (spec S7).
    public static let maxInputLineBytes = 1_048_576
    /// Bound for lines coming back from the app (results are capped at 256 KiB there).
    static let maxServerLineBytes = 8 * 1024 * 1024

    private let handshakeURL: URL
    private let input: Int32
    private let output: Int32
    private let log: @Sendable (String) -> Void
    private let connect: @Sendable (String) throws -> Int32
    private let helloTimeoutMilliseconds: Int32
    private let drainTimeoutMilliseconds: Int32
    /// Writes a forwarded line to the socket. Tests replace it to exercise the write-failure path.
    var forwardWrite: @Sendable (Int32, Data) -> Bool = UnixSocket.writeAll

    public init(
        handshakeURL: URL, input: Int32, output: Int32,
        log: @escaping @Sendable (String) -> Void,
        connect: @escaping @Sendable (String) throws -> Int32 = UnixSocket.connect(path:),
        helloTimeoutMilliseconds: Int32 = 3000,
        drainTimeoutMilliseconds: Int32 = 5000
    ) {
        self.handshakeURL = handshakeURL
        self.input = input
        self.output = output
        self.log = log
        self.connect = connect
        self.helloTimeoutMilliseconds = helloTimeoutMilliseconds
        self.drainTimeoutMilliseconds = drainTimeoutMilliseconds
    }

    /// Blocks until `input` reaches EOF; returns the process exit status (0 on EOF, 1 when stdout
    /// can no longer be written or stdin fails). On EOF, requests already forwarded are given up to
    /// `drainTimeoutMilliseconds` to be answered (so `printf '<request>' | proxywoman-mcp` prints its
    /// response) before the socket is closed.
    public func run() -> Int32 {
        Session(
            handshakeURL: handshakeURL, input: input, output: output, log: log, connect: connect,
            helloTimeoutMilliseconds: helloTimeoutMilliseconds,
            drainTimeoutMilliseconds: drainTimeoutMilliseconds, forwardWrite: forwardWrite
        ).run()
    }
}

/// One connected socket. Owns the descriptor: it is closed when the last reference goes away, so a
/// thread that still holds the link can never touch a recycled descriptor.
private final class Link: @unchecked Sendable {  // immutable fd + a semaphore, both thread-safe
    let fd: Int32
    let finished = DispatchSemaphore(value: 0)

    init(fd: Int32) { self.fd = fd }
    deinit { close(fd) }

    /// Wakes a reader blocked in `read` and makes the peer see EOF. Does not close the descriptor.
    func shutdownBoth() { shutdown(fd, SHUT_RDWR) }
}

private final class Session: @unchecked Sendable {  // mutable state is guarded by stateLock / outputLock
    private let handshakeURL: URL
    private let input: Int32
    private let output: Int32
    private let log: @Sendable (String) -> Void
    private let connect: @Sendable (String) throws -> Int32
    private let helloTimeoutMilliseconds: Int32
    private let drainTimeoutMilliseconds: Int32
    private let forwardWrite: @Sendable (Int32, Data) -> Bool

    // Guarded by stateLock: the current connection and the ids forwarded without a response yet.
    // A condition so the EOF drain can wait for `pending` to empty (broadcast on every change).
    private let stateLock = NSCondition()
    private var link: Link?
    /// The most recent link even after it was retired, so exit can wait for its reader thread (which
    /// may still be writing the failure replies of a retirement that just released the drain).
    private var lastLink: Link?
    private var pending: [JSONRPCID] = []

    // Guarded by outputLock: serializes whole lines on stdout between the two threads.
    // `finished` is set when run() is about to close the wake pipe: after that a stale reader thread
    // neither writes to stdout nor to the (possibly recycled) wake descriptor.
    private let outputLock = NSLock()
    private var outputBroken = false
    private var finished = false

    // Self-pipe so the socket thread can wake the stdin loop when stdout is gone. Both are written
    // exactly once in run(), before any socket thread exists, and only read afterwards.
    private var wakeRead: Int32 = -1
    private var wakeWrite: Int32 = -1

    init(
        handshakeURL: URL, input: Int32, output: Int32, log: @escaping @Sendable (String) -> Void,
        connect: @escaping @Sendable (String) throws -> Int32, helloTimeoutMilliseconds: Int32,
        drainTimeoutMilliseconds: Int32, forwardWrite: @escaping @Sendable (Int32, Data) -> Bool
    ) {
        self.handshakeURL = handshakeURL
        self.input = input
        self.output = output
        self.log = log
        self.connect = connect
        self.helloTimeoutMilliseconds = helloTimeoutMilliseconds
        self.drainTimeoutMilliseconds = drainTimeoutMilliseconds
        self.forwardWrite = forwardWrite
    }

    // MARK: Main loop (caller's thread)

    func run() -> Int32 {
        // A closed stdout must surface as EPIPE from write, never as a signal.
        _ = fcntl(output, F_SETNOSIGPIPE, 1)

        var wake: [Int32] = [0, 0]
        guard pipe(&wake) == 0 else {
            log("cannot create wake pipe: errno \(errno)")
            return 1
        }
        wakeRead = wake[0]
        wakeWrite = wake[1]
        for descriptor in wake {
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        }
        defer {
            outputLock.lock()
            finished = true
            outputLock.unlock()
            close(wake[0])
            close(wake[1])
        }

        var framer = LineFramer(maxLineBytes: StdioRelay.maxInputLineBytes)
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var status: Int32 = 0

        loop: while true {
            if isOutputBroken { break }
            var descriptors = [
                pollfd(fd: input, events: Int16(POLLIN), revents: 0),
                pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0),
            ]
            let ready = poll(&descriptors, 2, -1)
            if ready < 0 {
                if errno == EINTR { continue }
                log("poll failed: errno \(errno)")
                status = 1
                break
            }
            if descriptors[1].revents != 0 {
                drainWakePipe()
                continue
            }
            guard descriptors[0].revents != 0 else { continue }
            let count = buffer.withUnsafeMutableBytes { read(input, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                log("stdin read failed: errno \(errno)")
                status = 1
                break
            }
            if count == 0 { break }  // EOF
            for event in framer.append(Data(buffer[0..<count])) {
                handle(event)
                if isOutputBroken { break loop }
            }
        }

        if !isOutputBroken { waitForPendingAnswers() }
        closeConnectionForExit()
        return isOutputBroken ? 1 : status
    }

    private func drainWakePipe() {
        var scratch = [UInt8](repeating: 0, count: 64)
        while true {
            let count = scratch.withUnsafeMutableBytes { read(wakeRead, $0.baseAddress, $0.count) }
            if count <= 0 { return }
        }
    }

    private func handle(_ event: LineFramer.Event) {
        switch event {
        case .tooLong:
            log("dropped an input line longer than \(StdioRelay.maxInputLineBytes) bytes")
            _ = writeOutput(
                JSONRPCOutbound.error(
                    id: nil, .invalidRequest("Request line exceeds the 1 MiB limit.")))
        case .line(let line):
            process(line)
        }
    }

    /// Forwards one line. A write that fails on a connection the app has already closed is retried
    /// once on a fresh connection, since the line was never delivered.
    private func process(_ line: Data) {
        var parsed = JSONRPCInbound.parse(line: line)
        if case .invalid = parsed, Self.isResponse(line) {
            // A reply from the client (to a server request): pass it through when connected, never
            // track it as pending and never answer it with an error.
            parsed = .notification(method: "", params: nil)
        }
        let id: JSONRPCID?
        switch parsed {
        case .request(let requestID, _, _): id = requestID
        case .invalid(let invalidID, _): id = invalidID
        case .notification: id = nil
        }

        for _ in 0..<2 {
            let link: Link
            switch obtainLink() {
            case .success(let obtained): link = obtained
            case .failure(let failure):
                replyUnavailable(parsed, message: failure.message)
                return
            }
            guard register(id, on: link) else { continue }  // retired in the meantime
            var framed = line
            framed.append(0x0A)
            if forwardWrite(link.fd, framed) { return }
            log("write to the ProxyWoman socket failed")
            // If the reader already failed this id, the client has its answer: do not retry.
            guard unregister(id) else { return }
            retire(link, message: StdioRelay.connectionClosedMessage)
        }
        replyUnavailable(parsed, message: StdioRelay.appUnavailableMessage)
    }

    private func replyUnavailable(_ parsed: JSONRPCInbound, message: String) {
        switch parsed {
        case .request(let id, _, _):
            _ = writeOutput(JSONRPCOutbound.error(id: id, .appUnavailable(message)))
        case .invalid(let id, let error):
            _ = writeOutput(JSONRPCOutbound.error(id: id, error))
        case .notification:
            log("dropped a line that needs no reply: ProxyWoman unavailable")
        }
    }

    /// stdin hit EOF: give requests that were already forwarded a bounded time to be answered.
    private func waitForPendingAnswers() {
        let deadline = Date(timeIntervalSinceNow: TimeInterval(drainTimeoutMilliseconds) / 1000)
        stateLock.lock()
        defer { stateLock.unlock() }
        while link != nil && !pending.isEmpty {
            if !stateLock.wait(until: deadline) {
                log("gave up waiting for \(pending.count) unanswered request(s)")
                return
            }
        }
    }

    private func closeConnectionForExit() {
        stateLock.lock()
        let current = link
        let last = lastLink
        link = nil
        pending = []
        stateLock.unlock()
        current?.shutdownBoth()
        // Let the reader thread unwind (finish its replies, close the descriptor); bounded in case
        // it is stuck writing to a stdout nobody reads.
        _ = last?.finished.wait(timeout: .now() + 2)
    }

    // MARK: State

    private var isOutputBroken: Bool {
        outputLock.lock()
        defer { outputLock.unlock() }
        return outputBroken
    }

    private func register(_ id: JSONRPCID?, on link: Link) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard self.link === link else { return false }
        if let id { pending.append(id) }
        return true
    }

    /// True when the id was still pending (or there is no id).
    private func unregister(_ id: JSONRPCID?) -> Bool {
        guard let id else { return true }
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let index = pending.firstIndex(of: id) else { return false }
        pending.remove(at: index)
        stateLock.broadcast()
        return true
    }

    /// A response for `id` arrived on `link`. A stale reader (its link already replaced) must not
    /// remove ids that belong to the current connection.
    private func completed(_ id: JSONRPCID, on link: Link) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard self.link === link else { return }
        if let index = pending.firstIndex(of: id) {
            pending.remove(at: index)
            stateLock.broadcast()
        }
    }

    private var hasPending: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !pending.isEmpty
    }

    /// Drops `link` if it is still current and answers every request that was forwarded on it.
    /// Idempotent: the caller that actually detaches the link owns the replies.
    private func retire(_ link: Link, message: String) {
        stateLock.lock()
        guard self.link === link else {
            stateLock.unlock()
            return
        }
        self.link = nil
        let orphaned = pending
        pending = []
        stateLock.broadcast()
        stateLock.unlock()

        link.shutdownBoth()
        for id in orphaned {
            _ = writeOutput(JSONRPCOutbound.error(id: id, .appUnavailable(message)))
        }
    }

    // MARK: stdout

    /// Writes one protocol line. After the first failure (EPIPE...) everything is refused and the
    /// stdin loop is woken so `run()` can return 1.
    private func writeOutput(_ line: Data) -> Bool {
        outputLock.lock()
        defer { outputLock.unlock() }
        guard !outputBroken, !finished else { return false }
        var framed = line
        framed.append(0x0A)
        if UnixSocket.writeAll(output, framed) { return true }
        outputBroken = true
        log("stdout is closed; stopping")
        var byte: UInt8 = 1
        _ = write(wakeWrite, &byte, 1)  // safe: `finished` is still false, so the pipe is open
        return false
    }

    // MARK: Connecting (caller's thread)

    private struct Unavailable: Error { var message: String }

    private func obtainLink() -> Result<Link, Unavailable> {
        stateLock.lock()
        let existing = link
        stateLock.unlock()
        if let existing { return .success(existing) }
        return connectNew()
    }

    private func connectNew() -> Result<Link, Unavailable> {
        let base = StdioRelay.appUnavailableMessage
        let handshake: MCPHandshake
        do {
            handshake = try HandshakeFile.read(at: handshakeURL)
        } catch let failure as HandshakeFile.Failure {
            log("handshake file \(handshakeURL.path) rejected: \(failure)")
            if failure == .missing { return .failure(Unavailable(message: base)) }
            return .failure(Unavailable(message: "\(base) (handshake file: \(failure))"))
        } catch {
            log("handshake file \(handshakeURL.path) unreadable: \(error)")
            return .failure(Unavailable(message: base))
        }

        let fd: Int32
        do {
            fd = try connect(handshake.socketPath)
        } catch {
            log("cannot connect to \(handshake.socketPath): \(error)")
            return .failure(Unavailable(message: base))
        }
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let link = Link(fd: fd)  // closes `fd` if the handshake below fails

        let hello = MCPHello(
            token: handshake.token, client: StdioRelay.clientName, protocolVersion: 1)
        var helloLine = hello.line()
        helloLine.append(0x0A)
        guard UnixSocket.writeAll(fd, helloLine) else {
            log("cannot send hello to \(handshake.socketPath)")
            return .failure(Unavailable(message: base))
        }
        guard let leftover = awaitAcknowledgement(on: link) else {
            return .failure(Unavailable(message: base))
        }

        stateLock.lock()
        self.link = link
        lastLink = link
        stateLock.unlock()
        let thread = Thread { [self] in readSocket(link, initial: leftover) }
        thread.name = "proxywoman-mcp.socket-reader"
        thread.start()
        return .success(link)
    }

    /// Waits up to the hello timeout for the first server line to be `{"ok":true}`. Returns bytes
    /// that followed it in the same read (normally none), or nil when the server refused.
    private func awaitAcknowledgement(on link: Link) -> Data? {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(helloTimeoutMilliseconds) * 1_000_000
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            if let newline = received.firstIndex(of: 0x0A) {
                var first = received[received.startIndex..<newline]
                if first.last == 0x0D { first = first.dropLast() }
                let accepted = (try? JSONValue.parse(Data(first)))?["ok"]?.boolValue == true
                if !accepted {
                    log("the server refused the hello")
                    return nil
                }
                return Data(received[received.index(after: newline)...])
            }
            guard received.count <= buffer.count else {
                log("the server's hello reply is too long")
                return nil
            }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else {
                log("the server did not answer the hello in time")
                return nil
            }
            var descriptor = pollfd(fd: link.fd, events: Int16(POLLIN), revents: 0)
            let milliseconds = Int32(min((deadline - now) / 1_000_000 + 1, UInt64(Int32.max)))
            let ready = poll(&descriptor, 1, milliseconds)
            if ready < 0 {
                if errno == EINTR { continue }
                log("poll failed during the hello: errno \(errno)")
                return nil
            }
            if ready == 0 { continue }
            let count = buffer.withUnsafeMutableBytes { read(link.fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                log("read failed during the hello: errno \(errno)")
                return nil
            }
            if count == 0 {
                log("the server closed the connection during the hello")
                return nil
            }
            received.append(contentsOf: buffer[0..<count])
        }
    }

    // MARK: Socket reader (dedicated thread)

    private func readSocket(_ link: Link, initial: Data) {
        var framer = LineFramer(maxLineBytes: StdioRelay.maxServerLineBytes)
        var healthy = deliver(framer.append(initial), from: link)
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while healthy {
            let count = buffer.withUnsafeMutableBytes { read(link.fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                log("socket read failed: errno \(errno)")
                break
            }
            if count == 0 { break }
            healthy = deliver(framer.append(Data(buffer[0..<count])), from: link)
        }
        retire(link, message: StdioRelay.connectionClosedMessage)
        log("connection to ProxyWoman closed")
        link.finished.signal()
    }

    /// Passes server lines to stdout verbatim. False when the connection should be dropped.
    private func deliver(_ events: [LineFramer.Event], from link: Link) -> Bool {
        for event in events {
            switch event {
            case .tooLong:
                log("dropping the connection: the server sent an oversized line")
                return false
            case .line(let line):
                if hasPending, let id = responseID(in: line) { completed(id, on: link) }
                if !writeOutput(line) { return false }
            }
        }
        return true
    }

    /// A JSON-RPC response object: no `method`, but a `result` or an `error`.
    private static func isResponse(_ line: Data) -> Bool {
        guard let value = try? JSONValue.parse(line), value.objectValue != nil, value["method"] == nil
        else { return false }
        return value["result"] != nil || value["error"] != nil
    }

    /// The id of a response (a message with an `id` and no `method`).
    private func responseID(in line: Data) -> JSONRPCID? {
        guard let value = try? JSONValue.parse(line), value["method"] == nil else { return nil }
        switch value["id"] {
        case .int(let number): return .int(number)
        case .string(let text): return .string(text)
        default: return nil
        }
    }
}
