import Foundation
import Testing
import FlowStore
@testable import RulesEngine

private func target(
    _ scheme: String = "https", host: String = "api.example.com", port: Int = 443,
    method: String = "GET", path: String = "/v1/items?a=1&a=2"
) -> HTTPMessageTarget {
    HTTPMessageTarget(scheme: scheme, host: host, port: port, method: method, pathAndQuery: path)
}

private func request(_ target: HTTPMessageTarget = target(), headers: [HeaderField] = []) -> HTTPMessageHead {
    .request(target, headers: headers)
}

private func response(_ status: Int = 200, headers: [HeaderField] = []) -> HTTPMessageHead {
    .response(status: status, reason: nil, headers: headers)
}

private func rule(
    _ id: UUID = UUID(), order: Int = 0, enabled: Bool = true, matcher: RuleMatcher = RuleMatcher(),
    action: LegacyRuleAction
) -> LegacyRule {
    LegacyRule(id: id, name: "r", enabled: enabled, order: order, matcher: matcher, action: action)
}

private func remote(_ host: String = "other.test", port: Int = 8443) -> MapRemoteAction {
    MapRemoteAction(targetScheme: "https", targetHost: host, targetPort: port, path: .preserve)
}

private func snapshot(_ rules: [LegacyRule], revision: UInt64 = 7) -> LegacyRuleSnapshot {
    LegacyRuleSnapshot(revision: revision, rules: rules)
}

private func expectRuleMutation(_ expected: HTTPMutationError, _ operation: () throws -> Void) {
    do {
        try operation()
        Issue.record("expected rule mutation failure")
    } catch let error as RuleEvaluationError {
        #expect(error.mutation == expected)
        #expect(error.matches.total > 0)
    } catch {
        Issue.record("unexpected rule evaluation error: \(error)")
    }
}

private func expectOutcomes(_ expected: [(UUID, RuleOutcomeCode)], _ operation: () throws -> Void,
                            sourceLocation: SourceLocation = #_sourceLocation) {
    do {
        try operation()
        Issue.record("expected rule mutation failure", sourceLocation: sourceLocation)
    } catch let error as RuleEvaluationError {
        #expect(error.matches.outcomes.map(\.ruleID) == expected.map(\.0), sourceLocation: sourceLocation)
        #expect(error.matches.outcomes.map(\.code) == expected.map(\.1), sourceLocation: sourceLocation)
    } catch {
        Issue.record("unexpected rule evaluation error: \(error)", sourceLocation: sourceLocation)
    }
}

@Suite("RuleEvaluation")
struct RuleEvaluationTests {
    @Test func firstMapDoesNotSwallowHeaderOrBreakpoint() throws {
        let firstMap = remote("first.test")
        let secondMap = remote("second.test")
        let ids = (0..<6).map { _ in UUID() }
        let rules = [
            rule(ids[0], order: 0, action: .editHeaders(direction: .request, operations: [
                .append(name: "Set-Cookie", value: "a=1")])),
            rule(ids[1], order: 1, action: .mapRemote(firstMap)),
            rule(ids[2], order: 2, action: .breakpoint(direction: .request, mode: .headers)),
            rule(ids[3], order: 3, action: .mapRemote(secondMap)),
            rule(ids[4], order: 4, action: .editHeaders(direction: .request, operations: [
                .append(name: "Set-Cookie", value: "b=2")])),
            rule(ids[5], order: 5, action: .breakpoint(direction: .request, mode: .fullBody)),
        ]
        let decision = try LegacyRuleEvaluator.request(request(), snapshot: snapshot(rules))
        #expect(decision.route == .remote(firstMap))
        #expect(decision.effectiveHead.headers.values(for: "Set-Cookie") == ["a=1", "b=2"])
        #expect(decision.breakpoint == .fullBody)
        #expect(decision.matches.ruleIDs == ids)
        #expect(decision.matches.revision == 7)
        #expect(decision.matches.total == 6)
        let shadowed = decision.matches.outcomes.filter { $0.code == .shadowed }.map(\.ruleID)
        #expect(shadowed == [ids[3]])
        #expect(decision.matches.outcomes.filter { $0.code == .applied }.count == 5)
    }

