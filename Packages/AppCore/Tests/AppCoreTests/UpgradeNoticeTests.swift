import Foundation
import Localization
import RulesEngine
import Testing

@testable import AppCore

// Rules 2.0 R1, Task 11: the one-time upgrade notice. A migrated file stores which rule pairs may now
// behave differently (`MigrationNotice`); the rules window shows them once, the editor remembers that the
// user read them, and the pair text is built from the class when it is shown (D10).

// MARK: support

private struct StoredFile: Codable {
    var schemaVersion = 4
    var revision: UInt64 = 7
    var groups: [RuleGroup] = []
    var rules: [Rule]
    var assets: [ManagedAsset] = []
    var templatesInstalled = false
    var migrationNotice: MigrationNotice?
}

private func rule(_ name: String, host: String = "a.test", order: Int) -> Rule {
    Rule(
        id: UUID(), name: name, enabled: true, order: order, matcher: RuleMatcher(hostPattern: host),
        action: .rewriteStatus(RewriteStatusAction(status: 500)))
}

private func pair(_ changeClass: MigrationChangeClass, _ higher: Rule, _ lower: Rule) -> MigrationPair {
    MigrationPair(changeClass: changeClass, higherRuleID: higher.id, lowerRuleID: lower.id)
}

private func notice(
    _ pairs: [MigrationPair], acknowledged: Bool = false, omitted: Int = 0, schema: Int = 3
) -> MigrationNotice {
    MigrationNotice(
        report: MigrationReport(pairs: pairs), migratedFromSchema: schema, acknowledged: acknowledged,
        omittedPairCount: omitted)
}

