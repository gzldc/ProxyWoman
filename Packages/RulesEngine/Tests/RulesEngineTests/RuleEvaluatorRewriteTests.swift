import Foundation
import Testing
import FlowStore
@testable import RulesEngine

private func target(method: String = "GET", path: String = "/v1/items") -> HTTPMessageTarget {
    HTTPMessageTarget(scheme: "https", host: "api.example.com", port: 443, method: method, pathAndQuery: path)
}

private func request(_ target: HTTPMessageTarget = target(), headers: [HeaderField] = []) -> HTTPMessageHead {
    .request(target, headers: headers)
}

private func response(_ status: Int = 200, reason: String? = "OK", headers: [HeaderField] = []) -> HTTPMessageHead {
    .response(status: status, reason: reason, headers: headers)
}

private func text(_ type: String = "text/plain") -> [HeaderField] { [HeaderField(name: "Content-Type", value: type)] }

private func snapshot(_ rules: [LegacyRule]) -> LegacyRuleSnapshot { LegacyRuleSnapshot(revision: 9, rules: rules) }

private func bodyRule(
    _ id: UUID = UUID(), order: Int = 0, direction: HTTPMessageDirection = .response, find: String = "a",
    matcher: RuleMatcher = RuleMatcher()
) -> LegacyRule {
    LegacyRule(id: id, name: "b", enabled: true, order: order, matcher: matcher,
         action: .rewriteBody(direction: direction, BodyRewriteAction(find: find, replacement: "b")))
}

private func statusRule(
    _ id: UUID = UUID(), order: Int = 0, status: Int = 404, includeLocal: Bool = false,
    matcher: RuleMatcher = RuleMatcher()
) -> LegacyRule {
    LegacyRule(id: id, name: "s", enabled: true, order: order, matcher: matcher,
         action: .rewriteStatus(RewriteStatusAction(status: status, includeLocalResponses: includeLocal)))
}

private func headerRule(
    id: UUID = UUID(), order: Int = 0, _ direction: HTTPMessageDirection, _ operations: [HeaderEdit]
) -> LegacyRule {
    LegacyRule(id: id, name: "h", enabled: true, order: order, matcher: RuleMatcher(),
         action: .editHeaders(direction: direction, operations: operations))
}

private func breakpoint(_ direction: HTTPMessageDirection, order: Int = 0) -> LegacyRule {
    LegacyRule(id: UUID(), name: "p", enabled: true, order: order, matcher: RuleMatcher(),
         action: .breakpoint(direction: direction, mode: .fullBody))
}

private func code(_ summary: RuleMatchSummary, _ id: UUID) -> RuleOutcomeCode? {
    summary.outcomes.first { $0.ruleID == id }?.code
}

@Suite("RuleEvaluatorRewrite")
struct RuleEvaluatorRewriteTests {
    @Test func bodyRulesCollectedInOrderEvenWhenStoredOutOfOrder() throws {
        let ids = (0..<3).map { _ in UUID() }
        let rules = [bodyRule(ids[0], order: 2), bodyRule(ids[1], order: 0), bodyRule(ids[2], order: 1)]
        let decision = try LegacyRuleEvaluator.response(response(headers: text()), request: target(), snapshot: snapshot(rules))
        #expect(decision.bodyRewrites.map(\.ruleID) == [ids[1], ids[2], ids[0]])
        #expect(decision.matches.ruleIDs == [ids[1], ids[2], ids[0]])
        #expect(decision.matches.outcomes.map(\.code) == [.applied, .applied, .applied])
    }

    @Test func equalOrderKeepsStoredPosition() throws {
        let ids = (0..<3).map { _ in UUID() }
        let rules = ids.map { bodyRule($0, order: 5, direction: .request) }
        let decision = try LegacyRuleEvaluator.request(
            request(target(method: "POST"), headers: text()), snapshot: snapshot(rules))
        #expect(decision.bodyRewrites.map(\.ruleID) == ids)
    }

