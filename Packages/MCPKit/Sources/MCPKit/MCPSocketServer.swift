import Foundation
import MCPWire
import os

/// The app side of the MCP transport (spec D2–D4, S1, S7): one AF_UNIX stream socket, mode 0600, in a
/// directory only this user can write, plus a 0600 handshake file carrying a fresh token per start.
///
/// Admission, in order: connection limit, peer effective uid (`getpeereid`), then a hello line
/// `{"hello":{token,client,protocolVersion:1}}` within `helloTimeout` whose token matches in constant
/// time. Any failure closes the connection without a byte of reply. After `{"ok":true}` every line is
/// one JSON-RPC message for that connection's own `MCPSession`, handled strictly one at a time so the
/// answers keep the request order.
///
/// Trust boundary of the paths: only the final directory component is verified (not a symlink, ours,
/// not group/other writable). Its ancestors are trusted: in the standard layout they are the user's own
/// `~/Library/Application Support/…`; an isolated root was already validated by `IsolatedLaunch`.
///
/// Threads: one dedicated accept `Thread`, and one dedicated `Thread` per connection doing blocking
/// reads and writes; only `MCPSession.handle(line:)` runs on the cooperative pool (as a `Task` the
/// connection thread waits for). The threads hold a `Run` (the per-start state), never the server, so
/// dropping the last reference to the server runs `deinit`.
///
/// Stopping is split in two:
/// - `beginStop()` never blocks: it stops accepting, removes the socket and handshake files, cancels
///   every in-flight call and shuts every connection down. Safe on the main thread.
/// - `waitUntilStopped()` blocks until every thread of every stopped run has exited. It returns as soon
///   as the in-flight calls end, which is prompt when tools honour cancellation, but a tool that awaits
///   something that never completes keeps it waiting. Never call it on the main thread (a tool may be
///   waiting for a main-actor hop) or from inside a tool handler (it would wait for itself).
/// `stop()` is both, for tests and background callers. `deinit` only begins the stop and joins on a
/// background queue. `makeSession` must not capture the server strongly.
///
/// Nothing is ever written to stdout.
public final class MCPSocketServer: Sendable {
    public struct Configuration: Sendable {
        /// Holds `mcp.sock` and `mcp-handshake.json`.
        public var directory: URL
        /// True for the standard layout (created as / tightened to 0700); false for an isolated root,
        /// which must already exist and is only verified, never changed.
        public var createsDirectory: Bool
        public var maxConnections = 8
        public var maxLineBytes = 1_048_576
        public var helloTimeout: Duration = .seconds(3)

        public init(directory: URL, createsDirectory: Bool) {
            self.directory = directory
            self.createsDirectory = createsDirectory
        }
    }

    public enum StartFailure: Error, Equatable {
        /// The socket path (or, in a directory others can traverse, the private staging path) does not
        /// fit `sun_path`.
        case pathTooLong
        /// The directory is missing (isolated root), a symlink, not a directory, not ours, writable by
        /// group/other, or something that is not our stale socket sits at the socket path.
        case directoryUnsafe
        /// Creating or opening the directory failed with this errno (ENOSPC, EACCES, …).
        case directoryFailed(Int32)
        case bindFailed(Int32)
        case tokenFailed
        /// This instance is running, or another live process answers on the socket path.
        case alreadyRunning
        /// The handshake file could not be written (errno).
        case handshakeFailed(Int32)
    }

