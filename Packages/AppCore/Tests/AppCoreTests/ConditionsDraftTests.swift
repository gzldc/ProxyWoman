import Foundation
import RulesEngine
import Testing

@testable import AppCore

@Suite(.productionChinese) struct ConditionsDraftTests {
    private func row(_ draft: ConditionsDraft, _ index: Int) -> ConditionRowDraft { draft.rows[index] }

    @Test func changingFieldCoercesTheOperator() {
        var row = ConditionRowDraft(row: ConditionRow(field: .statusCode, op: .contains, value: "20"))
        row.setField(.host)
        #expect(row.op == .contains)
        #expect(row.row.validationIssue(limits: RulesLimits()) == nil)
        row.setField(.sessionState)
        #expect(row.op == .equals)
        #expect(row.value == "opened")
        #expect(row.row.validationIssue(limits: RulesLimits()) == nil)
    }

    @Test func nameFieldsGetDefaultNames() {
        var row = ConditionRowDraft(row: ConditionRow(field: .url, op: .contains))
        // The process field has no sub-key any more; a certificate row starts on its friendly name.
        row.setField(.clientApp)
        #expect(row.name.isEmpty)
        row.setField(.certificate)
        #expect(row.name == "friendlyName")
        row.setField(.requestHeader)
        #expect(row.name.isEmpty)
    }

    @Test func nonNameFieldsDropTheName() {
        var row = ConditionRowDraft(row: ConditionRow(field: .requestHeader, name: "X-Test", op: .equals, value: "1"))
        row.setField(.host)
        #expect(row.name.isEmpty)
        #expect(row.row.name == nil)
        #expect(row.row.validationIssue(limits: RulesLimits()) == nil)
    }

    @Test func emptyOperatorsHideTheValue() {
        var row = ConditionRowDraft(row: ConditionRow(field: .host, op: .equals, value: "a.com"))
        #expect(row.showsValue)
        row.setOperator(.isEmpty)
        #expect(!row.showsValue)
        #expect(row.value.isEmpty)
        row.setOperator(.isNotEmpty)
        #expect(!row.showsValue)
        row.setOperator(.contains)
        #expect(row.showsValue)
    }

    @Test func allSessionsHasNoOperatorAndNoValue() {
        var row = ConditionRowDraft(row: ConditionRow(field: .host, op: .equals, value: "a.com"))
        row.setField(.allSessions)
        #expect(!row.showsValue)
        #expect(ConditionOperator.allowed(for: .allSessions, name: nil).isEmpty)
        #expect(row.row.validationIssue(limits: RulesLimits()) == nil)
    }

    @Test func addRowAfterInsertsAtThePosition() {
        var draft = ConditionsDraft()
        draft.addRow()
        draft.addRow()
        let first = draft.rows[0].id
        draft.addRow(after: first)
        #expect(draft.rows.count == 3)
        #expect(draft.rows[0].id == first)
        #expect(draft.rows[1].id != draft.rows[2].id)
        #expect(draft.rows[1].field == .url && draft.rows[1].op == .contains)
        let middle = draft.rows[1].id
        draft.duplicateRow(middle)
        #expect(draft.rows.count == 4)
        #expect(draft.rows[2].id != middle && draft.rows[2].row == draft.rows[1].row)
        draft.removeRow(middle)
        #expect(draft.rows.count == 3 && !draft.rows.contains { $0.id == middle })
    }

    @Test func theLastRemainingRowIsNeverRemoved() {
        var draft = ConditionsDraft()
        draft.addRow()
        let only = draft.rows[0].id
        draft.removeRow(only)
        #expect(draft.rows.count == 1 && draft.rows[0].id == only)
        draft.addRow()
        draft.removeRow(only)
        #expect(draft.rows.count == 1 && draft.rows[0].id != only)
    }

    @Test func rowLimitIs32() {
        var draft = ConditionsDraft()
        for _ in 0..<32 { draft.addRow() }
        #expect(draft.validate(limits: RulesLimits())[ConditionsDraft.groupIssueID] == nil)
        draft.addRow()
        let issues = draft.validate(limits: RulesLimits())
        #expect(issues[ConditionsDraft.groupIssueID] == .tooManyConditions)
        #expect(issues.count == 1)
    }

