import FlowStore
import Foundation
import RulesEngine
import Testing

@testable import AppCore

private func rule(_ actions: [RuleAction]) -> Rule {
    Rule(
        name: "r", conditions: ConditionGroup(rows: [ConditionRow(field: .method, op: .equals, value: "GET")]),
        actions: actions)
}

private func saved(_ document: RuleDocument, limits: RulesLimits = RulesLimits()) -> Rule? {
    document.validate(limits: limits).rule
}

private func encoded(_ rule: Rule) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(rule)
}

// MARK: unedited multi-edit actions the form cannot show exactly (R8F2 T8 fix 2)

@Suite(.productionChinese) struct UneditedMultiEditTests {
    @Test func aQueryActionWithAnAllKeysReplaceComesBackUnedited() throws {
        // `name: ""` (not nil) is something the form reads as "all keys", so it builds nil.
        let action = RuleAction(
            .modifyQuery(
                QueryEditAction(operations: [
                    .findReplace(name: "", find: "a", replacement: "b", caseSensitive: true), .remove(name: "c"),
                ])))
        let original = rule([action])
        let document = RuleDocument(rule: original)
        #expect(document.actions.count == 2)
        let result = saved(document)
        #expect(result == original)
        #expect(try encoded(try #require(result)) == encoded(original))
    }

    @Test func aCookieActionWithAnAllKeysRegexComesBackUnedited() throws {
        let action = RuleAction(
            .editCookies(
                direction: .response,
                operations: [
                    .set(name: "a", value: "1"), .regex(name: "", pattern: "x", replacement: "y", caseSensitive: false),
                ]),
            isFinal: true)
        let original = rule([action])
        #expect(saved(RuleDocument(rule: original)) == original)
    }

    @Test func oneEditedCardOfAHeaderActionSavesTheOthersAsTheyWere() throws {
        let header = RuleAction(
            .editHeaders(
                direction: .request,
                operations: [.set(name: "A", value: "1"), .findReplace(name: "", find: "x", replacement: "y", caseSensitive: false), .remove(name: "C")]))
        var document = RuleDocument(rule: rule([header]))
        document.actions[0].headerRows[0].value = "2"
        let actions = try #require(saved(document)).actions
        #expect(
            actions == [
                RuleAction(.editHeaders(direction: .request, operations: [.set(name: "A", value: "2")])),
                RuleAction(
                    .editHeaders(
                        direction: .request, operations: [.findReplace(name: "", find: "x", replacement: "y", caseSensitive: false)])),
                RuleAction(.editHeaders(direction: .request, operations: [.remove(name: "C")])),
            ])
    }
}

// MARK: more edits than the action limit (R8F2 T8 fix 3)

@Suite(.productionChinese) struct LongStoredActionTests {
    private func longHeader(_ count: Int = 20) -> RuleAction {
        RuleAction(
            .editHeaders(direction: .request, operations: (0..<count).map { .set(name: "X-\($0)", value: "v\($0)") }),
            isFinal: true)
    }

    @Test func aTwentyEditActionOpensAsTwentyCardsAndSavesUneditedByteForByte() throws {
        let original = rule([RuleAction(.hide), longHeader()])
        let document = RuleDocument(rule: original)
        #expect(document.actions.count == 21)
        let validation = document.validate(limits: RulesLimits())
        #expect(validation.issues.isEmpty)
        let result = try #require(validation.rule)
        #expect(result == original)
        #expect(try encoded(result) == encoded(original))
    }

    @Test func editingOneCardMergesTheCardsBackIntoOneValidAction() throws {
        let original = rule([longHeader()])
        var document = RuleDocument(rule: original)
        document.actions[7].headerRows[0].value = "changed"
        let validation = document.validate(limits: RulesLimits())
        #expect(validation.issues.isEmpty)
        let result = try #require(validation.rule)
        #expect(result.actions.count == 1)
        guard case .editHeaders(let direction, let operations) = result.actions[0].kind else {
            Issue.record("not a header action")
            return
        }
        #expect(direction == .request && operations.count == 20 && result.actions[0].isFinal)
        #expect(operations[7] == .set(name: "X-7", value: "changed"))
        #expect(operations[6] == .set(name: "X-6", value: "v6") && operations[19] == .set(name: "X-19", value: "v19"))
        // It is a rule the engine accepts as it stands.
        try result.validate(limits: RulesLimits())
    }

    @Test func fewEditsStaySeparateActions() throws {
        var document = RuleDocument(rule: rule([longHeader(3)]))
        document.actions[1].headerRows[0].value = "changed"
        #expect(try #require(saved(document)).actions.count == 3)
    }

