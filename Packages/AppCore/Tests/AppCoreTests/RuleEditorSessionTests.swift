import FlowStore
import Foundation
import RulesEngine
import Testing

@testable import AppCore

private func marked(_ name: String, group: UUID? = nil, order: Int = 0, enabled: Bool = true) -> Rule {
    Rule(
        name: name, enabled: enabled, groupID: group, order: order,
        conditions: ConditionGroup(rows: [ConditionRow(field: .host, op: .equals, value: "\(name).test")]),
        actions: [RuleAction(.mark(MarkAction(background: "#AABBCC")))])
}

@MainActor
private func loaded(
    _ fixture: RulesFixture, groups: [RuleGroup] = [], rules: [Rule] = [], saves: CallCounter? = nil, saveGate: Gate? = nil,
    limits: RulesLimits = RulesLimits(), liveBreakpoints: Bool = false,
    bookmarking: DirectoryBookmarking = DirectoryBookmarking(make: { _ in Data([7]) })
) async throws -> RulesEditorModel {
    _ = try await fixture.repository.load()
    _ = try await fixture.repository.save(groups: groups, rules: rules, expectedRevision: 0)
    let model = RulesEditorModel(
        client: fixture.client(saves: saves, saveGate: saveGate), limits: limits, liveBreakpoints: liveBreakpoints,
        directoryBookmarking: bookmarking)
    await model.load()
    return model
}

/// Adds a complete mark card and a name, which is a document that saves.
@MainActor
private func fill(_ session: RuleEditorSession, name: String = "new") {
    session.update {
        $0.name = name
        $0.conditions = ConditionsDraft(group: ConditionGroup(rows: [ConditionRow(field: .host, op: .equals, value: "a.test")]))
        $0.actions = []
        $0.addAction(.mark)
    }
}

