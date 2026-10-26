import Foundation
import RulesEngine
import Testing
@testable import AppCore

/// Phase fix I2d: one switch for all rules, shown from the live provider flag and saved on change.
@MainActor @Suite(.productionChinese) struct GlobalRulesSwitchTests {
    @Test func defaultsOnAndShowsTheLiveProviderState() {
        let provider = RuleSnapshotProvider()
        var saved: [Bool] = []
        let rules = GlobalRulesSwitch(provider: provider, initial: Preferences().rulesEnabled, persist: { saved.append($0) })
        #expect(rules.isOn && provider.isEnabled)
        #expect(saved.isEmpty)
    }

    @Test func aSavedOffStateIsAppliedBeforeAnyTraffic() {
        let provider = RuleSnapshotProvider()
        var saved: [Bool] = []
        let rules = GlobalRulesSwitch(provider: provider, initial: false, persist: { saved.append($0) })
        #expect(!rules.isOn && !provider.isEnabled && provider.active() == nil)
        #expect(saved.isEmpty)
    }

    @Test func switchingAppliesLiveAndPersistsEachChange() {
        let provider = RuleSnapshotProvider()
        var saved: [Bool] = []
        let rules = GlobalRulesSwitch(provider: provider, initial: true, persist: { saved.append($0) })
        rules.setOn(false)
        #expect(!rules.isOn && !provider.isEnabled)
        rules.toggle()
        #expect(rules.isOn && provider.isEnabled)
        rules.setOn(true)
        #expect(saved == [false, true])
        // The shown state follows the provider, not the request.
        provider.setEnabled(false)
        rules.refresh()
        #expect(!rules.isOn)
    }

    @Test func preferenceDefaultsOnAndRoundTrips() throws {
        #expect(Preferences().rulesEnabled)
        let decoded = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        #expect(decoded.rulesEnabled)
        var off = Preferences()
        off.rulesEnabled = false
        let roundTrip = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(off))
        #expect(!roundTrip.rulesEnabled)
    }
}
