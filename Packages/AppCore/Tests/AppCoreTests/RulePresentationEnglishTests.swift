import Foundation
import RulesEngine
import Testing

@testable import AppCore
@testable import Localization

/// The rules list in English: each side has its own whole sentence, and the counts read the same way everywhere.
@Suite struct RulePresentationEnglishTests {
    private let english = Localizer(bundle: L10n.bundle, preferredLanguages: ["en"])

    private func summary(_ kind: ActionKind) -> String? {
        RulePresentation.actionSummary(of: kind, localizer: english)
    }

    @Test func editHeadersNamesTheSideInOneSentence() {
        let operations: [HeaderEdit] = [.addIfMissing(name: "A", value: "1"), .remove(name: "B")]
        #expect(summary(.editHeaders(direction: .request, operations: operations)) == "Edit request headers (2 items)")
        #expect(summary(.editHeaders(direction: .response, operations: Array(operations.prefix(1)))) == "Edit response headers (1 item)")
    }

    @Test func countsAreInParenthesesLikeCookiesAndQuery() {
        #expect(summary(.editCookies(direction: .request, operations: [])) == "Edit request cookies (0 items)")
        #expect(summary(.modifyQuery(QueryEditAction(operations: [.remove(name: "a")]))) == "Edit query parameters (1 item)")
    }

    @Test func appendModeSaysAppend() {
        #expect(summary(.modifyURL(URLEditAction(mode: .append, replacement: "?x=1"))) == "Append to URL: ?x=1")
        #expect(summary(.modifyURL(URLEditAction(mode: .set, replacement: "https://b.test/"))) == "Set URL to https://b.test/")
    }

    @Test func breakpointAndBodySentencesHaveNoCapitalisedSideWord() {
        let simple = Rule(
            id: UUID(), name: "b", enabled: true, order: 0, matcher: RuleMatcher(hostPattern: "a.test"),
            action: .breakpoint(direction: .response, mode: .fullBody))
        #expect(RulePresentation.actionSummary(of: simple, assetName: { _ in nil }, localizer: english) == "Pause on response and collect the full body")
        let request = Rule(
            id: UUID(), name: "b", enabled: true, order: 0, matcher: RuleMatcher(hostPattern: "a.test"),
            action: .breakpoint(direction: .request, mode: .headers))
        #expect(RulePresentation.actionSummary(of: request, assetName: { _ in nil }, localizer: english) == "Pause on request")
        let rewrite = Rule(
            id: UUID(), name: "r", enabled: true, order: 0, matcher: RuleMatcher(hostPattern: "a.test"),
            action: .rewriteBody(direction: .request, BodyRewriteAction(find: "foo", replacement: "bar")))
        #expect(
            RulePresentation.actionSummary(of: rewrite, assetName: { _ in nil }, localizer: english)
                == "In the request body, replace “foo” with “bar”")
        #expect(RulePresentation.summary(of: rewrite, localizer: english).hasSuffix("(request body)"))
        #expect(!RulePresentation.summary(of: rewrite, localizer: english).contains("In Request"))
    }
}
