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

/// Match syntax in the rule editor and the rule list (P2 task 3).
private let matchSyntaxKeys: [String] = [
    "rules.match.syntax",
    "rules.match.syntax.literal", "rules.match.syntax.wildcard", "rules.match.syntax.regex",
    "rules.match.hint.wildcard", "rules.match.hint.regex",
    "rules.issue.invalidWildcard", "rules.issue.invalidRegex", "rules.issue.regexTooComplex", "rules.issue.mixedSyntax",
    "rules.summary.withSyntax", "rules.summary.syntaxWildcard", "rules.summary.syntaxRegex",
]

/// Match syntax in the Allow and Block lists (P2 task 4). `traffic.error.invalidPattern` is also in
/// `TrafficPresentation.messageKeys`, `traffic.field.syntax` in the traffic interface keys.
private let trafficSyntaxKeys: [String] = ["traffic.field.syntax", "traffic.error.invalidPattern"]

/// The Map Local directory rule editor (P2 task 8).
private let mapLocalDirectoryKeys: [String] = [
    "rules.kind.mapLocalDirectory",
    "rules.mapLocalDirectory.choose", "rules.mapLocalDirectory.directory", "rules.mapLocalDirectory.noDirectory",
    "rules.mapLocalDirectory.servesIndex", "rules.mapLocalDirectory.missing",
    "rules.mapLocalDirectory.missing.notFound", "rules.mapLocalDirectory.missing.network",
    "rules.mapLocalDirectory.prefixHelp", "rules.mapLocalDirectory.liveHelp",
    "rules.issue.directoryRequired", "rules.issue.directoryNeedsPrefix", "rules.issue.invalidDirectory",
    "rules.error.directory", "rules.summary.directory",
]

/// The Compose file body mode (P2 task 9).
private let composeFileBodyKeys: [String] = [
    "compose.body.mode.file", "compose.body.file.choose", "compose.body.file.replace", "compose.body.file.remove",
    "compose.body.file.summary", "compose.body.file.hint", "compose.body.file.importFailed", "compose.body.file.noFiles",
]

/// Bringing a large captured request body into Compose (P2 task 10).
private let composeCapturedBodyKeys: [String] = [
    "compose.body.importing", "compose.body.importFailed", "compose.issue.bodyImporting", "compose.body.importCancel",
]

/// Original or effective request drafts and the close confirmation (P2 task 11).
private let composeVariantCloseKeys: [String] = [
    "compose.edit.variant.effective", "compose.entry.blocked.noEffective", "compose.close.title", "compose.close.discardMessage",
    "compose.close.cancelSendMessage", "compose.close.bothMessage", "compose.close.confirm", "compose.close.stay",
]

/// A regular expression that timed out or was switched off (P2 fix wave).
private let patternHealthKeys: [String] = [
    "ruleOutcome.patternTimedOut", "ruleOutcome.patternDisabled", "ruleOutcome.unknownRule",
    "pattern.disabled.badge", "pattern.disabled.help.rule", "pattern.disabled.help.entry",
]

/// Every key P2 added, by task. Later tasks append their own list here.
private let p2Keys: [String] = matchSyntaxKeys + trafficSyntaxKeys + mapLocalDirectoryKeys + composeFileBodyKeys
    + composeCapturedBodyKeys + composeVariantCloseKeys + patternHealthKeys

/// Every `"<prefix>…"` string literal in the given source files.
private func literalKeys(prefix: String, in files: [String]) throws -> Set<String> {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let pattern = try NSRegularExpression(pattern: "\"(" + NSRegularExpression.escapedPattern(for: prefix) + #"[A-Za-z0-9_.]+)""#)
    var used: Set<String> = []
    for file in files {
        let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let key = (text as NSString).substring(with: match.range(at: 1))
            if !key.hasSuffix(".") { used.insert(key) }
        }
    }
    return used
}

@Suite(.productionChinese) struct P2RulesDepthLocalizationTests {
    @Test func everyP2KeyExistsAndIsTranslatedInEveryLanguageWithTheSameArguments() throws {
        #expect(p2Keys.count == Set(p2Keys).count)
        let production = try strings(L10n.bundle, "zh-Hans")
        let fixtures = try fixtureBundle()
        let en = try strings(fixtures, "en")
        let fr = try strings(fixtures, "fr")
        let zh = try strings(fixtures, "zh-Hans")
        for key in p2Keys {
            let chinese = try #require(production[key], "\(key) missing in production")
            #expect(!chinese.isEmpty && chinese != key, "\(key)")
            #expect(zh[key] == chinese, "\(key): production and its fixture copy agree")
            let english = try #require(en[key], "\(key) missing in en")
            let french = try #require(fr[key], "\(key) missing in fr")
            // "key" itself is what an unresolved lookup would return.
            #expect(english != chinese && french != chinese && english != key && french != key, "\(key) is translated")
            #expect(specifiers(english) == specifiers(chinese) && specifiers(french) == specifiers(chinese), "\(key) arguments")
        }
    }

