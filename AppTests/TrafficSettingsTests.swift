import AppCore
import Foundation
import MCPKit
import RulesEngine
import Testing
@testable import ProxyWoman

@MainActor @Suite(.productionChinese) struct TrafficSettingsTests {
    private func sample() -> TrafficPolicy {
        var policy = TrafficPolicy()
        policy.allowEnabled = true
        policy.allowEntries = [TrafficFilterEntry(matcher: RuleMatcher(hostPattern: "a.com", port: 443))]
        policy.blockEnabled = true
        policy.blockMode = .hide
        policy.blockEntries = [
            TrafficFilterEntry(enabled: false, matcher: RuleMatcher(scheme: "https", hostPattern: "b.com", method: "POST", path: .prefix("/x")))
        ]
        policy.conditions.global = .preset(.lte)
        policy.conditions.hostRules = [
            HostNetworkRule(hostPattern: "c.com", port: 80, selection: .custom(
                NetworkProfile(downloadKbps: 100, uploadKbps: nil, latencyMs: 20, lossPercent: 1.5)))
        ]
        return policy
    }

    @Test func defaultsWhenNothingIsStored() {
        let settings = AppSettings(defaults: InMemorySettingsStorage())
        #expect(settings.trafficPolicy == TrafficPolicy())
    }

    @Test func trafficPolicyRoundTripsThroughInMemoryStorage() {
        let storage = InMemorySettingsStorage()
        let first = AppSettings(defaults: storage)
        let policy = sample()
        first.trafficPolicy = policy
        #expect(storage.data(forKey: "trafficPolicy") != nil)

        let second = AppSettings(defaults: storage)
        #expect(second.trafficPolicy == policy)
    }

