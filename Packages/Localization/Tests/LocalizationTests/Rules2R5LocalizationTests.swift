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

/// Task 1: the header edit method labels and the no-match sentence.
private let task1Keys: [String] = [
    "rules.headerMethod.set", "rules.headerMethod.addIfMissing", "rules.headerMethod.append",
    "rules.headerMethod.appendToValue", "rules.headerMethod.findReplace", "rules.headerMethod.regex",
    "rules.headerMethod.remove", "ruleOutcome.editNoMatch",
]

/// Task 2: the body edit operation labels and their summaries.
private let task2Keys: [String] = [
    "rules.bodyOperation.findReplace", "rules.bodyOperation.setValue", "rules.bodyOperation.clear",
    "rules.actionSummary.rewriteBody.setValue", "rules.actionSummary.rewriteBody.clear",
]

/// Task 3: why the outline refuses a drop.
private let task3Keys: [String] = [
    "rules.outline.drop.tooDeep", "rules.outline.drop.intoSelf", "rules.outline.drop.limit",
]

/// Task 5: the field menu sections, direction, judgment points, row modes and the document editor's issues.
private let task5Keys: [String] =
    ["common", "request", "response", "connection", "afterCompletion", "other"].map { "rules.fieldGroup.\($0)" }
    + ["request", "response", "both", "neither"].map { "rules.side.\($0)" }
    + ["rules.afterCompletion.tag"]
    + ["connect", "request", "response", "completion"].map { "rules.judgment.\($0)" }
    + ["conditions", "actions", "addCondition", "addAction", "mode.all", "mode.any", "mode.none", "occurrence.any", "occurrence.times"]
    .map { "rules.editor2.\($0)" }
    + [
        "invalidOperator", "tooManyConditions", "tooManyActions", "noActions", "actionNotAllowedAtResponsePoint",
        "actionNotAllowedAtCompletionPoint", "conditionNameRequired", "unexpectedConditionName", "invalidConditionName",
        "invalidConditionValue",
    ].map { "rules.issue.\($0)" }

/// Task 6: the 24 action types with a hint each, the menu groups, why a type is greyed out, and the card labels.
private let task6Types: [String] = [
    "modifyURL", "modifyQuery", "editRequestHeaders", "editRequestCookies", "rewriteRequestBody", "mapRemote",
    "requestBreakpoint", "delay", "rewriteStatus", "editResponseHeaders", "editResponseCookies", "rewriteResponseBody",
    "responseBreakpoint", "returnFile", "returnDirectory", "returnHandwritten", "returnPreset", "closeConnectionGraceful",
    "closeConnectionReset", "returnConnectTunnel", "noDecrypt", "hide", "mark", "comment",
]
private let task6Keys: [String] =
    task6Types.flatMap { ["rules.actionType.\($0)", "rules.actionType.\($0).hint"] }
    + ["common", "request", "response", "returnResponse", "connection", "record"].map { "rules.actionGroup.\($0)" }
    + ["requestSideAtResponsePoint", "onlyAnnotationAtCompletion", "needsConnectPointConditions", "connectOnlyMixed"]
    .map { "rules.unavailable.\($0)" }
    + ["rules.card.final", "rules.card.afterFinal", "rules.card.unreachable"]

/// Task 7: the query, cookie and URL edit method labels.
private let task7Keys: [String] =
    ["set", "add", "remove", "findReplace"].map { "rules.queryMethod.\($0)" }
    + ["set", "addIfMissing", "remove", "findReplace", "regex"].map { "rules.cookieMethod.\($0)" }
    + ["set", "findReplace", "regex"].map { "rules.urlMode.\($0)" }

/// Task 8: the titles of the 17 ready-made responses, which the preset form lists (`PresetResponse.Preset.titleKey`).
private let task8Keys: [String] = [
    "emptyHTML200", "gif200", "noContent204", "movedPermanently301", "found302", "seeOther303", "notModified304",
    "temporaryRedirect307", "permanentRedirect308", "badRequest400", "unauthorized401", "forbidden403", "notFound404",
    "proxyAuthRequired407", "tooManyRequests429", "internalError500", "serviceUnavailable503",
].map { "rules.preset.\($0)" }

/// Task 9: the final-action issue, the save-time warnings and confirmation, and the unsaved-changes question.
private let task9Keys: [String] = [
    "rules.issue.finalActionAtLaterPoint", "rules.warning.hideIsFinal", "rules.warning.everySessionFinal.title",
    "rules.warning.everySessionFinal.message", "rules.warning.contentLengthCorrected",
] + ["title", "message", "save", "discard", "cancel"].map { "rules.editor2.pending.\($0)" }