    static let acknowledgement = Data(#"{"ok":true}"#.utf8) + Data([0x0A])
    static let helloProtocolVersion = 1
    /// Longest hello line (bytes before its newline). Longer: refused at once, never read further.
    static let maxHelloBytes = 4096
    static let listenBacklog: Int32 = 8
    static let oversizeLineMessage = "Request line exceeds the size limit."
    /// Name of the private directory a socket is bound in when the target directory is traversable by
    /// others (an isolated root such as 0755). Swept on start when a crash left one behind.
    static let stagingPrefix = ".mcpb."
    static let stagedSocketName = "s"
    static let handshakeTempPrefix = "." + MCPPaths.handshakeFileName + "."
    static let handshakeTempSuffix = ".tmp"
    /// umask while binding: owner-only. See `bindListening`.
    static let bindUmask: mode_t = 0o077

    /// Serializes every umask change made by this module. umask is process-global, so the lock cannot
    /// stop other code from creating files while it is narrowed (see `bindListening`).
    private static let umaskLock = NSLock()

    private let configuration: Configuration
    private let makeSession: @Sendable () -> MCPSession
    private let peerCheck: @Sendable (Int32) -> Bool
    private let makeToken: @Sendable () throws -> String
    private let calls: SocketCalls
    /// Held for the whole of `start` and `beginStop` (both short), so they never interleave.
    private let lifecycle = NSLock()
    private let current = OSAllocatedUnfairLock<Active?>(initialState: nil)
    /// Runs that were stopped (or whose accept loop died) and whose threads may still be unwinding.
    private let stopping = OSAllocatedUnfairLock<[Run]>(initialState: [])

    public convenience init(configuration: Configuration, makeSession: @escaping @Sendable () -> MCPSession) {
        self.init(configuration: configuration, makeSession: makeSession, peerCheck: Self.peerIsCurrentUser)
    }

    /// Test seam: `peerCheck` decides on an accepted descriptor; `makeToken` replaces `MCPToken.generate`;
    /// `calls` replaces the connect probe, `bind` and `accept`.
    init(
        configuration: Configuration, makeSession: @escaping @Sendable () -> MCPSession,
        peerCheck: @escaping @Sendable (Int32) -> Bool,
        makeToken: @escaping @Sendable () throws -> String = MCPToken.generate,
        calls: SocketCalls = SocketCalls()
    ) {
        self.configuration = configuration
        self.makeSession = makeSession
        self.peerCheck = peerCheck
        self.makeToken = makeToken
        self.calls = calls
    }

    deinit {
        beginStop()
        // Never join here: the last reference may be dropped on the main thread.
        let runs = stopping.withLock { $0 }
        guard !runs.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            for run in runs { run.threads.wait() }
        }
    }

