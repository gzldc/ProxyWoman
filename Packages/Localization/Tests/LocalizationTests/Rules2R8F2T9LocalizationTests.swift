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

/// Positional conversion types, so reordered translations compare equal.
private func specifiers(_ format: String) -> [String] {
    let pattern = try! NSRegularExpression(pattern: #"%(?:([0-9]+)\$)?[-+ #0-9.]*(?:hh|h|ll|l|q|L|z|j|t)?([@dDuUxXoOfeEgGcCsSp])"#)
    let text = format.replacingOccurrences(of: "%%", with: "")
    return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).enumerated().map { index, match in
        let position = Range(match.range(at: 1), in: text).map { String(text[$0]) } ?? String(index + 1)
        return position + ":" + (Range(match.range(at: 2), in: text).map { String(text[$0]) } ?? "")
    }.sorted()
}

/// Keys added by R8F2 task 9 (the action card view).
private let r8f2Task9Keys = [
    "rules.card.fieldLabel", "rules.card.dragHandle", "rules.card.dragPreview", "rules.card.more", "rules.card.noticeCount",
    "rules.card.errorCount", "rules.card.noticeKind.error", "rules.card.noticeKind.warning", "rules.card.noticeItem",
    "rules.action.browse", "rules.action.language", "rules.mapLocal.fileReady",
    "rules.card.hint.expanded", "rules.card.hint.collapsed", "rules.action.moreOptions",
]

@Suite(.productionChinese) struct Rules2R8F2T9LocalizationTests {
    @Test func everyKeyIsInProductionAndFixturesWithTheSameArguments() throws {
        #expect(r8f2Task9Keys.count == Set(r8f2Task9Keys).count)
        let production = try strings(L10n.bundle, "zh-Hans")
        let fixtures = try fixtureBundle()
        let en = try strings(fixtures, "en")
        let fr = try strings(fixtures, "fr")
        let zh = try strings(fixtures, "zh-Hans")
        for key in r8f2Task9Keys {
            let chinese = try #require(production[key], "\(key) missing in production")
            #expect(!chinese.isEmpty && chinese != key, "\(key)")
            #expect(zh[key] == chinese, "\(key): production and its fixture copy agree")
            let english = try #require(en[key], "\(key) missing in en")
            let french = try #require(fr[key], "\(key) missing in fr")
            #expect(!english.isEmpty && !french.isEmpty, "\(key)")
            #expect(specifiers(english) == specifiers(chinese) && specifiers(french) == specifiers(chinese), "\(key) arguments")
        }
    }

    @Test func theCardLabelsReadAsSpecified() throws {
        let production = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        #expect(production.format("rules.card.fieldLabel", arguments: [2, "方式"]) == "方式（动作 2）")
        #expect(production.format("rules.card.noticeCount", arguments: [1, 3]) == "动作 1 有 3 条警告")
        #expect(production.string("rules.action.browse") == "浏览…")
    }

    @Test func noCardTextNamesTheReferenceProduct() throws {
        let production = try strings(L10n.bundle, "zh-Hans")
        for key in r8f2Task9Keys {
            #expect(!(production[key] ?? "").contains("Fiddler") && !(production[key] ?? "").contains("Telerik"), "\(key)")
        }
    }
}
