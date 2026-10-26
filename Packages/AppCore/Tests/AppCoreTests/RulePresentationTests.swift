import FlowStore
import Foundation
import Localization
import RulesEngine
import Testing

@testable import AppCore

private let ruleA = UUID(), ruleB = UUID(), gone = UUID()

private func names(_ id: UUID) -> String? {
    if id == ruleA { return "Fix price" }
    if id == ruleB { return "Force 404" }
    return nil
}

private func matches(_ outcomes: [RuleOutcome]) -> RuleMatchSummary {
    RuleMatchSummary(revision: 1, ruleIDs: [], total: outcomes.count, outcomes: outcomes)
}

@Suite(.productionChinese) struct RulePresentationTests {
    private func bodyRule(find: String, replacement: String, direction: HTTPMessageDirection = .response) -> Rule {
        Rule(id: UUID(), name: "r", enabled: true, order: 0, matcher: RuleMatcher(hostPattern: "a.test"),
             action: .rewriteBody(direction: direction, BodyRewriteAction(find: find, replacement: replacement)))
    }

    private func annotationRule(_ kind: ActionKind, mode: ConditionGroup.Mode = .all) -> Rule {
        var rule = Rule(
            id: UUID(), name: "r", enabled: true, order: 0, matcher: RuleMatcher(hostPattern: "a.test"), annotation: kind)
        rule.conditions.mode = mode
        return rule
    }

    @Test func annotationRulesAreSummarised() {
        func action(_ kind: ActionKind) -> String { RulePresentation.actionSummary(of: annotationRule(kind), assetName: { _ in nil }) }
        func title(_ kind: ActionKind) -> String { RulePresentation.kindTitle(of: annotationRule(kind)) }
        #expect(title(.mark(MarkAction(background: "#FF3B30"))) == "标记")
        #expect(title(.comment(CommentAction(text: "x"))) == "注释")
        #expect(title(.hide) == "不显示")
        #expect(action(.mark(MarkAction(background: "#FF3B30"))) == "标记为红色")
        #expect(action(.mark(MarkAction(background: "#FF3B30", text: "慢"))) == "标记为红色：慢")
        #expect(action(.mark(MarkAction(background: "#123456"))) == "标记为自定义颜色")
        #expect(action(.comment(CommentAction(mode: .append, text: "慢请求"))) == "追加注释：慢请求")
        #expect(action(.comment(CommentAction(mode: .set, text: "慢请求"))) == "设置注释：慢请求")
        #expect(action(.comment(CommentAction(mode: .findReplace, text: "a", replacement: "b"))) == "注释中把「a」替换为「b」")
        #expect(action(.comment(CommentAction(mode: .clear))) == "清空注释")
        #expect(action(.hide) == "不显示这条流量")

        let matcher = RuleMatcher(hostPattern: "a.test")
        let remote = Rule(id: UUID(), name: "r", enabled: true, order: 0, matcher: matcher,
                          action: .mapRemote(MapRemoteAction(targetScheme: "https", targetHost: "b.test", targetPort: 443, path: .preserve)))
        #expect(RulePresentation.matchSummary(of: annotationRule(.hide)) == RulePresentation.matchSummary(of: remote))
        var anyRemote = remote
        anyRemote.conditions.mode = .any
        #expect(RulePresentation.matchSummary(of: annotationRule(.hide, mode: .any)) == RulePresentation.matchSummary(of: anyRemote))
        #expect(RulePresentation.matchSummary(of: annotationRule(.hide, mode: .any)).contains("任一满足"))
    }

