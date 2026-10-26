import Darwin
import Foundation
import Localization
import MCPKit
import NIOCore
import NIOPosix
import RulesEngine
import SystemProxy
import Testing
import os
@testable import AppCore
@testable import ProxyWoman

/// The App side of the isolation switch. Without it the runtime is the one the app always had;
/// with it a whole real `AppModel` run (launch, a proxied request, settings writes, system-proxy
/// and certificate requests, a restart, shutdown) writes only under its root and never reaches the
/// injected `networksetup` runner, the trust operations or the standard preferences.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)), .productionChinese) struct IsolatedRuntimeTests {
    @Test func withoutTheSwitchTheRuntimeIsTheNormalOne() throws {
        let runner = RecordingCommandRunner(), trust = TrustRecorder()
        let runtime = try AppRuntime.resolve(arguments: ["/app", "-port", "9091"], environment: ["HOME": "/Users/u"],
                                             bundleIdentifier: "dev.pwapp.mac", temporaryDirectories: [],
                                             home: URL(fileURLWithPath: "/nonexistent-home"),
                                             commandRunner: runner, trust: trust.operations)
        #expect(runtime.isolated == nil)
        #expect(runtime.layout.applicationSupport.path == URL.applicationSupportDirectory.path + "/ProxyWoman")
        #expect(runtime.layout.bodies.path == URL.cachesDirectory.path + "/ProxyWoman/Bodies")
        #expect(runtime.layout.breakpointSpool.path == URL.cachesDirectory.path + "/ProxyWoman/BreakpointSpool")
        #expect(runtime.layout.proxyBackup.path == URL.applicationSupportDirectory.path + "/ProxyWoman/proxy-backup.json")
        #expect(ObjectIdentifier(runtime.settingsStorage) == ObjectIdentifier(UserDefaults.standard))
        #expect((runtime.systemProxyRunner as? RecordingCommandRunner) === runner)
        #expect(runtime.trust != nil)
        #expect(runtime.listenPort == nil)
        // Resolving the runtime itself runs nothing.
        #expect(runner.calls.isEmpty && trust.calls == 0)
    }

    @Test func aRefusedSwitchNeverFallsBackToTheNormalRuntime() throws {
        let runner = RecordingCommandRunner(), trust = TrustRecorder()
        let resolvedStandard = OSAllocatedUnfairLock(initialState: false)
        #expect(throws: IsolatedLaunch.Rejection.notAbsolute) {
            _ = try AppRuntime.resolve(arguments: ["/app", IsolatedLaunch.rootArgument, "relative"], environment: [:],
                                       bundleIdentifier: "dev.pwapp.mac.t12a-copy", temporaryDirectories: [],
                                       home: URL(fileURLWithPath: "/nonexistent-home"),
                                       standardLayout: { resolvedStandard.withLock { $0 = true }; return .standard(appName: "ProxyWoman") },
                                       commandRunner: runner, trust: trust.operations)
        }
        #expect(!resolvedStandard.withLock { $0 })
    }

    /// Fix round 1 (I1, I2): every unsafe or ambiguous launch ends with exit code 64 before any
    /// runtime exists, so neither `networksetup` nor the trust probe can run. (The `exit` call
    /// itself is `AppDelegate`'s single line; the App is not launched here.)
    @Test(arguments: RefusedLaunch.allCases)
    func unsafeOrAmbiguousLaunchesExitWith64WithoutTouchingTheSystem(_ launch: RefusedLaunch) throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("refused-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("root", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        defer { try? FileManager.default.removeItem(at: base) }
        let runner = RecordingCommandRunner(), trust = TrustRecorder()
        let resolvedStandard = OSAllocatedUnfairLock(initialState: false)
        let (arguments, environment, bundle, code) = launch.inputs(root: root.path, home: home.path)
        let startup = AppRuntime.startup(
            arguments: ["/app"] + arguments, environment: environment, bundleIdentifier: bundle,
            temporaryDirectories: [base], home: home,
            standardLayout: { resolvedStandard.withLock { $0 = true }; return .standard(appName: "ProxyWoman") },
            commandRunner: runner, trust: trust.operations)
        guard case .refuse(let refusal) = startup else { Issue.record("\(launch) was not refused"); return }
        #expect(refusal.exitCode == 64)
        #expect(refusal.rejection == code)
        #expect(refusal.message == L10n.format("isolatedMode.rejected", code.rawValue))
        #expect(runner.calls.isEmpty && trust.calls == 0)
        #expect(!resolvedStandard.withLock { $0 })
    }

    /// The same entry point still starts a normal launch of the official bundle unchanged.
    @Test func theStartupEntryPointRunsANormalOfficialLaunch() throws {
        let runner = RecordingCommandRunner(), trust = TrustRecorder()
        guard case .run(let runtime) = AppRuntime.startup(
            arguments: ["/app"], environment: [:], bundleIdentifier: "dev.pwapp.mac", temporaryDirectories: [],
            home: URL(fileURLWithPath: "/nonexistent-home"), commandRunner: runner, trust: trust.operations) else {
            Issue.record("normal launch refused"); return
        }
        #expect(runtime.isolated == nil)
        #expect((runtime.systemProxyRunner as? RecordingCommandRunner) === runner)
        #expect(runner.calls.isEmpty && trust.calls == 0)
    }

    @Test func anIsolatedRunWritesOnlyUnderItsRootAndNeverTouchesSystemProxyTrustOrPreferences() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("isolated-run-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("root", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        // Stand-in for the user's real default locations.
        let fakeHome = base.appendingPathComponent("real-home", isDirectory: true)
        let fakeSupport = fakeHome.appendingPathComponent("Library/Application Support", isDirectory: true)
        let fakeCaches = fakeHome.appendingPathComponent("Library/Caches", isDirectory: true)
        for directory in [home, fakeSupport, fakeCaches] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        defer { try? FileManager.default.removeItem(at: base) }
        let fakeBefore = try tree(fakeHome)
        let keys = ["port", "decryption", "passthroughHosts", "preferences"]
        let defaultsBefore = keys.map { UserDefaults.standard.object(forKey: $0).map { String(describing: $0) } }

        let runner = RecordingCommandRunner(), trust = TrustRecorder()
        let resolvedStandard = OSAllocatedUnfairLock(initialState: false)
        let runtime = try AppRuntime.resolve(
            arguments: ["/app", IsolatedLaunch.rootArgument, root.path], environment: ["CFFIXED_USER_HOME": home.path],
            bundleIdentifier: "dev.pwapp.mac.t12a-copy", temporaryDirectories: [base], home: home,
            standardLayout: {
                resolvedStandard.withLock { $0 = true }
                return .standard(appName: "ProxyWoman", applicationSupportBase: fakeSupport, cachesBase: fakeCaches)
            },
            commandRunner: runner, trust: trust.operations)
        let resolvedRoot = URL(fileURLWithPath: root.path).resolvingSymlinksInPath()
        #expect(runtime.isolated?.root.path == resolvedRoot.path)
        #expect(runtime.systemProxyRunner == nil && runtime.trust == nil)
        #expect(ObjectIdentifier(runtime.settingsStorage) != ObjectIdentifier(UserDefaults.standard))
        #expect(runtime.listenPort == 0)

        let origin = try await LoopbackOrigin.start()
        let model = AppModel(runtime: runtime)
        do {
            #expect(model.isolatedRoot?.path == resolvedRoot.path)
            #expect(model.lastError == L10n.format("isolatedMode.active", resolvedRoot.path))
            await model.launch()
            // MCP is off in an isolated run until the user turns it on: no socket, no handshake file.
            #expect(model.settings.mcp == MCPSettings() && model.mcp.status == .off)
            let port = try #require(model.listeningPort)
            #expect(model.listenHost == "127.0.0.1")
            #expect(model.upstreamProxyDescription == L10n.string("appModel.direct"))

            // Real traffic through the isolated listener is proxied and recorded.
            let client = try await LoopbackClient.connect(port: port)
            try await client.send("GET http://127.0.0.1:\(origin.port)/isolated HTTP/1.1\r\nHost: 127.0.0.1:\(origin.port)\r\nConnection: close\r\n\r\n")
            #expect(try await client.responseUntilClose().hasSuffix("origin-ok"))
            await client.close()
            #expect(origin.requests.map(\.uri) == ["/isolated"])
            try await pollUntil("the isolated flow is recorded") { model.store.allFlows().contains { $0.path == "/isolated" } }

            // Rules and their assets are saved under the root, and a Map Local reply comes from there.
            let source = base.appendingPathComponent("asset-source.txt")
            try Data("isolated-local".utf8).write(to: source)
            let asset = try await model.managedAssets.importFile(source, displayName: "isolated")
            let rule = Rule(id: UUID(), name: "local", enabled: true, order: 0, matcher: RuleMatcher(path: .exact("/local")),
                            action: .mapLocal(MapLocalAction(assetID: asset.id, headers: [])))
            _ = try await model.rulesRepository.save(groups: [], rules: [rule], expectedRevision: model.rulesRepository.provider.current().revision)
            let local = try await LoopbackClient.connect(port: port)
            try await local.send("GET http://127.0.0.1:\(origin.port)/local HTTP/1.1\r\nHost: 127.0.0.1:\(origin.port)\r\nConnection: close\r\n\r\n")
            #expect(try await local.responseUntilClose().hasSuffix("isolated-local"))
            await local.close()
            #expect(origin.requests.count == 1)

            // Preferences go to the run's own storage.
            model.settings.port = 23_456
            model.setDecryption(excluded: true, for: "isolated.example")
            #expect(runtime.settingsStorage.integer(forKey: "port") == 23_456)

            // No system proxy, no certificate trust.
            #expect(!model.requestSystemProxy(true))
            #expect(model.lastError == L10n.string("isolatedMode.systemProxyUnavailable"))
            #expect(!model.isSystemProxyEnabled && !model.isConfirmingSystemProxy)
            await model.installCertificate()
            #expect(model.lastError == L10n.string("isolatedMode.trustUnavailable"))
            await model.removeCertificateTrust()
            model.refreshTrust()
            #expect(!model.isCATrusted)

            // A restart on another loopback port.
            let next = try await freeLoopbackPort()
            await model.setPort(next)
            #expect(model.listeningPort == next)
        } catch { model.shutdown(); await origin.stop(); throw error }
        model.shutdown()
        await origin.stop()

        #expect(runner.calls.isEmpty, "networksetup was run: \(runner.calls)")
        #expect(trust.calls == 0)
        #expect(!resolvedStandard.withLock { $0 })
        #expect(try tree(fakeHome) == fakeBefore)
        #expect(keys.map { UserDefaults.standard.object(forKey: $0).map { String(describing: $0) } } == defaultsBefore)
        let written = try tree(root)
        #expect(written.contains("Library/Application Support/ProxyWoman/CA/root-ca.pem"))
        #expect(written.contains("Library/Caches/ProxyWoman/BreakpointSpool"))
        #expect(written.contains("Library/Application Support/ProxyWoman/Rules"))
        #expect(written.contains("Library/Application Support/ProxyWoman/RuleAssets"))
        #expect(!written.contains("Library/Application Support/ProxyWoman/proxy-backup.json"))
        #expect(!written.contains { $0.contains("mcp") }, "MCP left files behind: \(written.filter { $0.contains("mcp") })")
    }
}

