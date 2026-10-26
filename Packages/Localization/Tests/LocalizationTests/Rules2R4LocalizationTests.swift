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

private let presetNames = [
    "emptyHTML200", "gif200", "noContent204", "movedPermanently301", "found302", "seeOther303", "notModified304",
    "temporaryRedirect307", "permanentRedirect308", "badRequest400", "unauthorized401", "forbidden403", "notFound404",
    "proxyAuthRequired407", "tooManyRequests429", "internalError500", "serviceUnavailable503",
]

/// Task 1: the summaries of the new actions, the preset names and the two new outcome sentences.
private let task1Keys: [String] = [
    [
        "rules.actionSummary.modifyURL.set", "rules.actionSummary.modifyURL.findReplace",
        "rules.actionSummary.modifyURL.regex", "rules.actionSummary.modifyQuery",
        "rules.actionSummary.editCookies.request", "rules.actionSummary.editCookies.response",
        "rules.actionSummary.delay", "rules.actionSummary.returnHandwritten", "rules.actionSummary.returnPreset",
        "rules.actionSummary.closeConnection.graceful", "rules.actionSummary.closeConnection.reset",
        "rules.actionSummary.returnConnectTunnel", "rules.actionSummary.noDecrypt",
    ],
    presetNames.map { "rules.preset.\($0)" },
    ["ruleOutcome.skippedByTool", "ruleOutcome.delayCapped"],
].flatMap { $0 }

/// Task 4: the validation issues of the new actions and of connect-only rules.
private let task4Keys: [String] = [
    "rules.issue.invalidURLEdit", "rules.issue.invalidQueryEdit", "rules.issue.invalidCookieEdit",
    "rules.issue.emptyEditFind", "rules.issue.invalidDelay", "rules.issue.invalidHandwrittenResponse",
    "rules.issue.handwrittenResponseTooLarge", "rules.issue.presetNeedsLocation", "rules.issue.invalidPresetField",
    "rules.issue.connectActionCondition", "rules.issue.connectActionMixed",
]

/// Task 9: the recorded failure of an exchange a rule closed.
private let task9Keys: [String] = ["proxyLocalFailure.ruleClosed"]

/// Every key rules 2.0 phase R4 adds. Later R4 tasks append their keys here.
private let r4Keys: [String] = task1Keys + task4Keys + task9Keys

/// The arguments each sentence takes, by position: text is `@`, a number is `d`. A key not listed takes none.
private let r4Arguments: [String: [String]] = [
    "rules.actionSummary.modifyURL.set": ["1:@"],
    "rules.actionSummary.modifyURL.findReplace": ["1:@", "2:@"],
    "rules.actionSummary.modifyURL.regex": ["1:@"],
    "rules.actionSummary.modifyQuery": ["1:d"],
    "rules.actionSummary.editCookies.request": ["1:d"],
    "rules.actionSummary.editCookies.response": ["1:d"],
    "rules.actionSummary.delay": ["1:d"],
    "rules.actionSummary.returnHandwritten": ["1:d"],
    "rules.actionSummary.returnPreset": ["1:@"],
    "ruleOutcome.skippedByTool": ["1:@"],
    "ruleOutcome.delayCapped": ["1:@"],
    "proxyLocalFailure.ruleClosed": ["1:@"],
]

@Suite(.productionChinese) struct Rules2R4LocalizationTests {
    @Test func everyR4KeyExistsAndIsTranslatedInEveryLanguageWithTheSameArguments() throws {
        #expect(r4Keys.count == Set(r4Keys).count)
        let production = try strings(L10n.bundle, "zh-Hans")
        let fixtures = try fixtureBundle()
        let en = try strings(fixtures, "en")
        let fr = try strings(fixtures, "fr")
        let zh = try strings(fixtures, "zh-Hans")
        for key in r4Keys {
            let chinese = try #require(production[key], "\(key) missing in production")
            #expect(!chinese.isEmpty && chinese != key, "\(key)")
            #expect(zh[key] == chinese, "\(key): production and its fixture copy agree")
            let english = try #require(en[key], "\(key) missing in en")
            let french = try #require(fr[key], "\(key) missing in fr")
            #expect(!english.isEmpty && !french.isEmpty, "\(key)")
            #expect(english != key && french != key, "\(key) is translated")
            #expect(specifiers(english) == specifiers(chinese) && specifiers(french) == specifiers(chinese), "\(key) arguments")
            #expect(specifiers(chinese) == (r4Arguments[key] ?? []), "\(key) argument table")
        }
    }

