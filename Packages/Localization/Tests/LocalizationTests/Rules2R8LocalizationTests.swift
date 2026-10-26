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

/// Keys added by each R8 task, appended by that task. Task 1 adds none.
private let r8Task2Keys: [String] = [
    "inspector.tab.overview", "inspector.tab.requestDetails", "inspector.tab.rules", "shell.page.traffic", "shell.page.compose",
]
private let r8Task3Keys: [String] = []
private let r8Task4Keys: [String] = []
private let r8Task5Keys: [String] = [
    "shell.rail.label", "shell.rail.settings", "shell.rail.help.traffic", "inspector.toggle.show", "inspector.toggle.hide",
    "inspector.empty",
]
private let r8Task6Keys: [String] = [
    "sourceBar.title",
    "sourceBar.all",
    "sourceBar.marked",
    "sourceBar.hidden",
    "sourceBar.undecrypted",
    "sourceBar.count.accessibility",
    "trafficTab.all",
    "trafficToolbar.filter",
    "trafficToolbar.filter.showHidden",
    "trafficToolbar.systemProxy",
    "trafficToolbar.search",
    "trafficToolbar.clear",
    "trafficToolbar.clearAll",
    "trafficToolbar.more",
    "trafficToolbar.showComments",
    "statusBar.selected",
    "statusBar.count",
    "mainToolbar.listening",
]
private let r8Task7Keys: [String] = [
    "overview.section.summary",
    "overview.section.timing",
    "overview.section.sizes",
    "overview.section.connection",
    "overview.section.rules",
    "overview.url",
    "overview.method",
    "overview.status",
    "overview.status.inProgress",
    "overview.app",
    "overview.started",
    "overview.completed",
    "overview.duration",
    "overview.sent",
    "overview.received",
    "overview.clientIP",
    "overview.remoteIP",
    "overview.protocol",
    "overview.tls",
    "overview.tls.decrypted",
    "overview.tls.tunnel",
    "overview.none",
]
private let r8Task8Keys: [String] = [
    "rules.card.summary",
    "rules.card.hits",
    "rules.card.groupCount",
    "rules.row.moveUp",
    "rules.row.moveDown",
    "rules.row.addGroup",
    "rules.row.addRule",
    "rules.row.duplicate",
    "rules.row.rename",
    "rules.row.editNote",
    "rules.row.delete",
]
private let r8Task9Keys: [String] = [
    "rules.tab.addRule",
    "rules.row.collapse",
    "rules.row.expand",
    "rules.tab.runSelected",
    "rules.tab.addGroup",
    "rules.tab.runAll",
    "rules.tab.import",
    "rules.tab.export",
    "rules.tab.deleteSelected",
    "rules.tab.fromTemplate",
    "rules.tab.empty",
    "rules.tab.switch",
    "rules.row.run",
    "rules.row.more",
    "rules.row.toggle",
    "rules.note.title",
    "rules.note.placeholder",
    "rules.note.save",
]
private let r8Task10Keys: [String] = [
    "execute.runBanner.running",
    "execute.runBanner.finished",
    "execute.runBanner.cancelled",
    "execute.runBanner.undo",
    "execute.runBanner.details",
    "execute.runBanner.stop",
    "execute.runBanner.dismiss",
    "execute.summary.title",
    "execute.runNow.busy",
    "execute.runNow.noRules",
    "execute.runNow.noFlows",
]
private let r8Task11Keys: [String] = [
    "rules.builder.matchCount",
    "rules.builder.stop.lockedReason",
]
private let r8Task12Keys: [String] = [
    "rules.builder.name",
    "rules.builder.nameRequired",
    "rules.builder.nameRequiredLabel",
    "rules.builder.conditions",
    "rules.builder.actions",
    "rules.builder.when",
    "rules.builder.then",
    "rules.builder.addCondition",
    "rules.builder.addAction",
    "rules.builder.stop",
    "rules.builder.stop.help",
    "rules.builder.sampleText",
    "rules.builder.background",
    "rules.builder.textColor",
    "rules.builder.clearValue",
    "rules.builder.caseSensitive",
    "rules.builder.duplicateAction",
    "rules.builder.deleteAction",
    "rules.builder.deleteCondition",
    "rules.builder.save",
    "rules.builder.cancel",
    "rules.builder.errorBanner",
]
private let r8Task13Keys: [String] = []
private let r8Task14Keys: [String] = [
    "breakpoints.inspector.paused.request",
    "breakpoints.inspector.paused.response",
    "breakpoints.inspector.ended.timedOut",
    "breakpoints.inspector.ended.aborted",
    "breakpoints.row.paused",
    "breakpoints.row.pausedA11y",
    "breakpoints.action.abort",
]
private let r8Task15Keys: [String] = [
    "compose.page.untitled",
    "compose.tab.title",
]
private let r8Task16Keys: [String] = [
    "compose.page.newTab",
    "compose.page.drafts",
    "compose.page.drafts.empty",
    "compose.page.closeTab",
    "compose.page.empty",
    "compose.page.deleteDraft",
    "compose.close.saveDraft",
    "compose.close.discard",
    "shell.rail.help.compose",
]
private let r8Task17Keys: [String] = [
    "settings.page.trafficControl.title",
    "settings.page.trafficControl.keywords",
    "settings.page.https.title",
    "settings.page.https.keywords",
    "settings.https.undecryptedHint",
]
private let r8Task18Keys: [String] = [
    "appCommands.showTraffic",
    "appCommands.showCompose",
    "appCommands.toggleInspector",
]
private let r8Task20Keys: [String] = [
    "compose.sections.accessibility",
]

