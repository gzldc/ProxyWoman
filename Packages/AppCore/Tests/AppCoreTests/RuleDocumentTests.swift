import FlowStore
import Foundation
import Localization
import RulesEngine
import Testing

@testable import AppCore

@Suite(.productionChinese) struct RuleDocumentTests {
    private let limits = RulesLimits()

    private func conditions(_ rows: [ConditionRow], mode: ConditionGroup.Mode = .all) -> ConditionsDraft {
        ConditionsDraft(group: ConditionGroup(mode: mode, rows: rows))
    }

    /// A document with one filled-in card per type given, judged by `rows`.
    private func document(_ types: [ActionType], rows: [ConditionRow] = [], finals: Set<ActionType> = []) -> RuleDocument {
        var doc = RuleDocument(newIn: nil)
        doc.name = "r"
        doc.conditions = conditions(rows)
        for type in types {
            doc.addAction(type)
            doc.actions[doc.actions.count - 1] = Self.filled(type, final: finals.contains(type), id: doc.actions[doc.actions.count - 1].id)
        }
        return doc
    }

    /// A card of `type` whose form is complete.
    private static func filled(_ type: ActionType, final: Bool = false, id: UUID) -> ActionDraft {
        var card = ActionDraft(type: type, id: id)
        card.isFinal = final
        card.url.replacement = "https://b.test/"
        card.queryRows = [QueryEditRow(method: .set, name: "a", value: "1")]
        card.cookieRows = [CookieEditRow(method: .set, name: "a", value: "1")]
        card.headerRows = [HeaderEditRow(method: .set, name: "X-A", value: "1")]
        card.body = BodyEditDraft(find: "a", replacement: "b")
        card.remote.targetHost = "b.test"
        card.status.status = "503"
        card.delayText = "10"
        card.file.asset = ManagedAsset(id: UUID(), size: 3, displayName: "f.txt", importedAt: Date(timeIntervalSince1970: 1))
        card.directory.bookmark = Data([1, 2])
        card.directory.displayName = "d"
        card.directoryPrefix = "/d/"
        return card
    }

    private func kindName(_ kind: ActionKind) -> String {
        switch kind {
        case .returnFile: "returnFile"
        case .returnDirectory: "returnDirectory"
        case .mapRemote: "mapRemote"
        case .editHeaders: "editHeaders"
        case .breakpoint: "breakpoint"
        case .rewriteBody: "rewriteBody"
        case .rewriteStatus: "rewriteStatus"
        case .mark: "mark"
        case .comment: "comment"
        case .hide: "hide"
        case .modifyURL: "modifyURL"
        case .modifyQuery: "modifyQuery"
        case .editCookies: "editCookies"
        case .delay: "delay"
        case .returnHandwritten: "returnHandwritten"
        case .returnPreset: "returnPreset"
        case .closeConnection: "closeConnection"
        case .returnConnectTunnel: "returnConnectTunnel"
        case .noDecrypt: "noDecrypt"
        case .magicString: "magicString"
        }
    }

    // MARK: lossless round trip (Review Focus 4)

