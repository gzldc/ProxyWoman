import Foundation
import Localization
import Testing
@testable import AppCore

@MainActor @Suite(.timeLimit(.minutes(1)), .productionChinese) struct ComposeWorkspaceModelTests {
    private func makeWorkspace(files: FakeComposeBodyFiles = FakeComposeBodyFiles(), client: FakeComposeClient = FakeComposeClient())
        -> ComposeWorkspaceModel {
        ComposeWorkspaceModel(make: { ComposeViewModel(draft: $0, client: client, files: files) })
    }

    @Test func openAppendsAndSelects() {
        let workspace = makeWorkspace()
        let first = workspace.open(ComposeDraft(method: "GET", url: "https://a.test/"))
        let second = workspace.newBlankTab()
        #expect(workspace.tabs.map(\.id) == [first.id, second.id])
        #expect(workspace.selectedID == second.id && workspace.selected === second)
    }

    @Test func closingCleanTabClosesImmediately() async {
        let workspace = makeWorkspace()
        let tab = workspace.newBlankTab()
        await workspace.requestClose(tab.id)
        #expect(workspace.tabs.isEmpty && workspace.pendingClose == nil && workspace.parked.isEmpty)
        #expect(workspace.selectedID == nil)
    }

    @Test func cancelPendingCloseResolvesQuestionSoLaterClosesWork() async {
        let workspace = makeWorkspace()
        let a = workspace.newBlankTab()
        a.draft.method = "PUT"
        let b = workspace.newBlankTab()
        await workspace.requestClose(a.id)
        #expect(workspace.pendingClose == a.id)
        workspace.cancelPendingClose()
        #expect(workspace.pendingClose == nil && workspace.tabs.count == 2)
        await workspace.requestClose(b.id)
        #expect(workspace.tabs.map(\.id) == [a.id])
    }

    @Test func doubleCloseOfCleanTabClosesOnce() async {
        let workspace = makeWorkspace()
        let tab = workspace.newBlankTab()
        async let first: Void = workspace.requestClose(tab.id)
        async let second: Void = workspace.requestClose(tab.id)
        _ = await (first, second)
        #expect(workspace.tabs.isEmpty && workspace.pendingClose == nil)
    }

    @Test func closingDirtyTabAsks() async {
        let workspace = makeWorkspace()
        let tab = workspace.newBlankTab()
        tab.draft.method = "POST"
        await workspace.requestClose(tab.id)
        #expect(workspace.pendingClose == tab.id)
        #expect(workspace.tabs.map(\.id) == [tab.id])
    }

    @Test func secondRequestCloseDoesNotOverwritePending() async {
        let workspace = makeWorkspace()
        let a = workspace.newBlankTab()
        let b = workspace.newBlankTab()
        a.draft.method = "POST"
        b.draft.method = "PUT"
        await workspace.requestClose(a.id)
        await workspace.requestClose(b.id)
        #expect(workspace.pendingClose == a.id)
        await workspace.resolveClose(.cancel)
        #expect(workspace.pendingClose == nil && workspace.tabs.count == 2)
    }

    @Test func parkingKeepsRunningSendCancelledButImportAlone() async throws {
        let client = FakeComposeClient()
        let workspace = makeWorkspace(client: client)
        let tab = workspace.open(ComposeDraft(method: "GET", url: "https://h/"))
        let sending = Task { await tab.send() }
        await client.waitForSends(1)
        let request = try #require(client.sent.first)
        await workspace.requestClose(tab.id)
        await workspace.resolveClose(.saveDraft)
        #expect(client.cancelled == [request.id])
        client.finish(request.id, with: ComposeOutcome(flowID: 1, failure: ComposeOutcomeFailure(code: "compose.cancelled", message: "x"), delivery: .unknown))
        await sending.value
        #expect(workspace.parked.count == 1)
    }

    @Test func saveDraftParksAndKeepsModelOpen() async {
        let files = FakeComposeBodyFiles()
        let workspace = makeWorkspace(files: files)
        let tab = workspace.newBlankTab()
        tab.draft.method = "POST"
        let content = tab.draft
        await workspace.requestClose(tab.id)
        await workspace.resolveClose(.saveDraft)
        #expect(workspace.tabs.isEmpty && workspace.pendingClose == nil)
        #expect(workspace.parked.count == 1 && workspace.parked[0].model === tab)
        #expect(files.discards.isEmpty)
        #expect(tab.draft == content)
    }

    @Test func discardClosesAndDiscardsFiles() async {
        let files = FakeComposeBodyFiles()
        let workspace = makeWorkspace(files: files)
        let tab = workspace.newBlankTab()
        await tab.attachFile(URL(fileURLWithPath: "/tmp/body.bin"))
        let asset = files.importedFiles[0].assetID
        await workspace.requestClose(tab.id)
        #expect(workspace.pendingClose == tab.id)
        await workspace.resolveClose(.discard)
        #expect(workspace.tabs.isEmpty && workspace.parked.isEmpty && workspace.pendingClose == nil)
        #expect(files.discards == [[asset]])
    }

    @Test func cancelKeepsTab() async {
        let workspace = makeWorkspace()
        let tab = workspace.newBlankTab()
        tab.draft.method = "PUT"
        await workspace.requestClose(tab.id)
        await workspace.resolveClose(.cancel)
        #expect(workspace.pendingClose == nil && workspace.tabs.map(\.id) == [tab.id] && workspace.parked.isEmpty)
    }

    @Test func reopenRestoresSameModel() async {
        let workspace = makeWorkspace()
        let tab = workspace.newBlankTab()
        tab.draft.method = "POST"
        await workspace.requestClose(tab.id)
        await workspace.resolveClose(.saveDraft)
        workspace.reopen(workspace.parked[0].id)
        #expect(workspace.parked.isEmpty && workspace.tabs.count == 1)
        #expect(workspace.tabs[0] === tab && workspace.selected === tab)
    }

    @Test func selectionMovesToNeighbourOnClose() async {
        let workspace = makeWorkspace()
        let a = workspace.newBlankTab()
        let b = workspace.newBlankTab()
        let c = workspace.newBlankTab()
        workspace.selectedID = b.id
        await workspace.requestClose(b.id)
        #expect(workspace.selectedID == c.id)
        await workspace.requestClose(c.id)
        #expect(workspace.selectedID == a.id)
        await workspace.requestClose(a.id)
        #expect(workspace.selectedID == nil)
    }

    @Test func closingUnselectedTabKeepsSelection() async {
        let workspace = makeWorkspace()
        let a = workspace.newBlankTab()
        let b = workspace.newBlankTab()
        await workspace.requestClose(a.id)
        #expect(workspace.selectedID == b.id)
    }

    @Test func parkedIsCappedAt20ClosingOldest() async {
        let files = FakeComposeBodyFiles()
        let workspace = makeWorkspace(files: files)
        var first: ComposeViewModel?
        for index in 0...20 {
            let tab = workspace.newBlankTab()
            if index == 0 {
                first = tab
                await tab.attachFile(URL(fileURLWithPath: "/tmp/old.bin"))
            } else {
                tab.draft.method = "POST"
            }
            await workspace.requestClose(tab.id)
            await workspace.resolveClose(.saveDraft)
        }
        #expect(workspace.parked.count == 20)
        #expect(!workspace.parked.contains { $0.model === first })
        #expect(files.discards.count == 1)
    }

    @Test func discardParkedClosesModel() async {
        let files = FakeComposeBodyFiles()
        let workspace = makeWorkspace(files: files)
        let tab = workspace.newBlankTab()
        await tab.attachFile(URL(fileURLWithPath: "/tmp/x.bin"))
        await workspace.requestClose(tab.id)
        await workspace.resolveClose(.saveDraft)
        await workspace.discardParked(workspace.parked[0].id)
        #expect(workspace.parked.isEmpty && files.discards.count == 1)
    }

    @Test func titleUsesMethodAndHost() {
        let workspace = makeWorkspace()
        let tab = workspace.open(ComposeDraft(method: "POST", url: "https://api.example.com:8443/v1?x=1"))
        #expect(ComposeWorkspaceModel.title(of: tab) == L10n.format("compose.tab.title", "POST", "api.example.com"))
        let blank = workspace.newBlankTab()
        #expect(ComposeWorkspaceModel.title(of: blank) == L10n.string("compose.page.untitled"))
    }
}
