import FlowStore
import Foundation
import Testing

@testable import RulesEngine

private func conditions(
    enabled: Bool = true, global: NetworkSelection? = nil, rules: [HostNetworkRule] = []
) -> NetworkConditions {
    var value = NetworkConditions()
    value.enabled = enabled
    value.global = global
    value.hostRules = rules
    return value
}

private func hostRule(
    _ host: String, port: Int? = nil, enabled: Bool = true, _ preset: NetworkPreset = .threeG,
    id: UUID = UUID()
) -> HostNetworkRule {
    HostNetworkRule(id: id, enabled: enabled, hostPattern: host, port: port, selection: .preset(preset))
}

@Test func presetTableMatchesSpec() {
    #expect(NetworkPreset.allCases.count == 9)
    #expect(
        NetworkPreset.offline.profile
            == NetworkProfile(downloadKbps: nil, uploadKbps: nil, latencyMs: 0, lossPercent: 100))
    #expect(NetworkPreset.offline.profile.isOffline)
    #expect(
        NetworkPreset.veryBad.profile
            == NetworkProfile(downloadKbps: 500, uploadKbps: 500, latencyMs: 500, lossPercent: 10))
    #expect(
        NetworkPreset.slow.profile
            == NetworkProfile(downloadKbps: 5000, uploadKbps: 5000, latencyMs: 100, lossPercent: 1))
    #expect(
        NetworkPreset.medium.profile
            == NetworkProfile(downloadKbps: 10000, uploadKbps: 10000, latencyMs: 50, lossPercent: 0))
    #expect(
        NetworkPreset.edge.profile == NetworkProfile(downloadKbps: 240, uploadKbps: 200, latencyMs: 400, lossPercent: 0)
    )
    #expect(
        NetworkPreset.threeG.profile
            == NetworkProfile(downloadKbps: 780, uploadKbps: 300, latencyMs: 100, lossPercent: 0))
    #expect(
        NetworkPreset.lte.profile
            == NetworkProfile(downloadKbps: 40000, uploadKbps: 8000, latencyMs: 50, lossPercent: 0))
    #expect(
        NetworkPreset.wifi.profile
            == NetworkProfile(downloadKbps: 30000, uploadKbps: 20000, latencyMs: 10, lossPercent: 0))
    #expect(
        NetworkPreset.wifiAC.profile
            == NetworkProfile(downloadKbps: 200000, uploadKbps: 80000, latencyMs: 5, lossPercent: 0))
    for preset in NetworkPreset.allCases where preset != .offline {
        #expect(!preset.profile.isOffline)
    }
}

@Test func resolveDisabledIsNil() {
    let value = conditions(enabled: false, global: .preset(.threeG), rules: [hostRule("api.example.com", .lte)])
    #expect(value.resolve(host: "api.example.com", port: 443) == nil)
    #expect(!value.isActive)
}

@Test func resolveGlobalOnly() throws {
    let value = conditions(global: .preset(.threeG))
    let resolved = try #require(value.resolve(host: "any.test", port: 443))
    #expect(resolved.selection == .preset(.threeG))
    #expect(resolved.ruleID == nil)
    #expect(resolved.label == "preset.threeG")
    #expect(resolved.profile == NetworkPreset.threeG.profile)
    #expect(value.isActive)
    #expect(conditions().resolve(host: "any.test", port: 443) == nil)
    #expect(!conditions().isActive)
}

@Test func isActiveNeedsAnEnabledSelection() {
    #expect(conditions(global: .preset(.wifi)).isActive)
    #expect(conditions(rules: [hostRule("a.test")]).isActive)
    #expect(!conditions(rules: [hostRule("a.test", enabled: false)]).isActive)
}