    @Test func summaryForBodyRuleTruncatesLongText() {
        let short = bodyRule(find: "foo", replacement: "bar")
        let match = RulePresentation.matchSummary(short.matcher)
        #expect(RulePresentation.summary(of: short) == L10n.format(
            "rules.summary.rewriteBody.response", match, "foo", "bar"))

        let exactly40 = String(repeating: "a", count: 40)
        let long = String(repeating: "b", count: 41)
        let rule = bodyRule(find: long, replacement: exactly40, direction: .request)
        #expect(RulePresentation.summary(of: rule) == L10n.format(
            "rules.summary.rewriteBody.request", match, String(repeating: "b", count: 40) + "…", exactly40))
        // Whole characters, not bytes.
        let wide = String(repeating: "正", count: 41)
        #expect(RulePresentation.summary(of: bodyRule(find: wide, replacement: "")).contains(String(repeating: "正", count: 40) + "…"))
    }

    @Test func summaryForStatusRule() {
        let rule = Rule(
            id: UUID(), name: "s", enabled: true, order: 0, matcher: RuleMatcher(hostPattern: "a.test"),
            action: .rewriteStatus(RewriteStatusAction(status: 404)))
        #expect(RulePresentation.summary(of: rule) == L10n.format(
            "rules.summary.rewriteStatus", RulePresentation.matchSummary(rule.matcher), 404))
        #expect(RulePresentation.summary(of: rule).contains("404"))
    }

    @Test func outcomeLinesCoverEveryNewCode() {
        let cases: [(RuleOutcomeCode, String)] = [
            (.patternTimedOut, "ruleOutcome.patternTimedOut"), (.patternDisabled, "ruleOutcome.patternDisabled"),
            (.bodyNoMatch, "ruleOutcome.bodyNoMatch"), (.bodySkippedTooLarge, "ruleOutcome.bodySkippedTooLarge"),
            (.bodySkippedNotText, "ruleOutcome.bodySkippedNotText"),
            (.bodySkippedUndecodable, "ruleOutcome.bodySkippedUndecodable"),
            (.bodySkippedBreakpoint, "ruleOutcome.bodySkippedBreakpoint"),
            (.bodySkippedLocalRoute, "ruleOutcome.bodySkippedLocalRoute"),
            (.bodySkippedNoBody, "ruleOutcome.bodySkippedNoBody"),
            (.bodySkippedUnavailable, "ruleOutcome.bodySkippedUnavailable"),
            (.bodySkippedBusy, "ruleOutcome.bodySkippedBusy"),
            (.bodySkippedAborted, "ruleOutcome.bodySkippedAborted"),
            (.statusSkippedLocal, "ruleOutcome.statusSkippedLocal"),
        ]
        for (code, key) in cases {
            let lines = RulePresentation.outcomeLines(matches([RuleOutcome(ruleID: ruleA, code: code)]), ruleName: names)
            #expect(lines == [L10n.format(key, "Fix price")], "\(code.rawValue)")
            #expect(lines.first?.contains("Fix price") == true && lines.first?.hasPrefix("ruleOutcome.") == false)
        }
        // Once per rule and code, in first-seen order; other codes are not problems.
        let lines = RulePresentation.outcomeLines(
            matches([
                RuleOutcome(ruleID: ruleA, code: .bodyNoMatch),
                RuleOutcome(ruleID: ruleA, code: .applied),
                RuleOutcome(ruleID: ruleA, code: .bodyNoMatch),
                RuleOutcome(ruleID: ruleB, code: .statusSkippedLocal),
                RuleOutcome(ruleID: ruleA, code: .bodySkippedNotText),
                RuleOutcome(ruleID: ruleA, code: .breakpointBodyIgnored),
            ]),
            ruleName: names)
        #expect(lines == [
            L10n.format("ruleOutcome.bodyNoMatch", "Fix price"),
            L10n.format("ruleOutcome.statusSkippedLocal", "Force 404"),
            L10n.format("ruleOutcome.bodySkippedNotText", "Fix price"),
        ])
        #expect(RulePresentation.outcomeLines(nil, ruleName: names).isEmpty)
    }

    @Test func newOutcomeCodesHaveSentences() {
        let cases: [(RuleOutcomeCode, String, String)] = [
            (.unknownSize, "ruleOutcome.unknownSize", "规则「Fix price」有一个条件无法判断：报文的大小未知。"),
            (.appUnknown, "ruleOutcome.appUnknown", "规则「Fix price」有一个条件无法判断：还没查到发起这个请求的应用。"),
            (.bodyTooLarge, "ruleOutcome.bodyTooLarge", "规则「Fix price」有一个条件无法判断：正文超过 1 MiB，没有读取。"),
            (.bodySkippedOnDisk, "ruleOutcome.bodySkippedOnDisk", "规则「Fix price」有一个条件无法判断：正文已存到磁盘，没有读取。"),
            (.bodySkippedStreaming, "ruleOutcome.bodySkippedStreaming", "规则「Fix price」有一个条件无法判断：正文是流式或长度未知，没有读取。"),
        ]
        for (code, key, sentence) in cases {
            let outcomes = matches([RuleOutcome(ruleID: ruleA, code: code), RuleOutcome(ruleID: ruleA, code: code)])
            #expect(RulePresentation.outcomeLines(outcomes, ruleName: names) == [sentence], "\(code.rawValue)")
            #expect(L10n.format(key, "Fix price") == sentence)
            let result = RulePresentation.resultLines(outcomes, ruleName: names)
            #expect(result == [RuleResultLine(text: sentence, tone: .attention)], "\(code.rawValue)")
        }
    }

    @Test func bodySkippedNotTextCoversConditions() {
        let lines = RulePresentation.outcomeLines(
            matches([RuleOutcome(ruleID: ruleA, code: .bodySkippedNotText)]), ruleName: names)
        // No longer "not applied ... forwarded unchanged": a condition may be the one that could not read it.
        #expect(lines == ["规则「Fix price」没有读取或改写正文：它不是可解码的文本。"])
    }

    @Test func patternProblemLinesUnchanged() {
        let summary = matches([
            RuleOutcome(ruleID: ruleA, code: .patternTimedOut),
            RuleOutcome(ruleID: ruleA, code: .bodyNoMatch),
            RuleOutcome(ruleID: ruleB, code: .patternDisabled),
            RuleOutcome(ruleID: ruleB, code: .statusSkippedLocal),
        ])
        #expect(RulePresentation.patternProblemLines(summary, ruleName: names) == [
            L10n.format("ruleOutcome.patternTimedOut", "Fix price"),
            L10n.format("ruleOutcome.patternDisabled", "Force 404"),
        ])
        #expect(RulePresentation.patternProblemLines(nil, ruleName: names).isEmpty)
    }

    @Test func unknownRuleNameUsesPlaceholder() {
        let lines = RulePresentation.outcomeLines(matches([RuleOutcome(ruleID: gone, code: .bodySkippedTooLarge)]), ruleName: names)
        #expect(lines == [L10n.format("ruleOutcome.bodySkippedTooLarge", L10n.string("ruleOutcome.unknownRule"))])
    }
}