    @Test func requestBodyRuleMatchesOriginalRequestOnly() throws {
        // A Map Remote rule changes the effective target, but the body rule still matches the original one.
        let id = UUID()
        let remote = LegacyRule(id: UUID(), name: "m", enabled: true, order: 0, matcher: RuleMatcher(),
                          action: .mapRemote(MapRemoteAction(targetScheme: "https", targetHost: "other.test",
                                                             targetPort: 8443, path: .preserve)))
        let onOriginal = bodyRule(id, order: 1, direction: .request, matcher: RuleMatcher(hostPattern: "api.example.com"))
        let onRemote = bodyRule(UUID(), order: 2, direction: .request, matcher: RuleMatcher(hostPattern: "other.test"))
        let decision = try LegacyRuleEvaluator.request(
            request(target(method: "POST"), headers: text()), snapshot: snapshot([remote, onOriginal, onRemote]))
        #expect(decision.bodyRewrites.map(\.ruleID) == [id])
        #expect(!decision.matches.ruleIDs.contains(onRemote.id))
    }

    @Test func responseBodyRuleHonoursStatusRange() throws {
        let hit = bodyRule(order: 0, matcher: RuleMatcher(statusRange: 500...599))
        let miss = bodyRule(order: 1, matcher: RuleMatcher(statusRange: 200...299))
        let decision = try LegacyRuleEvaluator.response(
            response(503, headers: text()), request: target(), snapshot: snapshot([hit, miss]))
        #expect(decision.bodyRewrites.map(\.ruleID) == [hit.id])
        #expect(decision.matches.ruleIDs == [hit.id])
    }

    @Test func nonTextEffectiveContentTypeSkipsRule() throws {
        let rule = bodyRule()
        let decision = try LegacyRuleEvaluator.response(
            response(headers: text("image/png")), request: target(), snapshot: snapshot([rule]))
        #expect(decision.bodyRewrites.isEmpty)
        #expect(decision.matches.ruleIDs == [rule.id])
        #expect(code(decision.matches, rule.id) == .bodySkippedNotText)
        let none = try LegacyRuleEvaluator.response(response(), request: target(), snapshot: snapshot([rule]))
        #expect(code(none.matches, rule.id) == .bodySkippedNotText)
    }

    @Test func headerRuleCanMakeResponseTextLike() throws {
        let rewrite = bodyRule(order: 0)
        let edit = headerRule(order: 1, .response, [.set(name: "Content-Type", value: "text/plain")])
        let decision = try LegacyRuleEvaluator.response(
            response(headers: text("image/png")), request: target(), snapshot: snapshot([rewrite, edit]))
        #expect(decision.bodyRewrites.map(\.ruleID) == [rewrite.id])
        #expect(code(decision.matches, rewrite.id) == .applied)
        #expect(decision.effectiveHead.headers.values(for: "content-type") == ["text/plain"])
    }

    @Test func knownLengthOverCapSkips() throws {
        let rule = bodyRule()
        let limits = RulesLimits(rewriteBodyBytes: 100)
        let over = try LegacyRuleEvaluator.response(
            response(headers: text() + [HeaderField(name: "Content-Length", value: "101")]), request: target(),
            snapshot: snapshot([rule]), limits: limits)
        #expect(over.bodyRewrites.isEmpty)
        #expect(code(over.matches, rule.id) == .bodySkippedTooLarge)
        let exact = try LegacyRuleEvaluator.response(
            response(headers: text() + [HeaderField(name: "Content-Length", value: "100")]), request: target(),
            snapshot: snapshot([rule]), limits: limits)
        #expect(exact.bodyRewrites.map(\.ruleID) == [rule.id])
        let huge = try LegacyRuleEvaluator.response(
            response(headers: text() + [HeaderField(name: "Content-Length", value: "99999999999999999999999")]),
            request: target(), snapshot: snapshot([rule]), limits: limits)
        #expect(code(huge.matches, rule.id) == .bodySkippedTooLarge)
    }

    @Test func unknownLengthIsNotSkippedByEvaluator() throws {
        let rule = bodyRule()
        let limits = RulesLimits(rewriteBodyBytes: 100)
        let chunked = try LegacyRuleEvaluator.response(
            response(headers: text() + [HeaderField(name: "Transfer-Encoding", value: "chunked")]), request: target(),
            snapshot: snapshot([rule]), limits: limits)
        #expect(chunked.bodyRewrites.map(\.ruleID) == [rule.id])
        let junk = try LegacyRuleEvaluator.response(
            response(headers: text() + [HeaderField(name: "Content-Length", value: "abc")]), request: target(),
            snapshot: snapshot([rule]), limits: limits)
        #expect(junk.bodyRewrites.map(\.ruleID) == [rule.id])
    }

