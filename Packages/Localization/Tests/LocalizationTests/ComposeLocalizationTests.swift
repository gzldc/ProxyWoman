import AppCore
import Foundation
import Localization
import Testing
@testable import ProxyCore

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

@Suite(.productionChinese) struct ComposeLocalizationTests {
    @Test func everyComposeKeyIsTranslatedInEveryFixtureWithTheSameArguments() throws {
        let production = try strings(L10n.bundle, "zh-Hans").filter { $0.key.hasPrefix("compose.") }
        #expect(production.count >= 8)
        let fixtures = try fixtureBundle()
        for language in ["en", "fr", "zh-Hans"] {
            let fixture = try strings(fixtures, language).filter { $0.key.hasPrefix("compose.") }
            #expect(Set(production.keys).subtracting(fixture.keys).sorted() == [], "missing in \(language)")
            #expect(Set(fixture.keys).subtracting(production.keys).sorted() == [], "stale in \(language)")
            for (key, value) in production {
                guard let translated = fixture[key] else { continue }
                #expect(!translated.isEmpty && translated != key, "\(language) \(key)")
                #expect(specifiers(translated) == specifiers(value), "\(language) \(key) arguments")
                if language == "zh-Hans" { #expect(translated == value, "\(key) fixture copy") }
            }
        }
    }

    @Test func failureCodesAreStableAndMessagesAreLocalized() throws {
        #expect(ComposeFailureCode.allCases.map(\.rawValue) == [
            "compose.busy", "compose.shutdown", "compose.cancelled", "compose.invalidRequest",
            "compose.bodyUnavailable", "compose.responseIncomplete", "compose.timeout",
        ])
        let english = Localizer(bundle: try fixtureBundle(), preferredLanguages: ["en"])
        let french = Localizer(bundle: try fixtureBundle(), preferredLanguages: ["fr"])
        for code in ComposeFailureCode.allCases {
            let chinese = ComposeFailureText.message(code, detail: "invalidMethod")
            let en = ComposeFailureText.message(code, detail: "invalidMethod", localizer: english)
            let fr = ComposeFailureText.message(code, detail: "invalidMethod", localizer: french)
            #expect(!chinese.isEmpty && !chinese.hasPrefix("compose."), "\(code)")
            #expect(en != chinese && fr != chinese && en != fr, "\(code)")
        }
        #expect(ComposeFailureText.message(.invalidRequest, detail: "invalidMethod") == "Compose 请求无效（invalidMethod）。")
        #expect(ComposeFailureText.message(.invalidRequest, detail: "x", localizer: english) == "The Compose request is invalid (x).")
        #expect(ComposeFailureText.message(.busy) == "Compose 发送已达上限，请等待正在进行的请求完成后再试。")
        #expect(ComposeFailureText.message(.timeout, detail: "60") == "Compose 请求在 60 秒内没有完成，已超时取消。")
        #expect(ComposeFailureText.message(.timeout, detail: "5", localizer: english) == "The Compose request did not finish within 5 seconds and was cancelled.")
        #expect(ComposeFailureText.message(.cancelled) == "此 Compose 请求已取消。")
        #expect(ComposeFailureText.seconds(.seconds(600)) == "600")
        #expect(ComposeFailureText.seconds(.milliseconds(1_500)) == "1.5")
        #expect(ComposeFailureText.seconds(.milliseconds(600_250)) == "600.25")
        #expect(ComposeFailureText.notRunning() == "代理未运行")
        #expect(ComposeFailureText.notRunning(localizer: english) == "the proxy is not running")
    }

    /// Every key the Compose window, draft validation and flow-table entries use: production has
    /// it, the zh-Hans fixture is a copy, and en/fr really translate it (no fallback to Chinese).
    @Test func localizationKeysExist() throws {
        let fixtures = try fixtureBundle()
        let zh = Localizer(bundle: fixtures, preferredLanguages: ["zh-Hans"])
        let en = Localizer(bundle: fixtures, preferredLanguages: ["en"])
        let fr = Localizer(bundle: fixtures, preferredLanguages: ["fr"])
        let production = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        var keys = ComposeDraftIssue.Code.allCases.map(\.localizationKey)
        keys += ComposeEntryBlock.staticCases.map(\.localizationKey)
        keys += [ComposeBodyOmission.unreadable.localizationKey]
        keys += ComposeResultPresentation.messageKeys
        keys += ComposeReplay.messageKeys
        #expect(keys.count == Set(keys).count)
        for key in keys {
            #expect(key.hasPrefix("compose."), "\(key)")
            let chinese = production.string(key)
            #expect(chinese != key && !chinese.isEmpty, "\(key)")
            #expect(chinese == zh.string(key), "\(key): production and its fixture copy agree")
            #expect(en.string(key) != chinese && fr.string(key) != chinese, "\(key)")
        }
        #expect(ComposeEntryBlock.body(.bodyTruncated).localizedDescription == ReplayBlockReason.bodyTruncated.localizedDescription)
        #expect(ComposeBodyOmission.replay(.bodyOnDisk).localizedDescription == ReplayBlockReason.bodyOnDisk.localizedDescription)
    }

    @Test func everyLiteralComposeKeyInTheAppExistsInProduction() throws {
        let production = Set(try strings(L10n.bundle, "zh-Hans").keys)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let pattern = try NSRegularExpression(pattern: #""(compose\.[A-Za-z0-9_.]+)""#)
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

    @Test func englishAndFrenchComposeSentencesTakePositionalArguments() throws {
        let fixtures = try fixtureBundle()
        let en = Localizer(bundle: fixtures, preferredLanguages: ["en"])
        let fr = Localizer(bundle: fixtures, preferredLanguages: ["fr"])
        #expect(en.format("compose.response.summary", arguments: ["1.2 s", "4 KB"]) == "Took 1.2 s · 4 KB")
        #expect(fr.format("compose.response.summary", arguments: ["1,2 s", "4 Ko"]) == "Durée 1,2 s · 4 Ko")
        #expect(L10n.format("compose.response.summary", "1.2 秒", "4 KB") == "耗时 1.2 秒 · 4 KB")
        #expect(en.format("compose.replay.held", arguments: ["POST"])
            == "Replay did not send this POST request because it may have side effects; review it and click Send.")
        #expect(L10n.format("compose.replay.held", "POST") == "这是 POST 请求，重放可能产生副作用，因此没有自动发送；检查后点击“发送”。")
        #expect(en.format("compose.response.truncated", arguments: ["8 MB", "9 MB"])
            == "Only the first 8 MB of the 9 MB body are shown.")
        #expect(fr.format("compose.response.truncated", arguments: ["8 Mo", "9 Mo"])
            == "Seuls les premiers 8 Mo des 9 Mo du corps sont affichés.")
    }
}