// Rules 2.0 R4: the summaries of the new actions and the two new outcome sentences.
extension RulePresentationTests {
    private func summary(_ kind: ActionKind) -> String { RulePresentation.actionSummary(of: kind) ?? "" }

    @Test func olderActionsHaveNoNewActionSummary() {
        #expect(RulePresentation.actionSummary(of: .hide) == nil)
        #expect(RulePresentation.actionSummary(of: .rewriteStatus(RewriteStatusAction(status: 200))) == nil)
        #expect(RulePresentation.actionSummary(of: .noDecrypt) != nil)
    }

    @Test func newActionSummariesAreWholeSentences() {
        #expect(summary(.modifyURL(URLEditAction(mode: .set, replacement: "https://b.test/x"))) == "把 URL 改为 https://b.test/x")
        // Append mode has its own sentence; it used to read "Set URL to ..." in both languages.
        #expect(summary(.modifyURL(URLEditAction(mode: .append, replacement: "?debug=1"))) == "在 URL 末尾追加 ?debug=1")
        #expect(
            summary(.modifyURL(URLEditAction(mode: .findReplace, find: "a.test", replacement: "b.test")))
                == "在 URL 中把「a.test」替换为「b.test」")
        #expect(summary(.modifyURL(URLEditAction(mode: .regex, find: "v(\\d)", replacement: "w$1"))) == "用正则改写 URL（v(\\d)）")
        #expect(
            summary(.modifyQuery(QueryEditAction(operations: [.remove(name: "a"), .add(name: "b", value: "1")])))
                == "修改查询参数（2 项）")
        #expect(summary(.editCookies(direction: .request, operations: [.remove(name: "a")])) == "修改请求 Cookie（1 项）")
        #expect(
            summary(.editCookies(direction: .response, operations: [.remove(name: "a"), .remove(name: "b"), .remove(name: "c")]))
                == "修改响应 Cookie（3 项）")
        #expect(summary(.delay(milliseconds: 500)) == "延迟请求 500 毫秒")
        #expect(
            summary(.returnHandwritten(HandwrittenResponse(text: "HTTP/1.1 418 I'm a teapot\r\n\r\n"))) == "返回手写响应（状态码 418）")
        #expect(summary(.returnPreset(PresetResponse(preset: .notFound404))) == "返回预置响应：404 Not Found")
        #expect(summary(.closeConnection(.graceful)) == "关闭连接（正常）")
        #expect(summary(.closeConnection(.reset)) == "关闭连接（强制复位）")
        #expect(summary(.returnConnectTunnel) == "返回 CONNECT 隧道")
        #expect(summary(.noDecrypt) == "不解密")
    }

    @Test func everyNewSummaryIsNonEmptyAndHasNoFormatLeftovers() {
        let kinds: [ActionKind] = [
            .modifyURL(URLEditAction(mode: .set, replacement: "https://b.test/")),
            .modifyURL(URLEditAction(mode: .findReplace, find: "a", replacement: "b")),
            .modifyURL(URLEditAction(mode: .regex, find: "a", replacement: "b")),
            .modifyQuery(QueryEditAction(operations: [])),
            .editCookies(direction: .request, operations: []), .editCookies(direction: .response, operations: []),
            .delay(milliseconds: 1), .returnHandwritten(HandwrittenResponse(text: "")),
            .returnPreset(PresetResponse(preset: .gif200)), .closeConnection(.graceful), .closeConnection(.reset),
            .returnConnectTunnel, .noDecrypt,
        ]
        for kind in kinds {
            let text = summary(kind)
            #expect(!text.isEmpty && !text.contains("%") && !text.hasPrefix("rules."), "\(kind): \(text)")
        }
    }

    @Test func eachPresetHasItsOwnName() {
        var names: Set<String> = []
        for preset in PresetResponse.Preset.allCases {
            let name = summary(.returnPreset(PresetResponse(preset: preset)))
            #expect(!name.contains("rules.preset"), "\(preset)")
            names.insert(name)
        }
        #expect(PresetResponse.Preset.allCases.count == 20)
        #expect(names.count == 20)
    }

    @Test func aRuleWithOneNewActionShowsThatActionInTheList() {
        let rule = Rule(
            id: UUID(), name: "r", enabled: true, groupID: nil, order: 0, conditions: ConditionGroup(),
            actions: [RuleAction(.delay(milliseconds: 250))], note: nil)
        #expect(RulePresentation.actionSummary(of: rule, assetName: { _ in nil }) == "延迟请求 250 毫秒")
    }

    @Test func newOutcomesAreExplained() {
        let outcomes = matches([
            RuleOutcome(ruleID: ruleA, code: .skippedByTool),
            RuleOutcome(ruleID: ruleB, code: .delayCapped),
        ])
        let lines = RulePresentation.resultLines(outcomes, ruleName: names)
        #expect(lines.map(\.text) == [
            "规则「Fix price」的动作没有执行：屏蔽 / 允许列表 / SSL 解密列表已经决定了这条连接怎么处理。",
            "规则「Force 404」的延迟累计超过 60 秒，已按 60 秒执行。",
        ])
        #expect(lines.allSatisfy { $0.tone == .attention })
        #expect(RulePresentation.outcomeLines(outcomes, ruleName: names) == lines.map(\.text))
    }

    @Test func headerEditNoMatchIsExplainedAndHeaderSummaryStaysTheSame() {
        let lines = RulePresentation.resultLines(matches([RuleOutcome(ruleID: ruleA, code: .editNoMatch)]), ruleName: names)
        #expect(lines.map(\.text) == ["规则「Fix price」的 Header 修改没有找到匹配的字段。"])
        #expect(lines.allSatisfy { $0.tone == .attention })
        let rule = Rule(
            id: UUID(), name: "r", enabled: true, groupID: nil, order: 0, conditions: ConditionGroup(),
            actions: [
                RuleAction(
                    .editHeaders(
                        direction: .request,
                        operations: [.appendToValue(name: "A", text: "b"), .addIfMissing(name: "C", value: "d")]))
            ], note: nil)
        #expect(RulePresentation.actionSummary(of: rule, assetName: { _ in nil }) == "修改请求 Header，共 2 项")
    }
}

