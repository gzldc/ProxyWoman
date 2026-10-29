import Atomics
import CertKit
import Darwin
import FlowStore
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import os
import RulesEngine

public enum ProxyServerError: Error, Equatable {
    /// Every port from `port` to `port + portFallbackCount` is already in use.
    case portUnavailable
}

/// Internal observation boundary after each real cleanup operation; never replaces that operation.
enum ProxyCleanupStage: Int, Sendable { case listenerClosed, transportsDrained, lookupsStopped, eventLoopsStopped }
typealias ProxyCleanupProbe = @Sendable (ProxyCleanupStage, EventLoop) async throws -> Void

/// Everything a client connection needs, captured when it is accepted, so configuration
/// changes only affect new connections.
struct ProxyEnvironment: Sendable {
    /// Except `recordingEnabled`, which `recording` reads live.
    var configuration: ProxyConfiguration
    var recording: FlowRecording
    /// Interception certificates (from the server's CA) and upstream TLS contexts.
    var tls: TLSInterception
    var passthrough: PassthroughRegistry
    /// Shared by all connections of one server; scans run off the event loops.
    var clientLookup: ClientLookupBatcher
    var runConnections: ProxyRunConnections? = nil
    var webSockets: WebSocketCaptureCoordinator? = nil
    /// Published rules, read live when each exchange begins (nil: rules disabled).
    var rules: RuleSnapshotProvider? = nil
    var assets: ManagedAssetStore? = nil
    /// Map Local directory reads (the asset store's resolver); nil fails a directory rule as unsupported.
    var directories: MappedDirectoryResolver? = nil
    var breakpoints: BreakpointCoordinator? = nil
    var localResponseHooks: LocalResponseSource.Hooks? = nil
    /// Test seam for the rule delay timer (D16): returning true means the test owns the timer and fires the
    /// callback itself. Nil in production, where the exchange schedules on its own event loop.
    var ruleDelayHook: RuleDelayHook? = nil
    /// The run's bounded pool for exact body file I/O; never an event loop.
    var fileIOPool: NIOThreadPool? = nil
    var bodyRuntime: BreakpointBodyRuntime? = nil
    /// This server's own listener endpoints, which a remapped request must never reach.
    var listeners: ProxyListenerEndpoints? = nil
    /// Allow/Block lists and the other traffic tools, read live when each exchange begins (nil:
    /// every tool is off and traffic is handled exactly as before).
    var traffic: TrafficPolicyProvider? = nil
}

/// Takes a rule delay over: the requested delay and the callback that resumes the exchange (callable from any thread).
typealias RuleDelayHook = @Sendable (TimeAmount, @escaping @Sendable () -> Void) -> Bool

/// Where new flows go. Read each time an exchange or tunnel would begin, so pausing or resuming
/// applies to open connections too; flows that already began are recorded to their end.
struct FlowRecording: Sendable {
    let store: FlowStore
    let isEnabled: ManagedAtomic<Bool>
    let webSocketController: WebSocketRecordingController
    init(store: FlowStore, isEnabled: ManagedAtomic<Bool>) {
        self.store = store; self.isEnabled = isEnabled
        self.webSocketController = WebSocketRecordingController(store: store)
        self.webSocketController.setEnabled(isEnabled.load(ordering: .relaxed), revision: 1)
    }

    /// The store to begin a new flow in, or nil while recording is paused.
    var activeStore: FlowStore? { isEnabled.load(ordering: .relaxed) ? store : nil }
}

/// The HTTP proxy listener on `listenHost`.
public final class ProxyServer: Sendable {
    private struct Running: Sendable {
        var group: MultiThreadedEventLoopGroup
        var threadPool: NIOThreadPool
        var fileIOPool: NIOThreadPool
        var directoryOwner: SpoolDirectoryOwner
        var channel: Channel
        var port: Int
        var connections: ProxyRunConnections
        var webSockets: WebSocketCaptureCoordinator
    }

    private enum Lifecycle: Sendable {
        case stopped
        case starting(UUID, Task<Running, Error>)
        case running(Running)
        case stopping(UUID, Task<Void, Error>)
    }

    private struct State: Sendable {
        var configuration: ProxyConfiguration
        var lifecycle: Lifecycle = .stopped
        var recordingRevision: UInt64 = 1
    }

