import AppCore
import FlowStore
import Foundation
import MCPKit
import MCPWire
import RulesEngine
import Testing
import os
@testable import ProxyWoman

/// A short scratch directory under /tmp (`sockaddr_un.sun_path` holds 104 bytes).
final class Scratch: Sendable {
    let root: URL

    init() throws {
        root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("mcc-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        #expect(chmod(root.path, 0o700) == 0)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// The standard-layout directory (not created yet).
    var standard: URL { root.appendingPathComponent("MCP", isDirectory: true) }
    var other: URL { root.appendingPathComponent("other", isDirectory: true) }
}

@Suite(.productionChinese) struct FixedStatus: MCPStatusSource {
    func status() async -> MCPAppStatus {
        MCPAppStatus(recording: true, listeningPort: 9090, rulesCount: 0, enabledRulesCount: 0, globalRulesSwitchOn: true)
    }
}

final class RecordingSwitch: MCPRecordingControl {
    private let calls = OSAllocatedUnfairLock<[Bool]>(initialState: [])
    var requested: [Bool] { calls.withLock { $0 } }
    func setRecording(_ on: Bool) async -> Bool {
        calls.withLock { $0.append(on) }
        return on
    }
}

/// A controller over a real flow store and a real rules editor (a repository in the scratch directory), with
/// fake status and recording backends.
@MainActor final class Rig {
    let scratch: Scratch
    let editor: RulesEditorModel
    let recording = RecordingSwitch()
    let controller: MCPController

    init(
        directory: URL? = nil, createsDirectory: Bool = true, scratch: Scratch? = nil, store: FlowStore? = nil,
        beforeStart: (@MainActor (MCPSettings) -> Void)? = nil
    ) async throws {
        let scratch = try scratch ?? Scratch()
        self.scratch = scratch
        let limits = RulesLimits(minimumFreeDiskBytes: 0)
        let work = scratch.root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work.appendingPathComponent("config"), withIntermediateDirectories: true)
        let assets = ManagedAssetStore(
            directory: work.appendingPathComponent("assets"), limits: limits, budgets: OwnedFileBudgets(limits: limits))
        let repository = RuleRepository(directory: work.appendingPathComponent("config"), assets: assets, limits: limits)
        editor = RulesEditorModel(repository: repository, assets: assets, limits: limits)
        await editor.load()
        controller = MCPController(
            directory: directory ?? scratch.standard, createsDirectory: createsDirectory,
            app: MCPAppInfo(name: "ProxyWoman", version: "9.9"),
            store: store ?? FlowStore(bodyDirectory: work.appendingPathComponent("bodies")),
            rules: MCPRulesAdapter(editor: editor, globalSwitchOn: { true }),
            recording: recording, statusSource: FixedStatus(), beforeStart: beforeStart)
    }

    var directory: URL { scratch.standard }

    /// Stops the server and waits until its threads are gone.
    func finish() async {
        controller.shutdown()
        await controller.waitUntilStopped()
    }
}

func enabled(writeTools: Set<MCPWriteTool> = [], allowEnablingRules: Bool = false) -> MCPSettings {
    var settings = MCPSettings()
    settings.enabled = true
    settings.writeTools = writeTools
    settings.allowEnablingRules = allowEnablingRules
    return settings
}

func mode(_ path: String) -> mode_t? {
    var info = stat()
    return lstat(path, &info) == 0 ? info.st_mode & 0o7777 : nil
}

func exists(_ url: URL) -> Bool { lstatExists(url.path) }
func lstatExists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
}

/// The token a client reads from the handshake file.
func handshake(in directory: URL) throws -> MCPHandshake {
    try HandshakeFile.read(at: MCPPaths.handshakeURL(in: directory))
}

/// A blocking POSIX client whose reads run on a queue, so a test awaiting a reply never holds the main actor
/// (the tools hop to it). Every wait is a `poll` with a timeout.
final class Probe: Sendable {
    private let fd: Int32
    private let queue = DispatchQueue(label: "mcp-controller-test-probe")
    private let pending = OSAllocatedUnfairLock(initialState: Data())

    init(path: String) throws { fd = try UnixSocket.connect(path: path) }
    deinit { close(fd) }

    func send(_ text: String) { _ = UnixSocket.writeAll(fd, Data((text + "\n").utf8)) }

    func hello(token: String) async -> String? {
        var line = MCPHello(token: token, client: "controller-tests", protocolVersion: 1).line()
        line.append(0x0A)
        _ = UnixSocket.writeAll(fd, line)
        return await readLine()
    }