/// Writes `rules` and `notice` as a schema 4 file, the way a migration leaves them.
private func seed(_ fixture: RulesFixture, rules: [Rule], notice: MigrationNotice?) throws {
    try FileManager.default.createDirectory(at: fixture.configDir, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(StoredFile(rules: rules, migrationNotice: notice)).write(to: fixture.configFile)
}

private func storedFile(_ fixture: RulesFixture) throws -> StoredFile {
    try JSONDecoder().decode(StoredFile.self, from: Data(contentsOf: fixture.configFile))
}

private func names(of rules: [Rule]) -> (UUID) -> String? {
    { id in rules.first { $0.id == id }?.name }
}

/// The production client, with the acknowledge call counted (and optionally replaced).
private func countingClient(
    _ fixture: RulesFixture, acknowledgements: CallCounter,
    acknowledge: (@Sendable () async throws -> RuleSnapshot)? = nil
) -> RulesRepositoryClient {
    var client = fixture.client()
    let live = client.acknowledgeNotice
    client.acknowledgeNotice = {
        acknowledgements.increment()
        return try await (acknowledge ?? live)()
    }
    return client
}

@MainActor
private func loadedModel(
    _ fixture: RulesFixture, rules: [Rule], notice: MigrationNotice?, client: RulesRepositoryClient? = nil
) async throws -> RulesEditorModel {
    try seed(fixture, rules: rules, notice: notice)
    let model = RulesEditorModel(client: client ?? fixture.client(), limits: RulesLimits())
    await model.load()
    #expect(model.loadState == .loaded)
    return model
}

@MainActor @Suite(.productionChinese, .timeLimit(.minutes(1))) struct UpgradeNoticeTests {
    // MARK: presentation

    @Test func presentationGroupsPairsByClassInOrder() throws {
        let a = rule("A", order: 0), b = rule("B", order: 1), c = rule("C", order: 2), d = rule("D", order: 3)
        // Stored in report order (higher rule, lower rule, class); the classes are interleaved.
        let stored = notice([
            pair(.sequentialRewrite, a, b), pair(.finalAction, a, c), pair(.laterSeesEarlier, b, c),
            pair(.finalAction, b, d), pair(.sequentialRewrite, c, d),
        ])
        let presentation = try #require(UpgradeNoticePresentation.make(notice: stored, ruleName: names(of: [a, b, c, d])))

        #expect(presentation.sections.map(\.changeClass) == [.finalAction, .laterSeesEarlier, .sequentialRewrite])
        #expect(presentation.sections.map(\.titleKey) == ["rules.upgrade.class1.title", "rules.upgrade.class2.title", "rules.upgrade.class3.title"])
        #expect(presentation.sections.map(\.bodyKey) == ["rules.upgrade.class1.body", "rules.upgrade.class2.body", "rules.upgrade.class3.body"])
        let listed = presentation.sections.map { $0.items.map { [$0.higherName, $0.lowerName] } }
        #expect(listed == [[["A", "C"], ["B", "D"]], [["B", "C"]], [["A", "B"], ["C", "D"]]], "report order is kept inside a class")
        #expect(presentation.sections[0].items.map(\.higherID) == [a.id, b.id])
        #expect(presentation.sections[0].items.map(\.lowerID) == [c.id, d.id])
        #expect(presentation.sections.flatMap(\.items).map(\.changeClass) == [.finalAction, .finalAction, .laterSeesEarlier, .sequentialRewrite, .sequentialRewrite])
        let ids = presentation.sections.flatMap(\.items).map(\.id)
        #expect(Set(ids).count == ids.count, "every row has its own identity")
        #expect(presentation.omittedPairCount == 0 && presentation.omittedText() == nil)
    }

    @Test func aClassWithoutPairsHasNoSection() throws {
        let a = rule("A", order: 0), b = rule("B", order: 1)
        let presentation = try #require(
            UpgradeNoticePresentation.make(notice: notice([pair(.sequentialRewrite, a, b)]), ruleName: names(of: [a, b])))
        #expect(presentation.sections.map(\.changeClass) == [.sequentialRewrite])
    }

    @Test func theSamePairTwiceIsListedOnce() throws {
        let a = rule("A", order: 0), b = rule("B", order: 1)
        let twice = notice([pair(.finalAction, a, b), pair(.finalAction, a, b), pair(.laterSeesEarlier, a, b)])
        let presentation = try #require(UpgradeNoticePresentation.make(notice: twice, ruleName: names(of: [a, b])))
        #expect(presentation.sections.map { $0.items.count } == [1, 1])
    }

    @Test func emptyOrAbsentNoticeHasNoPresentation() {
        #expect(UpgradeNoticePresentation.make(notice: nil, ruleName: { _ in nil }) == nil)
        #expect(UpgradeNoticePresentation.make(notice: notice([]), ruleName: { _ in nil }) == nil)
        // Pairs counted but none listed (the stored list was cut down) still say so.
        let onlyCounted = UpgradeNoticePresentation.make(notice: notice([], omitted: 3), ruleName: { _ in nil })
        #expect(onlyCounted?.sections.isEmpty == true && onlyCounted?.omittedPairCount == 3)
    }

    /// The advice talks about "the listed pair"; with no pair listed (the stored list was cut down to a
    /// count) there is nothing for it to refer to.
    @Test func adviceIsShownOnlyWhenPairsAreListed() throws {
        let a = rule("A", order: 0), b = rule("B", order: 1)
        let listed = try #require(
            UpgradeNoticePresentation.make(notice: notice([pair(.finalAction, a, b)], omitted: 4), ruleName: names(of: [a, b])))
        #expect(listed.showsAdvice)
        let onlyCounted = try #require(UpgradeNoticePresentation.make(notice: notice([], omitted: 3), ruleName: { _ in nil }))
        #expect(onlyCounted.sections.isEmpty && !onlyCounted.showsAdvice)
        #expect(onlyCounted.introText() == L10n.format("rules.upgrade.introUnlisted", 3))
    }

    @Test func deletedRuleUsesThePlaceholderName() throws {
        let a = rule("A", order: 0), gone = rule("Gone", order: 1)
        let presentation = try #require(
            UpgradeNoticePresentation.make(notice: notice([pair(.finalAction, a, gone), pair(.finalAction, gone, a)]), ruleName: names(of: [a])))
        let items = presentation.sections[0].items
        let placeholder = L10n.string("ruleOutcome.unknownRule")
        #expect(items[0].higherName == "A" && items[0].lowerName == placeholder)
        #expect(items[1].higherName == placeholder && items[1].lowerName == "A")
        // The row still knows which rule it points at.
        #expect(items[0].lowerID == gone.id)
        #expect(presentation.pairText(items[0]) == L10n.format("rules.upgrade.pair", "A", placeholder))
    }

    @Test func anUnnamedRuleShowsTheUnnamedPlaceholder() throws {
        let a = rule("  ", order: 0), b = rule("B", order: 1)
        let presentation = try #require(
            UpgradeNoticePresentation.make(notice: notice([pair(.finalAction, a, b)]), ruleName: names(of: [a, b])))
        #expect(presentation.sections[0].items[0].higherName == L10n.string("rules.list.unnamed"))
    }

    @Test func pairTextNamesTheHigherRuleFirstAndTheLowerSecond() throws {
        let a = rule("Alpha", order: 0), b = rule("Beta", order: 1)
        let presentation = try #require(
            UpgradeNoticePresentation.make(notice: notice([pair(.laterSeesEarlier, a, b)]), ruleName: names(of: [a, b])))
        let item = presentation.sections[0].items[0]
        #expect(presentation.pairText(item) == "「Alpha」→「Beta」")
    }

    @Test func theOmittedCountIsItsOwnSentenceWithAPositionalArgument() throws {
        let a = rule("A", order: 0), b = rule("B", order: 1)
        let withPairs = try #require(
            UpgradeNoticePresentation.make(notice: notice([pair(.finalAction, a, b)], omitted: 12), ruleName: names(of: [a, b])))
        #expect(withPairs.omittedText() == "另有 12 对受影响的规则没有在这里列出。")
        // The sentence that opens the notice points at the list below.
        #expect(withPairs.introText() == L10n.string("rules.upgrade.intro"))
        // Without listed pairs there is no list, so no "more": the opening sentence carries the count and says
        // the pairs are not listed.
        let noPairs = try #require(UpgradeNoticePresentation.make(notice: notice([], omitted: 7), ruleName: { _ in nil }))
        #expect(noPairs.sections.isEmpty && noPairs.omittedText() == nil)
        let intro = noPairs.introText()
        #expect(intro == "规则的执行方式升级了。有 7 对规则，升级后的结果可能和以前不同，但这些规则对未列出；其余规则的行为不变。")
        #expect(intro.contains("未列出") && !intro.contains("另有") && !intro.contains("下面"))
    }

    // MARK: editor model

    @Test func acknowledgeCallsTheRepositoryAndHidesTheBlock() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let a = rule("A", order: 0), b = rule("B", order: 1)
        let acknowledgements = CallCounter()
        let model = try await loadedModel(
            fixture, rules: [a, b], notice: notice([pair(.finalAction, a, b)], omitted: 2),
            client: countingClient(fixture, acknowledgements: acknowledgements))
        #expect(model.migrationNotice?.acknowledged == false && model.showsUpgradeNotice && model.canAcknowledgeUpgradeNotice)
        #expect(model.upgradeNotice?.sections.map(\.changeClass) == [.finalAction])
        let revision = model.revision

        await model.acknowledgeUpgradeNotice()

        #expect(acknowledgements.value == 1)
        #expect(!model.showsUpgradeNotice && model.upgradeNotice == nil)
        #expect(model.migrationNotice?.acknowledged == true)
        #expect(model.error == nil && !model.isBusy)
        // The pairs are kept for "view upgrade notes"; only the flag changed, and no revision was spent
        // (an open draft must not conflict, D11).
        #expect(model.migrationNotice?.report.pairs == [pair(.finalAction, a, b)] && model.migrationNotice?.omittedPairCount == 2)
        #expect(model.revision == revision)
        let stored = try storedFile(fixture)
        #expect(stored.migrationNotice?.acknowledged == true && stored.revision == revision)
        #expect(fixture.repository.provider.current().migrationNotice?.acknowledged == true)
    }

    @Test func reopenShowsAnAcknowledgedNoticeAgain() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let a = rule("A", order: 0), b = rule("B", order: 1)
        let acknowledgements = CallCounter()
        let model = try await loadedModel(
            fixture, rules: [a, b], notice: notice([pair(.laterSeesEarlier, a, b)], acknowledged: true),
            client: countingClient(fixture, acknowledgements: acknowledgements))
        #expect(!model.showsUpgradeNotice && !model.hasUnreadUpgradeNotice, "read already: nothing opens by itself")
        #expect(model.upgradeNotice == nil)

        model.reopenUpgradeNotice()
        #expect(model.showsUpgradeNotice && model.canAcknowledgeUpgradeNotice)
        #expect(model.upgradeNotice?.sections.map(\.changeClass) == [.laterSeesEarlier])
        #expect(!model.hasUnreadUpgradeNotice, "reopening does not make it unread again")

        // "Got it" on a notice that was already acknowledged only closes it: nothing is written.
        await model.acknowledgeUpgradeNotice()
        #expect(!model.showsUpgradeNotice)
        #expect(acknowledgements.value == 0)
        #expect(try storedFile(fixture).migrationNotice?.acknowledged == true)

        model.reopenUpgradeNotice()
        #expect(model.showsUpgradeNotice)
    }

    @Test func acknowledgeFailureKeepsTheBlockAndShowsAnError() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let a = rule("A", order: 0), b = rule("B", order: 1)
        let model = try await loadedModel(fixture, rules: [a, b], notice: notice([pair(.sequentialRewrite, a, b)]))
        let before = try Data(contentsOf: fixture.configFile)

        fixture.fault.arm(.write)
        await model.acknowledgeUpgradeNotice()
        #expect(model.showsUpgradeNotice && model.migrationNotice?.acknowledged == false)
        #expect(model.error == .storage(.ioFailure))
        #expect(!model.isBusy)
        #expect(try Data(contentsOf: fixture.configFile) == before, "a failed write leaves the file as it was")
        #expect(fixture.repository.provider.current().migrationNotice?.acknowledged == false)

        // The user tries again once the disk works.
        fixture.fault.arm(nil)
        await model.acknowledgeUpgradeNotice()
        #expect(!model.showsUpgradeNotice && model.error == nil)
        #expect(try storedFile(fixture).migrationNotice?.acknowledged == true)
    }

    @Test func selectingAPairSelectsTheLowerRule() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let a = rule("A", order: 0), b = rule("B", order: 1), c = rule("C", order: 2)
        let model = try await loadedModel(fixture, rules: [a, b, c], notice: notice([pair(.finalAction, a, c), pair(.finalAction, a, b)]))
        let item = try #require(model.upgradeNotice?.sections.first?.items.first)
        #expect(item.higherID == a.id && item.lowerID == c.id)

        model.select(fromNotice: item)
        #expect(model.selection == c.id && model.draft?.id == c.id)
    }

    @Test func selectingAPairWithUnsavedChangesAsksFirst() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let a = rule("A", order: 0), b = rule("B", order: 1)
        let model = try await loadedModel(fixture, rules: [a, b], notice: notice([pair(.finalAction, a, b)]))
        model.requestSelection(a.id)
        var draft = try #require(model.draft)
        draft.name = "edited"
        model.setDraft(draft)
        #expect(model.isDraftDirty)

        model.select(fromNotice: try #require(model.upgradeNotice?.sections.first?.items.first))
        #expect(model.selection == a.id && model.draft?.name == "edited", "unsaved changes are not dropped silently")
        #expect(model.pendingNavigation == .select(b.id))
        model.confirmPendingNavigation()
        #expect(model.selection == b.id)
    }

    @Test func selectingAPairWhoseLowerRuleWasDeletedChangesNothing() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let a = rule("A", order: 0), b = rule("B", order: 1)
        let model = try await loadedModel(fixture, rules: [a, b], notice: notice([pair(.finalAction, a, b)]))
        let item = try #require(model.upgradeNotice?.sections.first?.items.first)
        #expect(await model.delete(id: b.id))
        model.requestSelection(a.id)

        model.select(fromNotice: item)
        #expect(model.selection == a.id && model.pendingNavigation == nil)
        #expect(model.upgradeNotice?.sections.first?.items.first?.lowerName == L10n.string("ruleOutcome.unknownRule"))
    }

    @Test func noticeSurvivesRuleSaves() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let a = rule("A", order: 0), b = rule("B", order: 1)
        let original = notice([pair(.finalAction, a, b)], omitted: 4)
        let model = try await loadedModel(fixture, rules: [a, b], notice: original)

        // An edit saved through the form.
        model.requestSelection(a.id)
        var draft = try #require(model.draft)
        draft.name = "renamed"
        model.setDraft(draft)
        #expect(await model.save())
        #expect(model.rules.first?.name == "renamed")
        #expect(model.migrationNotice == original && model.showsUpgradeNotice)
        #expect(try storedFile(fixture).migrationNotice == original)

        // A switch, a move and a delete publish new revisions too.
        #expect(await model.setEnabled(id: b.id, enabled: false))
        #expect(await model.move(fromOffsets: IndexSet(integer: 1), toOffset: 0))
        #expect(model.migrationNotice == original)
        #expect(await model.delete(id: a.id))
        #expect(model.migrationNotice == original)
        #expect(try storedFile(fixture).migrationNotice == original)

        // Once read, a later save does not make it unread again.
        await model.acknowledgeUpgradeNotice()
        #expect(await model.setEnabled(id: b.id, enabled: true))
        #expect(model.migrationNotice?.acknowledged == true && !model.showsUpgradeNotice)
        #expect(try storedFile(fixture).migrationNotice?.acknowledged == true)
    }

    @Test func noticeIsKeptWhenAnotherWriterWinsAConflict() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let a = rule("A", order: 0), b = rule("B", order: 1)
        let original = notice([pair(.finalAction, a, b)])
        let model = try await loadedModel(fixture, rules: [a, b], notice: original)
        // Another writer (the MCP adapter's editor, say) saves first.
        _ = try await fixture.repository.save(groups: [], rules: [a], expectedRevision: model.revision)

        #expect(await model.setEnabled(id: a.id, enabled: false) == false)
        #expect(model.conflict != nil)
        // While the conflict is unresolved no mutation runs, and marking the notice read is one.
        #expect(!model.canAcknowledgeUpgradeNotice)
        await model.acknowledgeUpgradeNotice()
        #expect(model.migrationNotice?.acknowledged == false && model.showsUpgradeNotice)
        #expect(try storedFile(fixture).migrationNotice?.acknowledged == false)
        model.discardChanges()
        #expect(model.rules.map(\.id) == [a.id])
        #expect(model.migrationNotice == original, "the newer state carries the notice")
        #expect(model.canAcknowledgeUpgradeNotice)
    }

    @Test func noNoticeMeansNoBlock() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let acknowledgements = CallCounter()
        let a = rule("A", order: 0)
        let model = try await loadedModel(
            fixture, rules: [a], notice: nil, client: countingClient(fixture, acknowledgements: acknowledgements))
        #expect(model.migrationNotice == nil && !model.showsUpgradeNotice && !model.hasUnreadUpgradeNotice)
        #expect(model.upgradeNotice == nil && !model.hasUpgradeNotice && !model.canAcknowledgeUpgradeNotice)

        model.reopenUpgradeNotice()
        #expect(!model.showsUpgradeNotice, "there is nothing to reopen")
        await model.acknowledgeUpgradeNotice()
        #expect(acknowledgements.value == 0 && model.error == nil)

        // A notice that lists nothing at all (a hand-edited file) shows nothing either.
        let empty = RulesFixture(); defer { empty.remove() }
        let hollow = try await loadedModel(empty, rules: [a], notice: notice([]))
        #expect(hollow.migrationNotice != nil && !hollow.showsUpgradeNotice && !hollow.hasUnreadUpgradeNotice)
        #expect(hollow.upgradeNotice == nil)
    }

    @Test func aNoticeThatOnlyCountsPairsIsStillShown() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let a = rule("A", order: 0)
        let model = try await loadedModel(fixture, rules: [a], notice: notice([], omitted: 9))
        #expect(model.showsUpgradeNotice && model.hasUnreadUpgradeNotice)
        #expect(model.upgradeNotice?.sections.isEmpty == true)
        #expect(model.upgradeNotice?.omittedText() == nil)
        #expect(model.upgradeNotice?.introText().contains("有 9 对规则") == true)
    }
}
