import FlowStore
import Foundation
import Testing

@testable import RulesEngine

// MARK: - Fixtures

private func id(_ n: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
}

private func number(of id: UUID) -> Int { Int(id.uuidString.suffix(12))! }

/// A reported pair as rule numbers and class number, for short expectations.
private struct Pair: Equatable, CustomStringConvertible {
    var higher: Int
    var lower: Int
    var changeClass: Int

    init(_ higher: Int, _ lower: Int, _ changeClass: Int) {
        self.higher = higher
        self.lower = lower
        self.changeClass = changeClass
    }

    var description: String { "\(higher)>\(lower) class \(changeClass)" }
}

private func rule(_ n: Int, enabled: Bool = true, _ matcher: RuleMatcher, _ action: LegacyRuleAction) -> LegacyRule {
    LegacyRule(id: id(n), name: "rule \(n)", enabled: enabled, order: n, matcher: matcher, action: action)
}

private func rule(_ n: Int, enabled: Bool = true, _ action: LegacyRuleAction) -> LegacyRule {
    rule(n, enabled: enabled, RuleMatcher(), action)
}

private func pairs(_ rules: [LegacyRule]) -> [Pair] {
    MigrationAnalyzer.report(for: rules).pairs.map {
        Pair(number(of: $0.higherRuleID), number(of: $0.lowerRuleID), $0.changeClass.rawValue)
    }
}

private func host(_ pattern: String) -> RuleMatcher { RuleMatcher(hostPattern: pattern) }

/// `mayOverlap` must not depend on which matcher comes first.
private func overlap(_ a: RuleMatcher, _ b: RuleMatcher, ignoringStatus: Bool = true) -> Bool {
    let forward = MigrationAnalyzer.mayOverlap(a, b, ignoringStatus: ignoringStatus)
    let backward = MigrationAnalyzer.mayOverlap(b, a, ignoringStatus: ignoringStatus)
    #expect(forward == backward, "mayOverlap depends on the order of \(a) and \(b)")
    return forward
}

private let mapLocal = LegacyRuleAction.mapLocal(OracleScenarios.localFile)
private let mapDirectory = LegacyRuleAction.mapLocalDirectory(OracleScenarios.directory)
private let requestEdit = OracleScenarios.edit(.request, .append(name: "X-Req", value: "1"))
private let responseEdit = OracleScenarios.edit(.response, .append(name: "X-Resp", value: "1"))
private let requestBreakpoint = LegacyRuleAction.breakpoint(direction: .request, mode: .headers)
private let responseBreakpoint = LegacyRuleAction.breakpoint(direction: .response, mode: .headers)
private let requestBody = LegacyRuleAction.rewriteBody(direction: .request, OracleScenarios.body())
private let responseBody = LegacyRuleAction.rewriteBody(direction: .response, OracleScenarios.body())

private func mapRemote(_ host: String = "b.test", port: Int = 443, path: RemotePathPolicy = .preserve) -> LegacyRuleAction {
    .mapRemote(OracleScenarios.remote(host, port: port, path: path))
}

private func status(_ code: Int) -> LegacyRuleAction { OracleScenarios.status(code) }

/// One action of each of the seven kinds, with the header edit, breakpoint and body rewrite in both
/// directions; every one is a valid lower rule for a matcher that does not use a status range.
private let everyAction: [(name: String, action: LegacyRuleAction)] = [
    ("mapLocal", mapLocal), ("mapLocalDirectory", mapDirectory), ("mapRemote", mapRemote("c.test")),
    ("request headers", requestEdit), ("response headers", responseEdit),
    ("request breakpoint", requestBreakpoint), ("response breakpoint", responseBreakpoint),
    ("request body", requestBody), ("response body", responseBody), ("status", status(404)),
]

// MARK: - Tests

@Suite("MigrationAnalyzer")
struct MigrationAnalyzerTests {
    // MARK: class 1, final action

    @Test func finalActionPairIsReported() {
        let a = host("a.test")
        #expect(pairs([rule(1, a, mapLocal), rule(2, a, responseEdit)]) == [Pair(1, 2, 1)])
    }

