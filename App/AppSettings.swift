import AppCore
import Foundation
import MCPKit
import Observation
import ProxyCore
import RulesEngine

/// User preferences, persisted on every change (in `UserDefaults` unless the launch is isolated).
@MainActor @Observable final class AppSettings {
    private enum Key {
        static let port = "port"
        static let decryption = "decryption"
        static let passthroughHosts = "passthroughHosts"
        static let preferences = "preferences"
        static let trafficPolicy = "trafficPolicy"
        /// The whole policy including wildcard and regular-expression entries; see `TrafficPolicyStorage`.
        static let trafficPolicyExtended = "trafficPolicy.extended"
        /// The MCP server settings (`MCPSettings`) as one JSON value; absent or unreadable means all off.
        static let mcp = "mcp"
        /// The main window's one-time banner about the rules upgrade notice was closed.
        static let rulesUpgradeBannerDismissed = "rulesUpgradeBannerDismissed"
        /// One-shot: when the last restart began (seconds since 1970) with the system proxy on.
        static let resumeSystemProxyAfterRestart = "resumeSystemProxyAfterRestart"
    }

    /// How long after a restart began its one-shot "turn the system proxy back on" mark is still honored.
    /// A relaunch that never happened must not switch the system proxy on at some later start.
    nonisolated static let restartResumeWindow: TimeInterval = 120

    @ObservationIgnored private let defaults: any SettingsStorage

    var port: Int {
        didSet { defaults.set(port, forKey: Key.port) }
    }

    var decryption: DecryptionPolicy {
        didSet {
            if let data = try? JSONEncoder().encode(decryption) {
                defaults.set(data, forKey: Key.decryption)
            }
        }
    }

    var passthroughHosts: Set<String> {
        didSet { defaults.set(passthroughHosts.sorted(), forKey: Key.passthroughHosts) }
    }

    /// 界面偏好，整体以 JSON 存在 `preferences` 键下；视图通过 `@Bindable` 绑定其字段。
    var preferences: Preferences {
        didSet {
            if let data = try? JSONEncoder().encode(preferences) {
                defaults.set(data, forKey: Key.preferences)
            }
        }
    }

    /// The traffic tools (Allow/Block lists, No Caching, Network Conditions), as one JSON value.
    /// Data that cannot be read back, or that no longer validates, becomes the default policy
    /// (every tool off, lists empty) rather than reaching the proxy.
    ///
    /// Entries with wildcard or regular-expression syntax are not written to the main value, which
    /// an older build also reads (and would misread and then overwrite); they go to a second value
    /// with a schema version (`TrafficPolicyStorage`).
    var trafficPolicy: TrafficPolicy {
        didSet {
            let encoded = TrafficPolicyStorage.encode(trafficPolicy)
            if let data = encoded.legacy { defaults.set(data, forKey: Key.trafficPolicy) }
            // A value from a newer schema is not ours to replace or delete.
            if !keepsNewerTrafficPolicy { defaults.set(encoded.extended, forKey: Key.trafficPolicyExtended) }
        }
    }

    @ObservationIgnored private var keepsNewerTrafficPolicy = false

    /// The MCP server: the master switch, which write tools the user allowed, and the redaction choices.
    /// Stored data that cannot be read back gives the defaults (everything off, redaction on).
    var mcp: MCPSettings {
        didSet {
            if let data = try? JSONEncoder().encode(mcp) { defaults.set(data, forKey: Key.mcp) }
        }
    }

    /// The user closed the main window's banner that points to the rules upgrade notice. Whether the notice
    /// itself was read is kept in the rules file; this only keeps the banner closed (in memory only in an
    /// isolated launch, like every setting).
    var rulesUpgradeBannerDismissed: Bool {
        didSet { defaults.set(rulesUpgradeBannerDismissed, forKey: Key.rulesUpgradeBannerDismissed) }
    }

    /// A restart is about to begin: remembers (`on`) or forgets that the system proxy was on, so the next
    /// launch can turn it back on. Not an observable preference; it lives for one restart only.
    func markResumeSystemProxyAfterRestart(_ on: Bool, now: Date = Date()) {
        defaults.set(on ? Int(now.timeIntervalSince1970) : nil, forKey: Key.resumeSystemProxyAfterRestart)
    }

    /// Reads and clears the mark: true at most once, and only shortly after the restart began.
    func takeResumeSystemProxyAfterRestart(now: Date = Date()) -> Bool {
        let started = defaults.integer(forKey: Key.resumeSystemProxyAfterRestart)
        guard started != 0 else { return false }
        defaults.set(nil, forKey: Key.resumeSystemProxyAfterRestart)
        let age = now.timeIntervalSince1970 - TimeInterval(started)
        return age >= -5 && age <= Self.restartResumeWindow
    }

    init(defaults: any SettingsStorage = UserDefaults.standard) {
        self.defaults = defaults
        let storedPort = defaults.integer(forKey: Key.port)
        port = (1...65535).contains(storedPort) ? storedPort : AppInfo.defaultPort
        decryption =
            defaults.data(forKey: Key.decryption)
            .flatMap { try? JSONDecoder().decode(DecryptionPolicy.self, from: $0) }
            ?? DecryptionPolicy()
        passthroughHosts = Set(defaults.stringArray(forKey: Key.passthroughHosts) ?? [])
        preferences =
            defaults.data(forKey: Key.preferences)
            .flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) }
            ?? Preferences()
        let storedPolicy = TrafficPolicyStorage.load(
            legacy: defaults.data(forKey: Key.trafficPolicy), extended: defaults.data(forKey: Key.trafficPolicyExtended))
        keepsNewerTrafficPolicy = storedPolicy.keepsExtended
        trafficPolicy = storedPolicy.policy
        mcp = defaults.data(forKey: Key.mcp).flatMap { try? JSONDecoder().decode(MCPSettings.self, from: $0) } ?? MCPSettings()
        rulesUpgradeBannerDismissed = defaults.bool(forKey: Key.rulesUpgradeBannerDismissed)
    }
}
