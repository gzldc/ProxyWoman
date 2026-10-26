import Darwin
import FlowStore
import Foundation
import Localization
import os
import RulesEngine
import Testing
@testable import AppCore

// MARK: support

/// A counter shared with repository closures.
final class CallCounter: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: 0)
    var value: Int { state.withLock { $0 } }
    func increment() { state.withLock { $0 += 1 } }
}

/// Suspends callers until released; `arrived()` waits for the first caller. No sleeping.
actor Gate {
    private var isOpen = false
    private var arrivals = 0
    /// Callers let through before the gate starts holding (and counting) anyone.
    private var freePasses: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var watchers: [CheckedContinuation<Void, Never>] = []

    init(passFirst: Int = 0) {
        freePasses = passFirst
    }

    func pass() async {
        if freePasses > 0 {
            freePasses -= 1
            return
        }
        arrivals += 1
        for watcher in watchers { watcher.resume() }
        watchers.removeAll()
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func arrived() async {
        guard arrivals == 0 else { return }
        await withCheckedContinuation { watchers.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiting { waiter.resume() }
        waiting.removeAll()
    }
}

/// A fault switch read on the repository's file executor.
final class FaultSwitch: Sendable {
    private let state = OSAllocatedUnfairLock<RuleRepository.Stage?>(initialState: nil)
    func arm(_ stage: RuleRepository.Stage?) { state.withLock { $0 = stage } }
    func check(_ stage: RuleRepository.Stage) throws {
        if state.withLock({ $0 }) == stage { throw OwnedFileError(.ioFailure, errno: EIO) }
    }
}

/// One isolated repository + managed asset store in a temporary directory.
@Suite(.productionChinese) struct RulesFixture {
    let root: URL
    let budgets: OwnedFileBudgets
    let assets: ManagedAssetStore
    let repository: RuleRepository
    let fault = FaultSwitch()
    var configDir: URL { root.appendingPathComponent("config") }
    var configFile: URL { configDir.appendingPathComponent("rules.json") }
    var assetsDir: URL { root.appendingPathComponent("assets") }

    init(root: URL? = nil) {
        let root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("pw-rules-ui-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root
        let limits = RulesLimits()
        budgets = OwnedFileBudgets(limits: limits, freeDiskBytes: { _ in Int64.max / 2 })
        assets = ManagedAssetStore(directory: root.appendingPathComponent("assets"), limits: limits, budgets: budgets)
        let fault = self.fault
        repository = RuleRepository(
            directory: root.appendingPathComponent("config"), assets: assets, limits: limits, fault: { try fault.check($0) })
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func sourceFile(_ name: String, _ text: String = "local body") -> URL {
        let url = root.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8))
        return url
    }

    func assetFiles() -> Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: assetsDir.path)) ?? []).filter { $0.hasSuffix(".asset") })
    }

    /// The production client, optionally counting or gating calls.
    func client(
        loads: CallCounter? = nil, saves: CallCounter? = nil, loadGate: Gate? = nil, saveGate: Gate? = nil,
        importGate: Gate? = nil, importDoneGate: Gate? = nil
    ) -> RulesRepositoryClient {
        var client = RulesRepositoryClient.live(repository: repository, assets: assets)
        let load = client.load, save = client.save, importFile = client.importFile
        client.load = {
            loads?.increment()
            await loadGate?.pass()
            return try await load()
        }
        client.save = { groups, rules, revision in
            saves?.increment()
            await saveGate?.pass()
            return try await save(groups, rules, revision)
        }
        client.importFile = { url, name in
            await importGate?.pass()
            let asset = try await importFile(url, name)
            // Holds a finished copy back, as a slow completion delivered late would arrive.
            await importDoneGate?.pass()
            return asset
        }
        return client
    }
}

@MainActor
private func waitUntil(_ what: Comment, _ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else {
            Issue.record(what)
            return
        }
        await Task.yield()
    }
}

private func headerRule(_ name: String, order: Int = 0) -> Rule {
    Rule(id: UUID(), name: name, enabled: true, order: order, matcher: RuleMatcher(hostPattern: "\(name).test"),
         action: .editHeaders(direction: .request, operations: [.set(name: "X-Rule", value: name)]))
}

@MainActor
private func editDraft(_ model: RulesEditorModel, _ change: (inout RuleEditorDraft) -> Void) throws {
    var draft = try #require(model.draft)
    change(&draft)
    model.setDraft(draft)
}

// MARK: tests

