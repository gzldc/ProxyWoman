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

/// The keys the traffic tools window, menus, status badges and flow context menu use (T9), on top
/// of `TrafficPresentation.messageKeys`.
private let interfaceKeys: [String] = [
    "traffic.window.title",
    "traffic.column.comment",  // R2 task 11: the flow table's optional comment column
    "traffic.tab.allow", "traffic.tab.block", "traffic.tab.conditions",
    "traffic.allow.title", "traffic.allow.hint", "traffic.allow.empty", "traffic.allow.inertHint", "traffic.allow.order",
    "traffic.block.hint", "traffic.block.order", "traffic.conditions.hint", "traffic.conditions.order",
    "traffic.block.title", "traffic.block.mode", "traffic.block.modeShow", "traffic.block.modeHide",
    "traffic.block.pathHint", "traffic.block.empty",
    "traffic.noCaching.menu",
    "traffic.conditions.menu", "traffic.conditions.off", "traffic.conditions.custom",
    "traffic.conditions.enable", "traffic.conditions.global", "traffic.conditions.globalNone",
    "traffic.conditions.hostRules", "traffic.conditions.hostRulesEmpty", "traffic.conditions.unlimited",
    "traffic.field.host", "traffic.field.hostPrompt", "traffic.field.port", "traffic.field.method",
    "traffic.field.pathPrefix", "traffic.field.download", "traffic.field.upload", "traffic.field.latency",
    "traffic.field.loss", "traffic.field.enabled", "traffic.field.selection", "traffic.field.any",
    "traffic.field.syntax",
    "traffic.action.add", "traffic.action.remove", "traffic.action.apply",
    "traffic.command.conditionsWindow",
    "traffic.flowMenu.blockHost", "traffic.flowMenu.captureOnlyHost", "traffic.flowMenu.throttleHost",
    "traffic.flowMenu.failedTitle",
    "traffic.status.openHint",
]

/// The keys the repeat-send backend (T10) and the repeat sheet and menu entry (T11) use.
private let repeatKeys: [String] = [
    "repeat.flow.appName", "repeat.safety.confirm", "repeat.failure.invalidDraft",
    "repeat.entry.menu",
    "repeat.sheet.title", "repeat.sheet.count", "repeat.sheet.concurrency", "repeat.sheet.interval",
    "repeat.sheet.applyRules", "repeat.sheet.start", "repeat.sheet.cancel", "repeat.sheet.close",
    "repeat.sheet.progress", "repeat.sheet.resultsHint", "repeat.sheet.failures",
    "repeat.sheet.failureRow", "repeat.sheet.failureRunRow",
    "repeat.sheet.error.notNumber", "repeat.sheet.error.range",
]

