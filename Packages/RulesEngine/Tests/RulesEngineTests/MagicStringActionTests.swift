import FlowStore
import Foundation
import Testing

@testable import RulesEngine

private func request(path: String = "/v1/items?a=1", method: String = "GET") -> HTTPMessageHead {
    .request(
        HTTPMessageTarget(scheme: "https", host: "a.test", port: 443, method: method, pathAndQuery: path),
        headers: [HeaderField(name: "Origin", value: "https://web.test")])
}

private let calm = PatternCache(budget: RegexBudget(clock: { .zero }))

private let ruleID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!

private func rule(
    _ actions: [RuleAction], when rows: [ConditionRow] = [], enabled: Bool = true, id: UUID = ruleID
) -> Rule {
    Rule(id: id, name: "r", enabled: enabled, order: 0, conditions: ConditionGroup(rows: rows), actions: actions)
}

private func decide(_ rules: Rule...) throws -> RequestRuleDecision {
    try RuleEvaluator.request(request(), snapshot: RuleSnapshot(revision: 1, rules: rules), cache: calm)
}

private func resolved(_ text: String) throws -> ActionKind {
    try MagicStringAction.resolve(text).get()
}

@Suite("MagicStringAction")
struct MagicStringActionTests {
    // MARK: the resolve table

    @Test func keywordTable() throws {
        let table: [(String, ActionKind)] = [
            ("*drop", .closeConnection(.graceful)),
            ("*DROP", .closeConnection(.graceful)),
            ("*reset", .closeConnection(.reset)),
            ("*delay:100", .delay(milliseconds: 100)),
            ("*delay:0", .delay(milliseconds: 0)),
            ("*Delay:2500", .delay(milliseconds: 2500)),
            ("*bpu", .breakpoint(direction: .request, mode: .headers)),
            ("*bpafter", .breakpoint(direction: .response, mode: .headers)),
            ("*redir:https://b.test/x?y=1", .returnPreset(PresetResponse(preset: .temporaryRedirect307, location: "https://b.test/x?y=1"))),
            ("*header:X-Test=abc", .editHeaders(direction: .request, operations: [.set(name: "X-Test", value: "abc")])),
            ("*header:X-Test=", .editHeaders(direction: .request, operations: [.set(name: "X-Test", value: "")])),
            ("*header:X-A=b=c", .editHeaders(direction: .request, operations: [.set(name: "X-A", value: "b=c")])),
            ("*CORSPreflightAllow", .returnHandwritten(HandwrittenResponse(text: MagicStringAction.corsPreflightResponse))),
            ("*corspreflightallow", .returnHandwritten(HandwrittenResponse(text: MagicStringAction.corsPreflightResponse))),
            ("*ReplyWithTunnel", .returnConnectTunnel),
            ("*exit", MagicStringAction.noOp),
        ]
        for (text, expected) in table {
            #expect(try resolved(text) == expected, "\(text)")
        }
    }

    @Test func urlsMapRemote() throws {
        let table: [(String, MapRemoteAction)] = [
            ("http://b.test/", MapRemoteAction(targetScheme: "http", targetHost: "b.test", targetPort: 80, path: .replace("/"))),
            ("https://B.test", MapRemoteAction(targetScheme: "https", targetHost: "B.test", targetPort: 443, path: .replace("/"))),
            (
                "https://b.test:8443/a/b?x=1&y=%20",
                MapRemoteAction(targetScheme: "https", targetHost: "b.test", targetPort: 8443, path: .replace("/a/b?x=1&y=%20"))
            ),
            ("HTTP://[::1]:9000/z", MapRemoteAction(targetScheme: "http", targetHost: "::1", targetPort: 9000, path: .replace("/z"))),
        ]
        for (text, expected) in table {
            #expect(try resolved(text) == .mapRemote(expected), "\(text) -> \(String(describing: try? resolved(text)))")
        }
    }

