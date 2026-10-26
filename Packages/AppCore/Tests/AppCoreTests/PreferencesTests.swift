import Foundation
import Testing

@testable import AppCore

@Suite(.productionChinese) struct PreferencesTests {
    @Test func defaults() {
        let p = Preferences()
        #expect(p.theme == .light)
        #expect(p.contentLayout == .horizontal)
        #expect(p.inspector == InspectorLayout())
        #expect(p.showMenuBarIcon)
        #expect(p.truncation == .tail)
        #expect(!p.autoOverrideSystemProxyAtLaunch)
        #expect(p.autoStartRecordingAtLaunch)
        #expect(p.autoSelectAvailablePort)
        #expect(p.alertOnQuit)
        #expect(p.fontSize == 12)
        #expect(p.monospaced)
        #expect(p.wordWrap)
        #expect(!p.showInvisibles)
        #expect(p.zebraRows)
        #expect(p.showResourceUsage)
        #expect(p.use24HourTime)
        #expect(!p.fullTimeFormat)
        #expect(p.autoRemoveOldRequests)
        #expect(p.copyFormat == .curl)
        #expect(!p.copyAddsProxy)
        #expect(!p.copyPreservesOriginalHeaders)
        #expect(p.pinnedApps.isEmpty)
        #expect(p.pinnedHosts.isEmpty)
    }

    @Test func oldPreferencesWithoutInspectorDecodeToDefaults() throws {
        let p = try JSONDecoder().decode(Preferences.self, from: Data(#"{"fontSize":14}"#.utf8))
        #expect(p.inspector == InspectorLayout())
    }

    @Test func storedVerticalLayoutIsKept() throws {
        let p = try JSONDecoder().decode(Preferences.self, from: Data(#"{"contentLayout":"vertical"}"#.utf8))
        #expect(p.contentLayout == .vertical)
    }

    @Test func inspectorWidthIsClampedOnDecode() throws {
        let p = try JSONDecoder().decode(Preferences.self, from: Data(#"{"inspector":{"width":5}}"#.utf8))
        #expect(p.inspector.width == 320)
    }

    @Test func unknownInspectorTabKeepsTheRestOfTheLayout() throws {
        let json = #"{"inspector":{"width":500,"isCollapsed":true,"tab":"timeline","sourceBarVisible":false}}"#
        let p = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
        #expect(p.inspector.tab == .requestDetails)
        #expect(p.inspector.width == 500)
        #expect(p.inspector.isCollapsed)
        #expect(!p.inspector.sourceBarVisible)
    }

    @Test func decodingEmptyObjectYieldsDefaults() throws {
        let p = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        #expect(p == Preferences())
    }

    @Test func decodingPartialObjectKeepsOtherDefaults() throws {
        let p = try JSONDecoder().decode(Preferences.self, from: Data(#"{"fontSize":14}"#.utf8))
        var expected = Preferences()
        expected.fontSize = 14
        #expect(p == expected)
    }

    @Test func roundTrip() throws {
        var p = Preferences()
        p.theme = .dark
        p.contentLayout = .horizontal
        p.truncation = .middle
        p.pinnedApps = ["Safari"]
        p.pinnedHosts = ["example.com"]
        p.use24HourTime = false
        let data = try JSONEncoder().encode(p)
        #expect(try JSONDecoder().decode(Preferences.self, from: data) == p)
    }

    @Test func fontSizeIsClampedToSupportedRange() throws {
        let low = try JSONDecoder().decode(Preferences.self, from: Data(#"{"fontSize":3}"#.utf8))
        let high = try JSONDecoder().decode(Preferences.self, from: Data(#"{"fontSize":99}"#.utf8))
        #expect(low.fontSize == 10)
        #expect(high.fontSize == 18)
        var p = Preferences()
        p.fontSize = 40
        #expect(p.fontSize == 18)
        p.fontSize = 1
        #expect(p.fontSize == 10)
    }

    @Test func pinningAppsAndHostsKeepsOrderWithoutDuplicates() {
        var p = Preferences()
        p.setPinned(true, app: "curl")
        p.setPinned(true, app: "Safari")
        p.setPinned(true, app: "curl")
        #expect(p.pinnedApps == ["curl", "Safari"])
        #expect(p.isPinned(app: "curl"))
        p.setPinned(false, app: "curl")
        #expect(p.pinnedApps == ["Safari"])
        #expect(!p.isPinned(app: "curl"))

        p.setPinned(true, host: "a.com")
        p.setPinned(true, host: "a.com")
        #expect(p.pinnedHosts == ["a.com"])
        #expect(p.isPinned(host: "a.com"))
        p.setPinned(false, host: "a.com")
        #expect(p.pinnedHosts.isEmpty)
        #expect(p.pinnedApps == ["Safari"])
    }
}

extension PreferencesTests {
    @Test func commentColumnIsOffByDefaultAndRoundTrips() throws {
        var p = Preferences()
        #expect(!p.showCommentColumn)
        p.showCommentColumn = true
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(p))
        #expect(decoded.showCommentColumn)
    }

    @Test func oldPreferencesWithoutTheKeyDecodeToOff() throws {
        let decoded = try JSONDecoder().decode(Preferences.self, from: Data(#"{"fontSize":13}"#.utf8))
        #expect(!decoded.showCommentColumn && decoded.fontSize == 13)
    }
}
