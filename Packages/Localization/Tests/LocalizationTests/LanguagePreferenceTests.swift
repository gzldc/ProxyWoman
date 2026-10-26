import Foundation
import Testing

@testable import Localization

@Suite(.productionChinese) struct LanguagePreferenceTests {
    private func isolated(_ body: (UserDefaults, String, LanguagePreference) throws -> Void) throws {
        let suite = "dev.pwapp.language-preference-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults, suite, LanguagePreference(defaults: defaults, domainName: suite))
    }

    @Test func defaultIsFollowTheSystem() throws {
        try isolated { _, _, preference in #expect(preference.choice == .system) }
    }

    // Catches a stale value surviving a change: each write replaces the list.
    @Test func choicesWriteExactlyOneLanguage() throws {
        try isolated { defaults, suite, preference in
            preference.choice = .simplifiedChinese
            #expect(defaults.persistentDomain(forName: suite)?["AppleLanguages"] as? [String] == ["zh-Hans"])
            #expect(preference.choice == .simplifiedChinese)
            preference.choice = .english
            #expect(defaults.persistentDomain(forName: suite)?["AppleLanguages"] as? [String] == ["en"])
            #expect(preference.choice == .english)
            preference.choice = .simplifiedChinese
            #expect(defaults.persistentDomain(forName: suite)?["AppleLanguages"] as? [String] == ["zh-Hans"])
        }
    }

    @Test func systemRemovesTheOverride() throws {
        try isolated { defaults, suite, preference in
            preference.choice = .english
            preference.choice = .system
            #expect(defaults.persistentDomain(forName: suite)?["AppleLanguages"] == nil)
            #expect(preference.choice == .system)
        }
    }

    @Test(arguments: [
        (["zh-Hans"], LanguageChoice.simplifiedChinese), (["zh-Hans-CN", "en"], .simplifiedChinese),
        (["en"], .english), (["en-US", "zh-Hans"], .english),
        (["fr"], .system), ([String](), .system),
    ])
    func storedValueMapsBackToOneOfTheThreeChoices(stored: [String], expected: LanguageChoice) throws {
        try isolated { defaults, _, preference in
            defaults.set(stored, forKey: "AppleLanguages")
            #expect(preference.choice == expected)
        }
    }

    @Test func nativeNamesAreInTheirOwnLanguage() {
        #expect(LanguageChoice.simplifiedChinese.nativeName == "简体中文")
        #expect(LanguageChoice.english.nativeName == "English")
        #expect(LanguageChoice.system.nativeName == nil)
        #expect(LanguageChoice.allCases == [.system, .simplifiedChinese, .english])
    }

    // MARK: Resolution rule L1-4

    /// A production-shaped bundle: Simplified Chinese and English only.
    private func chineseAndEnglishBundle() throws -> (Bundle, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for (language, text) in [("zh-Hans", "你好"), ("en", "Hello")] {
            let lproj = directory.appendingPathComponent("\(language).lproj")
            try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
            try "\"greeting\" = \"\(text)\";".write(
                to: lproj.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        }
        return (try #require(Bundle(url: directory)), directory)
    }

    @Test(arguments: [
        (["zh-Hans"], "zh-Hans", "你好"), (["zh-Hans-CN", "en"], "zh-Hans", "你好"),
        (["zh-Hant-TW", "en"], "zh-Hans", "你好"), (["en"], "en", "Hello"), (["en-US", "zh-Hans"], "en", "Hello"),
        (["en-GB"], "en", "Hello"),
        // The first language is neither Chinese nor English: Chinese, even when English comes second.
        (["fr", "en"], "zh-Hans", "你好"), (["de-DE", "en-US"], "zh-Hans", "你好"), (["ja"], "zh-Hans", "你好"),
        ([String](), "zh-Hans", "你好"),
    ])
    func firstPreferredLanguageDecidesAndOthersGetChinese(languages: [String], code: String, greeting: String) throws {
        let (bundle, directory) = try chineseAndEnglishBundle()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(bundle.localizations.contains("en") && bundle.localizations.contains("zh-Hans"))
        let localizer = Localizer(bundle: bundle, preferredLanguages: languages)
        #expect(localizer.languageCode == code)
        #expect(localizer.string("greeting") == greeting)
    }

    // The override reaches the resolver the way the app does: through Locale.preferredLanguages-shaped input.
    @Test func chosenLanguageResolvesThroughTheStoredList() throws {
        let (bundle, directory) = try chineseAndEnglishBundle()
        defer { try? FileManager.default.removeItem(at: directory) }
        try isolated { defaults, _, preference in
            preference.choice = .english
            let stored = defaults.stringArray(forKey: "AppleLanguages") ?? []
            #expect(Localizer(bundle: bundle, preferredLanguages: stored).languageCode == "en")
            preference.choice = .simplifiedChinese
            let again = defaults.stringArray(forKey: "AppleLanguages") ?? []
            #expect(Localizer(bundle: bundle, preferredLanguages: again + ["en"]).languageCode == "zh-Hans")
        }
    }
}