    /// The peer's effective uid (from the kernel, not from anything the peer says) is ours.
    static func peerIsCurrentUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return false }
        return uid == geteuid()
    }

    /// False once stopped, and also when the accept loop died (its files are then already removed).
    public var isRunning: Bool { current.withLock { $0 }.map { !$0.run.isShutDown } ?? false }

    /// Accepted connections not yet closed, including ones still inside their hello window.
    public var connectionCount: Int { current.withLock { $0 }?.run.count ?? 0 }

    /// The current token, empty when not running. Test seam.
    var token: String {
        guard let run = current.withLock({ $0 })?.run, !run.isShutDown else { return "" }
        return run.token
    }

    /// Waits (no polling) until `connectionCount == expected`. Test seam.
    func waitForConnectionCount(_ expected: Int, timeout: Duration) -> Bool {
        guard let active = current.withLock({ $0 }) else { return expected == 0 }
        return active.run.waitForCount(expected, timeout: timeout)
    }

    /// The process umask, read under the same lock `start` binds under. Test seam.
    static func currentUmask() -> mode_t {
        umaskLock.lock()
        defer { umaskLock.unlock() }
        let mask = umask(0o022)
        umask(mask)
        return mask
    }

    // MARK: Start

    /// Verifies the directory, replaces a stale socket, binds and listens, then makes a fresh token and
    /// writes the handshake file — last, so a client that sees the handshake can always connect.
    /// Throws `.alreadyRunning` when this instance already runs or another process answers on the path.
    public func start() throws {
        lifecycle.lock()
        defer { lifecycle.unlock() }
        if let active = current.withLock({ $0 }) {
            guard active.run.isShutDown else { throw StartFailure.alreadyRunning }
            retire(active)  // its accept loop died; its threads unwind on their own
        }

        let directory = configuration.directory
        let socketPath = MCPPaths.socketURL(in: directory).path
        let handshakeURL = MCPPaths.handshakeURL(in: directory)
        guard MCPPaths.fitsSocketPath(MCPPaths.socketURL(in: directory)) else { throw StartFailure.pathTooLong }

        let directoryMode = try Self.prepareDirectory(directory, creates: configuration.createsDirectory)
        try Self.clearSocketPath(socketPath, connect: calls.connect)
        // Only now is the directory ours to tidy (a live instance would have answered above).
        Self.sweepLeftovers(in: directory.path)

        let listener = try Self.bindListening(
            socketPath: socketPath, directory: directory.path,
            othersCanTraverse: directoryMode & 0o077 != 0, bind: calls.bind)

        let token: String
        do {
            token = try makeToken()
        } catch {
            listener.close()
            Self.removeIfSame(socketPath, listener.socketIdentity)
            throw StartFailure.tokenFailed
        }

        let handshakeIdentity: FileIdentity?
        do {
            let handshake = MCPHandshake(
                version: MCPHandshake.currentVersion, pid: getpid(), socketPath: socketPath, token: token,
                startedAt: Date())
            try HandshakeFile.write(handshake, to: handshakeURL)
            handshakeIdentity = FileIdentity(path: handshakeURL.path)
        } catch {
            listener.close()
            Self.removeIfSame(socketPath, listener.socketIdentity)
            Self.removeHandshake(at: handshakeURL.path, identity: nil, token: token)
            throw StartFailure.handshakeFailed((error as? POSIXError)?.code.rawValue ?? EIO)
        }

        let publication = Publication(
            socketPath: socketPath, socketIdentity: listener.socketIdentity, handshakePath: handshakeURL.path,
            handshakeIdentity: handshakeIdentity)
        let run = Run(
            token: token, configuration: configuration, makeSession: makeSession, peerCheck: peerCheck,
            accept: calls.accept, publication: publication)
        run.threads.enter()
        let thread = Thread {
            run.acceptLoop(listener)
            run.threads.leave()
        }
        thread.name = "ProxyWoman.MCP.accept"
        thread.start()

        current.withLock { $0 = Active(run: run, listener: listener) }
    }

    // MARK: Stop

    /// Does not block: stops accepting (wakes the accept loop through its self-pipe), removes the socket
    /// and handshake files, cancels every in-flight call and shuts every connection down. Threads finish
    /// on their own; `waitUntilStopped()` joins them. Idempotent; a later `start()` may run at once.
    public func beginStop() {
        lifecycle.lock()
        defer { lifecycle.unlock() }
        guard let active = current.withLock({ $0 }) else { return }
        retire(active)
        active.listener.wake()
        active.run.shutDown()
    }

    /// Blocks until every thread of every run stopped so far has exited. Never call it on the main thread
    /// or from a tool handler (see the type comment).
    public func waitUntilStopped() {
        let runs = stopping.withLock { $0 }
        for run in runs { run.threads.wait() }
        stopping.withLock { list in list.removeAll { run in runs.contains { $0 === run } } }
    }

    /// `beginStop()` then `waitUntilStopped()`. Not for the main thread.
    public func stop() {
        beginStop()
        waitUntilStopped()
    }

    /// Moves the run out of `current`. Caller holds `lifecycle`.
    private func retire(_ active: Active) {
        current.withLock { $0 = nil }
        stopping.withLock { $0.append(active.run) }
    }

    // MARK: Directory and socket path

    /// Returns the directory's permission bits after verification. The final component is opened with
    /// `O_NOFOLLOW` and checked/changed through that descriptor, so a swapped-in symlink is never
    /// followed.
    private static func prepareDirectory(_ directory: URL, creates: Bool) throws -> mode_t {
        let path = directory.path
        var info = stat()
        if lstat(path, &info) != 0 {
            let code = errno
            guard code == ENOENT else { throw StartFailure.directoryFailed(code) }
            guard creates else { throw StartFailure.directoryUnsafe }  // an isolated root must exist
            try createAncestors(of: directory)
            // mkdir's mode is narrowed by the umask, never widened; the fchmod below makes it exact.
            if mkdir(path, 0o700) != 0 && errno != EEXIST { throw StartFailure.directoryFailed(errno) }
        }

        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            let code = errno
            switch code {
            case ELOOP, ENOTDIR, ENOENT: throw StartFailure.directoryUnsafe  // symlink, file, vanished
            default: throw StartFailure.directoryFailed(code)
            }
        }
        defer { close(fd) }
        guard fstat(fd, &info) == 0 else { throw StartFailure.directoryFailed(errno) }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o022 == 0 else {
            throw StartFailure.directoryUnsafe
        }

        if creates && info.st_mode & 0o7777 != 0o700 {
            guard fchmod(fd, 0o700) == 0 else { throw StartFailure.directoryFailed(errno) }
            guard fstat(fd, &info) == 0, info.st_mode & 0o7777 == 0o700 else { throw StartFailure.directoryUnsafe }
        }
        return info.st_mode & 0o7777
    }

    /// `mkdir -p` for the ancestors (standard layout only), with the process umask like any other
    /// directory the app creates.
    private static func createAncestors(of directory: URL) throws {
        var missing: [String] = []
        var ancestor = directory.deletingLastPathComponent()
        while ancestor.path != "/", !ancestor.path.isEmpty, lstatInfo(ancestor.path) == nil, errno == ENOENT {
            missing.append(ancestor.path)
            ancestor = ancestor.deletingLastPathComponent()
        }
        for path in missing.reversed() where mkdir(path, 0o777) != 0 && errno != EEXIST {
            throw StartFailure.directoryFailed(errno)
        }
    }

    /// Nothing at the path: fine. Our socket that definitely nobody listens on (ECONNREFUSED): a crashed
    /// instance's, removed. Our socket that answers, or refuses only for now (EAGAIN, ETIMEDOUT: a live
    /// listener with a full backlog): `.alreadyRunning`. Any other probe error (EMFILE, EACCES, EINTR…):
    /// `.bindFailed(errno)`, nothing removed. Anything that is not our socket (regular file, symlink,
    /// directory, FIFO, someone else's socket): `.directoryUnsafe`, and it is never deleted.
    private static func clearSocketPath(_ path: String, connect: @Sendable (String) throws -> Int32) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            let code = errno
            if code == ENOENT { return }
            throw StartFailure.directoryFailed(code)
        }
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == geteuid() else {
            throw StartFailure.directoryUnsafe
        }
        do {
            let probe = try connect(path)
            close(probe)
            throw StartFailure.alreadyRunning
        } catch let failure as UnixSocket.Failure {
            switch failure {
            case .connectFailed(ECONNREFUSED), .connectFailed(ENOENT):
                break  // stale
            case .connectFailed(EAGAIN), .connectFailed(ETIMEDOUT):
                throw StartFailure.alreadyRunning
            case .connectFailed(let code), .bindFailed(let code), .listenFailed(let code):
                throw StartFailure.bindFailed(code)
            case .pathTooLong:
                throw StartFailure.pathTooLong
            }
        } catch let failure as StartFailure {
            throw failure
        } catch {
            throw StartFailure.bindFailed(EIO)
        }
        guard removeIfSame(path, FileIdentity(info)) else { throw StartFailure.directoryUnsafe }
    }

    /// Removes leftovers of a crash, only when they are ours: handshake temp files
    /// (`.mcp-handshake.json.<uuid>.tmp`, regular files owned by us — they hold a token) and staging
    /// directories (owned by us; only an inner socket node is unlinked, then `rmdir`, which fails and
    /// keeps anything unexpected).
    private static func sweepLeftovers(in directory: String) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
        for name in names {
            let path = directory + "/" + name
            guard let info = lstatInfo(path), info.st_uid == geteuid() else { continue }
            if name.hasPrefix(handshakeTempPrefix), name.hasSuffix(handshakeTempSuffix),
                name.count > handshakeTempPrefix.count + handshakeTempSuffix.count
            {
                if info.st_mode & S_IFMT == S_IFREG { unlink(path) }
            } else if name.hasPrefix(stagingPrefix), info.st_mode & S_IFMT == S_IFDIR {
                let inner = path + "/" + stagedSocketName
                if let innerInfo = lstatInfo(inner), innerInfo.st_mode & S_IFMT == S_IFSOCK,
                    innerInfo.st_uid == geteuid()
                {
                    unlink(inner)
                }
                rmdir(path)
            }
        }
    }

    // MARK: Binding

    /// Creates the listening socket at `socketPath`, ending up exactly 0600.
    ///
    /// How the mode is guaranteed:
    /// - The node is only ever created where no other user can reach it: directly in the directory when
    ///   that directory grants group/other nothing (the standard 0700 layout), otherwise inside a private
    ///   `mkdtemp` (0700) staging directory, then moved into place with `renamex_np(RENAME_EXCL)` (never
    ///   replaces anything that appeared meanwhile).
    /// - `bind` runs under `umask(0o077)`, so the kernel creates the node owner-only (0700): no group or
    ///   other bit exists at any moment. umask is process-wide: `umaskLock` serializes our own
    ///   set/bind/restore but cannot stop another thread from creating a file or directory during those
    ///   microseconds. Such a file or directory loses its group/other bits (a 0755 directory becomes 0700,
    ///   a 0644 file 0600); the owner keeps full access. 0o077 rather than 0o177 so that such a directory
    ///   stays usable by its owner. If foreign code changed the umask in that window, our node could
    ///   come out wider — still unreachable, see the previous point, and checked next.
    /// - Right after bind the mode is set to exactly 0600 (`fchmodat`, no symlink following) and checked
    ///   with `lstat` (a socket, ours, exactly 0600); after the move the final path is checked to be that
    ///   same node. Any mismatch fails the start.
    /// Peers are still checked by uid and token, so even a wider node would not admit another user.
    private static func bindListening(
        socketPath: String, directory: String, othersCanTraverse: Bool,
        bind: @Sendable (Int32, sockaddr_un) -> Int32
    ) throws -> Listener {
        var stagingDirectory: String?
        var bindPath = socketPath
        if othersCanTraverse {
            var template = Array((directory + "/" + stagingPrefix + "XXXXXX").utf8CString)
            guard let created = mkdtemp(&template) else { throw StartFailure.bindFailed(errno) }
            let staging = String(cString: created)
            stagingDirectory = staging
            bindPath = staging + "/" + stagedSocketName
        }
        defer {
            if let stagingDirectory {
                unlink(stagingDirectory + "/" + stagedSocketName)  // gone after a successful move
                rmdir(stagingDirectory)
            }
        }
        if let stagingDirectory {
            guard let info = lstatInfo(stagingDirectory), info.st_mode & S_IFMT == S_IFDIR,
                info.st_uid == geteuid(), info.st_mode & 0o077 == 0
            else { throw StartFailure.directoryUnsafe }
        }

        let address: sockaddr_un
        do {
            address = try UnixSocket.address(for: bindPath)
        } catch {
            throw StartFailure.pathTooLong
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartFailure.bindFailed(errno) }
        var keep = false
        defer { if !keep { close(fd) } }
        // Non-blocking so a client that vanished between poll and accept cannot stall the loop.
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0, fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0
        else { throw StartFailure.bindFailed(errno) }

        umaskLock.lock()
        let previousMask = umask(bindUmask)
        let bindError = bind(fd, address)
        umask(previousMask)
        umaskLock.unlock()
        guard bindError == 0 else { throw StartFailure.bindFailed(bindError) }

        // From here on the node exists: remove it on any failure (only if it is still the same node).
        guard fchmodat(AT_FDCWD, bindPath, 0o600, AT_SYMLINK_NOFOLLOW) == 0,
            let boundInfo = lstatInfo(bindPath), isPrivateSocket(boundInfo)
        else {
            if stagingDirectory == nil { removeIfSame(bindPath, lstatInfo(bindPath).map(FileIdentity.init)) }
            throw StartFailure.directoryUnsafe
        }
        let identity = FileIdentity(boundInfo)

        guard listen(fd, listenBacklog) == 0 else {
            let code = errno
            if stagingDirectory == nil { removeIfSame(bindPath, identity) }
            throw StartFailure.bindFailed(code)
        }

        if stagingDirectory != nil {
            guard renamex_np(bindPath, socketPath, UInt32(RENAME_EXCL)) == 0 else {
                throw StartFailure.bindFailed(errno)
            }
        }
        guard let finalInfo = lstatInfo(socketPath), isPrivateSocket(finalInfo), FileIdentity(finalInfo) == identity
        else {
            removeIfSame(socketPath, identity)
            throw StartFailure.directoryUnsafe
        }

        var wake: [Int32] = [-1, -1]
        guard pipe(&wake) == 0 else {
            let code = errno
            removeIfSame(socketPath, identity)
            throw StartFailure.bindFailed(code)
        }
        for descriptor in wake {
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        }
        keep = true
        return Listener(fd: fd, wakeRead: wake[0], wakeWrite: wake[1], socketIdentity: identity)
    }

    private static func isPrivateSocket(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFSOCK && info.st_uid == geteuid() && info.st_mode & 0o7777 == 0o600
    }

    /// Unlinks `path` only while it is still the node identified by `identity`. True when the path is
    /// gone afterwards.
    @discardableResult
    fileprivate static func removeIfSame(_ path: String, _ identity: FileIdentity?) -> Bool {
        guard let identity else { return false }
        guard let info = lstatInfo(path) else { return errno == ENOENT }
        guard FileIdentity(info) == identity else { return false }
        return unlink(path) == 0 || errno == ENOENT
    }

    /// Removes the handshake file if it is ours: the node we wrote (same identity) or, when its identity
    /// is unknown, a valid handshake carrying our token.
    fileprivate static func removeHandshake(at path: String, identity: FileIdentity?, token: String) {
        if let identity {
            removeIfSame(path, identity)
            return
        }
        guard let handshake = try? HandshakeFile.read(at: URL(fileURLWithPath: path)),
            MCPToken.constantTimeEqual(handshake.token, token)
        else { return }
        unlink(path)
    }

    fileprivate static func lstatInfo(_ path: String) -> stat? {
        var info = stat()
        return lstat(path, &info) == 0 ? info : nil
    }
}