/// Task 10: the outline table's columns, labels, group count, delete questions and bottom-bar menu entries.
private let task10Keys: [String] =
    ["enabled", "name", "condition", "action", "hits"].map { "rules.outline.column.\($0)" }
    + ["groupCount", "moreActions", "newRule", "newGroup", "newGroupName", "clearHits", "showUpgradeNotes", "open", "enableGroup"]
    .map { "rules.outline.\($0)" }
    + ["rule", "group", "multiple"].map { "rules.outline.delete.\($0)" }
    + ["rules.outline.accessibility.table", "rules.outline.accessibility.hits"]

/// Task 11: the editor window's top bar, condition rows, save problems and the external-change question.
private let task11Keys: [String] = [
    "rules.editor2.title.new",
    "rules.editor2.title.edit",
    "rules.editor2.name",
    "rules.editor2.enabled",
    "rules.editor2.group",
    "rules.editor2.note",
    "rules.editor2.more",
    "rules.editor2.save",
    "rules.editor2.fixIssues",
    "rules.editor2.saveFailed.title",
    "rules.editor2.external.message",
    "rules.editor2.external.keepMine",
    "rules.editor2.external.reload",
    "rules.editor2.judgment.line",
    "rules.editor2.legacyTag",
    "rules.editor2.mode.label",
    "rules.editor2.occurrence.label",
    "rules.editor2.occurrence.lower",
    "rules.editor2.occurrence.upper",
    "rules.editor2.row.field",
    "rules.editor2.row.name",
    "rules.editor2.row.operator",
    "rules.editor2.row.value",
    "rules.editor2.row.suggestions",
    "rules.editor2.row.caseSensitive",
    "rules.editor2.row.clear",
    "rules.editor2.row.delete",
    "rules.editor2.hint.range",
    "rules.editor2.hint.date",
    "rules.editor2.hint.dateRange",
    "rules.editor2.shortcut.hint",
    "rules.outline.ungrouped",
    "rules.condition.certificate.subject",
    "rules.condition.certificate.issuer",
    "rules.condition.certificate.serialNumber",
    "rules.condition.certificate.sha256Fingerprint",
    "rules.condition.certificate.notBefore",
    "rules.condition.certificate.notAfter",
    "rules.condition.clientApp.name",
    "rules.condition.clientApp.path",
    "rules.condition.clientApp.pid",
    "rules.editor2.empty",
    "rules.editor2.busy",
    "rules.editor2.conflictInRulesWindow",
    "rules.liveCount.counting",
]

/// Task 12: the action cards and their forms.
private let task12Keys: [String] = [
    "rules.card.makeFinal",
    "rules.card.copy",
    "rules.card.delete",
    "rules.card.type",
    "rules.card.number",
    "rules.card.menuItem.unavailable",
    "rules.card.opaque",
    "rules.card.summary",
    "rules.card.hits",
    "rules.card.groupCount",
    "rules.form.method",
    "rules.delay.milliseconds",
    "rules.delay.help",
    "rules.returnDirectory.prefix",
    "rules.handwritten.label",
    "rules.handwritten.counter",
    "rules.preset.label",
    "rules.preset.location",
    "rules.preset.challenge",
    "rules.preset.body",
]

/// Every key rules 2.0 phase R5 adds. Later R5 tasks append their keys here.
private let r5Keys: [String] = task1Keys + task2Keys + task3Keys + task5Keys + task6Keys + task7Keys + task8Keys + task9Keys + task10Keys + task11Keys + task12Keys

/// The arguments each sentence takes, by position: text is `@`, a number is `d`. A key not listed takes none.
private let r5Arguments: [String: [String]] = [
    "ruleOutcome.editNoMatch": ["1:@"],
    "rules.actionSummary.rewriteBody.setValue": ["1:@"],
    "rules.editor2.occurrence.times": ["1:d", "2:d"],
    "rules.card.number": ["1:d"],
    "rules.card.summary": ["1:@", "2:@"],
    "rules.card.hits": ["1:d"],
    "rules.card.groupCount": ["1:d", "2:d"],
    "rules.card.menuItem.unavailable": ["1:@"],
    "rules.handwritten.counter": ["1:d", "2:d"],
    "rules.issue.tooManyConditions": ["1:d"],
    "rules.issue.tooManyActions": ["1:d"],
    "rules.outline.groupCount": ["1:d", "2:d"],
    "rules.outline.moreActions": ["1:@", "2:d"],
    "rules.outline.enableGroup": ["1:@"],
    "rules.outline.delete.rule": ["1:@"],
    "rules.outline.delete.group": ["1:@", "2:d"],
    "rules.outline.delete.multiple": ["1:d", "2:d"],
    "rules.outline.accessibility.hits": ["1:d"],
    "rules.editor2.judgment.line": ["1:@"],
]

