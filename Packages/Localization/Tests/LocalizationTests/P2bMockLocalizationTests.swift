import AppCore
import Foundation
import Localization
import RulesEngine
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

/// Saving a captured response as a Map Local rule (P2b task 9). The menu and cancel labels are
/// used by the traffic menu and the rules window of task 10.
private let mockKeys: [String] = [
    "rules.mock.menu", "rules.mock.importing", "rules.mock.importCancel", "rules.mock.draftName",
] + MockBlockReason.allCases.map { "rules.mock.blocked." + $0.rawValue }

@Suite(.productionChinese) struct P2bMockLocalizationTests {
    @Test func everyMockKeyExistsAndIsTranslatedInEveryLanguageWithTheSameArguments() throws {
        #expect(mockKeys.count == Set(mockKeys).count && mockKeys.count == 4 + 7)
        let production = try strings(L10n.bundle, "zh-Hans")
        let fixtures = try fixtureBundle()
        let en = try strings(fixtures, "en")
        let fr = try strings(fixtures, "fr")
        let zh = try strings(fixtures, "zh-Hans")
        for key in mockKeys {
            let chinese = try #require(production[key], "\(key) missing in production")
            #expect(!chinese.isEmpty && chinese != key, "\(key)")
            #expect(zh[key] == chinese, "\(key): production and its fixture copy agree")
            let english = try #require(en[key], "\(key) missing in en")
            let french = try #require(fr[key], "\(key) missing in fr")
            #expect(english != chinese && french != chinese && english != key && french != key, "\(key) is translated")
            #expect(specifiers(english) == specifiers(chinese) && specifiers(french) == specifiers(chinese), "\(key) arguments")
        }
    }

    @Test func progressTakesDoneThenTotalAndTheDraftNameTakesTheHost() throws {
        let production = try strings(L10n.bundle, "zh-Hans")
        #expect(specifiers(try #require(production["rules.mock.importing"])) == ["1:@", "2:@"])
        #expect(specifiers(try #require(production["rules.mock.draftName"])) == ["1:@"])
        #expect(L10n.format("rules.mock.draftName", "api.test") == "模拟：api.test")
        #expect(L10n.format("rules.mock.importing", "1 MB", "5 MB") == "正在复制响应正文… 1 MB / 5 MB")
        for key in ["rules.mock.menu", "rules.mock.importCancel"] + MockBlockReason.allCases.map({ "rules.mock.blocked." + $0.rawValue }) {
            #expect(specifiers(try #require(production[key])) == [], "\(key)")
        }
    }

    @Test func everyBlockReasonHasATranslatedMessage() throws {
        let fixtures = try fixtureBundle()
        let production = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        let en = Localizer(bundle: fixtures, preferredLanguages: ["en"])
        let fr = Localizer(bundle: fixtures, preferredLanguages: ["fr"])
        for reason in MockBlockReason.allCases {
            let chinese = production.string(reason.localizationKey)
            #expect(!chinese.isEmpty && chinese != reason.localizationKey, "\(reason)")
            #expect(en.string(reason.localizationKey) != chinese && fr.string(reason.localizationKey) != chinese, "\(reason)")
            #expect(reason.localizedDescription.isEmpty == false)
        }
    }

    @Test func mockKeysUsedBySourcesAreReachedByLiterals() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = [
            "Packages/AppCore/Sources/AppCore/Rules/ResponseMockDraft.swift",
            "Packages/AppCore/Sources/AppCore/Rules/RulesEditorModel.swift",
        ]
        let sources = try files.map { try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }.joined(separator: "\n")
        // The menu and cancel labels belong to task 10's views; every block reason's key is a full literal.
        let blockKeys = MockBlockReason.allCases.map { "rules.mock.blocked." + $0.rawValue }
        for key in ["rules.mock.importing", "rules.mock.draftName"] + blockKeys {
            #expect(sources.contains("\"\(key)\""), "\(key)")
        }
    }

    @Test func menuAndCancelLabelsAreUsedByTheViews() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let menu = try String(contentsOf: root.appendingPathComponent("App/Views/FlowTableView.swift"), encoding: .utf8)
        let window = try String(contentsOf: root.appendingPathComponent("App/Views/Rules/RulesBanners.swift"), encoding: .utf8)
        #expect(menu.contains("\"rules.mock.menu\""))
        #expect(window.contains("\"rules.mock.importCancel\""))
    }
}