    @Test func task1CountsAsTheTableSays() {
        #expect(presetNames.count == 17)
        #expect(task1Keys.count == 13 + 17 + 2)
    }

    @Test func task1SentencesReadWellInChinese() {
        let zh = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        #expect(zh.format("rules.actionSummary.modifyURL.set", arguments: ["https://b.test/"]) == "把 URL 改为 https://b.test/")
        #expect(zh.format("rules.actionSummary.modifyURL.findReplace", arguments: ["a", "b"]) == "在 URL 中把「a」替换为「b」")
        #expect(zh.format("rules.actionSummary.modifyURL.regex", arguments: ["a+"]) == "用正则改写 URL（a+）")
        #expect(zh.format("rules.actionSummary.modifyQuery", arguments: [2]) == "修改查询参数（2 项）")
        #expect(zh.format("rules.actionSummary.editCookies.request", arguments: [1]) == "修改请求 Cookie（1 项）")
        #expect(zh.format("rules.actionSummary.editCookies.response", arguments: [1]) == "修改响应 Cookie（1 项）")
        #expect(zh.format("rules.actionSummary.delay", arguments: [500]) == "延迟请求 500 毫秒")
        #expect(zh.format("rules.actionSummary.returnHandwritten", arguments: [418]) == "返回手写响应（状态码 418）")
        #expect(zh.format("rules.actionSummary.returnPreset", arguments: ["x"]) == "返回预置响应：x")
        #expect(zh.string("rules.actionSummary.closeConnection.graceful") == "关闭连接（正常）")
        #expect(zh.string("rules.actionSummary.closeConnection.reset") == "关闭连接（强制复位）")
        #expect(zh.string("rules.actionSummary.returnConnectTunnel") == "返回 CONNECT 隧道")
        #expect(zh.string("rules.actionSummary.noDecrypt") == "不解密")
        #expect(zh.string("rules.preset.emptyHTML200") == "200 OK（HTML）")
        #expect(zh.string("rules.preset.gif200") == "200 OK（GIF 图片）")
        #expect(zh.string("rules.preset.serviceUnavailable503") == "503 服务不可用")
        #expect(
            zh.format("ruleOutcome.skippedByTool", arguments: ["R"])
                == "规则「R」的动作没有执行：屏蔽 / 允许列表 / SSL 解密列表已经决定了这条连接怎么处理。")
        #expect(zh.format("ruleOutcome.delayCapped", arguments: ["R"]) == "规则「R」的延迟累计超过 60 秒，已按 60 秒执行。")
    }

    @Test func task4IssuesReadWellInChinese() {
        #expect(task4Keys.count == 11)
        let zh = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        #expect(zh.string("rules.issue.invalidURLEdit") == "URL 的修改方式不对。")
        #expect(zh.string("rules.issue.invalidQueryEdit") == "查询参数的名称或值含有不能直接写入的字符。")
        #expect(zh.string("rules.issue.invalidCookieEdit") == "Cookie 的名称或值不合法。")
        #expect(zh.string("rules.issue.emptyEditFind") == "请填写要查找的内容。")
        #expect(zh.string("rules.issue.invalidDelay") == "延迟必须在 0 到 60000 毫秒之间。")
        #expect(zh.string("rules.issue.invalidHandwrittenResponse") == "手写响应的格式不对。")
        #expect(zh.string("rules.issue.handwrittenResponseTooLarge") == "手写响应不能超过 64 KiB，更大的请用「返回文件」。")
        #expect(zh.string("rules.issue.presetNeedsLocation") == "这种预置响应必须填写跳转地址（Location）。")
        #expect(zh.string("rules.issue.invalidPresetField") == "预置响应的附加内容不合法。")
        #expect(
            zh.string("rules.issue.connectActionCondition")
                == "「不解密」和「返回 CONNECT 隧道」只能配合 所有会话、URL、协议方案、主机、端口、客户端 IP、进程 这些条件使用。")
        #expect(
            zh.string("rules.issue.connectActionMixed") == "「不解密」和「返回 CONNECT 隧道」只能和标记、注释、不显示、关闭连接放在同一条规则里。")
    }

    @Test func task9SentenceReadsWellInChinese() {
        let zh = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        #expect(zh.format("proxyLocalFailure.ruleClosed", arguments: ["R"]) == "连接已被规则「R」关闭。")
    }
}