    @Test func everyKindOfLowerRuleLosesToAFinalAction() {
        let served = RuleMatcher(hostPattern: "a.test", path: .prefix("/files/"))
        let lower = host("a.test")
        for (name, action) in everyAction {
            let lowerMatcher = name == "mapLocalDirectory" ? served : lower
            #expect(
                pairs([rule(1, host("a.test"), mapLocal), rule(2, lowerMatcher, action)]) == [Pair(1, 2, 1)],
                "file, then \(name)")
            #expect(
                pairs([rule(1, served, mapDirectory), rule(2, lowerMatcher, action)]) == [Pair(1, 2, 1)],
                "directory, then \(name)")
        }
        // A lower rule on a response with a status range is silenced at the response point too.
        #expect(
            pairs([
                rule(1, host("a.test"), mapLocal),
                rule(2, RuleMatcher(hostPattern: "a.test", statusRange: 500...599), responseEdit),
            ])
                == [Pair(1, 2, 1)])
    }

    @Test func aFinalActionOnlyReachesLowerRules() {
        let a = host("a.test")
        #expect(pairs([rule(1, a, responseEdit), rule(2, a, mapLocal)]).isEmpty)
        #expect(pairs([rule(1, a, requestEdit), rule(2, a, mapDirectory)]).isEmpty)
    }

    // MARK: matcher overlap

    @Test func disjointLiteralHostsAreNotReported() {
        #expect(pairs([rule(1, host("a.test"), mapLocal), rule(2, host("b.test"), responseEdit)]).isEmpty)
        #expect(pairs([rule(1, host("*.a.test"), mapLocal), rule(2, host("x.b.test"), responseEdit)]).isEmpty)
        #expect(pairs([rule(1, host("*.a.test"), mapLocal), rule(2, host("*.b.test"), responseEdit)]).isEmpty)
        // Hosts that can meet are listed.
        #expect(
            pairs([rule(1, host("*.a.test"), mapLocal), rule(2, host("x.a.test"), responseEdit)]) == [Pair(1, 2, 1)])
        #expect(pairs([rule(1, host("*.test"), mapLocal), rule(2, host("*.a.test"), responseEdit)]) == [Pair(1, 2, 1)])
        #expect(pairs([rule(1, host("a.test"), mapLocal), rule(2, host("a.test"), responseEdit)]) == [Pair(1, 2, 1)])
    }

    @Test func literalHostsFollowHostPatternSemantics() {
        let cases: [(String, String, Bool)] = [
            ("a.test", "a.test", true),
            ("a.test", "b.test", false),
            ("A.Test.", "a.test", true),  // case and trailing dot do not matter
            ("a.test", "*.a.test", false),  // `*.x` needs at least one label in front
            ("x.a.test", "*.a.test", true),
            ("x.b.test", "*.a.test", false),
            ("xa.test", "*.a.test", false),  // the dot belongs to the suffix
            ("*.a.test", "*.b.test", false),
            ("*.a.test", "*.b.a.test", true),
            ("*.test", "*.a.test", true),
            ("*.a.test", "*.A.TEST.", true),
            ("*", "b.test", true),
            ("*", "*.a.test", true),
            ("[::1]", "::1", true),
            ("::1", "0:0:0:0:0:0:0:1", true),  // one address, two spellings
            ("::1", "::2", false),
            ("::1", "*.a.test", false),
        ]
        for (left, right, expected) in cases {
            #expect(overlap(host(left), host(right)) == expected, "\(left) and \(right)")
        }
        #expect(overlap(host("a.test"), RuleMatcher()))
        #expect(overlap(RuleMatcher(), RuleMatcher()))
    }

    @Test func disjointSchemesPortsMethodsAreNotReported() {
        let rules = { (a: RuleMatcher, b: RuleMatcher) in [rule(1, a, mapLocal), rule(2, b, responseEdit)] }
        #expect(pairs(rules(RuleMatcher(scheme: "http"), RuleMatcher(scheme: "https"))).isEmpty)
        #expect(pairs(rules(RuleMatcher(port: 80), RuleMatcher(port: 443))).isEmpty)
        #expect(pairs(rules(RuleMatcher(method: "GET"), RuleMatcher(method: "POST"))).isEmpty)
        // Same value, or a field only one of them has: they can still meet.
        #expect(pairs(rules(RuleMatcher(scheme: "https"), RuleMatcher(scheme: "HTTPS"))) == [Pair(1, 2, 1)])
        #expect(pairs(rules(RuleMatcher(port: 443), RuleMatcher(port: 443))) == [Pair(1, 2, 1)])
        #expect(pairs(rules(RuleMatcher(method: "GET"), RuleMatcher(method: "GET"))) == [Pair(1, 2, 1)])
        #expect(pairs(rules(RuleMatcher(scheme: "http"), RuleMatcher())) == [Pair(1, 2, 1)])
        #expect(pairs(rules(RuleMatcher(port: 80), RuleMatcher(method: "POST"))) == [Pair(1, 2, 1)])
        // A method is compared as written, a scheme without regard to case.
        #expect(!overlap(RuleMatcher(method: "GET"), RuleMatcher(method: "get")))
        #expect(overlap(RuleMatcher(scheme: "http"), RuleMatcher(scheme: "HTTP")))
        // One field that cannot meet is enough.
        #expect(
            !overlap(
                RuleMatcher(scheme: "http", hostPattern: "a.test"), RuleMatcher(scheme: "https", hostPattern: "a.test"))
        )
    }

    @Test func prefixPathsThatExcludeEachOtherAreNotReported() {
        let rules = { (a: PathMatch, b: PathMatch) in
            [rule(1, RuleMatcher(path: a), mapLocal), rule(2, RuleMatcher(path: b), responseEdit)]
        }
        #expect(pairs(rules(.prefix("/v1/"), .prefix("/v2/"))).isEmpty)
        #expect(pairs(rules(.exact("/v1/a"), .exact("/v1/b"))).isEmpty)
        #expect(pairs(rules(.exact("/v2/a"), .prefix("/v1/"))).isEmpty)
        #expect(pairs(rules(.prefix("/v1/"), .exact("/v2/a"))).isEmpty)
        #expect(pairs(rules(.prefix("/v1/"), .prefix("/v1/items"))) == [Pair(1, 2, 1)])
        #expect(pairs(rules(.prefix("/v1/items"), .prefix("/v1/"))) == [Pair(1, 2, 1)])
        #expect(pairs(rules(.exact("/v1/a"), .prefix("/v1/"))) == [Pair(1, 2, 1)])
        #expect(pairs(rules(.exact("/v1/a"), .exact("/v1/a"))) == [Pair(1, 2, 1)])
        #expect(pairs(rules(.any, .exact("/v1/a"))) == [Pair(1, 2, 1)])
    }

    @Test func pathOverlapFollowsTheRawBytes() {
        let cases: [(PathMatch, PathMatch, Bool)] = [
            (.any, .any, true),
            (.any, .prefix("/a"), true),
            (.exact("/a"), .exact("/b"), false),
            (.exact("/a?x=1"), .exact("/a"), false),  // the query is part of the path
            (.exact("/v1"), .prefix("/v1/"), false),  // shorter than the prefix: it cannot start with it
            (.exact("/v1/x"), .prefix("/v1/"), true),
            (.prefix("/"), .prefix("/a"), true),
            (.prefix("/a"), .prefix("/ab"), true),  // no segment boundary is implied
            (.prefix("/a/"), .prefix("/ab"), false),
            (.wildcard("/v1/*"), .exact("/v2/x"), true),  // not provable, so they may meet
            (.regex("/v1/.*"), .prefix("/v2/"), true),
            (.regex("/a"), .wildcard("/b*"), true),
            // The same letters in a different Unicode form are different bytes, so different paths.
            (.exact("/caf\u{00E9}"), .exact("/cafe\u{0301}"), false),
        ]
        for (left, right, expected) in cases {
            #expect(overlap(RuleMatcher(path: left), RuleMatcher(path: right)) == expected, "\(left) and \(right)")
        }
    }

    @Test func statusRangesOnlyCountWhenStatusIsConsidered() {
        let low = RuleMatcher(statusRange: 400...499)
        let high = RuleMatcher(statusRange: 500...599)
        #expect(!overlap(low, high, ignoringStatus: false))
        #expect(overlap(low, high, ignoringStatus: true))
        #expect(overlap(high, RuleMatcher(statusRange: 599...599), ignoringStatus: false))
        #expect(overlap(high, RuleMatcher(), ignoringStatus: false))
        #expect(overlap(RuleMatcher(), RuleMatcher(), ignoringStatus: false))
        // Status ranges do not hide what the other fields say.
        #expect(
            !overlap(
                RuleMatcher(hostPattern: "a.test", statusRange: 500...599),
                RuleMatcher(hostPattern: "b.test", statusRange: 500...599), ignoringStatus: false))
    }

    @Test func wildcardAndRegexMatchersAreListedWhenNotProvablyDisjoint() {
        let wildcardHost = RuleMatcher(hostPattern: "*.b.test", hostSyntax: .wildcard)
        let regexHost = RuleMatcher(hostPattern: "^b\\.test$", hostSyntax: .regex)
        // a.test and `*.b.test` cannot meet, but proving it is not the analyzer's business: listed.
        #expect(pairs([rule(1, host("a.test"), mapLocal), rule(2, wildcardHost, responseEdit)]) == [Pair(1, 2, 1)])
        #expect(pairs([rule(1, wildcardHost, mapLocal), rule(2, host("a.test"), responseEdit)]) == [Pair(1, 2, 1)])
        #expect(pairs([rule(1, host("a.test"), mapLocal), rule(2, regexHost, responseEdit)]) == [Pair(1, 2, 1)])
        #expect(pairs([rule(1, regexHost, mapLocal), rule(2, wildcardHost, responseEdit)]) == [Pair(1, 2, 1)])
        #expect(
            pairs([
                rule(1, RuleMatcher(path: .wildcard("/v1/*")), mapLocal),
                rule(2, RuleMatcher(path: .exact("/v2/x")), responseEdit),
            ])
                == [Pair(1, 2, 1)])
        #expect(
            pairs([
                rule(1, RuleMatcher(path: .regex("/v1/.*")), mapLocal),
                rule(2, RuleMatcher(path: .prefix("/v2/")), responseEdit),
            ])
                == [Pair(1, 2, 1)])
        // Another field that does separate them still wins.
        #expect(
            pairs([
                rule(1, RuleMatcher(scheme: "http", hostPattern: "*.b.test", hostSyntax: .wildcard), mapLocal),
                rule(2, RuleMatcher(scheme: "https", hostPattern: "^b", hostSyntax: .regex), responseEdit),
            ]).isEmpty)
        #expect(
            pairs([
                rule(1, RuleMatcher(hostPattern: "*.b.test", method: "GET", hostSyntax: .wildcard), mapLocal),
                rule(2, RuleMatcher(method: "POST", path: .regex("/v1/.*")), responseEdit),
            ]).isEmpty)
    }

    // MARK: class 2, the later rule sees the earlier rule's change

    @Test func mapRemoteChangingHostIsReportedAgainstALowerHostRule() {
        let toB = mapRemote("b.test")
        // The lower rule names the host the request is moved away from.
        #expect(pairs([rule(1, host("a.test"), toB), rule(2, host("a.test"), responseEdit)]) == [Pair(1, 2, 2)])
        // It names the host the request is moved to: it did not match before, it does now.
        #expect(pairs([rule(1, host("a.test"), toB), rule(2, host("b.test"), responseEdit)]) == [Pair(1, 2, 2)])
        #expect(pairs([rule(1, host("a.test"), toB), rule(2, host("*.test"), requestEdit)]) == [Pair(1, 2, 2)])
        #expect(
            pairs([
                rule(1, host("a.test"), toB), rule(2, RuleMatcher(hostPattern: "^b", hostSyntax: .regex), requestEdit),
            ]) == [Pair(1, 2, 2)])
        // A rule for every host moves every request, so a lower rule for any one host is affected.
        #expect(pairs([rule(1, RuleMatcher(), toB), rule(2, host("a.test"), responseEdit)]) == [Pair(1, 2, 2)])
        #expect(pairs([rule(1, RuleMatcher(), toB), rule(2, host("c.test"), responseEdit)]) == [Pair(1, 2, 2)])
        // Every kind of lower rule reads the moved request.
        for (name, action) in everyAction where !["mapLocal", "mapLocalDirectory", "mapRemote"].contains(name) {
            let lowerMatcher = host("a.test")
            #expect(pairs([rule(1, host("a.test"), toB), rule(2, lowerMatcher, action)]) == [Pair(1, 2, 2)], "\(name)")
        }
    }

    @Test func mapRemoteChangingSchemeOrPortIsReported() {
        let toHTTP = LegacyRuleAction.mapRemote(
            MapRemoteAction(targetScheme: "http", targetHost: "a.test", targetPort: 80, path: .preserve))
        #expect(
            pairs([rule(1, host("a.test"), toHTTP), rule(2, RuleMatcher(scheme: "https"), responseEdit)]) == [
                Pair(1, 2, 2)
            ])
        #expect(
            pairs([rule(1, host("a.test"), toHTTP), rule(2, RuleMatcher(scheme: "http"), responseEdit)]) == [
                Pair(1, 2, 2)
            ])
        #expect(
            pairs([rule(1, host("a.test"), toHTTP), rule(2, RuleMatcher(port: 80), responseEdit)]) == [Pair(1, 2, 2)])

        let toPort = mapRemote("a.test", port: 8443)
        let fromPort = RuleMatcher(hostPattern: "a.test", port: 443)
        #expect(pairs([rule(1, fromPort, toPort), rule(2, RuleMatcher(port: 443), responseEdit)]) == [Pair(1, 2, 2)])
        #expect(pairs([rule(1, fromPort, toPort), rule(2, RuleMatcher(port: 8443), responseEdit)]) == [Pair(1, 2, 2)])
        // A port the request neither has nor gets.
        #expect(pairs([rule(1, fromPort, toPort), rule(2, RuleMatcher(port: 9000), responseEdit)]).isEmpty)
    }

    @Test func mapRemoteReplacingThePathIsReportedAgainstALowerPathRule() {
        let replace = mapRemote("b.test", path: .replace("/v2/moved"))
        let preserve = mapRemote("b.test")
        let lowerPath = RuleMatcher(path: .prefix("/v1/"))
        // The path moves, so a lower rule on the path is affected; with the path kept it reads the same path.
        #expect(pairs([rule(1, RuleMatcher(), replace), rule(2, lowerPath, responseEdit)]) == [Pair(1, 2, 2)])
        #expect(pairs([rule(1, RuleMatcher(), preserve), rule(2, lowerPath, responseEdit)]).isEmpty)
        // The replacement path is what a lower rule can start to match.
        #expect(
            pairs([
                rule(1, RuleMatcher(path: .prefix("/v3/")), replace),
                rule(2, RuleMatcher(path: .prefix("/v2/")), responseEdit),
            ]) == [Pair(1, 2, 2)])
        // Neither the original range nor the new path meets the lower rule.
        let sameHostReplace = mapRemote("a.test", path: .replace("/v2/moved"))
        #expect(
            pairs([
                rule(1, RuleMatcher(hostPattern: "a.test", path: .prefix("/v3/")), sameHostReplace),
                rule(2, RuleMatcher(path: .prefix("/v1/")), responseEdit),
            ]).isEmpty)
    }

    @Test func mapRemoteAgainstUnrelatedHostRuleIsNotReported() {
        let toB = mapRemote("b.test")
        // R is for a.test only and moves to b.test; the lower rule is for c.test.
        #expect(pairs([rule(1, host("a.test"), toB), rule(2, host("c.test"), responseEdit)]).isEmpty)
        #expect(pairs([rule(1, host("a.test"), toB), rule(2, host("*.c.test"), responseEdit)]).isEmpty)
        // The lower rule tests nothing a Map Remote changes.
        #expect(pairs([rule(1, RuleMatcher(), toB), rule(2, RuleMatcher(method: "GET"), responseEdit)]).isEmpty)
        #expect(
            pairs([rule(1, RuleMatcher(), toB), rule(2, RuleMatcher(path: .prefix("/v1/")), responseEdit)]).isEmpty)
        #expect(
            pairs([rule(1, RuleMatcher(), toB), rule(2, RuleMatcher(statusRange: 500...599), responseEdit)]).isEmpty)
        #expect(pairs([rule(1, RuleMatcher(), toB), rule(2, RuleMatcher(), responseEdit)]).isEmpty)
        // The two rules cannot see the same request at all.
        #expect(
            pairs([
                rule(1, RuleMatcher(hostPattern: "a.test", method: "GET"), toB),
                rule(2, RuleMatcher(hostPattern: "b.test", method: "POST"), responseEdit),
            ]).isEmpty)
    }

    @Test func statusRewriteAgainstALowerStatusRangeRuleIsReported() {
        #expect(
            pairs([rule(1, RuleMatcher(), status(500)), rule(2, RuleMatcher(statusRange: 500...599), responseEdit)])
                == [Pair(1, 2, 2)])
        // The rewritten status is not what decides: a range the rewrite never produces is listed as well.
        #expect(
            pairs([rule(1, RuleMatcher(), status(500)), rule(2, RuleMatcher(statusRange: 400...499), responseEdit)])
                == [Pair(1, 2, 2)])
        #expect(
            pairs([
                rule(1, RuleMatcher(statusRange: 100...199), status(500)),
                rule(2, RuleMatcher(statusRange: 500...599), responseEdit),
            ]) == [Pair(1, 2, 2)])
        #expect(
            pairs([
                rule(1, RuleMatcher(), status(500)), rule(2, RuleMatcher(statusRange: 500...599), responseBreakpoint),
            ]) == [Pair(1, 2, 2)])
        // No status range below: the lower rule reads no status.
        #expect(pairs([rule(1, RuleMatcher(), status(500)), rule(2, RuleMatcher(), responseEdit)]).isEmpty)
        // The target conditions still have to be able to meet.
        #expect(
            pairs([
                rule(1, host("a.test"), status(500)),
                rule(2, RuleMatcher(hostPattern: "b.test", statusRange: 500...599), responseEdit),
            ]).isEmpty)
        #expect(
            pairs([
                rule(1, host("a.test"), status(500)),
                rule(2, RuleMatcher(hostPattern: "a.test", statusRange: 500...599), responseEdit),
            ]) == [Pair(1, 2, 2)])
    }

    // MARK: class 2, extended: a response-judged rule above a lower URL changer

    @Test func responseJudgedRuleAboveALowerMapRemoteIsReported() {
        let judged = RuleMatcher(hostPattern: "a.test", statusRange: 500...599)
        let moveToB = mapRemote("b.test")
        #expect(pairs([rule(1, judged, responseEdit), rule(2, RuleMatcher(), moveToB)]) == [Pair(1, 2, 2)])
        // The same with every response-side action, and with a status rewrite as the higher rule.
        for (name, action) in everyAction
        where ["response headers", "response breakpoint", "response body", "status"].contains(name) {
            #expect(pairs([rule(1, judged, action), rule(2, host("a.test"), moveToB)]) == [Pair(1, 2, 2)], "\(name)")
        }
        // The lower Map Remote may only apply to some requests, and the higher rule may name the new host.
        #expect(pairs([rule(1, judged, responseEdit), rule(2, host("a.test"), moveToB)]) == [Pair(1, 2, 2)])
        #expect(
            pairs([
                rule(1, RuleMatcher(hostPattern: "b.test", statusRange: 500...599), responseEdit),
                rule(2, host("a.test"), moveToB),
            ]) == [Pair(1, 2, 2)])
        #expect(
            pairs([
                rule(1, RuleMatcher(hostPattern: "*.test", statusRange: 500...599), responseEdit),
                rule(2, host("a.test"), moveToB),
            ]) == [Pair(1, 2, 2)])
    }

    @Test func responseJudgedRuleOnSchemePortAndPathIsReportedWhenTheMapRemoteChangesThem() {
        let toHTTP = LegacyRuleAction.mapRemote(
            MapRemoteAction(targetScheme: "http", targetHost: "a.test", targetPort: 80, path: .preserve))
        #expect(
            pairs([
                rule(1, RuleMatcher(scheme: "https", statusRange: 500...599), responseEdit),
                rule(2, host("a.test"), toHTTP),
            ]) == [Pair(1, 2, 2)])
        #expect(
            pairs([
                rule(1, RuleMatcher(port: 443, statusRange: 500...599), responseEdit), rule(2, host("a.test"), toHTTP),
            ]) == [Pair(1, 2, 2)])
        // The path is only what the Map Remote changes when it replaces it.
        let onPath = RuleMatcher(path: .prefix("/v1/"), statusRange: 500...599)
        #expect(pairs([rule(1, onPath, responseEdit), rule(2, RuleMatcher(), mapRemote("b.test"))]).isEmpty)
        #expect(
            pairs([rule(1, onPath, responseEdit), rule(2, RuleMatcher(), mapRemote("b.test", path: .replace("/v2/")))])
                == [Pair(1, 2, 2)])
        #expect(
            pairs([
                rule(1, onPath, responseEdit),
                rule(2, RuleMatcher(path: .prefix("/v1/")), mapRemote("b.test", path: .replace("/v2/"))),
            ]) == [Pair(1, 2, 2)])
        #expect(
            pairs([
                rule(1, onPath, responseEdit),
                rule(2, RuleMatcher(path: .prefix("/v3/")), mapRemote("b.test", path: .replace("/v4/"))),
            ]).isEmpty)
    }

    @Test func responseJudgedRuleThatTheMapRemoteCannotAffectIsNotReported() {
        let moveToB = mapRemote("b.test")
        let lowerForA = host("a.test")
        // Neither the old nor the new request meets the higher rule.
        #expect(
            pairs([
                rule(1, RuleMatcher(hostPattern: "c.test", statusRange: 500...599), responseEdit),
                rule(2, lowerForA, moveToB),
            ]).isEmpty)
        #expect(
            pairs([
                rule(1, RuleMatcher(hostPattern: "*.c.test", statusRange: 500...599), responseEdit),
                rule(2, lowerForA, moveToB),
            ]).isEmpty)
        // It tests nothing the Map Remote changes.
        #expect(
            pairs([rule(1, RuleMatcher(statusRange: 500...599), responseEdit), rule(2, RuleMatcher(), moveToB)]).isEmpty
        )
        #expect(
            pairs([
                rule(1, RuleMatcher(method: "POST", statusRange: 500...599), responseEdit),
                rule(2, RuleMatcher(), moveToB),
            ]).isEmpty)
        // Without a status range it is judged at the request, before the lower Map Remote runs.
        #expect(pairs([rule(1, host("a.test"), responseEdit), rule(2, RuleMatcher(), moveToB)]).isEmpty)
        #expect(pairs([rule(1, host("a.test"), responseBreakpoint), rule(2, RuleMatcher(), moveToB)]).isEmpty)
        #expect(pairs([rule(1, host("a.test"), requestEdit), rule(2, RuleMatcher(), moveToB)]).isEmpty)
        // A lower rule that does not move the request changes nothing for it.
        let judged = RuleMatcher(hostPattern: "a.test", statusRange: 500...599)
        for (name, action) in everyAction where name != "mapRemote" {
            #expect(pairs([rule(1, judged, responseEdit), rule(2, host("a.test"), action)]).isEmpty, "\(name)")
        }
        // A disabled Map Remote moves nothing.
        #expect(pairs([rule(1, judged, responseEdit), rule(2, enabled: false, RuleMatcher(), moveToB)]).isEmpty)
    }

    @Test func pinnedOracleScenariosAreReportedWithTheirClass() {
        func expect(_ higher: LegacyRule, _ lower: LegacyRule, _ changeClass: MigrationChangeClass, _ name: String) {
            #expect(
                MigrationAnalyzer.report(for: [higher, lower]).pairs
                    == [MigrationPair(changeClass: changeClass, higherRuleID: higher.id, lowerRuleID: lower.id)],
                "\(name)")
        }
        let classOne = OracleScenarios.classOneMapLocalThenLowerRule()
        expect(classOne.higher, classOne.lower, .finalAction, "classOneMapLocalThenLowerRule")
        let classTwo = OracleScenarios.classTwoMapRemoteThenLowerHostRule()
        expect(classTwo.higher, classTwo.lower, .laterSeesEarlier, "classTwoMapRemoteThenLowerHostRule")
        let remotes = OracleScenarios.classThreeTwoMapRemotes()
        expect(remotes.higher, remotes.lower, .sequentialRewrite, "classThreeTwoMapRemotes")
        let remoteThenLocal = OracleScenarios.classThreeMapRemoteThenMapLocal()
        expect(remoteThenLocal.higher, remoteThenLocal.lower, .sequentialRewrite, "classThreeMapRemoteThenMapLocal")

        let localResponse = OracleScenarios.classOneLocalResponseLowerHeaderRule()
        expect(localResponse.higher, localResponse.lower, .finalAction, "classOneLocalResponseLowerHeaderRule")
        let statusThenRange = OracleScenarios.classTwoStatusThenRangeRule()
        expect(statusThenRange.higher, statusThenRange.lower, .laterSeesEarlier, "classTwoStatusThenRangeRule")
        let oldHost = OracleScenarios.classTwoMapRemoteThenResponseRuleOnTheOldHost()
        expect(oldHost.higher, oldHost.lower, .laterSeesEarlier, "classTwoMapRemoteThenResponseRuleOnTheOldHost")
        let extended = OracleScenarios.classTwoExtensionResponseJudgedRuleAboveALowerURLChanger()
        expect(
            extended.higher, extended.lower, .laterSeesEarlier,
            "classTwoExtensionResponseJudgedRuleAboveALowerURLChanger")
        let statuses = OracleScenarios.classThreeTwoStatusRewrites()
        expect(statuses.higher, statuses.lower, .sequentialRewrite, "classThreeTwoStatusRewrites")
    }

    // MARK: class 3, sequential rewrites

    @Test func twoStatusRewritesAreClassThree() {
        #expect(pairs([rule(1, RuleMatcher(), status(500)), rule(2, RuleMatcher(), status(404))]) == [Pair(1, 2, 3)])
        #expect(pairs([rule(1, host("a.test"), status(500)), rule(2, host("a.test"), status(404))]) == [Pair(1, 2, 3)])
        #expect(pairs([rule(1, host("a.test"), status(500)), rule(2, host("b.test"), status(404))]).isEmpty)
        // With status ranges the second rule also reads the first one's status (class 2) when it has a range.
        let same = RuleMatcher(statusRange: 500...599)
        #expect(pairs([rule(1, same, status(404)), rule(2, same, status(410))]) == [Pair(1, 2, 2), Pair(1, 2, 3)])
        // Ranges that share no status: never two rewrites of one response, but the second reads the first's status.
        let low = RuleMatcher(statusRange: 400...499)
        #expect(pairs([rule(1, same, status(404)), rule(2, low, status(410))]) == [Pair(1, 2, 2)])
        #expect(pairs([rule(1, same, status(404)), rule(2, RuleMatcher(), status(410))]) == [Pair(1, 2, 3)])
    }

    @Test func twoMapRemotesAreClassThree() {
        #expect(
            pairs([rule(1, RuleMatcher(), mapRemote("b.test")), rule(2, RuleMatcher(), mapRemote("c.test"))]) == [
                Pair(1, 2, 3)
            ])
        // The second one also names the host the first one moves away from, or moves to.
        #expect(
            pairs([rule(1, host("a.test"), mapRemote("b.test")), rule(2, host("a.test"), mapRemote("c.test"))]) == [
                Pair(1, 2, 2), Pair(1, 2, 3),
            ])
        #expect(
            pairs([rule(1, host("a.test"), mapRemote("b.test")), rule(2, host("b.test"), mapRemote("c.test"))]) == [
                Pair(1, 2, 2)
            ])
        #expect(
            pairs([rule(1, host("a.test"), mapRemote("b.test")), rule(2, host("c.test"), mapRemote("d.test"))]).isEmpty)
        #expect(
            pairs([
                rule(1, RuleMatcher(method: "GET"), mapRemote("b.test")),
                rule(2, RuleMatcher(method: "POST"), mapRemote("c.test")),
            ]).isEmpty)
    }

    @Test func mapRemoteThenMapLocalIsClassThree() {
        #expect(
            pairs([rule(1, RuleMatcher(), mapRemote("b.test")), rule(2, RuleMatcher(), mapLocal)]) == [Pair(1, 2, 3)])
        #expect(
            pairs([
                rule(1, RuleMatcher(), mapRemote("b.test")),
                rule(2, RuleMatcher(path: .prefix("/files/")), mapDirectory),
            ]) == [Pair(1, 2, 3)])
        // The other way round it is the final action.
        #expect(
            pairs([rule(1, RuleMatcher(), mapLocal), rule(2, RuleMatcher(), mapRemote("b.test"))]) == [Pair(1, 2, 1)])
        #expect(pairs([rule(1, RuleMatcher(), mapLocal), rule(2, RuleMatcher(), mapLocal)]) == [Pair(1, 2, 1)])
        // Disjoint requests cannot reach both.
        #expect(pairs([rule(1, host("a.test"), mapRemote("b.test")), rule(2, host("c.test"), mapLocal)]).isEmpty)
    }

    // MARK: what is never reported

    @Test func headerEditPairsAreNeverReported() {
        let sources: [(String, LegacyRuleAction)] = [
            ("request headers", requestEdit), ("response headers", responseEdit),
            ("request breakpoint", requestBreakpoint), ("response breakpoint", responseBreakpoint),
            ("request body", requestBody), ("response body", responseBody),
        ]
        for (sourceName, source) in sources {
            for (name, action) in everyAction {
                #expect(
                    pairs([rule(1, RuleMatcher(), source), rule(2, RuleMatcher(), action)]).isEmpty,
                    "\(sourceName) then \(name)")
                #expect(
                    pairs([rule(1, host("a.test"), source), rule(2, host("a.test"), action)]).isEmpty,
                    "\(sourceName) then \(name) on a.test")
            }
        }
    }

    @Test func disabledRulesProduceNoPairs() {
        #expect(pairs([rule(1, enabled: false, mapLocal), rule(2, responseEdit)]).isEmpty)
        #expect(pairs([rule(1, mapLocal), rule(2, enabled: false, responseEdit)]).isEmpty)
        #expect(pairs([rule(1, enabled: false, mapLocal), rule(2, enabled: false, responseEdit)]).isEmpty)
        #expect(
            pairs([rule(1, enabled: false, status(500)), rule(2, RuleMatcher(statusRange: 500...599), responseEdit)])
                .isEmpty)
        #expect(pairs([rule(1, enabled: false, mapRemote()), rule(2, enabled: false, mapRemote("c.test"))]).isEmpty)
        // A disabled rule in between neither joins a pair nor hides the pair around it.
        #expect(
            pairs([rule(1, mapLocal), rule(2, enabled: false, responseEdit), rule(3, responseEdit)]) == [Pair(1, 3, 1)])
        #expect(
            pairs([rule(1, enabled: false, mapLocal), rule(2, mapLocal), rule(3, responseEdit)]) == [Pair(2, 3, 1)])
    }

    @Test func emptyAndSingleRuleListsProduceAnEmptyReport() {
        #expect(MigrationAnalyzer.report(for: []).isEmpty)
        #expect(MigrationAnalyzer.report(for: [rule(1, mapLocal)]).isEmpty)
        #expect(MigrationAnalyzer.report(for: [rule(1, status(500))]).isEmpty)
        #expect(MigrationAnalyzer.report(for: [rule(1, enabled: false, mapLocal)]).isEmpty)
        #expect(MigrationAnalyzer.report(for: []) == MigrationReport(pairs: []))
    }

    @Test func pairsAreOrderedDeterministically() {
        let rules = [
            rule(1, mapLocal),
            rule(2, mapRemote("b.test")),
            rule(3, status(500)),
            rule(4, RuleMatcher(statusRange: 500...599), responseEdit),
            rule(5, RuleMatcher(statusRange: 500...599), status(404)),
        ]
        let expected = [
            Pair(1, 2, 1), Pair(1, 3, 1), Pair(1, 4, 1), Pair(1, 5, 1),
            Pair(3, 4, 2), Pair(3, 5, 2), Pair(3, 5, 3),
        ]
        let first = pairs(rules)
        #expect(first == expected)
        #expect(pairs(rules) == first)
        #expect(MigrationAnalyzer.report(for: rules) == MigrationAnalyzer.report(for: rules))
        // Sorted by (higher, lower, class).
        #expect(first.map { [$0.higher, $0.lower, $0.changeClass] }.isSortedLexicographically)
        // The position in the list is the priority, not the number of the rule: reversed, other pairs.
        #expect(pairs(Array(rules.reversed())) == [Pair(5, 4, 2), Pair(5, 3, 3), Pair(2, 1, 3)])
    }

    @Test func rulesAtTheFileLimitAreAnalysed() {
        // 500 rules (the limit for new files; an old file may hold more), none of which can meet another.
        let apart = (1...500).map { rule($0, host("h\($0).test"), mapLocal) }
        #expect(MigrationAnalyzer.report(for: apart).isEmpty)

        // One header edit in the middle that every Map Local above it can meet.
        var withAll = apart
        withAll[249] = rule(250, RuleMatcher(), responseEdit)
        let reported = pairs(withAll)
        #expect(reported.count == 249)
        #expect(reported.allSatisfy { $0.changeClass == 1 && $0.lower == 250 && $0.higher < 250 })
    }

    // MARK: the grid

    /// The final action's diagnostic record is the one difference the grid does not count: when a
    /// Map Local has any rule below it, the new evaluator records `finalStop` whether or not that rule
    /// could have matched (the evaluator cannot know without evaluating it). The traffic is the same,
    /// the old evaluator has no such record, and the pair is correctly absent from the report.
    @Test func finalStopAloneIsNotAReportedChange() throws {
        let higher = rule(1, host("a.test"), mapLocal)
        let lower = rule(2, host("b.test"), responseEdit)
        let scenario = OracleScenario("finalStopOnly", request: OracleScenarios.get(host: "a.test"), [higher, lower])
        let legacy = try scenario.legacyRequest()
        let next = try scenario.migratedRequest()
        #expect(legacy.matches.outcomes == [RuleOutcome(ruleID: higher.id, code: .applied)])
        #expect(
            next.matches.outcomes == [
                RuleOutcome(ruleID: higher.id, code: .applied),
                RuleOutcome(ruleID: higher.id, code: .finalStop, actionIndex: 0),
            ])
        #expect(OracleRequestResult { legacy } != OracleRequestResult { next })
        #expect(settled(OracleRequestResult { legacy }) == settled(OracleRequestResult { next }))
        #expect(MigrationAnalyzer.report(for: [higher, lower]).isEmpty)
    }

    /// The deterministic grid: two rules of every action and matcher family, three requests and three
    /// responses (a response seen as an origin's and as a local one). Whenever the old and the new
    /// evaluator disagree on anything the user can see, the pair must be in the report.
    @Test func everyOracleDifferenceIsReported() async {
        let sides = Grid.sides
        let cells = await withTaskGroup(of: [GridCell].self) { group in
            for higher in sides {
                group.addTask { sides.map { gridCell(higher, $0) } }
            }
            var all: [GridCell] = []
            for await chunk in group { all += chunk }
            return all.sorted { ($0.higher, $0.lower) < ($1.higher, $1.lower) }
        }

        #expect(cells.count == sides.count * sides.count)
        #expect(!cells.contains { $0.sawUnexpected }, "an evaluator threw something other than a rule failure")
        let missing = cells.filter { $0.differs && $0.reportedClasses.isEmpty }
        let examples = missing.prefix(15).map { "\($0.higher) then \($0.lower)" }
        #expect(missing.isEmpty, "\(missing.count) differences are not reported, e.g. \(examples)")

        // The grid exercises what it claims to: all three classes and the extension show up as real differences.
        let differing = cells.filter(\.differs)
        for changeClass in 1...3 {
            #expect(
                differing.contains { $0.reportedClasses.contains(changeClass) },
                "no differing pair is reported as class \(changeClass)")
        }
        let extended = differing.filter(\.isResponseJudgedAboveMapRemote)
        #expect(
            !extended.isEmpty, "the extension (a response-judged rule above a Map Remote) never differs in the grid")
        #expect(extended.allSatisfy { $0.reportedClasses.contains(2) })
        #expect(differing.count > 300, "only \(differing.count) differing pairs")
        // The analyzer is selective: most pairs are not listed.
        let listed = cells.filter { !$0.reportedClasses.isEmpty }
        #expect(listed.count < cells.count / 2, "\(listed.count) of \(cells.count) pairs are listed")
        // Listing what does not differ is allowed (never missing is the rule), but not wholesale.
        let unnecessary = listed.filter { !$0.differs }
        #expect(unnecessary.count < listed.count, "every listed pair is a false alarm")
    }
}