    @Test func headerEditsRunInOrderNotByActionTypeAndKeepOriginalContext() throws {
        let rules = [
            rule(order: 1, action: .editHeaders(direction: .request, operations: [
                .set(name: "X-A", value: "second")])),
            rule(order: 0, action: .editHeaders(direction: .request, operations: [
                .set(name: "X-A", value: "first"), .append(name: "x-b", value: "1")])),
        ]
        let original = request(headers: [HeaderField(name: "Accept", value: "*/*")])
        let decision = try LegacyRuleEvaluator.request(original, snapshot: snapshot(rules))
        #expect(decision.effectiveHead.headers.values(for: "X-A") == ["second"])
        #expect(decision.effectiveHead.headers.values(for: "X-B") == ["1"])
        #expect(original.headers.count == 1)
        #expect(decision.route == .original)
        #expect(decision.breakpoint == nil)
    }

    @Test func equalOrderKeepsStoredPosition() throws {
        let rules = [
            rule(order: 3, action: .editHeaders(direction: .request, operations: [.append(name: "X", value: "1")])),
            rule(order: 3, action: .editHeaders(direction: .request, operations: [.append(name: "X", value: "2")])),
            rule(order: 3, action: .editHeaders(direction: .request, operations: [.append(name: "X", value: "3")])),
        ]
        let decision = try LegacyRuleEvaluator.request(request(), snapshot: snapshot(rules))
        #expect(decision.effectiveHead.headers.values(for: "X") == ["1", "2", "3"])
    }

    @Test func disabledRulesNeverRun() throws {
        let rules = [
            rule(enabled: false, action: .mapRemote(remote())),
            rule(enabled: false, action: .breakpoint(direction: .request, mode: .headers)),
            rule(enabled: false, action: .editHeaders(direction: .request, operations: [.append(name: "X", value: "1")])),
        ]
        let decision = try LegacyRuleEvaluator.request(request(), snapshot: snapshot(rules))
        #expect(decision.route == .original)
        #expect(decision.breakpoint == nil)
        #expect(decision.effectiveHead == request())
        #expect(decision.matches.total == 0)
    }

    @Test func setReplacesAtFirstPositionAndKeepsRepeatedFields() throws {
        let headers = [
            HeaderField(name: "A", value: "1"), HeaderField(name: "Set-Cookie", value: "x=1"),
            HeaderField(name: "a", value: "2"), HeaderField(name: "Set-Cookie", value: "y=2"),
        ]
        let rules = [rule(action: .editHeaders(direction: .response, operations: [
            .set(name: "A", value: "new"), .remove(name: "missing"), .set(name: "Fresh", value: "f")]))]
        let decision = try LegacyRuleEvaluator.response(response(headers: headers), request: target(), snapshot: snapshot(rules))
        #expect(decision.effectiveHead.headers.map(\.name) == ["A", "Set-Cookie", "Set-Cookie", "Fresh"])
        #expect(decision.effectiveHead.headers.values(for: "A") == ["new"])
        #expect(decision.effectiveHead.headers.values(for: "Set-Cookie") == ["x=1", "y=2"])
    }

    @Test func removeDeletesEveryCaseInsensitiveOccurrence() throws {
        let headers = [HeaderField(name: "X-Y", value: "1"), HeaderField(name: "Keep", value: "k"),
                       HeaderField(name: "x-y", value: "2")]
        let rules = [rule(action: .editHeaders(direction: .request, operations: [.remove(name: "X-Y")]))]
        let decision = try LegacyRuleEvaluator.request(request(headers: headers), snapshot: snapshot(rules))
        #expect(decision.effectiveHead.headers == [HeaderField(name: "Keep", value: "k")])
    }

