import AppCore
import Foundation
import Localization
import RulesEngine
import Testing

// Rules 2.0 R1, Task 11: the upgrade notice in the three fixture languages. This suite lives beside the
// translations it reads (the fixture bundle is a resource of this test target); what the notice does with
// its pairs is in AppCoreTests/UpgradeNoticeTests.

private func fixtureBundle() throws -> Bundle {
    let url = try #require(Bundle.module.url(forResource: "Translations", withExtension: "bundle", subdirectory: "Fixtures"))
    return try #require(Bundle(url: url))
}

private let languages = ["zh-Hans", "en", "fr"]

private func table(_ bundle: Bundle, _ language: String) throws -> [String: String] {
    let url = try #require(bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language))
    return try #require(NSDictionary(contentsOf: url) as? [String: String])
}

private let higherID = UUID(), lowerID = UUID()

private func presentation(omitted: Int = 0) throws -> UpgradeNoticePresentation {
    let notice = MigrationNotice(
        report: MigrationReport(pairs: [MigrationPair(changeClass: .laterSeesEarlier, higherRuleID: higherID, lowerRuleID: lowerID)]),
        migratedFromSchema: 3, acknowledged: false, omittedPairCount: omitted)
    return try #require(
        UpgradeNoticePresentation.make(
            notice: notice, ruleName: { $0 == higherID ? "Fix price" : $0 == lowerID ? "Force 404" : nil }))
}

@Suite(.productionChinese) struct UpgradeNoticeTests {
    @Test func pairTextUsesPositionalArgumentsInEveryFixtureLanguage() throws {
        let bundle = try fixtureBundle()
        let notice = try presentation()
        let item = try #require(notice.sections.first?.items.first)
        for language in languages {
            let localizer = Localizer(bundle: bundle, preferredLanguages: [language])
            let template = try #require(try table(bundle, "\(language)")["rules.upgrade.pair"], "\(language)")
            // Both rules are named by position: the higher-priority rule is argument 1, the lower is argument 2.
            #expect(template.contains("%1$@") && template.contains("%2$@"), "\(language): \(template)")
            let expected = template.replacingOccurrences(of: "%1$@", with: "Fix price").replacingOccurrences(of: "%2$@", with: "Force 404")
            #expect(!expected.contains("%"), "\(language): \(expected)")
            #expect(notice.pairText(item, localizer: localizer) == expected, "\(language)")
        }
        // A deleted rule is named by the placeholder in the language of the row.
        for language in languages {
            let localizer = Localizer(bundle: bundle, preferredLanguages: [language])
            let deleted = UpgradeNoticePresentation.make(
                notice: MigrationNotice(
                    report: MigrationReport(pairs: [MigrationPair(changeClass: .finalAction, higherRuleID: higherID, lowerRuleID: lowerID)]),
                    migratedFromSchema: 3),
                ruleName: { $0 == higherID ? "Fix price" : nil }, localizer: localizer)
            let item = try #require(deleted?.sections.first?.items.first)
            #expect(item.lowerName == localizer.string("ruleOutcome.unknownRule"), "\(language)")
            #expect(item.lowerName != "ruleOutcome.unknownRule", "\(language) is translated")
        }
    }

    @Test func theOmittedCountTakesItsNumberByPositionInEveryFixtureLanguage() throws {
        let bundle = try fixtureBundle()
        let notice = try presentation(omitted: 42)
        for language in languages {
            let localizer = Localizer(bundle: bundle, preferredLanguages: [language])
            let template = try #require(try table(bundle, "\(language)")["rules.upgrade.omitted"], "\(language)")
            #expect(template.contains("%1$ld"), "\(language): \(template)")
            let text = try #require(notice.omittedText(localizer: localizer), "\(language)")
            #expect(text == template.replacingOccurrences(of: "%1$ld", with: "42"), "\(language)")
            #expect(text.contains("42") && !text.contains("%"), "\(language): \(text)")
        }
        #expect(try presentation().omittedText() == nil)
    }

