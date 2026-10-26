import Foundation
import RulesEngine
import Testing

@testable import AppCore

// Rules 2.0 R1, Task 10 (D20): a rule the old editor cannot state (several actions, a final flag the user
// ticked, an occurrence range, two rows for one field) is read-only there. It can still be switched on and
// off, copied, moved and deleted, and no save of the old editor ever drops it, its groups or the notice.

private func headerRule(_ name: String, order: Int = 0, mode: ConditionGroup.Mode = .all) -> Rule {
    var rule = Rule(
        id: UUID(), name: name, enabled: true, order: order, matcher: RuleMatcher(hostPattern: "\(name).test"),
        action: .editHeaders(direction: .request, operations: [.set(name: "X-Rule", value: name)]))
    rule.conditions.mode = mode
    return rule
}

private func multiActionRule(_ name: String, order: Int = 0, groupID: UUID? = nil) -> Rule {
    Rule(
        id: UUID(), name: name, groupID: groupID, order: order,
        conditions: ConditionGroup(rows: [ConditionRow(field: .host, op: .hostPattern, value: "\(name).test")]),
        actions: [
            RuleAction(.editHeaders(direction: .request, operations: [.set(name: "X-A", value: "1")])),
            RuleAction(.rewriteStatus(RewriteStatusAction(status: 201))),
        ])
}

private func pathRow(_ prefix: String) -> ConditionRow {
    ConditionRow(field: .pathAndQuery, op: .startsWith, value: prefix, caseSensitive: true)
}

/// Saves `rules` (and `groups`) as revision 1, then starts the app again over the same directory: the model that
/// has loaded them and the repository behind it (`live`, where what the model saved can be read).
@MainActor
private func loadedModel(
    _ fixture: RulesFixture, groups: [RuleGroup] = [], rules: [Rule], saves: CallCounter? = nil, liveBreakpoints: Bool = false
) async throws -> (model: RulesEditorModel, live: RulesFixture) {
    _ = try await fixture.repository.load()
    _ = try await fixture.repository.save(groups: groups, rules: rules, expectedRevision: 0)
    let live = RulesFixture(root: fixture.root)
    let model = RulesEditorModel(client: live.client(saves: saves), limits: RulesLimits(), liveBreakpoints: liveBreakpoints)
    await model.load()
    return (model, live)
}