    enum Read: Equatable {
        case line(String)
        /// The server closed the connection (end of stream or reset).
        case eof
        /// Nothing arrived within the timeout and the connection is still open.
        case timeout
    }

    /// nil for both EOF and timeout; use `read` when the difference matters.
    func readLine(timeout: Duration = .seconds(10)) async -> String? {
        if case .line(let line) = await read(timeout: timeout) { return line }
        return nil
    }

    func read(timeout: Duration = .seconds(10)) async -> Read {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.blockingRead(timeout: timeout)) }
        }
    }

    private func blockingRead(timeout: Duration) -> Read {
        let deadline = ContinuousClock.now + timeout
        while true {
            let line = pending.withLock { data -> String? in
                guard let newline = data.firstIndex(of: 0x0A) else { return nil }
                let line = String(decoding: data[data.startIndex..<newline], as: UTF8.self)
                data = Data(data[data.index(after: newline)...])
                return line
            }
            if let line { return .line(line) }
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { return .timeout }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(clamping: Int((remaining / .milliseconds(1)).rounded(.up))))
            if ready < 0 { if errno == EINTR { continue }; return .eof }
            if ready == 0 { continue }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 { if errno == EINTR || errno == EAGAIN { continue }; return .eof }  // a reset counts as closed
            if count == 0 { return .eof }
            let chunk = Data(buffer[0..<count])
            pending.withLock { $0.append(chunk) }
        }
    }
}

let createRuleCall = """
    {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_rule","arguments":\
    {"name":"Local API","match":{"scheme":"https","host":"api.test"},\
    "action":{"type":"map_remote","target_scheme":"http","target_host":"localhost","target_port":3000}}}}
    """

