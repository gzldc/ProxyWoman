import FlowStore
import Foundation
import Localization
import RulesEngine
import Testing
@testable import AppCore

private func rule(
    name: String = "r", enabled: Bool = true, matcher: RuleMatcher = RuleMatcher(hostPattern: "a.test"), _ action: LegacyRuleAction
) -> Rule {
    Rule(id: UUID(), name: name, enabled: enabled, order: 0, matcher: matcher, action: action)
}

/// The Action column and the filter text of the rules table.
@Suite(.productionChinese) struct RuleListColumnsTests {
    @Test func mapLocalNamesTheFileAndTheStatus() {
        let asset = UUID()
        let mapped = rule(.mapLocal(MapLocalAction(assetID: asset, status: 201, headers: [])))
        #expect(RulePresentation.actionSummary(of: mapped, assetName: { $0 == asset ? "mock.json" : nil }) == "返回本地文件「mock.json」，状态码 201")
        // A file the model does not know any more is said so rather than left blank.
        #expect(RulePresentation.actionSummary(of: mapped, assetName: { _ in nil }) == "返回本地文件「未知文件」，状态码 201")
    }

    @Test func mapLocalDirectoryNamesTheDirectory() {
        // A directory is served under the prefix its rule matches.
        let mapped = rule(
            matcher: RuleMatcher(hostPattern: "a.test", path: .prefix("/site/")),
            .mapLocalDirectory(MapLocalDirectoryAction(bookmark: Data(), displayName: "site")))
        #expect(RulePresentation.actionSummary(of: mapped, assetName: { _ in nil }) == "映射到目录「site」")
    }

    @Test func mapRemoteShowsTheTargetAndAReplacedPath() {
        let keep = rule(.mapRemote(MapRemoteAction(targetScheme: "https", targetHost: "b.test", targetPort: 8443, path: .preserve)))
        #expect(RulePresentation.actionSummary(of: keep, assetName: { _ in nil }) == "转发到 https://b.test:8443")
        let replace = rule(.mapRemote(MapRemoteAction(targetScheme: "http", targetHost: "b.test", targetPort: 80, path: .replace("/v2/x?y=1"))))
        #expect(RulePresentation.actionSummary(of: replace, assetName: { _ in nil }) == "转发到 http://b.test:80/v2/x?y=1")
    }

    @Test func headerEditsCountTheirOperationsAndNameTheSide() {
        let edits = rule(.editHeaders(direction: .response, operations: [.set(name: "A", value: "1"), .remove(name: "B")]))
        #expect(RulePresentation.actionSummary(of: edits, assetName: { _ in nil }) == "修改响应 Header，共 2 项")
    }

    @Test func breakpointsSayWhichSideAndWhetherTheBodyIsCollected() {
        let head = rule(.breakpoint(direction: .request, mode: .headers))
        let full = rule(.breakpoint(direction: .response, mode: .fullBody))
        #expect(RulePresentation.actionSummary(of: head, assetName: { _ in nil }) == "在请求上暂停")
        #expect(RulePresentation.actionSummary(of: full, assetName: { _ in nil }) == "在响应上暂停并收集完整正文")
    }

    @Test func bodyAndStatusRewritesShowWhatChanges() {
        let body = rule(.rewriteBody(direction: .response, BodyRewriteAction(find: "foo", replacement: "bar")))
        #expect(RulePresentation.actionSummary(of: body, assetName: { _ in nil }) == "在响应中将「foo」替换为「bar」")
        let long = rule(.rewriteBody(direction: .request, BodyRewriteAction(find: String(repeating: "b", count: 41), replacement: "")))
        #expect(RulePresentation.actionSummary(of: long, assetName: { _ in nil }) == "在请求中将「" + String(repeating: "b", count: 40) + "…」替换为「」")
        let status = rule(.rewriteStatus(RewriteStatusAction(status: 404)))
        #expect(RulePresentation.actionSummary(of: status, assetName: { _ in nil }) == "状态码改为 404")
    }

    @Test func theFilterTextCoversNameKindMatchingAndAction() {
        let status = rule(name: "Force 404", .rewriteStatus(RewriteStatusAction(status: 404)))
        let fields = RulePresentation.searchFields(of: status, assetName: { _ in nil })
        #expect(fields.contains("Force 404"))
        #expect(fields.contains(RuleKind.rewriteStatus.title))
        #expect(fields.contains(RulePresentation.matchSummary(status.matcher)))
        #expect(fields.contains("状态码改为 404"))
        // An unnamed rule is searched by the placeholder the list shows.
        let unnamed = rule(name: "  ", .rewriteStatus(RewriteStatusAction(status: 500)))
        #expect(RulePresentation.searchFields(of: unnamed, assetName: { _ in nil }).contains(L10n.string("rules.list.unnamed")))
    }

    @Test func aNewRuleDefaultsToTheSelectedKindOrMapLocal() {
        #expect(RuleKind.kindForNewDraft(selected: nil) == .mapLocal)
        #expect(RuleKind.kindForNewDraft(selected: .breakpoint) == .breakpoint)
        #expect(RuleKind.kindForNewDraft(selected: .rewriteStatus) == .rewriteStatus)
    }

    @Test func theDraftRowTakesBothCellsFromOneValidation() throws {
        var draft = RuleEditorDraft(kind: .rewriteStatus)
        draft.match.host = "a.test"
        draft.rewriteStatus.status = "404"
        let validation = draft.validate(order: 0, limits: RulesLimits())
        let saved = try #require(validation.rule)
        let cells = RulePresentation.draftRowSummary(validation, assetName: { _ in nil })
        #expect(cells.matching == RulePresentation.matchSummary(saved.matcher))
        #expect(cells.action == RulePresentation.actionSummary(of: saved, assetName: { _ in nil }))
        #expect(!cells.matching.isEmpty && !cells.action.isEmpty)

        // A draft with an issue shows empty cells; the issue itself is in the form.
        draft.rewriteStatus.status = "x"
        let invalid = draft.validate(order: 0, limits: RulesLimits())
        #expect(invalid.rule == nil)
        let empty = RulePresentation.draftRowSummary(invalid, assetName: { _ in nil })
        #expect(empty.matching.isEmpty && empty.action.isEmpty)
    }
}