// Rules 2.0 R5: body edit operations.
extension RulePresentationTests {
    @Test func bodySetValueAndClearHaveTheirOwnSentences() {
        let set = ActionKind.rewriteBody(
            direction: .response, BodyRewriteAction(find: "", replacement: "ok", operation: .setValue))
        let clear = ActionKind.rewriteBody(direction: .request, BodyRewriteAction(find: "", replacement: "", operation: .clear))
        #expect(RulePresentation.actionSummary(of: set) == "把正文设为「ok」")
        #expect(RulePresentation.actionSummary(of: clear) == "清空正文")
        #expect(RulePresentation.actionSummary(of: .rewriteBody(direction: .response, BodyRewriteAction(find: "a", replacement: "b"))) == nil)
        let rule = Rule(
            id: UUID(), name: "r", enabled: true, groupID: nil, order: 0, conditions: ConditionGroup(),
            actions: [RuleAction(clear)], note: nil)
        #expect(RulePresentation.actionSummary(of: rule, assetName: { _ in nil }) == "清空正文")
        #expect(RulePresentation.summary(of: rule).contains("rules.summary.rewriteBody") == false)
    }
}

@Suite(.productionChinese) struct OutcomeLineCardNumberTests {
    /// Stored: 0 mark, 1 header edit with three operations (several cards), 2 hide.
    private func splitRule() -> Rule {
        Rule(
            id: ruleA, name: "Fix price", conditions: ConditionGroup(mode: .all, rows: []),
            actions: [
                RuleAction(.mark(MarkAction(background: "#FF3B30"))),
                RuleAction(
                    .editHeaders(
                        direction: .request,
                        operations: [.set(name: "A", value: "1"), .set(name: "B", value: "2"), .remove(name: "C")])),
                RuleAction(.hide),
            ])
    }

