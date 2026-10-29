import Foundation
import Testing
import os

@testable import SystemProxy

/// Stateful stand-in for `networksetup`: answers `-get*` from its model, applies `-set*` to it,
/// and records every call. Never touches the real system.
final class FakeRunner: CommandRunner {
    struct ServiceState {
        var web: ProxyEndpoint
        var secure: ProxyEndpoint
        var bypass: [String]
    }
    struct State {
        var order: [String]
        var disabledInList: Set<String> = []
        var services: [String: ServiceState]
        var calls: [[String]] = []
        var privilegedBatches: [[[String]]] = []
        var privilegedGroups: [[[[String]]]] = []
    }

    private let state: OSAllocatedUnfairLock<State>
    /// Return an error to make a given call fail (called before the call is applied).
    private let failure: @Sendable ([String]) -> CommandError?
    private let onSet: @Sendable () -> Void
    private let privilegedFailure: CommandError?

    init(
        services: [(String, ServiceState)],
        failure: @escaping @Sendable ([String]) -> CommandError? = { _ in nil },
        privilegedFailure: CommandError? = nil,
        onSet: @escaping @Sendable () -> Void = {}
    ) {
        state = OSAllocatedUnfairLock(
            initialState: State(order: services.map(\.0), services: Dictionary(uniqueKeysWithValues: services)))
        self.failure = failure
        self.privilegedFailure = privilegedFailure
        self.onSet = onSet
    }

    var calls: [[String]] { state.withLock { $0.calls } }
    var setCalls: [[String]] { calls.filter { $0[0].hasPrefix("-set") } }
    var privilegedBatches: [[[String]]] { state.withLock { $0.privilegedBatches } }
    func service(_ name: String) -> ServiceState? { state.withLock { $0.services[name] } }
    var privilegedGroups: [[[[String]]]] { state.withLock { $0.privilegedGroups } }
    func resetCalls() { state.withLock { $0.calls = []; $0.privilegedBatches = []; $0.privilegedGroups = [] } }
    /// The service vanishes from the system (renamed/removed): it is no longer listed and any command on it fails.
    func removeService(_ name: String) { state.withLock { $0.order.removeAll { $0 == name }; $0.services[name] = nil } }
    /// The service stays but is shown with a leading asterisk in `-listallnetworkservices`.
    func disableInList(_ name: String) { state.withLock { _ = $0.disabledInList.insert(name) } }

    static func text(_ e: ProxyEndpoint) -> String {
        "Enabled: \(e.enabled ? "Yes" : "No")\nServer: \(e.host)\nPort: \(e.port)\nAuthenticated Proxy Enabled: 0\n"
    }

    static let missing = CommandError.failed("** Error: Unable to find item in network database.")

    func networksetup(_ args: [String]) throws(CommandError) -> String {
        state.withLock { $0.calls.append(args) }
        if let error = failure(args) { throw error }
        if args[0].hasPrefix("-set") { onSet() }
        let result: Result<String, CommandError> = state.withLock { st in
            if args[0] == "-listallnetworkservices" {
                return .success(
                    "An asterisk (*) denotes that a network service is disabled.\n"
                        + st.order.map { (st.disabledInList.contains($0) ? "*" : "") + $0 }.joined(separator: "\n") + "\n")
            }
            guard let service = st.services[args[1]] else { return .failure(Self.missing) }
            switch args[0] {
            case "-getwebproxy": return .success(Self.text(service.web))
            case "-getsecurewebproxy": return .success(Self.text(service.secure))
            case "-getproxybypassdomains":
                let b = service.bypass
                return .success(b.isEmpty ? "There aren't any bypass domains set on \(args[1]).\n" : b.joined(separator: "\n") + "\n")
            default:
                apply(args, to: &st)
                return .success("")
            }
        }
        return try result.get()
    }

    func networksetupPrivileged(_ commands: [[String]]) throws(CommandError) {
        try networksetupPrivileged(groups: [commands])
    }

    /// Mirrors the real script: `&&` inside a group, groups independent, failure if any group failed.
    func networksetupPrivileged(groups: [[[String]]]) throws(CommandError) {
        state.withLock { $0.privilegedBatches.append(groups.flatMap { $0 }); $0.privilegedGroups.append(groups) }
        if let privilegedFailure { throw privilegedFailure }
        let anyFailed = state.withLock { st -> Bool in
            var failed = false
            for group in groups {
                for c in group {
                    guard st.services[c[1]] != nil else { failed = true; break }
                    apply(c, to: &st)
                }
            }
            return failed
        }
        if anyFailed { throw Self.missing }
    }

    private func apply(_ args: [String], to st: inout State) {
        switch args[0] {
        case "-setwebproxy":
            st.services[args[1]]!.web = ProxyEndpoint(enabled: true, host: args[2], port: Int(args[3])!)
        case "-setsecurewebproxy":
            st.services[args[1]]!.secure = ProxyEndpoint(enabled: true, host: args[2], port: Int(args[3])!)
        case "-setwebproxystate": st.services[args[1]]!.web.enabled = args[2] == "on"
        case "-setsecurewebproxystate": st.services[args[1]]!.secure.enabled = args[2] == "on"
        case "-setproxybypassdomains":
            let domains = Array(args.dropFirst(2))
            st.services[args[1]]!.bypass = domains == ["Empty"] ? [] : domains
        default: break
        }
    }
}

