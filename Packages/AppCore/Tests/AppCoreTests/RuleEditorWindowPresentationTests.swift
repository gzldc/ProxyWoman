import Foundation
import Localization
import RulesEngine
import Testing

@testable import AppCore

@Suite(.productionChinese) struct RuleEditorWindowPresentationTests {
    private let zh = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])

    // MARK: group menu

    @Test func groupChoicesStartWithTheRootAndIndentByDepthInTreeOrder() {
        let a = RuleGroup(name: "A", parentID: nil, order: 1)
        let b = RuleGroup(name: "B", parentID: nil, order: 0)
        let a1 = RuleGroup(name: "A1", parentID: a.id, order: 0)
        let a11 = RuleGroup(name: "A11", parentID: a1.id, order: 0)
        let choices = RuleEditorWindowPresentation.groupChoices([a, a11, b, a1])
        #expect(choices.map(\.name) == ["", "B", "A", "A1", "A11"])
        #expect(choices.map(\.depth) == [0, 1, 1, 2, 3])
        #expect(choices.first?.id == nil)
        #expect(choices.dropFirst().map(\.id) == [b.id, a.id, a1.id, a11.id])
    }

    @Test func aGroupWhoseParentIsMissingIsListedUnderTheRoot() {
        let orphan = RuleGroup(name: "Lost", parentID: UUID(), order: 0)
        let choices = RuleEditorWindowPresentation.groupChoices([orphan])
        #expect(choices.map(\.id) == [nil, orphan.id])
        #expect(choices.last?.depth == 1)
    }

    @Test func aCycleOfGroupsDoesNotLoopForever() {
        var x = RuleGroup(name: "X", parentID: nil, order: 0)
        var y = RuleGroup(name: "Y", parentID: x.id, order: 0)
        x.parentID = y.id
        y.parentID = x.id
        let choices = RuleEditorWindowPresentation.groupChoices([x, y])
        #expect(choices.count == 1)
    }

    @Test func groupMenuTitlesNameTheRootAndIndent() {
        let root = RuleGroupChoice(id: nil, name: "", depth: 0)
        let deep = RuleGroupChoice(id: UUID(), name: "Deep", depth: 2)
        let empty = RuleGroupChoice(id: UUID(), name: "", depth: 1)
        #expect(RuleEditorWindowPresentation.title(of: root, localizer: zh) == "未分组")
        #expect(RuleEditorWindowPresentation.title(of: deep, localizer: zh).hasSuffix("Deep"))
        #expect(RuleEditorWindowPresentation.title(of: deep, localizer: zh).count > "Deep".count)
        #expect(RuleEditorWindowPresentation.title(of: empty, localizer: zh).contains(RulePresentation.displayName("", localizer: zh)))
    }

    // MARK: close prompt (R8F3-8)

    @Test func closePromptOffersSaveDontSaveCancelForAValidDocument() {
        let prompt = RuleEditorWindowPresentation.closePrompt(.askSave(name: "我的规则"), localizer: zh)
        #expect(prompt?.message == "要保存对“我的规则”的改动吗？")
        #expect(prompt?.detail == "你有未保存的改动，关闭后将丢失。")
        #expect(prompt?.canSave == true)
        #expect(prompt?.saveTitle == "保存" && prompt?.discardTitle == "不保存" && prompt?.cancelTitle == "取消")
    }

    @Test func closePromptForAnInvalidDocumentHasNoSave() {
        let prompt = RuleEditorWindowPresentation.closePrompt(.askDiscardOnly, localizer: zh)
        #expect(prompt?.message == "不保存就关闭？")
        #expect(prompt?.canSave == false)
        #expect(prompt?.discardTitle == "不保存" && prompt?.cancelTitle == "取消")
    }

    @Test func closePromptIsNilWhenTheWindowMayCloseAtOnce() {
        #expect(RuleEditorWindowPresentation.closePrompt(.closeNow, localizer: zh) == nil)
    }

    @Test func closePromptShortensALongNameToTwentyFourCharacters() {
        let long = String(repeating: "长", count: 30)
        let prompt = RuleEditorWindowPresentation.closePrompt(.askSave(name: long), localizer: zh)
        #expect(prompt?.message == "要保存对“\(String(repeating: "长", count: 24))…”的改动吗？")
        let exact = String(repeating: "长", count: 24)
        #expect(RuleEditorWindowPresentation.closePrompt(.askSave(name: exact), localizer: zh)?.message == "要保存对“\(exact)”的改动吗？")
    }

    // MARK: window words

    @Test func windowTitle() {
        #expect(RuleEditorWindowPresentation.windowTitle(isNew: true, localizer: zh) == "新建规则")
        #expect(RuleEditorWindowPresentation.windowTitle(isNew: false, localizer: zh) == "编辑规则")
    }

    @Test func saveIsOfferedWhenNothingRunsEvenIfNothingChanged() {
        func can(busy: Bool = false, importing: Bool = false, doc: Bool = true) -> Bool {
            RuleEditorWindowPresentation.canSave(hasDocument: doc, isBusy: busy, isImporting: importing)
        }
        #expect(can())
        #expect(!can(busy: true))
        #expect(!can(importing: true))
        #expect(!can(doc: false))
    }

    @Test func headerAndJudgmentWordsAreHumanAndCarryNoPointCodes() {
        #expect(RuleEditorWindowPresentation.headerModeTitle(.all, localizer: zh) == "满足全部条件")
        #expect(RuleEditorWindowPresentation.headerModeTitle(.any, localizer: zh) == "满足任一条件")
        #expect(RuleEditorWindowPresentation.headerModeTitle(.none, localizer: zh) == "全都不满足")
        #expect(RuleEditorWindowPresentation.matchedAtLine(.request, localizer: zh) == "会话将在请求阶段匹配。")
        #expect(RuleEditorWindowPresentation.matchedAtLine(.response, localizer: zh) == "会话将在响应阶段匹配。")
        #expect(RuleEditorWindowPresentation.matchedAtLine(.completion, localizer: zh) == "会话将在完成时匹配。")
        #expect(RuleEditorWindowPresentation.matchedAtLine(.connect, localizer: zh) == "会话将在请求阶段匹配。")
        for point in [EvaluationPoint.connect, .request, .response, .completion] {
            let line = RuleEditorWindowPresentation.matchedAtLine(point, localizer: zh)
            #expect(!line.contains("P0") && !line.contains("P1") && !line.contains("P2") && !line.contains("P3"))
        }
        #expect(RuleEditorWindowPresentation.autoName(localizer: zh) == "未命名规则")
    }

    @Test func aSaveResultSaysWhatToShow() {
        #expect(RuleEditorWindowPresentation.failureMessage(.failed(.conflict), localizer: zh) == zh.string("rules.editor2.conflictInRulesWindow"))
        #expect(RuleEditorWindowPresentation.failureMessage(.invalid, localizer: zh) == "请先修改标红的内容，再保存。")
        #expect(RuleEditorWindowPresentation.failureMessage(.saved, localizer: zh) == nil)
        #expect(RuleEditorWindowPresentation.failureMessage(.busy, localizer: zh) == "正在处理中，请稍后再试。")
        #expect(RuleEditorWindowPresentation.failureMessage(.needsConfirmation([.everySessionFinal]), localizer: zh) == nil)
    }

    // MARK: condition rows

    @Test func fieldMenuEntriesCarryDirectionTitleAndSide() {
        let all = ConditionFieldCatalog.menuSections.flatMap(\.entries)
        #expect(ConditionFieldCatalog.menuSections.map { $0.kind.title(localizer: zh) } == ["请求", "响应", "其他"])
        #expect(ConditionPresentation.fieldTitle(.durationMs, localizer: zh) == "耗时")
        #expect(ConditionEditorPresentation.title(ConditionField.durationMs.side, localizer: zh) == "无")
        #expect(ConditionEditorPresentation.title(ConditionField.responseHeader.side, localizer: zh) == "响应")
        #expect(ConditionEditorPresentation.title(ConditionField.url.side, localizer: zh) == "两侧")
        #expect(all.first { $0.field == .requestHeader }?.field.side == .request)
        // A field is in the menu once.
        #expect(Set(all.map(\.field)).count == all.count)
    }

    @Test func fieldSectionsListEveryNewFieldOnceAndOnlyThoseInTheListedSections() {
        let all = ConditionFieldCatalog.menuSections.flatMap(\.entries)
        // The four old-style fields are not offered; every other field is, once.
        let oldStyle: Set<ConditionField> = [.port, .queryString, .queryParam, .pathAndQuery]
        #expect(Set(all.map(\.field)) == Set(ConditionField.allCases).subtracting(oldStyle))
        #expect(all.count == ConditionField.allCases.count - oldStyle.count)
        #expect(ConditionFieldCatalog.menuSections.allSatisfy { !$0.entries.isEmpty })
        let sessionState = all.first { $0.field == .sessionState }
        #expect(sessionState?.isDeprecated == true)
        #expect(all.first { $0.field == .url }?.direction == .request)
        #expect(all.first { $0.field == .appProtocol }?.direction == .response)
    }

    @Test func rowMatchLineIsAlwaysThereWhenTheRowCanBeCounted() throws {
        // A row that is not valid yet matches nothing: red zero, so the line never disappears.
        let empty = try #require(RuleBuilderPresentation.rowMatchLine(count: nil, rowIsValid: false, localizer: zh))
        #expect(empty.text == zh.format("rules.builder.matchCount", arguments: [0]))
        #expect(empty.tone == .failure)
        let none = try #require(RuleBuilderPresentation.rowMatchLine(count: 0, rowIsValid: true, localizer: zh))
        #expect(none.tone == .failure)
        let some = try #require(RuleBuilderPresentation.rowMatchLine(count: 3, rowIsValid: true, localizer: zh))
        #expect(some.tone == .success)
        #expect(some.text == zh.format("rules.builder.matchCount", arguments: [3]))
        // A valid row still being counted has nothing to say yet.
        #expect(RuleBuilderPresentation.rowMatchLine(count: nil, rowIsValid: true, localizer: zh) == nil)
    }

    @Test func valueInputFollowsTheFieldTheNameAndTheComparison() {
        func input(_ field: ConditionField, name: String? = nil, op: ConditionOperator = .equals) -> ConditionValueInput {
            ConditionRowPresentation.valueInput(field: field, name: name, op: op, localizer: zh)
        }
        #expect(input(.host) == .text)
        #expect(input(.port) == .number)
        #expect(input(.clientApp, name: "pid") == .number)
        #expect(input(.clientApp, name: "name") == .text)
        #expect(input(.requestDate) == .date)
        #expect(input(.rulesModified) == .bool)
        #expect(input(.allSessions) == .none)
        #expect(input(.host, op: .isEmpty) == .none)
        #expect(input(.requestBody, op: .isNotEmpty) == .none)
        guard case .choice(let states) = input(.sessionState) else { Issue.record("choice"); return }
        #expect(states.map(\.value) == ["opened", "closed", "paused"])
        #expect(states.map(\.title) == ["已打开", "已关闭", "已暂停"])
        guard case .choice(let schemes) = input(.scheme) else { Issue.record("choice"); return }
        #expect(schemes.map(\.title) == ["HTTPS", "HTTP"])
        guard case .choice(let protocols) = input(.appProtocol) else { Issue.record("choice"); return }
        #expect(protocols.map(\.title) == ["HTTP", "WebSocket", "RPC", "gRPC", "Server-sent Events", "Socket.IO"])
    }

    @Test func everyChoiceOfEveryFieldHasAReadableTitle() {
        for field in ConditionFieldCatalog.menuSections.flatMap(\.entries).map(\.field) {
            guard case .choice(let choices) = ConditionRowPresentation.valueInput(field: field, name: nil, op: .equals, localizer: zh)
            else { continue }
            for choice in choices { #expect(!choice.title.isEmpty && !choice.title.hasPrefix("rules."), "\(field) \(choice.value)") }
        }
    }

    @Test func hintsForRangesAndDates() {
        #expect(ConditionRowPresentation.hint(field: .port, name: nil, op: .inRange, localizer: zh) == "范围写成「起..止」，例如 100..200。")
        #expect(ConditionRowPresentation.hint(field: .requestDate, name: nil, op: .equals, localizer: zh) == "日期写成 年-月-日，例如 2026-01-31。")
        #expect(
            ConditionRowPresentation.hint(field: .requestDate, name: nil, op: .inRange, localizer: zh)
                == "日期范围写成「起..止」，例如 2026-01-01..2026-01-31。")
        #expect(ConditionRowPresentation.hint(field: .host, name: nil, op: .equals, localizer: zh) == nil)
    }

    @Test func nameChoicesExistOnlyForFieldsWithAFixedSetAndAllHaveTitles() {
        #expect(ConditionRowPresentation.nameChoices(for: .host) == nil)
        #expect(ConditionRowPresentation.nameChoices(for: .requestHeader) == nil)
        for field in [ConditionField.certificate, .clientApp] {
            let choices = ConditionRowPresentation.nameChoices(for: field, localizer: zh)
            #expect(choices?.map(\.value) == (field == .certificate ? CertificateField.allCases.map(\.rawValue) : ConditionField.allowedNames(for: field)))
            for choice in choices ?? [] { #expect(!choice.title.isEmpty && !choice.title.hasPrefix("rules."), "\(choice.value)") }
        }
        #expect(ConditionRowPresentation.nameChoices(for: .clientApp, localizer: zh)?.map(\.title) == ["应用名称", "可执行文件路径", "进程号"])
    }

    @Test func operatorChoicesKeepTheCurrentComparisonEvenWhenTheMenuWouldNotOfferIt() {
        var row = ConditionRowDraft(row: ConditionRow(field: .host, op: .equals, value: "a"))
        #expect(ConditionRowPresentation.operatorChoices(for: row) == ConditionOperator.fiddlerOperators(for: .host, name: nil).flatMap { $0 })
        row = ConditionRowDraft(row: ConditionRow(field: .host, op: .hostPattern, value: "*.a.com"))
        #expect(row.isLegacyShape)
        #expect(ConditionRowPresentation.operatorChoices(for: row).contains(.hostPattern))
    }

    @Test func aRowIsReadableOnlyForAnOldStyleShapeAndNeverForNewOnes() {
        let legacy = ConditionRowDraft(row: ConditionRow(field: .host, op: .wildcard, value: "*.a.com"))
        let current = ConditionRowDraft(row: ConditionRow(field: .host, op: .equals, value: "a"))
        #expect(ConditionRowPresentation.isReadOnly(legacy))
        #expect(!ConditionRowPresentation.isReadOnly(current))
    }

    @Test func changingTheNameToOneOfAnotherKindFixesTheComparisonAndClearsTheValue() {
        var row = ConditionRowDraft(row: ConditionRow(field: .clientApp, name: "name", op: .contains, value: "Safari"))
        row.setName("pid")
        #expect(row.name == "pid")
        #expect(row.op == .equals)
        #expect(row.value == "")
        row.setOperator(.greaterThan)
        row.value = "42"
        row.setName("path")
        #expect(row.op == .equals)
        #expect(row.value == "")
    }

    @Test func changingTheNameOfTheSameKindKeepsComparisonAndValue() {
        var row = ConditionRowDraft(row: ConditionRow(field: .requestHeader, name: "A", op: .contains, value: "x"))
        row.setName("Accept")
        #expect(row.name == "Accept" && row.op == .contains && row.value == "x")
    }
}
