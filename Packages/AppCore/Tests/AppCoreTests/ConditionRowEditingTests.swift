import Foundation
import RulesEngine
import Testing

@testable import AppCore

@Suite(.productionChinese) struct ConditionRowEditingTests {
    private func row(_ field: ConditionField, name: String? = nil, op: ConditionOperator = .contains, value: String = "") -> ConditionRowDraft {
        ConditionRowDraft(row: ConditionRow(field: field, name: name, op: op, value: value))
    }

    @Test func plainEntriesAreSelectedByTheirComparison() {
        var draft = row(.url)
        let items = draft.descriptor().operatorControl.items
        let contains = items.first { $0.op == .contains }!
        let equals = items.first { $0.op == .equals }!
        #expect(draft.isSelected(contains) && !draft.isSelected(equals))
        draft.select(equals)
        #expect(draft.op == .equals && draft.isSelected(equals) && !draft.isSelected(contains))
    }

    @Test func pickingAComparisonWithoutAValueClearsTheValue() {
        var draft = row(.url, value: "abc")
        let empty = draft.descriptor().operatorControl.items.first { $0.op == .isEmpty }!
        draft.select(empty)
        #expect(draft.op == .isEmpty && draft.value.isEmpty)
    }

    @Test func validityEntriesShareEqualsAndDifferByValue() {
        var draft = row(.certificate, name: CertificateField.validity.rawValue, op: .equals, value: "valid")
        let items = draft.descriptor().operatorControl.items
        #expect(items.count == 2)
        let valid = items.first { $0.value == "valid" }!
        let invalid = items.first { $0.value == "invalid" }!
        #expect(draft.isSelected(valid) && !draft.isSelected(invalid))
        draft.select(invalid)
        #expect(draft.op == .equals && draft.value == "invalid" && draft.isSelected(invalid) && !draft.isSelected(valid))
    }

    @Test func suggestionsFilterByTypedTextKeepingOrder() {
        let all = ["Accept", "Accept-Language", "Content-Type", "accept-encoding"]
        #expect(ConditionSuggestions.matching(all, typed: "acc", limit: 10) == ["Accept", "Accept-Language", "accept-encoding"])
        #expect(ConditionSuggestions.matching(all, typed: "Accept", limit: 10) == ["Accept-Language", "accept-encoding"])
        #expect(ConditionSuggestions.matching(all, typed: "", limit: 2) == ["Accept", "Accept-Language"])
        #expect(ConditionSuggestions.matching(all, typed: "zzz", limit: 10).isEmpty)
        #expect(ConditionSuggestions.matching(all, typed: "a", limit: 0).isEmpty)
    }
}