/// Every relative path below `directory`, sorted.
private func tree(_ directory: URL) throws -> [String] {
    let base = directory.resolvingSymlinksInPath().path
    guard let enumerator = FileManager.default.enumerator(atPath: base) else { return [] }
    return enumerator.compactMap { $0 as? String }.sorted()
}

@MainActor private func pollUntil(_ what: String, timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { throw FixtureTimeout(what: what) }
        try await Task.sleep(for: .milliseconds(20))
    }
}

/// A loopback port nothing listens on right now (bound once by the OS, then released).
private func freeLoopbackPort() async throws -> Int {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    do {
        let channel = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
        let port = channel.localAddress?.port ?? 0
        try await channel.close().get()
        try await group.shutdownGracefully()
        return port
    } catch { try? await group.shutdownGracefully(); throw error }
}

/// Records every `networksetup` invocation instead of running it.
final class RecordingCommandRunner: CommandRunner {
    private let recorded = OSAllocatedUnfairLock<[[String]]>(initialState: [])
    var calls: [[String]] { recorded.withLock { $0 } }
    func networksetup(_ args: [String]) throws(CommandError) -> String {
        recorded.withLock { $0.append(args) }
        return ""
    }
    func networksetupPrivileged(_ commands: [[String]]) throws(CommandError) {
        recorded.withLock { $0.append(contentsOf: commands) }
    }
}

