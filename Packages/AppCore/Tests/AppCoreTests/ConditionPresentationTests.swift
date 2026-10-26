import Foundation
import Localization
import RulesEngine
import Testing

@testable import AppCore

@Suite(.productionChinese) struct ConditionPresentationTests {
    @Test func headerRowSummary() {
        let row = ConditionRow(field: .requestHeader, name: "X-Test", op: .equals, value: "1")
        #expect(ConditionPresentation.rowSummary(row) == "请求 Header（X-Test）等于 1")
    }

    @Test func unnamedRowSummary() {
        #expect(
            ConditionPresentation.rowSummary(ConditionRow(field: .statusCode, op: .greaterOrEqual, value: "500"))
                == "状态码 大于或等于 500")
        #expect(
            ConditionPresentation.rowSummary(ConditionRow(field: .durationMs, op: .greaterThan, value: "1000"))
                == "耗时 大于 1000")
    }

    @Test func isEmptyRowOmitsTheValue() {
        #expect(
            ConditionPresentation.rowSummary(ConditionRow(field: .requestBody, op: .isEmpty, value: "ignored"))
                == "请求正文 为空")
        #expect(
            ConditionPresentation.rowSummary(ConditionRow(field: .responseHeader, name: "Location", op: .isNotEmpty))
                == "响应 Header（Location）不为空")
    }

    @Test func choiceAndBoolValuesAreShownInWords() {
        #expect(
            ConditionPresentation.rowSummary(ConditionRow(field: .sessionState, op: .equals, value: "failed"))
                == "会话状态 是 失败")
        #expect(
            ConditionPresentation.rowSummary(ConditionRow(field: .appProtocol, op: .notEquals, value: "websocket"))
                == "协议 不等于 WebSocket")
        #expect(
            ConditionPresentation.rowSummary(ConditionRow(field: .rulesModified, op: .equals, value: "true"))
                == "已被规则修改：是")
        #expect(
            ConditionPresentation.rowSummary(ConditionRow(field: .rulesModified, op: .equals, value: "false"))
                == "已被规则修改：否")
        // A choice without a sentence of its own, and a value that is none of them, are shown as written.
        #expect(
            ConditionPresentation.rowSummary(ConditionRow(field: .scheme, op: .equals, value: "https")) == "协议方案 是 HTTPS")
        #expect(
            ConditionPresentation.rowSummary(ConditionRow(field: .sessionState, op: .equals, value: "odd")) == "会话状态 是 odd")
    }

    @Test func modeWrapsTheRows() {
        let rows = [
            ConditionRow(field: .durationMs, op: .greaterThan, value: "1000"),
            ConditionRow(field: .requestHeader, name: "X-Test", op: .equals, value: "1"),
        ]
        #expect(
            ConditionPresentation.summary(ConditionGroup(mode: .all, rows: rows))
                == "全部满足：耗时 大于 1000；请求 Header（X-Test）等于 1")
        #expect(
            ConditionPresentation.summary(ConditionGroup(mode: .any, rows: rows))
                == "任一满足：耗时 大于 1000；请求 Header（X-Test）等于 1")
        #expect(
            ConditionPresentation.summary(ConditionGroup(mode: .none, rows: rows))
                == "都不满足：耗时 大于 1000；请求 Header（X-Test）等于 1")
        // One row needs no "all of"; "none of" still says what it means.
        #expect(ConditionPresentation.summary(ConditionGroup(mode: .all, rows: [rows[0]])) == "耗时 大于 1000")
        #expect(ConditionPresentation.summary(ConditionGroup(mode: .any, rows: [rows[0]])) == "耗时 大于 1000")
        #expect(ConditionPresentation.summary(ConditionGroup(mode: .none, rows: [rows[0]])) == "都不满足：耗时 大于 1000")
    }

    @Test func emptyGroupIsAllSessions() {
        for mode in ConditionGroup.Mode.allCases {
            #expect(ConditionPresentation.summary(ConditionGroup(mode: mode, rows: [])) == "所有会话")
        }
    }

    @Test func legacyRowsKeepTheirExistingWording() {
        // A rule on fixed fields is summarised by RulePresentation as before; only rules with a row on
        // the new path take the condition wording.
        let legacy = Rule(
            id: UUID(), name: "L", enabled: true, order: 0, matcher: RuleMatcher(hostPattern: "a.test"),
            action: .rewriteStatus(RewriteStatusAction(status: 404)))
        #expect(RulePresentation.matchSummary(of: legacy) == RulePresentation.matchSummary(legacy.matcher))
        var multiple = Rule(
            id: UUID(), name: "M", enabled: true, order: 0,
            conditions: ConditionGroup(rows: [ConditionRow(field: .host, op: .hostPattern, value: "a.test")]),
            actions: [RuleAction(.hide), RuleAction(.mark(MarkAction(background: "#FF0000")))])
        #expect(RulePresentation.matchSummary(of: multiple) == L10n.format("rules.summary.conditionsCount", 1))
        multiple.conditions.rows.append(ConditionRow(field: .durationMs, op: .greaterThan, value: "1000"))
        #expect(
            RulePresentation.matchSummary(of: multiple)
                == "全部满足：主机 主机模式（旧式） a.test；耗时 大于 1000")
    }

    @Test func everyFieldAndOperatorHasATitle() {
        for field in ConditionField.allCases {
            let title = ConditionPresentation.fieldTitle(field)
            #expect(!title.isEmpty && !title.hasPrefix("rules.condition."), "\(field)")
        }
        for op in ConditionOperator.allCases {
            let title = ConditionPresentation.operatorTitle(op)
            #expect(!title.isEmpty && !title.hasPrefix("rules.condition."), "\(op)")
        }
        #expect(ConditionPresentation.fieldTitle(.requestHeader) == "请求 Header")
        #expect(ConditionPresentation.operatorTitle(.regexWhole) == "整串正则（旧式）")
    }
}
