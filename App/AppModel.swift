import AppCore
import AppKit
import CertKit
import FlowStore
import Foundation
import Localization
import MCPKit
import MCPWire
import Observation
import ProxyCore
import RulesEngine
import SystemProxy
import os

/// The repeat sheet being shown: one run over one captured request (`AppModel.beginRepeat`).
struct RepeatSheetRequest: Identifiable {
    let id = UUID()
    let model: RepeatRunModel
}

/// Owns the proxy engine and the system integration (system proxy, root certificate trust).
/// Everything that can block (networksetup, keychain trust) runs on dispatch queues, off the main
/// actor and off Swift's cooperative pool.
@MainActor @Observable final class AppModel {
    let webSocketHub: WebSocketInvalidationHub
    let store: FlowStore
    /// Manual marks and comments from the flow context menu.
    let flowAnnotations: FlowAnnotationCommands
    let rulesLimits: RulesLimits
    let ownedFileBudgets: OwnedFileBudgets
    let managedAssets: ManagedAssetStore
    /// The one rule repository; the proxy reads its published snapshot for every new exchange.
    let rulesRepository: RuleRepository
    /// Hit counts of the rules, read by the rules window's outline.
    let ruleHits: RuleHitsModel
    /// Shared by every Rules window for the whole app lifetime, so the rules file is read once.
    let rulesEditor: RulesEditorModel
    /// Pack read / export / write, and the one import flow shared by every Rules window.
    let rulePackClient: RulePackClient
    let rulePackImporter: RulePackImporter
    /// The rule editor window's one open document (its edits survive closing the window).
    let ruleEditorSession: RuleEditorSession
    /// Page and inspector layout of the main window; survives closing the window.
    let shell: MainShellModel
    /// Selection, delete confirmation and note editing of the rules tab; kept here so switching tabs loses nothing.
    let rulesTab = RulesTabState()
    /// Turns every rule on or off at once (toolbar, 工具 menu); saved in the settings.
    let rulesSwitch: GlobalRulesSwitch
    /// The paused breakpoint tickets, for the breakpoint window and the toolbar badge. The only
    /// subscriber of the coordinator's change feed.
    let breakpointQueue: BreakpointQueueModel
    /// The facade over the one coordinator the proxy server uses.
    let breakpointClient: ProxyBreakpointClient
    /// Every Compose window sends through this facade over the server's Compose service.
    let composeClient: ProxyComposeClient
    /// Compose windows copy chosen body files into the managed asset store through this.
    let composeFiles: ManagedComposeFiles
    /// The Compose page's tabs and parked drafts; kept here so closing the main window loses nothing.
    let composeWorkspace: ComposeWorkspaceModel
    /// Set by `beginRepeat`; the main window shows the repeat sheet for it until it is dismissed.
    var pendingRepeat: RepeatSheetRequest?
    /// The Allow/Block lists, No Caching and Network Conditions; edits reach the proxy through the
    /// provider it reads for every new exchange, and are saved in the settings.
    let trafficTools: TrafficToolsModel
    /// Which regular expressions a circuit breaker switched off; the rules and traffic windows
    /// mark the rules and entries that stopped matching.
    let patternHealth = PatternHealthMonitor()
    /// Runs the rules over captured flows (the Execute window); lives here so closing the window never stops a run.
    let executeRunner: ExecuteRunner
    /// The tab the traffic tools window shows; menus, badges and the flow menu set it first.
    let trafficToolsNavigation = TrafficToolsNavigation()
    /// The MCP server for AI clients. Created here, started only by `launch` when the settings turn it on,
    /// so with MCP off no file, socket or thread exists.
    let mcp: MCPController
    /// Breakpoint rules may be turned on: paused traffic can be continued or ended in the
    /// breakpoint window (T9b). Before it existed they were saved turned off.
    static let breakpointsAreLive = true
    let ca: CertificateAuthority
    let caStore: CAStore
    let passthrough: PassthroughRegistry
    let listenHost: String
    /// Set for an isolated test launch (`-ProxyWomanIsolatedRoot`, re-identified copy only): the
    /// app's own files are kept under this root and its settings in memory; the system proxy and
    /// certificate trust are never read or changed. Framework state stays in the copy's own
    /// preferences domain (see `IsolatedLaunch`).
    let isolatedRoot: URL?
    private(set) var listeningPort: Int?
    /// True until the first attempt to start the listener has finished (either way).
    private(set) var isStarting = true
    private(set) var isSystemProxyEnabled = false
    private(set) var isCATrusted = false
    /// Whether new exchanges are recorded; traffic is proxied either way.
    private(set) var isRecording: Bool
    /// The last port/listener error; the toolbar shows it while nothing listens. A successful
    /// restart clears it again.
    private(set) var portError: String?
    /// Shown as a banner by the UI.
    private(set) var lastError: String?
    /// An informational message (not an error), shown in its own dismissible banner.
    private(set) var lastNotice: String?
    var settings: AppSettings
    /// The user turned the system proxy on while the root certificate is not trusted: the main
    /// window asks first (see `requestSystemProxy`), since every decrypted HTTPS site would fail.
    var isConfirmingSystemProxy = false
    var settingsPage: SettingsPage = .general
    var certificateHighlightID: UUID?
    var showsAdvancedProxySettings = false
    private(set) var upstreamProxyDescription = L10n.string("appModel.upstreamUnread")

