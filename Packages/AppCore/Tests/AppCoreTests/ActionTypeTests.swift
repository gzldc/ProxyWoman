import FlowStore
import Foundation
import RulesEngine
import Testing

@testable import AppCore
@testable import Localization

@Suite(.productionChinese) struct ActionTypeTests {
    /// One stored action per type; the two close modes are separate entries.
    private static let representatives: [(ActionType, ActionKind)] = [
        (.modifyURL, .modifyURL(URLEditAction(mode: .set, replacement: "https://b.test/"))),
        (.modifyQuery, .modifyQuery(QueryEditAction(operations: []))),
        (.editRequestHeaders, .editHeaders(direction: .request, operations: [])),
        (.editRequestCookies, .editCookies(direction: .request, operations: [])),
        (.rewriteRequestBody, .rewriteBody(direction: .request, BodyRewriteAction(find: "a", replacement: "b"))),
        (.mapRemote, .mapRemote(MapRemoteAction(targetScheme: "https", targetHost: "b.test", targetPort: 443, path: .preserve))),
        (.requestBreakpoint, .breakpoint(direction: .request, mode: .headers)),
        (.delay, .delay(milliseconds: 5)),
        (.rewriteStatus, .rewriteStatus(RewriteStatusAction(status: 404))),
        (.editResponseHeaders, .editHeaders(direction: .response, operations: [])),
        (.editResponseCookies, .editCookies(direction: .response, operations: [])),
        (.rewriteResponseBody, .rewriteBody(direction: .response, BodyRewriteAction(find: "a", replacement: "b"))),
        (.responseBreakpoint, .breakpoint(direction: .response, mode: .headers)),
        (.returnFile, .returnFile(MapLocalAction(assetID: UUID(), headers: []))),
        (.returnDirectory, .returnDirectory(MapLocalDirectoryAction(bookmark: Data([1]), displayName: "d"), pathPrefix: "/a/")),
        (.returnHandwritten, .returnHandwritten(HandwrittenResponse(text: "HTTP/1.1 200 OK\r\n\r\n"))),
        (.returnPreset, .returnPreset(PresetResponse(preset: .gif200))),
        (.closeConnectionGraceful, .closeConnection(.graceful)),
        (.closeConnectionReset, .closeConnection(.reset)),
        (.returnConnectTunnel, .returnConnectTunnel),
        (.noDecrypt, .noDecrypt),
        (.hide, .hide),
        (.mark, .mark(MarkAction(background: "#FF3B30"))),
        (.comment, .comment(CommentAction(text: "x"))),
        (.magicString, .magicString("*delay:100")),
    ]

    @Test func everyActionKindMapsToExactlyOneType() {
        #expect(Self.representatives.count == 25)
        #expect(ActionType.allCases.count == 25)
        var seen = Set<ActionType>()
        for (type, kind) in Self.representatives {
            #expect(ActionType(kind) == type, "\(type)")
            seen.insert(type)
        }
        #expect(seen.count == 25)
        #expect(ActionType(.closeConnection(.graceful)) != ActionType(.closeConnection(.reset)))
    }

    @Test func typeTitlesAndHintsAreDistinctKeys() {
        let keys = ActionType.allCases.flatMap { [$0.titleKey, $0.hintKey] }
        #expect(Set(keys).count == 50)
        for type in ActionType.allCases {
            #expect(type.titleKey == "rules.actionType.\(type.rawValue)")
            #expect(type.hintKey == "rules.actionType.\(type.rawValue).hint")
        }
    }