    private let state: OSAllocatedUnfairLock<State>
    private let tls: TLSInterception
    private let recording: FlowRecording
    private let traffic = TrafficMeter()
    private let passthrough: PassthroughRegistry
    private let processLookup: ProcessLookup
    private let drainDeadline: ProxyDrainDeadline
    private let webSocketHooks: WebSocketObservationHooks
    private let cleanupProbe: ProxyCleanupProbe?
    private let rules: RuleSnapshotProvider?
    private let assets: ManagedAssetStore?
    private let breakpoints: BreakpointCoordinator?
    private let localResponseHooks: LocalResponseSource.Hooks?
    private let ruleDelayHook: RuleDelayHook?
    private let listeners = ProxyListenerEndpoints()
    private let trafficPolicy: TrafficPolicyProvider?
    private let bodyRuntime: BreakpointBodyRuntime
    /// Explicit Compose sends through this server's upstream path; available while it runs.
    public let compose: ComposeService

    public convenience init(
        configuration: ProxyConfiguration, certificateAuthority: CertificateAuthority,
        store: FlowStore, passthrough: PassthroughRegistry, processLookup: ProcessLookup = .live,
        rules: RuleSnapshotProvider? = nil, assets: ManagedAssetStore? = nil, breakpoints: BreakpointCoordinator? = nil,
        breakpointSpoolDirectory: URL? = nil, traffic: TrafficPolicyProvider? = nil
    ) {
        self.init(configuration: configuration, certificateAuthority: certificateAuthority, store: store,
                  passthrough: passthrough, processLookup: processLookup, drainDeadline: .standard, rules: rules, assets: assets, breakpoints: breakpoints,
                  breakpointSpoolDirectory: breakpointSpoolDirectory, traffic: traffic)
    }

    init(configuration: ProxyConfiguration, certificateAuthority: CertificateAuthority,
         store: FlowStore, passthrough: PassthroughRegistry, processLookup: ProcessLookup,
         drainDeadline: ProxyDrainDeadline, webSocketHooks: WebSocketObservationHooks = .init(),
         cleanupProbe: ProxyCleanupProbe? = nil, rules: RuleSnapshotProvider? = nil, assets: ManagedAssetStore? = nil, breakpoints: BreakpointCoordinator? = nil,
         localResponseHooks: LocalResponseSource.Hooks? = nil, bodyRuntime: BreakpointBodyRuntime? = nil,
         breakpointSpoolDirectory: URL? = nil, composeLimits: ComposeService.Limits? = nil,
         composeLifetimes: ComposeLifetimeProbe? = nil, traffic: TrafficPolicyProvider? = nil,
         ruleDelayHook: RuleDelayHook? = nil) {
        let limits = breakpoints?.limits ?? RulesLimits()
        self.compose = ComposeService(limits: composeLimits ?? ComposeService.Limits(limits), lifetimes: composeLifetimes)
        let spoolDirectory = breakpointSpoolDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyWoman-Breakpoints-" + UUID().uuidString)
        self.bodyRuntime = bodyRuntime ?? BreakpointBodyRuntime(directory: spoolDirectory,
            budgets: assets?.bodyBudgets ?? OwnedFileBudgets(limits: limits), limits: limits)
        self.cleanupProbe = cleanupProbe
        self.rules = rules
        self.assets = assets
        self.breakpoints = breakpoints
        self.localResponseHooks = localResponseHooks
        self.ruleDelayHook = ruleDelayHook
        self.trafficPolicy = traffic
        self.webSocketHooks = webSocketHooks
        self.drainDeadline = drainDeadline
        self.state = OSAllocatedUnfairLock(initialState: State(configuration: configuration))
        self.tls = TLSInterception(certificateAuthority: certificateAuthority)
        self.recording = FlowRecording(store: store, isEnabled: ManagedAtomic(configuration.recordingEnabled))
        self.passthrough = passthrough
        self.processLookup = processLookup
    }

    /// Binds a new run, waiting for any old run's actual cleanup before restarting.
    public func start() async throws {
        while true {
            let lifecycle = state.withLock { state in
                if case .stopped = state.lifecycle {
                    let id = UUID(), configuration = state.configuration
                    state.lifecycle = .starting(id, Task { try await self.makeRunning(configuration) })
                }
                return state.lifecycle
            }
            switch lifecycle {
            case .starting(let id, let task):
                do {
                    let running = try await task.value
                    state.withLock { state in
                        if case .starting(let current, _) = state.lifecycle, current == id { state.lifecycle = .running(running) }
                    }
                    return
                } catch {
                    state.withLock { state in
                        if case .starting(let current, _) = state.lifecycle, current == id { state.lifecycle = .stopped }
                    }
                    throw error
                }
            case .stopping(_, let cleanup): try await cleanup.value
            case .running: return
            case .stopped: continue
            }
        }
    }