private let clash = ProxyEndpoint(enabled: true, host: "127.0.0.1", port: 7897)
private let none = ProxyEndpoint(enabled: false, host: "", port: 0)
private let bypass = ["127.0.0.1", "192.168.0.0/16", "localhost", "*.local", "<local>"]

private func wifi(web: ProxyEndpoint = clash, secure: ProxyEndpoint = clash) -> (String, FakeRunner.ServiceState) {
    ("Wi-Fi", .init(web: web, secure: secure, bypass: bypass))
}

private func tempBackupURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("SystemProxyTests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("system-proxy-backup.json")
}

private func cleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

private func backupExists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

@Suite struct ControllerTests {
    @Test func snapshotReadsEveryService() throws {
        let runner = FakeRunner(services: [wifi(), ("USB ACM", .init(web: none, secure: none, bypass: []))])
        let url = tempBackupURL(); defer { cleanup(url) }
        let snapshots = try SystemProxyController(runner: runner, backupURL: url).snapshot()
        #expect(
            snapshots == [
                ServiceProxySnapshot(service: "Wi-Fi", web: clash, secureWeb: clash, bypassDomains: bypass),
                ServiceProxySnapshot(service: "USB ACM", web: none, secureWeb: none, bypassDomains: []),
            ])
        #expect(runner.setCalls.isEmpty)
    }

    @Test func enableWritesBackupBeforeChanging() throws {
        let url = tempBackupURL(); defer { cleanup(url) }
        let seen = OSAllocatedUnfairLock<[Bool]>(initialState: [])
        let runner = FakeRunner(services: [wifi()], onSet: { seen.withLock { $0.append(backupExists(url)) } })
        try SystemProxyController(runner: runner, backupURL: url).enable(host: "127.0.0.1", port: 9090)
        let observed = seen.withLock { $0 }
        #expect(!observed.isEmpty)
        #expect(observed.allSatisfy { $0 })
    }

    @Test func enableSetsOnlyWebAndSecureWeb() throws {
        let url = tempBackupURL(); defer { cleanup(url) }
        let runner = FakeRunner(services: [wifi()])
        let controller = SystemProxyController(runner: runner, backupURL: url)
        try controller.enable(host: "127.0.0.1", port: 9090)
        #expect(
            runner.setCalls == [
                ["-setwebproxy", "Wi-Fi", "127.0.0.1", "9090"],
                ["-setsecurewebproxy", "Wi-Fi", "127.0.0.1", "9090"],
            ])
        #expect(controller.isEnabledByUs)
    }

    @Test func disableRestoresExactly() throws {
        let url = tempBackupURL(); defer { cleanup(url) }
        let runner = FakeRunner(services: [wifi(web: clash, secure: none)])
        let controller = SystemProxyController(runner: runner, backupURL: url)
        try controller.enable(host: "127.0.0.1", port: 9090)
        runner.resetCalls()
        try controller.disable()
        #expect(
            runner.setCalls == [
                ["-setwebproxy", "Wi-Fi", "127.0.0.1", "7897"],
                ["-setsecurewebproxystate", "Wi-Fi", "off"],
            ])
        #expect(!backupExists(url))
        #expect(!controller.isEnabledByUs)
        #expect(runner.service("Wi-Fi")?.web == clash)
        // networksetup cannot clear a stored address, so only the disabled state is restorable here.
        #expect(runner.service("Wi-Fi")?.secure.enabled == false)
        #expect(runner.service("Wi-Fi")?.bypass == bypass)
    }

    @Test func enableAppendsBypassHostsAndDisableRestoresTheOriginalList() throws {
        let url = tempBackupURL(); defer { cleanup(url) }
        let runner = FakeRunner(services: [wifi()])
        let controller = SystemProxyController(runner: runner, backupURL: url)
        try controller.enable(host: "127.0.0.1", port: 9090, bypass: ["*.apple.com", "localhost"])
        #expect(runner.service("Wi-Fi")?.bypass == bypass + ["*.apple.com"])
        try controller.disable()
        #expect(runner.service("Wi-Fi")?.bypass == bypass)
        #expect(runner.service("Wi-Fi")?.web == clash)
    }

    @Test func disableLeavesABypassListSomeoneElseChanged() throws {
        let url = tempBackupURL(); defer { cleanup(url) }
        let runner = FakeRunner(services: [("Wi-Fi", .init(web: clash, secure: clash, bypass: []))])
        let controller = SystemProxyController(runner: runner, backupURL: url)
        try controller.enable(host: "127.0.0.1", port: 9090, bypass: ["*.apple.com"])
        #expect(runner.service("Wi-Fi")?.bypass == ["*.apple.com"])
        _ = try runner.networksetup(["-setproxybypassdomains", "Wi-Fi", "example.org"])
        try controller.disable()
        #expect(runner.service("Wi-Fi")?.bypass == ["example.org"])
    }

    @Test func disableRestoresAnEmptyOriginalBypassList() throws {
        let url = tempBackupURL(); defer { cleanup(url) }
        let runner = FakeRunner(services: [("Wi-Fi", .init(web: clash, secure: clash, bypass: []))])
        let controller = SystemProxyController(runner: runner, backupURL: url)
        try controller.enable(host: "127.0.0.1", port: 9090, bypass: ["*.apple.com"])
        runner.resetCalls()
        try controller.disable()
        #expect(runner.setCalls.contains(["-setproxybypassdomains", "Wi-Fi", "Empty"]))
        #expect(runner.service("Wi-Fi")?.bypass == [])
    }

    @Test func disableRestoresDisabledServiceWithRememberedAddress() throws {
        let url = tempBackupURL(); defer { cleanup(url) }
        let off = ProxyEndpoint(enabled: false, host: "10.0.0.5", port: 3128)
        let runner = FakeRunner(services: [wifi(web: off, secure: off)])
        let controller = SystemProxyController(runner: runner, backupURL: url)
        try controller.enable(host: "127.0.0.1", port: 9090)
        runner.resetCalls()
        try controller.disable()
        #expect(
            runner.setCalls == [
                ["-setwebproxy", "Wi-Fi", "10.0.0.5", "3128"],
                ["-setwebproxystate", "Wi-Fi", "off"],
                ["-setsecurewebproxy", "Wi-Fi", "10.0.0.5", "3128"],
                ["-setsecurewebproxystate", "Wi-Fi", "off"],
            ])
        #expect(runner.service("Wi-Fi")?.web == off)
    }

    @Test func disableWithoutBackupIsNoOp() throws {
        let url = tempBackupURL(); defer { cleanup(url) }
        let runner = FakeRunner(services: [wifi()])
        try SystemProxyController(runner: runner, backupURL: url).disable()
        #expect(runner.calls.isEmpty)
    }

    @Test func enableTwiceKeepsOriginalBackup() throws {
        let url = tempBackupURL(); defer { cleanup(url) }
        let runner = FakeRunner(services: [wifi()])
        let controller = SystemProxyController(runner: runner, backupURL: url)
        try controller.enable(host: "127.0.0.1", port: 9090)
        // A fresh snapshot now points at us ...
        #expect(try controller.snapshot().first?.web.port == 9090)
        try controller.enable(host: "127.0.0.1", port: 9091)
        // ... but the backup still holds the original Clash settings.
        let saved = try JSONDecoder().decode(ProxyBackup.self, from: Data(contentsOf: url))
        #expect(saved.services == [ServiceProxySnapshot(service: "Wi-Fi", web: clash, secureWeb: clash, bypassDomains: bypass)])
        // Both ports we pointed the system at count as ours.
        #expect(saved.ownHost == "127.0.0.1")
        #expect(saved.ownPorts == [9090, 9091])
        try controller.disable()
        #expect(runner.service("Wi-Fi")?.web == clash)
        #expect(runner.service("Wi-Fi")?.secure == clash)
    }

    @Test func recoverIfNeededRestoresAfterCrash() throws {
        let url = tempBackupURL(); defer { cleanup(url) }
        // First "process": enable, then "crash" (never disable).
        let crashed = FakeRunner(services: [wifi()])
        try SystemProxyController(runner: crashed, backupURL: url).enable(host: "127.0.0.1", port: 9090)
        #expect(crashed.service("Wi-Fi")?.web.port == 9090)
        // Second "process": new controller, same backup file, same (still modified) system.
        let runner = FakeRunner(services: [wifi(web: .init(enabled: true, host: "127.0.0.1", port: 9090), secure: .init(enabled: true, host: "127.0.0.1", port: 9090))])
        let controller = SystemProxyController(runner: runner, backupURL: url)
        #expect(controller.isEnabledByUs)
        #expect(try controller.recoverIfNeeded() == .restored)
        #expect(
            runner.setCalls == [
                ["-setwebproxy", "Wi-Fi", "127.0.0.1", "7897"],
                ["-setsecurewebproxy", "Wi-Fi", "127.0.0.1", "7897"],
            ])
        #expect(!backupExists(url))
    }

    @Test func originalSettingsComeFromBackupWhileEnabled() throws {
        let url = tempBackupURL()
        defer { cleanup(url) }
        let runner = FakeRunner(services: [wifi()])
        let controller = SystemProxyController(runner: runner, backupURL: url)
        let before = try controller.snapshot()
        #expect(try controller.originalSettings() == before)

        try controller.enable(host: "127.0.0.1", port: 9091)
        #expect(try controller.snapshot() != before)
        #expect(try controller.originalSettings() == before)
    }

    @Test func recoverIfNeededWithoutBackupDoesNothing() throws {
        let url = tempBackupURL(); defer { cleanup(url) }
        let runner = FakeRunner(services: [wifi()])
        #expect(try SystemProxyController(runner: runner, backupURL: url).recoverIfNeeded() == .nothingToRestore)
        #expect(runner.calls.isEmpty)
    }

    @Test func needsAuthorizationFallsBackToPrivilegedBatch() throws {
        let url = tempBackupURL(); defer { cleanup(url) }
        let runner = FakeRunner(
            services: [wifi(), ("USB ACM", .init(web: none, secure: none, bypass: []))],
            failure: { $0[0].hasPrefix("-set") ? .needsAuthorization : nil })
        try SystemProxyController(runner: runner, backupURL: url).enable(host: "127.0.0.1", port: 9090)
        #expect(
            runner.privilegedBatches == [
                [
                    ["-setwebproxy", "Wi-Fi", "127.0.0.1", "9090"],
                    ["-setsecurewebproxy", "Wi-Fi", "127.0.0.1", "9090"],
                    ["-setwebproxy", "USB ACM", "127.0.0.1", "9090"],
                    ["-setsecurewebproxy", "USB ACM", "127.0.0.1", "9090"],
                ]
            ])
        #expect(runner.service("Wi-Fi")?.web.port == 9090)
    }

    @Test func disableAlsoUsesPrivilegedFallback() throws {
        let url = tempBackupURL(); defer { cleanup(url) }
        let denyDirect = OSAllocatedUnfairLock(initialState: false)
        let runner = FakeRunner(
            services: [wifi()],
            failure: { args in args[0].hasPrefix("-set") && denyDirect.withLock { $0 } ? .needsAuthorization : nil })
        let controller = SystemProxyController(runner: runner, backupURL: url)
        try controller.enable(host: "127.0.0.1", port: 9090)
        denyDirect.withLock { $0 = true }
        runner.resetCalls()
        try controller.disable()
        #expect(
            runner.privilegedBatches == [
                [
                    ["-setwebproxy", "Wi-Fi", "127.0.0.1", "7897"],
                    ["-setsecurewebproxy", "Wi-Fi", "127.0.0.1", "7897"],
                ]
            ])
        #expect(!backupExists(url))
    }

    @Test func midwayFailureRollsBackAndRethrows() throws {
        let url = tempBackupURL(); defer { cleanup(url) }
        let failNext = OSAllocatedUnfairLock(initialState: true)
        let runner = FakeRunner(
            services: [wifi()],
            failure: { args in
                // Fail only the secure-web enable (second set command), once.
                if args == ["-setsecurewebproxy", "Wi-Fi", "127.0.0.1", "9090"], failNext.withLock({ let v = $0; $0 = false; return v }) {
                    return .failed("boom")
                }
                return nil
            })
        let controller = SystemProxyController(runner: runner, backupURL: url)
        #expect(throws: CommandError.failed("boom")) { try controller.enable(host: "127.0.0.1", port: 9090) }
        #expect(runner.service("Wi-Fi")?.web == clash)
        #expect(runner.service("Wi-Fi")?.secure == clash)
        #expect(!backupExists(url))
    }

    @Test func cancelledPrivilegedEnableLeavesNoBackup() throws {
        let url = tempBackupURL(); defer { cleanup(url) }
        let runner = FakeRunner(
            services: [wifi()],
            failure: { $0[0].hasPrefix("-set") ? .needsAuthorization : nil },
            privilegedFailure: .userCancelled)
        let controller = SystemProxyController(runner: runner, backupURL: url)
        #expect(throws: CommandError.userCancelled) { try controller.enable(host: "127.0.0.1", port: 9090) }
        #expect(!backupExists(url))
        #expect(runner.service("Wi-Fi")?.web == clash)
    }

    @Test func failedRestoreKeepsBackupForRetry() throws {
        let url = tempBackupURL(); defer { cleanup(url) }
        let broken = OSAllocatedUnfairLock(initialState: false)
        let runner = FakeRunner(
            services: [wifi()],
            failure: { args in args[0].hasPrefix("-set") && broken.withLock { $0 } ? .failed("nope") : nil })
        let controller = SystemProxyController(runner: runner, backupURL: url)
        try controller.enable(host: "127.0.0.1", port: 9090)
        broken.withLock { $0 = true }
        #expect(throws: CommandError.failed("nope")) { try controller.disable() }
        #expect(backupExists(url))
        broken.withLock { $0 = false }
        #expect(try controller.recoverIfNeeded() == .restored)
        #expect(runner.service("Wi-Fi")?.web == clash)
    }
}

