import AppCore
import FlowStore
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

private let editorErrors: [RulesEditorError] = [
    .conflict, .unavailable(.corrupt), .unavailable(.unsupportedSchema), .unavailable(.tooLarge), .unavailable(.unreadable),
    .unavailable(.migrationFailed),
    .notLoaded, .loadFailed, .invalidRule, .unknownAsset, .configurationTooLarge, .revisionExhausted,
    .storage(.ioFailure), .storage(.insufficientDiskSpace), .backupFailed(.ioFailure), .backupFailed(.notRegularFile),
    .backupFailed(.insufficientDiskSpace), .importFailed(.notRegularFile), .importFailed(.fileTooLarge),
    .importFailed(.capacityExceeded), .importFailed(.insufficientDiskSpace), .importFailed(.sourceChanged),
    .importFailed(.ioFailure), .breakpointsUnavailable,
]

@Suite(.productionChinese) struct RulesLocalizationTests {
    @Test func everyProductionRulesKeyIsTranslatedInEveryFixtureWithTheSameArguments() throws {
        let production = try table(L10n.bundle, "zh-Hans").strings.filter { $0.key.hasPrefix("rules.") }
        #expect(!production.isEmpty)
        let fixtures = try fixtureBundle()
        for language in ["en", "fr", "zh-Hans"] {
            let fixture = try table(fixtures, language)
            let keys = Set(fixture.strings.keys.filter { $0.hasPrefix("rules.") }).union(fixture.plurals.filter { $0.hasPrefix("rules.") })
            #expect(Set(production.keys).subtracting(keys).sorted() == [], "missing in \(language)")
            #expect(keys.subtracting(production.keys).sorted() == [], "stale in \(language)")
            for (key, value) in production {
                guard let translated = fixture.strings[key] else { continue }  // plural entries live in the stringsdict
                #expect(!translated.isEmpty && translated != key, "\(language) \(key)")
                #expect(specifiers(translated) == specifiers(value), "\(language) \(key) arguments")
            }
        }
        for (key, value) in production {
            #expect(!value.isEmpty && value != key && !value.contains("rules."), "\(key)")
        }
    }

    @Test func typedEditorTextsResolveInProductionAndInEveryFixtureLanguage() throws {
        let fixtures = try fixtureBundle()
        let zh = Localizer(bundle: fixtures, preferredLanguages: ["zh-Hans"])
        let en = Localizer(bundle: fixtures, preferredLanguages: ["en"])
        let fr = Localizer(bundle: fixtures, preferredLanguages: ["fr"])
        let production = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        let limits = RulesLimits()
        var texts: [(String, (Localizer) -> String)] = []
        texts += RuleDraftIssue.allCases.map { issue in (issue.localizationKey, { issue.message(limits: limits, localizer: $0) }) }
        texts += RuleKind.allCases.map { kind in (kind.localizationKey, { $0.string(kind.localizationKey) }) }
        texts += editorErrors.map { error in (error.localizationKey, { error.message(localizer: $0) }) }
        let warning = RuleDraftWarning.methodCase("get")
        texts.append((warning.localizationKey, { warning.message(localizer: $0) }))
        for (key, text) in texts {
            let chinese = text(production)
            #expect(!chinese.isEmpty && !chinese.contains("rules."), "\(key)")
            #expect(chinese == text(zh), "\(key): production and its fixture copy agree")
            // A fallback to the Chinese fixture would make these equal.
            #expect(text(en) != chinese && text(fr) != chinese, "\(key)")
        }
        #expect(warning.message(localizer: production).contains("get"))
        // Numbers are formatted for the language (grouping included), inside one whole sentence.
        #expect(RuleDraftIssue.fieldTooLong.message(limits: limits, localizer: en)
            == "This value is longer than the 8,192-byte limit for one field.")
    }

    @Test func englishCountsAndFrenchReorderedArgumentsUseWholeSentences() throws {
        let fixtures = try fixtureBundle()
        let en = Localizer(bundle: fixtures, preferredLanguages: ["en"])
        #expect(en.format("rules.list.count", arguments: [0]) == "0 rules")
        #expect(en.format("rules.list.count", arguments: [1]) == "1 rule")
        #expect(en.format("rules.list.count", arguments: [200]) == "200 rules")
        #expect(L10n.format("rules.list.count", 3) == "3 条规则")
        let fr = Localizer(bundle: fixtures, preferredLanguages: ["fr"])
        #expect(RulePresentation.matchSummary(RuleMatcher(hostPattern: "a.test", statusRange: 500...599), localizer: fr)
            == "statut 500–599 pour *://a.test/*")
        #expect(en.format("rules.reset.done", arguments: ["rules.corrupt-x.json"])
            == "The rules were reset. The unreadable file was kept as rules.corrupt-x.json.")
    }

    @Test func theEnableCheckboxOfARuleRowNamesTheRuleInEveryLanguage() throws {
        // The checkbox of a rule row is its own accessibility control; its label says which rule it enables.
        let fixtures = try fixtureBundle()
        for (language, expected) in [("en", "Enable Mock users"), ("fr", "Activer Mock users"), ("zh-Hans", "启用 Mock users")] {
            let localizer = Localizer(bundle: fixtures, preferredLanguages: [language])
            #expect(localizer.format("rules.list.enableRule", arguments: ["Mock users"]) == expected, "\(language)")
        }
        #expect(L10n.format("rules.list.enableRule", "Mock users") == "启用 Mock users")
    }

    @Test func ruleIdentityAndContentNeverDependOnTheLanguage() throws {
        let fixtures = try fixtureBundle()
        let en = Localizer(bundle: fixtures, preferredLanguages: ["en"])
        let zh = Localizer(bundle: fixtures, preferredLanguages: ["zh-Hans"])
        #expect(RulePresentation.matchSummary(RuleMatcher(), localizer: en) != RulePresentation.matchSummary(RuleMatcher(), localizer: zh))
        // Drafts take names and matchers from the captured request only, never from translated text.
        let flow = FlowStoreFlow.sample
        let first = RuleEditorDraft.fromFlow(flow, kind: .breakpoint)
        let second = RuleEditorDraft.fromFlow(flow, kind: .breakpoint)
        #expect(first.validate(order: 0, limits: RulesLimits()).rule?.conditions == second.validate(order: 0, limits: RulesLimits()).rule?.conditions)
        #expect(first.name == "api.example.test")
        #expect(RuleKind.allCases.map(\.rawValue) == ["mapLocal", "mapLocalDirectory", "mapRemote", "editHeaders", "breakpoint", "rewriteBody", "rewriteStatus", "mark", "comment", "hide"])
    }

    @Test func everyLiteralRulesKeyInTheAppExistsInProduction() throws {
        let production = Set(try table(L10n.bundle, "zh-Hans").strings.keys)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let pattern = try NSRegularExpression(pattern: #""(rules\.[A-Za-z0-9_.]+)""#)
        var used: Set<String> = []
        for directory in ["App", "Packages/AppCore/Sources"] {
            let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent(directory), includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                guard url.pathExtension == "swift", let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    let key = (text as NSString).substring(with: match.range(at: 1))
                    if !key.hasSuffix(".") { used.insert(key) }  // prefixes of typed keys are checked above
                }
            }
        }
        #expect(used.count > 20)
        #expect(used.subtracting(production).sorted() == [])
    }
}

private enum FlowStoreFlow {
    static var sample: Flow {
        Flow(id: 1, scheme: "https", method: "GET", host: "api.example.test", port: 443, path: "/items?id=1&id=2")
    }
}