/// The `tools/call` result a line carries: `isError` and the decoded JSON text of its first content item.
func decodeToolResult(_ line: String?) throws -> (isError: Bool, body: JSONValue) {
    let reply = try JSONValue.parse(Data(try #require(line, "no reply line").utf8))
    let result = try #require(reply["result"], "\(reply)")
    let text = try #require(result["content"]?.arrayValue?.first?["text"]?.stringValue)
    return (result["isError"]?.boolValue ?? false, try JSONValue.parse(Data(text.utf8)))
}

/// Blocks the calling thread, which is the point where a test wants the main actor unavailable.
private func blockUntilSignalled(_ semaphore: DispatchSemaphore, seconds: Double) -> Bool {
    semaphore.wait(timeout: .now() + seconds) == .success
}

@MainActor @Suite(.productionChinese, .serialized, .timeLimit(.minutes(1))) struct MCPControllerTests {
    @Test func constructingControllerCreatesNothing() async throws {
        let rig = try await Rig()
        #expect(!exists(rig.directory), "the MCP directory exists after construction")
        #expect(rig.controller.status == .off)
        // Switching MCP off, or shutting down, when it never ran creates nothing either.
        rig.controller.apply(MCPSettings())
        rig.controller.shutdown()
        #expect(!exists(rig.directory))
        #expect(rig.controller.status == .off)
        let listing = try FileManager.default.contentsOfDirectory(atPath: rig.scratch.root.path).sorted()
        #expect(listing == ["work"], "\(listing)")
    }

    @Test func applyEnabledStartsAndDisabledRemovesFiles() async throws {
        let rig = try await Rig()
        rig.controller.apply(enabled())
        #expect(rig.controller.status == .listening)
        let socket = MCPPaths.socketURL(in: rig.directory).path
        let handshakeURL = MCPPaths.handshakeURL(in: rig.directory).path
        #expect(mode(rig.directory.path) == 0o700)
        #expect(mode(socket) == 0o600 && mode(handshakeURL) == 0o600)
        #expect(try handshake(in: rig.directory).socketPath == socket)
        #expect(rig.controller.handshakePath == nil, "the standard layout needs no --handshake")

        rig.controller.apply(MCPSettings())
        #expect(rig.controller.status == .off)
        #expect(!lstatExists(socket) && !lstatExists(handshakeURL))
        await rig.finish()
    }

    @Test func enablingAgainWhileRunningOnlyUpdatesThePolicy() async throws {
        let rig = try await Rig()
        rig.controller.apply(enabled())
        let first = try handshake(in: rig.directory)
        let wider = enabled(writeTools: [.createRule, .setRecording], allowEnablingRules: true)
        rig.controller.apply(wider)
        #expect(rig.controller.status == .listening)
        #expect(rig.controller.policy.current == wider)
        let second = try handshake(in: rig.directory)
        #expect(second.token == first.token && second.startedAt == first.startedAt, "the server was not restarted")

        // Off and on again is a new start with a new token.
        rig.controller.apply(MCPSettings())
        rig.controller.apply(enabled())
        #expect(rig.controller.status == .listening)
        #expect(try handshake(in: rig.directory).token != first.token)
        #expect(rig.controller.policy.current == enabled())
        await rig.finish()
    }

    @Test func applyUpdatesPolicyBeforeStarting() async throws {
        // The start hook runs right before the server binds and sees the policy the server is about to
        // serve. Were the policy updated after the start, a first call over a new connection could be judged
        // by the old settings, and this hook would see them.
        struct Seen: Equatable {
            /// The policy snapshot the controller handed the hook (it reads it from the provider).
            var policy: MCPSettings
            var handshakeExisted: Bool
        }
        let scratch = try Scratch()
        let seen = OSAllocatedUnfairLock<[Seen]>(initialState: [])
        let rig = try await Rig(scratch: scratch) { policy in
            seen.withLock {
                $0.append(
                    Seen(
                        policy: policy,
                        handshakeExisted: lstatExists(MCPPaths.handshakeURL(in: scratch.standard).path)))
            }
        }

        let settings = enabled(writeTools: [.createRule])
        #expect(rig.controller.policy.current == MCPSettings())
        rig.controller.apply(settings)
        #expect(rig.controller.status == .listening)
        #expect(seen.withLock { $0 } == [Seen(policy: settings, handshakeExisted: false)])
        #expect(lstatExists(MCPPaths.handshakeURL(in: rig.directory).path), "bound only after the hook")

        // Updating a running server restarts nothing: no second start.
        let wider = enabled(writeTools: [.createRule, .setRecording])
        rig.controller.apply(wider)
        #expect(seen.withLock { $0.count } == 1)
        #expect(rig.controller.policy.current == wider)

        // A disabled apply still records the settings (the user's choices outlive the switch) and starts nothing.
        var off = wider
        off.enabled = false
        rig.controller.apply(off)
        #expect(rig.controller.status == .off)
        #expect(rig.controller.policy.current == off)
        #expect(seen.withLock { $0.count } == 1)
        await rig.finish()
    }

    @Test func aFailedStartStillLeavesTheNewPolicyInForce() async throws {
        // A start that fails before binding anything (the path is too long) still leaves the new snapshot in
        // force, and the hook saw it first.
        let long = String(repeating: "d", count: 90)
        let scratch = try Scratch()
        let hooked = OSAllocatedUnfairLock<[MCPSettings]>(initialState: [])
        let rig = try await Rig(
            directory: scratch.root.appendingPathComponent(long, isDirectory: true), scratch: scratch
        ) { argument in hooked.withLock { $0.append(argument) } }
        let settings = enabled(writeTools: [.createRule])
        rig.controller.apply(settings)
        #expect(rig.controller.status == .failed(.pathTooLong))
        #expect(rig.controller.policy.current == settings)
        #expect(hooked.withLock { $0 } == [settings])
        await rig.finish()
    }

    @Test func isolatedDirectoryHoldsSocketAndHandshake() async throws {
        let scratch = try Scratch()
        // An isolated root exists already and is only verified, never created or changed.
        let rig = try await Rig(directory: scratch.root, createsDirectory: false, scratch: scratch)
        rig.controller.apply(enabled())
        #expect(rig.controller.status == .listening)
        let socket = MCPPaths.socketURL(in: scratch.root).path
        let handshakeURL = MCPPaths.handshakeURL(in: scratch.root)
        #expect(mode(socket) == 0o600 && mode(handshakeURL.path) == 0o600)
        #expect(rig.controller.handshakePath == handshakeURL.path)
        #expect(!exists(rig.directory), "nothing is created beside the root")
        #expect(try handshake(in: scratch.root).socketPath == socket)
        await rig.finish()
        #expect(!lstatExists(socket) && !lstatExists(handshakeURL.path))
    }

    @Test func aMissingIsolatedRootIsUnsafeAndAFixedOneStartsOnTheNextApply() async throws {
        let scratch = try Scratch()
        let rig = try await Rig(directory: scratch.other, createsDirectory: false, scratch: scratch)
        rig.controller.apply(enabled())
        #expect(rig.controller.status == .failed(.directoryUnsafe))
        #expect(!exists(scratch.other), "an isolated root is never created")
        try FileManager.default.createDirectory(
            at: scratch.other, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        #expect(chmod(scratch.other.path, 0o700) == 0)
        rig.controller.apply(enabled())
        #expect(rig.controller.status == .listening)
        await rig.finish()
    }

    @Test func overlongDirectoryReportsFailedPathTooLong() async throws {
        let scratch = try Scratch()
        let long = scratch.root.appendingPathComponent(String(repeating: "x", count: 100), isDirectory: true)
        #expect(!MCPPaths.fitsSocketPath(MCPPaths.socketURL(in: long)))
        let rig = try await Rig(directory: long, scratch: scratch)
        rig.controller.apply(enabled())
        #expect(rig.controller.status == .failed(.pathTooLong))
        #expect(!exists(long), "nothing is created and nothing falls back to another place")
        #expect(MCPPresentation.failureText(.pathTooLong, appName: "ProxyWoman").contains("隔离目录路径太长"))
        await rig.finish()
    }

    @Test func shutdownRemovesFiles() async throws {
        let rig = try await Rig()
        rig.controller.apply(enabled())
        let socket = MCPPaths.socketURL(in: rig.directory).path
        let handshakeURL = MCPPaths.handshakeURL(in: rig.directory).path
        #expect(lstatExists(socket) && lstatExists(handshakeURL))
        rig.controller.shutdown()
        #expect(rig.controller.status == .off)
        #expect(!lstatExists(socket) && !lstatExists(handshakeURL))
        // Idempotent, and a later apply starts it again.
        rig.controller.shutdown()
        rig.controller.apply(enabled())
        #expect(rig.controller.status == .listening)
        await rig.finish()
        #expect(!lstatExists(socket))
    }

    @Test func helperPathIsBesideTheRunningExecutable() async throws {
        let scratch = try Scratch()
        let limits = RulesLimits(minimumFreeDiskBytes: 0)
        let assets = ManagedAssetStore(
            directory: scratch.root.appendingPathComponent("a"), limits: limits, budgets: OwnedFileBudgets(limits: limits))
        let repository = RuleRepository(directory: scratch.root.appendingPathComponent("r"), assets: assets, limits: limits)
        let editor = RulesEditorModel(repository: repository, assets: assets, limits: limits)
        let controller = MCPController(
            directory: scratch.standard, createsDirectory: true, app: MCPAppInfo(name: "ProxyWoman", version: "1"),
            store: FlowStore(bodyDirectory: scratch.root.appendingPathComponent("b")),
            rules: MCPRulesAdapter(editor: editor, globalSwitchOn: { true }), recording: RecordingSwitch(),
            statusSource: FixedStatus(), executableURL: URL(fileURLWithPath: "/Applications/ProxyWoman.app/Contents/MacOS/ProxyWoman"))
        #expect(controller.helperPath == "/Applications/ProxyWoman.app/Contents/MacOS/proxywoman-mcp")
        #expect(controller.handshakePath == nil)
        #expect(!exists(scratch.standard))
    }

    @Test func writeToolStaysDeniedUntilSettingsChange() async throws {
        let rig = try await Rig()
        rig.controller.apply(enabled())
        let shake = try handshake(in: rig.directory)
        let probe = try Probe(path: shake.socketPath)
        #expect(await probe.hello(token: shake.token) == #"{"ok":true}"#)

        // The master switch is on but create_rule was not allowed: refused, nothing saved.
        probe.send(createRuleCall)
        let denied = try decodeToolResult(await probe.readLine())
        #expect(denied.isError)
        #expect(denied.body["error"]?["code"]?.stringValue == "permission_denied")
        #expect(rig.editor.rules.isEmpty)

        // Turning the permission on takes effect for the very next call over the same connection.
        rig.controller.apply(enabled(writeTools: [.createRule]))
        probe.send(createRuleCall)
        let saved = try decodeToolResult(await probe.readLine())
        #expect(!saved.isError, "\(saved.body)")
        let rule = try #require(rig.editor.rules.first, "the rule window's model holds the new rule")
        #expect(rig.editor.rules.count == 1)
        #expect(rule.name == "Local API")
        #expect(!rule.enabled, "a rule the AI creates is saved turned off")

        // Taking it away again closes the door again.
        rig.controller.apply(enabled())
        probe.send(createRuleCall)
        #expect(try decodeToolResult(await probe.readLine()).isError)
        #expect(rig.editor.rules.count == 1)

        let outcomes = rig.controller.audit.snapshot().map(\.outcome)
        #expect(outcomes == [.denied(.permission(tool: "create_rule")), .ok, .denied(.permission(tool: "create_rule"))])
        await rig.finish()
    }

    @Test func switchingMCPOffDisconnectsClients() async throws {
        let rig = try await Rig()
        rig.controller.apply(enabled())
        let shake = try handshake(in: rig.directory)
        let probe = try Probe(path: shake.socketPath)
        #expect(await probe.hello(token: shake.token) == #"{"ok":true}"#)
        rig.controller.apply(MCPSettings())
        // The server closes the connection: the probe reads end of stream, not a timeout.
        #expect(await probe.read(timeout: .seconds(5)) == .eof)
        // And a request sent afterwards is never answered; the stream stays at its end.
        probe.send(#"{"jsonrpc":"2.0","id":7,"method":"ping"}"#)
        #expect(await probe.read(timeout: .seconds(5)) == .eof)
        await rig.finish()
    }

    @Test func aClientThatStaysQuietIsNotMistakenForAClosedOne() async throws {
        // Guards the probe itself: a live connection with nothing to say reads as a timeout, not as EOF.
        let rig = try await Rig()
        rig.controller.apply(enabled())
        let shake = try handshake(in: rig.directory)
        let probe = try Probe(path: shake.socketPath)
        #expect(await probe.hello(token: shake.token) == #"{"ok":true}"#)
        #expect(await probe.read(timeout: .milliseconds(200)) == .timeout)
        await rig.finish()
    }

    @Test func terminationBeginsStopWithoutTheMainActor() async throws {
        let rig = try await Rig()
        rig.controller.apply(enabled())
        let shake = try handshake(in: rig.directory)
        let socket = MCPPaths.socketURL(in: rig.directory).path
        let probe = try Probe(path: shake.socketPath)
        #expect(await probe.hello(token: shake.token) == #"{"ok":true}"#)

        // What the signal handler does, on another thread, while this (the main actor) is blocked: it must
        // not need the main actor, and it must not wait for any thread.
        let done = DispatchSemaphore(value: 0)
        let controller = rig.controller
        DispatchQueue.global().async {
            controller.beginStopForTermination()
            done.signal()
        }
        #expect(blockUntilSignalled(done, seconds: 10), "beginStopForTermination did not return")
        #expect(!lstatExists(socket) && !lstatExists(MCPPaths.handshakeURL(in: rig.directory).path))
        #expect(await probe.read(timeout: .seconds(5)) == .eof)
        // Cutting off twice, or cutting off a server that never started, is harmless.
        controller.beginStopForTermination()
        let idle = try await Rig()
        idle.controller.beginStopForTermination()
        await rig.finish()
        await idle.finish()
    }

    @Test func terminationSignalRestoresTheProxyFirstThenStopsMCPThenExits() {
        let order = OSAllocatedUnfairLock<[String]>(initialState: [])
        AppModel.runTerminationSequence(
            stopMCP: { order.withLock { $0.append("mcp") } },
            restoreSystemProxy: { order.withLock { $0.append("proxy") } },
            exit: { order.withLock { $0.append("exit") } })
        #expect(order.withLock { $0 } == ["proxy", "mcp", "exit"])
    }

    @Test func normalQuitRestoresTheProxyFirstThenStopsMCPThenTheRest() {
        let order = OSAllocatedUnfairLock<[String]>(initialState: [])
        func step(_ name: String) -> () -> Void { { order.withLock { $0.append(name) } } }
        AppModel.runShutdownSequence(
            restoreSystemProxy: step("proxy"), stopMCP: step("mcp"), stopWebSockets: step("websockets"),
            stopServer: step("server"))
        #expect(order.withLock { $0 } == ["proxy", "mcp", "websockets", "server"])
    }

    @Test func extraNamesFieldIsSplitAtBothCommasAndNormalized() {
        #expect(MCPPane.extraNames(from: "X-Session-Id, Foo，  bar ,,FOO") == ["x-session-id", "foo", "bar"])
        #expect(MCPPane.extraNames(from: "").isEmpty)
        #expect(MCPPane.extraNames(from: " , ，").isEmpty)
    }

    @Test func recordingToolReachesTheRecordingBridge() async throws {
        let rig = try await Rig()
        rig.controller.apply(enabled(writeTools: [.setRecording]))
        let shake = try handshake(in: rig.directory)
        let probe = try Probe(path: shake.socketPath)
        #expect(await probe.hello(token: shake.token) == #"{"ok":true}"#)
        probe.send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"set_recording","arguments":{"enabled":false}}}"#)
        let result = try decodeToolResult(await probe.readLine())
        #expect(!result.isError, "\(result.body)")
        #expect(rig.recording.requested == [false])
        await rig.finish()
    }
}