    private func makeRunning(_ configuration: ProxyConfiguration) async throws -> Running {
        bodyRuntime.beginRun()
        breakpoints?.beginRun()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        let threadPool = NIOThreadPool(numberOfThreads: 2)
        threadPool.start()
        let fileIOPool = NIOThreadPool(numberOfThreads: 2)
        fileIOPool.start()
        let connections = ProxyRunConnections(loop: group.next(), deadline: drainDeadline)
        let webSockets = WebSocketCaptureCoordinator(store: recording.store, hooks: webSocketHooks, controller: recording.webSocketController)
        let bodyIO = bodyRuntime.makeIO(eventLoop: group.next(), pool: fileIOPool)
        var directoryOwner: SpoolDirectoryOwner?
        do {
            // Preparation, cross-process ownership and recovery all precede listener admission.
            let owner = try await bodyIO.prepareRun()
            directoryOwner = owner
            let clientLookup = ClientLookupBatcher(processLookup: processLookup, threadPool: threadPool)
            let channel = try await bind(configuration, group: group, clientLookup: clientLookup, connections: connections,
                                         webSockets: webSockets, fileIOPool: fileIOPool)
            // Nothing can fail after the bind: Compose may use this run's loops from now on.
            compose.beginRun(ComposeService.Runtime(loops: group, environment: { [self] in
                var environment = makeEnvironment(clientLookup: clientLookup, connections: connections, webSockets: webSockets,
                                                  fileIOPool: fileIOPool)
                // A Compose send owns its virtual client; it is not one of the run's client connections.
                environment.runConnections = nil
                return environment
            }))
            return Running(group: group, threadPool: threadPool, fileIOPool: fileIOPool, directoryOwner: owner, channel: channel,
                port: channel.localAddress?.port ?? configuration.port, connections: connections, webSockets: webSockets)
        } catch {
            connections.stopAdmission()
            webSockets.stopAdmission()
            // Design §11: revoke paused tickets before the bounded drain (they keep exchanges open).
            breakpoints?.shutdown()
            let loop = group.next()
            do { try await connections.drain().get(); try await cleanupProbe?(.transportsDrained, loop) } catch {}
            await webSockets.shutdown()
            await bodyRuntime.drain()
            if let owner = directoryOwner {
                _ = try? await bodyIO.run { owner.release() }.get()
            }
            try? await fileIOPool.shutdownGracefully()
            do { try await threadPool.shutdownGracefully(); try await cleanupProbe?(.lookupsStopped, loop) } catch {}
            do { try await group.shutdownGracefully(); try await cleanupProbe?(.eventLoopsStopped, loop) } catch {}
            throw error
        }
    }

    /// One run-owned cleanup task: all callers join it, even if a caller is cancelled.
    /// Stop admission first, let accepted exchanges deliver through grace, then cancel the rest.
    public func stop() async throws {
        while true {
            let lifecycle = state.withLock { state in
                if case .running(let running) = state.lifecycle {
                    let id = UUID()
                    running.connections.stopAdmission()
                    running.webSockets.stopAdmission()
                    compose.stopAdmission()
                    state.lifecycle = .stopping(id, Task {
                        var failure: Error?
                        // Design §11: admission stopped, now revoke every paused ticket (idempotent; new
                        // reservations fail as capacity) before the drain, which a paused exchange would
                        // otherwise hold until its deadline, and so a late Continue cannot forward.
                        self.breakpoints?.shutdown()
                        let loop = running.channel.eventLoop
                        do { try await running.channel.close().get(); try await self.cleanupProbe?(.listenerClosed, loop) } catch { failure = error }
                        self.listeners.removeAll()
                        do { try await running.connections.drain().get(); try await self.cleanupProbe?(.transportsDrained, loop) } catch { if failure == nil { failure = error } }
                        // C6: after the client connections drained, before WebSockets and the loops stop.
                        await self.compose.shutdown()
                        // Still stopped: a ticket reserved since the first call is ended here too.
                        self.breakpoints?.shutdown()
                        await running.webSockets.shutdown()
                        await self.bodyRuntime.drain()
                        // Pin drain includes source/import unlink settlement; only now can another
                        // process own/sweep this directory. Release on the same still-active pool.
                        do {
                            try await running.fileIOPool.runIfActive(eventLoop: loop) { running.directoryOwner.release() }.get()
                        } catch { if failure == nil { failure = error } }
                        // Exchanges are drained: settle their remaining file work before loops stop.
                        do { try await running.fileIOPool.shutdownGracefully() } catch { if failure == nil { failure = error } }
                        // Lookups complete back on live loops; always attempt every cleanup stage.
                        do { try await running.threadPool.shutdownGracefully(); try await self.cleanupProbe?(.lookupsStopped, loop) } catch { if failure == nil { failure = error } }
                        do { try await running.group.shutdownGracefully(); try await self.cleanupProbe?(.eventLoopsStopped, loop) } catch { if failure == nil { failure = error } }
                        self.state.withLock { state in
                            if case .stopping(let current, _) = state.lifecycle, current == id { state.lifecycle = .stopped }
                        }
                        if let failure { throw failure }
                    })
                }
                return state.lifecycle
            }
            switch lifecycle {
            case .stopping(_, let task): try await task.value; return
            case .starting: try await start()
            case .stopped: return
            case .running: continue
            }
        }
    }