    private static let everyKind: [RuleAction] = [
        RuleAction(.modifyURL(URLEditAction(mode: .set, replacement: "https://b.test/"))),
        RuleAction(.modifyURL(URLEditAction(mode: .regex, find: "a+", replacement: "b", caseSensitive: true, preserveCredentials: true))),
        RuleAction(.modifyQuery(QueryEditAction(operations: [
            .set(name: "a", value: "1"), .add(name: "b", value: "2"), .remove(name: "c"),
            .findReplace(name: nil, find: "x", replacement: "y", caseSensitive: true),
        ])), isFinal: true),
        RuleAction(.editHeaders(direction: .request, operations: [
            .set(name: "A", value: "1"), .addIfMissing(name: "B", value: "2"), .append(name: "C", value: "3"),
            .appendToValue(name: "D", text: "x"), .findReplace(name: "E", find: "a", replacement: "b", caseSensitive: true),
            .regex(name: "F", pattern: "a", replacement: "b", caseSensitive: false), .remove(name: "G"),
        ])),
        RuleAction(.editCookies(direction: .request, operations: [
            .set(name: "a", value: "1"), .addIfMissing(name: "b", value: "2"), .remove(name: "c"),
            .findReplace(name: nil, find: "x", replacement: "y", caseSensitive: true),
            .regex(name: "d", pattern: "x", replacement: "y", caseSensitive: false),
        ])),
        RuleAction(.rewriteBody(direction: .request, BodyRewriteAction(find: "a", replacement: "b", syntax: .regex, caseSensitive: false, scope: .first))),
        RuleAction(.rewriteBody(direction: .request, BodyRewriteAction(find: "", replacement: "v", operation: .setValue))),
        RuleAction(.mapRemote(MapRemoteAction(targetScheme: "http", targetHost: "b.test", targetPort: 81, path: .replace("/p"), preserveCredentials: true)), isFinal: true),
        RuleAction(.breakpoint(direction: .request, mode: .fullBody)),
        RuleAction(.delay(milliseconds: 40)),
        RuleAction(.rewriteStatus(RewriteStatusAction(status: 503, includeLocalResponses: true))),
        RuleAction(.editHeaders(direction: .response, operations: [.remove(name: "X")])),
        RuleAction(.editCookies(direction: .response, operations: [.remove(name: "sid")])),
        RuleAction(.rewriteBody(direction: .response, BodyRewriteAction(find: "", replacement: "", operation: .clear))),
        RuleAction(.breakpoint(direction: .response, mode: .headers)),
        RuleAction(.returnFile(MapLocalAction(assetID: UUID(), status: 404, headers: [HeaderField(name: "X", value: "1")])), isFinal: true),
        RuleAction(.returnDirectory(
            MapLocalDirectoryAction(bookmark: Data([9, 9]), displayName: "site", servesIndex: false, missing: .network, headers: [HeaderField(name: "X", value: "1")]),
            pathPrefix: "/static/")),
        RuleAction(.returnHandwritten(HandwrittenResponse(text: "HTTP/1.1 204 No Content\r\n\r\n"))),
        RuleAction(.returnPreset(PresetResponse(preset: .temporaryRedirect307, location: "/x"))),
        RuleAction(.returnPreset(PresetResponse(preset: .proxyAuthRequired407, body: "b", challenge: "Basic"))),
        RuleAction(.returnPreset(PresetResponse(preset: .gif200))),
        RuleAction(.closeConnection(.graceful)),
        RuleAction(.closeConnection(.reset)),
        RuleAction(.returnConnectTunnel),
        RuleAction(.noDecrypt),
        RuleAction(.hide),
        RuleAction(.mark(MarkAction(background: "#AABBCC", foreground: "#000000", text: "t"))),
        RuleAction(.mark(MarkAction(background: "#AABBCC"))),
        RuleAction(.comment(CommentAction(mode: .set, text: "a"))),
        RuleAction(.comment(CommentAction(mode: .append, text: "a"))),
        RuleAction(.comment(CommentAction(mode: .findReplace, text: "a", replacement: "b"))),
        RuleAction(.comment(CommentAction(mode: .clear))),
    ]