    // MARK: matching

    @Test func exactAndPrefixPathsKeepEncodingAndQueryOrder() throws {
        let exact = rule(matcher: RuleMatcher(path: .exact("/a%2Fb?x=1&x=2&y")), action: .breakpoint(direction: .request, mode: .headers))
        let prefix = rule(matcher: RuleMatcher(path: .prefix("/a%2F")), action: .breakpoint(direction: .request, mode: .headers))
        let decoded = rule(matcher: RuleMatcher(path: .exact("/a/b?x=1&x=2&y")), action: .breakpoint(direction: .request, mode: .headers))
        let reordered = rule(matcher: RuleMatcher(path: .exact("/a%2Fb?y&x=1&x=2")), action: .breakpoint(direction: .request, mode: .headers))
        let upper = rule(matcher: RuleMatcher(path: .prefix("/A%2F")), action: .breakpoint(direction: .request, mode: .headers))
        let partial = rule(matcher: RuleMatcher(path: .prefix("/a%2Fb?x=1&x=2&y&z")), action: .breakpoint(direction: .request, mode: .headers))
        let head = request(target(path: "/a%2Fb?x=1&x=2&y"))
        let decision = try LegacyRuleEvaluator.request(head, snapshot: snapshot([exact, prefix, decoded, reordered, upper, partial]))
        #expect(decision.matches.ruleIDs == [exact.id, prefix.id])
    }

    @Test func prefixHasNoPathSegmentBoundary() throws {
        let prefix = rule(matcher: RuleMatcher(path: .prefix("/v1/it")), action: .breakpoint(direction: .request, mode: .headers))
        let decision = try LegacyRuleEvaluator.request(request(), snapshot: snapshot([prefix]))
        #expect(decision.matches.total == 1)
    }

    @Test func schemePortMethodAreAnded() throws {
        func hits(_ matcher: RuleMatcher) throws -> Int {
            try LegacyRuleEvaluator.request(request(), snapshot: snapshot([
                rule(matcher: matcher, action: .breakpoint(direction: .request, mode: .headers))])).matches.total
        }
        #expect(try hits(RuleMatcher(scheme: "https", port: 443, method: "GET")) == 1)
        #expect(try hits(RuleMatcher(scheme: "HTTPS")) == 1)
        #expect(try hits(RuleMatcher(scheme: "http")) == 0)
        #expect(try hits(RuleMatcher(port: 80)) == 0)
        #expect(try hits(RuleMatcher(method: "get")) == 0)
        #expect(try hits(RuleMatcher(scheme: "https", hostPattern: "api.example.com", port: 443, method: "GET", path: .prefix("/v1"))) == 1)
        #expect(try hits(RuleMatcher(scheme: "https", hostPattern: "api.example.com", port: 443, method: "POST", path: .prefix("/v1"))) == 0)
    }

    @Test func wildcardHostSemanticsMatchHostPattern() throws {
        func hits(_ pattern: String, host: String) throws -> Bool {
            let decision = try LegacyRuleEvaluator.request(request(target(host: host)), snapshot: snapshot([
                rule(matcher: RuleMatcher(hostPattern: pattern), action: .breakpoint(direction: .request, mode: .headers))]))
            return decision.matches.total == 1
        }
        let cases: [(String, String)] = [
            ("*.example.com", "a.b.example.com"), ("*.example.com", "example.com"), ("*", "x.test"),
            ("Example.COM.", "example.com"), ("", "example.com"), ("*.example.com", "badexample.com"),
        ]
        for (pattern, host) in cases {
            #expect(try hits(pattern, host: host) == HostPattern.matches(pattern, host: host), "\(pattern) ~ \(host)")
        }
    }