    public var boundPort: Int? {
        state.withLock { state in
            guard case .running(let running) = state.lifecycle else { return nil }
            return running.port
        }
    }

    /// Only affects connections accepted afterwards; `recordingEnabled` affects every exchange
    /// or tunnel that begins afterwards.
    public func updateConfiguration(_ mutate: @Sendable (inout ProxyConfiguration) -> Void) {
        let update = state.withLock { state in
            let before = state.configuration.recordingEnabled
            mutate(&state.configuration)
            recording.isEnabled.store(state.configuration.recordingEnabled, ordering: .relaxed)
            if before != state.configuration.recordingEnabled && state.recordingRevision < .max { state.recordingRevision += 1 }
            return (state.configuration.recordingEnabled, state.recordingRevision)
        }
        recording.webSocketController.setEnabled(update.0, revision: update.1)
    }

    /// Bytes relayed since this server was created (not reset by `stop()`), recorded or not.
    public func trafficTotals() -> TrafficTotals {
        traffic.totals
    }

    private func bind(
        _ configuration: ProxyConfiguration, group: MultiThreadedEventLoopGroup, clientLookup: ClientLookupBatcher,
        connections: ProxyRunConnections, webSockets: WebSocketCaptureCoordinator, fileIOPool: NIOThreadPool
    ) async throws -> Channel {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .childChannelInitializer { [self] channel in
                guard connections.accept(channel) else { return channel.close() }
                let environment = makeEnvironment(clientLookup: clientLookup, connections: connections, webSockets: webSockets,
                                                  fileIOPool: fileIOPool)
                return channel.eventLoop.makeCompletedFuture {
                    var handlers: [ChannelHandler] = [TrafficCountingHandler(meter: traffic)]
                    // The upload gate; exchanges bind it to their target (ClientConnectionContext).
                    if let trafficPolicy { handlers.append(ConnectionPacer(direction: .upload, traffic: trafficPolicy)) }
                    handlers += [
                        HTTPMessageTranslation.responseEncoder(), HTTP1TransferCodingFramer<HTTPResponseHead>(),
                        ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)),
                        ProxyHandler(mode: .forwardProxy, environment: environment),
                    ]
                    try channel.pipeline.syncOperations.addHandlers(handlers)
                }
            }

        let lastPort = min(65535, configuration.port + max(0, configuration.portFallbackCount))
        for port in configuration.port...lastPort {
            do {
                let bindHost = configuration.acceptsLANConnections ? "0.0.0.0" : configuration.listenHost
                let channel = try await bootstrap.bind(host: bindHost, port: port).get()
                listeners.add(channel.localAddress)
                return channel
            } catch let error as IOError where error.errnoCode == EADDRINUSE {
                continue
            }
        }
        throw ProxyServerError.portUnavailable
    }

    private func makeEnvironment(
        clientLookup: ClientLookupBatcher, connections: ProxyRunConnections, webSockets: WebSocketCaptureCoordinator,
        fileIOPool: NIOThreadPool
    ) -> ProxyEnvironment {
        ProxyEnvironment(
            configuration: state.withLock { $0.configuration },
            recording: recording,
            tls: tls,
            passthrough: passthrough,
            clientLookup: clientLookup, runConnections: connections, webSockets: webSockets,
            rules: rules, assets: assets, directories: assets?.directoryResolver(), breakpoints: breakpoints,
            localResponseHooks: localResponseHooks, ruleDelayHook: ruleDelayHook, fileIOPool: fileIOPool, bodyRuntime: bodyRuntime, listeners: listeners,
            traffic: trafficPolicy)
    }
}