private func twoServices(_ aWeb: ProxyEndpoint = clash) -> [(String, FakeRunner.ServiceState)] {
    let b = ProxyEndpoint(enabled: true, host: "10.0.0.9", port: 3128)
    return [
        ("AAA", .init(web: aWeb, secure: aWeb, bypass: bypass)),
        ("BBB", .init(web: b, secure: b, bypass: [])),
    ]
}

@Suite struct MissingServiceTests {
    private let b = ProxyEndpoint(enabled: true, host: "10.0.0.9", port: 3128)

    @Test func vanishedServiceDoesNotBlockRestoreOfOthers() throws {
        let url = tempBackupURL(); defer { cleanup(url) }
        let runner = FakeRunner(services: twoServices())
        let controller = SystemProxyController(runner: runner, backupURL: url)
        try controller.enable(host: "127.0.0.1", port: 9090)
        runner.removeService("AAA")  // renamed or removed while we were enabled
        runner.resetCalls()
        try controller.disable()
        #expect(runner.service("BBB")?.web == b)
        #expect(runner.service("BBB")?.secure == b)
        #expect(!runner.setCalls.contains { $0.count > 1 && $0[1] == "AAA" })
        #expect(!backupExists(url))
    }

    @Test func vanishedServiceIsSkippedInPrivilegedBatch() throws {
        let url = tempBackupURL(); defer { cleanup(url) }
        let denyDirect = OSAllocatedUnfairLock(initialState: false)
        let runner = FakeRunner(
            services: twoServices(),
            failure: { args in args[0].hasPrefix("-set") && denyDirect.withLock { $0 } ? .needsAuthorization : nil })
        let controller = SystemProxyController(runner: runner, backupURL: url)
        try controller.enable(host: "127.0.0.1", port: 9090)
        runner.removeService("AAA")
        denyDirect.withLock { $0 = true }
        runner.resetCalls()
        try controller.disable()
        // Per-service groups, and the vanished service is not in them.
        #expect(runner.privilegedGroups.count == 1)
        #expect(runner.privilegedGroups[0].count == 1)
        #expect(runner.privilegedGroups[0][0].allSatisfy { $0[1] == "BBB" })
        #expect(runner.service("BBB")?.web == b)
        #expect(!backupExists(url))
    }