    @Test func ipv6SpellingsMatchAsAddresses() throws {
        func hits(_ pattern: String, host: String) throws -> Bool {
            let decision = try LegacyRuleEvaluator.request(request(target("http", host: host, port: 8080)), snapshot: snapshot([
                rule(matcher: RuleMatcher(hostPattern: pattern, port: 8080), action: .breakpoint(direction: .request, mode: .headers))]))
            return decision.matches.total == 1
        }
        #expect(try hits("::1", host: "0:0:0:0:0:0:0:1"))
        #expect(try hits("[::1]", host: "::1"))
        #expect(try hits("2001:DB8::1", host: "2001:db8:0:0:0:0:0:1"))
        #expect(try !hits("::2", host: "::1"))
    }

    @Test func requestMatchingUsesOriginalAndDoesNotRematchAfterRewrite() throws {
        let rewrite = rule(order: 0, action: .editHeaders(direction: .request, operations: [.set(name: "Host-Hint", value: "x")]))
        let sees = rule(order: 1, matcher: RuleMatcher(hostPattern: "other.test"), action: .breakpoint(direction: .request, mode: .headers))
        let map = rule(order: 2, action: .mapRemote(remote("other.test")))
        let decision = try LegacyRuleEvaluator.request(request(), snapshot: snapshot([rewrite, sees, map]))
        #expect(decision.route == .remote(remote("other.test")))
        #expect(decision.breakpoint == nil)
        #expect(decision.matches.ruleIDs == [rewrite.id, map.id])
    }

    @Test func responseRulesMatchOriginalRequestAndStatus() throws {
        let ok = rule(order: 0, matcher: RuleMatcher(statusRange: 200...299), action: .editHeaders(direction: .response, operations: [.append(name: "X-S", value: "ok")]))
        let err = rule(order: 1, matcher: RuleMatcher(statusRange: 500...599), action: .editHeaders(direction: .response, operations: [.append(name: "X-S", value: "err")]))
        let any = rule(order: 2, action: .breakpoint(direction: .response, mode: .headers))
        let otherHost = rule(order: 3, matcher: RuleMatcher(hostPattern: "elsewhere.test"), action: .breakpoint(direction: .response, mode: .headers))
        let requestOnly = rule(order: 4, action: .editHeaders(direction: .request, operations: [.append(name: "X-R", value: "1")]))
        let rules = snapshot([ok, err, any, otherHost, requestOnly])
        let first = try LegacyRuleEvaluator.response(response(204), request: target(), snapshot: rules)
        #expect(first.matches.ruleIDs == [ok.id, any.id])
        #expect(first.effectiveHead.headers.values(for: "X-S") == ["ok"])
        #expect(first.breakpoint == .headers)
        let second = try LegacyRuleEvaluator.response(response(503), request: target(), snapshot: rules)
        #expect(second.matches.ruleIDs == [err.id, any.id])
        #expect(second.effectiveHead.headers.values(for: "X-S") == ["err"])
    }

    @Test func statusRangedRulesNeverFireOnRequests() throws {
        let ranged = rule(matcher: RuleMatcher(statusRange: 200...599), action: .breakpoint(direction: .request, mode: .headers))
        let decision = try LegacyRuleEvaluator.request(request(), snapshot: snapshot([ranged]))
        #expect(decision.matches.total == 0)
    }

