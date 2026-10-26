import AppCore
import Foundation
import Localization
import MCPKit
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

/// Source files that build one of the MCP keys by interpolation (`"mcpPane.\(name)"`), which hides the key from every scan.
private func interpolatedKeyFiles(prefixes: [String], in files: [String]) throws -> [String] {
    let alternatives = prefixes.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
    let pattern = try NSRegularExpression(pattern: "\"(?:" + alternatives + #")[A-Za-z0-9_.]*\\\("#)
    return try files.filter { file in
        let text = try String(contentsOf: sourceRoot.appendingPathComponent(file), encoding: .utf8)
        return pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
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

/// The settings page entry (looked up from the page's raw value, so it is not a literal in the sources).
private let pageKeys: [String] = ["settings.page.mcp.title", "settings.page.mcp.keywords"]

/// Settings page texts that take no argument.
private let plainPaneKeys: [String] = [
    "mcpPane.enable", "mcpPane.enableHelp",
    "mcpPane.status.label", "mcpPane.status.off", "mcpPane.status.listening", "mcpPane.status.unavailable",
    "mcpPane.connect.title", "mcpPane.connect.clientPicker",
    "mcpPane.connect.hint.claudeDesktop", "mcpPane.connect.hint.claudeCode", "mcpPane.connect.hint.cursor",
    "mcpPane.connect.snippetLabel", "mcpPane.connect.copy", "mcpPane.connect.copied",
    "mcpPane.write.title", "mcpPane.write.intro", "mcpPane.write.createRule", "mcpPane.write.updateRule",
    "mcpPane.write.setRuleEnabled", "mcpPane.write.setRecording", "mcpPane.write.allowEnabling",
    "mcpPane.write.allowEnablingWarning",
    "mcpPane.privacy.title", "mcpPane.privacy.redact", "mcpPane.privacy.redactOnHelp", "mcpPane.privacy.redactOffWarning",
    "mcpPane.privacy.extraNames", "mcpPane.privacy.extraNamesPlaceholder", "mcpPane.privacy.extraNamesHelp",
    "mcpPane.activity.title", "mcpPane.activity.empty", "mcpPane.activity.clear", "mcpPane.activity.unknownClient",
    "mcpPane.activity.column.time", "mcpPane.activity.column.client", "mcpPane.activity.column.tool",
    "mcpPane.activity.column.result", "mcpPane.activity.column.duration",
]

/// Product names, written the same in every language.
private let clientNameKeys: [String] = ["mcpPane.client.claudeDesktop", "mcpPane.client.claudeCode", "mcpPane.client.cursor"]

/// Why the server did not start: one sentence per `MCPSocketServer.StartFailure` case.
private let failureKeysTakingNumber: [String] = [
    "mcpPane.failure.directoryFailed", "mcpPane.failure.bindFailed", "mcpPane.failure.handshakeFailed",
]
private let failureKeysTakingName: [String] = ["mcpPane.failure.alreadyRunning"]
private let failureKeysTakingNothing: [String] = [
    "mcpPane.failure.pathTooLong", "mcpPane.failure.directoryUnsafe", "mcpPane.failure.tokenFailed",
]

/// One sentence per `MCPCallOutcome`.
private let outcomeKeysTakingText: [String] = ["mcp.outcome.deniedPermission", "mcp.outcome.failed"]
private let outcomeKeysTakingNothing: [String] = [
    "mcp.outcome.ok", "mcp.outcome.deniedDisabled", "mcp.outcome.deniedEnabling", "mcp.outcome.invalidArguments",
]

private let argumentPaneKeys: [String] = [
    "mcpPane.connect.requiresRunning", "mcpPane.activity.milliseconds",
]

/// Every key P7a task 10 added.
private let p7Keys: [String] =
    pageKeys + plainPaneKeys + clientNameKeys + failureKeysTakingNumber + failureKeysTakingName
    + failureKeysTakingNothing + outcomeKeysTakingText + outcomeKeysTakingNothing + argumentPaneKeys

/// The two families whose every defined key must be reached by a literal in the production sources.
private let paneAndOutcomePrefixes = ["mcpPane.", "mcp.outcome."]

@Suite(.productionChinese) struct P7MCPLocalizationTests {
    @Test func everyP7KeyExistsAndIsTranslatedInEveryLanguageWithTheSameArguments() throws {
        #expect(p7Keys.count == Set(p7Keys).count)
        let production = try strings(L10n.bundle, "zh-Hans")
        let fixtures = try fixtureBundle()
        let en = try strings(fixtures, "en")
        let fr = try strings(fixtures, "fr")
        let zh = try strings(fixtures, "zh-Hans")
        for key in p7Keys {
            let chinese = try #require(production[key], "\(key) missing in production")
            #expect(!chinese.isEmpty && chinese != key, "\(key)")
            #expect(zh[key] == chinese, "\(key): production and its fixture copy agree")
            let english = try #require(en[key], "\(key) missing in en")
            let french = try #require(fr[key], "\(key) missing in fr")
            #expect(!english.isEmpty && !french.isEmpty && english != key && french != key, "\(key)")
            if clientNameKeys.contains(key) {
                #expect(english == chinese && french == chinese, "\(key) is a product name")
            } else {
                #expect(english != chinese && french != chinese, "\(key) is translated")
            }
            #expect(specifiers(english) == specifiers(chinese) && specifiers(french) == specifiers(chinese), "\(key) arguments")
        }
    }

    @Test func textsTakeTheDocumentedArguments() throws {
        let production = try strings(L10n.bundle, "zh-Hans")
        func arguments(_ key: String) throws -> [String] { specifiers(try #require(production[key], "\(key)")) }
        for key in pageKeys + plainPaneKeys + clientNameKeys + failureKeysTakingNothing + outcomeKeysTakingNothing {
            #expect(try arguments(key) == [], "\(key)")
        }
        for key in failureKeysTakingNumber { #expect(try arguments(key) == ["1:d"], "\(key)") }
        for key in failureKeysTakingName + outcomeKeysTakingText { #expect(try arguments(key) == ["1:@"], "\(key)") }
        #expect(try arguments("mcpPane.connect.requiresRunning") == ["1:@"])
        #expect(try arguments("mcpPane.activity.milliseconds") == ["1:d"])
    }

    @Test func theSettingsPageHasATranslatedTitleAndKeywordsInEveryLanguage() throws {
        let production = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        let fixtures = try fixtureBundle()
        let en = Localizer(bundle: fixtures, preferredLanguages: ["en"])
        let fr = Localizer(bundle: fixtures, preferredLanguages: ["fr"])
        let chinese = SettingsPage.mcp.title(using: production)
        #expect(chinese == "MCP（AI 接入）")
        #expect(SettingsPage.mcp.title(using: en) != chinese && SettingsPage.mcp.title(using: fr) != chinese)
        #expect(SettingsPage.mcp.keywords(using: en) != SettingsPage.mcp.keywords(using: production))
        #expect(SettingsPage.mcp.icon == "sparkles")
        #expect(SettingsPage.mcp.matches("MCP", using: production) && SettingsPage.mcp.matches("Claude", using: en))
        #expect(!SettingsPage.tools.matches("Claude Cursor 套接字", using: production))
    }

    @Test func everyStartFailureHasATranslatedSentence() throws {
        let production = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        let fixtures = try fixtureBundle()
        let en = Localizer(bundle: fixtures, preferredLanguages: ["en"])
        let fr = Localizer(bundle: fixtures, preferredLanguages: ["fr"])
        // One value per case; the production switch has no default, so a new case is a compile error there.
        let failures: [MCPSocketServer.StartFailure] = [
            .pathTooLong, .directoryUnsafe, .directoryFailed(28), .bindFailed(13), .tokenFailed, .alreadyRunning,
            .handshakeFailed(30),
        ]
        var sentences: Set<String> = []
        for failure in failures {
            let chinese = MCPPresentation.failureText(failure, appName: "ProxyWoman", localizer: production)
            let english = MCPPresentation.failureText(failure, appName: "ProxyWoman", localizer: en)
            let french = MCPPresentation.failureText(failure, appName: "ProxyWoman", localizer: fr)
            #expect(!chinese.isEmpty && !chinese.contains("mcpPane."), "\(failure)")
            #expect(english != chinese && french != chinese && english != french, "\(failure)")
            #expect(!english.contains("mcpPane.") && !french.contains("mcpPane."), "\(failure)")
            #expect(!english.contains("%") && !french.contains("%") && !chinese.contains("%"), "\(failure) has a bare specifier")
            sentences.insert(chinese)
        }
        #expect(sentences.count == failures.count, "every case has its own sentence")
        #expect(MCPPresentation.failureText(.directoryFailed(28), appName: "ProxyWoman", localizer: en).contains("28"))
        #expect(MCPPresentation.failureText(.bindFailed(13), appName: "ProxyWoman", localizer: fr).contains("13"))
        #expect(MCPPresentation.failureText(.handshakeFailed(30), appName: "ProxyWoman", localizer: production).contains("30"))
        #expect(MCPPresentation.failureText(.alreadyRunning, appName: "Fox", localizer: en).contains("Fox"))
        // The path-too-long sentence is its own, about the isolated directory.
        #expect(MCPPresentation.failureText(.pathTooLong, appName: "ProxyWoman", localizer: production).contains("隔离目录路径太长"))
    }

    @Test func everyCallOutcomeHasATranslatedSentence() throws {
        let production = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        let fixtures = try fixtureBundle()
        let en = Localizer(bundle: fixtures, preferredLanguages: ["en"])
        let fr = Localizer(bundle: fixtures, preferredLanguages: ["fr"])
        let outcomes: [MCPCallOutcome] = [
            .ok, .denied(.disabled), .denied(.permission(tool: "create_rule")), .denied(.enablingNotAllowed),
            .invalidArguments, .failed(code: "not_found"),
        ]
        var sentences: Set<String> = []
        for outcome in outcomes {
            let chinese = MCPPresentation.outcomeText(outcome, localizer: production)
            let english = MCPPresentation.outcomeText(outcome, localizer: en)
            let french = MCPPresentation.outcomeText(outcome, localizer: fr)
            #expect(!chinese.isEmpty && !chinese.contains("mcp.outcome."), "\(outcome)")
            #expect(english != chinese && french != chinese && english != french, "\(outcome)")
            #expect(!english.contains("mcp.outcome.") && !french.contains("mcp.outcome."), "\(outcome)")
            #expect(!english.contains("%") && !french.contains("%") && !chinese.contains("%"), "\(outcome) has a bare specifier")
            sentences.insert(chinese)
        }
        #expect(sentences.count == outcomes.count)
        let denied = MCPPresentation.outcomeText(.denied(.permission(tool: "set_recording")), localizer: en)
        #expect(denied.contains("set_recording"))
        #expect(MCPPresentation.outcomeText(.failed(code: "too_large"), localizer: fr).contains("too_large"))
        // Text from the AI client with a format specifier in it stays literal.
        #expect(MCPPresentation.outcomeText(.failed(code: "%@%d"), localizer: en).contains("%@%d"))
    }

    /// Every literal with an MCP prefix anywhere in production source resolves to a production string, every
    /// production key of the pane and outcome families is reached by a literal, and no key is built by
    /// concatenation or interpolation.
    @Test func everyMCPPrefixedLiteralInProductionSourcesIsDefinedAndEveryFamilyKeyIsReached() throws {
        let files = try productionSources()
        #expect(files.count > 100)
        let prefixes = paneAndOutcomePrefixes + ["settings.page.mcp"]
        let production = try strings(L10n.bundle, "zh-Hans")
        var used: Set<String> = []
        for prefix in prefixes { used.formUnion(try literalKeys(prefix: prefix, in: files)) }
        for family in paneAndOutcomePrefixes {
            #expect(used.contains { $0.hasPrefix(family) }, "no literal with prefix \(family) found in the sources")
        }
        #expect(used.subtracting(production.keys).sorted() == [])
        #expect(try interpolatedKeyFiles(prefixes: prefixes, in: files) == [], "a key is built by interpolation")

        let familyKeys = Set(production.keys.filter { key in paneAndOutcomePrefixes.contains { key.hasPrefix($0) } })
        #expect(familyKeys.subtracting(used).sorted() == [], "defined but never used")
        #expect(familyKeys.isSubset(of: Set(p7Keys)), "a production key of the family is missing from this test's list")
        #expect(Set(p7Keys).subtracting(pageKeys).isSubset(of: familyKeys))

        let fixtures = try fixtureBundle()
        let en = try strings(fixtures, "en")
        let fr = try strings(fixtures, "fr")
        let zh = try strings(fixtures, "zh-Hans")
        for key in familyKeys.sorted() + pageKeys {
            let chinese = try #require(production[key])
            #expect(zh[key] == chinese, "\(key): fixture zh-Hans agrees with production")
            #expect(specifiers(try #require(en[key], "\(key) missing in en")) == specifiers(chinese), "\(key) en arguments")
            #expect(specifiers(try #require(fr[key], "\(key) missing in fr")) == specifiers(chinese), "\(key) fr arguments")
        }
    }
}