// MARK: - System calls (test seam)

/// The socket system calls whose failures tests need to reach.
struct SocketCalls: Sendable {
    /// Probes an existing socket node: a connected descriptor (closed by the caller), or a thrown
    /// `UnixSocket.Failure`.
    var connect: @Sendable (String) throws -> Int32 = UnixSocket.connect(path:)
    /// 0, or the errno of a failed bind. Runs with the bind umask in effect.
    var bind: @Sendable (Int32, sockaddr_un) -> Int32 = SocketCalls.systemBind
    /// An accepted descriptor and 0, or -1 and the errno.
    var accept: @Sendable (Int32) -> (fd: Int32, error: Int32) = SocketCalls.systemAccept

    static func systemBind(_ fd: Int32, _ address: sockaddr_un) -> Int32 {
        var address = address
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0 ? 0 : errno
    }

    static func systemAccept(_ listener: Int32) -> (fd: Int32, error: Int32) {
        let fd = Darwin.accept(listener, nil, nil)
        return fd >= 0 ? (fd, 0) : (-1, errno)
    }
}

// MARK: - Per-start state

private struct FileIdentity: Equatable, Sendable {
    var device: dev_t
    var inode: ino_t

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
    }

    init?(path: String) {
        guard let info = MCPSocketServer.lstatInfo(path) else { return nil }
        self.init(info)
    }
}

