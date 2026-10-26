import AppCore
import FlowStore
import Foundation
import MCPKit
import MCPWire
import Observation

/// Owns the MCP server of the app and starts or stops it from the settings (spec D2–D4, D18, S2, S8).
///
/// Constructing a controller builds the in-memory parts only (tool list, policy, audit log, activity model, the
/// not yet started server). It creates no directory, file, socket or thread; those appear when `apply` is
/// given settings that turn MCP on, and disappear again when they turn it off or at `shutdown`.
///
/// Stopping never blocks the main actor: `beginStop()` removes the socket and handshake files and cancels
/// the calls in flight at once, and the threads are joined on a background queue.
@MainActor @Observable final class MCPController {
    enum Status: Equatable {
        case off
        case listening
        case failed(MCPSocketServer.StartFailure)
        /// The server threw something that is not a `StartFailure`, so there is nothing more to say than that
        /// this build cannot run it. A helper missing from the bundle is not this: the server does not need the
        /// helper, and the settings page still shows the snippets.
        case unavailableInThisBuild
    }

    private(set) var status: Status = .off
    let audit: MCPAuditLog
    let policy: MCPPolicyProvider
    let activity: MCPActivityModel
    /// Where the AI clients find the bundled helper (the folder of the running executable).
    let helperPath: String
    /// The handshake file the helper must be told about (`--handshake`): nil in the standard layout, where
    /// the helper looks in the default place; the file in the isolated root otherwise.
    let handshakePath: String?

    @ObservationIgnored private let server: MCPSocketServer
    /// Test seam: runs on the main actor right before each start, with the policy snapshot the server is about
    /// to serve. Nothing is bound yet when it runs.
    @ObservationIgnored private let beforeStart: (@MainActor (MCPSettings) -> Void)?
    /// True from a successful start until the stop that follows has handed its threads to the background join.
    @ObservationIgnored private var hasStarted = false

    init(
        directory: URL, createsDirectory: Bool, app: MCPAppInfo, store: FlowStore, rules: MCPRulesAdapter,
        recording: any MCPRecordingControl, statusSource: any MCPStatusSource,
        executableURL: URL? = Bundle.main.executableURL, beforeStart: (@MainActor (MCPSettings) -> Void)? = nil
    ) {
        self.beforeStart = beforeStart
        let audit = MCPAuditLog()
        let policy = MCPPolicyProvider()
        self.audit = audit
        self.policy = policy
        activity = MCPActivityModel(log: audit)
        helperPath = MCPConfigSnippets.helperURL(executableURL: executableURL).path
        handshakePath = createsDirectory ? nil : MCPPaths.handshakeURL(in: directory).path

        let runner = MCPToolRunner(
            tools: MCPToolSet.make(app: app, store: store, status: statusSource, rules: rules, recording: recording),
            policy: policy, audit: audit)
        // Captures the runner, never the server: the server owns the closure.
        server = MCPSocketServer(
            configuration: MCPSocketServer.Configuration(directory: directory, createsDirectory: createsDirectory),
            makeSession: { MCPSession(runner: runner, app: app) })
    }

    /// Takes the new settings for every later call, then starts or stops the server to match. Switching on
    /// while the server already runs only updates the policy.
    func apply(_ settings: MCPSettings) {
        // First, so the very first call over a new connection already sees these settings.
        policy.update(settings)
        guard settings.enabled else {
            stopServer()
            status = .off
            return
        }
        if server.isRunning {
            status = .listening
            return
        }
        beforeStart?(policy.current)
        do {
            try server.start()
            hasStarted = true
            status = .listening
        } catch let failure as MCPSocketServer.StartFailure {
            status = .failed(failure)
        } catch {
            status = .unavailableInThisBuild
        }
    }

    /// App termination: connections are cut and the files removed before this returns.
    func shutdown() {
        stopServer()
        status = .off
    }

    /// For termination by signal, from any thread: cuts every connection and removes the socket and handshake
    /// files without waiting for anything (spec S8), so the process can exit at once. It does not touch
    /// `status`; the process is going away. A server that never started has nothing to stop.
    nonisolated func beginStopForTermination() {
        server.beginStop()
    }

    /// Waits (off the main thread) until the threads of every server stopped so far are gone. Test seam.
    func waitUntilStopped() async {
        let server = self.server
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                server.waitUntilStopped()
                continuation.resume()
            }
        }
    }

    private func stopServer() {
        guard hasStarted else { return }
        hasStarted = false
        server.beginStop()
        let server = self.server
        // Joining may wait for a tool that needs the main actor, so it never happens here.
        DispatchQueue.global(qos: .utility).async { server.waitUntilStopped() }
    }
}

/// What the MCP tools ask of the rest of the app: live status facts and the recording switch. Holds the
/// model weakly (the model owns the controller that owns this).
@MainActor final class MCPAppBridge: MCPStatusSource, MCPRecordingControl {
    private let editor: RulesEditorModel
    private let rulesSwitch: GlobalRulesSwitch
    weak var model: AppModel?

    init(editor: RulesEditorModel, rulesSwitch: GlobalRulesSwitch) {
        self.editor = editor
        self.rulesSwitch = rulesSwitch
    }

    func status() async -> MCPAppStatus {
        // The rules are read from the file once; until then the list would look empty.
        await editor.loadIfNeeded()
        let rules = editor.rules
        return MCPAppStatus(
            recording: model?.isRecording ?? false, listeningPort: model?.listeningPort, rulesCount: rules.count,
            enabledRulesCount: rules.filter(\.enabled).count, globalRulesSwitchOn: rulesSwitch.isOn)
    }

    func setRecording(_ on: Bool) async -> Bool {
        guard let model else { return false }
        model.setRecording(on)
        return model.isRecording
    }
}
