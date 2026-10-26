import Foundation
import Testing
@testable import RulesEngine

/// Phase fix I2d: the global rules switch is a provider-level flag; it never deletes or rewrites
/// the published rules.
struct RuleSnapshotProviderTests {
    private static func snapshot(_ revision: UInt64) -> RuleSnapshot {
        RuleSnapshot(revision: revision, rules: [Rule(
            id: UUID(), name: "r", enabled: true, order: 0, matcher: RuleMatcher(),
            action: .editHeaders(direction: .request, operations: [.set(name: "X", value: "1")]))])
    }

    @Test func switchedOffProviderOffersNoActiveSnapshotButKeepsThePublishedOne() {
        let provider = RuleSnapshotProvider(Self.snapshot(3))
        #expect(provider.isEnabled)
        #expect(provider.active() == provider.current())
        provider.setEnabled(false)
        #expect(!provider.isEnabled)
        #expect(provider.active() == nil)
        #expect(provider.current().revision == 3 && provider.current().rules.count == 1)
        // A save published while switched off stays published and stays inactive.
        let next = Self.snapshot(4)
        provider.publish(next)
        #expect(provider.active() == nil && provider.current() == next)
        provider.setEnabled(true)
        #expect(provider.isEnabled && provider.active() == next)
    }
}