    @Test func cardsOfAnotherStoredActionOrTypeAreNotMerged() throws {
        // 17 cards of one header action plus 16 of another: merging inside each group still leaves two actions.
        let original = rule([longHeader(17), RuleAction(.editHeaders(direction: .response, operations: (0..<16).map { .remove(name: "R\($0)") }))])
        var document = RuleDocument(rule: original)
        document.actions[0].headerRows[0].value = "changed"
        let actions = try #require(saved(document)).actions
        #expect(actions.count == 2)
        #expect(actions.map(\.kind.direction) == [.request, .response])
    }

    @Test func tooManyCardsThatCannotMergeStillReportTheLimit() {
        var document = RuleDocument(newIn: nil)
        document.name = "r"
        document.actions = (0..<17).map { _ in ActionDraft(type: .hide) }
        #expect(document.validate(limits: RulesLimits()).issues[.actions] == .tooManyActions)
    }

    @Test func aGroupWithATickedMiddleCardKeepsTheTick() throws {
        let original = rule([longHeader(18)])
        var document = RuleDocument(rule: original)
        document.actions[5].isFinal = true
        document.actions[2].headerRows[0].value = "changed"
        let result = try #require(saved(document))
        // The tick of a card that is not last in its run stops the merge there: two actions, each with its tick.
        #expect(result.actions.count == 2)
        #expect(result.actions[0].isFinal && result.actions[1].isFinal)
    }
}

// MARK: the key's "Aa" (R8F2 T8 fix 4)

@Suite(.productionChinese) struct KeyCaseTests {
    @Test func headerCookieAndQueryCardsShowTheKeyCaseSwitch() {
        for type in [ActionType.editRequestHeaders, .editResponseHeaders, .editRequestCookies, .editResponseCookies, .modifyQuery] {
            let descriptor = ActionEditorDescriptor(draft: ActionDraft(type: type))
            #expect(descriptor.showsKeyCase, "\(type)")
        }
        for type in [ActionType.comment, .modifyURL, .mark, .rewriteRequestBody, .delay] {
            #expect(!ActionEditorDescriptor(draft: ActionDraft(type: type)).showsKeyCase, "\(type)")
        }
    }

    @Test func aNewCardStartsWithTheSwitchOffAndWritesIt() throws {
        for type in [ActionType.editRequestHeaders, .editRequestCookies, .modifyQuery] {
            var document = RuleDocument(newIn: nil)
            document.addAction(type)
            let card = document.actions[0]
            #expect(card.keyCaseOn == false, "\(type)")
            #expect(ActionEditorDescriptor(draft: card).keyCaseOn == false)
            var filled = card
            switch type {
            case .editRequestHeaders: filled.headerRows[0].name = "X-A"; filled.headerRows[0].value = "1"
            case .editRequestCookies: filled.cookieRows[0].name = "a"; filled.cookieRows[0].value = "1"
            default: filled.queryRows[0].name = "a"; filled.queryRows[0].value = "1"
            }
            let built = try #require(filled.build().action)
            switch built.kind {
            case .editHeaders(_, let operations): #expect(operations == [.set(name: "X-A", value: "1", nameCaseSensitive: false)])
            case .editCookies(_, let operations): #expect(operations == [.set(name: "a", value: "1", nameCaseSensitive: false)])
            case .modifyQuery(let edit): #expect(edit.operations == [.set(name: "a", value: "1", nameCaseSensitive: false)])
            default: Issue.record("unexpected \(built.kind)")
            }
        }
    }

    @Test func changingAFreshCardToAKeyTypeAlsoStartsOff() {
        var document = RuleDocument(startingIn: nil)  // a mark card
        document.changeType(of: document.actions[0].id, to: .modifyQuery)
        #expect(document.actions[0].keyCaseOn == false)
    }

