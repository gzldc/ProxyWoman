import Foundation
import Testing

@testable import MCPKit

@Suite struct MCPSettingsTests {
    private func decode(_ json: String) throws -> MCPSettings {
        try JSONDecoder().decode(MCPSettings.self, from: Data(json.utf8))
    }

    @Test func defaultsAreAllOff() {
        let settings = MCPSettings()
        #expect(settings.enabled == false)
        #expect(settings.writeTools.isEmpty)
        #expect(settings.allowEnablingRules == false)
        #expect(settings.redaction.enabled == true)
        #expect(settings.redaction.extraNames.isEmpty)
    }

    @Test func decodesEmptyObjectToDefaults() throws {
        #expect(try decode("{}") == MCPSettings())
        #expect(try decode("[]") == MCPSettings())
        #expect(try decode("null") == MCPSettings())
    }

    @Test func ignoresUnknownWriteToolsAndBadTypes() throws {
        let settings = try decode(
            """
            {"enabled":true,"writeTools":["create_rule","bogus",7,"set_recording"],
             "allowEnablingRules":"yes","redaction":{"enabled":false,"extraNames":"nope"},"extra":1}
            """)
        #expect(settings.enabled == true)
        #expect(settings.writeTools == [.createRule, .setRecording])
        #expect(settings.allowEnablingRules == false)
        #expect(settings.redaction.enabled == false)
        #expect(settings.redaction.extraNames.isEmpty)

        let badShapes = try decode(#"{"enabled":3,"writeTools":"create_rule","redaction":[]}"#)
        #expect(badShapes == MCPSettings())
    }

    @Test func roundTrips() throws {
        var settings = MCPSettings()
        settings.enabled = true
        settings.writeTools = Set(MCPWriteTool.allCases)
        settings.allowEnablingRules = true
        settings.redaction = MCPRedactionSettings(enabled: false, extraNames: ["X-Mine", "pin"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(settings)
        #expect(try JSONDecoder().decode(MCPSettings.self, from: data) == settings)
        #expect(try encoder.encode(settings) == data)  // stable array order
    }

    @Test func writeToolRawValues() {
        #expect(MCPWriteTool.allCases.map(\.rawValue) == ["create_rule", "update_rule", "set_rule_enabled", "set_recording"])
    }

    @Test func extraNamesNormalize() {
        let long = String(repeating: "a", count: MCPRedactionSettings.maxNameLength)
        let tooLong = String(repeating: "b", count: MCPRedactionSettings.maxNameLength + 1)
        let settings = MCPRedactionSettings(
            enabled: true, extraNames: ["  Foo ", "foo", "FOO", "", "   ", "Bar\n", tooLong, long])
        #expect(settings.normalizedExtraNames() == ["foo", "bar", long])

        let many = (0..<33).map { "name\($0)" }
        let capped = MCPRedactionSettings(enabled: true, extraNames: many).normalizedExtraNames()
        #expect(capped.count == MCPRedactionSettings.maxExtraNames)
        #expect(capped == Array(many.prefix(32)))
    }

    @Test func policyProviderReturnsLatestSnapshot() {
        let provider = MCPPolicyProvider()
        #expect(provider.current == MCPSettings())
        var next = MCPSettings()
        next.enabled = true
        provider.update(next)
        #expect(provider.current == next)
    }
}