/// The files one start published, removed (only if still ours) when the run shuts down.
private struct Publication: Sendable {
    let socketPath: String
    let socketIdentity: FileIdentity
    let handshakePath: String
    let handshakeIdentity: FileIdentity?
}

private struct Active: Sendable {
    let run: Run
    let listener: Listener
}

/// The listening socket and the self-pipe that wakes the accept loop. Descriptors are closed exactly
/// once, under `closed` (by the accept loop as it exits), so `wake` never writes to a recycled
/// descriptor.
private final class Listener: Sendable {
    let fd: Int32
    let wakeRead: Int32
    private let wakeWrite: Int32
    let socketIdentity: FileIdentity
    private let closed = OSAllocatedUnfairLock(initialState: false)

    init(fd: Int32, wakeRead: Int32, wakeWrite: Int32, socketIdentity: FileIdentity) {
        self.fd = fd
        self.wakeRead = wakeRead
        self.wakeWrite = wakeWrite
        self.socketIdentity = socketIdentity
    }

    deinit { close() }

    func wake() {
        closed.withLock { closed in
            guard !closed else { return }
            var byte: UInt8 = 1
            _ = Darwin.write(wakeWrite, &byte, 1)  // non-blocking; one pending byte is enough
        }
    }

    /// Called by the accept loop as it exits, or by `start` before any loop ran.
    func close() {
        closed.withLock { closed in
            guard !closed else { return }
            closed = true
            Darwin.close(fd)
            Darwin.close(wakeRead)
            Darwin.close(wakeWrite)
        }
    }
}