    @Test func everyStoredRuleShapeRoundTripsThroughTheDocument() {
        let group = UUID()
        var rules: [Rule] = Self.everyKind.enumerated().map { index, action in
            Rule(
                name: "kind \(index)", enabled: index % 2 == 0, groupID: index % 3 == 0 ? group : nil, order: index,
                conditions: ConditionGroup(rows: [ConditionRow(field: .url, op: .contains, value: "example")]), actions: [action])
        }
        // several actions, a ticked final, an occurrence range, a note, mode "any"
        rules.append(Rule(
            name: "multi", enabled: false, groupID: group, order: 40,
            conditions: ConditionGroup(
                mode: .any, occurrence: .times(2...5),
                rows: [ConditionRow(field: .method, op: .equals, value: "GET", caseSensitive: true), ConditionRow(field: .host, op: .endsWith, value: ".test")]),
            actions: [
                RuleAction(.modifyURL(URLEditAction(mode: .set, replacement: "https://c.test/")), isFinal: true),
                RuleAction(.editHeaders(direction: .request, operations: [.set(name: "A", value: "1")])),
                RuleAction(.mark(MarkAction(background: "#AABBCC"))),
            ],
            note: "why this rule exists"))
        // the old-style comparisons
        rules.append(Rule(
            name: "legacy", order: 41,
            conditions: ConditionGroup(rows: [
                ConditionRow(field: .host, op: .hostPattern, value: "*.example.com"),
                ConditionRow(field: .pathAndQuery, op: .wildcard, value: "/a/*", caseSensitive: true),
                ConditionRow(field: .pathAndQuery, op: .regexWhole, value: "^/a/.*$", caseSensitive: true),
            ]),
            actions: [RuleAction(.hide)]))
        rules.append(Rule(
            name: "legacy status", order: 42,
            conditions: ConditionGroup(mode: .none, rows: [ConditionRow(field: .statusCode, op: .inRange, value: "200-299")]),
            actions: [RuleAction(.editHeaders(direction: .response, operations: [.remove(name: "X")]))]))
        rules.append(Rule(name: "everything", order: 43, actions: [RuleAction(.returnConnectTunnel, isFinal: true)]))
        rules.append(Rule(name: "magic", order: 45, actions: [RuleAction(.magicString("*delay:100"))]))
        rules.append(Rule(
            name: "", order: 44, conditions: ConditionGroup(occurrence: .times(1...1)), actions: [RuleAction(.closeConnection(.reset))]))

        // every action kind and every action type is among them
        let kinds = Set(rules.flatMap(\.actions).map { kindName($0.kind) })
        #expect(kinds.count == 20)
        #expect(Set(rules.flatMap(\.actions).compactMap { ActionType($0.kind) }) == Set(ActionType.allCases))
        for rule in rules {
            let validation = RuleDocument(rule: rule).validate(limits: limits)
            #expect(validation.issues.isEmpty, "\(rule.name): \(validation.issues)")
            #expect(validation.rule == rule, "\(rule.name)")
        }
    }

    @Test func documentKeepsTheRuleFieldsItIsBuiltFrom() {
        let group = UUID()
        let rule = Rule(name: "n", enabled: false, groupID: group, order: 7, actions: [RuleAction(.hide)], note: "x")
        let doc = RuleDocument(rule: rule)
        #expect(doc.id == rule.id && doc.name == "n" && !doc.enabled && doc.groupID == group && doc.order == 7 && doc.note == "x")
    }

    // MARK: new

    @Test func newDocumentIsEmptyEnabledAndHasNoActions() {
        let group = UUID()
        let doc = RuleDocument(newIn: group)
        #expect(doc.groupID == group && doc.enabled && doc.actions.isEmpty && doc.conditions.rows.isEmpty)
        let validation = doc.validate(limits: limits)
        #expect(validation.rule == nil)
        #expect(validation.issues[.actions] == .noActions)
    }

    @Test func theStartDocumentHasOneUrlRowAndOneMarkCard() {
        let group = UUID()
        let doc = RuleDocument(startingIn: group)
        #expect(doc.groupID == group && doc.enabled && doc.name == "")
        #expect(doc.conditions.rows.map(\.row) == [ConditionRow(field: .url, op: .contains)])
        #expect(doc.actions.map(\.type) == [.mark])
    }

    @Test func noActionsIsAFieldIssue() {
        var doc = document([.mark])
        doc.removeAction(doc.actions[0].id)
        #expect(doc.actions.count == 1, "the last card cannot be deleted")
        doc.actions = []
        #expect(doc.validate(limits: limits).issues == [.actions: .noActions])
    }