    @Test func judgmentPointFollowsTheLatestRow() {
        var draft = ConditionsDraft()
        #expect(draft.judgmentPoint == .connect && !draft.isCompletionJudged)
        draft = ConditionsDraft(group: ConditionGroup(rows: [ConditionRow(field: .url, op: .contains, value: "a")]))
        #expect(draft.judgmentPoint == .connect)
        draft = ConditionsDraft(group: ConditionGroup(rows: [ConditionRow(field: .statusCode, op: .equals, value: "200")]))
        #expect(draft.judgmentPoint == .response)
        draft = ConditionsDraft(group: ConditionGroup(rows: [
            ConditionRow(field: .url, op: .contains, value: "a"),
            ConditionRow(field: .durationMs, op: .greaterThan, value: "5"),
        ]))
        #expect(draft.judgmentPoint == .completion && draft.isCompletionJudged)
        draft = ConditionsDraft(group: ConditionGroup(rows: [ConditionRow(field: .appProtocol, op: .equals, value: "sse")]))
        #expect(draft.judgmentPoint == .response)
    }

    @Test func legacyRowsRoundTripUnchanged() {
        let originals = [
            ConditionRow(field: .host, op: .hostPattern, value: "*.example.com"),
            ConditionRow(field: .pathAndQuery, op: .wildcard, value: "/a/*", caseSensitive: true),
            ConditionRow(field: .pathAndQuery, op: .regexWhole, value: "/a/.*", caseSensitive: true),
        ]
        for original in originals {
            let draft = ConditionRowDraft(row: original)
            #expect(draft.isLegacyShape)
            #expect(draft.row == original)
        }
        #expect(!ConditionRowDraft(row: ConditionRow(field: .host, op: .equals, value: "a")).isLegacyShape)
        let group = ConditionGroup(mode: .any, occurrence: .times(2...5), rows: originals)
        #expect(ConditionsDraft(group: group).conditionGroup() == group)
    }

    @Test func specificOccurrenceSavesFirstN() {
        var draft = ConditionsDraft()
        draft.occurrence.setSpecific(true)
        draft.occurrence.setCountText("5")
        #expect(draft.occurrenceIssue() == nil)
        #expect(draft.conditionGroup()?.occurrence == .times(1...5))
        draft.occurrence.setCountText(" 1 ")
        #expect(draft.conditionGroup()?.occurrence == .times(1...1))
        draft.occurrence.setCountText("9999")
        #expect(draft.conditionGroup()?.occurrence == .times(1...9999))
    }

    @Test func specificOccurrenceValidatesN() {
        var draft = ConditionsDraft()
        draft.occurrence.setSpecific(true)
        for text in ["0", "-1", "10000", "", "1.5"] {
            draft.occurrence.setCountText(text)
            #expect(draft.occurrenceIssue() != nil, "\(text)")
            #expect(draft.conditionGroup() == nil, "\(text)")
        }
        draft.occurrence.setCountText("a")
        #expect(draft.occurrenceIssue() == .notANumber)
        draft.occurrence.setCountText("0")
        #expect(draft.occurrenceIssue() == .invalidConditionValue)
        // "any" ignores whatever the count field holds.
        draft.occurrence.setSpecific(false)
        #expect(draft.occurrenceIssue() == nil)
        #expect(draft.conditionGroup()?.occurrence == .any)
    }

    @Test func choiceMapsToAndFromOccurrence() {
        #expect(OccurrenceChoice(.any) == .any)
        #expect(OccurrenceChoice(.times(1...4)) == .specific(4))
        #expect(OccurrenceChoice(.times(3...5)) == .specific(5))
        #expect(OccurrenceChoice.any.occurrence == .any)
        #expect(OccurrenceChoice.specific(7).occurrence == .times(1...7))
        #expect(OccurrenceChoice.specific(0).occurrence == nil)
        #expect(OccurrenceChoice.specific(OccurrenceChoice.maxCount + 1).occurrence == nil)
        for occurrence in [Occurrence.any, .times(1...1), .times(1...12)] {
            #expect(OccurrenceChoice(occurrence).occurrence == occurrence)
        }
    }

    @Test func untouchedLegacyRangeIsKeptAndEditingRewritesIt() {
        let group = ConditionGroup(occurrence: .times(3...5))
        var draft = ConditionsDraft(group: group)
        #expect(draft.occurrence.isSpecific && draft.occurrence.countText == "5")
        #expect(draft.conditionGroup() == group)
        // Switching to any and back, or re-typing the same text, keeps the range.
        draft.occurrence.setSpecific(false)
        draft.occurrence.setSpecific(true)
        draft.occurrence.setCountText("5")
        #expect(draft.conditionGroup()?.occurrence == .times(3...5))
        draft.occurrence.setCountText("4")
        #expect(draft.conditionGroup()?.occurrence == .times(1...4))
        draft.occurrence.setCountText("5")
        #expect(draft.conditionGroup()?.occurrence == .times(1...5))
    }