    @Test func wrongMessageKindFails() {
        #expect(throws: HTTPMutationError.self) {
            try LegacyRuleEvaluator.request(response(), snapshot: snapshot([]))
        }
        #expect(throws: HTTPMutationError.self) {
            try LegacyRuleEvaluator.response(request(), request: target(), snapshot: snapshot([]))
        }
    }

    // MARK: summary bound, upgrade, execution-time validation

    @Test func summaryIsBoundedButEveryRuleStillRuns() throws {
        let rules = (0..<300).map { index in
            rule(order: index, action: .editHeaders(direction: .request, operations: [.set(name: "X-N", value: "\(index)")]))
        }
        let decision = try LegacyRuleEvaluator.request(request(), snapshot: snapshot(rules))
        // Every rule ran: the last set wins.
        #expect(decision.effectiveHead.headers.values(for: "X-N") == ["299"])
        #expect(decision.matches.total == 300)
        #expect(decision.matches.ruleIDs.count == RuleMatchSummary.maxRecords)
        #expect(decision.matches.omitted == 44)
    }

    @Test func upgradeCandidatesSkipMapAndBreakpointWithCode() throws {
        let headers = [
            HeaderField(name: "Connection", value: "Upgrade"), HeaderField(name: "Upgrade", value: "websocket"),
            HeaderField(name: "Sec-WebSocket-Key", value: "k"),
        ]
        let map = rule(order: 0, action: .mapRemote(remote()))
        let local = rule(order: 1, action: .mapLocal(MapLocalAction(assetID: UUID(), headers: [])))
        let pause = rule(order: 2, action: .breakpoint(direction: .request, mode: .fullBody))
        let edit = rule(order: 3, action: .editHeaders(direction: .request, operations: [.append(name: "X-T", value: "1")]))
        let decision = try LegacyRuleEvaluator.request(request(headers: headers), snapshot: snapshot([map, local, pause, edit]))
        #expect(decision.route == .original)
        #expect(decision.breakpoint == nil)
        #expect(decision.effectiveHead.headers.values(for: "X-T") == ["1"])
        let skipped = decision.matches.outcomes.filter { $0.code == .unsupportedUpgradeAction }.map(\.ruleID)
        #expect(skipped == [map.id, local.id, pause.id])
        #expect(decision.matches.total == 4)
    }

    @Test func upgradeHandshakeFieldsCannotBeEdited() {
        let headers = [
            HeaderField(name: "Connection", value: "Upgrade"), HeaderField(name: "Upgrade", value: "websocket"),
            HeaderField(name: "Sec-WebSocket-Key", value: "k"),
        ]
        let rules = [rule(action: .editHeaders(direction: .request, operations: [.set(name: "Sec-WebSocket-Key", value: "z")]))]
        expectRuleMutation(HTTPMutationError(code: .protectedHeader, field: .header(name: "Sec-WebSocket-Key"))) {
            _ = try LegacyRuleEvaluator.request(request(headers: headers), snapshot: snapshot(rules))
        }
        // The same edit on an ordinary request is fine.
        #expect(throws: Never.self) {
            _ = try LegacyRuleEvaluator.request(request(), snapshot: snapshot(rules))
        }
    }

    @Test func upgradeResponsesSkipBreakpointsEvenWhenRequestFlagIsPassed() throws {
        let pause = rule(action: .breakpoint(direction: .response, mode: .headers))
        let switching = try LegacyRuleEvaluator.response(
            response(101, headers: [HeaderField(name: "Upgrade", value: "websocket")]),
            request: target(), snapshot: snapshot([pause]))
        #expect(switching.breakpoint == nil)
        #expect(switching.matches.outcomes.map(\.code) == [.unsupportedUpgradeAction])
        let failed = try LegacyRuleEvaluator.response(response(400), request: target(), snapshot: snapshot([pause]), requestWasUpgradeCandidate: true)
        #expect(failed.breakpoint == nil)
        #expect(failed.matches.outcomes.map(\.code) == [.unsupportedUpgradeAction])
        let plain = try LegacyRuleEvaluator.response(response(400), request: target(), snapshot: snapshot([pause]))
        #expect(plain.breakpoint == .headers)
    }

    @Test func diskConfigIsValidatedAtExecutionTime() {
        let bad = [rule(action: .editHeaders(direction: .request, operations: [.set(name: "Content-Length", value: "1")]))]
        expectRuleMutation(HTTPMutationError(code: .protectedHeader, field: .header(name: "Content-Length"))) {
            _ = try LegacyRuleEvaluator.request(request(), snapshot: snapshot(bad))
        }
        let injection = [rule(action: .editHeaders(direction: .response, operations: [.append(name: "X", value: "a\r\nInjected: 1")]))]
        expectRuleMutation(HTTPMutationError(code: .invalidHeaderValue, field: .headerValue(name: "X"))) {
            _ = try LegacyRuleEvaluator.response(response(), request: target(), snapshot: snapshot(injection))
        }
    }

    @Test func accumulatedEditsStillRespectBlockLimits() {
        let big = String(repeating: "v", count: 8_000)
        let rules = (0..<9).map { index in
            rule(order: index, action: .editHeaders(direction: .request, operations: [.append(name: "X-\(index)", value: big)]))
        }
        expectRuleMutation(HTTPMutationError(code: .headerBlockTooLarge, field: .headers)) {
            _ = try LegacyRuleEvaluator.request(request(), snapshot: snapshot(rules))
        }
    }

    // Phase fix I2b: a rejected edit is never reported as applied (provenance and HAR export).
    @Test func rejectedEditIsRecordedAsRejectedAfterEarlierAppliedRules() {
        let ids = (0..<3).map { _ in UUID() }
        let requestRules = [
            rule(ids[0], order: 0, action: .editHeaders(direction: .request, operations: [.set(name: "X-Ok", value: "1")])),
            rule(ids[1], order: 1, action: .breakpoint(direction: .request, mode: .headers)),
            rule(ids[2], order: 2, action: .editHeaders(direction: .request, operations: [.set(name: "Content-Length", value: "1")])),
        ]
        expectOutcomes([(ids[0], .applied), (ids[1], .applied), (ids[2], .rejected)]) {
            _ = try LegacyRuleEvaluator.request(request(), snapshot: snapshot(requestRules))
        }
        let responseRules = [
            rule(ids[0], order: 0, action: .editHeaders(direction: .response, operations: [.set(name: "X-Ok", value: "1")])),
            rule(ids[1], order: 1, action: .editHeaders(direction: .response, operations: [.append(name: "X", value: "a\r\nB: 1")])),
        ]
        expectOutcomes([(ids[0], .applied), (ids[1], .rejected)]) {
            _ = try LegacyRuleEvaluator.response(response(), request: target(), snapshot: snapshot(responseRules))
        }
    }

    @Test func blockLimitFailureRecordsEveryContributingEditAsRejected() {
        let big = String(repeating: "v", count: 8_000)
        let ids = (0..<10).map { _ in UUID() }
        var rules = (0..<9).map { index in
            rule(ids[index], order: index, action: .editHeaders(direction: .request, operations: [.append(name: "X-\(index)", value: big)]))
        }
        rules.append(rule(ids[9], order: 9, action: .breakpoint(direction: .request, mode: .headers)))
        expectOutcomes(ids.prefix(9).map { ($0, .rejected) } + [(ids[9], .applied)]) {
            _ = try LegacyRuleEvaluator.request(request(), snapshot: snapshot(rules))
        }
        let responseRules = (0..<9).map { index in
            rule(ids[index], order: index, action: .editHeaders(direction: .response, operations: [.append(name: "X-\(index)", value: big)]))
        }
        expectOutcomes(ids.prefix(9).map { ($0, .rejected) }) {
            _ = try LegacyRuleEvaluator.response(response(), request: target(), snapshot: snapshot(responseRules))
        }
    }

    @Test func unchangedFinalHeadsSkipBlockValidationEvenWhenEditsMatch() throws {
        let headers = (0..<300).map { HeaderField(name: "X-\($0)", value: "original-\($0)") }
        let requestRules = [rule(order: 0, action: .editHeaders(direction: .request, operations: [
            .set(name: "X-0", value: "temporary")
        ])), rule(order: 1, action: .editHeaders(direction: .request, operations: [
            .set(name: "X-0", value: "original-0")
        ]))]
        let requestDecision = try LegacyRuleEvaluator.request(request(headers: headers), snapshot: snapshot(requestRules))
        #expect(requestDecision.effectiveHead.headers == headers)
        #expect(requestDecision.matches.total == 2)
        let responseRule = rule(action: .editHeaders(direction: .response, operations: [
            .set(name: "X-0", value: "original-0")
        ]))
        let responseDecision = try LegacyRuleEvaluator.response(response(headers: headers), request: target(), snapshot: snapshot([responseRule]))
        #expect(responseDecision.effectiveHead.headers == headers)
        #expect(responseDecision.matches.total == 1)
    }

    // MARK: values

    @Test func snapshotRoundTripsThroughJSON() throws {
        let rules = [
            rule(matcher: RuleMatcher(scheme: "https", hostPattern: "*.x.test", port: 8443, method: "POST",
                                      path: .prefix("/p"), statusRange: 400...499),
                 action: .editHeaders(direction: .response, operations: [.set(name: "A", value: "b"), .remove(name: "C")])),
            rule(action: .mapRemote(MapRemoteAction(targetScheme: "http", targetHost: "h.test", targetPort: 81, path: .replace("/z?q=1"), preserveCredentials: true))),
            rule(action: .mapLocal(MapLocalAction(assetID: UUID(), status: 404, headers: [HeaderField(name: "Content-Type", value: "text/plain")]))),
            rule(action: .breakpoint(direction: .request, mode: .fullBody)),
        ]
        let original = LegacyRuleSnapshot(revision: 9, rules: rules)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LegacyRuleSnapshot.self, from: data)
        #expect(decoded == original)
        #expect(decoded.schemaVersion == 1)
    }

    @Test func limitsDefaultsMatchThePlanTable() {
        let limits = RulesLimits()
        #expect(limits.configBytes == 8_388_608)
        #expect(limits.fieldBytes == 8_192)
        #expect(limits.recordedMatches == 256)
        #expect(limits.ticketCount == 64)
        #expect(limits.ticketsPerContext == 8)
        #expect(limits.ticketSeconds == 120)
        #expect(limits.breakpointBodyBytes == 52_428_800)
        #expect(limits.breakpointSpoolBytes == 268_435_456)
        #expect(limits.editorBodyBytes == 8_388_608)
        #expect(limits.editorMemoryBytes == 33_554_432)
        #expect(limits.ioChunkBytes == 65_536)
        #expect(limits.ioBufferBytes == 4_194_304)
        #expect(limits.assetFileBytes == 536_870_912)
        #expect(limits.assetStoreBytes == 2_147_483_648)
        #expect(limits.composeBodyBytes == 536_870_912)
        #expect(limits.composeSpoolBytes == 1_073_741_824)
        #expect(limits.composeSends == 10)
        #expect(limits.minimumFreeDiskBytes == 268_435_456)
        #expect(limits.headerBytes == 65_536)
        #expect(limits.headerFields == 256)
    }

    @Test func ruleValidationChecksFieldsAndSizes() throws {
        let valid = rule(matcher: RuleMatcher(scheme: "https", hostPattern: "*.example.com", port: 443, method: "GET", path: .prefix("/a")),
                         action: .mapRemote(remote()))
        try valid.validate()
        func code(_ rule: LegacyRule) -> RuleValidationError.Code? {
            do { try rule.validate(); return nil } catch let error as RuleValidationError { return error.code } catch { return nil }
        }
        let breakpoint = LegacyRuleAction.breakpoint(direction: .request, mode: .headers)
        #expect(code(rule(matcher: RuleMatcher(scheme: "ftp"), action: breakpoint)) == .invalidScheme)
        #expect(code(rule(matcher: RuleMatcher(hostPattern: "a b"), action: breakpoint)) == .invalidHostPattern)
        #expect(code(rule(matcher: RuleMatcher(port: 0), action: breakpoint)) == .invalidPort)
        #expect(code(rule(matcher: RuleMatcher(port: 65_536), action: breakpoint)) == .invalidPort)
        #expect(code(rule(matcher: RuleMatcher(method: "GE T"), action: breakpoint)) == .invalidMethod)
        #expect(code(rule(matcher: RuleMatcher(method: "TRACE"), action: breakpoint)) == nil)
        #expect(code(rule(matcher: RuleMatcher(method: "PURGE"), action: breakpoint)) == nil)
        #expect(code(rule(matcher: RuleMatcher(path: .exact("/a\r\nb")), action: breakpoint)) == .invalidPath)
        #expect(code(rule(matcher: RuleMatcher(path: .exact("/a#frag")), action: breakpoint)) == .invalidPath)
        #expect(code(rule(matcher: RuleMatcher(statusRange: 200...299), action: breakpoint)) == .statusRangeNotAllowed)
        #expect(code(rule(matcher: RuleMatcher(statusRange: 99...200), action: .breakpoint(direction: .response, mode: .headers))) == .invalidStatusRange)
        #expect(code(rule(matcher: RuleMatcher(statusRange: 200...600), action: .breakpoint(direction: .response, mode: .headers))) == .invalidStatusRange)
        #expect(code(rule(action: .mapLocal(MapLocalAction(assetID: UUID(), status: 101, headers: [])))) == .invalidStatus)
        #expect(code(rule(action: .mapLocal(MapLocalAction(assetID: UUID(), status: 600, headers: [])))) == .invalidStatus)
        #expect(code(rule(action: .mapLocal(MapLocalAction(assetID: UUID(), status: 599, headers: [
            HeaderField(name: "Content-Length", value: "3")])))) == .invalidHeaderEdit)
        #expect(code(rule(action: .mapRemote(MapRemoteAction(targetScheme: "ftp", targetHost: "h.test", targetPort: 1, path: .preserve)))) == .invalidTarget)
        #expect(code(rule(action: .mapRemote(MapRemoteAction(targetScheme: "https", targetHost: "user@h.test", targetPort: 1, path: .preserve)))) == .invalidTarget)
        #expect(code(rule(action: .mapRemote(MapRemoteAction(targetScheme: "https", targetHost: "h.test", targetPort: 0, path: .preserve)))) == .invalidTarget)
        #expect(code(rule(action: .mapRemote(MapRemoteAction(targetScheme: "https", targetHost: "h.test", targetPort: 1, path: .replace("nolead"))))) == .invalidTarget)
        #expect(code(rule(action: .mapRemote(MapRemoteAction(targetScheme: "https", targetHost: "h.test", targetPort: 1, path: .replace("/ok#frag"))))) == .invalidTarget)
        #expect(code(rule(action: .editHeaders(direction: .request, operations: [.set(name: "Host", value: "x")]))) == .invalidHeaderEdit)
    }

    @Test func configFieldLimitIs8192Bytes() throws {
        func code(_ path: String) -> RuleValidationError.Code? {
            do { try rule(matcher: RuleMatcher(path: .exact(path)), action: .breakpoint(direction: .request, mode: .headers)).validate(); return nil }
            catch let error as RuleValidationError { return error.code } catch { return nil }
        }
        #expect(code("/" + String(repeating: "a", count: 8_191)) == nil)
        #expect(code("/" + String(repeating: "a", count: 8_192)) == .fieldTooLong)
        // Counted in UTF-8 bytes, not characters.
        #expect(code("/" + String(repeating: "\u{00E9}", count: 4_096)) == .fieldTooLong)
        func valueCode(_ value: String) -> RuleValidationError.Code? {
            do { try rule(action: .editHeaders(direction: .request, operations: [.set(name: "X", value: value)])).validate(); return nil }
            catch let error as RuleValidationError { return error.code } catch { return nil }
        }
        #expect(valueCode(String(repeating: "v", count: 8_192)) == nil)
        #expect(valueCode(String(repeating: "v", count: 8_193)) == .fieldTooLong)
    }
}
