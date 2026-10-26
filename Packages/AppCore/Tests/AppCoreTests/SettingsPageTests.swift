import Foundation
import Localization
import Testing

@testable import AppCore

@Suite(.productionChinese) struct SettingsPageTests {
    @Test func unsupportedPreferredLanguageFallsBackToProductionChineseForSearch() {
        let localizer = Localizer(bundle: L10n.bundle, preferredLanguages: ["fr"])
        #expect(localizer.languageCode == "zh-Hans")
        #expect(SettingsPage.general.title(using: localizer) == "通用")
        #expect(SettingsPage.general.matches("通用", using: localizer))
        #expect(SettingsPage.general.matches("信任", using: localizer))
        #expect(SettingsPage.tools.matches("curl", using: localizer))
        #expect(!SettingsPage.privacy.matches("端口", using: localizer))
        #expect(SettingsPage.appearance.matches("", using: localizer))
        #expect(SettingsPage.general.rawValue == "general")
    }

    @Test func searchUsesResolvedResourceTitlesAndKeywordsWithoutChangingIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let french = directory.appendingPathComponent("fr.lproj")
        let chinese = directory.appendingPathComponent("zh-Hans.lproj")
        try FileManager.default.createDirectory(at: french, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chinese, withIntermediateDirectories: true)
        try
            "\"settings.page.general.title\" = \"Général\";\n\"settings.page.general.keywords\" = \"certificat réseau\";"
            .write(to: french.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        try "\"settings.page.privacy.title\" = \"隐私\";\n\"settings.page.privacy.keywords\" = \"数据\";".write(
            to: chinese.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        let bundle = try #require(Bundle(url: directory))
        let localizer = Localizer(bundle: bundle, preferredLanguages: ["fr"])
        #expect(SettingsPage.general.title(using: localizer) == "Général")
        #expect(SettingsPage.general.matches("GÉNÉRAL", using: localizer))
        #expect(SettingsPage.general.matches("certificat", using: localizer))
        #expect(!SettingsPage.general.matches("通用", using: localizer))
        #expect(SettingsPage.privacy.matches("数据", using: localizer))
        #expect(SettingsPage.general.id == .general)
    }

    @Test func pagesInSidebarOrder() {
        #expect(
            SettingsPage.allCases == [.general, .appearance, .privacy, .trafficControl, .https, .tools, .mcp, .advanced])
        #expect(SettingsPage.trafficControl.icon == "network" && SettingsPage.https.icon == "lock.shield")
    }

    @Test func newPagesHaveTitlesAndKeywords() {
        let localizer = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        #expect(SettingsPage.trafficControl.title(using: localizer) == "流量控制")
        #expect(SettingsPage.https.title(using: localizer) == "HTTPS")
        #expect(!SettingsPage.trafficControl.keywords(using: localizer).isEmpty)
        #expect(!SettingsPage.https.keywords(using: localizer).isEmpty)
    }

    @Test func searchFindsTrafficControlByAllowList() {
        let localizer = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        #expect(SettingsPage.trafficControl.matches("允许列表", using: localizer))
    }

    @Test func searchFindsHTTPSBySSL() {
        let localizer = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        #expect(SettingsPage.https.matches("SSL", using: localizer))
    }
}