// MARK: - Grid

private struct GridAction: Sendable {
    var name: String
    var action: LegacyRuleAction
    /// A directory mapping needs a `/…/` prefix path.
    var servesPrefix = false
}

private struct GridFamily: Sendable {
    var name: String
    var matcher: RuleMatcher
}

private struct GridSide: Sendable {
    var action: GridAction
    var family: GridFamily

    var name: String { "\(action.name)/\(family.name)" }

    func rule(_ n: Int) -> LegacyRule {
        var matcher = family.matcher
        if action.servesPrefix { matcher.path = .prefix("/v1/") }
        return LegacyRule(id: id(n), name: name, enabled: true, order: n, matcher: matcher, action: action.action)
    }

    /// Judged at the response: it has a status range and acts on the response.
    var isResponseJudged: Bool { family.matcher.statusRange != nil }

    var isMapRemote: Bool {
        if case .mapRemote = action.action { return true }
        return false
    }
}

private struct GridCell: Sendable {
    var higher: String
    var lower: String
    var differs: Bool
    /// An evaluator threw something that is neither a decision nor a rule evaluation failure.
    var sawUnexpected: Bool
    var reportedClasses: [Int]
    /// The higher rule is judged at the response and the lower one is a Map Remote.
    var isResponseJudgedAboveMapRemote: Bool
}