/// One accepted socket. The descriptor is read and written only by its own thread; `cancel` (from a
/// stop) and `close` (from that thread, last) are serialized by `state`, so a shutdown never hits a
/// descriptor number that was already closed and reused.
private final class Connection: Sendable {
    private struct State: Sendable {
        var closed = false
        var cancelled = false
        var call: Task<Void, Never>?
    }

    let id: Int
    let fd: Int32
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(id: Int, fd: Int32) {
        self.id = id
        self.fd = fd
    }

    deinit { close() }

    var isCancelled: Bool { state.withLock { $0.cancelled } }

    /// Marks the connection cancelled, cancels the in-flight call and shuts the socket down both ways,
    /// which wakes a blocked read (EOF) or write (EPIPE) on the connection thread. Never blocks.
    func cancel() {
        let call = state.withLock { state -> Task<Void, Never>? in
            state.cancelled = true
            if !state.closed { shutdown(fd, SHUT_RDWR) }
            defer { state.call = nil }
            return state.call
        }
        call?.cancel()
    }

    /// Records the in-flight call; false when the connection was already cancelled (the caller then
    /// cancels the call itself).
    func begin(_ call: Task<Void, Never>) -> Bool {
        state.withLock { state in
            guard !state.cancelled else { return false }
            state.call = call
            return true
        }
    }

    func end() { state.withLock { $0.call = nil } }

    func close() {
        state.withLock { state in
            guard !state.closed else { return }
            state.closed = true
            shutdown(fd, SHUT_RDWR)  // the peer sees EOF now, whatever else still holds this object
            Darwin.close(fd)
        }
    }
}

/// Everything the accept and connection threads need for one start. They hold this, never the server.
// @unchecked: `connections`, `nextID`, `accepting` and `shutDownStarted` are only touched with
// `condition` locked; every other stored property is an immutable Sendable value.
private final class Run: @unchecked Sendable {
    let token: String
    let maxConnections: Int
    let maxLineBytes: Int
    let helloTimeout: Duration
    let makeSession: @Sendable () -> MCPSession
    let peerCheck: @Sendable (Int32) -> Bool
    let accept: @Sendable (Int32) -> (fd: Int32, error: Int32)
    let publication: Publication
    /// The accept thread and every connection thread: `enter` before start, `leave` as the last action.
    let threads = DispatchGroup()

