import FlowStore
import Foundation
import Testing

@testable import RulesEngine

/// Spec 12.6: what a saved rule's actions will not do as written. Warnings never make a rule invalid.
@Suite("Rule execution warnings")
struct RuleExecutionWarningsTests {
    private let atRequest = [ConditionRow(field: .method, op: .equals, value: "GET")]
    private let atResponse = [ConditionRow(field: .statusCode, op: .equals, value: "200")]
    private let atConnect = [ConditionRow(field: .host, op: .equals, value: "a.test")]

    private func rule(_ rows: [ConditionRow], _ actions: [RuleAction]) -> Rule {
        Rule(name: "r", conditions: ConditionGroup(rows: rows), actions: actions)
    }

    private let requestHeader = RuleAction(.editHeaders(direction: .request, operations: [.set(name: "X-A", value: "1")]))
    private let responseHeader = RuleAction(.editHeaders(direction: .response, operations: [.set(name: "X-B", value: "1")]))
    private let manual = RuleAction(.returnHandwritten(HandwrittenResponse(text: "HTTP/1.1 200 OK\r\n\r\n")))
    private let mark = RuleAction(.mark(MarkAction(background: "#FF0000")))
    private let hide = RuleAction(.hide)

    @Test func noWarningsForAnOrdinaryRule() {
        #expect(RuleValidation.executionWarnings(rule(atRequest, [requestHeader, responseHeader, mark])).isEmpty)
        #expect(RuleValidation.executionWarnings(rule(atResponse, [responseHeader, mark])).isEmpty)
    }

    @Test func warning1RequestActionInAResponseJudgedRule() {
        let warnings = RuleValidation.executionWarnings(rule(atResponse, [requestHeader, responseHeader, mark]))
        #expect(warnings == [0: [.requestActionVisibleOnly]])
        // Each request-side kind is flagged, annotations and response-side actions are not.
        let kinds: [RuleAction] = [
            RuleAction(.mapRemote(MapRemoteAction(targetScheme: "https", targetHost: "b.test", targetPort: 443, path: .preserve))),
            RuleAction(.modifyURL(URLEditAction(mode: .set, replacement: "https://b.test/"))),
        ]
        for action in kinds {
            #expect(RuleValidation.executionWarnings(rule(atResponse, [action]))[0] == [.requestActionVisibleOnly], "\(action.kind)")
        }
    }

    /// Return File, manual and predefined responses, close and delay work at either point: a rule judged at the
    /// response runs them there, so they are not "request-side" and carry no warning 1.
    @Test func actionsThatWorkAtBothPointsAreNotRequestSideAtTheResponse() {
        let bothPoints: [RuleAction] = [
            RuleAction(.delay(milliseconds: 5)), RuleAction(.closeConnection(.reset)), RuleAction(.closeConnection(.graceful)),
            manual, RuleAction(.returnPreset(PresetResponse(preset: .notFound404))),
            RuleAction(.returnFile(MapLocalAction(assetID: UUID(), status: 200, headers: []))), RuleAction(.magicString("*drop")),
        ]
        for action in bothPoints {
            #expect(RuleValidation.executionWarnings(rule(atResponse, [action])).isEmpty, "\(action.kind)")
            #expect(action.kind.direction == nil, "\(action.kind)")
            #expect(action.kind.runsAtResponsePoint, "\(action.kind)")
        }
        // Ending the rule works there too: what follows a Return at the response never runs.
        #expect(RuleValidation.executionWarnings(rule(atResponse, [manual, mark])) == [1: [.afterFinalAction]])
    }

    @Test func warning1ShowsOnlyForRulesJudgedAtOrAfterTheResponse() {
        #expect(RuleValidation.executionWarnings(rule(atRequest, [requestHeader])).isEmpty)
        #expect(RuleValidation.executionWarnings(rule(atConnect, [requestHeader])).isEmpty)
    }

    @Test func warning2IsNeverProducedToday() {
        let rules = [
            rule(atRequest, [requestHeader, responseHeader]), rule(atResponse, [requestHeader]), rule([], [mark]),
            rule(atConnect, [RuleAction(.noDecrypt)]),
        ]
        for rule in rules {
            #expect(!RuleValidation.executionWarnings(rule).values.joined().contains(.matchPointUncertain))
        }
        #expect(ActionExecutionWarning.allCases.contains(.matchPointUncertain))
    }