    @Test func headResponseSkipsNoBody() throws {
        let rule = bodyRule()
        let decision = try LegacyRuleEvaluator.response(
            response(headers: text()), request: target(method: "HEAD"), snapshot: snapshot([rule]))
        #expect(decision.bodyRewrites.isEmpty)
        #expect(code(decision.matches, rule.id) == .bodySkippedNoBody)
    }

    @Test func status204And304SkipNoBody() throws {
        let rule = bodyRule()
        for status in [100, 102, 204, 304] {
            let decision = try LegacyRuleEvaluator.response(
                response(status, headers: text()), request: target(), snapshot: snapshot([rule]))
            #expect(decision.bodyRewrites.isEmpty, "\(status)")
            #expect(code(decision.matches, rule.id) == .bodySkippedNoBody, "\(status)")
        }
    }

    @Test func rewrittenStatusToNoBodySkips() throws {
        let body = bodyRule(order: 1)
        let status = statusRule(order: 0, status: 204)
        let decision = try LegacyRuleEvaluator.response(
            response(200, headers: text()), request: target(), snapshot: snapshot([status, body]))
        #expect(decision.statusRewrite == 204)
        #expect(decision.bodyRewrites.isEmpty)
        #expect(code(decision.matches, body.id) == .bodySkippedNoBody)
    }

    @Test func zeroContentLengthSkipsNoBody() throws {
        let rule = bodyRule()
        let decision = try LegacyRuleEvaluator.response(
            response(headers: text() + [HeaderField(name: "Content-Length", value: " 0 ")]), request: target(),
            snapshot: snapshot([rule]))
        #expect(code(decision.matches, rule.id) == .bodySkippedNoBody)
    }

    @Test func upgradeResponseGetsUnsupportedUpgradeAction() throws {
        let rule = bodyRule()
        let switching = try LegacyRuleEvaluator.response(
            response(101, headers: text()), request: target(), snapshot: snapshot([rule]))
        #expect(switching.bodyRewrites.isEmpty)
        #expect(code(switching.matches, rule.id) == .unsupportedUpgradeAction)
        let asked = try LegacyRuleEvaluator.response(
            response(headers: text()), request: target(), snapshot: snapshot([rule]), requestWasUpgradeCandidate: true)
        #expect(asked.bodyRewrites.isEmpty)
        #expect(code(asked.matches, rule.id) == .unsupportedUpgradeAction)
        let upgradeRequest = try LegacyRuleEvaluator.request(
            request(target(method: "POST"), headers: [HeaderField(name: "Connection", value: "Upgrade"),
                                                      HeaderField(name: "Upgrade", value: "websocket")] + text()),
            snapshot: snapshot([bodyRule(direction: .request)]))
        #expect(upgradeRequest.bodyRewrites.isEmpty)
        #expect(upgradeRequest.matches.outcomes.map(\.code) == [.unsupportedUpgradeAction])
    }

    @Test func breakpointSameDirectionEmptiesBodyRewrites() throws {
        let rule = bodyRule(order: 0)
        let pause = breakpoint(.response, order: 1)
        let decision = try LegacyRuleEvaluator.response(
            response(headers: text()), request: target(), snapshot: snapshot([rule, pause]))
        #expect(decision.bodyRewrites.isEmpty)
        #expect(decision.breakpoint == .fullBody)
        #expect(code(decision.matches, rule.id) == .bodySkippedBreakpoint)
        #expect(code(decision.matches, pause.id) == .applied)
        let requestPause = breakpoint(.request, order: 1)
        let requestDecision = try LegacyRuleEvaluator.request(
            request(target(method: "POST"), headers: text()), snapshot: snapshot([bodyRule(direction: .request), requestPause]))
        #expect(requestDecision.bodyRewrites.isEmpty)
        #expect(requestDecision.breakpoint == .fullBody)
        #expect(requestDecision.matches.outcomes.first?.code == .bodySkippedBreakpoint)
    }

