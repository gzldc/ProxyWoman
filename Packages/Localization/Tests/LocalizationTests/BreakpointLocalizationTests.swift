import AppCore
import Foundation
import Localization
import RulesEngine
import Testing

private func fixtureBundle() throws -> Bundle {
    let url = try #require(Bundle.module.url(forResource: "Translations", withExtension: "bundle", subdirectory: "Fixtures"))
    return try #require(Bundle(url: url))
}

/// Every key of one table (`.strings` plus `.stringsdict` plural entries) read from the real resource files.
private func table(_ bundle: Bundle, _ language: String) throws -> (strings: [String: String], plurals: Set<String>) {
    let strings = try #require(bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language))
    let values = try #require(NSDictionary(contentsOf: strings) as? [String: String])
    let plurals = bundle.url(forResource: "Localizable", withExtension: "stringsdict", subdirectory: nil, localization: language)
        .flatMap { NSDictionary(contentsOf: $0) as? [String: Any] }.map { Set($0.keys) } ?? []
    return (values, plurals)
}

/// Conversion types by argument position, so reordered translations compare equal.
private func specifiers(_ format: String) -> [Int: String] {
    let text = format.replacingOccurrences(of: "%%", with: "")
    let pattern = try! NSRegularExpression(pattern: #"%(?:([0-9]+)\$)?[-+ #0-9.]*(hh|h|ll|l|q|L|z|j|t)?([@dDuUxXoOfeEgGcCsSp])"#)
    var result: [Int: String] = [:]
    var next = 1
    for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        let position: Int
        if let range = Range(match.range(at: 1), in: text), let explicit = Int(text[range]) {
            position = explicit
        } else {
            position = next
            next += 1
        }
        let length = Range(match.range(at: 2), in: text).map { String(text[$0]) } ?? ""
        result[position] = length + (Range(match.range(at: 3), in: text).map { String(text[$0]) } ?? "")
    }
    return result
}

private let notices: [BreakpointNotice] = [
    .ended(draftDiscarded: false), .ended(draftDiscarded: true), .expired, .bodyUnavailable, .actionRejected,
]

@Suite(.productionChinese) struct BreakpointLocalizationTests {
    @Test func everyProductionBreakpointKeyIsTranslatedInEveryFixtureWithTheSameArguments() throws {
        let production = try table(L10n.bundle, "zh-Hans").strings.filter { $0.key.hasPrefix("breakpoints.") }
        #expect(production.count > 30)
        let fixtures = try fixtureBundle()
        for language in ["en", "fr", "zh-Hans"] {
            let fixture = try table(fixtures, language)
            let keys = Set(fixture.strings.keys.filter { $0.hasPrefix("breakpoints.") })
                .union(fixture.plurals.filter { $0.hasPrefix("breakpoints.") })
            #expect(Set(production.keys).subtracting(keys).sorted() == [], "missing in \(language)")
            #expect(keys.subtracting(production.keys).sorted() == [], "stale in \(language)")
            for (key, value) in production {
                guard let translated = fixture.strings[key] else { continue }  // plural entries live in the stringsdict
                #expect(!translated.isEmpty && translated != key, "\(language) \(key)")
                #expect(specifiers(translated) == specifiers(value), "\(language) \(key) arguments")
            }
        }
        for (key, value) in production {
            #expect(!value.isEmpty && value != key && !value.contains("breakpoints."), "\(key)")
        }
    }

    @Test func localizationKeysExist() throws {
        let fixtures = try fixtureBundle()
        let zh = Localizer(bundle: fixtures, preferredLanguages: ["zh-Hans"])
        let en = Localizer(bundle: fixtures, preferredLanguages: ["en"])
        let fr = Localizer(bundle: fixtures, preferredLanguages: ["fr"])
        let production = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        var keys = BreakpointEditIssue.allCases.map(\.localizationKey)
        keys += notices.map(\.localizationKey)
        keys += BreakpointBodyContent.messageKeys
        for key in keys {
            let chinese = production.string(key)
            #expect(chinese != key && !chinese.isEmpty, "\(key)")
            #expect(chinese == zh.string(key), "\(key): production and its fixture copy agree")
            // A fallback to the Chinese fixture would make these equal.
            #expect(en.string(key) != chinese && fr.string(key) != chinese, "\(key)")
        }
    }

    @Test func englishCountsAndFrenchReorderedArgumentsUseWholeSentences() throws {
        let fixtures = try fixtureBundle()
        let en = Localizer(bundle: fixtures, preferredLanguages: ["en"])
        #expect(en.format("breakpoints.clear.message", arguments: [0]) == "No paused breakpoints will be ended.")
        #expect(en.format("breakpoints.clear.message", arguments: [1]) == "1 paused breakpoint will be ended.")
        #expect(en.format("breakpoints.clear.message", arguments: [12]) == "12 paused breakpoints will be ended.")
        #expect(en.format("breakpoints.list.remaining", arguments: [1]) == "1 second")
        #expect(en.format("breakpoints.list.remaining", arguments: [9]) == "9 seconds")
        #expect(L10n.format("breakpoints.clear.message", 3) == "3 个已暂停的断点将被终止。")
        let fr = Localizer(bundle: fixtures, preferredLanguages: ["fr"])
        #expect(fr.format("breakpoints.body.readOnlyTooLarge", arguments: ["9 Mo", "8 Mo"])
            == "Seuls les premiers 8 Mo des 9 Mo du corps sont affichés et il ne peut pas être modifié ici ; conservez-le tel quel ou remplacez-le par un fichier.")
    }

    @Test func everyLiteralBreakpointKeyInTheAppExistsInProduction() throws {
        let production = Set(try table(L10n.bundle, "zh-Hans").strings.keys)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let pattern = try NSRegularExpression(pattern: #""(breakpoints\.[A-Za-z0-9_.]+)""#)
        var used: Set<String> = []
        for directory in ["App", "Packages/AppCore/Sources"] {
            let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent(directory), includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                guard url.pathExtension == "swift", let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    let key = (text as NSString).substring(with: match.range(at: 1))
                    if !key.hasSuffix(".") { used.insert(key) }
                }
            }
        }
        #expect(used.count > 20)
        #expect(used.subtracting(production).sorted() == [])
    }
}