    /// The main window's one-time banner that points to the rules upgrade notice: while the notice is unread
    /// and the user has not closed the banner. Reading the notice in the Rules window ends it as well.
    var showsRulesUpgradeBanner: Bool {
        rulesEditor.hasUnreadUpgradeNotice && !settings.rulesUpgradeBannerDismissed
    }

    /// Runs right away, without a window: `rules` empty = every enabled rule. The rules tab passes `.filtered`
    /// (the sessions of the current tab), the flow context menu `.selected`.
    func executeNow(rules: Set<UUID>, selectedIDs: [Int], visibleIDs: [Int], scope: ExecuteFlowScope) {
        let started = executeRunner.runNow(
            ExecuteRequest(
                rules: rules.isEmpty ? .allEnabled : .items(rules), selectedIDs: selectedIDs, filteredIDs: visibleIDs),
            scope: scope)
        guard started == nil else { return }
        if let reason = ExecuteNotStartedReason.of(
            phase: executeRunner.phase, ruleCount: executeRunner.ruleCount, flowCount: executeRunner.flowCount(for: scope))
        {
            showNotice(reason.text())
        }
    }

    func dismissRulesUpgradeBanner() {
        settings.rulesUpgradeBannerDismissed = true
    }

    /// Pair with SwiftUI's openSettings() from a menu or banner.
    func prepareCertificateSettings() {
        showsAdvancedProxySettings = false
        settingsPage = .general
        certificateHighlightID = UUID()
    }

    func prepareAdvancedProxySettings() {
        settingsPage = .general
        showsAdvancedProxySettings = true
    }

    @ObservationIgnored private let server: ProxyServer
    /// nil in an isolated launch: no `networksetup` read or write ever happens.
    @ObservationIgnored private let systemProxy: SystemProxyCoordinator?
    /// nil in an isolated launch: no keychain or trust-settings access ever happens.
    @ObservationIgnored private let trust: TrustOperations?
    private var portFallbackCount: Int { isolatedRoot == nil && settings.preferences.autoSelectAvailablePort ? 9 : 0 }
    /// The configured port plus its fallbacks: before the listener is up a loopback endpoint on
    /// any of them may be us. Once listening, only the bound port counts (see `startServer`).
    @ObservationIgnored private var ownPorts: ClosedRange<Int>
    /// The stored CA could not be loaded and a throw-away one is used for this run; trusting it
    /// would be pointless because it is gone after a restart.
    @ObservationIgnored private let isCATemporary: Bool
    @ObservationIgnored private var signalSources: [DispatchSourceSignal] = []
    @ObservationIgnored private var hasLaunched = false
    @ObservationIgnored private var isSwitchingSystemProxy = false
    /// The latest state the user asked for while a switch may be running; the switch loop follows it.
    @ObservationIgnored private var desiredSystemProxy: Bool?
    /// The last queued server start/restart; each one waits for the previous to finish.
    @ObservationIgnored private var serverWork: Task<Void, Never>?