    @Test func syntaxLabelTakesTheSummaryAndTheLabelInOrder() throws {
        let production = try strings(L10n.bundle, "zh-Hans")
        #expect(specifiers(try #require(production["rules.summary.withSyntax"])) == ["1:@", "2:@"])
        #expect(L10n.format("rules.summary.withSyntax", "GET *://a.test/*", "通配符") == "GET *://a.test/*（通配符）")
        for key in ["rules.summary.syntaxWildcard", "rules.summary.syntaxRegex", "rules.match.hint.wildcard", "rules.match.hint.regex"] {
            #expect(specifiers(try #require(production[key])) == [], "\(key)")
        }
    }

    @Test func everyLiteralMatchAndIssueKeyInTheEditorModelIsDefined() throws {
        let production = Set(try strings(L10n.bundle, "zh-Hans").keys)
        let files = [
            "Packages/AppCore/Sources/AppCore/Rules/RuleEditorDraft.swift",
            "Packages/AppCore/Sources/AppCore/Rules/RulePresentation.swift",
        ]
        let used = try literalKeys(prefix: "rules.match.", in: files).union(literalKeys(prefix: "rules.issue.", in: files))
        #expect(!used.isEmpty)
        #expect(used.subtracting(production).sorted() == [])
        // The syntax keys are reached through literals in the model, so none is left unused.
        let syntaxModelKeys = matchSyntaxKeys.filter { $0.hasPrefix("rules.match.") }
        #expect(Set(syntaxModelKeys).subtracting(used).sorted() == [])
    }

    @Test func everyIssueCaseHasATranslatedMessage() throws {
        let fixtures = try fixtureBundle()
        let production = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        let en = Localizer(bundle: fixtures, preferredLanguages: ["en"])
        let fr = Localizer(bundle: fixtures, preferredLanguages: ["fr"])
        let limits = RulesLimits()
        let issues: [RuleDraftIssue] = [
            .invalidWildcard, .invalidRegex, .regexTooComplex, .mixedSyntax,
            .directoryRequired, .directoryNeedsPrefix, .invalidDirectory,
        ]
        for issue in issues {
            let chinese = issue.message(limits: limits, localizer: production)
            #expect(!chinese.isEmpty && chinese != issue.localizationKey, "\(issue)")
            #expect(issue.message(limits: limits, localizer: en) != chinese && issue.message(limits: limits, localizer: fr) != chinese)
        }
    }

