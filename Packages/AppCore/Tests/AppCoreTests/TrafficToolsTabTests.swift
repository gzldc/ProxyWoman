import RulesEngine
import Testing

@testable import AppCore

@Suite(.productionChinese) struct TrafficToolsTabTests {
    @Test func tabIdentityIsTheCaseNotTheTitle() {
        #expect(TrafficToolsTab.allCases.map(\.id) == ["allow", "block", "conditions"])
        #expect(Set(TrafficToolsTab.allCases.map(\.title)).count == 3)
    }

    @Test func badgesOpenTheirTab() {
        #expect(TrafficBadge.noCaching.tab == nil)
        #expect(TrafficBadge.allowList(2).tab == .allow)
        #expect(TrafficBadge.blockList(1).tab == .block)
        #expect(TrafficBadge.conditions("x").tab == .conditions)
    }

    @MainActor @Test func navigationStartsOnTheAllowTab() {
        let navigation = TrafficToolsNavigation()
        #expect(navigation.tab == .allow)
        navigation.tab = .conditions
        #expect(navigation.tab == .conditions)
    }

    @Test func draftRoundTripsEveryPreset() {
        for preset in NetworkPreset.allCases {
            #expect(NetworkProfileDraft(preset.profile).profile == preset.profile, "\(preset)")
        }
    }

    @Test func emptyBandwidthMeansUnlimited() {
        let draft = NetworkProfileDraft(downloadText: " ", uploadText: "", latencyText: "20", lossText: "1,5")
        #expect(draft.profile == NetworkProfile(downloadKbps: nil, uploadKbps: nil, latencyMs: 20, lossPercent: 1.5))
    }

    @Test func numbersAreBroughtIntoRange() {
        let draft = NetworkProfileDraft(downloadText: "0", uploadText: "2000000", latencyText: "-5", lossText: "250")
        #expect(draft.profile == NetworkProfile(downloadKbps: 1, uploadKbps: 1_000_000, latencyMs: 0, lossPercent: 100))
        #expect(draft.profile?.problem == nil)
        #expect(draft.clamped == NetworkProfileDraft(downloadText: "1", uploadText: "1000000", latencyText: "0", lossText: "100"))
    }

    @Test func textThatIsNotANumberGivesNoProfile() {
        #expect(NetworkProfileDraft(downloadText: "fast").profile == nil)
        #expect(NetworkProfileDraft(uploadText: "1.5").profile == nil)
        #expect(NetworkProfileDraft(latencyText: "").profile == nil)
        #expect(NetworkProfileDraft(lossText: "nan").profile == nil)
        let broken = NetworkProfileDraft(downloadText: "x")
        #expect(broken.clamped == broken)
    }
}