@Test func firstMatchingHostRuleBeatsGlobalAndLaterRules() throws {
    let first = UUID()
    let second = UUID()
    let value = conditions(
        global: .preset(.wifi),
        rules: [hostRule("api.example.com", .edge, id: first), hostRule("api.example.com", .lte, id: second)])
    let matched = try #require(value.resolve(host: "api.example.com", port: 443))
    #expect(matched.ruleID == first)
    #expect(matched.label == "preset.edge")
    let other = try #require(value.resolve(host: "other.test", port: 443))
    #expect(other.ruleID == nil)
    #expect(other.label == "preset.wifi")
}

@Test func disabledAndPortMismatchedRulesAreSkipped() throws {
    let disabled = hostRule("a.test", enabled: false, .offline)
    let portOnly = hostRule("a.test", port: 8443, .veryBad)
    let anyPort = hostRule("a.test", .slow)
    let value = conditions(rules: [disabled, portOnly, anyPort])
    let defaultPort = try #require(value.resolve(host: "a.test", port: 443))
    #expect(defaultPort.ruleID == anyPort.id)
    #expect(defaultPort.label == "preset.slow")
    let altPort = try #require(value.resolve(host: "a.test", port: 8443))
    #expect(altPort.ruleID == portOnly.id)
}

@Test func wildcardHostRule() {
    let value = conditions(rules: [hostRule("*.example.com", .slow)])
    #expect(value.resolve(host: "a.example.com", port: 443)?.label == "preset.slow")
    #expect(value.resolve(host: "example.com", port: 443) == nil)
}

@Test func ipv6AndCaseSpellingsMatchRules() {
    let value = conditions(rules: [hostRule("[2001:DB8::1]", .slow)])
    #expect(value.resolve(host: "2001:db8:0::1", port: 443)?.label == "preset.slow")
    #expect(value.resolve(host: "2001:db8:0::2", port: 443) == nil)
}

@Test func profileValidationBoundaries() {
    func profile(
        down: Int? = 1, up: Int? = 1, latency: Int = 0, loss: Double = 0
    ) -> NetworkProfile {
        NetworkProfile(downloadKbps: down, uploadKbps: up, latencyMs: latency, lossPercent: loss)
    }
    #expect(profile().problem == nil)
    #expect(profile(down: nil, up: nil).problem == nil)
    #expect(profile(down: 1_000_000, up: 1_000_000, latency: 10_000, loss: 100).problem == nil)
    #expect(profile(down: 0).problem == .downloadOutOfRange)
    #expect(profile(down: 1_000_001).problem == .downloadOutOfRange)
    #expect(profile(up: 0).problem == .uploadOutOfRange)
    #expect(profile(up: 1_000_001).problem == .uploadOutOfRange)
    #expect(profile(latency: -1).problem == .latencyOutOfRange)
    #expect(profile(latency: 10_001).problem == .latencyOutOfRange)
    #expect(profile(loss: -0.1).problem == .lossOutOfRange)
    #expect(profile(loss: 100.1).problem == .lossOutOfRange)
}

@Test func codableRoundTripWithAssociatedValues() throws {
    let custom = NetworkProfile(downloadKbps: 1234, uploadKbps: nil, latencyMs: 42, lossPercent: 2.5)
    let rule = hostRule("*.example.com", port: 443, .lte)
    let value = conditions(global: .custom(custom), rules: [rule])
    let data = try JSONEncoder().encode(value)
    let decoded = try JSONDecoder().decode(NetworkConditions.self, from: data)
    #expect(decoded == value)
    #expect(decoded.global?.label == "custom")
    #expect(decoded.hostRules.first?.selection == .preset(.lte))

    let presetData = try JSONEncoder().encode(NetworkSelection.preset(.offline))
    #expect(try JSONDecoder().decode(NetworkSelection.self, from: presetData) == .preset(.offline))
}

@Test func defaultDecodesFromEmptyObject() throws {
    let empty = Data("{}".utf8)
    #expect(try JSONDecoder().decode(NetworkConditions.self, from: empty) == NetworkConditions())
    #expect(
        try JSONDecoder().decode(NetworkProfile.self, from: empty)
            == NetworkProfile(downloadKbps: nil, uploadKbps: nil, latencyMs: 0, lossPercent: 0))
}
