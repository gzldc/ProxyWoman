import Foundation
import RulesEngine
import Testing

@testable import AppCore
@testable import Localization

@Suite(.productionChinese) struct RuleBuilderPresentationTests {
    @Test func builderSectionsListEveryOfferedActionTypeOnce() {
        let flat = ActionType.builderSections.flatMap { $0 }
        #expect(flat.count == ActionType.allCases.count - 2)
        #expect(Set(flat) == Set(ActionType.allCases).subtracting([.mapRemote, .returnDirectory]))
    }

    @Test func builderOrderStartsLikeTheReference() {
        let flat = ActionType.builderSections.flatMap { $0 }
        #expect(Array(flat.prefix(12)) == [
            .mark, .modifyURL, .modifyQuery, .rewriteStatus, .rewriteRequestBody, .rewriteResponseBody,
            .editRequestHeaders, .editResponseHeaders, .editRequestCookies, .editResponseCookies,
            .requestBreakpoint, .responseBreakpoint,
        ])
    }

    @Test func intrinsicallyFinalLocksStop() {
        let state = RuleBuilderPresentation.stopProcessing(for: ActionDraft(type: .returnPreset))
        #expect(state == .init(isOn: true, isLocked: true, reasonKey: "rules.builder.stop.lockedReason"))
    }

    @Test func ordinaryActionFollowsTick() {
        var draft = ActionDraft(type: .modifyURL)
        draft.isFinal = false
        #expect(RuleBuilderPresentation.stopProcessing(for: draft) == .init(isOn: false, isLocked: false, reasonKey: nil))
        draft.isFinal = true
        #expect(RuleBuilderPresentation.stopProcessing(for: draft) == .init(isOn: true, isLocked: false, reasonKey: nil))
    }

    @Test func zeroMatchesIsRed() throws {
        let line = try #require(RuleBuilderPresentation.matchCountLine(0))
        #expect(line.tone == .failure)
        #expect(line.text == L10n.format("rules.builder.matchCount", 0))
    }

    @Test func someMatchesIsGreen() throws {
        let line = try #require(RuleBuilderPresentation.matchCountLine(7))
        #expect(line.tone == .success)
        #expect(line.text == L10n.format("rules.builder.matchCount", 7))
    }

    @Test func unknownCountHasNoLine() {
        #expect(RuleBuilderPresentation.matchCountLine(nil) == nil)
    }

    @Test func sideDots() {
        #expect(RuleBuilderPresentation.dot(for: ActionType.Side.request) == .request)
        #expect(RuleBuilderPresentation.dot(for: ActionType.Side.response) == .response)
        #expect(RuleBuilderPresentation.dot(for: ActionType.Side.both) == .success)
        #expect(RuleBuilderPresentation.dot(for: ActionType.Side.none) == .success)
        #expect(RuleBuilderPresentation.dot(for: ConditionSide.request) == .request)
        #expect(RuleBuilderPresentation.dot(for: ConditionSide.response) == .response)
        #expect(RuleBuilderPresentation.dot(for: ConditionSide.both) == .success)
        #expect(RuleBuilderPresentation.dot(for: ConditionSide.neither) == .success)
    }

    @Test func anEmptyNameCanSaveBecauseItIsAutoNamed() {
        #expect(RuleBuilderPresentation.canSave(hasDocument: true, isBusy: false, isImporting: false))
        #expect(!RuleBuilderPresentation.canSave(hasDocument: false, isBusy: false, isImporting: false))
        #expect(!RuleBuilderPresentation.canSave(hasDocument: true, isBusy: true, isImporting: false))
    }

    @Test func caseSwitchOnlyForTextComparisons() {
        for op in [ConditionOperator.equals, .notEquals, .contains, .notContains, .startsWith, .endsWith, .regex] {
            #expect(RuleBuilderPresentation.supportsCaseSensitivity(input: .text, op: op))
        }
        #expect(!RuleBuilderPresentation.supportsCaseSensitivity(input: .text, op: .inRange))
        #expect(!RuleBuilderPresentation.supportsCaseSensitivity(input: .text, op: .isEmpty))
        #expect(!RuleBuilderPresentation.supportsCaseSensitivity(input: .number, op: .equals))
        #expect(!RuleBuilderPresentation.supportsCaseSensitivity(input: .date, op: .before))
        #expect(!RuleBuilderPresentation.supportsCaseSensitivity(input: .bool, op: .equals))
        #expect(!RuleBuilderPresentation.supportsCaseSensitivity(input: .none, op: .equals))
    }
}