    private let condition = NSCondition()
    private var connections: [Int: Connection] = [:]
    private var nextID = 0
    private var accepting = true
    private var shutDownStarted = false

    init(
        token: String, configuration: MCPSocketServer.Configuration,
        makeSession: @escaping @Sendable () -> MCPSession, peerCheck: @escaping @Sendable (Int32) -> Bool,
        accept: @escaping @Sendable (Int32) -> (fd: Int32, error: Int32), publication: Publication
    ) {
        self.token = token
        maxConnections = configuration.maxConnections
        maxLineBytes = configuration.maxLineBytes
        helloTimeout = configuration.helloTimeout
        self.makeSession = makeSession
        self.peerCheck = peerCheck
        self.accept = accept
        self.publication = publication
    }

    var count: Int {
        condition.lock()
        defer { condition.unlock() }
        return connections.count
    }

    var isShutDown: Bool {
        condition.lock()
        defer { condition.unlock() }
        return shutDownStarted
    }

    func waitForCount(_ expected: Int, timeout: Duration) -> Bool {
        let deadline = Date(timeIntervalSinceNow: Double(timeout / .milliseconds(1)) / 1000)
        condition.lock()
        defer { condition.unlock() }
        while connections.count != expected {
            if !condition.wait(until: deadline) { return connections.count == expected }
        }
        return true
    }

    /// Never blocks. Stops admitting, removes the published files (only if still ours), then cancels every
    /// connection's in-flight call and shuts its socket down. Idempotent.
    func shutDown() {
        condition.lock()
        guard !shutDownStarted else {
            condition.unlock()
            return
        }
        shutDownStarted = true
        accepting = false
        let open = Array(connections.values)
        condition.unlock()

        MCPSocketServer.removeHandshake(
            at: publication.handshakePath, identity: publication.handshakeIdentity, token: token)
        MCPSocketServer.removeIfSame(publication.socketPath, publication.socketIdentity)
        for connection in open { connection.cancel() }
    }

    private func admit(_ fd: Int32) -> Connection? {
        condition.lock()
        defer { condition.unlock() }
        guard accepting, connections.count < maxConnections else { return nil }
        nextID += 1
        let connection = Connection(id: nextID, fd: fd)
        connections[nextID] = connection
        condition.broadcast()
        return connection
    }

    private func remove(_ connection: Connection) {
        condition.lock()
        connections[connection.id] = nil
        condition.broadcast()
        condition.unlock()
    }

    // MARK: Accept loop (dedicated thread)

    /// Runs until woken by a stop. If it ends for any other reason (poll or accept failing), the run is
    /// shut down, so the server reports not running and nothing advertises the dead endpoint.
    func acceptLoop(_ listener: Listener) {
        let woken = runAcceptLoop(listener)
        if !woken { shutDown() }
        listener.close()
    }

    /// True when woken by a stop; false when the loop died.
    private func runAcceptLoop(_ listener: Listener) -> Bool {
        while true {
            var descriptors = [
                pollfd(fd: listener.fd, events: Int16(POLLIN), revents: 0),
                pollfd(fd: listener.wakeRead, events: Int16(POLLIN), revents: 0),
            ]
            let ready = poll(&descriptors, 2, -1)
            if ready < 0 {
                if errno == EINTR { continue }
                return false
            }
            if descriptors[1].revents != 0 { return true }
            if descriptors[0].revents & Int16(POLLNVAL | POLLERR) != 0 { return false }
            guard descriptors[0].revents & Int16(POLLIN) != 0 else { continue }

            let accepted = accept(listener.fd)
            if accepted.fd < 0 {
                switch accepted.error {
                case EINTR, EAGAIN, EWOULDBLOCK, ECONNABORTED:
                    continue
                case EMFILE, ENFILE, ENOBUFS, ENOMEM:
                    // Out of descriptors or memory: back off without spinning, still woken by a stop.
                    var wake = pollfd(fd: listener.wakeRead, events: Int16(POLLIN), revents: 0)
                    if poll(&wake, 1, 100) > 0 { return true }
                    continue
                default:
                    return false
                }
            }
            admitAccepted(accepted.fd)
        }
    }

