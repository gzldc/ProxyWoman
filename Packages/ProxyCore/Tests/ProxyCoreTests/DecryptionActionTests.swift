import Testing

@testable import ProxyCore

@Suite(.productionChinese) struct DecryptionActionTests {
    @Test func enablingHostClearsBothBarriersAndPreservesUnrelatedRules() {
        var policy = DecryptionPolicy(excludedHosts: ["*.example.com", "other.com"])
        let passthrough = PassthroughRegistry(hosts: ["api.example.com", "other.com"])
        policy.enableDecryption(for: "API.EXAMPLE.COM.", passthrough: passthrough)
        #expect(policy.shouldDecrypt("api.example.com"))
        #expect(!passthrough.contains("api.example.com"))
        #expect(!policy.shouldDecrypt("other.com"))
        #expect(passthrough.contains("other.com"))
    }

    @Test func enablingHostAlsoEnablesTheGlobalPolicy() {
        var policy = DecryptionPolicy(enabled: false)
        policy.enableDecryption(for: "example.com", passthrough: PassthroughRegistry())
        #expect(policy.shouldDecrypt("example.com"))
    }
}