    @Test func emptyNameIsAllowedLikeBefore() {
        var doc = document([.hide])
        doc.name = ""
        let validation = doc.validate(limits: limits)
        #expect(validation.rule?.name == "")
        #expect(doc.displayName == RulePresentation.displayName(""))
        doc.name = "x"
        #expect(doc.displayName == "x")
    }

    // MARK: connect-only and the judgment point

    @Test func conditionsAreConnectOnlyUsesTheWhitelist() {
        #expect(RuleDocument(newIn: nil).conditionsAreConnectOnly)
        for field in [ConditionField.url, .scheme, .host, .port, .clientIP, .clientApp] {
            var doc = RuleDocument(newIn: nil)
            doc.conditions = conditions([ConditionRow(field: field, name: field == .clientApp ? "name" : nil, op: .equals, value: "x")])
            #expect(doc.conditionsAreConnectOnly, "\(field)")
        }
        for field in [ConditionField.method, .path, .statusCode, .requestHeader, .durationMs, .remoteIP] {
            var doc = RuleDocument(newIn: nil)
            doc.conditions = conditions([ConditionRow(field: field, name: field == .requestHeader ? "X" : nil, op: .equals, value: "x")])
            #expect(!doc.conditionsAreConnectOnly, "\(field)")
        }
        var mixed = RuleDocument(newIn: nil)
        mixed.conditions = conditions([ConditionRow(field: .host, op: .equals, value: "a"), ConditionRow(field: .method, op: .equals, value: "GET")])
        #expect(!mixed.conditionsAreConnectOnly)
    }

    @Test func judgmentPointFollowsTheLatestRow() {
        var doc = RuleDocument(newIn: nil)
        #expect(doc.judgmentPoint == .connect)
        doc.conditions = conditions([ConditionRow(field: .method, op: .equals, value: "GET")])
        #expect(doc.judgmentPoint == .connect)
        doc.conditions = conditions([ConditionRow(field: .path, op: .equals, value: "/")])
        #expect(doc.judgmentPoint == .request)
        doc.conditions = conditions([ConditionRow(field: .statusCode, op: .equals, value: "200")])
        #expect(doc.judgmentPoint == .response)
        doc.conditions = conditions([ConditionRow(field: .sessionState, op: .equals, value: "completed")])
        #expect(doc.judgmentPoint == .completion)
    }

    @Test func judgmentPointFlipWarnsAndKeepsTheCard() {
        var doc = document([.modifyURL])
        let id = doc.actions[0].id
        #expect(doc.validate(limits: limits).rule != nil)
        doc.conditions = conditions([ConditionRow(field: .statusCode, op: .equals, value: "200")])
        let validation = doc.validate(limits: limits)
        #expect(doc.actions.count == 1)
        // Spec R8F2-6: the rule saves; the card only warns that the edit is visible in the app.
        #expect(validation.rule != nil)
        #expect(validation.issues[.action(id, .type)] == nil)
        #expect(validation.cardStates[id] == .requestVisibleOnly)
        // flipping back clears it
        doc.conditions = conditions([])
        #expect(doc.validate(limits: limits).rule != nil)
    }

    @Test func unavailableTypeAtJudgmentPointBlocksSave() {
        let doc = document([.delay], rows: [ConditionRow(field: .sessionState, op: .equals, value: "completed")])
        let validation = doc.validate(limits: limits)
        #expect(validation.rule == nil)
        #expect(validation.issues[.action(doc.actions[0].id, .type)] == .actionNotAllowedAtCompletionPoint)
        #expect(validation.cardStates[doc.actions[0].id] == .blocked(.onlyAnnotationAtCompletion))
        let marking = document([.mark], rows: [ConditionRow(field: .sessionState, op: .equals, value: "completed")])
        #expect(marking.validate(limits: limits).rule != nil)
    }