    @Test func trailingSpaceKeepsThePreservedRange() {
        var draft = ConditionsDraft(group: ConditionGroup(occurrence: .times(3...5)))
        draft.occurrence.setCountText("5 ")
        #expect(draft.conditionGroup()?.occurrence == .times(3...5))
        #expect(draft.occurrence.preservedLegacyRange == 3...5)
        draft.occurrence.setCountText(" 6")
        #expect(draft.conditionGroup()?.occurrence == .times(1...6))
        #expect(draft.occurrence.preservedLegacyRange == nil)
        #expect(ConditionsDraft(group: ConditionGroup(occurrence: .times(1...5))).occurrence.preservedLegacyRange == nil)
    }

    @Test func loadedOccurrenceRoundTrips() {
        for occurrence in [Occurrence.any, .times(1...1), .times(1...6), .times(2...9)] {
            let group = ConditionGroup(occurrence: occurrence)
            #expect(ConditionsDraft(group: group).conditionGroup() == group)
        }
        #expect(ConditionsDraft(group: ConditionGroup(occurrence: .times(1...3))).occurrence.choice == .specific(3))
    }

    @Test func conditionGroupIsNilWhileAnyRowIsInvalid() {
        var draft = ConditionsDraft(group: ConditionGroup(rows: [ConditionRow(field: .statusCode, op: .equals, value: "200")]))
        #expect(draft.conditionGroup()?.rows.count == 1)
        draft.addRow()
        draft.rows[1].value = "x"
        #expect(draft.conditionGroup() != nil)
        draft.rows[1].setField(.requestHeader)
        draft.rows[1].setOperator(.regex)
        draft.rows[1].value = "("
        #expect(draft.conditionGroup() == nil)
    }

    @Test func validateMapsEngineCodesToIssues() {
        let draft = ConditionsDraft(group: ConditionGroup(rows: [
            ConditionRow(field: .queryParam, op: .equals, value: "1"),
            ConditionRow(field: .url, op: .regex, value: "("),
            ConditionRow(field: .durationMs, op: .greaterThan, value: "abc"),
            ConditionRow(field: .url, op: .inRange, value: "1-2"),
            ConditionRow(field: .url, name: "n", op: .equals, value: "a"),
            ConditionRow(field: .certificate, name: "bogus", op: .equals, value: "a"),
            ConditionRow(field: .host, op: .equals, value: "a"),
        ]))
        let issues = draft.validate(limits: RulesLimits())
        let ids = draft.rows.map(\.id)
        #expect(issues[ids[0]] == .conditionNameRequired)
        #expect(issues[ids[1]] == .invalidRegex)
        #expect(issues[ids[2]] == .invalidConditionValue)
        #expect(issues[ids[3]] == .invalidOperator)
        #expect(issues[ids[4]] == .unexpectedConditionName)
        #expect(issues[ids[5]] == .invalidConditionName)
        #expect(issues[ids[6]] == nil)
        #expect(issues.count == 6)
    }

    @Test func legacyRowsValidateOnTheOldPath() {
        let draft = ConditionsDraft(group: ConditionGroup(rows: [
            ConditionRow(field: .host, op: .hostPattern, value: "*.example.com"),
            ConditionRow(field: .port, op: .equals, value: "99999"),
        ]))
        let issues = draft.validate(limits: RulesLimits())
        #expect(issues[draft.rows[0].id] == nil)
        #expect(issues[draft.rows[1].id] == .invalidPort)
    }
}

@Suite(.productionChinese) struct ConditionFieldMenuTests {
    private static let oldStyle: Set<ConditionField> = [.port, .queryString, .queryParam, .pathAndQuery]

    @Test func menuCoversEveryFieldExactlyOnce() {
        let listed = ConditionFieldCatalog.menuSections.flatMap(\.entries).map(\.field)
        #expect(listed.count == Set(listed).count)
        #expect(Set(listed) == Set(ConditionField.allCases).subtracting(Self.oldStyle))
        #expect(ConditionFieldCatalog.menuSections.map(\.kind) == [.request, .response, .other])
    }

    @Test func everyFieldKnownOnlyAfterCompletionIsInTheMenu() {
        let listed = Set(ConditionFieldCatalog.menuSections.flatMap(\.entries).map(\.field))
        let completion = ConditionField.allCases.filter { $0.knowablePoint == .completion }
        #expect(!completion.isEmpty)
        #expect(listed.isSuperset(of: completion))
    }
}