    @Test func theDocumentMapsStoredActionsToTheirFirstCard() {
        let document = RuleDocument(rule: splitRule())
        #expect(document.actions.count > 3)
        let owners = document.storedActionOwners()
        #expect(owners.count == 3)
        #expect(owners[0] == 0 && owners[1] == 1)
        #expect(owners[2] == document.actions.count - 1)
        #expect(document.cardIndex(forStoredAction: 2) == document.actions.count - 1)
        #expect(document.cardIndex(forStoredAction: 3) == nil && document.cardIndex(forStoredAction: -1) == nil)
        // An untouched rule rebuilds to the stored actions the owners point at.
        #expect(document.assemble(document.actions.map { $0.build() })?.owners == owners)
    }

    @Test func outcomeLinesNumberTheCardWhenTheRuleIsOpenInTheEditor() {
        let document = RuleDocument(rule: splitRule())
        let outcomes = matches([RuleOutcome(ruleID: ruleA, code: .finalStop, actionIndex: 2)])
        // Without a mapping the stored index is shown, as before.
        #expect(RulePresentation.outcomeLines(outcomes, ruleName: names) == [L10n.format("ruleOutcome.finalStop", "Fix price", 3)])
        let shown = document.actions.count
        let mapped = RulePresentation.outcomeLines(
            outcomes, ruleName: names, cardIndex: { rule, stored, _ in rule == ruleA ? document.cardIndex(forStoredAction: stored) : nil })
        #expect(mapped == [L10n.format("ruleOutcome.finalStop", "Fix price", shown)])
        // A rule that is not open (no mapping answer) keeps the stored number.
        let other = RulePresentation.outcomeLines(
            matches([RuleOutcome(ruleID: ruleB, code: .finalStop, actionIndex: 1)]), ruleName: names,
            cardIndex: { _, _, _ in nil })
        #expect(other == [L10n.format("ruleOutcome.finalStop", "Force 404", 2)])
        let results = RulePresentation.resultLines(
            matches([RuleOutcome(ruleID: ruleA, code: .applied, actionIndex: 2)]), ruleName: names,
            cardIndex: { _, stored, _ in document.cardIndex(forStoredAction: stored) })
        #expect(results.map(\.text) == [L10n.format("ruleOutcome.appliedAction", "Fix price", shown)])
    }
}