    @Test func disabledInListServiceIsStillRestored() throws {
        let url = tempBackupURL(); defer { cleanup(url) }
        let runner = FakeRunner(services: twoServices())
        let controller = SystemProxyController(runner: runner, backupURL: url)
        try controller.enable(host: "127.0.0.1", port: 9090)
        runner.disableInList("BBB")
        try controller.disable()
        #expect(runner.service("BBB")?.web == b)
        #expect(runner.service("AAA")?.web == clash)
        #expect(!backupExists(url))
    }

    @Test func enableWithExistingBackupSkipsVanishedService() throws {
        let url = tempBackupURL(); defer { cleanup(url) }
        let runner = FakeRunner(services: twoServices())
        let controller = SystemProxyController(runner: runner, backupURL: url)
        try controller.enable(host: "127.0.0.1", port: 9090)
        runner.removeService("AAA")
        runner.resetCalls()
        try controller.enable(host: "127.0.0.1", port: 9091)
        #expect(
            runner.setCalls == [
                ["-setwebproxy", "BBB", "127.0.0.1", "9091"],
                ["-setsecurewebproxy", "BBB", "127.0.0.1", "9091"],
            ])
    }

    @Test func failingServiceKeepsOnlyItselfInBackupAndRetrySucceeds() throws {
        let url = tempBackupURL(); defer { cleanup(url) }
        let broken = OSAllocatedUnfairLock(initialState: false)
        let runner = FakeRunner(
            services: twoServices(),
            failure: { args in
                args[0].hasPrefix("-set") && args[1] == "AAA" && broken.withLock { $0 } ? .failed("nope") : nil
            })
        let controller = SystemProxyController(runner: runner, backupURL: url)
        try controller.enable(host: "127.0.0.1", port: 9090)
        broken.withLock { $0 = true }
        #expect(throws: CommandError.failed("nope")) { try controller.disable() }
        #expect(runner.service("BBB")?.web == b)  // later service was still restored
        #expect(runner.service("AAA")?.web.port == 9090)
        let saved = try JSONDecoder().decode(ProxyBackup.self, from: Data(contentsOf: url)).services
        #expect(saved.map(\.service) == ["AAA"])
        broken.withLock { $0 = false }
        #expect(try controller.recoverIfNeeded() == .restored)
        #expect(runner.service("AAA")?.web == clash)
        #expect(!backupExists(url))
    }

    @Test func failedPrivilegedRestoreKeepsBackupForExistingServices() throws {
        let url = tempBackupURL(); defer { cleanup(url) }
        let denyDirect = OSAllocatedUnfairLock(initialState: false)
        let runner = FakeRunner(
            services: twoServices(),
            failure: { args in args[0].hasPrefix("-set") && denyDirect.withLock { $0 } ? .needsAuthorization : nil },
            privilegedFailure: .userCancelled)
        // Enable directly (no denial yet), then deny and cancel the prompt on disable.
        let controller = SystemProxyController(runner: runner, backupURL: url)
        try controller.enable(host: "127.0.0.1", port: 9090)
        denyDirect.withLock { $0 = true }
        #expect(throws: CommandError.userCancelled) { try controller.disable() }
        let saved = try JSONDecoder().decode(ProxyBackup.self, from: Data(contentsOf: url)).services
        #expect(saved.map(\.service) == ["AAA", "BBB"])
    }
}