    @Test func warning3RequestActionAfterAResponseAction() {
        #expect(
            RuleValidation.executionWarnings(rule(atRequest, [responseHeader, requestHeader]))
                == [1: [.requestActionAfterResponseAction]])
        // The right order, and annotations in between, are fine.
        #expect(RuleValidation.executionWarnings(rule(atRequest, [requestHeader, mark, responseHeader])).isEmpty)
        #expect(RuleValidation.executionWarnings(rule(atRequest, [mark, requestHeader])).isEmpty)
        // At the response warning 1 already says everything.
        #expect(RuleValidation.executionWarnings(rule(atResponse, [responseHeader, requestHeader])) == [1: [.requestActionVisibleOnly]])
    }

    @Test func warning4NoDecryptNeedsSimpleConditions() {
        let noDecrypt = RuleAction(.noDecrypt)
        let simple: [[ConditionRow]] = [
            [], [ConditionRow(field: .allSessions, op: .equals)], atConnect,
            [ConditionRow(field: .url, op: .contains, value: "x")], [ConditionRow(field: .scheme, op: .equals, value: "https")],
            [ConditionRow(field: .clientIP, op: .equals, value: "1.1.1.1")],
            [ConditionRow(field: .clientApp, op: .contains, value: "Safari")],
        ]
        for rows in simple { #expect(RuleValidation.executionWarnings(rule(rows, [noDecrypt])).isEmpty, "\(rows)") }
        let others: [[ConditionRow]] = [
            atRequest, atResponse, [ConditionRow(field: .port, op: .equals, value: "443")],
            [ConditionRow(field: .clientApp, name: "Key", op: .contains, value: "Safari")],
            atConnect + [ConditionRow(field: .path, op: .equals, value: "/")],
        ]
        for rows in others {
            #expect(
                RuleValidation.executionWarnings(rule(rows, [noDecrypt]))[0]?.contains(.noDecryptNeedsSimpleConditions) == true,
                "\(rows)")
        }
        // Only the Do Not Decrypt card is flagged.
        #expect(RuleValidation.executionWarnings(rule(atRequest, [mark, noDecrypt])).keys.sorted() == [1])
    }

    @Test func warning5MoreThanOneManualResponse() {
        #expect(RuleValidation.executionWarnings(rule(atRequest, [manual])).isEmpty)
        #expect(
            RuleValidation.executionWarnings(rule(atRequest, [manual, mark, manual, manual]))[2]?
                .contains(.multipleManualResponses) == true)
        // The first manual response is final, so what follows it is also an error.
        #expect(
            RuleValidation.executionWarnings(rule(atRequest, [manual, manual]))[1]
                == [.multipleManualResponses, .afterFinalAction])
    }

    @Test func errorAfterAFinalAction() {
        #expect(RuleValidation.executionWarnings(rule(atRequest, [hide, mark, responseHeader])) == [1: [.afterFinalAction], 2: [.afterFinalAction]])
        let ticked = RuleAction(.editHeaders(direction: .response, operations: [.set(name: "X", value: "1")]), isFinal: true)
        #expect(RuleValidation.executionWarnings(rule(atRequest, [ticked, mark])) == [1: [.afterFinalAction]])
        #expect(RuleValidation.executionWarnings(rule(atRequest, [mark, responseHeader, hide])).isEmpty)
        #expect(ActionExecutionWarning.afterFinalAction.isError)
        #expect(ActionExecutionWarning.allCases.filter(\.isError) == [.afterFinalAction])
    }

    @Test func aRequestActionAtTheResponseNeverEndsTheRule() {
        // A skipped (or record-only) request action cuts nothing, even when final by nature.
        let file = RuleAction(.mapRemote(MapRemoteAction(targetScheme: "https", targetHost: "b.test", targetPort: 443, path: .preserve)))
        let ticked = RuleAction(.editHeaders(direction: .request, operations: [.set(name: "X", value: "1")]), isFinal: true)
        #expect(RuleValidation.executionWarnings(rule(atResponse, [file, mark])) == [0: [.requestActionVisibleOnly]])
        #expect(RuleValidation.executionWarnings(rule(atResponse, [ticked, responseHeader])) == [0: [.requestActionVisibleOnly]])
        // A response-side final action still does.
        let finalResponse = RuleAction(.rewriteStatus(RewriteStatusAction(status: 500)), isFinal: true)
        #expect(
            RuleValidation.executionWarnings(rule(atResponse, [finalResponse, requestHeader]))
                == [1: [.requestActionVisibleOnly, .afterFinalAction]])
    }

    @Test func combinedWarningsAreListedInCaseOrder() {
        let warnings = RuleValidation.executionWarnings(rule(atResponse, [hide, requestHeader]))
        #expect(warnings[1] == [.requestActionVisibleOnly, .afterFinalAction])
    }

    @Test func warningsDoNotMakeTheRuleInvalid() throws {
        try rule(atResponse, [requestHeader, responseHeader]).validate()
        try rule(atRequest, [responseHeader, requestHeader]).validate()
    }

    @Test func warning1IsLeftOutWhereNoDecryptAlreadyWarns() {
        // In a response-judged rule Do Not Decrypt is both a request-side action and never possible: only 4 shows.
        let warnings = RuleValidation.executionWarnings(rule(atResponse, [RuleAction(.noDecrypt)]))
        #expect(warnings[0] == [.noDecryptNeedsSimpleConditions])
        // A request-side neighbour keeps its own 1.
        #expect(RuleValidation.executionWarnings(rule(atResponse, [requestHeader]))[0] == [.requestActionVisibleOnly])
    }
}