    @Test func directoryEditorKeysAreAllReachedByLiteralsInTheEditorSources() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = [
            "Packages/AppCore/Sources/AppCore/Rules/RuleEditorDraft.swift",
            "Packages/AppCore/Sources/AppCore/Rules/RulesEditorModel.swift",
            "Packages/AppCore/Sources/AppCore/Rules/RulePresentation.swift",
            "App/Views/Rules/ActionForms.swift",
            "App/Views/Rules/ActionFormsReturn.swift",
        ]
        let sources = try files.map { try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }.joined(separator: "\n")
        // Issue and kind keys are built from a case name (and checked by the issue test above).
        let literal = mapLocalDirectoryKeys.filter { !$0.hasPrefix("rules.issue.") && $0 != "rules.kind.mapLocalDirectory" }
        let missing = literal.filter { !sources.contains("\"\($0)\"") }
        #expect(missing.sorted() == [])
        #expect(RuleKind.mapLocalDirectory.localizationKey == "rules.kind.mapLocalDirectory")
        #expect(Set(RuleDraftIssue.allCases.map(\.localizationKey)).isSuperset(of: [
            "rules.issue.directoryRequired", "rules.issue.directoryNeedsPrefix", "rules.issue.invalidDirectory",
        ]))
    }

    @Test func composeFileBodyKeysAreReachedByLiteralsAndTakeNameThenSize() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = [
            "Packages/AppCore/Sources/AppCore/Compose/ComposeBodyFiles.swift",
            "Packages/AppCore/Sources/AppCore/Compose/ComposeViewModel.swift",
            "App/Views/Compose/ComposeContent.swift",
        ]
        let sources = try files.map { try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }.joined(separator: "\n")
        // The mode label is built from the case name (`compose.body.mode.` + rawValue).
        let missing = composeFileBodyKeys.filter { $0 != "compose.body.mode.file" && !sources.contains("\"\($0)\"") }
        #expect(missing.sorted() == [])
        #expect(ComposeBodyMode.file.localizationKey == "compose.body.mode.file")
        let production = try strings(L10n.bundle, "zh-Hans")
        #expect(specifiers(try #require(production["compose.body.file.summary"])) == ["1:@", "2:@"])
        #expect(L10n.format("compose.body.file.summary", "a.zip", "1 KB") == "a.zip（1 KB）")
    }

    @Test func capturedBodyKeysAreReachedAndProgressTakesDoneThenTotal() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = [
            "Packages/AppCore/Sources/AppCore/Compose/ComposeDraft.swift",
            "Packages/AppCore/Sources/AppCore/Compose/ComposeViewModel.swift",
            "App/Views/Compose/ComposeContent.swift",
        ]
        let sources = try files.map { try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }.joined(separator: "\n")
        // The issue text is built from the case name (`compose.issue.` + rawValue).
        let missing = composeCapturedBodyKeys.filter { $0 != "compose.issue.bodyImporting" && !sources.contains("\"\($0)\"") }
        #expect(missing.sorted() == [])
        #expect(ComposeDraftIssue.Code.bodyImporting.localizationKey == "compose.issue.bodyImporting")
        #expect(ComposeDraftIssue.Code.bodyImporting.severity == .error)
        #expect(ComposeBodyOmission.importFailed.localizationKey == "compose.body.importFailed")
        let production = try strings(L10n.bundle, "zh-Hans")
        #expect(specifiers(try #require(production["compose.body.importing"])) == ["1:@", "2:@"])
        #expect(L10n.format("compose.body.importing", "1 MB", "5 MB") == "正在导入请求正文… 1 MB / 5 MB")
    }

    @Test func variantAndCloseKeysAreReached() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = [
            "Packages/AppCore/Sources/AppCore/Compose/ComposeDraft.swift",
            "Packages/AppCore/Sources/AppCore/Compose/ComposeCloseAssessment.swift",
            "App/Views/FlowTableView.swift",
        ]
        let sources = try files.map { try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }.joined(separator: "\n")
        let missing = composeVariantCloseKeys.filter { !sources.contains("\"\($0)\"") }
        #expect(missing.sorted() == [])
        #expect(ComposeEntryBlock.noEffectiveRequest.localizationKey == "compose.entry.blocked.noEffective")
        #expect(Set(ComposeCloseAssessment.messageKeys) == Set(composeVariantCloseKeys.filter { $0.hasPrefix("compose.close.") }))
        for assessment in [ComposeCloseAssessment.confirmDiscard, .confirmCancelSend, .confirmBoth] {
            let text = try #require(assessment.messageText)
            #expect(!text.isEmpty && !text.hasPrefix("compose."))
        }
        #expect(ComposeCloseAssessment.none.messageText == nil)
        #expect(ComposeCloseAssessment.confirmText == "关闭" && ComposeCloseAssessment.stayText == "返回")
    }

    @Test func patternHealthKeysAreReachedByLiteralsAndTakeTheRuleName() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = [
            "Packages/AppCore/Sources/AppCore/Rules/RulePresentation.swift",
            "App/Views/Rules/RulesOutlineView.swift",
            "App/Views/Traffic/TrafficToolTabs.swift",
        ]
        let sources = try files.map { try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }.joined(separator: "\n")
        #expect(patternHealthKeys.filter { !sources.contains("\"\($0)\"") }.sorted() == [])
        let production = try strings(L10n.bundle, "zh-Hans")
        for key in ["ruleOutcome.patternTimedOut", "ruleOutcome.patternDisabled"] {
            #expect(specifiers(try #require(production[key])) == ["1:@"], "\(key)")
        }
        #expect(L10n.format("ruleOutcome.patternTimedOut", "屏蔽广告") == "规则「屏蔽广告」的正则表达式匹配超时，本次未匹配。")
    }

    /// Final sweep (P2 task 12): any literal with one of the P2 key prefixes, anywhere in production
    /// source, resolves to a production string. Keys built from a case name are covered by the
    /// per-feature tests above.
    @Test func everyP2PrefixedLiteralInProductionSourcesIsDefined() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var files: [String] = []
        var roots = [root.appendingPathComponent("App")]
        let packages = root.appendingPathComponent("Packages")
        for package in try FileManager.default.contentsOfDirectory(atPath: packages.path) {
            roots.append(packages.appendingPathComponent(package).appendingPathComponent("Sources"))
        }
        for directory in roots {
            guard let enumerator = FileManager.default.enumerator(atPath: directory.path) else { continue }
            for case let name as String in enumerator where name.hasSuffix(".swift") {
                files.append(String(directory.appendingPathComponent(name).path.dropFirst(root.path.count + 1)))
            }
        }
        #expect(files.count > 100)
        let prefixes = ["rules.match.", "rules.mapLocalDirectory.", "compose.body.file.", "compose.body.import",
                        "compose.close.", "compose.edit.variant.", "traffic.error.invalidPattern", "pattern.disabled.",
                        "ruleOutcome.pattern", "ruleOutcome.unknownRule"]
        let production = Set(try strings(L10n.bundle, "zh-Hans").keys)
        var used: Set<String> = []
        for prefix in prefixes { used.formUnion(try literalKeys(prefix: prefix, in: files)) }
        // Every P2 key in these families is reached by some literal or is defined, and none is undefined.
        #expect(used.count >= 20)
        #expect(used.subtracting(production).sorted() == [])
        let familyKeys = p2Keys.filter { key in prefixes.contains { key.hasPrefix($0) } }
        #expect(Set(familyKeys).subtracting(production).sorted() == [])
    }
}
