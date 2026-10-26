import Foundation
import RulesEngine
import Testing

@testable import AppCore

@Suite(.productionChinese) struct ActionFormPresentationTests {
    @Test func headerMethodsShowOnlyTheInputsTheyUse() {
        #expect(HeaderMethod.set.inputs == RowInputs(value: true, replacement: false, caseSensitive: false))
        #expect(HeaderMethod.appendToValue.inputs == RowInputs(value: true, replacement: false, caseSensitive: false))
        #expect(HeaderMethod.remove.inputs == RowInputs(value: false, replacement: false, caseSensitive: false))
        #expect(HeaderMethod.findReplace.inputs == RowInputs(value: true, replacement: true, caseSensitive: true))
        #expect(HeaderMethod.regex.inputs == RowInputs(value: true, replacement: true, caseSensitive: true))
        #expect(HeaderMethod.regex.inputs.valueIsFind)
        #expect(!HeaderMethod.set.inputs.valueIsFind)
    }

    @Test func queryAndCookieMethodsFollowTheSameShape() {
        #expect(QueryMethod.add.inputs == RowInputs(value: true, replacement: false, caseSensitive: false))
        #expect(QueryMethod.remove.inputs.value == false)
        #expect(QueryMethod.findReplace.inputs.replacement)
        #expect(CookieMethod.addIfMissing.inputs.value)
        #expect(!CookieMethod.addIfMissing.inputs.replacement)
        #expect(CookieMethod.remove.inputs == RowInputs(value: false, replacement: false, caseSensitive: false))
        #expect(CookieMethod.regex.inputs.caseSensitive)
        // An empty key means every key, except where a field is created.
        #expect(QueryMethod.findReplace.allowsEmptyName && QueryMethod.set.allowsEmptyName && QueryMethod.remove.allowsEmptyName)
        #expect(CookieMethod.regex.allowsEmptyName && CookieMethod.appendToValue.allowsEmptyName)
        #expect(!QueryMethod.addIfMissing.allowsEmptyName && !QueryMethod.add.allowsEmptyName)
        #expect(HeaderMethod.findReplace.allowsEmptyName && HeaderMethod.remove.allowsEmptyName)
        #expect(!HeaderMethod.addIfMissing.allowsEmptyName && !HeaderMethod.append.allowsEmptyName)
        #expect(!CookieMethod.addIfMissing.allowsEmptyName)
    }

    @Test func presetInputsFollowThePreset() {
        #expect(PresetInputs(.found302) == PresetInputs(location: true, challenge: false, body: false))
        #expect(PresetInputs(.unauthorized401) == PresetInputs(location: false, challenge: true, body: true))
        #expect(PresetInputs(.proxyAuthRequired407).challenge)
        #expect(PresetInputs(.notFound404) == PresetInputs(location: false, challenge: false, body: true))
        #expect(PresetInputs(.noContent204) == PresetInputs(location: false, challenge: false, body: false))
    }

    @Test func handwrittenCounterCountsUTF8Bytes() {
        #expect(HandwrittenCounter.bytes("abc") == 3)
        #expect(HandwrittenCounter.bytes("é") == 2)
        #expect(HandwrittenCounter.isOver("aaa", limit: 2))
        #expect(!HandwrittenCounter.isOver("aa", limit: 2))
    }

    @Test func theMenuIsTheCatalogGroupedAndEveryOfferedTypeOnce() {
        let sections = ActionMenuPresentation.sections { _ in .available }
        #expect(sections.count == 12)
        #expect(sections.map { $0.items.map(\.type) } == ActionCatalog.menuGroups.map { $0.map(\.type) })
        #expect(sections.flatMap(\.items).map(\.direction) == ActionCatalog.menuGroups.flatMap { $0.map(\.direction) })
    }

    @Test func unavailableItemsKeepTheirReason() {
        let sections = ActionMenuPresentation.sections { $0 == .delay ? .unavailable(.onlyAnnotationAtCompletion) : .available }
        let items = sections.flatMap(\.items).filter { $0.type == .delay }
        #expect(items.count == 1)
        #expect(items.allSatisfy { $0.reason == .onlyAnnotationAtCompletion && !$0.isAvailable })
        #expect(sections.flatMap(\.items).filter { $0.type == .mark }.allSatisfy { $0.isAvailable })
    }

    @Test func aNewCardIsAMarkWithBothColoursUnchanged() {
        var document = RuleDocument(newIn: nil)
        #expect(ActionMenuPresentation.defaultNewType == .mark)
        document.conditions.addRow()
        document.conditions.rows[0].setField(.statusCode)
        #expect(ActionMenuPresentation.defaultNewType == .mark)
        let card = ActionDraft(type: .mark)
        #expect(card.mark.backgroundChoice == .unchanged && card.mark.foregroundChoice == .unchanged)
        #expect(card.build().action == RuleAction(.mark(MarkAction(background: ""))))
    }
}

@Suite(.productionChinese) struct ActionFormTitleKeyTests {
    @Test func bodyOperationsAndSidesHaveTheirKeys() {
        #expect(BodyRewriteOperation.allCases.map(\.titleKey) == ["rules.bodyOperation.findReplace", "rules.bodyOperation.setValue", "rules.bodyOperation.clear"])
        #expect(ActionType.Side.none.titleKey == "rules.side.neither")
        #expect(ActionType.hide.side.titleKey == "rules.side.neither")
    }
}