private let r8F1Task3Keys: [String] = [
    "rules.editor2.occurrence.choice.any",
    "rules.editor2.occurrence.choice.specific",
    "rules.editor2.occurrence.count",
    "rules.editor2.occurrence.legacyHelp",
]

private let r8F1Task4Keys: [String] = [
    "rules.builder.autoName",
    "rules.builder.header.mode.all",
    "rules.builder.header.mode.any",
    "rules.builder.header.mode.none",
    "rules.builder.header.then",
    "rules.builder.matchedAt.connect",
    "rules.builder.matchedAt.request",
    "rules.builder.matchedAt.response",
    "rules.builder.matchedAt.completion",
    "rules.builder.matchedAt.help",
    "rules.builder.nameField.accessibility",
]

private let r8AllKeys: [String] =
    r8Task2Keys + r8Task3Keys + r8Task4Keys + r8Task5Keys + r8Task6Keys + r8Task7Keys + r8Task8Keys + r8Task9Keys
    + r8Task10Keys + r8Task11Keys + r8Task12Keys + r8Task13Keys + r8Task14Keys + r8Task15Keys + r8Task16Keys
    + r8Task17Keys + r8Task18Keys + r8Task20Keys + r8F1Task3Keys + r8F1Task4Keys

@Suite(.productionChinese) struct Rules2R8LocalizationTests {
    @Test func everyR8KeyIsInProductionAndFixturesWithTheSameArguments() throws {
        #expect(r8AllKeys.count == Set(r8AllKeys).count)
        let production = try strings(L10n.bundle, "zh-Hans")
        let fixtures = try fixtureBundle()
        let en = try strings(fixtures, "en")
        let fr = try strings(fixtures, "fr")
        let zh = try strings(fixtures, "zh-Hans")
        for key in r8AllKeys {
            let chinese = try #require(production[key], "\(key) missing in production")
            #expect(!chinese.isEmpty && chinese != key, "\(key)")
            #expect(zh[key] == chinese, "\(key): production and its fixture copy agree")
            let english = try #require(en[key], "\(key) missing in en")
            let french = try #require(fr[key], "\(key) missing in fr")
            #expect(!english.isEmpty && !french.isEmpty, "\(key)")
            #expect(english != key && french != key, "\(key) is translated")
            #expect(specifiers(english) == specifiers(chinese) && specifiers(french) == specifiers(chinese), "\(key) arguments")
        }
    }

    // MARK: Audit scans (source text, no GUI)

    private var repositoryRoot: URL {
        // .../Packages/Localization/Tests/LocalizationTests/<this file>
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func swiftFiles(under relative: String, includingTests: Bool) -> [URL] {
        let root = repositoryRoot.appendingPathComponent(relative)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { url in
            guard url.pathExtension == "swift" else { return false }
            let path = url.path
            if path.contains("/.build/") { return false }
            return includingTests || !path.contains("/Tests/")
        }
    }

    private func stringLiterals(in text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #""(?:[^"\\\n]|\\.)*""#)
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    @Test func noBrandWordInProductText() throws {
        let banned = ["fiddler", "telerik"]
        var offenders: [String] = []
        for relative in ["App", "Packages"] {
            for url in swiftFiles(under: relative, includingTests: false) {
                let text = try String(contentsOf: url, encoding: .utf8)
                for literal in stringLiterals(in: text) where banned.contains(where: { literal.localizedCaseInsensitiveContains($0) }) {
                    // The one allowlisted compatibility literal: a Classic file name used by imported rules.
                    if url.lastPathComponent == "MagicStringAction.swift", literal == "\"200_FiddlerGif\"" { continue }
                    offenders.append("\(url.lastPathComponent): \(literal)")
                }
            }
        }
        let production = try strings(L10n.bundle, "zh-Hans")
        for (key, value) in production where banned.contains(where: { value.localizedCaseInsensitiveContains($0) }) {
            offenders.append("zh-Hans \(key)")
        }
        let fixtures = try fixtureBundle()
        for language in ["zh-Hans", "en", "fr"] {
            for (key, value) in try strings(fixtures, language) where banned.contains(where: { value.localizedCaseInsensitiveContains($0) }) {
                offenders.append("\(language) fixture \(key)")
            }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }

    @Test func shellViewsUseTokensNotHexColors() throws {
        var files = swiftFiles(under: "App/Views/Shell", includingTests: true)
        for relative in ["App/Views/Rules/RulesTab.swift", "App/Views/Rules/RuleCardCell.swift", "App/Views/Compose/ComposePage.swift"] {
            files.append(repositoryRoot.appendingPathComponent(relative))
        }
        #expect(files.count >= 4)
        let forbidden = [
            try NSRegularExpression(pattern: #"Color\(\s*red:"#),
            try NSRegularExpression(pattern: #"NSColor\(\s*(?:srgbRed|calibratedRed|deviceRed|red):"#),
            try NSRegularExpression(pattern: "#colorLiteral"),
            try NSRegularExpression(pattern: #"0x[0-9A-Fa-f]{6}"#),
        ]
        var offenders: [String] = []
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            for regex in forbidden where regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                offenders.append("\(url.lastPathComponent): \(regex.pattern)")
            }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }
}
