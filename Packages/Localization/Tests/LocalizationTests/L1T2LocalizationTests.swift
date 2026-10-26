import Foundation
import Localization
import Testing

private let l1Task2Keys = [
    "generalPane.languageChoice.system", "generalPane.languageRestart.title", "generalPane.languageRestart.message",
    "generalPane.languageRestart.restartNow", "generalPane.languageRestart.later", "appModel.restartFailed",
]
private let removedKeys = ["generalPane.languageExplanation", "generalPane.languageHelp", "generalPane.supportedLanguages"]
private let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@Suite(.productionChinese) struct L1T2LocalizationTests {
    private func table(_ bundle: Bundle, _ language: String) throws -> [String: String] {
        let url = try #require(bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language))
        return try #require(NSDictionary(contentsOf: url) as? [String: String])
    }

    @Test func languagePickerKeysAreInProductionAndEveryFixture() throws {
        let fixtureURL = try #require(Bundle.module.url(forResource: "Translations", withExtension: "bundle", subdirectory: "Fixtures"))
        let fixtures = try #require(Bundle(url: fixtureURL))
        let production = try table(L10n.bundle, "zh-Hans")
        for key in l1Task2Keys {
            #expect(!(production[key] ?? "").isEmpty && production[key] != key, "\(key)")
            for language in ["en", "fr", "zh-Hans"] { #expect(!(try table(fixtures, language)[key] ?? "").isEmpty, "\(key) \(language)") }
        }
        #expect(production["generalPane.languageChoice.system"] == "跟随系统")
        #expect(production["generalPane.languageRestart.title"] == "重启后生效")
        #expect(production["generalPane.languageRestart.restartNow"] == "立即重启")
        #expect(production["generalPane.languageRestart.later"] == "稍后")
        // The product name is a parameter in every language.
        for language in ["en", "fr", "zh-Hans"] {
            #expect(try table(fixtures, language)["generalPane.languageRestart.message"]?.contains("%1$@") == true)
        }
    }

    @Test func theOldNoInAppChoiceTextsAreGone() throws {
        let production = try table(L10n.bundle, "zh-Hans")
        for key in removedKeys { #expect(production[key] == nil, "\(key)") }
        for text in production.values { #expect(!text.contains("没有独立的 App 内语言偏好")) }
    }

    @Test func generalSearchKeywordsMentionLanguageAndEnglish() throws {
        let keywords = try #require(try table(L10n.bundle, "zh-Hans")["settings.page.general.keywords"])
        for word in ["语言", "界面语言", "language", "English", "英文", "中文", "重启"] { #expect(keywords.contains(word), "\(word)") }
    }

    // Every new key is used by production code, so none is left behind.
    @Test func everyNewKeyIsUsedByTheApp() throws {
        var source = ""
        for file in ["App/Views/Settings/GeneralPane.swift", "App/AppModel.swift"] {
            source += try String(contentsOf: repositoryRoot.appendingPathComponent(file), encoding: .utf8)
        }
        for key in l1Task2Keys { #expect(source.contains("\"\(key)\""), "\(key)") }
        for key in removedKeys { #expect(!source.contains("\"\(key)\""), "\(key)") }
    }
}