@Suite(.productionChinese) struct Rules2R5LocalizationTests {
    /// The keys the plan's localization table names outright (`docs/superpowers/plans/2026-10-24-rules2-R5.md`), the
    /// families written out. `rules.outline.onlyEnabled` is deliberately absent: the shared list bar already has that
    /// switch, so the outline never got a key of its own (T10 report).
    private static let planTableKeys: [String] = {
        func family(_ prefix: String, _ names: [String]) -> [String] { names.map { prefix + $0 } }
        var keys: [String] = []
        keys += family("rules.headerMethod.", ["set", "addIfMissing", "append", "appendToValue", "findReplace", "regex", "remove"])
        keys += family("rules.bodyOperation.", ["findReplace", "setValue", "clear"]) + ["ruleOutcome.editNoMatch"]
        keys += family("rules.outline.column.", ["enabled", "name", "condition", "action", "hits"])
        keys += family("rules.outline.", ["groupCount", "newRule", "newGroup", "newGroupName", "ungrouped", "clearHits", "showUpgradeNotes"])
        keys += family("rules.outline.delete.", ["rule", "group", "multiple"])
        keys += family("rules.outline.drop.", ["tooDeep", "intoSelf", "limit"])
        keys += family("rules.editor2.", [
            "title.new", "title.edit", "name", "enabled", "group", "note", "more", "conditions", "actions", "addCondition",
            "addAction", "mode.all", "mode.any", "mode.none", "occurrence.any", "occurrence.times", "pending.title",
            "pending.message", "pending.save", "pending.discard", "pending.cancel", "shortcut.hint",
        ])
        keys += family("rules.fieldGroup.", ["common", "request", "response", "connection", "afterCompletion", "other"])
        keys += family("rules.side.", ["request", "response", "both", "neither"]) + ["rules.afterCompletion.tag"]
        keys += family("rules.judgment.", ["connect", "request", "response", "completion"])
        keys += task6Types.flatMap { ["rules.actionType.\($0)", "rules.actionType.\($0).hint"] }
        keys += family("rules.actionGroup.", ["common", "request", "response", "returnResponse", "connection", "record"])
        keys += family("rules.unavailable.", [
            "requestSideAtResponsePoint", "onlyAnnotationAtCompletion", "needsConnectPointConditions", "connectOnlyMixed",
        ])
        keys += family("rules.card.", ["final", "afterFinal", "copy", "delete", "unreachable"])
        keys += family("rules.issue.", [
            "finalActionAtLaterPoint", "noActions", "actionNotAllowedAtResponsePoint", "actionNotAllowedAtCompletionPoint",
        ])
        keys += family("rules.warning.", ["hideIsFinal", "everySessionFinal.title", "everySessionFinal.message", "contentLengthCorrected"])
        keys += family("rules.form.", ["method"])
        return keys
    }()

    @Test func everyPlanTableKeyIsAudited() throws {
        let audited = Set(r5Keys)
        #expect(Self.planTableKeys.filter { !audited.contains($0) } == [])
        let production = try strings(L10n.bundle, "zh-Hans")
        #expect(Self.planTableKeys.filter { production[$0] == nil } == [])
    }