@Suite struct UpstreamDerivationTests {
    private func snap(_ name: String, web: ProxyEndpoint, secure: ProxyEndpoint, bypass: [String] = ["localhost"]) -> ServiceProxySnapshot {
        ServiceProxySnapshot(service: name, web: web, secureWeb: secure, bypassDomains: bypass)
    }

    @Test func upstreamDerivation() {
        let s = [snap("Wi-Fi", web: clash, secure: clash, bypass: bypass)]
        let up = SystemProxyController.upstream(from: s, ownPort: 9090)
        #expect(up?.host == "127.0.0.1")
        #expect(up?.port == 7897)
        #expect(up?.bypass == bypass)

        let own = ProxyEndpoint(enabled: true, host: "127.0.0.1", port: 9090)
        #expect(SystemProxyController.upstream(from: [snap("Wi-Fi", web: own, secure: own)], ownPort: 9090) == nil)
        #expect(SystemProxyController.upstream(from: [snap("Wi-Fi", web: none, secure: none)], ownPort: 9090) == nil)
        #expect(SystemProxyController.upstream(from: [], ownPort: 9090) == nil)
    }

    @Test func prefersSecureWebOverWeb() {
        let http = ProxyEndpoint(enabled: true, host: "10.0.0.1", port: 8080)
        let https = ProxyEndpoint(enabled: true, host: "10.0.0.2", port: 8443)
        let up = SystemProxyController.upstream(from: [snap("A", web: http, secure: none), snap("B", web: none, secure: https)], ownPort: 9090)
        #expect(up?.host == "10.0.0.2")
        #expect(up?.port == 8443)
    }

