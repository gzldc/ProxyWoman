import Foundation
import Testing

@testable import RulesEngine

/// How the Allow/Block lists are stored so that an older build, which knows nothing about
/// wildcard or regular-expression entries, can neither misread them nor destroy them.
@Suite("TrafficPolicyStorage")
struct TrafficPolicyStorageTests {
    private let literal = TrafficFilterEntry(matcher: RuleMatcher(hostPattern: "a.test"))
    private let wildcard = TrafficFilterEntry(matcher: RuleMatcher(hostPattern: "*.ads.test", hostSyntax: .wildcard))
    private let regex = TrafficFilterEntry(matcher: RuleMatcher(hostPattern: "x", path: .regex("/ads/.*")))

    private func policy(allow: [TrafficFilterEntry] = [], block: [TrafficFilterEntry] = []) -> TrafficPolicy {
        var policy = TrafficPolicy()
        policy.allowEnabled = !allow.isEmpty
        policy.allowEntries = allow
        policy.blockEnabled = !block.isEmpty
        policy.blockEntries = block
        return policy
    }

    @Test func aPolicyWithoutAdvancedEntriesIsStoredExactlyAsBefore() throws {
        let plain = policy(allow: [literal], block: [TrafficFilterEntry(matcher: RuleMatcher(hostPattern: "b.test", method: "POST"))])
        let encoded = TrafficPolicyStorage.encode(plain)
        // Same encoder, same value as before this change (JSON key order is not fixed by Foundation, so
        // compare what the bytes say, not their order).
        let stored = try #require(encoded.legacy)
        #expect(try JSONDecoder().decode(TrafficPolicy.self, from: stored) == plain)
        #expect(try JSONSerialization.jsonObject(with: stored) as? NSDictionary
                == (try JSONSerialization.jsonObject(with: try JSONEncoder().encode(plain)) as? NSDictionary))
        #expect(encoded.extended == nil)
        let loaded = TrafficPolicyStorage.load(legacy: encoded.legacy, extended: nil)
        #expect(loaded.policy == plain && !loaded.keepsExtended)
    }

    @Test func advancedEntriesGoToTheExtendedValueAndTheOldKeyKeepsTheLiteralSubset() throws {
        var full = policy(allow: [literal, wildcard], block: [regex])
        full.noCaching = true
        let encoded = TrafficPolicyStorage.encode(full)
        let legacy = try JSONDecoder().decode(TrafficPolicy.self, from: try #require(encoded.legacy))
        #expect(legacy.allowEntries == [literal])
        #expect(legacy.blockEntries.isEmpty)
        #expect(legacy.noCaching && legacy.allowEnabled && legacy.blockEnabled, "the switches stay")
        #expect((try? legacy.validate()) != nil, "what an older build reads is valid for it")
        let legacyText = String(decoding: try #require(encoded.legacy), as: UTF8.self)
        #expect(!legacyText.contains("hostSyntax") && !legacyText.contains("regex") && !legacyText.contains("wildcard"))
        let extended = String(decoding: try #require(encoded.extended), as: UTF8.self)
        #expect(extended.contains("\"schemaVersion\":2"))
        let loaded = TrafficPolicyStorage.load(legacy: encoded.legacy, extended: encoded.extended)
        #expect(loaded.policy == full && !loaded.keepsExtended)
    }

    @Test func editsMadeByAnOlderBuildAreKeptAndTheAdvancedEntriesAreNotLost() throws {
        let full = policy(allow: [literal, wildcard], block: [regex])
        let stored = TrafficPolicyStorage.encode(full)
        // An older build reads its key, the user adds a block entry and turns No Caching on there.
        var older = try JSONDecoder().decode(TrafficPolicy.self, from: try #require(stored.legacy))
        let added = TrafficFilterEntry(matcher: RuleMatcher(hostPattern: "new.test"))
        older.blockEntries.append(added)
        older.noCaching = true
        let loaded = TrafficPolicyStorage.load(legacy: try JSONEncoder().encode(older), extended: stored.extended)
        #expect(loaded.policy.allowEntries == [literal, wildcard])
        #expect(Set(loaded.policy.blockEntries) == [added, regex])
        #expect(loaded.policy.noCaching)
        #expect(loaded.policy.blockEnabled)
    }

    @Test func aLiteralEntryRemovedByAnOlderBuildStaysRemoved() throws {
        let full = policy(allow: [literal, wildcard])
        let stored = TrafficPolicyStorage.encode(full)
        var older = try JSONDecoder().decode(TrafficPolicy.self, from: try #require(stored.legacy))
        older.allowEntries = []
        let loaded = TrafficPolicyStorage.load(legacy: try JSONEncoder().encode(older), extended: stored.extended)
        #expect(loaded.policy.allowEntries == [wildcard])
    }

    @Test func anOlderBuildThatResetItsPolicyDoesNotTakeTheNewerEntriesWithIt() throws {
        var full = policy(allow: [literal, wildcard], block: [regex])
        full.noCaching = true
        let stored = TrafficPolicyStorage.encode(full)
        let reset = try JSONEncoder().encode(TrafficPolicy())  // what the older build writes after failing to read
        // Unreadable or default legacy data next to a good extended value: the extended value is the
        // last complete state and wins as a whole, switches and literal entries included.
        for legacy in [reset, Data("garbage".utf8), nil] {
            let loaded = TrafficPolicyStorage.load(legacy: legacy, extended: stored.extended)
            #expect(loaded.policy == full, "\(String(describing: legacy))")
        }
    }

    @Test func aNewerSchemaIsNeverOverwrittenAndNeverUsed() throws {
        let newer = Data(#"{"schemaVersion":3,"policy":{"allowEnabled":true,"somethingNew":1}}"#.utf8)
        let legacy = try JSONEncoder().encode(policy(allow: [literal]))
        let loaded = TrafficPolicyStorage.load(legacy: legacy, extended: newer)
        #expect(loaded.keepsExtended)
        #expect(loaded.policy.allowEntries == [literal], "the readable literal subset still works")
    }

    @Test func anUnreadableExtendedValueIsIgnoredAndMayBeReplaced() throws {
        let legacy = try JSONEncoder().encode(policy(allow: [literal]))
        for bad in ["garbage", #"{"schemaVersion":2}"#, #"{"schemaVersion":2,"policy":{"blockMode":"sideways"}}"#, "[]"] {
            let loaded = TrafficPolicyStorage.load(legacy: legacy, extended: Data(bad.utf8))
            #expect(loaded.policy.allowEntries == [literal], "\(bad)")
            #expect(!loaded.keepsExtended, "\(bad)")
        }
    }

    @Test func mergeThatWouldBeInvalidFallsBackToTheLegacyPolicy() throws {
        let advanced = (0..<TrafficPolicy.maxEntries).map { _ in
            TrafficFilterEntry(matcher: RuleMatcher(hostPattern: "*.t", hostSyntax: .wildcard))
        }
        let stored = TrafficPolicyStorage.encode(policy(allow: advanced))
        var older = TrafficPolicy()
        older.allowEntries = [literal]
        let loaded = TrafficPolicyStorage.load(legacy: try JSONEncoder().encode(older), extended: stored.extended)
        #expect(loaded.policy.allowEntries == [literal])
        #expect((try? loaded.policy.validate()) != nil)
    }

    @Test func nothingStoredGivesTheDefaultPolicy() {
        #expect(TrafficPolicyStorage.load(legacy: nil, extended: nil) == .init(policy: TrafficPolicy(), keepsExtended: false))
        #expect(TrafficPolicyStorage.load(legacy: Data("x".utf8), extended: nil).policy == TrafficPolicy())
    }
}