/// Counts every trust query or change instead of reaching the keychain.
final class TrustRecorder: Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)
    var calls: Int { count.withLock { $0 } }
    var operations: TrustOperations {
        TrustOperations(
            isTrusted: { [count] _ in count.withLock { $0 += 1 }; return false },
            install: { [count] _ in count.withLock { $0 += 1 } },
            remove: { [count] _ in count.withLock { $0 += 1 } })
    }
}


/// Launches that must not start (fix round 1).
enum RefusedLaunch: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case misspelledFlag, wrongCase, doubleDash, equalsForm, missingValue, homeOverriddenWithoutFlag
    case reidentifiedCopyWithoutFlag, officialBundleIsolated, noBundleIsolated

    var testDescription: String { rawValue }

    func inputs(root: String, home: String) -> (arguments: [String], environment: [String: String], bundle: String?,
                                                rejection: IsolatedLaunch.Rejection) {
        let copy = "dev.pwapp.mac.t12a-copy", official = "dev.pwapp.mac", fixed = ["CFFIXED_USER_HOME": home]
        switch self {
        case .misspelledFlag: return (["-ProxyWomanIsolatedRot", root], fixed, copy, .malformedArgument)
        case .wrongCase: return (["-proxywomanisolatedroot", root], [:], official, .malformedArgument)
        case .doubleDash: return (["--ProxyWomanIsolatedRoot", root], fixed, copy, .malformedArgument)
        case .equalsForm: return (["-ProxyWomanIsolatedRoot=" + root], fixed, copy, .malformedArgument)
        case .missingValue: return ([IsolatedLaunch.rootArgument], fixed, copy, .missingRoot)
        case .homeOverriddenWithoutFlag: return (["-port", "9091"], fixed, official, .homeOverriddenWithoutRoot)
        case .reidentifiedCopyWithoutFlag: return (["-port", "9091"], [:], copy, .unofficialBundleWithoutRoot)
        case .officialBundleIsolated: return ([IsolatedLaunch.rootArgument, root], fixed, official, .officialBundleIdentifier)
        case .noBundleIsolated: return ([IsolatedLaunch.rootArgument, root], fixed, nil, .officialBundleIdentifier)
        }
    }
}