    /// A key a later change adds in these families must be added to the audit lists above. `rules.issue.` and
    /// `rules.warning.` are left out: they also hold the older (pre-R5) draft problems, which other suites cover.
    @Test func noR5KeyFamilyHoldsAnUnauditedKey() throws {
        let production = try strings(L10n.bundle, "zh-Hans")
        let families = [
            "rules.headerMethod.", "rules.bodyOperation.", "rules.outline.", "rules.editor2.", "rules.fieldGroup.", "rules.side.",
            "rules.judgment.", "rules.actionType.", "rules.actionGroup.", "rules.unavailable.", "rules.card.",
            "rules.form.", "rules.queryMethod.", "rules.cookieMethod.", "rules.urlMode.", "rules.preset.",
        ]
        // R6 keys that live in an R5 family; Rules2R6LocalizationTests audits them.
        let audited = Set(r5Keys).union(["rules.outline.column.run", "rules.outline.run.rule", "rules.outline.run.group"])
            // R8F-1 (T3) keys; Rules2R8LocalizationTests audits them.
            .union(["rules.editor2.occurrence.choice.any", "rules.editor2.occurrence.choice.specific", "rules.editor2.occurrence.count",
                    "rules.editor2.occurrence.legacyHelp"])
            // R8F2-T3 keys: the three presets the engine gained.
            .union(["rules.preset.transparentPixel200", "rules.preset.digestAuth401", "rules.preset.unreachable502"])
            // R8F2-T4 keys: the magic string action type.
            .union(["rules.actionType.magicString", "rules.actionType.magicString.hint"])
            // R8F2-T6 key: the warning on a request-side action in a rule judged at the response.
            .union(["rules.card.requestVisibleOnly"])
            // R8F2-T8 keys; Rules2R8F2T8LocalizationTests audits them.
            .union([
                "rules.card.requestSkippedAtResponse", "rules.queryMethod.regex", "rules.queryMethod.addIfMissing",
                "rules.queryMethod.appendToValue", "rules.cookieMethod.appendToValue", "rules.urlMode.append",
            ])
            // R8F2-T9 keys; Rules2R8F2T9LocalizationTests audits them.
            .union([
                "rules.card.fieldLabel", "rules.card.dragHandle", "rules.card.dragPreview", "rules.card.more",
                "rules.card.noticeCount", "rules.card.errorCount", "rules.card.noticeKind.error", "rules.card.noticeKind.warning",
                "rules.card.noticeItem", "rules.card.hint.expanded", "rules.card.hint.collapsed",
            ])
            // R8F3-T8 keys; Rules2R8F3T8LocalizationTests audits them.
            .union([
                "rules.editor2.close.saveMessage", "rules.editor2.close.invalidMessage", "rules.editor2.close.detail",
                "rules.editor2.close.dontSave",
            ])
        let loose = production.keys.filter { key in families.contains { key.hasPrefix($0) } && !audited.contains(key) }
        #expect(loose.sorted() == [])
    }

    @Test func everyR5KeyExistsAndIsTranslatedInEveryLanguageWithTheSameArguments() throws {
        #expect(r5Keys.count == Set(r5Keys).count)
        let production = try strings(L10n.bundle, "zh-Hans")
        let fixtures = try fixtureBundle()
        let en = try strings(fixtures, "en")
        let fr = try strings(fixtures, "fr")
        let zh = try strings(fixtures, "zh-Hans")
        for key in r5Keys {
            let chinese = try #require(production[key], "\(key) missing in production")
            #expect(!chinese.isEmpty && chinese != key, "\(key)")
            #expect(zh[key] == chinese, "\(key): production and its fixture copy agree")
            let english = try #require(en[key], "\(key) missing in en")
            let french = try #require(fr[key], "\(key) missing in fr")
            #expect(!english.isEmpty && !french.isEmpty, "\(key)")
            #expect(english != key && french != key, "\(key) is translated")
            #expect(specifiers(english) == specifiers(chinese) && specifiers(french) == specifiers(chinese), "\(key) arguments")
            #expect(specifiers(chinese) == (r5Arguments[key] ?? []), "\(key) argument table")
        }
    }

    @Test func task1SentencesReadWellInChinese() {
        #expect(task1Keys.count == 8)
        let zh = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        #expect(zh.string("rules.headerMethod.set") == "设置值")
        #expect(zh.string("rules.headerMethod.addIfMissing") == "若不存在则添加")
        #expect(zh.string("rules.headerMethod.append") == "添加字段")
        #expect(zh.string("rules.headerMethod.appendToValue") == "追加到值")
        #expect(zh.string("rules.headerMethod.findReplace") == "查找并替换")
        #expect(zh.string("rules.headerMethod.regex") == "正则表达式")
        #expect(zh.string("rules.headerMethod.remove") == "移除")
        #expect(zh.format("ruleOutcome.editNoMatch", arguments: ["R"]) == "规则「R」的 Header 修改没有找到匹配的字段。")
    }

