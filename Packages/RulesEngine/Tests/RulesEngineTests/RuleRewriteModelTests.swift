import FlowStore
import Foundation
import Testing

@testable import RulesEngine

private func rewriteRule(
    _ action: LegacyRuleAction, matcher: RuleMatcher = RuleMatcher()
) -> LegacyRule {
    LegacyRule(id: UUID(), name: "r", enabled: true, order: 0, matcher: matcher, action: action)
}

private func bodyRule(
    _ action: BodyRewriteAction, direction: HTTPMessageDirection = .response, matcher: RuleMatcher = RuleMatcher()
) -> LegacyRule {
    rewriteRule(.rewriteBody(direction: direction, action), matcher: matcher)
}

private func failure(_ rule: LegacyRule) -> RuleValidationError? {
    do { try rule.validate(); return nil } catch let error as RuleValidationError { return error } catch { return nil }
}

@Suite("RuleRewriteModel") struct RuleRewriteModelTests {
    @Test func rewriteBodyDirectionIsItsOwn() {
        let action = BodyRewriteAction(find: "a", replacement: "b")
        #expect(LegacyRuleAction.rewriteBody(direction: .request, action).direction == .request)
        #expect(LegacyRuleAction.rewriteBody(direction: .response, action).direction == .response)
    }

    @Test func rewriteStatusRunsOnResponse() {
        #expect(LegacyRuleAction.rewriteStatus(RewriteStatusAction(status: 404)).direction == .response)
        #expect(!RewriteStatusAction(status: 404).includeLocalResponses)
    }

    @Test func emptyFindRejected() {
        let error = failure(bodyRule(BodyRewriteAction(find: "", replacement: "x")))
        #expect(error == RuleValidationError(code: .emptyFind, field: .bodyFind))
    }

    @Test func overlongFindRejected() {
        let long = String(repeating: "a", count: BodyRewriteAction.maxFindBytes + 1)
        #expect(BodyRewriteAction.maxFindBytes == 1024)
        #expect(failure(bodyRule(BodyRewriteAction(find: long, replacement: "x")))
            == RuleValidationError(code: .findTooLong, field: .bodyFind))
        #expect(failure(bodyRule(BodyRewriteAction(find: long, replacement: "x", syntax: .regex)))
            == RuleValidationError(code: .findTooLong, field: .bodyFind))
        // Counted in UTF-8 bytes: 513 two-byte characters are 1026 bytes.
        let wide = String(repeating: "\u{00E9}", count: 513)
        #expect(failure(bodyRule(BodyRewriteAction(find: wide, replacement: "x")))?.code == .findTooLong)
        #expect(failure(bodyRule(BodyRewriteAction(find: String(repeating: "a", count: 1024), replacement: "x"))) == nil)
    }

    @Test func overlongReplacementRejected() {
        let limit = RulesLimits().fieldBytes
        #expect(failure(bodyRule(BodyRewriteAction(find: "a", replacement: String(repeating: "b", count: limit)))) == nil)
        #expect(failure(bodyRule(BodyRewriteAction(find: "a", replacement: String(repeating: "b", count: limit + 1))))
            == RuleValidationError(code: .fieldTooLong, field: .bodyReplacement))
    }

    @Test func invalidRegexRejectedOnBodyFind() {
        #expect(failure(bodyRule(BodyRewriteAction(find: "(", replacement: "x", syntax: .regex)))
            == RuleValidationError(code: .invalidRegex, field: .bodyFind))
        #expect(failure(bodyRule(BodyRewriteAction(find: "[a-", replacement: "x", syntax: .regex)))?.code == .invalidRegex)
    }

    @Test func riskyRegexRejectedOnBodyFind() {
        #expect(failure(bodyRule(BodyRewriteAction(find: "(a+)+", replacement: "x", syntax: .regex)))
            == RuleValidationError(code: .regexTooComplex, field: .bodyFind))
    }

    @Test func textModeNeverCompilesAsRegexSoSpecialCharsAreValid() {
        for find in ["(", "[a-", "(a+)+", "a.b*", #"\"#] {
            #expect(failure(bodyRule(BodyRewriteAction(find: find, replacement: "x", syntax: .text))) == nil, "\(find)")
        }
    }

    @Test func validationDoesNotTouchTheSharedPatternCache() {
        let action = BodyRewriteAction(find: "validation-only-\(UUID().uuidString)", replacement: "x", syntax: .regex)
        #expect(failure(bodyRule(action)) == nil)
        #expect(!PatternCache.shared.isBodyPatternDisabled(action))
    }

    @Test func requestBodyRuleWithStatusRangeRejected() {
        let rule = bodyRule(
            BodyRewriteAction(find: "a", replacement: "b"), direction: .request, matcher: RuleMatcher(statusRange: 200...299))
        #expect(failure(rule) == RuleValidationError(code: .statusRangeNotAllowed, field: .statusRange))
    }

    @Test func responseBodyRuleWithStatusRangeAccepted() {
        let rule = bodyRule(
            BodyRewriteAction(find: "a", replacement: "b"), direction: .response, matcher: RuleMatcher(statusRange: 200...299))
        #expect(failure(rule) == nil)
        #expect(failure(rewriteRule(.rewriteStatus(RewriteStatusAction(status: 500)), matcher: RuleMatcher(statusRange: 400...499))) == nil)
    }

    @Test(arguments: [100, 199, 0, -1])
    func statusBelow200Rejected(_ status: Int) {
        #expect(failure(rewriteRule(.rewriteStatus(RewriteStatusAction(status: status))))
            == RuleValidationError(code: .invalidStatus, field: .rewriteStatus))
    }

    @Test(arguments: [200, 204, 599])
    func status200and599Accepted(_ status: Int) {
        #expect(failure(rewriteRule(.rewriteStatus(RewriteStatusAction(status: status)))) == nil)
    }

    @Test(arguments: [600, 1000])
    func status600Rejected(_ status: Int) {
        #expect(failure(rewriteRule(.rewriteStatus(RewriteStatusAction(status: status))))
            == RuleValidationError(code: .invalidStatus, field: .rewriteStatus))
    }

    @Test func codableRoundTripBothActions() throws {
        let rules = [
            bodyRule(BodyRewriteAction(find: "a", replacement: "b", syntax: .regex, caseSensitive: false, scope: .first),
                     direction: .request),
            rewriteRule(.rewriteStatus(RewriteStatusAction(status: 418, includeLocalResponses: true))),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for rule in rules {
            #expect(try JSONDecoder().decode(LegacyRule.self, from: encoder.encode(rule)) == rule)
        }
    }

    @Test func bodyPatternCacheDefaultBudgetIsFiveSeconds() {
        // Controller ruling: the body budget is generous; the 3-strike breaker still bounds it.
        #expect(PatternCache().bodyBudget.maxDuration == .seconds(5))
    }
}
