import Foundation
import Localization
import Testing

private let r8f3Task8Keys = ["saveMessage", "invalidMessage", "detail", "dontSave"].map { "rules.editor2.close.\($0)" }

@Suite(.productionChinese) struct Rules2R8F3T8LocalizationTests {
    @Test func closePromptKeysAreInProductionAndEveryFixture() throws {
        let fixtureURL = try #require(Bundle.module.url(forResource: "Translations", withExtension: "bundle", subdirectory: "Fixtures"))
        let fixtures = try #require(Bundle(url: fixtureURL))
        func table(_ bundle: Bundle, _ language: String) throws -> [String: String] {
            let url = try #require(bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language))
            return try #require(NSDictionary(contentsOf: url) as? [String: String])
        }
        let production = try table(L10n.bundle, "zh-Hans")
        for key in r8f3Task8Keys {
            #expect(!(production[key] ?? "").isEmpty && production[key] != key, "\(key)")
            for language in ["en", "fr", "zh-Hans"] { #expect(!(try table(fixtures, language)[key] ?? "").isEmpty, "\(key) \(language)") }
        }
        #expect(production["rules.editor2.close.dontSave"] == "不保存")
        #expect(production["rules.editor2.close.invalidMessage"] == "不保存就关闭？")
    }
}
