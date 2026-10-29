import AppCore
import Foundation
import ProxyCore
import SystemProxy
import Testing

@testable import ProxyWoman

/// The upstream the proxy chains through for each choice in Upstream Proxy Settings.
@MainActor @Suite(.productionChinese) struct UpstreamChoiceTests {
    private let clash = ProxyEndpoint(enabled: true, host: "127.0.0.1", port: 7897)
    private var original: [ServiceProxySnapshot] {
        [ServiceProxySnapshot(service: "Wi-Fi", web: clash, secureWeb: clash, bypassDomains: ["*.local"])]
    }

    @Test func automaticFollowsTheOriginalSystemProxy() {
        let upstream = AppModel.upstreamProxy(for: Preferences(), original: original, ownPorts: 9090...9090)
        #expect(upstream == UpstreamProxy(host: "127.0.0.1", port: 7897, bypass: ["*.local"]))
        #expect(AppModel.upstreamDescription(upstream, preferences: Preferences(), originalKnown: true).contains("7897"))
    }

    @Test func manualUsesTheEnteredProxyAndIgnoresTheOriginal() {
        var preferences = Preferences()
        preferences.upstreamMode = .manual
        preferences.manualUpstream = ManualUpstream(host: " 10.0.0.2 ", port: 3128, bypass: ["intranet.example"])
        let upstream = AppModel.upstreamProxy(for: preferences, original: original, ownPorts: 9090...9090)
        #expect(upstream == UpstreamProxy(host: "10.0.0.2", port: 3128, bypass: ["intranet.example"]))
        #expect(AppModel.upstreamDescription(upstream, preferences: preferences, originalKnown: true) == "10.0.0.2:3128（手动设置）")
    }

    @Test func anIncompleteManualProxyGoesDirect() {
        var preferences = Preferences()
        preferences.upstreamMode = .manual
        preferences.manualUpstream = ManualUpstream(host: "", port: 3128)
        let upstream = AppModel.upstreamProxy(for: preferences, original: original, ownPorts: 9090...9090)
        #expect(upstream == nil)
        #expect(AppModel.upstreamDescription(upstream, preferences: preferences, originalKnown: true) == "手动上游代理未填写完整，当前直连")
    }

    @Test func directNeverChains() {
        var preferences = Preferences()
        preferences.upstreamMode = .direct
        #expect(AppModel.upstreamProxy(for: preferences, original: original, ownPorts: 9090...9090) == nil)
    }

    @Test func preferencesWithoutTheNewKeysDecodeToTheDefaults() throws {
        let decoded = try JSONDecoder().decode(Preferences.self, from: Data(#"{"theme":"dark"}"#.utf8))
        #expect(decoded.upstreamMode == .automatic && !decoded.allowLANDevices && decoded.systemBypassDomains.isEmpty)
        var changed = Preferences()
        changed.allowLANDevices = true
        changed.systemBypassDomains = ["*.apple.com"]
        let roundTrip = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(changed))
        #expect(roundTrip == changed)
    }
}