    @Test func breakpointOtherDirectionDoesNotBlockRewrites() throws {
        let rule = bodyRule()
        let decision = try LegacyRuleEvaluator.response(
            response(headers: text()), request: target(), snapshot: snapshot([rule, breakpoint(.request, order: 1)]))
        #expect(decision.bodyRewrites.map(\.ruleID) == [rule.id])
        let requestRule = bodyRule(direction: .request)
        let requestDecision = try LegacyRuleEvaluator.request(
            request(target(method: "POST"), headers: text()),
            snapshot: snapshot([requestRule, breakpoint(.response, order: 1)]))
        #expect(requestDecision.bodyRewrites.map(\.ruleID) == [requestRule.id])
    }

    @Test func localRouteSkipsRequestBodyRules() throws {
        let local = LegacyRule(id: UUID(), name: "l", enabled: true, order: 0, matcher: RuleMatcher(),
                         action: .mapLocal(MapLocalAction(assetID: UUID(), headers: [])))
        let directory = LegacyRule(id: UUID(), name: "d", enabled: true, order: 0, matcher: RuleMatcher(),
                             action: .mapLocalDirectory(MapLocalDirectoryAction(bookmark: Data([1]), displayName: "d")))
        for map in [local, directory] {
            let rule = bodyRule(order: 1, direction: .request)
            let decision = try LegacyRuleEvaluator.request(
                request(target(method: "POST"), headers: text()), snapshot: snapshot([map, rule]))
            #expect(decision.bodyRewrites.isEmpty)
            #expect(code(decision.matches, rule.id) == .bodySkippedLocalRoute)
            // The route is decided after the whole pass: a body rule listed before the Map is skipped too.
            let early = bodyRule(order: 0, direction: .request)
            let reversed = try LegacyRuleEvaluator.request(
                request(target(method: "POST"), headers: text()), snapshot: snapshot([early, map]))
            #expect(code(reversed.matches, early.id) == .bodySkippedLocalRoute)
        }
    }

    @Test func mapRemoteRouteStillCollectsRequestBodyRules() throws {
        let remote = LegacyRule(id: UUID(), name: "m", enabled: true, order: 0, matcher: RuleMatcher(),
                          action: .mapRemote(MapRemoteAction(targetScheme: "https", targetHost: "other.test",
                                                             targetPort: 8443, path: .preserve)))
        let rule = bodyRule(order: 1, direction: .request)
        let decision = try LegacyRuleEvaluator.request(
            request(target(method: "POST"), headers: text()), snapshot: snapshot([remote, rule]))
        #expect(decision.bodyRewrites.map(\.ruleID) == [rule.id])
    }

    @Test func statusRewriteFirstWinsOthersShadowed() throws {
        let rules = [statusRule(order: 0, status: 404), statusRule(order: 1, status: 500)]
        let decision = try LegacyRuleEvaluator.response(response(), request: target(), snapshot: snapshot(rules))
        #expect(decision.statusRewrite == 404)
        #expect(code(decision.matches, rules[0].id) == .applied)
        #expect(code(decision.matches, rules[1].id) == .shadowed)
        #expect(decision.matches.ruleIDs == rules.map(\.id))
    }

    @Test func statusRewriteSetsReasonNil() throws {
        let decision = try LegacyRuleEvaluator.response(
            response(200, reason: "Fine", headers: [HeaderField(name: "X-A", value: "1")]), request: target(),
            snapshot: snapshot([statusRule(status: 418)]))
        #expect(decision.effectiveHead == .response(status: 418, reason: nil, headers: [HeaderField(name: "X-A", value: "1")]))
        let untouched = try LegacyRuleEvaluator.response(response(200, reason: "Fine"), request: target(), snapshot: snapshot([]))
        #expect(untouched.effectiveHead == .response(status: 200, reason: "Fine", headers: []))
        #expect(untouched.statusRewrite == nil)
    }