/// Every `"<prefix>…"` string literal in the App and AppCore sources.
private func literalKeys(prefix: String) throws -> Set<String> {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let pattern = try NSRegularExpression(pattern: "\"(" + NSRegularExpression.escapedPattern(for: prefix) + #"[A-Za-z0-9_.]+)""#)
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
    return used
}

@Suite(.productionChinese) struct TrafficToolsLocalizationTests {
    @Test func interfaceKeysExistAndAreTranslatedInEveryLanguage() throws {
        #expect(interfaceKeys.count == Set(interfaceKeys).count)
        let production = try strings(L10n.bundle, "zh-Hans")
        let fixtures = try fixtureBundle()
        let en = try strings(fixtures, "en")
        let fr = try strings(fixtures, "fr")
        let zh = try strings(fixtures, "zh-Hans")
        for key in interfaceKeys {
            let chinese = try #require(production[key], "\(key) missing in production")
            #expect(!chinese.isEmpty, "\(key)")
            #expect(zh[key] == chinese, "\(key): production and its fixture copy agree")
            let english = try #require(en[key], "\(key) missing in en")
            let french = try #require(fr[key], "\(key) missing in fr")
            // "key" itself is what an unresolved lookup would return.
            #expect(english != chinese && french != chinese && english != key && french != key, "\(key) is translated")
            #expect(specifiers(english) == specifiers(chinese) && specifiers(french) == specifiers(chinese), "\(key) arguments")
        }
    }

    @Test func repeatKeysExistAndAreTranslatedInEveryLanguageWithTheSameArguments() throws {
        let production = try strings(L10n.bundle, "zh-Hans")
        let fixtures = try fixtureBundle()
        let en = try strings(fixtures, "en")
        let fr = try strings(fixtures, "fr")
        let zh = try strings(fixtures, "zh-Hans")
        #expect(repeatKeys.count == Set(repeatKeys).count)
        for key in repeatKeys {
            let chinese = try #require(production[key], "\(key) missing in production")
            #expect(!chinese.isEmpty && chinese != key, "\(key)")
            #expect(zh[key] == chinese, "\(key): production and its fixture copy agree")
            let english = try #require(en[key], "\(key) missing in en")
            let french = try #require(fr[key], "\(key) missing in fr")
            #expect(english != chinese && french != chinese && english != key && french != key, "\(key) is translated")
            #expect(specifiers(english) == specifiers(chinese) && specifiers(french) == specifiers(chinese), "\(key) arguments")
        }
        // Counts stay numeric (%ld), never pre-formatted text.
        #expect(specifiers(try #require(production["repeat.flow.appName"])) == ["1:d"])
        #expect(specifiers(try #require(production["repeat.safety.confirm"])) == ["1:d"])
        #expect(specifiers(try #require(production["repeat.failure.invalidDraft"])) == [])
        #expect(L10n.format("repeat.flow.appName", 3) == "重复发送 #3")
        // The sheet's counts are numeric too; failure rows take the index, code and message in order.
        #expect(specifiers(try #require(production["repeat.sheet.progress"])) == ["1:d", "2:d", "3:d", "4:d", "5:d"])
        #expect(specifiers(try #require(production["repeat.sheet.failures"])) == ["1:d"])
        #expect(specifiers(try #require(production["repeat.sheet.failureRow"])) == ["1:d", "2:@", "3:@"])
        #expect(specifiers(try #require(production["repeat.sheet.failureRunRow"])) == ["1:@", "2:@"])
        #expect(specifiers(try #require(production["repeat.sheet.error.notNumber"])) == [])
        #expect(specifiers(try #require(production["repeat.sheet.error.range"])) == ["1:d", "2:d"])
        #expect(L10n.format("repeat.sheet.error.range", 1, 1000) == "请输入 1 到 1,000 之间的整数")
        #expect(L10n.format("repeat.sheet.progress", 3, 10, 2, 1, 0) == "已发送 3 / 10，成功 2，失败 1，取消 0")
    }

    @Test func everyRepeatKeyIsTranslatedInEveryFixtureAndNothingIsStale() throws {
        let production = try strings(L10n.bundle, "zh-Hans").filter { $0.key.hasPrefix("repeat.") }
        #expect(Set(production.keys) == Set(repeatKeys))
        let fixtures = try fixtureBundle()
        for language in ["en", "fr", "zh-Hans"] {
            let fixture = try strings(fixtures, language).filter { $0.key.hasPrefix("repeat.") }
            #expect(Set(production.keys).subtracting(fixture.keys).sorted() == [], "missing in \(language)")
            #expect(Set(fixture.keys).subtracting(production.keys).sorted() == [], "stale in \(language)")
            for (key, value) in production {
                guard let translated = fixture[key] else { continue }
                #expect(specifiers(translated) == specifiers(value), "\(language) \(key) arguments")
            }
        }
    }

    @Test func everyLiteralRepeatKeyInTheAppExistsInProduction() throws {
        let production = Set(try strings(L10n.bundle, "zh-Hans").keys)
        // The run's own failure code reads like a key but is a machine code, not text.
        let used = try literalKeys(prefix: "repeat.").subtracting(["repeat.invalidDraft"])  // RepeatRunModel.invalidDraftCode
        #expect(!used.isEmpty)
        #expect(used.subtracting(production).sorted() == [])
        // The sheet and the menu entry really use their keys, so none is left behind unused.
        #expect(Set(repeatKeys).subtracting(used).sorted() == [])
    }

    @Test func localizationKeysExist() throws {
        let fixtures = try fixtureBundle()
        let zh = Localizer(bundle: fixtures, preferredLanguages: ["zh-Hans"])
        let en = Localizer(bundle: fixtures, preferredLanguages: ["en"])
        let fr = Localizer(bundle: fixtures, preferredLanguages: ["fr"])
        let production = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        let keys = TrafficPresentation.messageKeys
        #expect(keys.count == Set(keys).count)
        #expect(keys.count >= 9 + 9 + 8 + 1)
        for key in keys {
            #expect(key.hasPrefix("traffic."), "\(key)")
            let chinese = production.string(key)
            #expect(chinese != key && !chinese.isEmpty, "\(key)")
            #expect(chinese == zh.string(key), "\(key): production and its fixture copy agree")
            #expect(en.string(key) != chinese && fr.string(key) != chinese, "\(key)")
        }
    }

    @Test func everyTrafficKeyIsTranslatedInEveryFixtureWithTheSameArguments() throws {
        let production = try strings(L10n.bundle, "zh-Hans").filter { $0.key.hasPrefix("traffic.") }
        #expect(Set(production.keys) == Set(TrafficPresentation.messageKeys).union(interfaceKeys))
        let fixtures = try fixtureBundle()
        for language in ["en", "fr", "zh-Hans"] {
            let fixture = try strings(fixtures, language).filter { $0.key.hasPrefix("traffic.") }
            #expect(Set(production.keys).subtracting(fixture.keys).sorted() == [], "missing in \(language)")
            #expect(Set(fixture.keys).subtracting(production.keys).sorted() == [], "stale in \(language)")
            for (key, value) in production {
                guard let translated = fixture[key] else { continue }
                #expect(specifiers(translated) == specifiers(value), "\(language) \(key) arguments")
            }
        }
    }

    @Test func everyLiteralTrafficKeyInTheAppExistsInProduction() throws {
        let production = Set(try strings(L10n.bundle, "zh-Hans").keys)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let pattern = try NSRegularExpression(pattern: #""(traffic\.[A-Za-z0-9_.]+)""#)
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
        #expect(!used.isEmpty)
        #expect(used.subtracting(production).sorted() == [])
    }

    @Test func englishAndFrenchSentencesTakePositionalArguments() throws {
        let fixtures = try fixtureBundle()
        let en = Localizer(bundle: fixtures, preferredLanguages: ["en"])
        let fr = Localizer(bundle: fixtures, preferredLanguages: ["fr"])
        #expect(en.format("traffic.profile.summary", arguments: [780, 300, 100, 0.0]) == "Down 780 kbps · Up 300 kbps · Latency 100 ms · Loss 0%")
        #expect(fr.format("traffic.profile.summary", arguments: [780, 300, 100, 0.0]) == "Descendant 780 kb/s · Montant 300 kb/s · Latence 100 ms · Perte 0 %")
        #expect(L10n.format("traffic.profile.summary", 780, 300, 100, 0.0) == "下行 780 kbps · 上行 300 kbps · 延迟 100 ms · 丢包 0%")
    }

    /// Every summary variant is rendered in each language, so a missing key or swapped branch fails.
    @Test func everyProfileSummaryVariantRendersExactly() throws {
        let fixtures = try fixtureBundle()
        let zh = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        let en = Localizer(bundle: fixtures, preferredLanguages: ["en"])
        let fr = Localizer(bundle: fixtures, preferredLanguages: ["fr"])
        let both = NetworkPreset.offline.profile
        let download = NetworkProfile(downloadKbps: nil, uploadKbps: 300, latencyMs: 100, lossPercent: 0)
        let upload = NetworkProfile(downloadKbps: 780, uploadKbps: nil, latencyMs: 100, lossPercent: 1.5)
        let limited = NetworkPreset.threeG.profile
        let expected: [(NetworkProfile, String, String, String)] = [
            (limited, "下行 780 kbps · 上行 300 kbps · 延迟 100 ms · 丢包 0%",
             "Down 780 kbps · Up 300 kbps · Latency 100 ms · Loss 0%",
             "Descendant 780 kb/s · Montant 300 kb/s · Latence 100 ms · Perte 0 %"),
            (download, "下行不限速 · 上行 300 kbps · 延迟 100 ms · 丢包 0%",
             "Down unlimited · Up 300 kbps · Latency 100 ms · Loss 0%",
             "Descendant illimité · Montant 300 kb/s · Latence 100 ms · Perte 0 %"),
            (upload, "下行 780 kbps · 上行不限速 · 延迟 100 ms · 丢包 1.5%",
             "Down 780 kbps · Up unlimited · Latency 100 ms · Loss 1.5%",
             "Descendant 780 kb/s · Montant illimité · Latence 100 ms · Perte 1,5 %"),
            (both, "带宽不限速 · 延迟 0 ms · 丢包 100%",
             "Bandwidth unlimited · Latency 0 ms · Loss 100%",
             "Bande passante illimitée · Latence 0 ms · Perte 100 %"),
        ]
        for (profile, zhText, enText, frText) in expected {
            #expect(TrafficPresentation.summary(of: profile, localizer: zh) == zhText)
            #expect(TrafficPresentation.summary(of: profile, localizer: en) == enText)
            #expect(TrafficPresentation.summary(of: profile, localizer: fr) == frText)
        }
    }
}