    @Test func availabilityOfATypeLooksAtTheOtherCards() {
        let response = [ConditionRow(field: .statusCode, op: .equals, value: "200")]
        var doc = document([.rewriteStatus], rows: response)
        #expect(doc.availability(of: .modifyURL, replacing: nil) == .available)
        #expect(doc.availability(of: .editResponseHeaders, replacing: nil) == .available)
        doc.conditions = conditions([])
        #expect(doc.availability(of: .noDecrypt, replacing: nil) == .unavailable(.connectOnlyMixed))
        // replacing the only card, the card itself is no sibling
        #expect(doc.availability(of: .noDecrypt, replacing: doc.actions[0].id) == .available)
        doc.conditions = conditions([ConditionRow(field: .method, op: .equals, value: "GET")])
        #expect(doc.availability(of: .noDecrypt, replacing: doc.actions[0].id) == .unavailable(.needsConnectPointConditions))
    }

    @Test func connectOnlyActionsNeedConnectPointConditions() {
        let method = [ConditionRow(field: .method, op: .equals, value: "GET")]
        let blocked = document([.noDecrypt], rows: method).validate(limits: limits)
        #expect(blocked.rule == nil)
        #expect(blocked.issues.values.contains(.connectActionCondition))
        #expect(document([.noDecrypt], rows: [ConditionRow(field: .host, op: .equals, value: "a.test")]).validate(limits: limits).rule != nil)
        let mixed = document([.noDecrypt, .modifyURL]).validate(limits: limits)
        #expect(mixed.rule == nil)
        #expect(mixed.issues.values.contains(.connectActionMixed))
    }

    // MARK: final actions

    @Test func finalFollowedByActionsIsAllowedAndMarked() {
        let doc = document([.returnPreset, .mark])
        let validation = doc.validate(limits: limits)
        #expect(validation.rule != nil && validation.issues.isEmpty)
        #expect(validation.cardStates[doc.actions[0].id] == .final)
        #expect(validation.cardStates[doc.actions[1].id] == .unreachable)
        // a ticked final does the same
        let ticked = document([.modifyURL, .mark], finals: [.modifyURL])
        let states = ticked.validate(limits: limits).cardStates
        #expect(states[ticked.actions[0].id] == .final && states[ticked.actions[1].id] == .unreachable)
    }

    @Test func emptyConditionsWithFinalNeedsConfirmation() {
        #expect(document([.returnPreset]).validate(limits: limits).confirmations == [.everySessionFinal])
        #expect(document([.modifyURL], finals: [.modifyURL]).validate(limits: limits).confirmations == [.everySessionFinal])
        #expect(document([.hide]).validate(limits: limits).confirmations == [.everySessionFinal])
        let narrowed = document([.returnPreset], rows: [ConditionRow(field: .host, op: .equals, value: "a.test")])
        #expect(narrowed.validate(limits: limits).confirmations.isEmpty)
    }

    @Test func emptyConditionsWithNonFinalDoesNot() {
        #expect(document([.modifyURL, .mark]).validate(limits: limits).confirmations.isEmpty)
    }

    @Test func hideAddsTheWarning() {
        let doc = document([.hide])
        #expect(doc.validate(limits: limits).warnings[doc.actions[0].id] == [.hideCutsLowerRules])
        let other = document([.mark])
        #expect(other.validate(limits: limits).warnings.isEmpty)
    }

    @Test func aFinalActionNeedsAJudgmentPointOfRequestOrEarlier() {
        let response = [ConditionRow(field: .statusCode, op: .equals, value: "200")]
        let completion = [ConditionRow(field: .sessionState, op: .equals, value: "completed")]
        // ticked final at the response point
        let atResponse = document([.rewriteStatus], rows: response, finals: [.rewriteStatus])
        var validation = atResponse.validate(limits: limits)
        #expect(validation.rule == nil)
        #expect(validation.issues[.action(atResponse.actions[0].id, .final)] == .finalActionAtLaterPoint)
        // ticked final at the completion point
        let atCompletion = document([.mark], rows: completion, finals: [.mark])
        validation = atCompletion.validate(limits: limits)
        #expect(validation.rule == nil)
        #expect(validation.issues[.action(atCompletion.actions[0].id, .final)] == .finalActionAtLaterPoint)
        // not ticked: fine; at the request point: fine; hide never changes the transport: fine
        #expect(document([.rewriteStatus], rows: response).validate(limits: limits).rule != nil)
        #expect(document([.modifyURL], rows: [ConditionRow(field: .method, op: .equals, value: "GET")], finals: [.modifyURL]).validate(limits: limits).rule != nil)
        #expect(document([.hide], rows: completion).validate(limits: limits).rule != nil)
        #expect(document([.hide], rows: response, finals: [.hide]).validate(limits: limits).rule != nil)
    }