    @Test func fallsBackToWebAndIgnoresOwnEndpoint() {
        let own = ProxyEndpoint(enabled: true, host: "localhost", port: 9090)
        let http = ProxyEndpoint(enabled: true, host: "10.0.0.1", port: 8080)
        let up = SystemProxyController.upstream(from: [snap("A", web: http, secure: own)], ownPort: 9090)
        #expect(up?.host == "10.0.0.1")
        #expect(up?.port == 8080)
    }

    @Test func anyPortInOwnRangeIsOurs() {
        let fallback = ProxyEndpoint(enabled: true, host: "127.0.0.1", port: 9091)
        let http = ProxyEndpoint(enabled: true, host: "10.0.0.1", port: 8080)
        let up = SystemProxyController.upstream(from: [snap("A", web: http, secure: fallback)], ownPorts: 9090...9099)
        #expect(up?.host == "10.0.0.1")
        #expect(SystemProxyController.upstream(from: [snap("A", web: fallback, secure: fallback)], ownPorts: 9090...9099) == nil)
        let outside = ProxyEndpoint(enabled: true, host: "::1", port: 9100)
        #expect(SystemProxyController.upstream(from: [snap("A", web: outside, secure: outside)], ownPorts: 9090...9099)?.port == 9100)
    }

    /// The app passes only its bound port once listening: a user port of 7897 (Clash's) falls back
    /// to 7898, and Clash below it must still be used as the upstream.
    @Test func upstreamBelowFallbackBoundPortIsKept() {
        let up = SystemProxyController.upstream(
            from: [snap("A", web: clash, secure: clash)], ownPorts: 7898...7898)
        #expect(up?.host == "127.0.0.1")
        #expect(up?.port == 7897)
        let own = ProxyEndpoint(enabled: true, host: "127.0.0.1", port: 7898)
        #expect(
            SystemProxyController.upstream(from: [snap("A", web: own, secure: own)], ownPorts: 7898...7898) == nil)
    }

    @Test func sameHostDifferentPortIsNotOurs() {
        let other = ProxyEndpoint(enabled: true, host: "127.0.0.1", port: 7897)
        #expect(SystemProxyController.upstream(from: [snap("A", web: other, secure: other)], ownPort: 9090)?.port == 7897)
        let remote = ProxyEndpoint(enabled: true, host: "10.1.1.1", port: 9090)
        #expect(SystemProxyController.upstream(from: [snap("A", web: remote, secure: remote)], ownPort: 9090)?.host == "10.1.1.1")
    }
}

private let ours = ProxyEndpoint(enabled: true, host: "127.0.0.1", port: 9090)

@Suite struct OwnershipTests {
    @Test func endpointChangedBySomeoneElseIsNotTouched() throws {
        let url = tempBackupURL(); defer { cleanup(url) }
        let runner = FakeRunner(services: [wifi()])
        let controller = SystemProxyController(runner: runner, backupURL: url)
        try controller.enable(host: "127.0.0.1", port: 9090)
        // Another tool takes over the HTTPS proxy while we are enabled.
        _ = try runner.networksetup(["-setsecurewebproxy", "Wi-Fi", "10.0.0.1", "8888"])
        runner.resetCalls()
        #expect(try controller.disable() == .restored)
        #expect(runner.setCalls == [["-setwebproxy", "Wi-Fi", "127.0.0.1", "7897"]])
        #expect(runner.service("Wi-Fi")?.web == clash)
        #expect(runner.service("Wi-Fi")?.secure == ProxyEndpoint(enabled: true, host: "10.0.0.1", port: 8888))
        #expect(!backupExists(url))
    }

    @Test func endpointSwitchedOffBySomeoneElseStaysOff() throws {
        let url = tempBackupURL(); defer { cleanup(url) }
        let runner = FakeRunner(services: [wifi()])
        let controller = SystemProxyController(runner: runner, backupURL: url)
        try controller.enable(host: "127.0.0.1", port: 9090)
        _ = try runner.networksetup(["-setwebproxystate", "Wi-Fi", "off"])
        runner.resetCalls()
        try controller.disable()
        #expect(runner.setCalls == [["-setsecurewebproxy", "Wi-Fi", "127.0.0.1", "7897"]])
        #expect(runner.service("Wi-Fi")?.web.enabled == false)
        #expect(!backupExists(url))
    }

