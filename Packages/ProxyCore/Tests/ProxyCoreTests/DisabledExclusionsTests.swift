import Foundation
import Testing

@testable import ProxyCore

@Suite(.productionChinese) struct DisabledExclusionsTests {
    @Test func disabledWildcardIsPersistedButDoesNotExclude() throws {
        let json =
            #"{"enabled":true,"excludedHosts":["*.example.com","other.com"],"disabledExcludedHosts":["*.example.com"]}"#
        let policy = try JSONDecoder().decode(DecryptionPolicy.self, from: Data(json.utf8))
        #expect(policy.shouldDecrypt("api.example.com"))
        #expect(!policy.shouldDecrypt("other.com"))
        let restored = try JSONDecoder().decode(DecryptionPolicy.self, from: JSONEncoder().encode(policy))
        #expect(restored.shouldDecrypt("api.example.com"))
    }

    @Test func oldPreferencesKeepTheirActiveExclusions() throws {
        let json = #"{"enabled":true,"excludedHosts":["*.example.com"]}"#
        let policy = try JSONDecoder().decode(DecryptionPolicy.self, from: Data(json.utf8))
        #expect(!policy.shouldDecrypt("api.example.com"))
    }

    @Test func disablingOneRuleDoesNotDisableOverlappingRules() throws {
        let json =
            #"{"enabled":true,"excludedHosts":["*.example.com","api.example.com"],"disabledExcludedHosts":["*.example.com"]}"#
        let policy = try JSONDecoder().decode(DecryptionPolicy.self, from: Data(json.utf8))
        #expect(!policy.shouldDecrypt("api.example.com"))
        #expect(policy.shouldDecrypt("web.example.com"))
    }
}

@Suite(.productionChinese) struct DisabledExclusionActionTests {
    @Test func enableActionCleansDisabledMatchingRulesAndPassthrough() {
        var policy = DecryptionPolicy(
            enabled: false, excludedHosts: ["*.example.com", "other.com"],
            disabledExcludedHosts: ["*.example.com", "other.com"])
        let registry = PassthroughRegistry(hosts: ["api.example.com"])
        policy.enableDecryption(for: "api.example.com", passthrough: registry)
        #expect(policy.disabledExcludedHosts == ["other.com"])
        #expect(policy.excludedHosts == ["other.com"])
        #expect(policy.shouldDecrypt("api.example.com"))
        #expect(!registry.contains("api.example.com"))
    }
}

@Suite(.productionChinese) struct ActiveExactExclusionTests {
    @Test func uncheckedExactRuleDoesNotChooseEnableAction() {
        let policy = DecryptionPolicy(excludedHosts: ["example.com"], disabledExcludedHosts: ["example.com"])
        #expect(policy.shouldDecrypt("example.com"))
        #expect(!policy.hasActiveExactExclusion(for: "example.com"))
    }

    @Test func activeExactRuleUsesHostNormalization() {
        let policy = DecryptionPolicy(excludedHosts: [" Example.COM. ", "[::1]"])
        #expect(policy.hasActiveExactExclusion(for: "example.com"))
        #expect(policy.hasActiveExactExclusion(for: "::1"))
        #expect(!policy.hasActiveExactExclusion(for: "other.com"))
    }

    @Test func wildcardRemainsOutsideExactMenuQuery() {
        let policy = DecryptionPolicy(excludedHosts: ["*.example.com", "*"])
        #expect(!policy.shouldDecrypt("api.example.com"))
        #expect(!policy.hasActiveExactExclusion(for: "api.example.com"))
    }
}
