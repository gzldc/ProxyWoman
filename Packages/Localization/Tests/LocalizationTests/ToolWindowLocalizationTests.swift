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

private func specifiers(_ format: String) -> [String] {
    let pattern = try! NSRegularExpression(pattern: #"%(?:([0-9]+)\$)?[-+ #0-9.]*(?:hh|h|ll|l|q|L|z|j|t)?([@dDuUxXoOfeEgGcCsSp])"#)
    let text = format.replacingOccurrences(of: "%%", with: "")
    return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).enumerated().map { index, match in
        let position = Range(match.range(at: 1), in: text).map { String(text[$0]) } ?? String(index + 1)
        return position + ":" + (Range(match.range(at: 2), in: text).map { String(text[$0]) } ?? "")
    }.sorted()
}

/// The keys the shared tool-window skeleton (header, shortcut legend, bottom bar) uses, on top of each
/// tool's own description lines (`traffic.*.hint/order`, `rules.window.*`, `breakpoints.window.hint`).
private let toolWindowKeys: [String] = [
    "toolWindow.command.new", "toolWindow.command.edit", "toolWindow.command.delete",
    "toolWindow.command.duplicate", "toolWindow.command.toggle", "toolWindow.key.space",
    "toolWindow.legend.entry", "toolWindow.legend.separator",
    "toolWindow.empty.hint", "toolWindow.noMatches",
    "toolWindow.bar.help", "toolWindow.bar.onlyEnabled", "toolWindow.bar.filter", "toolWindow.bar.filterPrompt",
    "toolWindow.bar.more", "toolWindow.bar.clearAll", "toolWindow.bar.clearAllTitle",
    "toolWindow.bar.clearAllMessage", "toolWindow.bar.clearAllConfirm",
]

private let toolDescriptionKeys: [String] = [
    "traffic.allow.order", "traffic.block.hint", "traffic.block.order", "traffic.conditions.hint",
    "traffic.conditions.order", "rules.window.hint", "rules.window.order", "breakpoints.window.hint",
    "rules.actionSummary.mapLocal", "rules.actionSummary.assetUnknown", "rules.actionSummary.mapLocalDirectory",
    "rules.actionSummary.mapRemote", "rules.actionSummary.editHeaders.request", "rules.actionSummary.editHeaders.response",
    "rules.actionSummary.breakpoint.request", "rules.actionSummary.breakpoint.response",
    "rules.actionSummary.breakpointFullBody.request", "rules.actionSummary.breakpointFullBody.response",
    "rules.actionSummary.rewriteBody.request", "rules.actionSummary.rewriteBody.response", "rules.actionSummary.rewriteStatus",
]

/// Symbols and separators read the same in every language.
private let languageNeutral: Set<String> = ["toolWindow.legend.entry", "toolWindow.legend.separator"]

@Suite(.productionChinese) struct ToolWindowLocalizationTests {
    @Test func everyToolWindowKeyIsTranslatedInEveryLanguageWithTheSameArguments() throws {
        let every: [String] = toolWindowKeys + toolDescriptionKeys
        #expect(Set(every).count == every.count)
        let production = try strings(L10n.bundle, "zh-Hans")
        let fixtures = try fixtureBundle()
        let en = try strings(fixtures, "en")
        let fr = try strings(fixtures, "fr")
        let zh = try strings(fixtures, "zh-Hans")
        for key in every {
            let chinese = try #require(production[key], "\(key) missing in production")
            #expect(!chinese.isEmpty && chinese != key, "\(key)")
            #expect(zh[key] == chinese, "\(key): production and its fixture copy agree")
            let english = try #require(en[key], "\(key) missing in en")
            let french = try #require(fr[key], "\(key) missing in fr")
            if !languageNeutral.contains(key) {
                #expect(english != chinese && french != chinese && english != key && french != key, "\(key) is translated")
            }
            #expect(specifiers(english) == specifiers(chinese) && specifiers(french) == specifiers(chinese), "\(key) arguments")
        }
    }

    @Test func theToolWindowFamilyHasNoStaleKeys() throws {
        let production = try strings(L10n.bundle, "zh-Hans").keys.filter { $0.hasPrefix("toolWindow.") }
        #expect(Set(production) == Set(toolWindowKeys))
    }

    @Test func theLegendEntryTakesTheTitleThenTheKeys() {
        #expect(L10n.format("toolWindow.legend.entry", "新建", "⌘N") == "新建 ⌘N")
    }

    @Test func everyToolWindowKeyIsUsedByTheAppAndEveryLiteralOneIsDefined() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let all = NSRegularExpression.escapedPattern(for: "toolWindow.")
        let pattern = try NSRegularExpression(pattern: "\"(" + all + #"[A-Za-z0-9_.]+)""#)
        var used: Set<String> = []
        for directory in ["App", "Packages/AppCore/Sources"] {
            let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent(directory), includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                guard url.pathExtension == "swift", let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    used.insert((text as NSString).substring(with: match.range(at: 1)))
                }
            }
        }
        let production = Set(try strings(L10n.bundle, "zh-Hans").keys)
        #expect(used.subtracting(production).sorted() == [])
        #expect(Set(toolWindowKeys).subtracting(used).sorted() == [], "defined but never used")
    }
}