    @Test func missingKeysTakeDefaults() {
        let storage = InMemorySettingsStorage()
        storage.set(Data(#"{"allowEnabled":true}"#.utf8), forKey: "trafficPolicy")
        let settings = AppSettings(defaults: storage)
        var expected = TrafficPolicy()
        expected.allowEnabled = true
        #expect(settings.trafficPolicy == expected)
    }

    @Test(arguments: [
        "not json",
        #"{"allowEntries":[{"enabled":true}]}"#,
        #"{"conditions":{"global":{"preset":{"_0":"nope"}}}}"#,
        #"{"blockMode":"sideways"}"#,
        "[]",
    ])
    func corruptDataFallsBackToDefaults(_ text: String) {
        let storage = InMemorySettingsStorage()
        storage.set(Data(text.utf8), forKey: "trafficPolicy")
        let settings = AppSettings(defaults: storage)
        #expect(settings.trafficPolicy == TrafficPolicy())
        #expect(settings.trafficPolicy.allowEntries.isEmpty && settings.trafficPolicy.blockEntries.isEmpty)
    }

    @Test func restoredPolicyThatFailsValidationFallsBackToDefaults() {
        var invalid = TrafficPolicy()
        invalid.allowEntries = [TrafficFilterEntry(matcher: RuleMatcher(hostPattern: "not a host"))]
        let storage = InMemorySettingsStorage()
        storage.set(try? JSONEncoder().encode(invalid), forKey: "trafficPolicy")
        #expect(AppSettings(defaults: storage).trafficPolicy == TrafficPolicy())
    }

    // MARK: advanced entries and older builds

    private func advancedPolicy() -> TrafficPolicy {
        var policy = sample()
        policy.blockEntries.append(TrafficFilterEntry(matcher: RuleMatcher(hostPattern: #"ads\..*"#, hostSyntax: .regex)))
        policy.allowEntries.append(TrafficFilterEntry(matcher: RuleMatcher(hostPattern: "api-*.example.com", hostSyntax: .wildcard)))
        return policy
    }

    @Test func advancedEntriesAreKeptOutOfTheKeyAnOlderBuildReads() throws {
        let storage = InMemorySettingsStorage()
        let settings = AppSettings(defaults: storage)
        let policy = advancedPolicy()
        settings.trafficPolicy = policy
        let legacy = try #require(storage.data(forKey: "trafficPolicy"))
        let text = String(decoding: legacy, as: UTF8.self)
        #expect(!text.contains("hostSyntax") && !text.contains("api-*") && !text.contains("ads"))
        #expect(storage.data(forKey: "trafficPolicy.extended") != nil)
        #expect(AppSettings(defaults: storage).trafficPolicy == policy)
    }

    @Test func anOlderBuildResettingItsPolicyDoesNotLoseAdvancedEntries() throws {
        let storage = InMemorySettingsStorage()
        let policy = advancedPolicy()
        AppSettings(defaults: storage).trafficPolicy = policy
        // What an older build does when it cannot read the entries: default policy, written back.
        storage.set(try JSONEncoder().encode(TrafficPolicy()), forKey: "trafficPolicy")
        #expect(AppSettings(defaults: storage).trafficPolicy == policy)
    }

    @Test func noExtendedValueIsWrittenWithoutAdvancedEntriesAndItIsRemovedWhenTheLastOneGoes() {
        let storage = InMemorySettingsStorage()
        let settings = AppSettings(defaults: storage)
        settings.trafficPolicy = sample()
        #expect(storage.data(forKey: "trafficPolicy.extended") == nil)
        settings.trafficPolicy = advancedPolicy()
        #expect(storage.data(forKey: "trafficPolicy.extended") != nil)
        settings.trafficPolicy = sample()
        #expect(storage.data(forKey: "trafficPolicy.extended") == nil)
    }

    @Test func aNewerExtendedValueIsLeftUntouched() throws {
        let storage = InMemorySettingsStorage()
        let newer = Data(#"{"schemaVersion":3,"policy":{"future":true}}"#.utf8)
        storage.set(newer, forKey: "trafficPolicy.extended")
        let stored = sample()
        storage.set(try JSONEncoder().encode(stored), forKey: "trafficPolicy")
        let settings = AppSettings(defaults: storage)
        #expect(settings.trafficPolicy == stored)
        settings.trafficPolicy = advancedPolicy()
        settings.trafficPolicy = TrafficPolicy()
        #expect(storage.data(forKey: "trafficPolicy.extended") == newer)
        #expect(storage.data(forKey: "trafficPolicy") != nil)
    }

    // MARK: MCP settings

    @Test func settingsDefaultToMCPOff() {
        let storage = InMemorySettingsStorage()
        let settings = AppSettings(defaults: storage)
        #expect(settings.mcp == MCPSettings())
        #expect(!settings.mcp.enabled && settings.mcp.writeTools.isEmpty && !settings.mcp.allowEnablingRules)
        #expect(settings.mcp.redaction.enabled && settings.mcp.redaction.extraNames.isEmpty)
        #expect(storage.data(forKey: "mcp") == nil, "reading the defaults writes nothing")
    }

    @Test func mcpSettingsRoundTripThroughInMemoryStorage() {
        let storage = InMemorySettingsStorage()
        let first = AppSettings(defaults: storage)
        var mcp = MCPSettings()
        mcp.enabled = true
        mcp.writeTools = [.createRule, .setRecording]
        mcp.allowEnablingRules = true
        mcp.redaction = MCPRedactionSettings(enabled: false, extraNames: ["x-session", "otp"])
        first.mcp = mcp
        #expect(storage.data(forKey: "mcp") != nil)
        #expect(AppSettings(defaults: storage).mcp == mcp)
        // Changing it again is stored again.
        first.mcp.enabled = false
        #expect(AppSettings(defaults: storage).mcp.enabled == false)
        #expect(AppSettings(defaults: storage).mcp.writeTools == [.createRule, .setRecording])
    }

    @Test(arguments: ["not json", "[]", "42", "\"on\"", #"{"enabled":"yes","writeTools":7,"redaction":[]}"#])
    func corruptStoredMCPSettingsFallBackToDefaults(_ text: String) {
        let storage = InMemorySettingsStorage()
        storage.set(Data(text.utf8), forKey: "mcp")
        #expect(AppSettings(defaults: storage).mcp == MCPSettings())
        storage.set("not data", forKey: "mcp")
        #expect(AppSettings(defaults: storage).mcp == MCPSettings())
    }

    @Test func missingKeysOfStoredMCPSettingsTakeDefaults() {
        let storage = InMemorySettingsStorage()
        storage.set(Data(#"{"enabled":true,"writeTools":["create_rule","fly_to_moon"]}"#.utf8), forKey: "mcp")
        var expected = MCPSettings()
        expected.enabled = true
        expected.writeTools = [.createRule]
        #expect(AppSettings(defaults: storage).mcp == expected)
    }

    @Test func isolatedLaunchStartsWithMCPOff() throws {
        let base = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("mcs-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        let root = base.appendingPathComponent("root", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        defer { try? FileManager.default.removeItem(at: base) }
        let runtime = try AppRuntime.resolve(
            arguments: ["/app", IsolatedLaunch.rootArgument, root.path], environment: ["CFFIXED_USER_HOME": home.path],
            bundleIdentifier: "dev.pwapp.mac.p7-copy", temporaryDirectories: [base], home: home)
        #expect(runtime.isolated != nil)
        // Even a value an earlier session left in the process-wide defaults cannot reach an isolated run:
        // the run's settings are its own in-memory storage.
        let settings = AppSettings(defaults: runtime.settingsStorage)
        #expect(settings.mcp == MCPSettings())
        #expect(!settings.mcp.enabled)
        settings.mcp.enabled = true
        #expect(runtime.settingsStorage.data(forKey: "mcp") != nil)
    }
}