@MainActor @Suite(.timeLimit(.minutes(1)), .productionChinese) struct RuleReadOnlyTests {
    // MARK: which rules are read-only

    @Test func multiActionRuleLoadsAsReadOnlyWithReason() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let multi = multiActionRule("multi"), plain = headerRule("plain", order: 1)
        let (model, _) = try await loadedModel(fixture, rules: [multi, plain])

        #expect(model.isReadOnly(multi.id) && !model.isReadOnly(plain.id))
        #expect(!model.isReadOnly(UUID()), "an unknown id is not read-only")
        #expect(RuleKind(multi) == nil && RuleKind(plain) == .editHeaders)

        model.requestSelection(multi.id)
        #expect(model.draft?.readOnlyReason == .multipleActions)
        #expect(model.draft?.name == "multi" && model.draft?.enabled == true)
        #expect(!model.isDraftDirty && !model.canSave)
        model.requestSelection(plain.id)
        #expect(model.draft?.readOnlyReason == nil && model.canSave)
    }

    @Test func ruleWithTwoPathRowsIsReadOnly() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let rule = Rule(
            id: UUID(), name: "two paths", conditions: ConditionGroup(rows: [pathRow("/a/"), pathRow("/b/")]),
            actions: [RuleAction(.rewriteStatus(RewriteStatusAction(status: 404)))])
        let (model, _) = try await loadedModel(fixture, rules: [rule])
        #expect(model.isReadOnly(rule.id))
        model.requestSelection(rule.id)
        #expect(model.draft?.readOnlyReason == .unsupportedConditions)
    }

    @Test func userFinalFlagMakesRuleReadOnly() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let rule = Rule(
            id: UUID(), name: "final",
            conditions: ConditionGroup(rows: [ConditionRow(field: .host, op: .hostPattern, value: "a.test")]),
            actions: [RuleAction(.rewriteStatus(RewriteStatusAction(status: 404)), isFinal: true)])
        let (model, _) = try await loadedModel(fixture, rules: [rule])
        #expect(model.isReadOnly(rule.id))
        model.requestSelection(rule.id)
        #expect(model.draft?.readOnlyReason == .userFinalFlag)
    }

    @Test func occurrenceRangeMakesRuleReadOnly() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let rule = Rule(
            id: UUID(), name: "second hit",
            conditions: ConditionGroup(occurrence: .times(2...3), rows: [ConditionRow(field: .host, op: .hostPattern, value: "a.test")]),
            actions: [RuleAction(.rewriteStatus(RewriteStatusAction(status: 404)))])
        let (model, _) = try await loadedModel(fixture, rules: [rule])
        #expect(model.isReadOnly(rule.id))
        model.requestSelection(rule.id)
        #expect(model.draft?.readOnlyReason == .occurrence)
    }

    @Test func anyAndNoneModeRulesWithFixedFieldsStayEditable() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let any = headerRule("any", mode: .any), none = headerRule("none", order: 1, mode: .none)
        let (model, _) = try await loadedModel(fixture, rules: [any, none])
        #expect(!model.isReadOnly(any.id) && !model.isReadOnly(none.id))
        model.requestSelection(none.id)
        #expect(model.draft?.matchMode == ConditionGroup.Mode.none && model.draft?.readOnlyReason == nil)
    }

    // MARK: no way to save one

    @Test func readOnlyRuleCannotBeSavedThroughDraft() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let multi = multiActionRule("multi")
        let saves = CallCounter()
        let (model, _) = try await loadedModel(fixture, rules: [multi], saves: saves)
        let stored = try Data(contentsOf: fixture.configFile)

        // The draft refuses to produce a rule, whatever its fields say.
        let draft = RuleEditorDraft(rule: multi, asset: nil)
        let result = draft.validate(order: 0, limits: RulesLimits())
        #expect(result.rule == nil && result.issues == [.name: .unsupportedStructure])

        model.requestSelection(multi.id)
        // Edits are ignored, so the draft cannot become dirty either.
        var edited = try #require(model.draft)
        edited.name = "renamed"
        edited.matchMode = .any
        model.setDraft(edited)
        #expect(model.draft?.name == "multi" && model.draft?.matchMode == .all && !model.isDraftDirty)
        #expect(await model.save() == false)
        #expect(saves.value == 0)
        #expect(model.revision == 1 && model.rules == [multi])
        #expect(try Data(contentsOf: fixture.configFile) == stored)
    }

    @Test func externalWriterCannotSaveAReadOnlyDraft() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let multi = multiActionRule("multi")
        let saves = CallCounter()
        let (model, _) = try await loadedModel(fixture, rules: [multi], saves: saves)
        let outcome = await model.commitExternal(
            draft: RuleEditorDraft(rule: multi, asset: nil), isNew: false, allowEnabledRule: true)
        #expect(outcome == .invalid([.name: .unsupportedStructure]))
        #expect(saves.value == 0 && model.rules == [multi])
    }

    @Test func saveRefusesToOverwriteARuleThatBecameReadOnlyElsewhere() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let plain = headerRule("plain")
        _ = try await fixture.repository.load()
        _ = try await fixture.repository.save(groups: [], rules: [plain], expectedRevision: 0)
        let window = RulesEditorModel(client: fixture.client(), limits: RulesLimits())
        await window.load()
        window.requestSelection(plain.id)
        var edited = try #require(window.draft)
        edited.name = "edited"
        window.setDraft(edited)

        // Meanwhile another window gives the rule a second action.
        var several = plain
        several.actions.append(RuleAction(.rewriteStatus(RewriteStatusAction(status: 201))))
        _ = try await fixture.repository.save(groups: [], rules: [several], expectedRevision: 1)
        #expect(await window.save() == false && window.error == .conflict)
        #expect(window.conflict?.rules == [several], "the newer rules come from the published snapshot, whole")
        window.rebaseOnLatest()
        #expect(window.isReadOnly(plain.id) && window.rules == [several])

        // The form still shows the old single action; saving it would drop the second one.
        #expect(await window.save() == false)
        #expect(window.error == .conflict)
        #expect(fixture.repository.provider.current().rules == [several])
        #expect(fixture.repository.provider.current().revision == 2)

        // The same for a writer that read the rule before the change.
        window.discardChanges()
        let outcome = await window.commitExternal(draft: edited, isNew: false, allowEnabledRule: true)
        #expect(outcome == .conflict)
        #expect(fixture.repository.provider.current().rules == [several])
    }

    // MARK: what stays available

    @Test func duplicateKeepsEveryAction() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let multi = multiActionRule("multi"), after = headerRule("after", order: 1)
        let (model, live) = try await loadedModel(fixture, rules: [multi, after])

        // The copy of an editable rule is a draft; there is none for this one, so nothing happens there.
        model.duplicate(id: multi.id)
        #expect(model.draft == nil && live.repository.provider.current().revision == 1)

        #expect(await model.duplicateReadOnly(id: multi.id))
        let published = live.repository.provider.current()
        // Saved at once (there is no draft to hold it), right after its original, with every action.
        #expect(published.revision == 2 && published.rules.count == 3)
        #expect(published.rules.map(\.id).first == multi.id && published.rules.map(\.id).last == after.id)
        let copy = published.rules[1]
        #expect(copy.id != multi.id)
        #expect(copy.actions == multi.actions && copy.conditions == multi.conditions && copy.name == multi.name)
        #expect(copy.enabled == multi.enabled && copy.groupID == multi.groupID && copy.note == multi.note)
        #expect(model.rules == published.rules)
        #expect(model.isReadOnly(copy.id))
        #expect(await model.duplicateReadOnly(id: UUID()) == false)
        #expect(await model.duplicateReadOnly(id: after.id) == false, "an editable rule is copied as a draft")
        #expect(live.repository.provider.current().revision == 2)
    }

    @Test func duplicateOfAnEditableRuleStillMakesAnUnsavedDraft() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let plain = headerRule("plain")
        let (model, live) = try await loadedModel(fixture, rules: [plain])
        model.duplicate(id: plain.id)
        let copyID = try #require(model.draft?.id)
        #expect(copyID != plain.id && model.isDraftNew && model.selection == copyID)
        #expect(live.repository.provider.current().revision == 1, "nothing is saved until the user saves")
    }

    @Test func reorderKeepsGroupsAndNonSimpleRules() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let group = RuleGroup(id: UUID(), name: "Group", enabled: true, parentID: nil, order: 1)
        let a = headerRule("a", order: 0), multi = multiActionRule("multi", order: 2), b = headerRule("b", order: 3)
        var inGroup = headerRule("inGroup", order: 0)
        inGroup.groupID = group.id
        let saves = CallCounter()
        let (model, live) = try await loadedModel(fixture, groups: [group], rules: [a, multi, b, inGroup], saves: saves)
        #expect(model.groups == [group])

        // Evaluation: a, Group{inGroup}, multi, b. Moving b to the top must not move the group.
        #expect(await model.move(fromOffsets: IndexSet(integer: 2), toOffset: 0))
        var published = live.repository.provider.current()
        #expect(published.groups == [group])
        #expect(published.rules.map(\.name) == ["b", "a", "multi", "inGroup"])
        #expect(published.rules.first { $0.name == "multi" }?.actions == multi.actions)
        #expect(published.rules.first { $0.name == "inGroup" } == inGroup)
        #expect(published.evaluationOrder.map(\.name) == ["b", "inGroup", "a", "multi"])
        #expect(model.groups == [group] && model.rules == published.rules)

        #expect(await model.reorder(ids: [multi.id, inGroup.id, a.id, b.id]))
        published = live.repository.provider.current()
        #expect(published.groups == [group])
        #expect(published.rules.count == 4 && published.rules.contains { $0.actions == multi.actions })
        #expect(published.evaluationOrder.map(\.name) == ["multi", "inGroup", "a", "b"])
        #expect(saves.value == 2)
    }

    @Test func enableDisableAndDeleteWorkOnReadOnlyRules() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let multi = multiActionRule("multi"), other = headerRule("other", order: 1)
        let (model, live) = try await loadedModel(fixture, rules: [multi, other])

        #expect(await model.setEnabled(id: multi.id, enabled: false))
        var published = live.repository.provider.current()
        var expected = multi
        expected.enabled = false
        #expect(published.rules.first == expected, "only the switch changed")
        #expect(await model.setEnabled(id: multi.id, enabled: true))
        #expect(live.repository.provider.current().rules.first == multi)

        model.requestSelection(multi.id)
        #expect(await model.delete(id: multi.id))
        published = live.repository.provider.current()
        #expect(published.rules.map(\.id) == [other.id])
        #expect(model.selection == nil && model.draft == nil)
    }

    @Test func aReadOnlyRuleWithABreakpointCannotBeEnabledBeforeLiveBreakpoints() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        var paused = Rule(
            id: UUID(), name: "paused", enabled: false,
            conditions: ConditionGroup(rows: [ConditionRow(field: .host, op: .hostPattern, value: "a.test")]),
            actions: [
                RuleAction(.breakpoint(direction: .request, mode: .headers)),
                RuleAction(.rewriteStatus(RewriteStatusAction(status: 201))),
            ])
        paused.note = "kept"
        let saves = CallCounter()
        let (model, _) = try await loadedModel(fixture, rules: [paused], saves: saves)
        #expect(await model.setEnabled(id: paused.id, enabled: true) == false)
        #expect(model.error == .breakpointsUnavailable && saves.value == 0)
    }

    // MARK: what an editable save keeps

    @Test func saveKeepsGroupsAndNotice() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        // A schema 3 file whose first rule sends the traffic away from the host the second rule matches:
        // migrating it stores an upgrade notice.
        let remote = LegacyRule(
            id: UUID(), name: "remote", enabled: true, order: 0, matcher: RuleMatcher(hostPattern: "a.test"),
            action: .mapRemote(MapRemoteAction(targetScheme: "https", targetHost: "b.test", targetPort: 443, path: .preserve)))
        let lower = LegacyRule(
            id: UUID(), name: "lower", enabled: true, order: 1, matcher: RuleMatcher(hostPattern: "a.test"),
            action: .editHeaders(direction: .response, operations: [.set(name: "X-Lower", value: "1")]))
        try writeLegacyFile(fixture, rules: [remote, lower])
        let migrated = try await fixture.repository.load()
        let notice = try #require(migrated.migrationNotice, "the setup must produce a notice")
        let group = RuleGroup(id: UUID(), name: "Group", enabled: true, parentID: nil, order: 5)
        let multi = multiActionRule("multi", order: 6)
        let seeded = try await fixture.repository.save(
            groups: [group], rules: migrated.rules + [multi], expectedRevision: migrated.revision)
        #expect(seeded.migrationNotice == notice)

        let restarted = RulesFixture(root: fixture.root)
        let model = RulesEditorModel(client: restarted.client(), limits: RulesLimits())
        await model.load()
        #expect(model.groups == [group])
        model.requestSelection(lower.id)
        var draft = try #require(model.draft)
        draft.name = "lower, renamed"
        model.setDraft(draft)
        #expect(await model.save())

        let published = restarted.repository.provider.current()
        #expect(published.revision == seeded.revision + 1)
        #expect(published.groups == [group])
        #expect(published.migrationNotice == notice)
        #expect(published.rules.map(\.name) == ["remote", "lower, renamed", "multi"])
        #expect(published.rules.last == multi)
        // The saved file says the same.
        #expect(try await RulesFixture(root: fixture.root).repository.load() == published)
    }

    @Test func editingASimpleRuleKeepsItsGroupNoteAndStoredRows() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let group = RuleGroup(id: UUID(), name: "Group", enabled: true, parentID: nil, order: 0)
        // Rows in an order the old editor would not write, in a group, with a note.
        let stored = Rule(
            id: UUID(), name: "stored", groupID: group.id, order: 0,
            conditions: ConditionGroup(
                mode: .any,
                rows: [
                    ConditionRow(field: .host, op: .hostPattern, value: "a.test"),
                    ConditionRow(field: .scheme, op: .equals, value: "https"),
                ]),
            actions: [RuleAction(.rewriteStatus(RewriteStatusAction(status: 404)))], note: "keep me")
        let (model, live) = try await loadedModel(fixture, groups: [group], rules: [stored])

        model.requestSelection(stored.id)
        var draft = try #require(model.draft)
        #expect(draft.matchMode == .any && draft.readOnlyReason == nil)
        draft.name = "renamed"
        model.setDraft(draft)
        #expect(await model.save())
        var expected = stored
        expected.name = "renamed"
        #expect(live.repository.provider.current().rules == [expected])

        // Changing what the rule matches does rewrite the rows, still in its group with its note.
        draft = try #require(model.draft)
        draft.match.port = "8443"
        model.setDraft(draft)
        #expect(await model.save())
        let changed = try #require(live.repository.provider.current().rules.first)
        #expect(changed.groupID == group.id && changed.note == "keep me")
        #expect(changed.conditions.mode == .any)
        #expect(changed.conditions.rows.map(\.field) == [.scheme, .host, .port])
    }
}

/// A schema 3 `rules.json` as the version before rules 2.0 wrote it.
private func writeLegacyFile(_ fixture: RulesFixture, rules: [LegacyRule]) throws {
    struct LegacyFile: Encodable {
        var schemaVersion = 3
        var revision: UInt64 = 1
        var rules: [LegacyRule]
        var assets: [ManagedAsset] = []
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try FileManager.default.createDirectory(at: fixture.configDir, withIntermediateDirectories: true)
    try encoder.encode(LegacyFile(rules: rules)).write(to: fixture.configFile)
}