private enum Grid {
    static let actions: [GridAction] = [
        GridAction(name: "mapLocal", action: mapLocal),
        GridAction(name: "mapLocalDirectory", action: mapDirectory, servesPrefix: true),
        GridAction(name: "mapRemoteHost", action: mapRemote("b.test")),
        GridAction(name: "mapRemotePath", action: mapRemote("a.test", path: .replace("/v2/moved"))),
        GridAction(
            name: "mapRemoteSchemePort",
            action: .mapRemote(
                MapRemoteAction(targetScheme: "http", targetHost: "a.test", targetPort: 8080, path: .preserve))),
        GridAction(name: "requestHeaders", action: requestEdit),
        GridAction(name: "requestBreakpoint", action: requestBreakpoint),
        GridAction(name: "responseHeaders", action: responseEdit),
        GridAction(name: "responseBreakpoint", action: responseBreakpoint),
        GridAction(name: "responseBody", action: responseBody),
        GridAction(name: "rewriteStatus500", action: status(500)),
    ]

    static let families: [GridFamily] = [
        GridFamily(name: "all", matcher: RuleMatcher()),
        GridFamily(name: "sameHost", matcher: host("a.test")),
        GridFamily(name: "otherHost", matcher: host("b.test")),
        GridFamily(name: "wildcardHost", matcher: RuleMatcher(hostPattern: "*.test", hostSyntax: .wildcard)),
        GridFamily(name: "pathPrefix", matcher: RuleMatcher(path: .prefix("/v1/"))),
        GridFamily(name: "statusRange", matcher: RuleMatcher(statusRange: 500...599)),
        GridFamily(name: "clientErrorRange", matcher: RuleMatcher(statusRange: 400...499)),
        GridFamily(name: "sameHostAndStatus", matcher: RuleMatcher(hostPattern: "a.test", statusRange: 500...599)),
    ]

