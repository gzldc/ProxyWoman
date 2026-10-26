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

/// Keys added by R8F2 task 7 (condition row views).
private let r8f2Task7Keys = ["rules.editor3.legacyOption", "rules.editor3.key.caseSensitive", "rules.editor3.date.choose",
    "rules.editor3.fieldValue", "rules.editor3.deprecatedLabel",
]

@Suite(.productionChinese) struct Rules2R8F2T7LocalizationTests {
    @Test func everyKeyIsInProductionAndFixtures() throws {
        let production = try strings(L10n.bundle, "zh-Hans")
        let fixtures = try fixtureBundle()
        let zh = try strings(fixtures, "zh-Hans")
        let en = try strings(fixtures, "en")
        let fr = try strings(fixtures, "fr")
        for key in r8f2Task7Keys {
            let chinese = try #require(production[key], "\(key) missing in production")
            #expect(zh[key] == chinese, "\(key)")
            #expect(en[key]?.isEmpty == false && fr[key]?.isEmpty == false, "\(key)")
        }
        #expect(en["rules.editor3.legacyOption"]?.contains("%1$@") == true)
        #expect(fr["rules.editor3.legacyOption"]?.contains("%1$@") == true)
    }
}