    @Test func endpointStillOursOnAnEarlierPortIsRestored() throws {
        let url = tempBackupURL(); defer { cleanup(url) }
        let runner = FakeRunner(services: [wifi()])
        let controller = SystemProxyController(runner: runner, backupURL: url)
        try controller.enable(host: "127.0.0.1", port: 9090)
        // Re-pointing at a new port fails for HTTPS: it still points at the old port.
        try controller.enable(host: "127.0.0.1", port: 9095)
        _ = try runner.networksetup(["-setsecurewebproxy", "Wi-Fi", "127.0.0.1", "9090"])
        try controller.disable()
        #expect(runner.service("Wi-Fi")?.web == clash)
        #expect(runner.service("Wi-Fi")?.secure == clash)
    }

    @Test func backupRecordsOwnHostAndPort() throws {
        let url = tempBackupURL(); defer { cleanup(url) }
        let runner = FakeRunner(services: [wifi()])
        try SystemProxyController(runner: runner, backupURL: url).enable(host: "127.0.0.1", port: 9092)
        let saved = try JSONDecoder().decode(ProxyBackup.self, from: Data(contentsOf: url))
        #expect(saved.ownHost == "127.0.0.1")
        #expect(saved.ownPorts == [9092])
    }

    @Test func legacyBackupStillRestores() throws {
        let url = tempBackupURL(); defer { cleanup(url) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacy = [ServiceProxySnapshot(service: "Wi-Fi", web: clash, secureWeb: none, bypassDomains: bypass)]
        try JSONEncoder().encode(legacy).write(to: url)
        let runner = FakeRunner(services: [wifi(web: ProxyEndpoint(enabled: true, host: "localhost", port: 9095), secure: ours)])
        let controller = SystemProxyController(runner: runner, backupURL: url)
        #expect(try controller.originalSettings() == legacy)
        #expect(try controller.recoverIfNeeded() == .restored)
        #expect(runner.service("Wi-Fi")?.web == clash)
        #expect(runner.service("Wi-Fi")?.secure.enabled == false)
        #expect(!backupExists(url))
    }

    @Test func legacyBackupLeavesLoopbackOutsideTheDefaultRangeAlone() throws {
        let url = tempBackupURL(); defer { cleanup(url) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode([ServiceProxySnapshot(service: "Wi-Fi", web: none, secureWeb: none, bypassDomains: [])])
            .write(to: url)
        let runner = FakeRunner(services: [wifi()])  // Clash on 127.0.0.1:7897 is someone else
        #expect(try SystemProxyController(runner: runner, backupURL: url).recoverIfNeeded() == .restored)
        #expect(runner.setCalls.isEmpty)
        #expect(runner.service("Wi-Fi")?.web == clash)
        #expect(!backupExists(url))
    }

    @Test func sparseOwnedPortsLeaveIntermediateForeignProxyUntouched() throws {
        let url = tempBackupURL(); defer { cleanup(url) }
        let runner = FakeRunner(services: [wifi()])
        let controller = SystemProxyController(runner: runner, backupURL: url)
        try controller.enable(host: "127.0.0.1", port: 9090)
        try controller.enable(host: "127.0.0.1", port: 9190)
        let data = try Data(contentsOf: url)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["ownPorts"] as? [Int] == [9090, 9190])
        #expect(try ProxyBackup.decode(data).ownPorts == [9090, 9190])
        let foreign = ProxyEndpoint(enabled: true, host: "127.0.0.1", port: 9150)
        _ = try runner.networksetup(["-setwebproxy", "Wi-Fi", foreign.host, String(foreign.port)])
        runner.resetCalls()
        #expect(try controller.disable() == .restored)
        #expect(runner.service("Wi-Fi")?.web == foreign)
        #expect(runner.service("Wi-Fi")?.secure == clash)
        #expect(runner.setCalls == [["-setsecurewebproxy", "Wi-Fi", "127.0.0.1", "7897"]])
    }

    @Test func partialRestoreRetainsExactPortsForRecovery() throws {
        let url = tempBackupURL(); defer { cleanup(url) }
        let failRestore = OSAllocatedUnfairLock(initialState: false)
        let runner = FakeRunner(services: [wifi()], failure: { args in
            failRestore.withLock { $0 } && args[0] == "-setsecurewebproxy" && args.last == "7897"
                ? .failed("retry restore") : nil
        })
        let controller = SystemProxyController(runner: runner, backupURL: url)
        try controller.enable(host: "127.0.0.1", port: 9090)
        try controller.enable(host: "127.0.0.1", port: 9190)
        _ = try runner.networksetup(["-setwebproxy", "Wi-Fi", "localhost", "9150"])
        failRestore.withLock { $0 = true }
        #expect(throws: CommandError.failed("retry restore")) { try controller.disable() }
        let data = try Data(contentsOf: url)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["ownPorts"] as? [Int] == [9090, 9190])
        #expect(runner.service("Wi-Fi")?.web.port == 9150)
        failRestore.withLock { $0 = false }
        runner.resetCalls()
        #expect(try SystemProxyController(runner: runner, backupURL: url).recoverIfNeeded() == .restored)
        #expect(runner.service("Wi-Fi")?.web.port == 9150)
        #expect(runner.service("Wi-Fi")?.secure == clash)
        #expect(runner.setCalls == [["-setsecurewebproxy", "Wi-Fi", "127.0.0.1", "7897"]])
        #expect(!backupExists(url))
    }