    @Test func aSavedLegacyCardShowsTheOriginalBehaviourAndWritesNothingNew() throws {
        let stored = [
            RuleAction(.editHeaders(direction: .request, operations: [.set(name: "A", value: "1")])),
            RuleAction(.modifyQuery(QueryEditAction(operations: [.remove(name: "q")]))),
            RuleAction(.editCookies(direction: .request, operations: [.remove(name: "c")])),
        ]
        let original = rule(stored)
        let document = RuleDocument(rule: original)
        // header names ignore case, query and cookie names do not
        #expect(document.actions.map(\.keyCaseOn) == [false, true, true])
        #expect(try #require(saved(document)).actions == stored)
        for card in document.actions { #expect(card.build().action != nil) }
        #expect(try encoded(try #require(saved(document))) == encoded(original))
        // Not touched, so the form still reads nil.
        #expect(document.actions[1].queryRows[0].nameCaseSensitive == nil)
    }

    @Test func flippingTheSwitchWritesTheChoice() throws {
        var document = RuleDocument(rule: rule([RuleAction(.modifyQuery(QueryEditAction(operations: [.remove(name: "q")])))]))
        document.actions[0].setKeyCase(false)
        #expect(document.actions[0].keyCaseOn == false)
        #expect(
            try #require(saved(document)).actions
                == [RuleAction(.modifyQuery(QueryEditAction(operations: [.remove(name: "q", nameCaseSensitive: false)])))])
        document.actions[0].setKeyCase(true)
        #expect(
            try #require(saved(document)).actions
                == [RuleAction(.modifyQuery(QueryEditAction(operations: [.remove(name: "q", nameCaseSensitive: true)])))])
    }

    @Test func theFlagSurvivesOpenAndSave() throws {
        let stored = [
            RuleAction(.editHeaders(direction: .response, operations: [.set(name: "A", value: "1", nameCaseSensitive: true)])),
            RuleAction(.editCookies(direction: .request, operations: [.findReplace(name: "c", find: "a", replacement: "b", caseSensitive: true, nameCaseSensitive: false)])),
        ]
        let original = rule(stored)
        let document = RuleDocument(rule: original)
        #expect(document.actions.map(\.keyCaseOn) == [true, false])
        #expect(saved(document) == original)
        // And through an edit of the neighbouring text.
        var edited = document
        edited.actions[1].cookieRows[0].value = "z"
        let actions = try #require(saved(edited)).actions
        #expect(actions[0] == stored[0])
        #expect(actions[1] == RuleAction(.editCookies(direction: .request, operations: [.findReplace(name: "c", find: "z", replacement: "b", caseSensitive: true, nameCaseSensitive: false)])))
    }

    @Test func aFlaggedRuleStillValidatesAndRoundTripsThroughJSON() throws {
        let flagged = rule([RuleAction(.editHeaders(direction: .request, operations: [.remove(name: "A", nameCaseSensitive: true)]))])
        try flagged.validate(limits: RulesLimits())
        let data = try encoded(flagged)
        #expect(try JSONDecoder().decode(Rule.self, from: data) == flagged)
    }
}

// MARK: magic strings at the CONNECT point (R8F2 T8 fix 5)

@Suite(.productionChinese) struct MagicStringConnectTests {
    private func connectOnlyDocument(_ cards: [ActionDraft]) -> RuleDocument {
        var document = RuleDocument(newIn: nil)
        document.conditions.addRow()
        document.conditions.rows[0].setField(.host)
        document.actions = cards
        return document
    }

    private func magic(_ text: String) -> ActionDraft {
        var card = ActionDraft(type: .magicString)
        card.magicText = text
        return card
    }

    @Test func aMagicStringTakesTheTraitsOfWhatItResolvesTo() {
        #expect(magic("*ReplyWithTunnel").traits == ActionType.Traits(isConnectOnly: true, canRunAtConnect: true, isAnnotation: false))
        #expect(magic("*drop").traits.canRunAtConnect && !magic("*drop").traits.isConnectOnly)
        #expect(!magic("*delay:100").traits.canRunAtConnect)
        #expect(!magic("").traits.canRunAtConnect)
        #expect(magic("*exit").traits.isAnnotation)
    }

    @Test func aTunnelStringBesideARequestSideCardIsFlagged() {
        var document = RuleDocument(newIn: nil)
        document.conditions.addRow()
        document.conditions.rows[0].setField(.url)
        document.actions = [magic("*ReplyWithTunnel"), ActionDraft(type: .modifyURL)]
        // Both cards are blocked from each other: the string is connect-only, the other cannot run at the CONNECT.
        let analysis = document.cardAnalysis()
        #expect(analysis.states.contains(.blocked(.connectOnlyMixed)))
    }

    @Test func aTunnelStringAtTheRequestPointNeedsConnectConditions() {
        var document = RuleDocument(newIn: nil)
        document.conditions.addRow()
        document.conditions.rows[0].setField(.method)
        document.actions = [magic("*ReplyWithTunnel")]
        #expect(document.cardAnalysis().states == [.blocked(.needsConnectPointConditions)])
    }

    @Test func aDropStringIsFineBesideAMarkAtTheConnectPoint() {
        let document = connectOnlyDocument([magic("*drop"), ActionDraft(type: .mark)])
        #expect(!document.cardAnalysis().states.contains { if case .blocked = $0 { true } else { false } })
    }

    @Test func aSiblingMagicStringTunnelBlocksAPlainRequestCardThroughTheDocument() {
        let document = connectOnlyDocument([magic("*ReplyWithTunnel")])
        #expect(document.availability(of: .modifyURL, replacing: nil) == .unavailable(.connectOnlyMixed))
        #expect(document.availability(of: .mark, replacing: nil) == .available)
        let plain = connectOnlyDocument([magic("*delay:5")])
        #expect(plain.availability(of: .noDecrypt, replacing: nil) == .unavailable(.connectOnlyMixed))
    }
}