    /// A pair is {higher-priority rule, lower-priority rule}. For class 2 either one can be the affected
    /// rule (a response rule with a status range, above a Map Remote, reads the moved request), so neither
    /// the class-2 explanation nor the advice may say the lower rule is the one that is affected or tell the
    /// user to move "L before R" without saying when that applies.
    @Test func classTwoAndTheAdviceDoNotAssumeWhichRuleIsAffected() throws {
        let production = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        #expect(production.string("rules.upgrade.class2.title") == "规则的条件读到的是改写之后的请求或状态码")
        #expect(
            production.string("rules.upgrade.class2.body")
                == "判断一条规则的条件时，读到的是另一条规则已经改写过的请求或状态码，不再是原始内容。例如：远程映射改了域名之后，按原域名匹配的规则可能不再命中；状态码改写之后，带状态码范围的规则读到的是新状态码。列表里的每一对中，一条做了改写，另一条的条件读到了改写后的内容。")
        #expect(
            production.string("rules.upgrade.advice")
                == "处理办法：对列表里的一对规则，如果受影响的那条排在后面，可以把它移到前面，让它先于另一条运行；也可以把受影响那条的条件改成改写之后的目标。带状态码范围的规则要等响应到达时才判断，移动它不会改变它读到的请求，请改它的条件。")

        // The same property in every fixture language: the class-2 sentences name no rule by its position.
        let directional: [String: [String]] = [
            "zh-Hans": ["优先级更低", "优先级更高", "后面的规则", "前面的规则", "前面规则", "更低优先级"],
            "en": ["lower", "higher", "later rule", "earlier rule", "following rule", "preceding rule"],
            "fr": ["inférieure", "supérieure", "règle suivante", "règle précédente", "règles suivantes"],
        ]
        let bundle = try fixtureBundle()
        for language in languages {
            let strings = try table(bundle, "\(language)")
            let class2 = try #require(strings["rules.upgrade.class2.title"]) + #require(strings["rules.upgrade.class2.body"])
            for word in try #require(directional[language]) {
                #expect(!class2.localizedLowercase.contains(word.localizedLowercase), "\(language) class 2 says “\(word)”")
            }
            // Where the advice speaks of order it does so only for a rule that is in the lower position.
            let advice = try #require(strings["rules.upgrade.advice"], "\(language)")
            #expect(advice != "rules.upgrade.advice" && !advice.isEmpty, "\(language)")
        }
    }

    /// A rule with a status range is judged when the response arrives, so moving it above the Map Remote does not
    /// change the request it reads; the advice says so in every language (review minor M1 of Task 11).
    @Test func theAdviceSaysThatAStatusRangeRuleIsJudgedWhenTheResponseArrives() throws {
        let bundle = try fixtureBundle()
        let phrases = ["zh-Hans": "带状态码范围的规则要等响应到达时才判断", "en": "judged when the response arrives", "fr": "évaluée à l’arrivée de la réponse"]
        for language in languages {
            let advice = try #require(try table(bundle, "\(language)")["rules.upgrade.advice"], "\(language)")
            #expect(advice.contains(try #require(phrases[language])), "\(language): \(advice)")
        }
    }

    /// Return File and Map Local Directory are both final actions, and a Map Remote can be followed by either: the
    /// class 1 and class 3 headings name the directory mapping in every language (review minor M2 of Task 11).
    @Test func theFinalActionAndSequenceHeadingsNameTheDirectoryMapping() throws {
        let bundle = try fixtureBundle()
        let names = ["zh-Hans": "本地目录映射", "en": "Map Local Directory", "fr": "dossier local"]
        for language in languages {
            let strings = try table(bundle, "\(language)")
            let name = try #require(names[language])
            for key in ["rules.upgrade.class1.title", "rules.upgrade.class3.title", "rules.upgrade.class3.body"] {
                #expect(try #require(strings[key], "\(language) \(key)").contains(name), "\(language) \(key)")
            }
        }
        let production = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        #expect(production.string("rules.upgrade.class1.title") == "返回文件（本地映射）和本地目录映射现在是最终动作")
        #expect(production.string("rules.upgrade.class3.title") == "同一目标被多条规则改写或映射（含本地目录映射）时依次执行")
    }

    /// When the stored list holds no pair there is nothing "below" and nothing "more": the opening sentence takes
    /// the count by position and says the pairs are not listed (review minor M3 of Task 11).
    @Test func theOpeningSentenceOfANoticeWithoutListedPairsTakesTheCountAndSaysUnlisted() throws {
        let bundle = try fixtureBundle()
        let notice = try #require(
            UpgradeNoticePresentation.make(
                notice: MigrationNotice(report: MigrationReport(pairs: []), migratedFromSchema: 3, omittedPairCount: 42),
                ruleName: { _ in nil }))
        #expect(notice.sections.isEmpty && notice.omittedText() == nil)
        let unlisted = ["zh-Hans": "未列出", "en": "not listed", "fr": "ne sont pas listées"]
        let listedBelow = ["zh-Hans": ["下面", "另有"], "en": ["below", "more affected"], "fr": ["ci-dessous", "de plus"]]
        for language in languages {
            let localizer = Localizer(bundle: bundle, preferredLanguages: [language])
            let template = try #require(try table(bundle, "\(language)")["rules.upgrade.introUnlisted"], "\(language)")
            #expect(template.contains("%1$ld"), "\(language): \(template)")
            let text = notice.introText(localizer: localizer)
            #expect(text == template.replacingOccurrences(of: "%1$ld", with: "42"), "\(language)")
            #expect(text.contains("42") && !text.contains("%"), "\(language): \(text)")
            #expect(text.contains(try #require(unlisted[language])), "\(language): \(text)")
            for word in try #require(listedBelow[language]) { #expect(!text.contains(word), "\(language) says “\(word)”: \(text)") }
        }
    }

    @Test func theIntroSaysHowPairsAreWrittenAndWhatAClickDoes() throws {
        let production = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        let intro = production.string("rules.upgrade.intro")
        #expect(intro.contains("「优先级更高的规则」→「优先级更低的规则」") && intro.contains("点一下会选中其中优先级更低的那条"))
        // The list can include a pair that does not differ in practice, so the intro does not promise that it does.
        #expect(intro.contains("可能"))
        let bundle = try fixtureBundle()
        for language in ["en", "fr"] {
            #expect(try table(bundle, "\(language)")["rules.upgrade.intro"] != intro, "\(language)")
        }
    }
}