    @Test func oldRangeObjectClaimsOnlyItsEndpoints() throws {
        let data = Data(#"{"ownHost":"127.0.0.1","ownPorts":{"lower":9090,"upper":9190},"services":[]}"#.utf8)
        let backup = try ProxyBackup.decode(data)
        #expect(backup.isOurs(ProxyEndpoint(enabled: true, host: "localhost", port: 9090)))
        #expect(backup.isOurs(ProxyEndpoint(enabled: true, host: "::1", port: 9190)))
        #expect(!backup.isOurs(ProxyEndpoint(enabled: true, host: "127.0.0.1", port: 9150)))
        #expect(!backup.isOurs(ProxyEndpoint(enabled: true, host: "10.0.0.1", port: 9190)))
        #expect(!backup.isOurs(ProxyEndpoint(enabled: false, host: "localhost", port: 9090)))
    }

    @Test func newPortSetDecodesBoundariesAndEncodesInSortedOrder() throws {
        let data = Data(#"{"ownHost":"127.0.0.1","ownPorts":[65535,9190,1,9090,9090],"services":[]}"#.utf8)
        let backup = try ProxyBackup.decode(data)
        #expect(backup.ownPorts == [1, 9090, 9190, 65535])
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(backup)) as? [String: Any])
        #expect(json["ownPorts"] as? [Int] == [1, 9090, 9190, 65535])
    }

    @Test func unreadableBackupIsRetainedWithoutCommands() throws {
        let url = tempBackupURL(); defer { cleanup(url) }
        // A directory is a deterministic unreadable backup fixture, even for privileged test users.
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let runner = FakeRunner(services: [wifi()])
        let controller = SystemProxyController(runner: runner, backupURL: url)
        #expect(throws: SystemProxyError.invalidBackup) { try controller.disable() }
        #expect(throws: SystemProxyError.invalidBackup) { try controller.originalSettings() }
        #expect(throws: SystemProxyError.invalidBackup) { try controller.enable(host: "127.0.0.1", port: 9090) }
        #expect(runner.calls.isEmpty)
        #expect(runner.privilegedBatches.isEmpty)
        #expect(backupExists(url))
    }

    @Test(arguments: ["[]", "[0]", "[-1,9090]", "[9090,65536]", "[9090,1.5]",
                      "{\"lower\":0,\"upper\":9090}", "{\"lower\":9090,\"upper\":65536}",
                      "{\"lower\":9090}"])
    func invalidPortBackupCannotBeDecoded(ports: String) {
        let data = Data("{\"ownHost\":\"127.0.0.1\",\"ownPorts\":\(ports),\"services\":[]}".utf8)
        #expect(throws: SystemProxyError.invalidBackup) { try ProxyBackup.decode(data) }
    }

    @Test(arguments: ["[9090,65536]", "{\"lower\":0,\"upper\":9099}", "not JSON"])
    func corruptBackupIsRetainedWithoutGuessingOwnership(ports: String) throws {
        let url = tempBackupURL(); defer { cleanup(url) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = ports == "not JSON" ? Data(ports.utf8)
            : Data("{\"ownHost\":\"127.0.0.1\",\"ownPorts\":\(ports),\"services\":[]}".utf8)
        try data.write(to: url)
        let foreign = ProxyEndpoint(enabled: true, host: "127.0.0.1", port: 9095)
        let runner = FakeRunner(services: [wifi(web: foreign, secure: foreign)])
        let controller = SystemProxyController(runner: runner, backupURL: url)
        #expect(throws: SystemProxyError.invalidBackup) { try controller.recoverIfNeeded() }
        #expect(runner.calls.isEmpty)
        #expect(runner.privilegedBatches.isEmpty)
        #expect(runner.service("Wi-Fi")?.web == foreign)
        #expect(runner.service("Wi-Fi")?.secure == foreign)
        #expect(backupExists(url))
        #expect(try Data(contentsOf: url) == data)
    }

    @Test(arguments: [-1, 0, 65536, Int.max])
    func invalidEnablePortDoesNotReadWriteOrApply(port: Int) throws {
        let url = tempBackupURL(); defer { cleanup(url) }
        let runner = FakeRunner(services: [wifi()])
        let controller = SystemProxyController(runner: runner, backupURL: url)
        #expect(throws: SystemProxyError.invalidPort(port)) { try controller.enable(host: "127.0.0.1", port: port) }
        #expect(runner.calls.isEmpty)
        #expect(!backupExists(url))
    }
}
