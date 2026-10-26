import Foundation
import Localization
import Testing

private let r8f3Task4Keys = ["request", "response", "other"].map { "rules.fieldSection.\($0)" }

@Suite(.productionChinese) struct Rules2R8F3T4LocalizationTests {
    @Test func sectionHeadersAreInProductionAndEveryFixture() throws {
        let fixtureURL = try #require(Bundle.module.url(forResource: "Translations", withExtension: "bundle", subdirectory: "Fixtures"))
        let fixtures = try #require(Bundle(url: fixtureURL))
        func table(_ bundle: Bundle, _ language: String) throws -> [String: String] {
            let url = try #require(bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language))
            return try #require(NSDictionary(contentsOf: url) as? [String: String])
        }
        let production = try table(L10n.bundle, "zh-Hans")
        for key in r8f3Task4Keys {
            #expect(!(production[key] ?? "").isEmpty && production[key] != key, "\(key)")
            for language in ["en", "fr", "zh-Hans"] { #expect(!(try table(fixtures, language)[key] ?? "").isEmpty, "\(key) \(language)") }
        }
        #expect(r8f3Task4Keys.map { production[$0] } == ["请求", "响应", "其他"])
    }
}