    // MARK: limits

    @Test func tooManyActionsAndConditions() {
        var doc = document([])
        for _ in 0..<17 { doc.addAction(.hide) }
        let validation = doc.validate(limits: limits)
        #expect(validation.rule == nil)
        #expect(validation.issues[.actions] == .tooManyActions)
        var sixteen = document([])
        for _ in 0..<16 { sixteen.addAction(.hide) }
        #expect(sixteen.validate(limits: limits).issues[.actions] == nil)

        var rows = RuleDocument(newIn: nil)
        rows.addAction(.hide)
        for _ in 0..<33 { rows.conditions.addRow() }
        for index in rows.conditions.rows.indices { rows.conditions.rows[index].value = "a" }
        let many = rows.validate(limits: limits)
        #expect(many.rule == nil)
        #expect(many.issues[.conditions] == .tooManyConditions)
    }

    @Test func fieldProblemsLandOnTheirRowAndCard() {
        var doc = document([.modifyURL, .delay])
        doc.conditions = conditions([ConditionRow(field: .url, op: .regex, value: "(")])
        doc.actions[1].delayText = "abc"
        doc.conditions.occurrence = OccurrenceDraft(isSpecific: true, countText: "0")
        let validation = doc.validate(limits: limits)
        #expect(validation.rule == nil)
        #expect(validation.issues[.conditionRow(doc.conditions.rows[0].id)] != nil)
        #expect(validation.issues[.occurrence] == .invalidConditionValue)
        #expect(validation.issues[.action(doc.actions[1].id, .delay)] == .notANumber)
        var long = document([.hide])
        long.name = String(repeating: "a", count: limits.fieldBytes + 1)
        #expect(long.validate(limits: limits).issues[.name] == .fieldTooLong)
    }

    // MARK: seeds

    @Test func seedFromFlowDraftKeepsMatcherAsRows() {
        var draft = RuleEditorDraft(kind: .mapLocal)
        draft.name = "a.test"
        draft.match.scheme = .https
        draft.match.host = "a.test"
        draft.match.port = "443"
        draft.match.method = "GET"
        draft.match.pathMode = .exact
        draft.match.path = "/x?y=1"
        let doc = RuleDocument.seed(from: draft, limits: limits)
        #expect(doc.id == draft.id && doc.name == "a.test")
        let fields = doc.conditions.rows.map(\.row)
        #expect(fields.contains(ConditionRow(field: .scheme, op: .equals, value: "https")))
        #expect(fields.contains { $0.field == .host && $0.value == "a.test" })
        #expect(fields.contains(ConditionRow(field: .port, op: .equals, value: "443")))
        #expect(fields.contains(ConditionRow(field: .method, op: .equals, value: "GET", caseSensitive: true)))
        #expect(fields.contains { $0.field == .pathAndQuery && $0.value == "/x?y=1" })
        #expect(doc.actions.map(\.type) == [.returnFile])
    }

    @Test func seedFromAValidDraftKeepsTheRuleItProduces() throws {
        var draft = RuleEditorDraft(kind: .mark)
        draft.name = "m"
        draft.match.host = "a.test"
        let rule = try #require(draft.validate(order: 0, limits: limits).rule)
        let doc = RuleDocument.seed(from: draft, limits: limits)
        #expect(doc.validate(limits: limits).rule == rule)
    }