    @Test func statusRewriteWithStatusRangeOnlyMatchesRange() throws {
        let rule = statusRule(status: 200, matcher: RuleMatcher(statusRange: 500...599))
        let hit = try LegacyRuleEvaluator.response(response(503), request: target(), snapshot: snapshot([rule]))
        #expect(hit.statusRewrite == 200)
        let miss = try LegacyRuleEvaluator.response(response(404), request: target(), snapshot: snapshot([rule]))
        #expect(miss.statusRewrite == nil)
        #expect(miss.matches.ruleIDs.isEmpty)
    }

    @Test func statusRewriteSkippedForLocalByDefault() throws {
        let rule = statusRule()
        let decision = try LegacyRuleEvaluator.response(
            response(), request: target(), snapshot: snapshot([rule]), isLocalResponse: true)
        #expect(decision.statusRewrite == nil)
        #expect(code(decision.matches, rule.id) == .statusSkippedLocal)
        #expect(decision.effectiveHead == response())
        // A skipped rule does not shadow a later one that includes local responses.
        let later = statusRule(order: 1, status: 410, includeLocal: true)
        let both = try LegacyRuleEvaluator.response(
            response(), request: target(), snapshot: snapshot([rule, later]), isLocalResponse: true)
        #expect(both.statusRewrite == 410)
        #expect(code(both.matches, rule.id) == .statusSkippedLocal)
        #expect(code(both.matches, later.id) == .applied)
    }

    @Test func statusRewriteAppliesToLocalWhenIncluded() throws {
        let rule = statusRule(status: 503, includeLocal: true)
        let decision = try LegacyRuleEvaluator.response(
            response(), request: target(), snapshot: snapshot([rule]), isLocalResponse: true)
        #expect(decision.statusRewrite == 503)
        #expect(code(decision.matches, rule.id) == .applied)
        let origin = try LegacyRuleEvaluator.response(response(), request: target(), snapshot: snapshot([rule]))
        #expect(origin.statusRewrite == 503)
    }

    @Test func statusRewriteOnUpgradeResponseUnsupported() throws {
        let rule = statusRule()
        let switching = try LegacyRuleEvaluator.response(response(101), request: target(), snapshot: snapshot([rule]))
        #expect(switching.statusRewrite == nil)
        #expect(code(switching.matches, rule.id) == .unsupportedUpgradeAction)
        #expect(switching.effectiveHead == response(101))
        let asked = try LegacyRuleEvaluator.response(
            response(400), request: target(), snapshot: snapshot([rule]), requestWasUpgradeCandidate: true)
        #expect(asked.statusRewrite == nil)
        #expect(code(asked.matches, rule.id) == .unsupportedUpgradeAction)
    }

    @Test func rulesMatchedSummaryCountsNewRules() throws {
        let body = bodyRule(order: 0)
        let status = statusRule(order: 1)
        let edit = headerRule(order: 2, .response, [.set(name: "X-A", value: "1")])
        let decision = try LegacyRuleEvaluator.response(
            response(headers: text()), request: target(), snapshot: snapshot([body, status, edit]))
        #expect(decision.matches.total == 3)
        #expect(decision.matches.revision == 9)
        #expect(decision.matches.ruleIDs == [body.id, status.id, edit.id])
        #expect(decision.matches.outcomes.map(\.ruleID) == [body.id, status.id, edit.id])
    }

    @Test func noNewRulesGivesEmptyRewritesAndIdenticalDecision() throws {
        let edit = headerRule(.response, [.set(name: "X-A", value: "1")])
        let pause = breakpoint(.response, order: 1)
        let rules = [edit, pause]
        let head = response(200, reason: "OK", headers: text())
        let decision = try LegacyRuleEvaluator.response(head, request: target(), snapshot: snapshot(rules))
        #expect(decision.bodyRewrites.isEmpty)
        #expect(decision.statusRewrite == nil)
        #expect(decision.effectiveHead == .response(
            status: 200, reason: "OK", headers: text() + [HeaderField(name: "X-A", value: "1")]))
        #expect(decision.breakpoint == .fullBody)
        #expect(decision.matches.outcomes.map(\.code) == [.applied, .applied])
        let requestDecision = try LegacyRuleEvaluator.request(
            request(), snapshot: snapshot([headerRule(.request, [.set(name: "X-B", value: "2")])]))
        #expect(requestDecision.bodyRewrites.isEmpty)
        #expect(requestDecision.route == .original)
    }
}
