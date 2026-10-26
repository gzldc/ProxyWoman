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

private let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Every `"<prefix>…"` string literal in the given source files (a literal that ends with "." is a
/// prefix a key is built from, not a key).
private func literalKeys(prefix: String, in files: [String]) throws -> Set<String> {
    let pattern = try NSRegularExpression(pattern: "\"(" + NSRegularExpression.escapedPattern(for: prefix) + #"[A-Za-z0-9_.]+)""#)
    var used: Set<String> = []
    for file in files {
        let text = try String(contentsOf: sourceRoot.appendingPathComponent(file), encoding: .utf8)
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let key = (text as NSString).substring(with: match.range(at: 1))
            if !key.hasSuffix(".") { used.insert(key) }
        }
    }
    return used
}

/// Every Swift source file of the app target and of all packages (tests excluded), relative to the repository root.
private func productionSources() throws -> [String] {
    var files: [String] = []
    var roots = [sourceRoot.appendingPathComponent("App")]
    let packages = sourceRoot.appendingPathComponent("Packages")
    for package in try FileManager.default.contentsOfDirectory(atPath: packages.path) {
        roots.append(packages.appendingPathComponent(package).appendingPathComponent("Sources"))
    }
    for directory in roots {
        guard let enumerator = FileManager.default.enumerator(atPath: directory.path) else { continue }
        for case let name as String in enumerator where name.hasSuffix(".swift") {
            files.append(String(directory.appendingPathComponent(name).path.dropFirst(sourceRoot.path.count + 1)))
        }
    }
    return files
}

/// The editor of the two new rule kinds (P2b task 7).
private let editorKeys: [String] = [
    "rules.kind.rewriteBody", "rules.kind.rewriteStatus",
    "rules.rewriteBody.find", "rules.rewriteBody.syntax.regex", "rules.rewriteBody.scope", "rules.rewriteBody.scope.all", "rules.rewriteBody.scope.first",
    "rules.rewriteStatus.status", "rules.rewriteStatus.includeLocal", "rules.issue.emptyFind", "rules.issue.findTooLong",
]

/// The rule list lines.
private let summaryKeys: [String] = ["rules.summary.rewriteBody.request", "rules.summary.rewriteBody.response", "rules.summary.rewriteStatus"]

/// What happened to a message, one sentence per rule; each takes the rule name.
private let outcomeKeys: [String] = [
    "ruleOutcome.bodyNoMatch", "ruleOutcome.bodySkippedTooLarge", "ruleOutcome.bodySkippedNotText",
    "ruleOutcome.bodySkippedUndecodable", "ruleOutcome.bodySkippedBreakpoint", "ruleOutcome.bodySkippedLocalRoute",
    "ruleOutcome.bodySkippedNoBody", "ruleOutcome.bodySkippedUnavailable", "ruleOutcome.bodySkippedBusy",
    "ruleOutcome.bodySkippedAborted", "ruleOutcome.statusSkippedLocal",
]

/// Every key P2b added by task 7. Later tasks append their own list here.
private let p2bKeys: [String] = editorKeys + summaryKeys + outcomeKeys

@Suite(.productionChinese) struct P2bAutoRewriteLocalizationTests {
    @Test func everyP2bKeyExistsAndIsTranslatedInEveryLanguageWithTheSameArguments() throws {
        #expect(p2bKeys.count == Set(p2bKeys).count)
        let production = try strings(L10n.bundle, "zh-Hans")
        let fixtures = try fixtureBundle()
        let en = try strings(fixtures, "en")
        let fr = try strings(fixtures, "fr")
        let zh = try strings(fixtures, "zh-Hans")
        for key in p2bKeys {
            let chinese = try #require(production[key], "\(key) missing in production")
            #expect(!chinese.isEmpty && chinese != key, "\(key)")
            #expect(zh[key] == chinese, "\(key): production and its fixture copy agree")
            let english = try #require(en[key], "\(key) missing in en")
            let french = try #require(fr[key], "\(key) missing in fr")
            #expect(english != chinese && french != chinese && english != key && french != key, "\(key) is translated")
            #expect(specifiers(english) == specifiers(chinese) && specifiers(french) == specifiers(chinese), "\(key) arguments")
        }
    }

    @Test func summaryAndOutcomeTextsTakeTheDocumentedArguments() throws {
        let production = try strings(L10n.bundle, "zh-Hans")
        #expect(specifiers(try #require(production["rules.summary.rewriteBody.request"])) == ["1:@", "2:@", "3:@"])
        #expect(specifiers(try #require(production["rules.summary.rewriteBody.response"])) == ["1:@", "2:@", "3:@"])
        #expect(specifiers(try #require(production["rules.summary.rewriteStatus"])) == ["1:@", "2:d"])
        for key in outcomeKeys {
            #expect(specifiers(try #require(production[key])) == ["1:@"], "\(key)")
        }
        for key in editorKeys where key != "rules.issue.findTooLong" {
            #expect(specifiers(try #require(production[key])) == [], "\(key)")
        }
        #expect(specifiers(try #require(production["rules.issue.findTooLong"])) == ["1:d"])
        #expect(L10n.format("rules.summary.rewriteStatus", "GET *://a.test/*", 404).contains("404"))
        #expect(L10n.format("ruleOutcome.bodyNoMatch", "屏蔽广告").contains("屏蔽广告"))
    }

    @Test func everyIssueCaseHasATranslatedMessageInEveryLanguage() throws {
        let production = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        let fixtures = try fixtureBundle()
        let en = Localizer(bundle: fixtures, preferredLanguages: ["en"])
        let fr = Localizer(bundle: fixtures, preferredLanguages: ["fr"])
        let limits = RulesLimits()
        let prod = try strings(L10n.bundle, "zh-Hans")
        #expect(!RuleDraftIssue.allCases.isEmpty)
        for issue in RuleDraftIssue.allCases {
            #expect(prod[issue.localizationKey] != nil, "\(issue)")
            let chinese = issue.message(limits: limits, localizer: production)
            #expect(!chinese.isEmpty && chinese != issue.localizationKey, "\(issue)")
            #expect(issue.message(limits: limits, localizer: en) != chinese, "\(issue) en")
            #expect(issue.message(limits: limits, localizer: fr) != chinese, "\(issue) fr")
        }
        #expect(Set(RuleDraftIssue.allCases.map(\.localizationKey)).isSuperset(of: ["rules.issue.emptyFind", "rules.issue.findTooLong"]))
    }

    @Test func kindTitlesAreTranslated() throws {
        let fixtures = try fixtureBundle()
        let en = try strings(fixtures, "en")
        for kind in [RuleKind.rewriteBody, .rewriteStatus] {
            #expect(!kind.title.isEmpty && kind.title != kind.localizationKey)
            #expect(en[kind.localizationKey] != nil && en[kind.localizationKey] != kind.title)
        }
    }

    @Test func summaryAndOutcomeKeysAreReachedByLiteralsInThePresentationSource() throws {
        let source = try String(
            contentsOf: sourceRoot.appendingPathComponent("Packages/AppCore/Sources/AppCore/Rules/RulePresentation.swift"),
            encoding: .utf8)
        let missing = (summaryKeys + outcomeKeys).filter { !source.contains("\"\($0)\"") }
        #expect(missing.sorted() == [])
    }

    /// Final sweep (P2b task 12), covering both key families of the phase: the rewrite editor, outcome
    /// and failure keys (this file) and the response mock keys (`P2bMockLocalizationTests.swift`).
    /// Any literal with one of the P2b prefixes anywhere in production source resolves to a production
    /// string, every production key in these families is reached by a literal (no exceptions: keys are
    /// never built from a prefix, see `LiteralKeyScanTests`), and each has an en/fr translation with
    /// the same arguments.
    @Test func everyP2bPrefixedLiteralInProductionSourcesIsDefinedAndEveryFamilyKeyIsReached() throws {
        let files = try productionSources()
        #expect(files.count > 100)
        let prefixes = ["rules.rewriteBody.", "rules.rewriteStatus.", "rules.mock.", "ruleOutcome.body",
                        "ruleOutcome.statusSkipped", "proxyLocalFailure.rewriteBody"]
        let production = try strings(L10n.bundle, "zh-Hans")
        var used: Set<String> = []
        for prefix in prefixes { used.formUnion(try literalKeys(prefix: prefix, in: files)) }
        // Both families are really scanned: the editor family, the outcome family, the failure family and the mock family.
        for family in prefixes {
            #expect(used.contains { $0.hasPrefix(family) }, "no literal with prefix \(family) found in the sources")
        }
        #expect(used.count >= 30)
        #expect(used.subtracting(production.keys).sorted() == [])

        let familyKeys = Set(production.keys.filter { key in prefixes.contains { key.hasPrefix($0) } })
        #expect(Set(MockBlockReason.allCases.map { "rules.mock.blocked." + $0.rawValue }).isSubset(of: used))
        #expect(familyKeys.subtracting(used).sorted() == [], "defined but never used")

        let fixtures = try fixtureBundle()
        let en = try strings(fixtures, "en")
        let fr = try strings(fixtures, "fr")
        let zh = try strings(fixtures, "zh-Hans")
        for key in familyKeys.sorted() {
            let chinese = try #require(production[key])
            #expect(zh[key] == chinese, "\(key): fixture zh-Hans agrees with production")
            #expect(specifiers(try #require(en[key], "\(key) missing in en")) == specifiers(chinese), "\(key) en arguments")
            #expect(specifiers(try #require(fr[key], "\(key) missing in fr")) == specifiers(chinese), "\(key) fr arguments")
        }
    }
}
