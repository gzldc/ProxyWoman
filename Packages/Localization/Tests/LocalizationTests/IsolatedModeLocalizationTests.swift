import Foundation
import Localization
import Testing

private func fixtureBundle() throws -> Bundle {
    let url = try #require(Bundle.module.url(forResource: "Translations", withExtension: "bundle", subdirectory: "Fixtures"))
    return try #require(Bundle(url: url))
}

private func strings(_ bundle: Bundle, _ language: String) throws -> [String: String] {
    let url = try #require(bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language))
    return try #require(NSDictionary(contentsOf: url) as? [String: String])
}

/// The isolated test mode's sentences: production zh-Hans has each key, the zh-Hans fixture is a
/// copy, en/fr really translate them with the same positional arguments.
@Suite(.productionChinese) struct IsolatedModeLocalizationTests {
    @Test func everyIsolatedModeKeyIsTranslatedWithTheSameArguments() throws {
        let production = try strings(L10n.bundle, "zh-Hans").filter { $0.key.hasPrefix("isolatedMode.") }
        #expect(Set(production.keys) == ["isolatedMode.active", "isolatedMode.systemProxyUnavailable",
                                         "isolatedMode.trustUnavailable", "isolatedMode.rejected"])
        let fixtures = try fixtureBundle()
        for language in ["en", "fr", "zh-Hans"] {
            let fixture = try strings(fixtures, language).filter { $0.key.hasPrefix("isolatedMode.") }
            #expect(Set(fixture.keys) == Set(production.keys), "\(language)")
            for (key, value) in production {
                let translated = try #require(fixture[key], "\(language) \(key)")
                #expect(translated.components(separatedBy: "%1$@").count == value.components(separatedBy: "%1$@").count,
                        "\(language) \(key) arguments")
                if language == "zh-Hans" { #expect(translated == value, "\(key) fixture copy") }
                else { #expect(translated != value, "\(language) \(key) not translated") }
            }
        }
        let english = Localizer(bundle: fixtures, preferredLanguages: ["en"])
        #expect(english.format("isolatedMode.active", arguments: ["/private/tmp/run"]).contains("/private/tmp/run"))
        #expect(L10n.format("isolatedMode.rejected", "notAbsolute").contains("notAbsolute"))
    }
}