    @Test func seedKeepsAMockDraftsAssetOnTheFileCard() throws {
        let asset = ManagedAsset(id: UUID(), size: 9, displayName: "body.json", importedAt: Date(timeIntervalSince1970: 5))
        var draft = RuleEditorDraft(kind: .mapLocal)
        draft.match.host = "a.test"
        draft.mapLocal.asset = asset
        draft.mapLocal.status = "201"
        let doc = RuleDocument.seed(from: draft, limits: limits)
        #expect(doc.actions.count == 1 && doc.actions[0].file.asset == asset)
        let rule = try #require(doc.validate(limits: limits).rule)
        #expect(rule.actions[0].kind == .returnFile(MapLocalAction(assetID: asset.id, status: 201, headers: [])))
    }

    @Test func seedFromInvalidDraftFallsBackToConditionsPlusDefaultAction() {
        var draft = RuleEditorDraft(kind: .mapRemote)
        draft.match.host = "a.test"
        draft.match.port = "not a number"
        draft.mapRemote.targetHost = "b.test"
        draft.mapRemote.targetPort = "8080"
        let doc = RuleDocument.seed(from: draft, limits: limits)
        #expect(doc.actions.map(\.type) == [.mapRemote])
        #expect(doc.actions[0].remote.targetHost == "b.test" && doc.actions[0].remote.targetPort == "8080")
        #expect(doc.conditions.rows.map(\.row.field) == [.host])

        var response = RuleEditorDraft(kind: .editHeaders)
        response.direction = .response
        response.match.host = "("
        response.match.syntax = .regex
        response.headerOperations = [HeaderOperationRow(kind: .remove, name: "X")]
        let seeded = RuleDocument.seed(from: response, limits: limits)
        #expect(seeded.actions.map(\.type) == [.editResponseHeaders])
        #expect(seeded.actions[0].headerRows.map(\.name) == ["X"] && seeded.actions[0].headerRows.map(\.method) == [.remove])
    }

    // MARK: editing the cards

    @Test func addDuplicateRemoveMoveActions() {
        var doc = RuleDocument(newIn: nil)
        doc.addAction(.mark)
        doc.addAction(.hide)
        doc.addAction(.comment, after: doc.actions[0].id)
        #expect(doc.actions.map(\.type) == [.mark, .comment, .hide])
        let first = doc.actions[0].id, last = doc.actions[2].id
        doc.duplicateAction(first)
        #expect(doc.actions.map(\.type) == [.mark, .mark, .comment, .hide])
        #expect(Set(doc.actions.map(\.id)).count == 4)
        doc.moveAction(last, by: -2)
        #expect(doc.actions.map(\.type) == [.mark, .hide, .mark, .comment])
        doc.moveAction(first, by: -5)
        #expect(doc.actions[0].id == first)
        doc.moveAction(first, by: 99)
        #expect(doc.actions.last?.id == first)
        doc.removeAction(first)
        #expect(doc.actions.count == 3)
        doc.removeAction(UUID())
        doc.duplicateAction(UUID())
        #expect(doc.actions.count == 3)
    }

    @Test func changingActionTypeKeepsFinalFlag() {
        var doc = document([.delay], finals: [.delay])
        let id = doc.actions[0].id
        doc.changeType(of: id, to: .rewriteStatus)
        #expect(doc.actions[0].type == .rewriteStatus && doc.actions[0].isFinal && doc.actions[0].id == id)
        doc.changeType(of: UUID(), to: .hide)
        #expect(doc.actions.map(\.type) == [.rewriteStatus])
    }

    @Test func warningsAndConfirmationsHaveSentences() {
        let zh = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        let keys = [
            ActionWarning.contentLengthCorrected.localizationKey, ActionWarning.hideCutsLowerRules.localizationKey,
            RuleDocumentConfirmation.everySessionFinal.titleKey, RuleDocumentConfirmation.everySessionFinal.messageKey,
            RuleDraftIssue.finalActionAtLaterPoint.localizationKey,
        ]
        for key in keys { #expect(zh.string(key) != key, "\(key)") }
        #expect(RuleDraftIssue.finalActionAtLaterPoint.rawValue == "finalActionAtLaterPoint")
    }
}
