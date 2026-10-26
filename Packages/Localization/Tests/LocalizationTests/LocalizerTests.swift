import Foundation
import Testing

@testable import Localization

@Suite(.productionChinese) struct LocalizerTests {
    private func translations() throws -> Bundle {
        let url = try #require(
            Bundle.module.url(forResource: "Translations", withExtension: "bundle", subdirectory: "Fixtures"))
        return try #require(Bundle(url: url))
    }

    // Catches region matching being replaced with exact language-code comparison.
    @Test func canadianFrenchUsesFrenchResources() throws {
        let localizer = Localizer(bundle: try translations(), preferredLanguages: ["fr-CA"])
        #expect(localizer.languageCode == "fr")
        #expect(localizer.locale.identifier == "fr")
        #expect(localizer.supportedLanguageCodes == ["en", "fr", "zh-Hans"])
        #expect(localizer.string("greeting") == "Bonjour")
    }

    // Catches Foundation's first available language replacing the specified fallback.
    @Test func unknownLanguageFallsBackToChinese() throws {
        let localizer = Localizer(bundle: try translations(), preferredLanguages: ["de-DE"])
        #expect(localizer.languageCode == "zh-Hans")
        #expect(localizer.string("greeting") == "你好")
    }

    @Test func missingTranslationFallsBackPerKey() throws {
        let localizer = Localizer(bundle: try translations(), preferredLanguages: ["fr"])
        #expect(localizer.string("chinese.only") == "仅有中文")
        #expect(localizer.string("missing.everywhere") == "missing.everywhere")
    }

    // Catches interpolating arguments before formatting, or formatting arguments twice.
    @Test func translatedFormatReordersLiteralUnicodeAndPercentArguments() throws {
        let localizer = Localizer(bundle: try translations(), preferredLanguages: ["fr"])
        #expect(
            localizer.format("reordered", arguments: ["中文 50% \"引用\"", "café 🦊 %2$@"])
                == "café 🦊 %2$@ / 中文 50% \"引用\"")
    }

    @Test(arguments: [(1, "1 flow"), (2, "2 flows")])
    func englishPluralRulesComeFromStringsdict(count: Int, expected: String) throws {
        let localizer = Localizer(bundle: try translations(), preferredLanguages: ["en-US"])
        #expect(localizer.format("flow.count", arguments: [count]) == expected)
    }

    // Catches eagerly evaluating Bundle.module, which can terminate installed apps.
    @Test func packagedAppResourcesTakePriorityWithoutEvaluatingDevelopmentFallback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let appURL = directory.appendingPathComponent("Fixture.app")
        let contents = appURL.appendingPathComponent("Contents")
        let resources = contents.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "dev.pwapp.packaging-test", "CFBundlePackageType": "APPL"]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        let packagedURL = resources.appendingPathComponent("Localization.bundle")
        try FileManager.default.copyItem(at: L10n.bundle.bundleURL, to: packagedURL)
        let appBundle = try #require(Bundle(url: appURL))
        let developmentBundle = try translations()
        var evaluatedDevelopmentFallback = false
        let resolved = L10n.resolveBundle(appBundle: appBundle) {
            evaluatedDevelopmentFallback = true
            return developmentBundle
        }
        #expect(!evaluatedDevelopmentFallback)
        #expect(resolved.bundleURL.standardizedFileURL == packagedURL.standardizedFileURL)
        #expect(Localizer(bundle: resolved, preferredLanguages: ["zh-Hans"]).string("common.cancel") == "取消")
    }

    @Test func developmentResourcesAreUsedWhenAppDoesNotContainLocalizationBundle() throws {
        let developmentBundle = try translations()
        let resolved = L10n.resolveBundle(appBundle: developmentBundle) { developmentBundle }
        #expect(Localizer(bundle: resolved, preferredLanguages: ["fr"]).string("greeting") == "Bonjour")
    }

    @Test func productionResourcesOfferEnglishToAnEnglishSystem() {
        let localizer = Localizer(bundle: L10n.bundle, preferredLanguages: ["en-US"])
        #expect(localizer.supportedLanguageCodes == ["en", "zh-Hans"])
        #expect(localizer.languageCode == "en")
        #expect(localizer.string("common.cancel") == "Cancel")
        #expect(localizer.format("app.quit.confirmation", arguments: ["Fixture 50% 🦊"]).contains("Fixture 50% 🦊"))
    }

    @Test func productionChineseStaysAvailableAndUnsupportedLanguagesFallBackToIt() {
        let chinese = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        #expect(chinese.languageCode == "zh-Hans")
        #expect(chinese.string("common.cancel") == "取消")
        #expect(chinese.format("app.quit.confirmation", arguments: ["Fixture 50% 🦊"]) == "是否退出 Fixture 50% 🦊？")
        let french = Localizer(bundle: L10n.bundle, preferredLanguages: ["fr", "en"])
        #expect(french.languageCode == "zh-Hans")
        #expect(french.string("common.cancel") == "取消")
    }
}