    @Test func predefinedNames() throws {
        let location = MagicStringAction.defaultRedirectLocation
        let table: [(String, PresetResponse)] = [
            ("200_SimpleHTML.dat", PresetResponse(preset: .emptyHTML200)),
            ("*200_SimpleHTML.dat", PresetResponse(preset: .emptyHTML200)),
            ("200_FiddlerGif.dat", PresetResponse(preset: .gif200)),
            ("200_TransPixel.dat", PresetResponse(preset: .transparentPixel200)),
            ("204_NoContent.dat", PresetResponse(preset: .noContent204)),
            ("302_Redirect.dat", PresetResponse(preset: .found302, location: location)),
            ("303_RedirectWithGet.dat", PresetResponse(preset: .seeOther303, location: location)),
            ("304_NotModified.dat", PresetResponse(preset: .notModified304)),
            ("307_RedirectWithMethod.dat", PresetResponse(preset: .temporaryRedirect307, location: location)),
            ("401_AuthBasic.dat", PresetResponse(preset: .unauthorized401)),
            ("401_AuthDigest.dat", PresetResponse(preset: .digestAuth401)),
            ("403_AuthDeny.dat", PresetResponse(preset: .forbidden403)),
            ("404_Plain.dat", PresetResponse(preset: .notFound404)),
            ("407_ProxyAuthBasic.dat", PresetResponse(preset: .proxyAuthRequired407)),
            ("502_Unreachable.dat", PresetResponse(preset: .unreachable502)),
            ("404_plain.DAT", PresetResponse(preset: .notFound404)),
        ]
        for (text, expected) in table {
            #expect(try resolved(text) == .returnPreset(expected), "\(text)")
        }
    }

    @Test func unresolvable() {
        let table: [(String, MagicStringError)] = [
            ("", .empty),
            ("*delay:", .invalidArgument),
            ("*delay:abc", .invalidArgument),
            ("*delay:-5", .invalidArgument),
            ("*redir:", .invalidArgument),
            ("*redir:bad\nlocation", .invalidArgument),
            ("*header:", .invalidArgument),
            ("*header:novalue", .invalidArgument),
            ("*header:=v", .invalidArgument),
            ("*header:Bad Name=v", .invalidArgument),
            ("ftp://b.test/", .unrecognized),
            ("http://", .invalidArgument),
            ("https://b.test:99999/", .invalidArgument),
            ("*unknown", .unrecognized),
            ("*", .unrecognized),
            ("999_Missing.dat", .unrecognized),
            ("hello world", .unrecognized),
            ("/Users/me/file.txt", .localFilePath),
            ("~/file.txt", .localFilePath),
            ("C:\\files\\a.txt", .localFilePath),
        ]
        for (text, error) in table {
            #expect(MagicStringAction.resolve(text) == .failure(error), "\(text)")
        }
    }

    @Test func corsResponseParsesAndAllowsEverything() throws {
        let parsed = try HandwrittenResponse(text: MagicStringAction.corsPreflightResponse).parse().get().response
        #expect(parsed.status == 200)
        func value(_ name: String) -> String? { parsed.headers.first { $0.name == name }?.value }
        #expect(value("Access-Control-Allow-Origin") == "*")
        #expect(value("Access-Control-Allow-Headers") == "*")
        #expect(value("Access-Control-Allow-Methods")?.contains("OPTIONS") == true)
    }

    // MARK: properties follow the resolved kind

    @Test func propertiesFollowTheResolvedKind() throws {
        let table: [(String, HTTPMessageDirection?, Bool, Bool, Bool)] = [
            // text, direction, final, annotation, canRunAtConnect
            ("*drop", nil, true, false, true),
            ("*reset", nil, true, false, true),
            ("*delay:10", nil, false, false, false),
            ("*bpu", .request, false, false, false),
            ("*bpafter", .response, false, false, false),
            ("*redir:http://x.test/", nil, true, false, false),
            ("*header:A=b", .request, false, false, false),
            ("*CORSPreflightAllow", nil, true, false, false),
            ("*ReplyWithTunnel", .request, true, false, true),
            ("*exit", nil, true, true, true),
            ("http://x.test/", .request, false, false, false),
            ("404_Plain.dat", nil, true, false, false),
        ]
        for (text, direction, final, annotation, connect) in table {
            let kind = ActionKind.magicString(text)
            let target = try resolved(text)
            #expect(kind.direction == direction, "\(text) direction")
            #expect(kind.direction == target.direction || text == "*exit", "\(text) matches resolved")
            #expect(kind.isIntrinsicallyFinal == final, "\(text) final")
            #expect(kind.isAnnotation == annotation, "\(text) annotation")
            #expect(kind.canRunAtConnect == connect, "\(text) connect")
        }
        #expect(ActionKind.magicString("*ReplyWithTunnel").isConnectOnly)
        #expect(!ActionKind.magicString("*drop").isConnectOnly)
        // A string that does not resolve does nothing, anywhere.
        #expect(ActionKind.magicString("nonsense").isAnnotation)
        #expect(!ActionKind.magicString("nonsense").isIntrinsicallyFinal)
    }

    // MARK: execution equivalence