    /// Every action with every family it can validly have: a status range belongs to response rules only.
    static let sides: [GridSide] = actions.flatMap { action in
        families.compactMap { family in
            family.matcher.statusRange != nil && action.action.direction == .request
                ? nil : GridSide(action: action, family: family)
        }
    }

    static let requests: [HTTPMessageHead] = [
        OracleScenarios.get(host: "a.test", path: "/v1/items?a=1", headers: OracleScenarios.text()),
        OracleScenarios.get(host: "b.test", path: "/v1/items?a=1", headers: OracleScenarios.text()),
        OracleScenarios.get(host: "c.test", method: "POST", path: "/other", headers: OracleScenarios.text()),
    ]

    static let responses: [HTTPMessageHead] = [
        OracleScenarios.response(200, headers: OracleScenarios.text()),
        OracleScenarios.response(404, reason: "Not Found", headers: OracleScenarios.text()),
        OracleScenarios.response(503, reason: "Service Unavailable", headers: OracleScenarios.text()),
    ]
}

/// The old and the new evaluator on `[higher, lower]` for every request and response of the grid.
private func gridCell(_ higher: GridSide, _ lower: GridSide) -> GridCell {
    let rules = [higher.rule(1), lower.rule(2)]
    let reported = MigrationAnalyzer.report(for: rules).pairs.map(\.changeClass.rawValue)
    var differs = false
    var sawUnexpected = false
    func observe(_ result: OracleRequestResult) -> OracleRequestResult {
        if case .unexpected = result { sawUnexpected = true }
        return settled(result)
    }
    func observe(_ result: OracleResponseResult) -> OracleResponseResult {
        if case .unexpected = result { sawUnexpected = true }
        return settled(result)
    }
    search: for request in Grid.requests {
        let requestPoint = OracleScenario("grid", request: request, rules)
        if observe(OracleRequestResult { try requestPoint.legacyRequest() })
            != observe(OracleRequestResult { try requestPoint.migratedRequest() })
        {
            differs = true
            break search
        }
        for response in Grid.responses {
            for isLocalResponse in [false, true] {
                let scenario = OracleResponseScenario(
                    "grid", request: request, response: response, isLocalResponse: isLocalResponse, rules)
                if observe(OracleResponseResult { try scenario.legacyResponse() })
                    != observe(OracleResponseResult { try scenario.migratedResponse() })
                {
                    differs = true
                    break search
                }
            }
        }
    }
    return GridCell(
        higher: higher.name, lower: lower.name, differs: differs, sawUnexpected: sawUnexpected,
        reportedClasses: reported, isResponseJudgedAboveMapRemote: higher.isResponseJudged && lower.isMapRemote)
}