    @Test func sidesMatchTheKindDirection() {
        // A magic string takes its direction from the string it holds; its menu side is "both", as in the reference.
        for (type, kind) in Self.representatives where type != .magicString {
            switch kind.direction {
            case .request?: #expect(type.side == .request, "\(type)")
            case .response?: #expect(type.side == .response, "\(type)")
            // Annotations work wherever the rule is judged; so do Return, close and delay (they run at either point).
            case nil: #expect(type.side == (kind.isAnnotation ? .none : .both), "\(type)")
            }
            #expect(type.isIntrinsicallyFinal == kind.isIntrinsicallyFinal, "\(type)")
            #expect(type.isConnectOnly == kind.isConnectOnly, "\(type)")
            #expect(type.canRunAtConnect == kind.canRunAtConnect, "\(type)")
            #expect(type.isAnnotation == kind.isAnnotation, "\(type)")
        }
        for type in [ActionType.hide, .mark, .comment] { #expect(type.side == .none) }
    }

    @Test func menuGroupsFollowTheReference() {
        let names = ActionCatalog.menuGroups.map { $0.map(\.type) }
        #expect(names == [
            [.mark], [.modifyURL, .modifyQuery, .rewriteStatus], [.rewriteRequestBody, .rewriteResponseBody],
            [.editRequestHeaders, .editResponseHeaders], [.editRequestCookies, .editResponseCookies],
            [.requestBreakpoint, .responseBreakpoint], [.returnFile, .returnHandwritten, .returnPreset, .returnConnectTunnel],
            [.hide, .noDecrypt], [.closeConnectionGraceful, .closeConnectionReset], [.delay], [.comment], [.magicString],
        ])
        // Map Remote and Return Directory are not offered but remain displayable.
        let offered = Set(ActionCatalog.menuTypes)
        #expect(Set(ActionType.allCases).subtracting(offered) == [.mapRemote, .returnDirectory])
        #expect(ActionType.mapRemote.isLegacyOnly && ActionType.returnDirectory.isLegacyOnly && !ActionType.mark.isLegacyOnly)
        #expect(ActionCatalog.menuTypes.count == Set(ActionCatalog.menuTypes).count)
    }

    @Test func menuDirectionsFollowTheReference() {
        let expected: [(ActionType, ConditionDirection)] = [
            (.mark, .both), (.modifyURL, .request), (.modifyQuery, .request), (.rewriteStatus, .response),
            (.rewriteRequestBody, .request), (.rewriteResponseBody, .response), (.editRequestHeaders, .request),
            (.editResponseHeaders, .response), (.editRequestCookies, .request), (.editResponseCookies, .response),
            (.requestBreakpoint, .request), (.responseBreakpoint, .response), (.returnFile, .both), (.returnHandwritten, .both),
            (.returnPreset, .both), (.returnConnectTunnel, .request), (.hide, .both), (.noDecrypt, .request),
            (.closeConnectionGraceful, .both), (.closeConnectionReset, .both), (.delay, .both), (.comment, .both),
            (.magicString, .both),
        ]
        for (type, direction) in expected { #expect(type.direction == direction, "\(type)") }
        #expect(expected.count == ActionCatalog.menuTypes.count)
    }

    @Test func menuTitlesAreTheSpecifiedChineseNames() {
        let names = ActionCatalog.menuTypes.map { L10n.string($0.titleKey) }
        #expect(names == [
            "标记会话", "修改 URL", "修改查询字符串", "修改状态码", "修改请求正文", "修改响应正文", "修改请求 Header", "修改响应 Header",
            "修改请求 Cookie", "修改响应 Cookie", "设置请求断点", "设置响应断点", "返回文件", "返回手动响应", "返回预定义响应",
            "返回 CONNECT 隧道", "不显示", "不解密", "正常关闭连接", "强制关闭连接", "延迟请求", "注释", "魔法字符串",
        ])
    }

    @Test func availableAtRequestPointEverything() {
        for type in ActionType.allCases where !type.isConnectOnly {
            #expect(type.availability(at: .request, conditionsAreConnectOnly: false, siblings: []) == .available, "\(type)")
        }
    }

    @Test func responsePointAllowsRequestSideTypes() {
        for type in [ActionType.modifyURL, .delay, .returnFile, .mapRemote, .editRequestHeaders, .returnPreset] {
            #expect(type.availability(at: .response, conditionsAreConnectOnly: false, siblings: []) == .available, "\(type)")
        }
        for type in [ActionType.editResponseHeaders, .rewriteStatus, .rewriteResponseBody, .responseBreakpoint, .hide, .mark] {
            #expect(type.availability(at: .response, conditionsAreConnectOnly: false, siblings: []) == .available, "\(type)")
        }
    }

    @Test func completionPointOnlyAnnotations() {
        for type in ActionType.allCases {
            let expected: ActionType.Availability =
                type.isAnnotation ? .available : .unavailable(.onlyAnnotationAtCompletion)
            #expect(type.availability(at: .completion, conditionsAreConnectOnly: false, siblings: []) == expected, "\(type)")
        }
    }

    @Test func connectOnlyNeedsConnectConditions() {
        #expect(ActionType.noDecrypt.availability(at: .request, conditionsAreConnectOnly: false, siblings: []) == .unavailable(.needsConnectPointConditions))
        #expect(ActionType.returnConnectTunnel.availability(at: .connect, conditionsAreConnectOnly: false, siblings: []) == .unavailable(.needsConnectPointConditions))
        #expect(ActionType.noDecrypt.availability(at: .connect, conditionsAreConnectOnly: true, siblings: []) == .available)
    }

    @Test func connectOnlyMixedWithHeaderEditIsRefused() {
        #expect(
            ActionType.noDecrypt.availability(at: .connect, conditionsAreConnectOnly: true, siblings: [.editRequestHeaders])
                == .unavailable(.connectOnlyMixed))
        #expect(
            ActionType.editRequestHeaders.availability(at: .connect, conditionsAreConnectOnly: true, siblings: [.noDecrypt])
                == .unavailable(.connectOnlyMixed))
    }

    @Test func noDecryptAndCloseConnectionCanShare() {
        #expect(ActionType.noDecrypt.availability(at: .connect, conditionsAreConnectOnly: true, siblings: [.closeConnectionReset, .mark]) == .available)
        #expect(ActionType.closeConnectionGraceful.availability(at: .connect, conditionsAreConnectOnly: true, siblings: [.noDecrypt]) == .available)
        #expect(ActionType.mark.availability(at: .connect, conditionsAreConnectOnly: true, siblings: [.returnConnectTunnel]) == .available)
    }

    /// The states of cards in a document whose only condition is `field` (a method row is judged at the request, a status
    /// row at the response).
    private func states(_ cards: [(ActionType, Bool)], field: ConditionField = .method) -> [ActionCardState] {
        document(cards, field: field).cardAnalysis().states
    }

    private func document(_ cards: [(ActionType, Bool)], field: ConditionField = .method) -> RuleDocument {
        var document = RuleDocument(newIn: nil)
        document.conditions.addRow()
        document.conditions.rows[0].setField(field)
        document.actions = cards.map { type, isFinal in
            var card = ActionDraft(type: type)
            card.isFinal = isFinal
            return card
        }
        return document
    }

    @Test func cardStatesMarkUnreachableAfterFinal() {
        #expect(states([(.mark, false), (.returnPreset, false), (.editResponseHeaders, false)]) == [.active, .final, .unreachable])
    }

    @Test func tickedFinalMakesAnyCardFinal() {
        #expect(states([(.editRequestHeaders, true), (.mark, false)]) == [.final, .unreachable])
    }

    @Test func hideIsFinalAndCutsTheRest() {
        #expect(states([(.hide, false), (.comment, false)]) == [.final, .unreachable])
    }

    @Test func aMagicStringIsFinalByWhatItStandsFor() {
        var drop = ActionDraft(type: .magicString)
        drop.magicText = "*drop"
        var delay = ActionDraft(type: .magicString)
        delay.magicText = "*delay:5"
        var exit = ActionDraft(type: .magicString)
        exit.magicText = "*exit"
        for (card, expected) in [(drop, ActionCardState.final), (delay, .active), (exit, .final)] {
            var document = document([])
            document.actions = [card, ActionDraft(type: .mark)]
            let analysis = document.cardAnalysis()
            #expect(analysis.states[0] == expected, "\(card.magicText)")
            #expect(analysis.states[1] == (expected == .final ? .unreachable : .active))
        }
    }

    @Test func changingTheJudgmentPointFlagsCardsInsteadOfDroppingThem() {
        let cards: [(ActionType, Bool)] = [(.modifyURL, false), (.editResponseHeaders, false)]
        #expect(states(cards) == [.active, .active])
        #expect(states(cards, field: .statusCode) == [.requestVisibleOnly, .active])
        #expect(states([(.modifyURL, false)], field: .statusCode) == [.requestVisibleOnly])
    }

    @Test func aRequestSideFinalCardAtTheResponseDoesNotCutTheOnesAfterIt() {
        // A request breakpoint cannot be applied to a record: skipped, with its own wording.
        let analysis = document([(.requestBreakpoint, false), (.editResponseHeaders, false)], field: .statusCode).cardAnalysis()
        #expect(analysis.states == [.requestSkippedAtResponse, .active])
        #expect(ActionCardState.requestVisibleOnly.explanationKey == "rules.card.requestVisibleOnly")
        #expect(ActionCardState.requestSkippedAtResponse.explanationKey == "rules.card.requestSkippedAtResponse")
        #expect(ActionCardState.requestVisibleOnly.labelKey == nil)
    }

    /// Return, close and delay work at the response too: no "request action" notice, and Return and close end the rule there.
    @Test func returnCloseAndDelayRunAtTheResponse() {
        for type in [ActionType.delay, .returnPreset, .returnHandwritten, .returnFile, .closeConnectionGraceful, .closeConnectionReset] {
            #expect(type.side == .both, "\(type)")
            let analysis = document([(type, false)], field: .statusCode).cardAnalysis()
            #expect(!analysis.states.contains(.requestSkippedAtResponse) && !analysis.states.contains(.requestVisibleOnly), "\(type)")
            #expect(analysis.notices == [[]], "\(type)")
        }
        let analysis = document([(.returnPreset, false), (.editResponseHeaders, false)], field: .statusCode).cardAnalysis()
        #expect(analysis.states == [.final, .unreachable])
    }

    @Test func forbiddenTypesStayAsBlockedCards() {
        // A status row is judged at the response, where Do Not Decrypt cannot run.
        #expect(states([(.noDecrypt, false)], field: .statusCode) == [.blocked(.needsConnectPointConditions)])
        // After the exchange finished only annotations may run.
        #expect(states([(.delay, false), (.mark, false)], field: .durationMs) == [.blocked(.onlyAnnotationAtCompletion), .active])
    }

    @Test func explanationKeysAreWholeKeys() {
        let reasons: [ActionType.Reason] = [
            .requestSideAtResponsePoint, .onlyAnnotationAtCompletion, .needsConnectPointConditions, .connectOnlyMixed,
        ]
        #expect(ActionType.explanationKey(.requestSideAtResponsePoint) == "rules.unavailable.requestSideAtResponsePoint")
        #expect(ActionType.explanationKey(.onlyAnnotationAtCompletion) == "rules.unavailable.onlyAnnotationAtCompletion")
        #expect(ActionType.explanationKey(.needsConnectPointConditions) == "rules.unavailable.needsConnectPointConditions")
        #expect(ActionType.explanationKey(.connectOnlyMixed) == "rules.unavailable.connectOnlyMixed")
        #expect(Set(reasons.map(ActionType.explanationKey)).count == 4)
        #expect(ActionCardState.final.labelKey == "rules.card.final")
        #expect(ActionCardState.unreachable.labelKey == "rules.card.unreachable")
        #expect(ActionCardState.active.labelKey == nil)
    }
}