    @Test func requestPointEquivalence() throws {
        let pairs: [(String, ActionKind)] = [
            ("*drop", .closeConnection(.graceful)),
            ("*reset", .closeConnection(.reset)),
            ("*delay:100", .delay(milliseconds: 100)),
            ("*bpu", .breakpoint(direction: .request, mode: .headers)),
            ("*redir:https://b.test/", .returnPreset(PresetResponse(preset: .temporaryRedirect307, location: "https://b.test/"))),
            ("*header:X-Test=abc", .editHeaders(direction: .request, operations: [.set(name: "X-Test", value: "abc")])),
            ("*CORSPreflightAllow", .returnHandwritten(HandwrittenResponse(text: MagicStringAction.corsPreflightResponse))),
            ("https://b.test:8443/p?q=1", try resolved("https://b.test:8443/p?q=1")),
            ("404_Plain.dat", .returnPreset(PresetResponse(preset: .notFound404))),
            ("302_Redirect.dat", .returnPreset(PresetResponse(preset: .found302, location: MagicStringAction.defaultRedirectLocation))),
        ]
        for (text, kind) in pairs {
            let magic = try decide(rule([RuleAction(.magicString(text))]))
            let plain = try decide(rule([RuleAction(kind)]))
            #expect(magic == plain, "\(text)")
        }
    }

    @Test func delayAndRedirectBehave() throws {
        #expect(try decide(rule([RuleAction(.magicString("*delay:100"))])).delayMilliseconds == 100)
        let redirect = try decide(rule([RuleAction(.magicString("*redir:https://b.test/new"))]))
        guard case .generated(let response) = redirect.route else {
            Issue.record("expected a generated response")
            return
        }
        #expect(response.status == 307)
        #expect(response.headers.first { $0.name == "Location" }?.value == "https://b.test/new")
        #expect(try decide(rule([RuleAction(.magicString("*bpu"))])).breakpoint == .headers)
    }

    @Test func headerSetReachesTheEffectiveHead() throws {
        let decision = try decide(rule([RuleAction(.magicString("*header:X-Test=abc"))]))
        #expect(decision.effectiveHead.headers.contains(HeaderField(name: "X-Test", value: "abc")))
        #expect(decision.rulesModified)
    }

    @Test func responseBreakpointRunsAtTheResponsePoint() throws {
        let snapshot = RuleSnapshot(revision: 1, rules: [rule([RuleAction(.magicString("*bpafter"))])])
        let first = try RuleEvaluator.request(request(), snapshot: snapshot, cache: calm)
        #expect(first.breakpoint == nil)
        let second = try RuleEvaluator.response(
            .response(status: 200, reason: "OK", headers: []), after: first, snapshot: snapshot, cache: calm)
        #expect(second.breakpoint == .headers)
    }

    @Test func exitStopsLowerRulesAndDoesNothingElse() throws {
        let lower = rule([RuleAction(.closeConnection(.reset))], id: UUID())
        let withExit = try decide(rule([RuleAction(.magicString("*exit"))]), lower)
        #expect(withExit.route == .original)
        #expect(!withExit.rulesModified)
        #expect(withExit.carry?.finalStop != nil)
        let without = try decide(lower)
        #expect(without.route == .close(.reset, ruleID: lower.id))
        // Actions after *exit in the same rule do not run either.
        let sameRule = try decide(rule([RuleAction(.magicString("*exit")), RuleAction(.closeConnection(.reset))]))
        #expect(sameRule.route == .original)
    }

    @Test func exitLeavesTheCommentAndAnnotationsAlone() throws {
        for comment in ["   ", String(repeating: "x", count: 100_000), "keep"] {
            let facts = ExchangeFacts(comment: comment)
            let decision = try RuleEvaluator.request(
                request(), snapshot: RuleSnapshot(revision: 1, rules: [rule([RuleAction(.magicString("*exit"))])]),
                facts: facts, cache: calm)
            #expect(decision.annotations.isEmpty)
        }
        let spaced = try decide(rule([RuleAction(.magicString("  *EXIT\n"))]))
        #expect(spaced.annotations.isEmpty && spaced.carry?.finalStop != nil)
        // A real comment action is still recorded.
        let real = try decide(rule([RuleAction(.comment(CommentAction(mode: .append, text: "a")))]))
        #expect(real.annotations.count == 1)
    }

