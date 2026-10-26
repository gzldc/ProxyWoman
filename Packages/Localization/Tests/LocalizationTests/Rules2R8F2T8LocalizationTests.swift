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

private let markColorIDs = [
    "yellowTransparent", "fuchsiaTransparent", "redTransparent", "oliveTransparent", "purpleTransparent", "maroonTransparent",
    "aquaTransparent", "limeTransparent", "greenTransparent", "tealTransparent", "blueTransparent", "navyTransparent", "yellow",
    "fuchsia", "red", "olive", "purple", "maroon", "aqua", "lime", "green", "teal", "blue", "navy", "white", "silverTransparent",
    "grayTransparent", "black",
]

/// Keys added by R8F2 task 8 (action model and presentation).
private let r8f2Task8Keys: [String] =
    markColorIDs.map { "rules.markColor." + $0 } + [
        "rules.markColor.unchanged", "rules.markColor.default", "rules.action.key.all", "rules.action.placeholder.set",
        "rules.action.placeholder.replaceWith", "rules.action.placeholder.append", "rules.action.placeholder.milliseconds",
        "rules.action.placeholder.status", "rules.action.language.plaintext", "rules.action.language.json",
        "rules.action.language.css", "rules.action.language.xml", "rules.action.language.html",
        "rules.action.language.typescript", "rules.action.legacy.fullBody", "rules.action.convertToReturnFile",
        "rules.queryMethod.regex", "rules.queryMethod.addIfMissing", "rules.queryMethod.appendToValue",
        "rules.cookieMethod.appendToValue", "rules.urlMode.append", "rules.comment.mode.regex", "rules.comment.mode.addIfMissing",
        "rules.card.requestSkippedAtResponse", "rules.notice.matchPointUncertain", "rules.notice.requestAfterResponse",
        "rules.notice.noDecryptConditions", "rules.notice.multipleManualResponses", "rules.banner.actionsErrors",
        "rules.banner.actionsWarnings", "rules.issue.magicStringLocalFile", "rules.warning.markTextColorNeedsBackground",
        "ruleOutcome.requestActionVisibleOnly", "ruleOutcome.requestActionSkippedAtResponse",
    ]

@Suite(.productionChinese) struct Rules2R8F2T8LocalizationTests {
    @Test func everyKeyIsInProductionAndFixturesWithTheSameArguments() throws {
        #expect(r8f2Task8Keys.count == Set(r8f2Task8Keys).count)
        let production = try strings(L10n.bundle, "zh-Hans")
        let fixtures = try fixtureBundle()
        let en = try strings(fixtures, "en")
        let fr = try strings(fixtures, "fr")
        let zh = try strings(fixtures, "zh-Hans")
        for key in r8f2Task8Keys {
            let chinese = try #require(production[key], "\(key) missing in production")
            #expect(!chinese.isEmpty && chinese != key, "\(key)")
            #expect(zh[key] == chinese, "\(key): production and its fixture copy agree")
            let english = try #require(en[key], "\(key) missing in en")
            let french = try #require(fr[key], "\(key) missing in fr")
            #expect(!english.isEmpty && !french.isEmpty, "\(key)")
            #expect(specifiers(english) == specifiers(chinese) && specifiers(french) == specifiers(chinese), "\(key) arguments")
        }
    }

    @Test func actionNamesAndMethodsReadAsSpecified() throws {
        let production = try strings(L10n.bundle, "zh-Hans")
        let expected: [String: String] = [
            "rules.actionType.mark": "标记会话", "rules.actionType.modifyQuery": "修改查询字符串",
            "rules.actionType.returnHandwritten": "返回手动响应", "rules.actionType.returnPreset": "返回预定义响应",
            "rules.actionType.delay": "延迟请求", "rules.actionType.magicString": "魔法字符串",
            "rules.headerMethod.set": "设置值", "rules.headerMethod.findReplace": "查找并替换",
            "rules.headerMethod.regex": "正则表达式", "rules.headerMethod.addIfMissing": "若不存在则添加",
            "rules.headerMethod.appendToValue": "追加到值", "rules.headerMethod.remove": "移除",
            "rules.preset.transparentPixel200": "200 OK（像素）", "rules.preset.digestAuth401": "401 摘要认证",
            "rules.markColor.unchanged": "不变", "rules.markColor.default": "默认",
        ]
        for (key, text) in expected { #expect(production[key] == text, "\(key)") }
    }

    @Test func noActionTextNamesTheReferenceProduct() throws {
        let production = try strings(L10n.bundle, "zh-Hans")
        for (key, text) in production where key.hasPrefix("rules.actionType.") || key.hasPrefix("rules.markColor.")
            || key.hasPrefix("rules.action.") || key.hasPrefix("rules.notice.") || key.hasPrefix("rules.preset.")
        {
            #expect(!text.contains("Fiddler") && !text.contains("Telerik"), "\(key)")
        }
    }
}