    init(runtime: AppRuntime) {
        let settings = AppSettings(defaults: runtime.settingsStorage)
        self.settings = settings
        isolatedRoot = runtime.isolated?.root
        trust = runtime.trust

        let layout = runtime.layout
        let bodies = layout.bodies
        let rulesLimits = RulesLimits()
        self.rulesLimits = rulesLimits
        let budgets = OwnedFileBudgets(limits: rulesLimits)
        ownedFileBudgets = budgets
        let managedAssets = ManagedAssetStore(
            directory: layout.ruleAssets, limits: rulesLimits, budgets: budgets)
        self.managedAssets = managedAssets
        // Loaded once (by `launch`) before the listener starts; until then rules are disabled.
        rulesRepository = RuleRepository(
            directory: layout.rules, assets: managedAssets, limits: rulesLimits)
        let hitCounter = rulesRepository.provider.hits
        ruleHits = RuleHitsModel(count: { hitCounter.count($0) }, reset: { hitCounter.reset($0) })
        rulesEditor = RulesEditorModel(
            repository: rulesRepository, assets: managedAssets, limits: rulesLimits, liveBreakpoints: Self.breakpointsAreLive,
            directoryBookmarking: .live)
        ruleEditorSession = RuleEditorSession(model: rulesEditor)
        shell = MainShellModel(inspector: settings.preferences.inspector) { settings.preferences.inspector = $0 }
        rulePackClient = .live(assets: managedAssets, limits: rulesLimits, appVersion: AppInfo.version)
        rulePackImporter = RulePackImporter(model: rulesEditor, client: rulePackClient)
        // Applied to the provider before the listener can admit any exchange.
        rulesSwitch = GlobalRulesSwitch(
            provider: rulesRepository.provider, initial: settings.preferences.rulesEnabled,
            persist: { settings.preferences.rulesEnabled = $0 })
        // One coordinator for the whole app: the server pauses into it, the window reads and commands it.
        let breakpoints = BreakpointCoordinator(limits: rulesLimits)
        breakpointClient = ProxyBreakpointClient(coordinator: breakpoints)
        breakpointQueue = BreakpointQueueModel(client: breakpointClient, limits: rulesLimits)
        let breakpointSpool = layout.breakpointSpool
        // Spilled bodies of a previous run are useless without its in-memory flows.
        try? FileManager.default.removeItem(at: bodies)
        store = FlowStore(bodyDirectory: bodies)
        flowAnnotations = FlowAnnotationCommands(store: store)
        webSocketHub = WebSocketInvalidationHub(store: store)
        // Only built here (no file, socket or thread); `launch` starts it when the settings say so. The tools
        // keep the bridge alive; it reaches the model weakly (set at the end of `init`).
        let mcpBridge = MCPAppBridge(editor: rulesEditor, rulesSwitch: rulesSwitch)
        let mcpSwitch = rulesSwitch
        mcp = MCPController(
            directory: runtime.isolated.map { MCPPaths.isolatedDirectory(root: $0.root) }
                ?? MCPPaths.standardDirectory(
                    applicationSupport: layout.applicationSupport.deletingLastPathComponent(), appName: AppInfo.name),
            createsDirectory: runtime.isolated == nil,
            app: MCPAppInfo(name: AppInfo.name, version: AppInfo.version), store: store,
            rules: MCPRulesAdapter(editor: rulesEditor, globalSwitchOn: { mcpSwitch.isOn }),
            recording: mcpBridge, statusSource: mcpBridge)

        let caStore = CAStore(directory: layout.certificateAuthority)
        self.caStore = caStore
        var startupError: String?
        do {
            ca = try CertificateAuthority.loadOrCreate(store: caStore)
            isCATemporary = false
        } catch {
            startupError = L10n.format("appModel.rootReadFailed", caStore.directory.path, String(describing: error))
            do {
                ca = try CertificateAuthority.generate()
            } catch {
                fatalError(L10n.format("appModel.temporaryRootFailed", String(describing: error)))
            }
            isCATemporary = true
        }

        passthrough = PassthroughRegistry(hosts: settings.passthroughHosts)

        var configuration = ProxyConfiguration()
        configuration.productName = AppInfo.name
        configuration.port = settings.port
        configuration.portFallbackCount = settings.preferences.autoSelectAvailablePort ? 9 : 0
        configuration.decryption = settings.decryption
        configuration.recordingEnabled = settings.preferences.autoStartRecordingAtLaunch
        if let isolated = runtime.isolated {
            // Loopback only, on the requested port (0: the system picks one), never a fallback range.
            configuration.listenHost = "127.0.0.1"
            configuration.port = isolated.port
            configuration.portFallbackCount = 0
        }
        isRecording = configuration.recordingEnabled
        listenHost = configuration.listenHost
        ownPorts = Self.ownPorts(from: configuration.port, fallbackCount: configuration.portFallbackCount)
        // Applied before the listener can admit any exchange; No Caching and the Network
        // Conditions switch start off whatever was saved.
        let trafficProvider = TrafficPolicyProvider()
        trafficTools = TrafficToolsModel(
            provider: trafficProvider, initial: settings.trafficPolicy,
            persist: { settings.trafficPolicy = $0 })
        let server = ProxyServer(
            configuration: configuration, certificateAuthority: ca, store: store, passthrough: passthrough,
            rules: rulesRepository.provider, assets: managedAssets, breakpoints: breakpoints,
            breakpointSpoolDirectory: breakpointSpool, traffic: trafficProvider)
        self.server = server
        composeClient = ProxyComposeClient(service: server.compose)
        composeFiles = ManagedComposeFiles(store: managedAssets)
        let workspaceClient = composeClient
        let workspaceFiles = composeFiles
        let bodyStore = store
        composeWorkspace = ComposeWorkspaceModel(make: { draft in
            ComposeViewModel(
                draft: draft, client: workspaceClient, files: workspaceFiles,
                acquireBody: { try bodyStore.acquireBody($0) })
        })
        // Every run gets its own pattern cache, so a pattern Execute switches off never switches off a live rule.
        let provider = rulesRepository.provider
        executeRunner = ExecuteRunner(
            store: store, snapshot: { provider.current() },
            environment: { [store, managedAssets, rulesLimits] in
                ExecuteEnvironment(
                    assets: managedAssets, limits: rulesLimits, cache: PatternCache(), makeBody: { store.makeManagedBody($0) })
            })
        systemProxy = runtime.systemProxyRunner.map {
            SystemProxyCoordinator(controller: SystemProxyController(runner: $0, backupURL: layout.proxyBackup))
        }
        lastError = startupError ?? runtime.isolated.map { L10n.format("isolatedMode.active", $0.root.path) }
        breakpointQueue.start()

        passthrough.onChange { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Read the registry itself: handlers may run out of order across threads.
                self.settings.passthroughHosts = self.passthrough.hosts
            }
        }
        mcpBridge.model = self
    }

    /// Crash recovery, trust state, upstream detection, then the listener. Runs once.
    func launch() async {
        guard !hasLaunched else { return }
        hasLaunched = true
        // Read and cleared first, so a one-shot mark never outlives this launch.
        let resumesSystemProxy = settings.takeResumeSystemProxyAfterRestart()
        // Isolated: nothing to restore, so no recovery and no process-wide signal handlers.
        if let systemProxy {
            signalSources = Self.makeSignalSources(systemProxy: systemProxy, mcp: mcp)
            do {
                try await systemProxy.run { try $0.recoverIfNeeded() }
            } catch {
                lastError = L10n.format("appModel.restoreFailed", Self.message(for: error))
            }
            isSystemProxyEnabled = systemProxy.isEnabledByUs
        }

        refreshTrust()

        // Exactly once, before the first listener: persisted asset references are adopted before
        // any import, and a failure keeps rules disabled with the error shown in the Rules window.
        await rulesEditor.load()

        await enqueueServerWork { model in
            await model.startServer(chainingThrough: await model.originalProxySettings())
        }
        isStarting = false
        // Through the usual request, which asks first while the root is not trusted.
        if Self.shouldEnableSystemProxyAtLaunch(
            autoOverride: settings.preferences.autoOverrideSystemProxyAtLaunch, resumeAfterRestart: resumesSystemProxy,
            isListening: listeningPort != nil, isEnabled: isSystemProxyEnabled)
        {
            requestSystemProxy(true)
        }

        // Then: the rules are loaded and the listener is up, so the first tool call sees a ready app. A
        // fresh install and an isolated launch have MCP off, so this creates nothing there.
        mcp.apply(settings.mcp)

        // Then the built-in templates, once per version (a deleted tree is not made again): one off-main save that never
        // delays the proxy, the listener, MCP or the system-proxy step. The rules are loaded by now, and a concurrent
        // write (the MCP tools, the editor) is retried on a conflict.
        await rulesEditor.installTemplatesIfNeeded()
    }

    /// The setting, or a restart that began with the system proxy on (which keeps the system proxy as it was).
    nonisolated static func shouldEnableSystemProxyAtLaunch(
        autoOverride: Bool, resumeAfterRestart: Bool, isListening: Bool, isEnabled: Bool
    ) -> Bool {
        (autoOverride || resumeAfterRestart) && isListening && !isEnabled
    }

    /// True from the moment a restart is under way until the quit it asked for begins: the quit confirmation is
    /// skipped (the user already chose to restart) while everything else of a normal quit, restoring the system
    /// proxy included, still runs. One-shot: the quit consumes it (`takeRestartForTermination`), and a quit that
    /// does not happen clears it again, so a later ⌘Q asks as usual and a later restart works.
    private(set) var isRestarting = false
    /// Calls off the arranged relaunch (see `AppRelauncher.launch`).
    private var cancelRelaunch: (() -> Void)?

    /// The termination delegate asks: true (once) when this quit is the one a restart asked for.
    func takeRestartForTermination() -> Bool {
        guard isRestarting else { return false }
        isRestarting = false
        cancelRelaunch = nil
        return true
    }

    /// Quits normally and starts a new instance once this one is gone. When the system proxy is on, a one-shot
    /// mark makes the new instance turn it on again after the normal quit restored it, so the system proxy
    /// ends up as it was. If the new instance cannot be arranged, nothing quits and the error is shown. `terminate`
    /// returns only when the quit did not happen (a quit that goes ahead ends the process); then the arrangement
    /// and the mark are undone.
    func restart(using relauncher: AppRelauncher, terminate: () -> Void) {
        guard !isRestarting else { return }
        settings.markResumeSystemProxyAfterRestart(isSystemProxyEnabled)
        do {
            cancelRelaunch = try relauncher.launch()
        } catch {
            settings.markResumeSystemProxyAfterRestart(false)
            let reason = (error as? AppRelauncher.Failure)?.reason ?? Self.message(for: error)
            lastError = L10n.format("appModel.restartFailed", reason)
            return
        }
        isRestarting = true
        terminate()
        abandonRestart()
    }

    /// The quit did not happen (it was not even asked to go ahead): forget the restart. After the quit was
    /// approved (`takeRestartForTermination`) there is nothing to undo.
    private func abandonRestart() {
        guard isRestarting else { return }
        let cancel = cancelRelaunch
        cancelRelaunch = nil
        isRestarting = false
        cancel?()
        settings.markResumeSystemProxyAfterRestart(false)
    }

    /// Pauses or resumes recording; open connections keep being proxied.
    func setRecording(_ on: Bool) {
        guard on != isRecording else { return }
        isRecording = on
        server.updateConfiguration { $0.recordingEnabled = on }
    }

    /// Bytes relayed since launch, for the status bar's throughput.
    func trafficTotals() -> TrafficTotals {
        server.trafficTotals()
    }

    /// Applies `preferences.theme` to the whole app now and again whenever the preferences change.
    func followThemePreference() {
        withObservationTracking {
            Self.applyTheme(settings.preferences.theme)
        } onChange: { [weak self] in
            Task { @MainActor in self?.followThemePreference() }
        }
    }

    private static func applyTheme(_ theme: ThemeMode) {
        let appearance: NSAppearance? =
            switch theme {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        if NSApp.appearance?.name != appearance?.name { NSApp.appearance = appearance }
    }

    /// Restarts the listener on `port` (falling back to the following ports while busy). If the
    /// system proxy is ours it is re-pointed at the new port, or restored when nothing listens.
    func setPort(_ port: Int) async {
        guard (1...65535).contains(port) else {
            reportPortError(L10n.string("appModel.invalidPort"))
            return
        }
        await enqueueServerWork { model in
            await model.restartServer(on: port)
        }
    }

    /// Replaces the whole decryption policy; applies to new connections.
    func setDecryptionPolicy(_ policy: DecryptionPolicy) {
        guard policy != settings.decryption else { return }
        settings.decryption = policy
        server.updateConfiguration { [policy] in $0.decryption = policy }
    }

    private func enqueueServerWork(_ work: @escaping @MainActor (AppModel) async -> Void) async {
        let previous = serverWork
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            await work(self)
        }
        serverWork = task
        await task.value
    }

    private func restartServer(on port: Int) async {
        let stalePortError = portError
        portError = nil
        settings.port = port
        ownPorts = Self.ownPorts(from: port, fallbackCount: portFallbackCount)
        let fallbackCount = portFallbackCount
        server.updateConfiguration {
            $0.port = port
            $0.portFallbackCount = fallbackCount
        }
        // Read before stopping, to keep the time nothing listens short.
        let original = await originalProxySettings()
        listeningPort = nil
        do {
            try await server.stop()
        } catch {
            reportPortError(L10n.format("appModel.stopFailed", Self.message(for: error)))
        }
        await startServer(chainingThrough: original)

        let host = listenHost
        let newPort = listeningPort
        let restored: Bool
        if let systemProxy {
            do {
                // On the serial queue, after any switch the user started earlier.
                restored = try await systemProxy.run { controller in
                    guard controller.isEnabledByUs else { return false }
                    if let newPort {
                        // With a backup present this only re-applies the set commands.
                        try controller.enable(host: host, port: newPort)
                        return false
                    }
                    // Never leave the system pointing at a port nothing listens on.
                    try controller.disable()
                    return true
                }
            } catch is SystemProxyCoordinator.Terminating {
                return
            } catch {
                reportPortError(L10n.format("appModel.updateProxyFailed", Self.message(for: error)))
                restored = false
            }
            isSystemProxyEnabled = systemProxy.isEnabledByUs
        } else {
            restored = false // isolated: the system proxy is never touched
        }

        if restored {
            if let reason = portError {
                reportPortError(L10n.format("appModel.errorAndProxyRestored", reason))
            } else {
                reportPortError(L10n.string("appModel.proxyRestored"))
            }
        } else if newPort != nil, portError == nil, let stalePortError, lastError == stalePortError {
            lastError = nil
        }
    }

    private func reportPortError(_ message: String) {
        portError = message
        lastError = message
    }

    /// The settings to chain through (see `SystemProxyController.originalSettings()`); nil if unreadable.
    /// Isolated: no system proxy is read, so there is nothing to chain through (direct).
    private func originalProxySettings() async -> [ServiceProxySnapshot]? {
        guard let systemProxy else { return [] }
        return try? await systemProxy.run { try $0.originalSettings() }
    }

    /// Chains through the proxy the system already uses (e.g. Clash), so `curl -x` works too.
    /// Until the listener is up, a loopback endpoint on any port of our range may be us; once it
    /// is, only the bound port is: the lower ports were busy because someone else holds them,
    /// possibly that very upstream.
    private func startServer(chainingThrough original: [ServiceProxySnapshot]?) async {
        setUpstream(from: original, ownPorts: ownPorts)
        do {
            try await server.start()
            listeningPort = server.boundPort
        } catch ProxyServerError.portUnavailable {
            reportPortError(
                L10n.format(
                    "appModel.portsOccupied", String(describing: ownPorts.lowerBound),
                    String(describing: ownPorts.upperBound)))
        } catch {
            reportPortError(L10n.format("appModel.startFailed", Self.message(for: error)))
        }
        if let port = listeningPort {
            setUpstream(from: original, ownPorts: port...port)
        }
    }

    private func setUpstream(from original: [ServiceProxySnapshot]?, ownPorts: ClosedRange<Int>) {
        let upstream = original.flatMap { Self.upstreamProxy(from: $0, ownPorts: ownPorts) }
        upstreamProxyDescription =
            upstream.map {
                L10n.format("appModel.followingUpstream", String(describing: $0.host), String(describing: $0.port))
            }
            ?? (original == nil ? L10n.string("appModel.upstreamUnknown") : L10n.string("appModel.direct"))
        server.updateConfiguration { $0.upstreamProxy = upstream }
    }

    enum SystemProxyConfirmation {
        case installCertificate, enableAnyway, cancel
    }

    /// What the system-proxy toggles call. Turning it on while HTTPS is decrypted with a root the
    /// system does not trust breaks every HTTPS site, so that asks for confirmation first.
    /// Returns true when a confirmation is now pending (shown by the main window).
    @discardableResult
    func requestSystemProxy(_ on: Bool) -> Bool {
        guard systemProxy != nil else {
            if on { lastError = L10n.string("isolatedMode.systemProxyUnavailable") }
            return false
        }
        if on, !isSystemProxyEnabled, settings.decryption.enabled {
            refreshTrust()
            if !isCATrusted {
                isConfirmingSystemProxy = true
                return true
            }
        }
        Task { await setSystemProxy(on) }
        return false
    }

    /// The user's answer to the confirmation `requestSystemProxy` asked for.
    func confirmSystemProxy(_ choice: SystemProxyConfirmation) {
        isConfirmingSystemProxy = false
        switch choice {
        case .installCertificate: prepareCertificateSettings()
        case .enableAnyway: Task { await setSystemProxy(true) }
        case .cancel: break
        }
    }

    /// The latest request wins: toggling again while a switch runs is applied once it finishes.
    private func setSystemProxy(_ on: Bool) async {
        desiredSystemProxy = on
        guard !isSwitchingSystemProxy else { return }
        isSwitchingSystemProxy = true
        defer {
            isSwitchingSystemProxy = false
            desiredSystemProxy = nil
        }
        while let desired = desiredSystemProxy, desired != isSystemProxyEnabled {
            let succeeded = await applySystemProxy(desired)
            // A failure is not retried unless the user asked for something else meanwhile.
            if !succeeded, desiredSystemProxy == desired { break }
        }
    }

    private func applySystemProxy(_ on: Bool) async -> Bool {
        guard let systemProxy else { return false }
        var succeeded = false
        do {
            if on {
                guard let port = listeningPort else {
                    lastError = L10n.string("appModel.proxyNotRunning")
                    return false
                }
                let host = listenHost
                let server = self.server
                let upstream = try await systemProxy.run { controller in
                    // Only the bound port is ours (see `startServer`).
                    let upstream = Self.upstreamProxy(from: try controller.originalSettings(), ownPorts: port...port)
                    server.updateConfiguration { $0.upstreamProxy = upstream }
                    try controller.enable(host: host, port: port)
                    return upstream
                }
                upstreamProxyDescription =
                    upstream.map {
                        L10n.format(
                            "appModel.followingUpstream", String(describing: $0.host), String(describing: $0.port))
                    } ?? L10n.string("appModel.direct")
            } else {
                try await systemProxy.run { try $0.disable() }
            }
            succeeded = true
        } catch is SystemProxyCoordinator.Terminating {
            return false
        } catch {
            lastError = L10n.format(
                on ? "appModel.enableProxyFailed" : "appModel.disableProxyFailed", Self.message(for: error))
        }
        isSystemProxyEnabled = systemProxy.isEnabledByUs
        return succeeded
    }

    /// Cheap and silent. Handshake failures only feed the passthrough list once the root is
    /// trusted; before that every handshake fails and would poison it.
    func refreshTrust() {
        let trusted = trust?.isTrusted(ca) ?? false
        if isCATrusted != trusted { isCATrusted = trusted }
        server.updateConfiguration { $0.autoPassthroughOnHandshakeFailure = trusted }
    }

    /// Shows the system's password dialog.
    func installCertificate() async {
        guard let trust else {
            lastError = L10n.string("isolatedMode.trustUnavailable")
            return
        }
        guard !isCATemporary else {
            lastError = L10n.format("appModel.rootUnavailable", caStore.directory.path)
            return
        }
        let rootDER = ca.rootCertificateDER
        do {
            try await runBlocking(on: .global(qos: .userInitiated)) {
                try trust.install(rootDER)
            }
        } catch {
            lastError = L10n.format("appModel.installFailed", Self.message(for: error))
        }
        refreshTrust()
    }

    /// The caller must first confirm removal; macOS may ask for authorization.
    func removeCertificateTrust() async {
        guard let trust else {
            lastError = L10n.string("isolatedMode.trustUnavailable")
            return
        }
        let rootDER = ca.rootCertificateDER
        do {
            try await runBlocking(on: .global(qos: .userInitiated)) {
                try trust.remove(rootDER)
            }
        } catch {
            lastError = L10n.format("appModel.removeTrustFailed", Self.message(for: error))
        }
        refreshTrust()
    }

    /// Adds or removes exactly `host` in the decryption exclusions; applies to new connections.
    func setDecryption(excluded: Bool, for host: String) {
        var policy = settings.decryption
        let normalizedHost = HostPattern.normalize(host)
        policy.excludedHosts.removeAll { HostPattern.normalize($0) == normalizedHost }
        policy.disabledExcludedHosts.removeAll { HostPattern.normalize($0) == normalizedHost }
        if excluded { policy.excludedHosts.append(host) }
        setDecryptionPolicy(policy)
    }

    /// Opens the repeat sheet for a captured request. A flow Replay could not send (a tunnel, an
    /// Upgrade, a body that is not whole) never gets one; sending is up to the sheet's Start.
    func beginRepeat(flow: Flow) {
        guard ComposeEntry.replay(flow) == nil else { return }
        pendingRepeat = RepeatSheetRequest(model: RepeatRunModel(draft: ComposeDraft(from: flow), client: composeClient))
    }

    /// Whether "Repeat…" applies to `flow`: exactly what `beginRepeat` accepts. The flow table's
    /// context menu and the menu bar command share it, so both are enabled for the same flows.
    func canRepeat(flow: Flow?) -> Bool {
        flow.map { ComposeEntry.replay($0) == nil } ?? false
    }

    /// Whether "Save Response as Mock Rule…" applies to `flow`: its captured response can become a
    /// mock and the rules editor can take a new draft. The menu bar command and the flow table's
    /// context menu share it.
    func canSaveResponseAsMock(flow: Flow?) -> Bool {
        guard let flow, rulesEditor.canMutate else { return false }
        return responseMockBlockReason(flow: flow) == nil
    }

    /// Why the flow's captured response cannot become a mock (nil when it can); the context menu
    /// shows it as the disabled entry's tooltip.
    func responseMockBlockReason(flow: Flow) -> String? {
        if case .failure(let reason) = ResponseMockExtractor.extract(from: flow, limits: rulesEditor.limits) {
            return reason.localizedDescription
        }
        return nil
    }

    /// Starts a mock rule draft from the flow's captured response. A response that cannot be a mock
    /// shows its reason instead of opening the window. Otherwise `openRules` runs at once, so the
    /// copy progress and its cancel button are visible while a large body is copied; a failed copy
    /// shows the editor's own error banner there. The finished draft opens in the rule editor window
    /// (`openEditor`), which takes over the copied file.
    func saveResponseAsMock(
        flow: Flow, openRules: @escaping @MainActor () -> Void, openEditor: @escaping @MainActor () -> Void
    ) {
        Task { @MainActor in
            // The entry point was enabled earlier; the editor may have become busy since.
            guard rulesEditor.canMutate else { return }
            if case .failure(let reason) = ResponseMockExtractor.extract(from: flow, limits: rulesEditor.limits) {
                showError(reason.localizedDescription)
                return
            }
            openRules()
            let session = ruleEditorSession
            let reason = await rulesEditor.beginMockDraft(from: flow, acquireBody: acquireBody) { draft in
                session.openSeed(draft)
                openEditor()
            }
            if let reason {
                showError(reason.localizedDescription)
            }
        }
    }

    /// The draft of an Edit: the captured original request, or the one actually sent upstream.
    /// Nil when the flow cannot be edited that way (a tunnel, an Upgrade, or no separate upstream
    /// request); nothing is sent by building it.
    func composeDraft(flow: Flow, variant: ComposeRequestVariant) -> ComposeDraft? {
        guard ComposeEntry.edit(flow, variant: variant) == nil else { return nil }
        return ComposeDraft(from: flow, variant: variant)
    }

    /// Opens `draft` as a new Compose tab and shows the Compose page. A Replay sends its safe-method
    /// draft once; a large captured body is then copied into the tab's own asset with visible progress.
    @discardableResult func openCompose(_ draft: ComposeDraft, isReplay: Bool) -> ComposeViewModel {
        let model = composeWorkspace.open(draft)
        shell.page = .compose
        Task { @MainActor in
            if isReplay { await model.replayOnOpen() }
            await model.importCapturedBody()
        }
        return model
    }

    /// Opens a read lease on a captured body, for Compose to copy a large original body in chunks.
    var acquireBody: @Sendable (BodyRef) throws -> HTTPBodyReadLease {
        let store = self.store
        return { try store.acquireBody($0) }
    }

    func showError(_ message: String) {
        lastError = message
    }

    func dismissError() {
        lastError = nil
    }

    func showNotice(_ message: String) {
        lastNotice = message
    }

    func dismissNotice() {
        lastNotice = nil
    }

    /// Called when the app terminates: waits for an in-flight system-proxy switch, restores the
    /// system proxy if we changed it, stops the server.
    func shutdown() {
        Self.runShutdownSequence(
            restoreSystemProxy: { systemProxy?.restoreForTermination() },
            stopMCP: { mcp.shutdown() },
            stopWebSockets: { webSocketHub.stop() },
            stopServer: {
                let server = self.server
                let stopped = DispatchSemaphore(value: 0)
                Task.detached {
                    try? await server.stop()
                    stopped.signal()
                }
                _ = stopped.wait(timeout: .now() + 2)
            })
    }

    /// What a normal quit does, in this order: the system proxy is restored first (the safety-critical step;
    /// nothing may be queued ahead of it), then the MCP server is cut off (it never blocks), then the
    /// WebSocket hub and the proxy server stop. Pulled out so a test can run it.
    nonisolated static func runShutdownSequence(
        restoreSystemProxy: () -> Void, stopMCP: () -> Void, stopWebSockets: () -> Void, stopServer: () -> Void
    ) {
        restoreSystemProxy()
        stopMCP()
        stopWebSockets()
        stopServer()
    }

    // MARK: - Helpers

    private static func ownPorts(from port: Int, fallbackCount: Int) -> ClosedRange<Int> {
        port...min(65535, port + fallbackCount)
    }

    private nonisolated static func upstreamProxy(
        from snapshots: [ServiceProxySnapshot], ownPorts: ClosedRange<Int>
    ) -> UpstreamProxy? {
        SystemProxyController.upstream(from: snapshots, ownPorts: ownPorts)
            .map { UpstreamProxy(host: $0.host, port: $0.port, bypass: $0.bypass) }
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case let error as CommandError:
            switch error {
            case .needsAuthorization: return L10n.string("appModel.authorizationRequired")
            case .userCancelled: return L10n.string("appModel.authorizationCancelled")
            case .launchFailed(let executable, let reason): return L10n.format("appModel.commandLaunchFailed", executable, reason)
            case .failed(let text): return text
            }
        case let error as SystemProxyError:
            switch error {
            case .invalidBackup: return L10n.string("appModel.invalidBackup")
            case .invalidPort(let port): return L10n.format("appModel.invalidProxyPort", port)
            }
        case let error as TrustError:
            return Self.message(for: error)
        default:
            return String(describing: error)
        }
    }

    private static func message(for error: TrustError) -> String {
        switch error {
        case .keychainAdd(let status):
            if let detail = error.systemDetail { return L10n.format("appModel.trust.keychainAddDetail", Int(status), detail) }
            return L10n.format("appModel.trust.keychainAdd", Int(status))
        case .trustSettings(let status):
            if let detail = error.systemDetail { return L10n.format("appModel.trust.settingsDetail", Int(status), detail) }
            return L10n.format("appModel.trust.settings", Int(status))
        case .invalidCertificate:
            return L10n.string("appModel.trust.invalidCertificate")
        }
    }

    /// What a termination signal does, in this order: the system proxy is restored first (the safety-critical
    /// step; it waits for a running switch, and nothing may delay it), then the MCP server is cut off (it never
    /// blocks, and its socket and handshake files must not outlive the process), then the process exits.
    /// Pulled out so a test can run it.
    nonisolated static func runTerminationSequence(
        stopMCP: () -> Void, restoreSystemProxy: () -> Void, exit: () -> Void
    ) {
        restoreSystemProxy()
        stopMCP()
        exit()
    }

    /// Termination by signal skips `applicationWillTerminate`, so the system proxy is restored
    /// here. Nonisolated so the handlers are not tied to the main actor.
    private nonisolated static func makeSignalSources(
        systemProxy: SystemProxyCoordinator, mcp: MCPController
    ) -> [DispatchSourceSignal] {
        [SIGTERM, SIGINT, SIGHUP].map { sig in
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler {
                runTerminationSequence(
                    stopMCP: { mcp.beginStopForTermination() },
                    restoreSystemProxy: { systemProxy.restoreForTermination() }, exit: { exit(0) })
            }
            source.resume()
            return source
        }
    }
}