// A result without its `finalStop` records: the one record the old evaluator never wrote, and not a change the
// user can see (see `finalStopAloneIsNotAReportedChange`).

private func settled(_ matches: OracleRequestResult.Matches) -> OracleRequestResult.Matches {
    var matches = matches
    matches.outcomes.removeAll { $0.code == .finalStop }
    return matches
}

private func settled(_ result: OracleRequestResult) -> OracleRequestResult {
    switch result {
    case .decided(let head, let route, let breakpoint, let steps, let matches):
        .decided(
            effectiveHead: head, route: route, breakpoint: breakpoint, bodyRewrites: steps, matches: settled(matches))
    case .failed(let error, let matches):
        .failed(error, settled(matches))
    case .unexpected:
        result
    }
}

private func settled(_ result: OracleResponseResult) -> OracleResponseResult {
    switch result {
    case .decided(let head, let breakpoint, let steps, let statusRewrite, let matches):
        .decided(
            effectiveHead: head, breakpoint: breakpoint, bodyRewrites: steps, statusRewrite: statusRewrite,
            matches: settled(matches))
    case .failed(let error, let matches):
        .failed(error, settled(matches))
    case .unexpected:
        result
    }
}

extension Array where Element == [Int] {
    fileprivate var isSortedLexicographically: Bool {
        zip(self, dropFirst()).allSatisfy { $0.lexicographicallyPrecedes($1) }
    }
}
