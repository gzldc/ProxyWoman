import FlowStore
import Foundation
import os
import RulesEngine
import Testing
@testable import ProxyCore

@Suite("ExchangeRuleSessionCompletion", .productionChinese) struct ExchangeRuleSessionCompletionTests {
    private static let target = HTTPMessageTarget(scheme: "http", host: "example.test", port: 80, method: "GET", pathAndQuery: "/")
    private static let mark = MarkAction(background: "#FF0000")
    private let reads = OSAllocatedUnfairLock(initialState: (comment: 0, app: 0))

    private func session(_ rules: [Rule], storedComment: String? = nil) -> ExchangeRuleSession {
        var source = ExchangeRuleSession.FactsSource()
        let reads = self.reads
        source.comment = { reads.withLock { $0.comment += 1 }; return storedComment }
        source.app = { reads.withLock { $0.app += 1 }; return .unknown }
        return ExchangeRuleSession(
            snapshot: RuleSnapshot(revision: 3, rules: rules.enumerated().map { index, rule in
                var rule = rule
                rule.order = index
                return rule
            }), hits: nil, originalRequest: .request(Self.target, headers: []), provenance: .init(), factsSource: source)
    }

    private func rule(_ name: String, _ rows: [ConditionRow], _ actions: [RuleAction] = [RuleAction(.mark(Self.mark))]) -> Rule {
        Rule(name: name, conditions: ConditionGroup(rows: rows), actions: actions)
    }

    private let finished = FlowCompletionInput(state: .completed, durationMilliseconds: 5, responseWireBytes: 3)

    @Test func factsReadNeitherCommentNorAppWhenNoRowNeedsThem() {
        let session = session([rule("path", [ConditionRow(field: .pathAndQuery, op: .startsWith, value: "/")])])
        _ = session.facts()
        #expect(reads.withLock { $0.comment } == 0 && reads.withLock { $0.app } == 0)
    }

    @Test func factsReadOnlyWhatARowNeeds() {
        let comment = session([rule("c", [ConditionRow(field: .comment, op: .contains, value: "x")])])
        _ = comment.facts()
        #expect(reads.withLock { $0.comment } == 1 && reads.withLock { $0.app } == 0)
        let app = session([rule("a", [ConditionRow(field: .clientApp, name: "name", op: .equals, value: "x")])])
        _ = app.facts()
        #expect(reads.withLock { $0.comment } == 1 && reads.withLock { $0.app } == 1)
    }

    @Test func completionAfterARejectedRequestReadsThePresentedRequest() throws {
        let reject = rule("reject", [], [RuleAction(.editHeaders(
            direction: .request, operations: [.set(name: "Content-Length", value: "1")]))])
        let p3 = rule("p3", [ConditionRow(field: .sessionState, op: .equals, value: "failed"),
                             ConditionRow(field: .host, op: .equals, value: "example.test")])
        let session = session([reject, p3])
        #expect(throws: ExchangeRuleFailure.self) { try session.prepareRequest() }
        let output = session.completion(FlowCompletionInput(state: .failed, durationMilliseconds: 1, responseWireBytes: nil))
        let marks = output.annotations.compactMap { annotation -> FlowMark? in
            if case .mark(let mark) = annotation { mark } else { nil }
        }
        #expect(marks.map(\.source) == [.rule(id: p3.id, name: "p3")])
        #expect(output.provenance?.ruleMatches?.ruleIDs.contains(p3.id) == true)
    }

    @Test func completionReadsTheCommentTheEarlierPointsLeftAndHandsOverTheirAnnotations() throws {
        let p1 = rule("p1", [], [RuleAction(.comment(CommentAction(mode: .append, text: "a")))])
        let p3 = rule("p3", [ConditionRow(field: .comment, op: .equals, value: "stored a"),
                              ConditionRow(field: .sessionState, op: .equals, value: "completed")])
        let session = session([p1, p3], storedComment: "stored")
        _ = try session.prepareRequest()
        let output = session.completion(finished)
        #expect(output.annotations.count == 2)
        if case .comment(let action) = output.annotations[0] { #expect(action.text == "a") } else { Issue.record("P1 comment first") }
        if case .mark(let mark) = output.annotations[1] { #expect(mark.source == .rule(id: p3.id, name: "p3")) } else { Issue.record("P3 mark second") }
        let matches = try #require(output.provenance?.ruleMatches)
        #expect(matches.ruleIDs == [p1.id, p3.id] && matches.total == 2)
        #expect(session.drainAnnotations().isEmpty)
    }
}