    @Test func task2SentencesReadWellInChinese() {
        #expect(task2Keys.count == 5)
        let zh = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        #expect(zh.string("rules.bodyOperation.findReplace") == "查找并替换")
        #expect(zh.string("rules.bodyOperation.setValue") == "设置值")
        #expect(zh.string("rules.bodyOperation.clear") == "移除")
        #expect(zh.format("rules.actionSummary.rewriteBody.setValue", arguments: ["ok"]) == "把正文设为「ok」")
        #expect(zh.string("rules.actionSummary.rewriteBody.clear") == "清空正文")
    }

    @Test func task3SentencesReadWellInChinese() {
        #expect(task3Keys.count == 3)
        let zh = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        #expect(zh.string("rules.outline.drop.tooDeep") == "分组最多嵌套 3 层，放不进去。")
        #expect(zh.string("rules.outline.drop.intoSelf") == "不能把分组放进它自己或它的子分组里。")
        #expect(zh.string("rules.outline.drop.limit") == "规则数量已达上限，无法放入。")
    }

    @Test func task10SentencesReadWellInChinese() {
        #expect(task10Keys.count == 19)
        let zh = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        #expect(zh.string("rules.outline.column.hits") == "命中次数")
        #expect(zh.format("rules.outline.groupCount", arguments: [2, 5]) == "已启用 2 / 5")
        #expect(zh.format("rules.outline.moreActions", arguments: ["隐藏", 3]) == "隐藏 等 3 项")
        #expect(zh.format("rules.outline.delete.group", arguments: ["A", 4]) == "删除分组「A」及其中的 4 条规则？")
    }

    @Test func task5SentencesReadWellInChinese() {
        #expect(task5Keys.count == 34)
        let zh = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        #expect(zh.string("rules.fieldGroup.afterCompletion") == "完成后")
        #expect(zh.string("rules.afterCompletion.tag") == "完成后")
        #expect(zh.string("rules.judgment.completion") == "完成点（P3）")
        #expect(zh.string("rules.editor2.mode.none") == "全都不满足")
        #expect(zh.format("rules.editor2.occurrence.times", arguments: [2, 5]) == "第 2 到 5 次")
        #expect(zh.format("rules.issue.tooManyConditions", arguments: [32]) == "条件最多 32 行。")
        #expect(zh.string("rules.issue.noActions") == "至少需要一个动作。")
    }

    @Test func task6SentencesReadWellInChinese() {
        #expect(task6Types.count == 24 && task6Keys.count == 61)
        let zh = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        #expect(zh.string("rules.actionType.closeConnectionGraceful") == "正常关闭连接")
        #expect(zh.string("rules.actionType.closeConnectionReset") == "强制关闭连接")
        #expect(zh.string("rules.card.unreachable") == "不会执行")
        #expect(zh.format("rules.card.summary", arguments: ["A", "B"]) == "A → B")
        #expect(zh.format("rules.card.hits", arguments: [3]) == "命中 3")
        #expect(zh.format("rules.card.groupCount", arguments: [2, 5]) == "已启用 2 / 5 条")
        #expect(
            zh.string("rules.unavailable.requestSideAtResponsePoint")
                == "这条规则要等服务器响应到达才能判定，那时请求已经发出去了，改请求或直接返回响应都来不及。把动作改成响应侧动作，或拆成两条规则。")
        #expect(
            zh.string("rules.unavailable.onlyAnnotationAtCompletion")
                == "这条规则要等整条流量结束才能判定（因为用了「耗时 / 响应大小 / 会话状态」），那时只能做标记、注释或不显示。")
    }

    @Test func task8SentencesReadWellInChinese() {
        #expect(task8Keys.count == 17)
        let zh = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        #expect(zh.string("rules.preset.notFound404") == "404 Not Found")
        #expect(zh.string("rules.preset.temporaryRedirect307") == "307 重定向（保持方法）")
    }

    @Test func task9SentencesReadWellInChinese() {
        #expect(task9Keys.count == 10)
        let zh = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        #expect(zh.string("rules.warning.everySessionFinal.title") == "这会对所有流量生效")
        #expect(zh.string("rules.editor2.pending.discard") == "放弃改动")
        #expect(zh.string("rules.issue.finalActionAtLaterPoint").contains("最终"))
    }

    @Test func task11SentencesReadWellInChinese() {
        #expect(task11Keys.count == 45)
        let zh = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        #expect(zh.format("rules.editor2.judgment.line", arguments: ["完成点（P3）"]) == "判定时机：完成点（P3）")
        #expect(zh.string("rules.outline.ungrouped") == "未分组")
        #expect(zh.string("rules.editor2.fixIssues") == "请先修改标红的内容，再保存。")
    }
}
