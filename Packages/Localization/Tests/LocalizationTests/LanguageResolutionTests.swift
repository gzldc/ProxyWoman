import Foundation
import Testing

@testable import Localization

/// The restart prompt appears only when the chosen language differs from the one in effect (rulings L1-1, L1-4).
@Suite struct LanguageResolutionTests {
    private let bundle = L10n.bundle

    @Test(arguments: [
        // choice, system languages, resolved
        (LanguageChoice.system, ["en-US"], "en"), (.system, ["zh-Hans-CN", "en"], "zh-Hans"),
        // the first language counts: French first gives Chinese although English follows
        (.system, ["fr", "en"], "zh-Hans"), (.system, ["en", "zh-Hans"], "en"), (.system, [], "zh-Hans"),
        (.simplifiedChinese, ["en"], "zh-Hans"), (.english, ["zh-Hans"], "en"), (.english, ["fr"], "en"),
    ])
    func aChoiceResolvesByTheFirstLanguageRule(choice: LanguageChoice, system: [String], expected: String) {
        #expect(choice.resolvedLanguageCode(systemLanguages: system, bundle: bundle) == expected)
    }

    @Test func choosingTheLanguageInEffectNeedsNoRestart() {
        // English shown because the system is English: "system" and "English" change nothing, Chinese does.
        #expect(!LanguageChoice.system.changesLanguage(from: "en", systemLanguages: ["en-US"], bundle: bundle))
        #expect(!LanguageChoice.english.changesLanguage(from: "en", systemLanguages: ["en-US"], bundle: bundle))
        #expect(LanguageChoice.simplifiedChinese.changesLanguage(from: "en", systemLanguages: ["en-US"], bundle: bundle))
        // Chinese forced over an English system: "system" now changes it, reverting to Chinese does not.
        #expect(LanguageChoice.system.changesLanguage(from: "zh-Hans", systemLanguages: ["en-US"], bundle: bundle))
        #expect(!LanguageChoice.simplifiedChinese.changesLanguage(from: "zh-Hans", systemLanguages: ["en-US"], bundle: bundle))
        // A French-first system shows Chinese, so "system" is the language in effect there.
        #expect(!LanguageChoice.system.changesLanguage(from: "zh-Hans", systemLanguages: ["fr", "en"], bundle: bundle))
        #expect(LanguageChoice.english.changesLanguage(from: "zh-Hans", systemLanguages: ["fr", "en"], bundle: bundle))
        #expect(LanguageChoice.system.changesLanguage(from: "zh-Hans", systemLanguages: nil, bundle: bundle))
        #expect(!LanguageChoice.simplifiedChinese.changesLanguage(from: "zh-Hans", systemLanguages: nil, bundle: bundle))
    }
}