/// Runs every `SystemProxyController` call on one serial queue, so quitting (or a signal) waits for
/// an in-flight switch before restoring, and nothing queued afterwards runs. Sendable and free of
/// main-actor state so the signal handlers can use it.
private final class SystemProxyCoordinator: Sendable {
    struct Terminating: Error {}

    private let controller: SystemProxyController
    private let queue = DispatchQueue(label: "dev.pwapp.mac.system-proxy")
    private let terminating = OSAllocatedUnfairLock(initialState: false)

    init(controller: SystemProxyController) {
        self.controller = controller
    }

    /// Only checks for the backup file; cheap on any thread.
    var isEnabledByUs: Bool { controller.isEnabledByUs }

    /// Throws `Terminating` instead of running once `restoreForTermination()` has started.
    @discardableResult
    func run<T: Sendable>(_ work: @escaping @Sendable (SystemProxyController) throws -> T) async throws -> T {
        try await runBlocking(on: queue) { [controller, terminating] in
            if terminating.withLock({ $0 }) { throw Terminating() }
            return try work(controller)
        }
    }

    /// Blocks until queued work has finished, then restores the system proxy if it is ours.
    func restoreForTermination() {
        terminating.withLock { $0 = true }
        queue.sync {
            // On failure the backup stays and the next launch retries via `recoverIfNeeded`.
            if controller.isEnabledByUs { _ = try? controller.disable() }
        }
    }
}

/// Runs blocking work (a child process, a system dialog) on `queue` rather than on a Swift
/// concurrency thread.
private func runBlocking<T: Sendable>(
    on queue: DispatchQueue, _ work: @escaping @Sendable () throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        queue.async { continuation.resume(with: Result { try work() }) }
    }
}
