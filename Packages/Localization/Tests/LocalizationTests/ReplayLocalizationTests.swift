import AppCore
import Foundation
import Localization
import Testing

@Suite(.productionChinese) struct ReplayLocalizationTests {
    @Test func replayReasonsResolveInChineseAndEnglish() throws {
        let url = try #require(Bundle.module.url(forResource: "Translations", withExtension: "bundle", subdirectory: "Fixtures"))
        let bundle = try #require(Bundle(url: url))
        for language in ["en", "zh-Hans"] {
            let localizer = Localizer(bundle: bundle, preferredLanguages: [language])
            for reason in ReplayBlockReason.allCases {
                let text = localizer.string(reason.localizationKey)
                #expect(text != reason.localizationKey && !text.isEmpty)
                #expect(language == "en" ? text.contains("request body") : text.contains("请求正文"))
                #expect(L10n.string(reason.localizationKey) != reason.localizationKey)
            }
        }
    }
}