    private func admitAccepted(_ fd: Int32) {
        // The accepted socket inherits O_NONBLOCK from the listener on Darwin: the connection thread
        // wants blocking I/O. No SIGPIPE on a write to a vanished peer.
        var on: Int32 = 1
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
            fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK) == 0,
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0
        else {
            close(fd)
            return
        }
        // Over the limit (counting clients still in their hello), or shutting down: closed before
        // anything is read.
        guard let connection = admit(fd) else {
            close(fd)
            return
        }
        let deadline = ContinuousClock.now + helloTimeout
        threads.enter()
        let thread = Thread { [self] in
            serve(connection, helloDeadline: deadline)
            threads.leave()
        }
        thread.name = "ProxyWoman.MCP.connection"
        thread.start()
    }

    // MARK: Connection (dedicated thread per connection)

    private func serve(_ connection: Connection, helloDeadline: ContinuousClock.Instant) {
        defer {
            // Leave the table first, then close: a peer that sees EOF also sees the slot freed.
            remove(connection)
            connection.close()
        }
        guard peerCheck(connection.fd) else { return }
        guard let leftover = readHello(connection, deadline: helloDeadline) else { return }
        guard UnixSocket.writeAll(connection.fd, MCPSocketServer.acknowledgement) else { return }

        let session = makeSession()
        var framer = LineFramer(maxLineBytes: maxLineBytes)
        guard process(framer.append(leftover), session: session, connection: connection) else { return }

        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(connection.fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                return
            }
            // EOF. Bytes after the last newline are still in `framer` and are dropped here, never run:
            // StdioRelay re-sends a line whose write failed on a fresh connection, which is only safe
            // because a partial line is never executed.
            if count == 0 { return }
            guard process(framer.append(Data(buffer[0..<count])), session: session, connection: connection)
            else { return }
        }
    }

    /// Reads up to the first newline within the deadline, never more than `maxHelloBytes + 1` bytes in
    /// total. Returns the bytes after the newline when the line is a valid hello for this run's token;
    /// nil (close silently) otherwise.
    private func readHello(_ connection: Connection, deadline: ContinuousClock.Instant) -> Data? {
        let limit = MCPSocketServer.maxHelloBytes + 1  // the line plus its newline
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: limit)
        while true {
            if let newline = received.firstIndex(of: 0x0A) {
                var line = received[received.startIndex..<newline]
                if line.last == 0x0D { line = line.dropLast() }
                guard let hello = MCPHello.parse(line: Data(line)),
                    hello.protocolVersion == MCPSocketServer.helloProtocolVersion,
                    MCPToken.constantTimeEqual(hello.token, token)
                else { return nil }
                return Data(received[received.index(after: newline)...])
            }
            guard received.count < limit else { return nil }  // no newline within the cap
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { return nil }
            var descriptor = pollfd(fd: connection.fd, events: Int16(POLLIN), revents: 0)
            let milliseconds = Int32(clamping: Int((remaining / .milliseconds(1)).rounded(.up)))
            let ready = poll(&descriptor, 1, max(1, milliseconds))
            if ready < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if ready == 0 { continue }  // the deadline check above ends the wait
            let wanted = limit - received.count
            let count = buffer.withUnsafeMutableBytes { read(connection.fd, $0.baseAddress, wanted) }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return nil
            }
            if count == 0 { return nil }
            received.append(contentsOf: buffer[0..<count])
        }
    }

    /// Handles framed events in order. False when the connection should close.
    private func process(_ events: [LineFramer.Event], session: MCPSession, connection: Connection) -> Bool {
        for event in events {
            if connection.isCancelled { return false }
            let reply: Data?
            switch event {
            case .tooLong:
                reply = JSONRPCOutbound.error(id: nil, .invalidRequest(MCPSocketServer.oversizeLineMessage))
            case .line(let line):
                reply = handle(line, session: session, connection: connection)
            }
            guard let reply else { continue }  // a notification
            var framed = reply
            framed.append(0x0A)
            guard UnixSocket.writeAll(connection.fd, framed) else { return false }
        }
        return true
    }

    /// Runs one line on the cooperative pool and blocks this (dedicated) thread until it is answered, so
    /// one connection never has two calls in flight and answers keep the request order. A peer that
    /// disconnects during a long call is only noticed once the call ends (or a stop cancels it).
    private func handle(_ line: Data, session: MCPSession, connection: Connection) -> Data? {
        let answer = OSAllocatedUnfairLock<Data?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)
        let call = Task.detached {
            let reply = await session.handle(line: line)
            answer.withLock { $0 = reply }
            done.signal()
        }
        if !connection.begin(call) { call.cancel() }
        done.wait()
        connection.end()
        return answer.withLock { $0 }
    }
}