@MainActor @Suite(.timeLimit(.minutes(1)), .productionChinese) struct RuleEditorSessionTests {
    // MARK: closing the window (R8F3-8)

    @Test func closingACleanOrEmptyEditorNeedsNoQuestion() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let a = marked("a")
        let session = RuleEditorSession(model: try await loaded(fixture, rules: [a]))
        #expect(session.closeDecision() == .closeNow)
        session.openRule(a.id)
        #expect(session.closeDecision() == .closeNow)
    }

    @Test func closingADirtyValidEditorOffersSaveWithTheName() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let a = marked("a")
        let session = RuleEditorSession(model: try await loaded(fixture, rules: [a]))
        session.openRule(a.id)
        session.update { $0.name = "edited" }
        #expect(session.closeDecision() == .askSave(name: "edited"))
        session.update { $0.name = "  " }
        #expect(session.closeDecision() == .askSave(name: RuleEditorWindowPresentation.autoName()))
    }

    @Test func closingADirtyInvalidEditorOffersOnlyDiscard() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let a = marked("a")
        let session = RuleEditorSession(model: try await loaded(fixture, rules: [a]))
        session.openRule(a.id)
        session.update { $0.actions = [] }
        #expect(session.isDirty)
        #expect(session.closeDecision() == .askDiscardOnly)
    }

    @Test func discardingOnCloseLeavesNoStaleEditsForTheNextOpen() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let a = marked("a")
        let session = RuleEditorSession(model: try await loaded(fixture, rules: [a]))
        session.openRule(a.id)
        session.update { $0.name = "edited" }
        session.discard()
        #expect(session.document == nil && session.closeDecision() == .closeNow)
        session.openRule(a.id)
        #expect(session.document?.name == "a" && !session.isDirty)
    }

    // MARK: switching

    @Test func openingAnotherRuleWhileDirtyAsks() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let a = marked("a"), b = marked("b", order: 1)
        let session = RuleEditorSession(model: try await loaded(fixture, rules: [a, b]))
        session.openRule(a.id)
        #expect(session.document?.id == a.id && !session.isDirty && !session.isNew)
        session.openRule(a.id)  // the same rule: nothing to ask
        #expect(session.pendingSwitch == nil)
        session.update { $0.name = "edited" }
        #expect(session.isDirty)
        session.openRule(b.id)
        #expect(session.pendingSwitch == .rule(b.id))
        #expect(session.document?.id == a.id && session.document?.name == "edited")
        session.openNew(inGroup: nil)
        #expect(session.pendingSwitch == .new(inGroup: nil))
        session.openSeed(RuleEditorDraft(kind: .hide))
        if case .seed = session.pendingSwitch {} else { Issue.record("expected a pending seed") }
        #expect(session.document?.id == a.id)
    }

    @Test func aCleanDocumentSwitchesAtOnce() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let a = marked("a"), b = marked("b", order: 1)
        let session = RuleEditorSession(model: try await loaded(fixture, rules: [a, b]))
        session.openRule(a.id)
        session.openRule(b.id)
        #expect(session.document?.id == b.id && session.pendingSwitch == nil)
        session.openNew(inGroup: nil)
        #expect(session.isNew && !session.isDirty)
        session.openRule(UUID())  // unknown: nothing opens
        #expect(session.isNew)
    }

    @Test func resolveDiscardSwitches() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let a = marked("a"), b = marked("b", order: 1)
        let model = try await loaded(fixture, rules: [a, b])
        let session = RuleEditorSession(model: model)
        session.openRule(a.id)
        session.update { $0.name = "edited" }
        session.openRule(b.id)
        await session.resolvePendingSwitch(.discard)
        #expect(session.document?.id == b.id && session.pendingSwitch == nil && !session.isDirty)
        #expect(model.rules.first { $0.id == a.id }?.name == "a")
    }

    @Test func resolveSaveSavesThenSwitches() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let a = marked("a"), b = marked("b", order: 1)
        let model = try await loaded(fixture, rules: [a, b])
        let session = RuleEditorSession(model: model)
        session.openRule(a.id)
        session.update { $0.name = "edited" }
        session.openRule(b.id)
        await session.resolvePendingSwitch(.save)
        #expect(model.rules.first { $0.id == a.id }?.name == "edited")
        #expect(session.document?.id == b.id && session.pendingSwitch == nil)
    }

    @Test func resolveSaveThatCannotSaveKeepsTheDocumentAndTheQuestion() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let a = marked("a"), b = marked("b", order: 1)
        let saves = CallCounter()
        let session = RuleEditorSession(model: try await loaded(fixture, rules: [a, b], saves: saves))
        session.openRule(a.id)
        session.update { $0.actions = [] }
        session.openRule(b.id)
        await session.resolvePendingSwitch(.save)
        #expect(session.document?.id == a.id && session.pendingSwitch == .rule(b.id))
        #expect(session.validation?.issues[.actions] == .noActions)
        #expect(saves.value == 0)
    }

    @Test func resolveCancelKeeps() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let a = marked("a"), b = marked("b", order: 1)
        let session = RuleEditorSession(model: try await loaded(fixture, rules: [a, b]))
        session.openRule(a.id)
        session.update { $0.name = "edited" }
        session.openRule(b.id)
        await session.resolvePendingSwitch(.cancel)
        #expect(session.pendingSwitch == nil && session.document?.id == a.id && session.document?.name == "edited" && session.isDirty)
    }

    // MARK: new rule start state and auto-name (R8F T4; overrides R8-4)

    @Test func aNewRuleStartsWithOneUrlRowAndOneMarkCardAndIsNotDirty() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let session = RuleEditorSession(model: try await loaded(fixture))
        session.openNew(inGroup: nil)
        let document = try #require(session.document)
        #expect(document.conditions.rows.count == 1)
        #expect(document.conditions.rows[0].field == .url && document.conditions.rows[0].op == .contains && document.conditions.rows[0].value == "")
        #expect(document.actions.map(\.type) == [.mark])
        #expect(session.isNew && !session.isDirty && session.validation == nil)
    }

    @Test func anEmptyNameIsSavedAsTheAutoName() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let model = try await loaded(fixture)
        let session = RuleEditorSession(model: model)
        session.openNew(inGroup: nil)
        fill(session, name: "  ")
        #expect(await session.save() == .saved)
        #expect(model.rules.map(\.name) == [RuleEditorWindowPresentation.autoName()])
        #expect(session.document?.name == RuleEditorWindowPresentation.autoName() && !session.isDirty)
    }

    @Test func anInvalidSaveShowsNoProblemUntilTheFirstSave() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let model = try await loaded(fixture)
        let session = RuleEditorSession(model: model)
        session.openNew(inGroup: nil)
        session.update { $0.actions = [] }
        #expect(session.validation == nil)
        #expect(await session.save() == .invalid)
        #expect(session.validation?.issues.isEmpty == false && model.rules.isEmpty)
    }

    // MARK: saving

    @Test func savingNewRuleGoesToTheTopAndEnabled() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let group = RuleGroup(name: "G", order: 1)
        let x = marked("x", order: 0), inside = marked("inside", group: group.id, order: 0)
        let model = try await loaded(fixture, groups: [group], rules: [x, inside])
        let session = RuleEditorSession(model: model)

        session.openNew(inGroup: nil)
        #expect(session.isNew && session.document?.enabled == true)
        fill(session, name: "top")
        #expect(session.isDirty)
        #expect(await session.save() == .saved)
        let saved = try #require(model.rules.first { $0.name == "top" })
        #expect(saved.enabled && saved.groupID == nil && saved.order == 0)
        #expect(model.rules.first { $0.id == x.id }?.order == 1)
        #expect(!session.isNew && !session.isDirty && session.document?.order == 0)

        session.openNew(inGroup: group.id)
        fill(session, name: "in group")
        #expect(await session.save() == .saved)
        let nested = try #require(model.rules.first { $0.name == "in group" })
        #expect(nested.groupID == group.id && nested.order == 0)
        #expect(model.rules.first { $0.id == inside.id }?.order == 1)
    }

    @Test func savingExistingKeepsPlace() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let a = marked("a", order: 0), b = marked("b", order: 1), c = marked("c", order: 2)
        let model = try await loaded(fixture, rules: [a, b, c])
        let session = RuleEditorSession(model: model)
        session.openRule(b.id)
        session.update { $0.name = "bee"; $0.note = "n" }
        #expect(await session.save() == .saved)
        #expect(model.rules.map(\.name) == ["a", "bee", "c"] && model.rules.map(\.order) == [0, 1, 2])
        #expect(model.rules[1].note == "n" && model.rules[1].id == b.id)
        #expect(!session.isDirty)
    }

    @Test func savingAnExistingRuleIntoAnotherGroupPutsItOnTop() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let group = RuleGroup(name: "G", order: 1)
        let a = marked("a", order: 0), in1 = marked("in1", group: group.id, order: 0)
        let model = try await loaded(fixture, groups: [group], rules: [a, in1])
        let session = RuleEditorSession(model: model)
        session.openRule(a.id)
        session.update { $0.groupID = group.id }
        #expect(await session.save() == .saved)
        let moved = try #require(model.rules.first { $0.id == a.id })
        #expect(moved.groupID == group.id && moved.order == 0)
        #expect(model.rules.first { $0.id == in1.id }?.order == 1)
        #expect(session.document?.groupID == group.id)
    }

    @Test func savingInvalidReturnsInvalidAndSavesNothing() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let saves = CallCounter()
        let session = RuleEditorSession(model: try await loaded(fixture, saves: saves))
        session.openNew(inGroup: nil)
        session.update { $0.actions = [] }
        #expect(session.validation == nil)
        #expect(await session.save() == .invalid)
        #expect(saves.value == 0)
        #expect(session.validation?.issues[.actions] == .noActions)
        // the verdict follows the edits once it was shown
        fill(session)
        #expect(session.validation?.rule != nil && session.validation?.issues.isEmpty == true)
        #expect(await session.save() == .saved)
        #expect(saves.value == 1)
    }

    @Test func savingNeedsConfirmationWhenEverySessionFinal() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let saves = CallCounter()
        let model = try await loaded(fixture, saves: saves)
        let session = RuleEditorSession(model: model)
        session.openNew(inGroup: nil)
        session.update { $0.conditions = ConditionsDraft(); $0.actions = []; $0.addAction(.returnPreset) }
        #expect(await session.save() == .needsConfirmation([.everySessionFinal]))
        #expect(saves.value == 0 && model.rules.isEmpty)
        #expect(await session.save(confirmed: true) == .saved)
        #expect(model.rules.count == 1 && saves.value == 1)
    }

    @Test func aFinalActionAtTheResponsePointCannotBeSaved() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let saves = CallCounter()
        let session = RuleEditorSession(model: try await loaded(fixture, saves: saves))
        session.openNew(inGroup: nil)
        session.update {
            $0.conditions = ConditionsDraft(group: ConditionGroup(rows: [ConditionRow(field: .statusCode, op: .equals, value: "200")]))
            $0.addAction(.rewriteStatus)
            $0.actions[0].status.status = "503"
            $0.actions[0].isFinal = true
        }
        #expect(await session.save(confirmed: true) == .invalid)
        #expect(session.validation?.issues[.action(session.document!.actions[0].id, .final)] == .finalActionAtLaterPoint)
        #expect(saves.value == 0)
    }

    @Test func saveRefusesWhatTheTreeCannotTake() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let saves = CallCounter()
        let a = marked("a")
        let model = try await loaded(fixture, rules: [a], saves: saves, limits: RulesLimits(ruleCount: 1))
        let session = RuleEditorSession(model: model)
        // the rule cap
        session.openNew(inGroup: nil)
        fill(session)
        #expect(await session.save() == .failed(.configurationTooLarge))
        #expect(saves.value == 0 && model.rules.count == 1)
        // an id that is already a rule
        var draft = RuleEditorDraft(kind: .hide)
        draft.id = a.id
        session.discard()
        session.openSeed(draft)
        #expect(await session.save(confirmed: true) == .failed(.invalidRule))
        #expect(saves.value == 0)
    }

    // MARK: the saved tree changes while the document is open

    @Test func deletedWhileEditingKeepsTheDraftAsNew() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let a = marked("a"), b = marked("b", order: 1)
        let model = try await loaded(fixture, rules: [a, b])
        let session = RuleEditorSession(model: model)
        session.openRule(a.id)
        #expect(!session.isNew && !session.isDirty)
        #expect(await model.deleteItems([a.id]))
        session.reconcile()
        #expect(session.isNew && session.isDirty && session.document?.id == a.id)
        #expect(await session.save() == .saved)
        #expect(model.rules.count == 2 && model.rules.first { $0.id == a.id }?.order == 0 && !session.isNew)
    }

    @Test func aDeletedGroupDropsTheNewDocumentToTheRoot() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let group = RuleGroup(name: "G", order: 0)
        let model = try await loaded(fixture, groups: [group], rules: [marked("x", order: 1)])
        let session = RuleEditorSession(model: model)
        session.openNew(inGroup: group.id)
        fill(session)
        #expect(await model.deleteItems([group.id]))
        session.reconcile()
        #expect(session.document?.groupID == nil)
        #expect(await session.save() == .saved)
        #expect(model.rules.first { $0.name == "new" }?.groupID == nil)
    }

    @Test func movedInTheOutlineWhileEditingFollowsWithoutBecomingDirty() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let group = RuleGroup(name: "G", order: 0)
        let a = marked("a", group: group.id, order: 0), b = marked("b", order: 1)
        let model = try await loaded(fixture, groups: [group], rules: [a, b])
        let session = RuleEditorSession(model: model)
        session.openRule(a.id)
        #expect(await model.moveItems([a.id], toParent: nil, at: 0))
        session.reconcile()
        let saved = try #require(model.rules.first { $0.id == a.id })
        #expect(session.document?.groupID == nil && session.document?.order == saved.order && !session.isDirty)
        // the user's own pick of a group is not overwritten by a move
        session.update { $0.groupID = group.id }
        #expect(await model.moveItem(a.id, by: 1))
        session.reconcile()
        #expect(session.document?.groupID == group.id && session.isDirty)
    }

    @Test func enabledToggledInOutlineFollowsIntoTheSession() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let a = marked("a")
        let model = try await loaded(fixture, rules: [a])
        let session = RuleEditorSession(model: model)
        session.openRule(a.id)
        #expect(await model.setEnabled(id: a.id, enabled: false))
        session.reconcile()
        #expect(session.document?.enabled == false && !session.isDirty)
        session.update { $0.name = "x" }
        #expect(await model.setEnabled(id: a.id, enabled: true))
        session.reconcile()
        #expect(session.document?.enabled == true && session.document?.name == "x" && session.isDirty)
    }

    @Test func conflictKeepsDraftDirty() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let a = marked("a"), other = marked("other", order: 1)
        let model = try await loaded(fixture, rules: [a])
        let session = RuleEditorSession(model: model)
        session.openRule(a.id)
        session.update { $0.name = "mine" }
        // another writer saves behind the model's back
        _ = try await fixture.repository.save(groups: [], rules: [a, other], expectedRevision: model.revision)
        #expect(await session.save() == .failed(.conflict))
        #expect(session.isDirty && session.document?.name == "mine")
        // continuing from the newer rules, the next save is explicit and works
        model.rebaseOnLatest()
        #expect(await session.save() == .saved)
        #expect(model.rules.map(\.name).sorted() == ["mine", "other"])
    }

    @Test func anEditOfTheSameRuleBehindTheEditorIsNotOverwritten() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let a = marked("a")
        let model = try await loaded(fixture, rules: [a])
        let session = RuleEditorSession(model: model)
        session.openRule(a.id)
        session.update { $0.name = "mine" }
        var theirs = a
        theirs.note = "theirs"
        #expect(await model.commitEditedRule(theirs))
        session.reconcile()
        #expect(session.hasExternalChange)
        #expect(await session.save() == .failed(.conflict))
        #expect(model.rules.first?.name == "a" && session.isDirty && session.document?.name == "mine")
        // the user may overwrite on purpose ...
        session.keepMyVersion()
        #expect(!session.hasExternalChange && session.isDirty)
        #expect(await session.save() == .saved)
        #expect(model.rules.first?.name == "mine")
        // ... or take the other version
        var again = try #require(model.rules.first)
        again.note = "third"
        #expect(await model.commitEditedRule(again))
        session.update { $0.name = "unwanted" }
        session.reconcile()
        #expect(session.hasExternalChange)
        session.reloadSaved()
        #expect(session.document?.name == "mine" && session.document?.note == "third" && !session.isDirty && !session.hasExternalChange)
    }

    // MARK: breakpoints

    @Test func breakpointRuleIsSavedDisabledWithoutLiveBreakpoints() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let model = try await loaded(fixture, liveBreakpoints: false)
        let session = RuleEditorSession(model: model)
        session.openNew(inGroup: nil)
        session.update {
            $0.name = "bp"
            $0.conditions = ConditionsDraft(group: ConditionGroup(rows: [ConditionRow(field: .host, op: .equals, value: "a.test")]))
            $0.addAction(.requestBreakpoint)
        }
        #expect(session.document?.enabled == true)
        #expect(await session.save() == .saved)
        #expect(model.rules.first?.enabled == false)
        #expect(session.document?.enabled == false && !session.isDirty)
    }

    @Test func canEnableIsFalseThere() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let session = RuleEditorSession(model: try await loaded(fixture, liveBreakpoints: false))
        session.openNew(inGroup: nil)
        #expect(session.canEnable)
        session.update { $0.actions = []; $0.addAction(.responseBreakpoint) }
        #expect(!session.canEnable)
        let live = try await loaded(RulesFixture(), liveBreakpoints: true)
        let liveSession = RuleEditorSession(model: live)
        liveSession.openNew(inGroup: nil)
        liveSession.update { $0.addAction(.requestBreakpoint) }
        #expect(liveSession.canEnable)
    }

    // MARK: managed files

    @Test func importedAssetIsDiscardedOnCancel() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let session = RuleEditorSession(model: try await loaded(fixture))
        session.openNew(inGroup: nil)
        session.update { $0.actions = []; $0.addAction(.returnFile) }
        let card = try #require(session.document?.actions.first?.id)
        await session.importFile(fixture.sourceFile("page.html"), forAction: card)
        let asset = try #require(session.document?.actions.first?.file.asset)
        #expect(session.importState == .idle && asset.displayName == "page.html")
        #expect(fixture.assetFiles() == [asset.id.uuidString + ".asset"])
        #expect(session.document?.actions.first?.file.headers.first?.name == "Content-Type")
        #expect(session.isDirty)
        session.discard()
        await session.settled()
        #expect(session.document == nil && fixture.assetFiles().isEmpty)
    }

    @Test func aMagicStringThatIsALocalFileBecomesAReturnFileCard() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let session = RuleEditorSession(model: try await loaded(fixture))
        session.openNew(inGroup: nil)
        session.update { $0.actions = []; $0.addAction(.magicString) }
        let card = try #require(session.document?.actions.first?.id)
        let file = fixture.sourceFile("page.html")
        session.update { $0.actions[0].magicText = file.path }
        #expect(session.document?.actions.first?.build().issues[.magicString] == .magicStringLocalFile)
        await session.convertMagicStringToReturnFile(forAction: card)
        await session.settled()
        let converted = try #require(session.document?.actions.first)
        #expect(converted.id == card && converted.type == .returnFile)
        #expect(converted.file.asset?.displayName == "page.html" && session.importState == .idle)
        #expect(fixture.assetFiles() == [try #require(converted.file.asset).id.uuidString + ".asset"])
        #expect(converted.build().issues.isEmpty)
    }

    @Test func convertingAgainWhenTheImportGivesTheSameCopyStillConverts() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        _ = try await fixture.repository.load()
        _ = try await fixture.repository.save(groups: [], rules: [], expectedRevision: 0)
        // A store that already holds the file hands back the copy it has: the same asset every time.
        let same = ManagedAsset(id: UUID(), size: 3, displayName: "same.html", importedAt: Date(timeIntervalSince1970: 1))
        var client = fixture.client()
        client.importFile = { _, _ in same }
        let model = RulesEditorModel(client: client, limits: RulesLimits(), liveBreakpoints: false, directoryBookmarking: DirectoryBookmarking(make: { _ in Data([7]) }))
        await model.load()
        let session = RuleEditorSession(model: model)
        session.openNew(inGroup: nil)
        session.update { $0.actions = []; $0.addAction(.magicString) }
        let card = try #require(session.document?.actions.first?.id)
        let file = fixture.sourceFile("same.html")
        session.update { $0.actions[0].magicText = file.path }
        await session.convertMagicStringToReturnFile(forAction: card)
        #expect(session.document?.actions.first?.type == .returnFile)
        // Back to a magic string: the card still holds the copy, and importing again gives that very copy.
        session.update { $0.changeType(of: card, to: .magicString) }
        #expect(session.document?.actions.first?.type == .magicString)
        await session.convertMagicStringToReturnFile(forAction: card)
        let converted = try #require(session.document?.actions.first)
        #expect(converted.type == .returnFile)
        #expect(converted.file.asset?.id == same.id)
    }

    @Test func aMagicStringThatIsNoExistingFileIsLeftAlone() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let session = RuleEditorSession(model: try await loaded(fixture))
        session.openNew(inGroup: nil)
        session.update { $0.actions = []; $0.addAction(.magicString) }
        let card = try #require(session.document?.actions.first?.id)
        session.update { $0.actions[0].magicText = "/definitely/not/here.html" }
        await session.convertMagicStringToReturnFile(forAction: card)
        #expect(session.document?.actions.first?.type == .magicString && fixture.assetFiles().isEmpty)
        session.update { $0.actions[0].magicText = "*drop" }
        await session.convertMagicStringToReturnFile(forAction: card)
        #expect(session.document?.actions.first?.type == .magicString)
    }

    @Test func replacingAFileDiscardsTheOneItReplaced() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let session = RuleEditorSession(model: try await loaded(fixture))
        session.openNew(inGroup: nil)
        session.update { $0.actions = []; $0.addAction(.returnFile) }
        let card = try #require(session.document?.actions.first?.id)
        await session.importFile(fixture.sourceFile("one.txt"), forAction: card)
        await session.importFile(fixture.sourceFile("two.json"), forAction: card)
        await session.settled()
        let current = try #require(session.document?.actions.first?.file.asset)
        #expect(current.displayName == "two.json" && fixture.assetFiles() == [current.id.uuidString + ".asset"])
        // the suggested type followed the new file
        #expect(session.document?.actions.first?.file.headers.map(\.value) == [RulesEditorModel.contentType(for: "two.json")])
    }

    @Test func keptAssetsSurviveSave() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let model = try await loaded(fixture)
        let session = RuleEditorSession(model: model)
        session.openNew(inGroup: nil)
        session.update {
            $0.name = "files"
            $0.conditions = ConditionsDraft(group: ConditionGroup(rows: [ConditionRow(field: .host, op: .equals, value: "a.test")]))
            $0.actions = []
            $0.addAction(.returnFile)
            $0.addAction(.returnFile)
        }
        let first = try #require(session.document?.actions[0].id), second = try #require(session.document?.actions[1].id)
        await session.importFile(fixture.sourceFile("a.txt"), forAction: first)
        await session.importFile(fixture.sourceFile("b.txt"), forAction: second)
        let kept = try #require(session.document?.actions[0].file.asset)
        session.update { $0.removeAction(second) }
        #expect(await session.save() == .saved)
        await session.settled()
        #expect(fixture.assetFiles() == [kept.id.uuidString + ".asset"])
        #expect(model.rules.first?.actions.first?.kind == .returnFile(MapLocalAction(
            assetID: kept.id, status: 200, headers: [HeaderField(name: "Content-Type", value: "text/plain")])))
    }

    @Test func switchingTypeAwayAndBackKeepsTheAsset() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let model = try await loaded(fixture)
        let session = RuleEditorSession(model: model)
        session.openNew(inGroup: nil)
        session.update {
            $0.name = "swap"
            $0.conditions = ConditionsDraft(group: ConditionGroup(rows: [ConditionRow(field: .host, op: .equals, value: "a.test")]))
            $0.actions = []
            $0.addAction(.returnFile)
        }
        let card = try #require(session.document?.actions.first?.id)
        await session.importFile(fixture.sourceFile("a.txt"), forAction: card)
        let asset = try #require(session.document?.actions.first?.file.asset)
        session.update { $0.changeType(of: card, to: .mark) }
        #expect(await session.save() == .saved)
        await session.settled()
        #expect(fixture.assetFiles() == [asset.id.uuidString + ".asset"], "a hidden form still holds its file")
        session.update { $0.changeType(of: card, to: .returnFile) }
        #expect(await session.save() == .saved)
        await session.settled()
        #expect(fixture.assetFiles() == [asset.id.uuidString + ".asset"])
        #expect(model.rules.first?.actions.first?.kind == .returnFile(MapLocalAction(
            assetID: asset.id, status: 200, headers: [HeaderField(name: "Content-Type", value: "text/plain")])))
        // closing discards what no saved rule uses, and keeps what one does
        session.discard()
        await session.settled()
        #expect(fixture.assetFiles() == [asset.id.uuidString + ".asset"])
    }

    @Test func openingARuleShowsTheRealAssetNotAPlaceholder() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        _ = try await fixture.repository.load()
        let asset = try await fixture.assets.importFile(fixture.sourceFile("kept.txt", "hello"), displayName: "kept.txt")
        let rule = Rule(
            name: "file", conditions: ConditionGroup(rows: [ConditionRow(field: .host, op: .equals, value: "a.test")]),
            actions: [RuleAction(.returnFile(MapLocalAction(assetID: asset.id, headers: [])))])
        let model = try await loaded(fixture, rules: [rule])
        let session = RuleEditorSession(model: model)
        session.openRule(rule.id)
        let shown = try #require(session.document?.actions.first?.file.asset)
        #expect(shown.id == asset.id && shown.displayName == "kept.txt" && shown.size == 5)
        #expect(!session.isDirty)
        #expect(await session.save() == .saved)
    }

    @Test func aMockSeedsImportIsTheSessionsToDiscard() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let model = try await loaded(fixture)
        let session = RuleEditorSession(model: model)
        let asset = try await model.importManagedFile(from: fixture.sourceFile("mock.json", "{}"))
        var draft = RuleEditorDraft(kind: .mapLocal)
        draft.match.host = "a.test"
        draft.mapLocal.asset = asset
        session.openSeed(draft)
        #expect(session.isNew && !session.isDirty && session.document?.actions.first?.file.asset == asset)
        session.discard()
        await session.settled()
        #expect(fixture.assetFiles().isEmpty)
    }

    @Test func decliningAPendingSeedDiscardsItsImport() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let a = marked("a")
        let model = try await loaded(fixture, rules: [a])
        let session = RuleEditorSession(model: model)
        session.openRule(a.id)
        session.update { $0.name = "edited" }
        let asset = try await model.importManagedFile(from: fixture.sourceFile("mock.json", "{}"))
        var draft = RuleEditorDraft(kind: .mapLocal)
        draft.mapLocal.asset = asset
        session.openSeed(draft)
        #expect(session.pendingSwitch != nil)
        await session.resolvePendingSwitch(.cancel)
        await session.settled()
        #expect(session.document?.id == a.id && fixture.assetFiles().isEmpty)
    }

    @Test func aSeedThatReplacesAnUnansweredSeedDiscardsTheOldOnesImport() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let a = marked("a")
        let model = try await loaded(fixture, rules: [a])
        let session = RuleEditorSession(model: model)
        session.openRule(a.id)
        session.update { $0.name = "edited" }
        var first = RuleEditorDraft(kind: .mapLocal)
        first.mapLocal.asset = try await model.importManagedFile(from: fixture.sourceFile("one.json", "{}"))
        var second = RuleEditorDraft(kind: .mapLocal)
        second.mapLocal.asset = try await model.importManagedFile(from: fixture.sourceFile("two.json", "{}"))
        session.openSeed(first)
        session.openSeed(second)
        await session.settled()
        #expect(fixture.assetFiles().count == 1)
        await session.resolvePendingSwitch(.discard)
        #expect(session.document?.actions.first?.file.asset == second.mapLocal.asset)
    }

    @Test func aSeedRefusedWhileBusyDiscardsItsImport() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let gate = Gate()
        let a = marked("a")
        let model = try await loaded(fixture, rules: [a], saveGate: gate)
        let session = RuleEditorSession(model: model)
        session.openRule(a.id)
        session.update { $0.name = "edited" }
        async let saved = session.save()
        await gate.arrived()
        var draft = RuleEditorDraft(kind: .mapLocal)
        draft.mapLocal.asset = try await model.importManagedFile(from: fixture.sourceFile("busy.json", "{}"))
        session.openSeed(draft)
        await gate.open()
        #expect(await saved == .saved)
        await session.settled()
        #expect(fixture.assetFiles().isEmpty)
    }

    @Test func theModelRevisionIsExposedForReconciling() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let a = marked("a")
        let model = try await loaded(fixture, rules: [a])
        let session = RuleEditorSession(model: model)
        let before = session.modelRevision
        #expect(await model.setEnabled(id: a.id, enabled: false))
        #expect(session.modelRevision != before && session.modelRevision == model.revision)
    }

    @Test func chooseDirectoryStoresTheBookmark() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let session = RuleEditorSession(model: try await loaded(fixture))
        session.openNew(inGroup: nil)
        session.update { $0.actions = []; $0.addAction(.returnDirectory) }
        let card = try #require(session.document?.actions.first?.id)
        await session.chooseDirectory(fixture.root.appendingPathComponent("site"), forAction: card)
        #expect(session.document?.actions.first?.directory.bookmark == Data([7]))
        #expect(session.document?.actions.first?.directory.displayName == "site" && session.isDirty)

        let failing = RuleEditorSession(model: try await loaded(
            RulesFixture(), bookmarking: DirectoryBookmarking(make: { _ in throw OwnedFileError(.ioFailure, errno: EIO) })))
        failing.openNew(inGroup: nil)
        failing.update { $0.addAction(.returnDirectory) }
        await failing.chooseDirectory(fixture.root, forAction: try #require(failing.document?.actions.first?.id))
        #expect(failing.importState == .failed(.directoryFailed) && failing.document?.actions.first?.directory.bookmark == nil)
    }

    // MARK: closing, busy

    @Test func discardClosesAndNewDocumentLeavesNoRule() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let saves = CallCounter()
        let model = try await loaded(fixture, rules: [marked("a")], saves: saves)
        let session = RuleEditorSession(model: model)
        session.openNew(inGroup: nil)
        fill(session)
        session.discard()
        #expect(session.document == nil && !session.isDirty && !session.isNew && session.validation == nil && session.pendingSwitch == nil)
        #expect(model.rules.map(\.name) == ["a"] && saves.value == 0)
        #expect(await session.save() == .invalid)
    }

    @Test func updateIsIgnoredWhileBusy() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let gate = Gate()
        let model = try await loaded(fixture, saveGate: gate)
        let session = RuleEditorSession(model: model)
        session.openNew(inGroup: nil)
        fill(session)
        async let saved = session.save()
        await gate.arrived()
        session.update { $0.name = "changed while saving" }
        #expect(session.document?.name == "new")
        #expect(await session.save() == .busy)
        await gate.open()
        #expect(await saved == .saved)
        session.update { $0.name = "after" }
        #expect(session.document?.name == "after")
    }

    @Test func updateCannotChangeTheDocumentsIdentity() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let session = RuleEditorSession(model: try await loaded(fixture))
        session.openNew(inGroup: nil)
        let id = try #require(session.document?.id)
        session.update { $0.id = UUID() }
        #expect(session.document?.id == id)
    }

    @Test func closingOrSwitchingIsIgnoredWhileASaveRuns() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let gate = Gate()
        let a = marked("a"), b = marked("b", order: 1)
        let model = try await loaded(fixture, rules: [a, b], saveGate: gate)
        let session = RuleEditorSession(model: model)
        session.openRule(a.id)
        session.update { $0.name = "edited" }
        async let saved = session.save()
        await gate.arrived()
        session.discard()
        session.openNew(inGroup: nil)
        session.openRule(b.id)
        session.openSeed(RuleEditorDraft(kind: .hide))
        await session.resolvePendingSwitch(.discard)
        #expect(session.document?.id == a.id && session.document?.name == "edited")
        await gate.open()
        #expect(await saved == .saved)
        #expect(session.document?.id == a.id && !session.isDirty && !session.isNew)
        #expect(model.rules.first { $0.id == a.id }?.name == "edited")
    }

    @Test func aStaleModelErrorIsNotThisSavesFailure() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let model = try await loaded(fixture, rules: [marked("a")])
        #expect(await model.addGroup(name: "x", inParent: UUID()) == nil)  // leaves model.error behind
        #expect(model.error != nil)
        let session = RuleEditorSession(model: model)
        session.openNew(inGroup: nil)
        fill(session)
        #expect(await session.save() == .saved)
        #expect(model.error == nil)
    }

    @Test func resolvingSaveOnACleanDocumentJustSwitches() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let saves = CallCounter()
        let a = marked("a"), b = marked("b", order: 1)
        let session = RuleEditorSession(model: try await loaded(fixture, rules: [a, b], saves: saves))
        session.openRule(a.id)
        session.update { $0.name = "edited" }
        session.openRule(b.id)
        #expect(session.pendingSwitch == .rule(b.id))
        #expect(await session.save() == .saved)
        await session.resolvePendingSwitch(.save)
        #expect(saves.value == 1 && session.document?.id == b.id)
    }

    @Test func aPendingSwitchToARuleThatVanishedKeepsTheDocument() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let a = marked("a"), b = marked("b", order: 1)
        let model = try await loaded(fixture, rules: [a, b])
        let session = RuleEditorSession(model: model)
        session.openRule(a.id)
        session.update { $0.name = "edited" }
        session.openRule(b.id)
        #expect(await model.deleteItems([b.id]))
        await session.resolvePendingSwitch(.discard)
        #expect(session.document?.id == a.id && session.document?.name == "edited" && session.pendingSwitch == nil)
    }

    @Test func aDirectoryChoiceDoesNotEndARunningFileImport() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let gate = Gate()
        _ = try await fixture.repository.load()
        var client = fixture.client()
        let importFile = client.importFile
        client.importFile = { url, name in
            await gate.pass()
            return try await importFile(url, name)
        }
        let model = RulesEditorModel(client: client, limits: RulesLimits(), directoryBookmarking: DirectoryBookmarking(make: { _ in Data([7]) }))
        await model.load()
        let session = RuleEditorSession(model: model)
        session.openNew(inGroup: nil)
        session.update { $0.actions = []; $0.addAction(.returnFile); $0.addAction(.returnDirectory) }
        let file = try #require(session.document?.actions[0].id), directory = try #require(session.document?.actions[1].id)
        let source = fixture.sourceFile("a.txt")
        async let imported: Void = session.importFile(source, forAction: file)
        await gate.arrived()
        #expect(session.importState == .importing)
        await session.chooseDirectory(fixture.root, forAction: directory)
        #expect(session.importState == .importing && session.document?.actions[1].directory.bookmark == nil)
        await gate.open()
        await imported
        #expect(session.importState == .idle)
    }
}