    @Test func surroundingWhitespaceIsIgnored() throws {
        #expect(try resolved("  *drop \n") == .closeConnection(.graceful))
        #expect(try resolved("\t*delay:5\n") == .delay(milliseconds: 5))
        #expect(MagicStringAction.isExit(" *Exit\n"))
        #expect(MagicStringAction.resolve(" \n ") == .failure(.empty))
        #expect(MagicStringCondition.parse("  EXACT:x \n") == MagicStringCondition.parse("EXACT:x"))
        #expect(MagicStringCondition.parse(" METHOD:get *\n")?.method == "GET")
        #expect(MagicStringCondition.parse("   ") == nil)
    }

    @Test func connectPointRunsTheResolvedAction() throws {
        let snapshot = RuleSnapshot(revision: 1, rules: [rule([RuleAction(.magicString("*drop"))])])
        #expect(snapshot.requirements.connect)
        let plain = RuleSnapshot(revision: 1, rules: [rule([RuleAction(.closeConnection(.graceful))])])
        #expect(plain.requirements.connect)
    }

    // MARK: validation

    @Test func validation() throws {
        func code(_ text: String) -> RuleValidationError.Code? {
            do {
                try rule([RuleAction(.magicString(text))]).validate()
                return nil
            } catch let error as RuleValidationError {
                return error.code
            } catch { return .invalidOperator }
        }
        for good in ["*drop", "*delay:100", "http://b.test/", "404_Plain.dat", "*redir:https://x.test/", "*exit"] {
            #expect(code(good) == nil, "\(good)")
        }
        for bad in ["", "nonsense", "*delay:x", "/etc/hosts", "*header:novalue"] {
            #expect(code(bad) == .invalidMagicString, "\(bad)")
        }
        // The resolved action is validated like a written one.
        #expect(code("*delay:999999999") == .invalidDelay)
        #expect(code("http://bad host/") == .invalidMagicString)
        #expect(code(String(repeating: "a", count: RulesLimits().fieldBytes + 1)) == .fieldTooLong)
    }

    @Test func judgmentPointRulesFollowTheResolvedAction() throws {
        let responseRow = ConditionRow(field: .statusCode, op: .equals, value: "200")
        func code(_ text: String) -> RuleValidationError.Code? {
            do {
                try rule([RuleAction(.magicString(text))], when: [responseRow]).validate()
                return nil
            } catch let error as RuleValidationError { return error.code } catch { return .invalidOperator }
        }
        #expect(code("*bpafter") == nil)
        #expect(code("*bpu") == nil)
        #expect(code("*exit") == nil)
    }

    // MARK: stored form

    @Test func storedShapeAppendsAndRoundTrips() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let kind = ActionKind.magicString("*drop")
        let text = String(decoding: try encoder.encode(kind), as: UTF8.self)
        #expect(text == #"{"magicString":{"_0":"*drop"}}"#)
        #expect(try JSONDecoder().decode(ActionKind.self, from: Data(text.utf8)) == kind)
    }

    @Test func oldFilesAreUnaffected() throws {
        let old = rule([RuleAction(.closeConnection(.graceful)), RuleAction(.delay(milliseconds: 5))])
        #expect(old.expandingMagicStrings() == old)
        let snapshot = RuleSnapshot(revision: 3, rules: [old])
        #expect(snapshot.evaluationOrder == [old])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        let decoded = try JSONDecoder().decode(RuleSnapshot.self, from: data)
        #expect(try encoder.encode(decoded) == data)
    }

    @Test func expansionOnlyTouchesMagicStrings() {
        let mixed = rule([RuleAction(.hide), RuleAction(.magicString("*delay:7"), isFinal: true), RuleAction(.noDecrypt)])
        let expanded = mixed.expandingMagicStrings()
        #expect(expanded.actions[0] == mixed.actions[0])
        #expect(expanded.actions[1] == RuleAction(.delay(milliseconds: 7), isFinal: true))
        #expect(expanded.actions[2] == mixed.actions[2])
        #expect(RuleSnapshot(revision: 1, rules: [mixed]).evaluationOrder == [expanded])
        // The stored rule keeps the text.
        #expect(RuleSnapshot(revision: 1, rules: [mixed]).rules == [mixed])
    }

    @Test func unusedMeansTheSameDecision() throws {
        let rules = [
            rule([RuleAction(.delay(milliseconds: 3)), RuleAction(.editHeaders(direction: .request, operations: [.set(name: "A", value: "b")]))]),
        ]
        let decision = try RuleEvaluator.request(request(), snapshot: RuleSnapshot(revision: 1, rules: rules), cache: calm)
        #expect(decision.delayMilliseconds == 3)
        #expect(decision.effectiveHead.headers.contains(HeaderField(name: "A", value: "b")))
    }
}