@MainActor @Suite(.productionChinese, .timeLimit(.minutes(1))) struct RulesEditorModelTests {
    @Test func loadOnceAcrossConcurrentCallsAndWindowReopen() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        _ = try await fixture.repository.load()
        let seeded = try await fixture.repository.save(groups: [], rules: [headerRule("seed")], expectedRevision: 0)

        let restarted = RulesFixture(root: fixture.root)
        let loads = CallCounter(), gate = Gate()
        let model = RulesEditorModel(client: restarted.client(loads: loads, loadGate: gate), limits: RulesLimits())
        async let first: Void = model.load()
        async let second: Void = model.load()
        await gate.arrived()
        #expect(model.loadState == .loading)
        await gate.open()
        _ = await (first, second)
        #expect(loads.value == 1)
        #expect(model.loadState == .loaded)
        #expect(model.rules == seeded.rules && model.revision == seeded.revision)

        // Closing and reopening the window reuses the model: nothing is read again.
        await model.load()
        #expect(loads.value == 1)
        #expect(restarted.repository.provider.current() == seeded)
    }

    @Test func addValidRulePersistsAndPublishes() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let saves = CallCounter()
        let model = RulesEditorModel(client: fixture.client(saves: saves), limits: RulesLimits())
        await model.load()
        model.beginDraft(kind: .editHeaders)
        let id = try #require(model.draft?.id)
        #expect(model.selection == id && model.isDraftNew)
        try editDraft(model) {
            $0.name = "Debug header"
            $0.match.host = "api.test"
            $0.headerOperations = [HeaderOperationRow(kind: .append, name: "X-Debug", value: "1")]
        }
        #expect(await model.save())

        let expected = Rule(id: id, name: "Debug header", enabled: true, order: 0, matcher: RuleMatcher(hostPattern: "api.test"),
                            action: .editHeaders(direction: .request, operations: [.append(name: "X-Debug", value: "1")]))
        #expect(saves.value == 1)
        #expect(fixture.repository.provider.current() == RuleSnapshot(revision: 1, rules: [expected]))
        #expect(model.rules == [expected] && model.revision == 1)
        #expect(!model.isDraftDirty && !model.isDraftNew && model.selection == id)
        #expect(try await RulesFixture(root: fixture.root).repository.load() == RuleSnapshot(revision: 1, rules: [expected]))
    }

    @Test func invalidDraftIsNotSavedAndMarksTheField() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let saves = CallCounter()
        let model = RulesEditorModel(client: fixture.client(saves: saves), limits: RulesLimits())
        await model.load()
        model.beginDraft(kind: .mapRemote)
        try editDraft(model) { $0.mapRemote.targetHost = "not a host" }
        #expect(await model.save() == false)
        #expect(model.issues == [.targetHost: .invalidTargetHost])
        #expect(saves.value == 0)
        #expect(fixture.repository.provider.current().revision == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.configFile.path))
        #expect(model.draft?.mapRemote.targetHost == "not a host")

        // Fixing the field clears its error before the next save attempt.
        try editDraft(model) { $0.mapRemote.targetHost = "fixed.test" }
        #expect(model.issues.isEmpty)
        #expect(await model.save())
        #expect(fixture.repository.provider.current().revision == 1)
    }

    @Test func saveFailureKeepsTheCommittedSnapshotAndTheDirtyDraftWithItsImport() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let model = RulesEditorModel(client: fixture.client(), limits: RulesLimits())
        await model.load()
        model.beginDraft(kind: .editHeaders)
        try editDraft(model) { $0.match.host = "first.test" }
        #expect(await model.save())
        let committed = fixture.repository.provider.current()

        model.beginDraft(kind: .mapLocal)
        await model.importAsset(from: fixture.sourceFile("page.html", "<p>hi</p>"))
        let asset = try #require(model.draft?.mapLocal.asset)
        #expect(asset.displayName == "page.html" && asset.size == 9)
        #expect(model.draft?.mapLocal.headers == [HeaderFieldRow(id: try #require(model.draft?.mapLocal.headers.first?.id),
                                                                name: "Content-Type", value: "text/html")])
        try editDraft(model) { $0.mapLocal.status = "203" }
        let dirty = try #require(model.draft)

        fixture.fault.arm(.write)
        #expect(await model.save() == false)
        #expect(model.error == .storage(.ioFailure))
        #expect(model.rules == committed.rules && model.revision == committed.revision)
        #expect(fixture.repository.provider.current() == committed)
        #expect(model.draft == dirty && model.isDraftDirty)
        #expect(fixture.assetFiles() == [asset.id.uuidString + ".asset"])

        fixture.fault.arm(nil)
        #expect(await model.save())
        #expect(model.error == nil)
        let published = fixture.repository.provider.current()
        #expect(published.revision == committed.revision + 1)
        #expect(published.rules.last?.action == .mapLocal(MapLocalAction(
            assetID: asset.id, status: 203, headers: [HeaderField(name: "Content-Type", value: "text/html")])))
        #expect(model.reusableAssets == [asset])
    }

    @Test func moveReordersPublishesAndKeepsEveryIdentity() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        _ = try await fixture.repository.load()
        let a = headerRule("a", order: 0), b = headerRule("b", order: 1), c = headerRule("c", order: 2)
        _ = try await fixture.repository.save(groups: [], rules: [a, b, c], expectedRevision: 0)
        let restarted = RulesFixture(root: fixture.root)
        let saves = CallCounter()
        let model = RulesEditorModel(client: restarted.client(saves: saves), limits: RulesLimits())
        await model.load()

        #expect(await model.move(fromOffsets: IndexSet(integer: 2), toOffset: 0))
        let published = restarted.repository.provider.current()
        #expect(published.revision == 2)
        #expect(published.rules.map(\.id) == [c.id, a.id, b.id])
        #expect(published.rules.map(\.order) == [0, 1, 2])
        #expect(published.rules.map(\.name) == ["c", "a", "b"])
        #expect(model.rules == published.rules)

        #expect(await model.reorder(ids: [b.id, c.id, a.id]))
        #expect(restarted.repository.provider.current().rules.map(\.id) == [b.id, c.id, a.id])
        // An ID list that is not a permutation of the saved rules is refused without saving.
        #expect(await model.reorder(ids: [b.id, c.id]) == false)
        #expect(saves.value == 2)
    }

    @Test func corruptStoreShowsResetAndResetBacksUp() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.configDir, withIntermediateDirectories: true)
        let corrupt = Data("{\"schemaVersion\":1,\"rules\":[}".utf8)
        FileManager.default.createFile(atPath: fixture.configFile.path, contents: corrupt)
        let saves = CallCounter()
        let model = RulesEditorModel(client: fixture.client(saves: saves), limits: RulesLimits())
        await model.load()
        #expect(model.loadState == .unavailable(.corrupt))
        #expect(!model.canMutate)

        // Every other operation is refused while the banner is shown.
        model.beginDraft(kind: .breakpoint)
        #expect(model.draft == nil)
        #expect(await model.reorder(ids: []) == false)
        #expect(saves.value == 0)
        #expect(try Data(contentsOf: fixture.configFile) == corrupt)

        #expect(await model.resetUnavailableConfiguration())
        #expect(model.loadState == .loaded && model.canMutate)
        let backup = try #require(model.lastBackupName)
        #expect(try Data(contentsOf: fixture.configDir.appendingPathComponent(backup)) == corrupt)
        #expect(fixture.repository.provider.current() == RuleSnapshot(revision: 1, rules: []))
        #expect(model.revision == 1 && model.rules.isEmpty)

        model.beginDraft(kind: .breakpoint)
        #expect(await model.save())
        #expect(fixture.repository.provider.current().revision == 2)
    }

    @Test func duplicateToggleAndDeleteEachPublishTheNextRevision() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        _ = try await fixture.repository.load()
        let a = headerRule("a"), z = headerRule("z", order: 1)
        _ = try await fixture.repository.save(groups: [], rules: [a, z], expectedRevision: 0)
        let restarted = RulesFixture(root: fixture.root)
        let model = RulesEditorModel(client: restarted.client(), limits: RulesLimits())
        await model.load()

        // ⌘D makes an unsaved copy with a new identity, inserted after its original once saved.
        model.duplicate(id: a.id)
        let copyID = try #require(model.draft?.id)
        #expect(copyID != a.id && model.isDraftNew && model.selection == copyID)
        #expect(restarted.repository.provider.current().revision == 1)
        #expect(await model.save())
        var published = restarted.repository.provider.current()
        #expect(published.rules.map(\.id) == [a.id, copyID, z.id])
        #expect(published.rules[1].matcher == a.matcher && published.rules[1].action == a.action && published.rules[1].name == a.name)

        #expect(await model.setEnabled(id: copyID, enabled: false))
        published = restarted.repository.provider.current()
        #expect(published.revision == 3 && published.rules[1].enabled == false)
        #expect(model.draft?.enabled == false && !model.isDraftDirty)

        #expect(await model.delete(id: copyID))
        published = restarted.repository.provider.current()
        #expect(published.revision == 4 && published.rules.map(\.id) == [a.id, z.id])
        #expect(model.selection == nil && model.draft == nil)
    }

    @Test func annotationRuleCanBeEditedDuplicatedAndSaved() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        _ = try await fixture.repository.load()
        let groupID = UUID()
        var mark = Rule(
            id: UUID(), name: "m", enabled: true, order: 0, matcher: RuleMatcher(hostPattern: "m.test"),
            annotation: .mark(MarkAction(background: "#FF3B30")))
        mark.groupID = groupID
        mark.note = "keep me"
        let tail = headerRule("z", order: 1)
        _ = try await fixture.repository.save(
            groups: [RuleGroup(id: groupID, name: "g")], rules: [mark, tail], expectedRevision: 0)
        let restarted = RulesFixture(root: fixture.root)
        let model = RulesEditorModel(client: restarted.client(), limits: RulesLimits())
        await model.load()

        #expect(!model.isReadOnly(mark.id))
        model.requestSelection(mark.id)
        #expect(model.draft?.kind == .mark && model.draft?.readOnlyReason == nil)
        try editDraft(model) { $0.mark.background = "#007AFF"; $0.mark.text = "t" }
        #expect(await model.save())
        let saved = try #require(restarted.repository.provider.current().rules.first { $0.id == mark.id })
        #expect(saved.actions == [RuleAction(.mark(MarkAction(background: "#007AFF", text: "t")))])
        #expect(saved.groupID == groupID && saved.note == "keep me" && saved.order == mark.order)

        model.duplicate(id: mark.id)
        let copyID = try #require(model.draft?.id)
        #expect(copyID != mark.id && model.draft?.kind == .mark && model.isDraftNew)
        #expect(await model.save())
        #expect(restarted.repository.provider.current().rules.contains { $0.id == copyID && $0.simpleAnnotation != nil })
    }

    @Test func savingAnAnnotationDraftOverARuleThatBecameMultiActionIsAConflict() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        _ = try await fixture.repository.load()
        let hide = Rule(
            id: UUID(), name: "h", enabled: true, order: 0, matcher: RuleMatcher(hostPattern: "h.test"), annotation: .hide)
        _ = try await fixture.repository.save(groups: [], rules: [hide], expectedRevision: 0)
        let window = RulesEditorModel(client: fixture.client(), limits: RulesLimits())
        await window.load()
        window.requestSelection(hide.id)
        try editDraft(window) { $0.name = "renamed" }

        // Meanwhile another window gives the rule a second action.
        var several = hide
        several.actions.append(RuleAction(.comment(CommentAction(text: "x"))))
        _ = try await fixture.repository.save(groups: [], rules: [several], expectedRevision: 1)
        #expect(await window.save() == false && window.error == .conflict)
        window.rebaseOnLatest()
        #expect(window.isReadOnly(hide.id))
        #expect(await window.save() == false && window.error == .conflict)
        #expect(fixture.repository.provider.current().rules == [several])
    }

    @Test func staleRevisionIsAConflictNeverASilentOverwrite() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let savesB = CallCounter()
        let windowA = RulesEditorModel(client: fixture.client(), limits: RulesLimits())
        let windowB = RulesEditorModel(client: fixture.client(saves: savesB), limits: RulesLimits())
        await windowA.load()
        await windowB.load()

        windowA.beginDraft(kind: .breakpoint)
        #expect(await windowA.save())
        let winner = fixture.repository.provider.current()

        windowB.beginDraft(kind: .editHeaders)
        try editDraft(windowB) { $0.match.host = "b.test" }
        let dirty = try #require(windowB.draft)
        #expect(await windowB.save() == false)
        #expect(windowB.error == .conflict && windowB.conflict == winner)
        #expect(fixture.repository.provider.current() == winner)
        #expect(windowB.draft == dirty && windowB.rules.isEmpty)
        // No retry until the user chooses: every save path stays closed.
        #expect(await windowB.save() == false)
        #expect(await windowB.reorder(ids: []) == false)
        #expect(savesB.value == 1)

        windowB.rebaseOnLatest()
        #expect(windowB.conflict == nil && windowB.rules == winner.rules && windowB.draft == dirty)
        #expect(await windowB.save())
        let merged = fixture.repository.provider.current()
        #expect(merged.revision == winner.revision + 1)
        #expect(merged.rules.map(\.id) == winner.rules.map(\.id) + [dirty.id])
    }

    @Test func overlappingMutationsAreRejectedWhileOneIsInFlight() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        _ = try await fixture.repository.load()
        let a = headerRule("a")
        _ = try await fixture.repository.save(groups: [], rules: [a], expectedRevision: 0)
        let restarted = RulesFixture(root: fixture.root)
        let saves = CallCounter(), gate = Gate()
        let model = RulesEditorModel(client: restarted.client(saves: saves, saveGate: gate), limits: RulesLimits())
        await model.load()

        async let toggled = model.setEnabled(id: a.id, enabled: false)
        await gate.arrived()
        #expect(model.isBusy && !model.canMutate)
        #expect(await model.delete(id: a.id) == false)
        model.beginDraft(kind: .breakpoint)
        #expect(model.draft == nil)
        await gate.open()
        #expect(await toggled)
        #expect(!model.isBusy)
        #expect(saves.value == 1)
        #expect(restarted.repository.provider.current().rules.map(\.enabled) == [false])
    }

    @Test func breakpointRulesStayDisabledUntilLiveBreakpointsExist() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let saves = CallCounter()
        let model = RulesEditorModel(client: fixture.client(saves: saves), limits: RulesLimits(), liveBreakpoints: false)
        await model.load()
        model.beginDraft(kind: .breakpoint)
        try editDraft(model) { $0.enabled = true }
        #expect(await model.save())
        let rule = try #require(fixture.repository.provider.current().rules.first)
        #expect(rule.action == .breakpoint(direction: .request, mode: .headers))
        #expect(rule.enabled == false)
        #expect(model.draft?.enabled == false && !model.isDraftDirty)

        #expect(await model.setEnabled(id: rule.id, enabled: true) == false)
        #expect(model.error == .breakpointsUnavailable)
        #expect(saves.value == 1)
        #expect(fixture.repository.provider.current().rules.first?.enabled == false)
    }

    @Test func liveBreakpointRulesCanBeEnabledAndPublish() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let model = RulesEditorModel(client: fixture.client(), limits: RulesLimits(), liveBreakpoints: true)
        await model.load()
        model.beginDraft(kind: .breakpoint)
        #expect(model.draft?.enabled == true)
        #expect(!model.showsSavedDisabledBreakpointNotice)
        #expect(await model.save())
        let rule = try #require(fixture.repository.provider.current().rules.first)
        #expect(rule.enabled && rule.action == .breakpoint(direction: .request, mode: .headers))

        #expect(await model.setEnabled(id: rule.id, enabled: false))
        #expect(fixture.repository.provider.current().rules.first?.enabled == false)
        #expect(await model.setEnabled(id: rule.id, enabled: true))
        #expect(fixture.repository.provider.current().rules.first?.enabled == true)
        #expect(model.error == nil)
    }

    @Test func breakpointRulesSavedBeforeLiveBreakpointsShowAnEnableNotice() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        // Saved by a build without the breakpoint window: stored turned off.
        let earlier = RulesEditorModel(client: fixture.client(), limits: RulesLimits(), liveBreakpoints: false)
        await earlier.load()
        earlier.beginDraft(kind: .breakpoint)
        #expect(await earlier.save())
        let id = try #require(earlier.rules.first?.id)

        let restarted = RulesFixture(root: fixture.root)
        let model = RulesEditorModel(client: restarted.client(), limits: RulesLimits(), liveBreakpoints: true)
        await model.load()
        #expect(model.rules.first?.enabled == false)
        model.requestSelection(id)
        #expect(model.showsSavedDisabledBreakpointNotice)
        #expect(await model.setEnabled(id: id, enabled: true))
        #expect(!model.showsSavedDisabledBreakpointNotice)
        #expect(restarted.repository.provider.current().rules.first?.enabled == true)
    }

    @Test func navigatingAwayFromADirtyDraftAsksFirstAndNeverOverwritesIt() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        _ = try await fixture.repository.load()
        let a = headerRule("a"), b = headerRule("b", order: 1)
        _ = try await fixture.repository.save(groups: [], rules: [a, b], expectedRevision: 0)
        let restarted = RulesFixture(root: fixture.root)
        let model = RulesEditorModel(client: restarted.client(), limits: RulesLimits())
        await model.load()

        model.requestSelection(a.id)
        #expect(model.selection == a.id && !model.isDraftDirty)
        try editDraft(model) { $0.name = "edited" }
        model.requestSelection(b.id)
        #expect(model.pendingNavigation == .select(b.id))
        #expect(model.selection == a.id && model.draft?.name == "edited")
        model.cancelPendingNavigation()
        #expect(model.pendingNavigation == nil && model.draft?.name == "edited")

        let flow = Flow(id: 3, scheme: "https", method: "GET", host: "c.test", port: 443, path: "/c?x=1")
        model.beginDraft(from: flow, kind: .mapRemote)
        #expect(model.selection == a.id && model.draft?.name == "edited")
        guard case .draft(let pending) = model.pendingNavigation else { Issue.record("no pending draft"); return }
        #expect(pending.kind == .mapRemote)
        model.confirmPendingNavigation()
        #expect(model.selection == pending.id && model.draft == pending && model.isDraftNew)
        // An unsaved flow draft publishes nothing.
        #expect(restarted.repository.provider.current().revision == 1)
        #expect(model.rules.map(\.name) == ["a", "b"])
    }

    // MARK: Map Local imports (T9a-GPT-R35)

    @Test func replacedAndCancelledImportsAreDiscardedButReferencedAssetsAreKept() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let model = RulesEditorModel(client: fixture.client(), limits: RulesLimits())
        await model.load()
        model.beginDraft(kind: .mapLocal)
        await model.importAsset(from: fixture.sourceFile("one.json", "{}"))
        let first = try #require(model.draft?.mapLocal.asset)
        await model.importAsset(from: fixture.sourceFile("two.json", "[]"))
        let second = try #require(model.draft?.mapLocal.asset)
        try await waitUntil("replaced import discarded") { fixture.assetFiles() == [second.id.uuidString + ".asset"] }
        #expect(await fixture.assets.asset(first.id) == nil)

        #expect(await model.save())
        let saved = try #require(model.draft?.id)
        // Reusing the saved asset in a new draft and discarding that draft keeps the asset.
        model.beginDraft(kind: .mapLocal)
        model.useAsset(second)
        model.discardChanges()
        #expect(model.selection == nil)
        let lease = try await fixture.assets.lease(second.id)
        lease.cancel()
        #expect(fixture.assetFiles() == [second.id.uuidString + ".asset"])

        // A new import that is abandoned with its unsaved draft is removed.
        model.requestSelection(saved)
        #expect(model.draft?.mapLocal.asset == second)
        await model.importAsset(from: fixture.sourceFile("three.txt"))
        let third = try #require(model.draft?.mapLocal.asset)
        model.discardChanges()
        try await waitUntil("abandoned import discarded") { fixture.assetFiles() == [second.id.uuidString + ".asset"] }
        #expect(await fixture.assets.asset(third.id) == nil)
        #expect(model.draft?.mapLocal.asset == second)
    }

    @Test func lateImportCompletionForAnAbandonedDraftIsDiscarded() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let gate = Gate()
        let model = RulesEditorModel(client: fixture.client(importDoneGate: gate), limits: RulesLimits())
        await model.load()
        model.beginDraft(kind: .mapLocal)
        let source = fixture.sourceFile("late.bin")
        let importing = Task { await model.importAsset(from: source) }
        await gate.arrived()
        #expect(model.importState == .importing)
        #expect(fixture.assetFiles().count == 1)  // the copy itself already finished

        model.requestSelection(nil)
        model.confirmPendingNavigation()
        #expect(model.draft == nil && model.importState == .idle)
        model.beginDraft(kind: .mapLocal)
        let other = try #require(model.draft)
        await gate.open()
        await importing.value
        #expect(model.draft == other)
        try await waitUntil("late import discarded") { fixture.assetFiles().isEmpty }
    }

    @Test func cancelledImportLeavesNoCopyAndNoAsset() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let gate = Gate()
        let model = RulesEditorModel(client: fixture.client(importGate: gate), limits: RulesLimits())
        await model.load()
        model.beginDraft(kind: .mapLocal)
        let importing = Task { await model.importAsset(from: fixture.sourceFile("big.bin", String(repeating: "x", count: 200_000))) }
        await gate.arrived()
        model.cancelImport()
        #expect(model.importState == .idle)
        await gate.open()
        await importing.value
        #expect(model.draft?.mapLocal.asset == nil && model.importState == .idle && model.error == nil)
        try await waitUntil("no managed copy") { fixture.assetFiles().isEmpty }
        #expect(fixture.budgets.snapshot().bytes[.asset, default: 0] == 0)
    }

    @Test func failedImportIsReportedOnTheDraftThatStartedIt() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let model = RulesEditorModel(client: fixture.client(), limits: RulesLimits())
        await model.load()
        model.beginDraft(kind: .mapLocal)
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        await model.importAsset(from: fixture.root.appendingPathComponent("folder"))
        #expect(model.importState == .failed(.importFailed(.notRegularFile)))
        #expect(model.draft?.mapLocal.asset == nil)
    }

    // MARK: imports and saves never overlap (review fix I-1, R33)

    @Test func saveIsRefusedWhileAnImportRunsAndAnImportIsRefusedWhileASaveRuns() async throws {
        // Order 1: the import is running when Save is pressed.
        let fixture = RulesFixture(); defer { fixture.remove() }
        // The review's case: file A is chosen and valid, file B is still being copied.
        let saves = CallCounter(), importGate = Gate(passFirst: 1)
        let model = RulesEditorModel(client: fixture.client(saves: saves, importGate: importGate), limits: RulesLimits())
        await model.load()
        model.beginDraft(kind: .mapLocal)
        await model.importAsset(from: fixture.sourceFile("before.txt"))
        let before = try #require(model.draft?.mapLocal.asset)
        let importing = Task { await model.importAsset(from: fixture.sourceFile("first.txt")) }
        await importGate.arrived()
        #expect(model.importState == .importing && !model.canSave && model.canMutate)
        #expect(await model.save() == false)
        #expect(saves.value == 0 && fixture.repository.provider.current().revision == 0)
        #expect(model.draft?.mapLocal.asset == before)
        await importGate.open()
        await importing.value
        let first = try #require(model.draft?.mapLocal.asset)
        #expect(first != before && model.canSave)
        #expect(await model.save())
        #expect(saves.value == 1)
        #expect(fixture.repository.provider.current().rules.first?.action
            == .mapLocal(MapLocalAction(assetID: first.id, headers: [HeaderField(name: "Content-Type", value: "text/plain")])))

        // Order 2: the save is running when a file is picked.
        let second = RulesFixture(); defer { second.remove() }
        let saveGate = Gate()
        let other = RulesEditorModel(client: second.client(saveGate: saveGate), limits: RulesLimits())
        await other.load()
        other.beginDraft(kind: .mapLocal)
        await other.importAsset(from: second.sourceFile("kept.txt"))
        let kept = try #require(other.draft?.mapLocal.asset)
        async let saved = other.save()
        await saveGate.arrived()
        await other.importAsset(from: second.sourceFile("ignored.txt"))
        #expect(other.draft?.mapLocal.asset == kept && other.importState == .idle)
        await saveGate.open()
        #expect(await saved)
        #expect(second.repository.provider.current().rules.first?.action
            == .mapLocal(MapLocalAction(assetID: kept.id, headers: [HeaderField(name: "Content-Type", value: "text/plain")])))
        #expect(second.assetFiles() == [kept.id.uuidString + ".asset"])
        #expect(other.draft?.mapLocal.asset == kept && !other.isDraftDirty)
        #expect(fixture.assetFiles() == [first.id.uuidString + ".asset"])
    }

    @Test func importFinishingDuringAnotherMutationWaitsAndReleasesNothingTheTransactionCouldUse() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        _ = try await fixture.repository.load()
        let a = headerRule("a")
        _ = try await fixture.repository.save(groups: [], rules: [a], expectedRevision: 0)
        let restarted = RulesFixture(root: fixture.root)
        let saveGate = Gate(), importDone = Gate(passFirst: 1), deferred = Gate()
        let model = RulesEditorModel(
            client: restarted.client(saveGate: saveGate, importDoneGate: importDone), limits: RulesLimits())
        await model.load()
        model.beginDraft(kind: .mapLocal)
        await model.importAsset(from: restarted.sourceFile("old.json", "{}"))
        let old = try #require(model.draft?.mapLocal.asset)

        let replacing = Task { await model.importAsset(from: restarted.sourceFile("new.json", "[]")) }
        await importDone.arrived()  // the new copy exists, its result is held back
        async let toggled = model.setEnabled(id: a.id, enabled: false)
        await saveGate.arrived()  // a repository transaction is in flight
        await deferred.open()
        model.importDeferredHook = { Task { await deferred.pass() } }
        await importDone.open()
        await deferred.arrived()  // the import result reached the model while it was busy

        // Nothing changed under the running transaction: same draft, old asset still owned.
        #expect(model.isBusy && model.draft?.mapLocal.asset == old && model.importState == .importing)
        #expect(await restarted.assets.asset(old.id) == old)

        await saveGate.open()
        #expect(await toggled)
        await replacing.value
        let new = try #require(model.draft?.mapLocal.asset)
        #expect(new != old && model.importState == .idle)
        #expect(restarted.repository.provider.current().rules.map(\.enabled) == [false])
        // Only now is the replaced, never-saved copy released.
        #expect(await restarted.assets.asset(old.id) == nil)
        #expect(restarted.assetFiles() == [new.id.uuidString + ".asset"])
        #expect(await model.save())
        #expect(restarted.repository.provider.current().rules.last?.action
            == .mapLocal(MapLocalAction(assetID: new.id, headers: [HeaderField(name: "Content-Type", value: "application/json")])))
    }

    @Test func suggestedContentTypeFollowsANewFileUntilTheUserEditsIt() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let model = RulesEditorModel(client: fixture.client(), limits: RulesLimits())
        await model.load()
        model.beginDraft(kind: .mapLocal)
        await model.importAsset(from: fixture.sourceFile("page.html"))
        #expect(model.draft?.mapLocal.headers.map(\.value) == ["text/html"])
        await model.importAsset(from: fixture.sourceFile("data.json"))
        #expect(model.draft?.mapLocal.headers.map(\.value) == ["application/json"])
        try editDraft(model) { $0.mapLocal.headers[0].value = "text/plain; charset=utf-8" }
        await model.importAsset(from: fixture.sourceFile("other.html"))
        #expect(model.draft?.mapLocal.headers.map(\.value) == ["text/plain; charset=utf-8"])
    }

    @Test func securityScopeIsBalancedAcrossTheWholeAwaitedCopy() async throws {
        let events = OSAllocatedUnfairLock<[String]>(initialState: [])
        func access(starts: Bool) -> ScopedFileAccess {
            ScopedFileAccess(
                start: { url in events.withLock { $0.append("start " + url.lastPathComponent) }; return starts },
                stop: { url in events.withLock { $0.append("stop " + url.lastPathComponent) } })
        }
        let url = URL(fileURLWithPath: "/synthetic/picked.bin")
        let gate = Gate()
        let copy = Task { try await access(starts: true).withAccess(to: url) { await gate.pass(); events.withLock { $0.append("copied") } } }
        await gate.arrived()
        #expect(events.withLock { $0 } == ["start picked.bin"])
        await gate.open()
        try await copy.value
        #expect(events.withLock { $0 } == ["start picked.bin", "copied", "stop picked.bin"])

        // Outside the sandbox `start` returns false: the copy still runs and nothing is stopped.
        events.withLock { $0 = [] }
        try await access(starts: false).withAccess(to: url) { events.withLock { $0.append("copied") } }
        #expect(events.withLock { $0 } == ["start picked.bin", "copied"])

        // A failing copy still releases the scope it took.
        events.withLock { $0 = [] }
        await #expect(throws: OwnedFileError(.ioFailure)) {
            try await access(starts: true).withAccess(to: url) { throw OwnedFileError(.ioFailure) }
        }
        #expect(events.withLock { $0 } == ["start picked.bin", "stop picked.bin"])

        // The model takes and releases the scope around its import.
        let fixture = RulesFixture(); defer { fixture.remove() }
        events.withLock { $0 = [] }
        let model = RulesEditorModel(client: fixture.client(), limits: RulesLimits(), fileAccess: access(starts: true))
        await model.load()
        model.beginDraft(kind: .mapLocal)
        await model.importAsset(from: fixture.sourceFile("scoped.txt"))
        #expect(model.draft?.mapLocal.asset != nil)
        #expect(events.withLock { $0 } == ["start scoped.txt", "stop scoped.txt"])
    }

    // MARK: Map Local directory (P2 task 8)

    private struct BookmarkFailure: Error {}

    /// Records `start`/`stop` of the file scope and what the bookmark facade saw in between.
    private final class ScopeLog: Sendable {
        let events = OSAllocatedUnfairLock<[String]>(initialState: [])
        func add(_ event: String) { events.withLock { $0.append(event) } }
        var value: [String] { events.withLock { $0 } }
        var access: ScopedFileAccess {
            ScopedFileAccess(
                start: { [self] url in add("start " + url.lastPathComponent); return true },
                stop: { [self] url in add("stop " + url.lastPathComponent) })
        }
    }

    @Test func chooseDirectoryUsesFakeBookmarkingAndStoresNoPath() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let picked = fixture.root.appendingPathComponent("my-site-build")
        try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
        let bytes = Data([0xB0, 0x0C, 0x4A, 0x11])
        let made = OSAllocatedUnfairLock<[URL]>(initialState: [])
        let model = RulesEditorModel(
            client: fixture.client(), limits: RulesLimits(),
            directoryBookmarking: DirectoryBookmarking(make: { url in made.withLock { $0.append(url) }; return bytes }))
        await model.load()
        model.beginDraft(kind: .mapLocalDirectory)
        try editDraft(model) { $0.match.host = "app.test"; $0.match.path = "/static/" }
        await model.chooseDirectory(picked, access: ScopeLog().access)
        #expect(made.withLock { $0 } == [picked])
        #expect(model.draft?.mapLocalDirectory.bookmark == bytes)
        #expect(model.draft?.mapLocalDirectory.displayName == "my-site-build")
        #expect(model.error == nil)

        #expect(await model.save())
        let saved = try #require(model.rules.last)
        guard case .mapLocalDirectory(let action) = saved.action else { Issue.record("wrong action"); return }
        #expect(action.bookmark == bytes && action.displayName == "my-site-build")
        // The path string is nowhere: not in the draft, the rule, or the stored file.
        #expect(!String(describing: model.draft as Any).contains(picked.path))
        #expect(!String(describing: saved).contains(picked.path))
        let stored = try Data(contentsOf: fixture.configFile)
        #expect(stored.range(of: Data(picked.path.utf8)) == nil)
        #expect(stored.range(of: Data(fixture.root.path.utf8)) == nil)
        #expect(!model.isDraftDirty)
    }

    @Test func chooseDirectoryFailureShowsLocalizedError() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let model = RulesEditorModel(
            client: fixture.client(), limits: RulesLimits(),
            directoryBookmarking: DirectoryBookmarking(make: { _ in throw BookmarkFailure() }))
        await model.load()
        model.beginDraft(kind: .mapLocalDirectory)
        let before = try #require(model.draft)
        let log = ScopeLog()
        await model.chooseDirectory(URL(fileURLWithPath: "/synthetic/gone"), access: log.access)
        #expect(model.error == .directoryFailed)
        #expect(model.draft == before)
        #expect(log.value == ["start gone", "stop gone"])
        let localizer = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        #expect(model.error?.message(localizer: localizer) == localizer.string("rules.error.directory"))
        #expect(RulesEditorError.directoryFailed.localizationKey == "rules.error.directory")
        model.dismissError()
        #expect(model.error == nil)
    }

    /// Rules 2.0 R1 Task 7: a failed schema 4 migration has its own sentence (no reset is offered for it).
    @Test func rulesEditorErrorMapsMigrationFailedToItsKey() {
        let error = RulesEditorError(RuleRepositoryError.unavailable(.migrationFailed))
        #expect(error == .unavailable(.migrationFailed))
        #expect(error.localizationKey == "rules.error.unavailable.migrationFailed")
        let localizer = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        #expect(error.message(localizer: localizer)
            == "旧规则文件无法迁移到规则 2.0（备份或写入失败）。原文件没有改动，规则已暂停；请检查磁盘空间后重试迁移。")
    }

    @Test func chooseDirectoryRunsInsideScopedAccess() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let log = ScopeLog()
        let model = RulesEditorModel(
            client: fixture.client(), limits: RulesLimits(),
            directoryBookmarking: DirectoryBookmarking(make: { url in log.add("make " + url.lastPathComponent); return Data([7]) }))
        await model.load()
        model.beginDraft(kind: .mapLocalDirectory)
        await model.chooseDirectory(URL(fileURLWithPath: "/synthetic/site"), access: log.access)
        #expect(log.value == ["start site", "make site", "stop site"])
        #expect(model.draft?.mapLocalDirectory.bookmark == Data([7]))
    }

    @Test func chooseDirectoryWithoutADraftIsIgnored() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let model = RulesEditorModel(
            client: fixture.client(), limits: RulesLimits(),
            directoryBookmarking: DirectoryBookmarking(make: { _ in Data([1]) }))
        await model.load()
        // Without a draft there is nothing to attach the directory to.
        await model.chooseDirectory(URL(fileURLWithPath: "/synthetic/a"), access: ScopeLog().access)
        #expect(model.draft == nil && model.error == nil)
    }

    @Test func discardingDraftLeavesNoAssetBehind() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let model = RulesEditorModel(
            client: fixture.client(), limits: RulesLimits(),
            directoryBookmarking: DirectoryBookmarking(make: { _ in Data([1, 2]) }))
        await model.load()
        model.beginDraft(kind: .mapLocalDirectory)
        await model.chooseDirectory(URL(fileURLWithPath: "/synthetic/dist"), access: ScopeLog().access)
        #expect(model.isDraftDirty && model.importState == .idle)
        model.discardChanges()
        #expect(model.draft == nil)
        #expect(fixture.assetFiles().isEmpty)

        // A saved directory rule references no managed asset either.
        model.beginDraft(kind: .mapLocalDirectory)
        try editDraft(model) { $0.match.path = "/s/" }
        await model.chooseDirectory(URL(fileURLWithPath: "/synthetic/dist"), access: ScopeLog().access)
        #expect(await model.save())
        #expect(fixture.assetFiles().isEmpty && model.reusableAssets.isEmpty)
        model.requestSelection(nil)
        model.requestSelection(model.rules.first?.id)
        #expect(model.draft?.kind == .mapLocalDirectory && !model.isDraftDirty)
        #expect(model.draft?.mapLocalDirectory.displayName == "dist")
    }
}
