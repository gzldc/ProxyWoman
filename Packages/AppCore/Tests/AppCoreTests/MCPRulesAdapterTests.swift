import FlowStore
import Foundation
import MCPKit
import MCPWire
import RulesEngine
import Testing
@testable import AppCore

// MARK: support

/// The global rules switch the adapter reports, as a closure over a main-actor box.
@MainActor private final class SwitchBox {
    var isOn = true
}

/// One editor over a real repository in a temporary directory (the pattern of `RulesEditorModelTests`),
/// optionally seeded, with the adapter on top.
@MainActor private final class Rig {
    let seedFixture: RulesFixture?
    let fixture: RulesFixture
    let editor: RulesEditorModel
    let adapter: MCPRulesAdapter
    let globalSwitch = SwitchBox()
    let saves = CallCounter()
    let saveGate: Gate?

    init(
        seed: [Rule] = [], groups: [RuleGroup] = [], seedWith: ((RulesFixture) async throws -> [Rule])? = nil,
        liveBreakpoints: Bool = false, saveGate: Gate? = nil, loaded: Bool = true,
        transform: ((inout RulesRepositoryClient) -> Void)? = nil
    ) async throws {
        var seedFixture: RulesFixture?
        let fixture: RulesFixture
        if seed.isEmpty, groups.isEmpty, seedWith == nil {
            fixture = RulesFixture()
        } else {
            let first = RulesFixture()
            _ = try await first.repository.load()
            let rules = try await seedWith?(first) ?? seed
            _ = try await first.repository.save(groups: groups, rules: rules, expectedRevision: 0)
            seedFixture = first
            // A restart over the same directory: the editor reads what the seed wrote.
            fixture = RulesFixture(root: first.root)
        }
        self.seedFixture = seedFixture
        self.fixture = fixture
        self.saveGate = saveGate
        var client = fixture.client(saves: saves, saveGate: saveGate)
        transform?(&client)
        editor = RulesEditorModel(client: client, limits: RulesLimits(), liveBreakpoints: liveBreakpoints)
        let box = globalSwitch
        adapter = MCPRulesAdapter(editor: editor, globalSwitchOn: { box.isOn })
        if loaded { await editor.load() }
    }

    deinit {
        fixture.remove()
    }

    var provider: RuleSnapshot { fixture.repository.provider.current() }
}

private func seedRule(
    _ name: String, enabled: Bool = false, host: String? = nil, order: Int = 0,
    action: LegacyRuleAction? = nil, matcher: RuleMatcher? = nil
) -> Rule {
    Rule(
        id: UUID(), name: name, enabled: enabled, order: order,
        matcher: matcher ?? RuleMatcher(hostPattern: host ?? "\(name.lowercased()).test"),
        action: action ?? .editHeaders(direction: .request, operations: [.set(name: "X-Rule", value: name)]))
}

/// A rule of the 2.0 model the old editor cannot state: a remote mapping followed by a response header edit, under
/// two fixed-field conditions combined by `mode`.
private func multiActionRule(
    _ name: String, enabled: Bool = false, order: Int = 0, mode: ConditionGroup.Mode = .all, groupID: UUID? = nil,
    extra: [RuleAction] = []
) -> Rule {
    var rule = Rule(
        id: UUID(), name: name, enabled: enabled, groupID: groupID, order: order,
        conditions: ConditionGroup(
            mode: mode, rows: [
                ConditionRow(field: .host, op: .hostPattern, value: "multi.test"),
                ConditionRow(field: .method, op: .equals, value: "GET", caseSensitive: true),
            ]),
        actions: [
            RuleAction(.mapRemote(MapRemoteAction(targetScheme: "http", targetHost: "localhost", targetPort: 3000, path: .preserve))),
            RuleAction(.editHeaders(direction: .response, operations: [.set(name: "X-Multi", value: "1")])),
        ])
    rule.actions += extra
    return rule
}

private let headerAction: [String: JSONValue] = [
    "type": .string("edit_headers"), "direction": .string("response"),
    "operations": .array([.object(["op": .string("set"), "name": .string("X-AI"), "value": .string("1")])]),
]
private let statusAction: [String: JSONValue] = ["type": .string("rewrite_status"), "status": .int(503)]

private func remoteMatch(host: String = "api.test") -> [String: JSONValue] {
    ["scheme": .string("https"), "host": .string(host)]
}

private let remoteAction: [String: JSONValue] = [
    "type": .string("map_remote"), "target_scheme": .string("http"), "target_host": .string("localhost"),
    "target_port": .int(3000),
]

private func remoteSpec(name: String = "Local API", host: String = "api.test") -> MCPRuleSpec {
    MCPRuleSpec(name: name, match: remoteMatch(host: host), action: remoteAction)
}

private func savedID(_ outcome: MCPRuleWriteOutcome) -> UUID? {
    if case .saved(let id, _, _) = outcome { id } else { nil }
}

private func issueSet(_ outcome: MCPRuleWriteOutcome) -> Set<String> {
    guard case .invalid(let issues) = outcome else { return [] }
    return Set(issues.map { "\($0.field)=\($0.issue)" })
}

@MainActor private func context(allowEnabling: Bool = false) -> MCPToolContext {
    var settings = MCPSettings()
    settings.enabled = true
    settings.allowEnablingRules = allowEnabling
    return MCPToolContext(settings: settings, redactor: MCPRedactor(settings.redaction), now: Date())
}

/// The issues a tool reports to the AI client for `arguments`, after its token filter.
@MainActor private func toolIssues(
    _ tool: some MCPTool, _ arguments: [String: JSONValue]
) async throws -> [(field: String, issue: String)] {
    do {
        _ = try await tool.call(arguments, context: context())
        Issue.record("expected rule_invalid")
        return []
    } catch let error as MCPToolError {
        #expect(error.code == "rule_invalid")
        let items = try #require(error.extra?["issues"]?.arrayValue)
        return items.compactMap { item in
            guard let field = item["field"]?.stringValue, let issue = item["issue"]?.stringValue else { return nil }
            return (field, issue)
        }
    }
}

// MARK: tests

@MainActor @Suite(.timeLimit(.minutes(2)), .productionChinese) struct MCPRulesAdapterTests {
    // MARK: create

    @Test func createSavesDisabledRuleVisibleInEditor() async throws {
        let rig = try await Rig()
        let outcome = await rig.adapter.create(remoteSpec(), enable: false)
        let id = try #require(savedID(outcome))
        #expect(outcome == .saved(id: id, enabled: false, revision: 1))
        // The Rules window's model sees it at once, and so does the proxy's published snapshot.
        let rule = try #require(rig.editor.rules.first)
        #expect(rig.editor.rules.count == 1 && rule.id == id && rule.enabled == false)
        #expect(rule.name == "Local API")
        #expect(rule.matcher == RuleMatcher(scheme: "https", hostPattern: "api.test"))
        #expect(rule.action == .mapRemote(MapRemoteAction(targetScheme: "http", targetHost: "localhost", targetPort: 3000, path: .preserve)))
        #expect(rig.editor.revision == 1)
        #expect(rig.provider.rules == rig.editor.rules && rig.provider.revision == 1)
    }

    @Test func createWithEnableTrueSavesEnabled() async throws {
        let rig = try await Rig()
        let outcome = await rig.adapter.create(remoteSpec(), enable: true)
        let id = try #require(savedID(outcome))
        #expect(outcome == .saved(id: id, enabled: true, revision: 1))
        #expect(rig.editor.rules.first?.enabled == true)
    }

    @Test func createAppendsAfterTheExistingRulesAndLeavesThemAlone() async throws {
        let existing = [seedRule("A", order: 0), seedRule("B", enabled: true, order: 1)]
        let rig = try await Rig(seed: existing)
        let outcome = await rig.adapter.create(remoteSpec(), enable: false)
        let id = try #require(savedID(outcome))
        #expect(rig.editor.rules.map(\.id) == existing.map(\.id) + [id])
        #expect(rig.editor.rules.map(\.order) == [0, 1, 2])
        #expect(Array(rig.editor.rules.prefix(2)) == existing)
        #expect(outcome == .saved(id: id, enabled: false, revision: 2))
    }

    @Test func createLeavesTheOpenEditorSessionAlone() async throws {
        let rig = try await Rig()
        rig.editor.beginDraft(kind: .rewriteStatus)
        var draft = try #require(rig.editor.draft)
        draft.name = "typing…"
        rig.editor.setDraft(draft)
        let before = rig.editor.draft
        #expect(rig.editor.isDraftDirty)

        let outcome = await rig.adapter.create(remoteSpec(), enable: false)
        #expect(savedID(outcome) != nil)
        #expect(rig.editor.draft == before && rig.editor.isDraftDirty && rig.editor.selection == before?.id)
        #expect(rig.editor.rules.count == 1)
    }

    @Test func invalidRuleReturnsIssuesAndSavesNothing() async throws {
        let rig = try await Rig()
        let spec = MCPRuleSpec(
            name: "Bad", match: ["host": .string("bad host!"), "port": .int(70_000)],
            action: ["type": .string("map_remote"), "target_host": .string("not a host")])
        let outcome = await rig.adapter.create(spec, enable: false)
        guard case .invalid(let issues) = outcome else {
            Issue.record("expected invalid, got \(outcome)")
            return
        }
        #expect(issues.contains(MCPRuleIssue(field: "action.target_host", issue: "invalidTargetHost")))
        #expect(issues.contains(MCPRuleIssue(field: "match.host", issue: "invalidHostPattern")))
        #expect(issues.contains(MCPRuleIssue(field: "match.port", issue: "invalidPort")))
        #expect(rig.saves.value == 0)
        #expect(rig.editor.revision == 0 && rig.editor.rules.isEmpty)
        #expect(rig.provider.revision == 0)
        #expect(!FileManager.default.fileExists(atPath: rig.fixture.configFile.path))
        // The user's window shows nothing about it.
        #expect(rig.editor.issues.isEmpty && rig.editor.error == nil)
    }

    @Test func validationIsTheRulesWindowValidation() async throws {
        let rig = try await Rig()
        let spec = MCPRuleSpec(
            name: "Many problems",
            match: [
                "host": .string("a b"), "port": .int(70_000), "method": .string("G ET"), "status_min": .int(500),
                "status_max": .int(400),
            ],
            action: ["type": .string("rewrite_body"), "direction": .string("response"), "find": .string("")])
        let outcome = await rig.adapter.create(spec, enable: false)

        // The same rule built by hand in the editor's draft type, validated by the window's own function.
        var draft = RuleEditorDraft(kind: .rewriteBody)
        draft.name = "Many problems"
        draft.enabled = false
        draft.direction = .response
        draft.match.host = "a b"
        draft.match.port = "70000"
        draft.match.method = "G ET"
        draft.match.statusLower = "500"
        draft.match.statusUpper = "400"
        draft.bodyRewrite.find = ""
        let expected = draft.validate(order: 0, limits: RulesLimits()).issues
        #expect(expected.count >= 4)

        let names: [RuleDraftField: String] = [
            .host: "match.host", .port: "match.port", .method: "match.method", .statusRange: "match.status_range",
            .bodyFind: "action.find", .path: "match.path", .name: "name", .scheme: "match.scheme",
        ]
        let expectedSet = Set(expected.map { "\(names[$0.key] ?? "?")=\($0.value.rawValue)" })
        #expect(!expectedSet.contains { $0.hasPrefix("?") })
        #expect(issueSet(outcome) == expectedSet)
        guard case .invalid(let issues) = outcome else { return }
        #expect(issues.count == expected.count)
    }

    @Test func headerOperationIssuesNameTheOperationByPosition() async throws {
        let rig = try await Rig()
        let operations: [JSONValue] = [
            .object(["op": .string("set"), "name": .string("X-Fine"), "value": .string("1")]),
            .object(["op": .string("add"), "name": .string("bad name"), "value": .string("1")]),
            .object(["op": .string("remove"), "name": .string("X-Other")]),
        ]
        let spec = MCPRuleSpec(
            name: "Headers", match: [:], action: ["type": .string("edit_headers"), "operations": .array(operations)])
        let outcome = await rig.adapter.create(spec, enable: false)
        #expect(issueSet(outcome) == ["action.operations[1]=headerNameInvalid"])
        #expect(rig.editor.rules.isEmpty)
    }

    @Test func realValidationIssuesKeepTheirFieldNamesThroughTheToolFilter() async throws {
        let rig = try await Rig()
        let create = CreateRuleTool(rules: rig.adapter)
        let allowedFields: Set<String> = [
            "name", "match.scheme", "match.host", "match.port", "match.method", "match.path", "match.status_range",
            "match.syntax", "action.target_scheme", "action.target_host", "action.target_port", "action.path",
            "action.direction", "action.operations[0]", "action.operations[1]", "action.find", "action.replace",
            "action.status", "action.syntax", "action.scope",
        ]
        var seen: Set<String> = []
        let cases: [[String: JSONValue]] = [
            [
                "name": .string("a"),
                "match": .object(["host": .string("a b"), "port": .int(70_000), "method": .string("G ET"), "path": .string("no-slash")]),
                "action": .object(["type": .string("map_remote"), "target_host": .string("x y"), "target_port": .int(0)]),
            ],
            [
                "name": .string("b"),
                "match": .object(["status_min": .int(500), "status_max": .int(400), "syntax": .string("regex"), "path": .string("(")]),
                "action": .object(["type": .string("rewrite_status"), "status": .int(99)]),
            ],
            [
                "name": .string("c"), "match": .object([:]),
                "action": .object([
                    "type": .string("edit_headers"),
                    "operations": .array([
                        .object(["op": .string("set"), "name": .string("bad name"), "value": .string("v")]),
                        .object(["op": .string("remove"), "name": .string("Host")]),
                    ]),
                ]),
            ],
            [
                "name": .string("d"), "match": .object(["scheme": .string("ftp"), "syntax": .string("glob")]),
                "action": .object([
                    "type": .string("rewrite_body"), "direction": .string("sideways"), "find": .string(""),
                    "syntax": .string("wildcard"), "scope": .string("some"),
                ]),
            ],
            [
                "name": .string("e"), "match": .object([:]),
                "action": .object(["type": .string("map_remote"), "target_scheme": .string("gopher"), "target_host": .string("h.test")]),
            ],
        ]
        for arguments in cases {
            let issues = try await toolIssues(create, arguments)
            #expect(!issues.isEmpty)
            for issue in issues {
                // `unknown` is what the tool's token filter makes of a field or issue it does not trust.
                #expect(issue.field != "unknown", "field of \(issue.issue)")
                #expect(issue.issue != "unknown", "issue of \(issue.field)")
                #expect(allowedFields.contains(issue.field), "\(issue.field)")
                seen.insert(issue.field)
            }
        }
        // The cases above reach most of the table (a few fields only exist for other rule kinds).
        #expect(seen.count >= 14, "\(seen.sorted())")
        #expect(rig.editor.rules.isEmpty)
    }

    @Test func unknownEnumWordsAreIssuesNotSilentDefaults() async throws {
        let rig = try await Rig()
        let spec = MCPRuleSpec(
            name: "Words", match: ["scheme": .string("ftp"), "syntax": .string("glob")],
            action: [
                "type": .string("rewrite_body"), "direction": .string("sideways"), "find": .string("x"),
                "syntax": .string("wildcard"), "scope": .string("some"),
            ])
        let outcome = await rig.adapter.create(spec, enable: false)
        let found = issueSet(outcome)
        for expected in [
            "match.scheme=invalid_value", "match.syntax=invalid_value", "action.direction=invalid_value",
            "action.syntax=invalid_value", "action.scope=invalid_value",
        ] {
            #expect(found.contains(expected), "\(expected) in \(found.sorted())")
        }
        #expect(rig.saves.value == 0 && rig.editor.rules.isEmpty)
    }

    // MARK: spec to rule mapping

    @Test func headerOperationsMapSetAddRemove() async throws {
        let rig = try await Rig()
        let spec = MCPRuleSpec(
            name: "Headers", match: ["method": .string("GET")],
            action: [
                "type": .string("edit_headers"), "direction": .string("response"),
                "operations": .array([
                    .object(["op": .string("set"), "name": .string("X-A"), "value": .string("1")]),
                    .object(["op": .string("add"), "name": .string("X-B"), "value": .string("2")]),
                    .object(["op": .string("remove"), "name": .string("X-C")]),
                ]),
            ])
        let id = try #require(savedID(await rig.adapter.create(spec, enable: false)))
        let rule = try #require(rig.editor.rules.first { $0.id == id })
        #expect(rule.action == .editHeaders(direction: .response, operations: [
            .set(name: "X-A", value: "1"), .append(name: "X-B", value: "2"), .remove(name: "X-C"),
        ]))
        #expect(rule.matcher == RuleMatcher(method: "GET"))
    }

    @Test func bodyAndStatusRewritesMap() async throws {
        let rig = try await Rig()
        let body = MCPRuleSpec(
            name: "Body", match: ["host": .string("a.test")],
            action: [
                "type": .string("rewrite_body"), "direction": .string("response"), "find": .string("a+"), "replace": .string("b"),
                "syntax": .string("regex"), "case_sensitive": .bool(false), "scope": .string("first"),
            ])
        let bodyID = try #require(savedID(await rig.adapter.create(body, enable: false)))
        #expect(
            rig.editor.rules.first { $0.id == bodyID }?.action
                == .rewriteBody(
                    direction: .response,
                    BodyRewriteAction(find: "a+", replacement: "b", syntax: .regex, caseSensitive: false, scope: .first)))

        // "literal" is the AI-facing word for plain text.
        let plain = MCPRuleSpec(
            name: "Plain", match: [:], action: ["type": .string("rewrite_body"), "find": .string("x"), "syntax": .string("literal")])
        let plainID = try #require(savedID(await rig.adapter.create(plain, enable: false)))
        #expect(
            rig.editor.rules.first { $0.id == plainID }?.action
                == .rewriteBody(direction: .request, BodyRewriteAction(find: "x", replacement: "", syntax: .text)))

        let status = MCPRuleSpec(
            name: "Status", match: ["status_min": .int(500), "status_max": .int(599)],
            action: ["type": .string("rewrite_status"), "status": .int(404), "include_local_responses": .bool(true)])
        let statusID = try #require(savedID(await rig.adapter.create(status, enable: false)))
        let rule = try #require(rig.editor.rules.first { $0.id == statusID })
        #expect(rule.action == .rewriteStatus(RewriteStatusAction(status: 404, includeLocalResponses: true)))
        #expect(rule.matcher.statusRange == 500...599)
    }

    @Test func mapRemoteDefaultsPortFromTheTargetSchemeAndPathMapsToReplace() async throws {
        let rig = try await Rig()
        func create(_ action: [String: JSONValue]) async throws -> MapRemoteAction {
            let id = try #require(savedID(await rig.adapter.create(MCPRuleSpec(name: "r", match: [:], action: action), enable: false)))
            guard case .mapRemote(let remote)? = rig.editor.rules.first(where: { $0.id == id })?.action else {
                Issue.record("not map_remote")
                return MapRemoteAction(targetScheme: "", targetHost: "", targetPort: 0, path: .preserve)
            }
            return remote
        }
        let http = try await create(["type": .string("map_remote"), "target_scheme": .string("http"), "target_host": .string("h.test")])
        #expect(http.targetScheme == "http" && http.targetPort == 80 && http.path == .preserve)
        let https = try await create(["type": .string("map_remote"), "target_host": .string("h.test"), "path": .string("/v2/x?y=1"),
                                      "preserve_credentials": .bool(true)])
        #expect(https.targetScheme == "https" && https.targetPort == 443 && https.path == .replace("/v2/x?y=1"))
        #expect(https.preserveCredentials)
    }

    /// Path semantics (decision): under the default literal syntax a given path is an exact match, which is
    /// what the Rules window gives a path typed into a literal matcher; a prefix is written as a wildcard.
    @Test func pathSyntaxMapsLikeTheRulesWindow() async throws {
        let rig = try await Rig()
        func matcher(_ match: [String: JSONValue]) async throws -> RuleMatcher {
            let spec = MCPRuleSpec(name: "p", match: match, action: ["type": .string("rewrite_status"), "status": .int(500)])
            let id = try #require(savedID(await rig.adapter.create(spec, enable: false)))
            return try #require(rig.editor.rules.first { $0.id == id }).matcher
        }
        #expect(try await matcher(["path": .string("/a")]).path == .exact("/a"))
        #expect(try await matcher(["path": .string("/a"), "syntax": .string("literal")]).path == .exact("/a"))
        #expect(try await matcher(["path": .string("")]).path == .any)
        #expect(try await matcher([:]).path == .any)
        let wildcard = try await matcher(["host": .string("*.a.test"), "path": .string("/api/*"), "syntax": .string("wildcard")])
        #expect(wildcard.path == .wildcard("/api/*") && wildcard.hostSyntax == .wildcard && wildcard.hostPattern == "*.a.test")
        let regex = try await matcher(["path": .string("^/v[0-9]+/"), "syntax": .string("regex")])
        #expect(regex.path == .regex("^/v[0-9]+/"))
        let all = try await matcher([
            "scheme": .string("http"), "host": .string("a.test"), "port": .int(8080), "method": .string("POST"),
        ])
        #expect(all == RuleMatcher(scheme: "http", hostPattern: "a.test", port: 8080, method: "POST"))
    }

    // MARK: update

    @Test func updateReplacesInPlaceKeepingOrder() async throws {
        let rules = [seedRule("A", order: 0), seedRule("B", order: 1), seedRule("C", order: 2)]
        let rig = try await Rig(seed: rules)
        let spec = MCPRuleSpec(
            name: "B renamed", match: ["host": .string("renamed.test"), "method": .string("PUT")],
            action: ["type": .string("edit_headers"), "operations": .array([.object(["op": .string("add"), "name": .string("X-New"), "value": .string("9")])])])
        let outcome = await rig.adapter.update(id: rules[1].id, spec, enable: nil, allowEnabledRule: false)
        #expect(outcome == .saved(id: rules[1].id, enabled: false, revision: 2))
        #expect(rig.editor.rules.map(\.id) == rules.map(\.id))
        #expect(rig.editor.rules.map(\.order) == [0, 1, 2])
        #expect(rig.editor.rules[0] == rules[0] && rig.editor.rules[2] == rules[2])
        let updated = rig.editor.rules[1]
        #expect(updated.name == "B renamed")
        #expect(updated.matcher == RuleMatcher(hostPattern: "renamed.test", method: "PUT"))
        #expect(updated.action == .editHeaders(direction: .request, operations: [.append(name: "X-New", value: "9")]))
        #expect(rig.provider.rules == rig.editor.rules)
    }

    @Test func updatePatchKeepsWhatItDoesNotMention() async throws {
        let original = seedRule(
            "Orig",
            action: .editHeaders(direction: .response, operations: [.set(name: "X-A", value: "1"), .remove(name: "X-B")]),
            matcher: RuleMatcher(
                scheme: "https", hostPattern: "orig.test", port: 8443, method: "GET", path: .prefix("/api/")))
        let rig = try await Rig(seed: [original])

        // Name only: matcher and action untouched.
        _ = await rig.adapter.update(id: original.id, MCPRuleSpec(name: "New name", match: nil, action: nil), enable: nil, allowEnabledRule: false)
        var expected = original
        expected.name = "New name"
        #expect(rig.editor.rules == [expected])

        // One match member: the others, including a prefix path mode only the window can set, stay.
        _ = await rig.adapter.update(
            id: original.id, MCPRuleSpec(name: nil, match: ["host": .string("other.test")], action: nil), enable: nil,
            allowEnabledRule: false)
        expected.matcher.hostPattern = "other.test"
        #expect(rig.editor.rules == [expected])

        // A new path under a prefix rule stays a prefix; an action patch of the same type keeps its direction.
        _ = await rig.adapter.update(
            id: original.id,
            MCPRuleSpec(name: nil, match: ["path": .string("/v2/")], action: ["type": .string("edit_headers")]), enable: nil,
            allowEnabledRule: false)
        expected.matcher.path = .prefix("/v2/")
        #expect(rig.editor.rules == [expected])

        // An empty string makes a string member match anything again.
        _ = await rig.adapter.update(
            id: original.id, MCPRuleSpec(name: nil, match: ["method": .string(""), "path": .string("")], action: nil), enable: nil,
            allowEnabledRule: false)
        expected.matcher.method = nil
        expected.matcher.path = .any
        #expect(rig.editor.rules == [expected])
    }

    @Test func updateCanChangeTheActionTypeAndKeepsTheMatch() async throws {
        let original = seedRule("Orig", host: "orig.test")
        let rig = try await Rig(seed: [original])
        let outcome = await rig.adapter.update(
            id: original.id,
            MCPRuleSpec(name: nil, match: nil, action: ["type": .string("rewrite_status"), "status": .int(418)]), enable: nil,
            allowEnabledRule: false)
        #expect(savedID(outcome) == original.id)
        #expect(rig.editor.rules.first?.action == .rewriteStatus(RewriteStatusAction(status: 418)))
        #expect(rig.editor.rules.first?.matcher == original.matcher)
    }

    @Test func updateOfEnabledRuleRefusedUnlessAllowed() async throws {
        let live = seedRule("Live", enabled: true, order: 0)
        let off = seedRule("Off", enabled: false, order: 1)
        let rig = try await Rig(seed: [live, off])
        let rename = MCPRuleSpec(name: "Renamed", match: nil, action: nil)
        let nothing = MCPRuleSpec(name: nil, match: nil, action: nil)
        let before = rig.editor.rules

        // A patch of any kind is refused while the rule is enabled …
        #expect(await rig.adapter.update(id: live.id, rename, enable: nil, allowEnabledRule: false) == .ruleIsEnabled)
        // … including a patch that only turns it off (D10: ask the user to disable it first).
        #expect(await rig.adapter.update(id: live.id, nothing, enable: false, allowEnabledRule: false) == .ruleIsEnabled)
        #expect(await rig.adapter.update(id: live.id, rename, enable: false, allowEnabledRule: false) == .ruleIsEnabled)
        #expect(rig.editor.rules == before && rig.saves.value == 0 && rig.editor.revision == 1)

        // A disabled rule is fine without the permission.
        #expect(savedID(await rig.adapter.update(id: off.id, rename, enable: nil, allowEnabledRule: false)) == off.id)
        #expect(rig.editor.rules[1].name == "Renamed" && rig.editor.rules[1].enabled == false)

        // With the permission an enabled rule can be changed and stays enabled, or be turned off.
        let kept = await rig.adapter.update(id: live.id, rename, enable: nil, allowEnabledRule: true)
        #expect(kept == .saved(id: live.id, enabled: true, revision: 3))
        let disabled = await rig.adapter.update(id: live.id, nothing, enable: false, allowEnabledRule: true)
        #expect(disabled == .saved(id: live.id, enabled: false, revision: 4))
        #expect(rig.editor.rules[0].enabled == false && rig.editor.rules[0].name == "Renamed")
    }

    @Test func updateRuleToolRefusesAnEnabledRuleWhenTheMasterSwitchIsOff() async throws {
        let live = seedRule("Live", enabled: true)
        let rig = try await Rig(seed: [live])
        let tool = UpdateRuleTool(rules: rig.adapter)
        for arguments: [String: JSONValue] in [
            ["id": .string(live.id.uuidString), "enable": .bool(false)],
            ["id": .string(live.id.uuidString), "name": .string("x")],
        ] {
            do {
                _ = try await tool.call(arguments, context: context(allowEnabling: false))
                Issue.record("expected rule_is_enabled")
            } catch let error as MCPToolError {
                #expect(error.code == "rule_is_enabled")
            }
        }
        #expect(rig.editor.rules == [live])
        // With the permission the same call goes through.
        let result = try await tool.call(
            ["id": .string(live.id.uuidString), "enable": .bool(false)], context: context(allowEnabling: true))
        #expect(result["enabled"] == .bool(false))
        #expect(rig.editor.rules.first?.enabled == false)
    }

    @Test func updateOfDirtyOpenDraftReportsBeingEdited() async throws {
        let target = seedRule("Target", order: 0)
        let other = seedRule("Other", order: 1)
        let rig = try await Rig(seed: [target, other])
        rig.editor.requestSelection(target.id)
        var draft = try #require(rig.editor.draft)
        draft.name = "Half typed"
        rig.editor.setDraft(draft)
        #expect(rig.editor.isDraftDirty)

        let rename = MCPRuleSpec(name: "AI name", match: nil, action: nil)
        #expect(await rig.adapter.update(id: target.id, rename, enable: nil, allowEnabledRule: true) == .beingEdited)
        #expect(await rig.adapter.setEnabled(id: target.id, true) == .beingEdited)
        #expect(rig.editor.rules == [target, other] && rig.saves.value == 0)
        #expect(rig.editor.draft?.name == "Half typed" && rig.editor.isDraftDirty)

        // Another rule is not blocked by the open draft.
        #expect(savedID(await rig.adapter.update(id: other.id, rename, enable: nil, allowEnabledRule: false)) == other.id)
        #expect(rig.editor.draft?.name == "Half typed" && rig.editor.isDraftDirty)
    }

    @Test func updateOfCleanOpenDraftRefreshesTheWindow() async throws {
        let target = seedRule("Target")
        let rig = try await Rig(seed: [target])
        rig.editor.requestSelection(target.id)
        #expect(!rig.editor.isDraftDirty)
        let outcome = await rig.adapter.update(
            id: target.id, MCPRuleSpec(name: "From AI", match: nil, action: nil), enable: nil, allowEnabledRule: false)
        #expect(savedID(outcome) == target.id)
        // The open form shows the new state and is not dirty, so saving it later cannot undo the AI's change.
        #expect(rig.editor.draft?.name == "From AI")
        #expect(!rig.editor.isDraftDirty)
        #expect(rig.editor.selection == target.id)
    }

    @Test func updateUnknownIdIsNotFound() async throws {
        let rig = try await Rig(seed: [seedRule("A")])
        let outcome = await rig.adapter.update(
            id: UUID(), MCPRuleSpec(name: "x", match: nil, action: nil), enable: nil, allowEnabledRule: true)
        #expect(outcome == .notFound)
    }

    @Test func mapLocalUpdateIsUnsupported() async throws {
        var localID = UUID(), directoryID = UUID(), breakpointID = UUID()
        let rig = try await Rig(seedWith: { fixture in
            let asset = try await fixture.assets.importFile(fixture.sourceFile("page.html", "<p>x</p>"), displayName: "page.html")
            let local = seedRule("Local", action: .mapLocal(MapLocalAction(assetID: asset.id, status: 200, headers: [])))
            let directory = seedRule(
                "Dir", action: .mapLocalDirectory(MapLocalDirectoryAction(bookmark: Data([1, 2, 3]), displayName: "d")),
                matcher: RuleMatcher(hostPattern: "d.test", path: .prefix("/s/")))
            let breakpoint = seedRule("Stop", action: .breakpoint(direction: .request, mode: .headers))
            return [local, directory, breakpoint]
        })
        localID = rig.editor.rules[0].id
        directoryID = rig.editor.rules[1].id
        breakpointID = rig.editor.rules[2].id
        let before = rig.editor.rules
        let unsupported = MCPRuleWriteOutcome.invalid([MCPRuleIssue(field: "action", issue: "unsupported_type")])

        // Whatever the patch is, a rule that needs a file or directory is not changed through MCP.
        let rename = MCPRuleSpec(name: "AI", match: nil, action: nil)
        #expect(await rig.adapter.update(id: localID, rename, enable: nil, allowEnabledRule: true) == unsupported)
        #expect(await rig.adapter.update(id: directoryID, rename, enable: false, allowEnabledRule: true) == unsupported)
        // A breakpoint rule keeps its type too: an action patch is refused, a rename is fine.
        let retype = MCPRuleSpec(name: nil, match: nil, action: ["type": .string("rewrite_status"), "status": .int(500)])
        #expect(await rig.adapter.update(id: breakpointID, retype, enable: nil, allowEnabledRule: true) == unsupported)
        #expect(rig.editor.rules == before && rig.saves.value == 0)
        #expect(savedID(await rig.adapter.update(id: breakpointID, rename, enable: nil, allowEnabledRule: true)) == breakpointID)

        // Turning such a rule on or off is still available.
        #expect(await rig.adapter.setEnabled(id: localID, true) == .saved(id: localID, enabled: true, revision: 3))
    }

    // MARK: setEnabled

    @Test func setEnabledRoundTrips() async throws {
        let rule = seedRule("Toggle")
        let rig = try await Rig(seed: [rule])
        #expect(await rig.adapter.setEnabled(id: rule.id, true) == .saved(id: rule.id, enabled: true, revision: 2))
        #expect(rig.editor.rules.first?.enabled == true && rig.provider.rules.first?.enabled == true)
        #expect(await rig.adapter.setEnabled(id: rule.id, false) == .saved(id: rule.id, enabled: false, revision: 3))
        #expect(rig.editor.rules.first?.enabled == false)
        // Already in the asked state: nothing is written.
        let writes = rig.saves.value
        #expect(await rig.adapter.setEnabled(id: rule.id, false) == .saved(id: rule.id, enabled: false, revision: 3))
        #expect(rig.saves.value == writes)
    }

    @Test func setEnabledUnknownIdNotFound() async throws {
        let rig = try await Rig(seed: [seedRule("A")])
        #expect(await rig.adapter.setEnabled(id: UUID(), true) == .notFound)
        #expect(await rig.adapter.setEnabled(id: UUID(), false) == .notFound)
    }

    @Test func breakpointRuleCannotBeEnabledWhenNotLive() async throws {
        let breakpoint = seedRule("Stop", action: .breakpoint(direction: .request, mode: .headers))
        let rig = try await Rig(seed: [breakpoint], liveBreakpoints: false)
        let outcome = await rig.adapter.setEnabled(id: breakpoint.id, true)
        #expect(outcome == .invalid([MCPRuleIssue(field: "enabled", issue: "breakpoint_unavailable")]))
        #expect(rig.editor.rules.first?.enabled == false && rig.saves.value == 0)
        // Nothing appears in the user's window.
        #expect(rig.editor.error == nil)

        let live = try await Rig(seed: [breakpoint], liveBreakpoints: true)
        #expect(await live.adapter.setEnabled(id: breakpoint.id, true) == .saved(id: breakpoint.id, enabled: true, revision: 2))
    }

    // MARK: busy, conflict, loading

    @Test func busyWhileEditorMutating() async throws {
        let gate = Gate()
        let rule = seedRule("A")
        let rig = try await Rig(seed: [rule], saveGate: gate)
        let editor = rig.editor
        let holding = Task { @MainActor in await editor.setEnabled(id: rule.id, enabled: true) }
        await gate.arrived()
        #expect(editor.isBusy)

        let rename = MCPRuleSpec(name: "x", match: nil, action: nil)
        #expect(await rig.adapter.create(remoteSpec(), enable: false) == .busy)
        #expect(await rig.adapter.update(id: rule.id, rename, enable: nil, allowEnabledRule: true) == .busy)
        #expect(await rig.adapter.setEnabled(id: rule.id, false) == .busy)
        // Listing never waits for the writer.
        let listing = await rig.adapter.list(includeDisabled: true)
        #expect(listing.rules.count == 1)

        await gate.open()
        #expect(await holding.value)
        let outcome = await rig.adapter.create(remoteSpec(), enable: false)
        #expect(savedID(outcome) != nil)
        #expect(rig.editor.rules.count == 2)
    }

    @Test func conflictFromRepositoryMaps() async throws {
        let rule = seedRule("A")
        let rig = try await Rig(seed: [rule], transform: { client in
            client.save = { _, _, _ in
                // The editor reads the newer rules from the published snapshot, not from this payload.
                throw RuleRepositoryError.conflict(current: RuleSnapshot(revision: 9, rules: []))
            }
        })
        #expect(await rig.adapter.create(remoteSpec(), enable: false) == .conflict)
        #expect(rig.editor.conflict != nil)
        // The window keeps the conflict for the user to resolve; further writes say so too.
        #expect(await rig.adapter.setEnabled(id: rule.id, true) == .conflict)
        #expect(rig.editor.rules == [rule])
    }

    @Test func storageFailureIsRetryableBusyAndShownToTheUser() async throws {
        let rig = try await Rig(transform: { client in
            client.save = { _, _, _ in throw OwnedFileError(.ioFailure, errno: EIO) }
        })
        #expect(await rig.adapter.create(remoteSpec(), enable: false) == .busy)
        #expect(rig.editor.error == .storage(.ioFailure))
        #expect(rig.editor.rules.isEmpty)
    }

    @Test func adapterLoadsTheEditorOnDemand() async throws {
        let rule = seedRule("A")
        let rig = try await Rig(seed: [rule], loaded: false)
        #expect(rig.editor.loadState == .notLoaded)
        let listing = await rig.adapter.list(includeDisabled: true)
        #expect(rig.editor.loadState == .loaded)
        #expect(listing.rules.map(\.id) == [rule.id] && listing.revision == 1)

        let fresh = try await Rig(loaded: false)
        let outcome = await fresh.adapter.create(remoteSpec(), enable: false)
        #expect(savedID(outcome) != nil)
        #expect(fresh.editor.loadState == .loaded)
    }

    // MARK: external commit on the editor

    @Test func commitExternalChecksNewnessAgainstTheSavedRules() async throws {
        let rule = seedRule("A")
        let rig = try await Rig(seed: [rule])
        var draft = RuleEditorDraft(kind: .rewriteStatus)
        draft.rewriteStatus.status = "500"
        // A new draft cannot reuse a saved id; an existing one must exist.
        var reused = draft
        reused.id = rule.id
        #expect(await rig.editor.commitExternal(draft: reused, isNew: true, allowEnabledRule: true) == .conflict)
        #expect(await rig.editor.commitExternal(draft: draft, isNew: false, allowEnabledRule: true) == .notFound)
        #expect(rig.editor.rules == [rule])
        let saved = await rig.editor.commitExternal(draft: draft, isNew: true, allowEnabledRule: false)
        #expect(saved == .saved(id: draft.id, enabled: true, revision: 2))
    }

    // MARK: list

    @Test func listReportsRulesInOrderWithRevisionAndSwitch() async throws {
        let rules = [
            seedRule("A", enabled: true, order: 0, action: .rewriteStatus(RewriteStatusAction(status: 503)),
                     matcher: RuleMatcher(scheme: "https", hostPattern: "a.test", method: "GET", path: .prefix("/api/"))),
            seedRule("B", enabled: false, order: 1),
            seedRule("C", enabled: true, order: 2, action: .mapRemote(MapRemoteAction(targetScheme: "http", targetHost: "localhost", targetPort: 3000, path: .preserve))),
        ]
        let rig = try await Rig(seed: rules)
        rig.globalSwitch.isOn = false
        let all = await rig.adapter.list(includeDisabled: true)
        #expect(all.revision == 1 && all.globalSwitchOn == false)
        #expect(all.rules.map(\.id) == rules.map(\.id))
        #expect(all.rules.map(\.order) == [0, 1, 2])
        #expect(all.rules.map(\.enabled) == [true, false, true])
        #expect(all.rules.map(\.type) == ["rewrite_status", "edit_headers", "map_remote"])
        #expect(all.rules.map(\.direction) == ["response", "request", nil])
        #expect(all.rules[0].match == .object([
            "scheme": .string("https"), "host": .string("a.test"), "method": .string("GET"), "path": .string("/api/"),
            "path_mode": .string("prefix"), "syntax": .string("literal"),
        ]))
        #expect(all.rules[0].summary.contains("503"))
        #expect(all.rules[2].summary.contains("localhost"))

        rig.globalSwitch.isOn = true
        let enabledOnly = await rig.adapter.list(includeDisabled: false)
        #expect(enabledOnly.rules.map(\.id) == [rules[0].id, rules[2].id])
        // The position stays the rule's position among all rules.
        #expect(enabledOnly.rules.map(\.order) == [0, 2])
        #expect(enabledOnly.globalSwitchOn)
    }

    @Test func listSummariesHideAssetsAndBookmarks() async throws {
        let bookmark = Data("BOOKMARK-BYTES-PRIVATE".utf8)
        var assetID = UUID()
        let rig = try await Rig(seedWith: { fixture in
            let file = fixture.sourceFile("secret-launch-codes.html", "<p>x</p>")
            let asset = try await fixture.assets.importFile(file, displayName: "secret-launch-codes.html")
            return [
                seedRule(
                    "Local file",
                    action: .mapLocal(MapLocalAction(assetID: asset.id, status: 201, headers: [HeaderField(name: "X-Secret", value: "hunter2")])),
                    matcher: RuleMatcher(hostPattern: "files.test")),
                seedRule(
                    "Local dir",
                    action: .mapLocalDirectory(MapLocalDirectoryAction(bookmark: bookmark, displayName: "private-folder-name")),
                    matcher: RuleMatcher(hostPattern: "dir.test", path: .prefix("/static/"))),
            ]
        })
        if case .mapLocal(let local) = rig.editor.rules[0].action { assetID = local.assetID }
        // The editor knows the asset's file name; the listing must not.
        #expect(rig.editor.knownAssets[assetID]?.displayName == "secret-launch-codes.html")

        let listing = await rig.adapter.list(includeDisabled: true)
        #expect(listing.rules.map(\.type) == ["map_local", "map_local_directory"])
        #expect(listing.rules[0].summary.contains("201"))
        #expect(listing.rules[0].direction == nil && listing.rules[1].direction == nil)

        var text = "\(listing)"
        for rule in listing.rules { text += (try? rule.match.encoded()).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
        for forbidden in [
            "secret-launch-codes", assetID.uuidString, "BOOKMARK", "private-folder-name", bookmark.base64EncodedString(),
            "hunter2", "X-Secret",
        ] {
            #expect(!text.contains(forbidden), "\(forbidden)")
        }
    }

    // MARK: Rules 2.0: actions, mode, group (Task 12)

    @Test func createBuildsAMultiActionRuleWithModeAny() async throws {
        let rig = try await Rig()
        let spec = MCPRuleSpec(
            name: "Combo", match: ["host": .string("api.test"), "method": .string("GET"), "mode": .string("any")], action: nil,
            actions: [remoteAction, headerAction, statusAction])
        let outcome = await rig.adapter.create(spec, enable: false)
        let id = try #require(savedID(outcome))
        #expect(outcome == .saved(id: id, enabled: false, revision: 1))
        let rule = try #require(rig.editor.rules.first)
        #expect(rule.id == id && rule.name == "Combo" && rule.enabled == false)
        #expect(rule.conditions.mode == .any)
        #expect(rule.conditions.occurrence == .any)
        #expect(rule.conditions.rows.map(\.field) == [.host, .method])
        #expect(
            rule.actions.map(\.kind) == [
                .mapRemote(MapRemoteAction(targetScheme: "http", targetHost: "localhost", targetPort: 3000, path: .preserve)),
                .editHeaders(direction: .response, operations: [.set(name: "X-AI", value: "1")]),
                .rewriteStatus(RewriteStatusAction(status: 503)),
            ])
        // Never a final flag, whatever the action; and the old editor cannot state it.
        #expect(rule.actions.allSatisfy { !$0.isFinal })
        #expect(rule.simple == nil)
        // The proxy's snapshot has the same rule.
        #expect(rig.provider.rules == rig.editor.rules && rig.provider.revision == 1)

        // Enabling goes through the same gate as before: the adapter is told whether to enable.
        let enabled = await rig.adapter.create(spec, enable: true)
        #expect(rig.editor.rules.last?.enabled == true && savedID(enabled) != nil)
    }

    @Test func createWithOneActionsElementIsTheSameRuleAsCreateWithAction() async throws {
        let rig = try await Rig()
        let one = await rig.adapter.create(MCPRuleSpec(name: "One", match: remoteMatch(), action: nil, actions: [remoteAction]), enable: false)
        let plain = await rig.adapter.create(remoteSpec(name: "One"), enable: false)
        let first = try #require(rig.editor.rules.first { $0.id == savedID(one) })
        let second = try #require(rig.editor.rules.first { $0.id == savedID(plain) })
        var normalised = second
        normalised.id = first.id
        normalised.order = first.order
        #expect(first == normalised)
        #expect(first.simple != nil)
    }

    @Test func createWithActionsNamesTheOffendingElementInItsIssues() async throws {
        let rig = try await Rig()
        let badHeader: [String: JSONValue] = [
            "type": .string("edit_headers"),
            "operations": .array([
                .object(["op": .string("set"), "name": .string("X-Fine"), "value": .string("1")]),
                .object(["op": .string("set"), "name": .string("bad name"), "value": .string("1")]),
            ]),
        ]
        let badStatus: [String: JSONValue] = ["type": .string("rewrite_status"), "status": .int(99)]
        let spec = MCPRuleSpec(
            name: "Bad", match: ["port": .int(70_000)], action: nil,
            actions: [remoteAction, badHeader, badStatus, ["type": .string("map_remote"), "target_host": .string("not a host")]])
        let found = issueSet(await rig.adapter.create(spec, enable: false))
        #expect(found.contains("actions[1].operations[1]=headerNameInvalid"), "\(found.sorted())")
        #expect(found.contains("actions[2].status=invalidStatus"), "\(found.sorted())")
        #expect(found.contains("actions[3].target_host=invalidTargetHost"), "\(found.sorted())")
        // The shared match is reported once, not once per element.
        #expect(found.contains("match.port=invalidPort"))
        #expect(found.filter { $0.hasPrefix("match.port") }.count == 1)
        #expect(!found.contains { $0.hasPrefix("actions[0]") })
        #expect(rig.saves.value == 0 && rig.editor.rules.isEmpty)
    }

    @Test func createWithActionsRefusesWhatTheEditorCannotBuild() async throws {
        let rig = try await Rig()
        func issues(_ spec: MCPRuleSpec) async -> Set<String> { issueSet(await rig.adapter.create(spec, enable: false)) }
        // Types that cannot be created through MCP, however they get here.
        let notCreatable = await issues(
            MCPRuleSpec(name: "x", match: [:], action: nil, actions: [remoteAction, ["type": .string("map_local")], ["type": .string("breakpoint")]]))
        #expect(notCreatable == ["actions[1].type=unsupported_type", "actions[2].type=unsupported_type"])
        // The count limits.
        #expect(await issues(MCPRuleSpec(name: "x", match: [:], action: nil, actions: [])) == ["actions=no_actions"])
        let seventeen = Array(repeating: statusAction, count: 17)
        #expect(await issues(MCPRuleSpec(name: "x", match: [:], action: nil, actions: seventeen)) == ["actions=too_many_actions"])
        // Only one of the two forms.
        #expect(
            await issues(MCPRuleSpec(name: "x", match: [:], action: remoteAction, actions: [remoteAction])) == ["actions=conflicts_with_action"])
        // A request-side action behind a status range, as in the Rules window.
        let behindRange = await issues(
            MCPRuleSpec(name: "x", match: ["status_min": .int(500), "status_max": .int(599)], action: nil, actions: [headerAction, ["type": .string("edit_headers")]]))
        #expect(behindRange == ["match.status_range=statusRangeNotAllowed"])
        // A word that names no mode.
        #expect(
            await issues(MCPRuleSpec(name: "x", match: ["mode": .string("some")], action: nil, actions: [statusAction]))
                == ["match.mode=invalid_value"])
        #expect(rig.saves.value == 0 && rig.editor.rules.isEmpty)
    }

    @Test func matchModeRoundTripsThroughCreateUpdateAndList() async throws {
        let rig = try await Rig()
        let spec = MCPRuleSpec(
            name: "None", match: ["host": .string("blocked.test"), "mode": .string("none")], action: statusAction)
        let id = try #require(savedID(await rig.adapter.create(spec, enable: false)))
        #expect(rig.editor.rules.first?.conditions.mode == ConditionGroup.Mode.none)
        #expect(rig.editor.rules.first?.simple?.mode == ConditionGroup.Mode.none)
        #expect(await rig.adapter.list(includeDisabled: true).rules.first?.mode == "none")

        // A patch without a mode keeps it; one with a mode changes only that.
        _ = await rig.adapter.update(id: id, MCPRuleSpec(name: nil, match: ["host": .string("other.test")], action: nil), enable: nil, allowEnabledRule: false)
        #expect(rig.editor.rules.first?.conditions.mode == ConditionGroup.Mode.none)
        #expect(rig.editor.rules.first?.simple?.matcher.hostPattern == "other.test")
        _ = await rig.adapter.update(id: id, MCPRuleSpec(name: nil, match: ["mode": .string("any")], action: nil), enable: nil, allowEnabledRule: false)
        #expect(rig.editor.rules.first?.conditions.mode == .any)
        #expect(rig.editor.rules.first?.simple?.matcher.hostPattern == "other.test")
        #expect(await rig.adapter.list(includeDisabled: true).rules.first?.mode == "any")
    }

    @Test func existingSingleActionCallsBehaveExactlyAsBefore() async throws {
        // The calls the existing tests make, once more as one story: a create with `action` makes only a rule
        // the old editor can state, and lists, patches and switches it as it always did.
        let rig = try await Rig()
        let id = try #require(savedID(await rig.adapter.create(remoteSpec(), enable: false)))
        let rule = try #require(rig.editor.rules.first)
        #expect(rule.simple != nil && rule.actions.count == 1 && !rule.actions[0].isFinal)
        #expect(rule.conditions.mode == .all && rule.conditions.occurrence == .any && rule.groupID == nil && rule.note == nil)

        let listed = try #require(await rig.adapter.list(includeDisabled: true).rules.first)
        #expect(listed.type == "map_remote" && listed.direction == nil)
        #expect(listed.match == .object(["scheme": .string("https"), "host": .string("api.test"), "syntax": .string("literal")]))
        #expect(listed.summary == "map_remote: https://api.test/* -> http://localhost:3000")
        #expect(listed.mode == "all" && listed.groupID == nil)
        #expect(listed.actions == [MCPRuleActionSummary(type: "map_remote", direction: nil, isFinal: false)])

        // An `action` patch keeps the rule one the old editor can state.
        let patched = await rig.adapter.update(id: id, MCPRuleSpec(name: nil, match: nil, action: statusAction), enable: nil, allowEnabledRule: false)
        #expect(savedID(patched) == id)
        #expect(rig.editor.rules.first?.simple?.action == .rewriteStatus(RewriteStatusAction(status: 503)))
        #expect(await rig.adapter.setEnabled(id: id, true) == .saved(id: id, enabled: true, revision: 3))
    }

    @Test func createRuleToolWithActionsReachesTheEditor() async throws {
        let rig = try await Rig()
        let tool = CreateRuleTool(rules: rig.adapter)
        let result = try await tool.call(
            [
                "name": .string("Tool combo"), "match": .object(["host": .string("tool.test"), "mode": .string("any"), "method": .string("POST")]),
                "actions": .array([.object(remoteAction), .object(statusAction)]),
            ], context: context())
        #expect(result["enabled"] == .bool(false))
        let rule = try #require(rig.editor.rules.first)
        #expect(rule.actions.count == 2 && rule.conditions.mode == .any && !rule.enabled)
        // And the listing the tool gives shows what was made.
        let listing = try await ListRulesTool(rules: rig.adapter).call([:], context: context())
        let item = try #require(listing["rules"]?.arrayValue?.first)
        #expect(item["type"] == .string("multiple") && item["match"] == .null && item["mode"] == .string("any"))
        #expect(item["actions"]?.arrayValue?.compactMap { $0["type"]?.stringValue } == ["map_remote", "rewrite_status"])
    }

    // MARK: update

    @Test func updateRefusesMatchPatchOnMultiActionRule() async throws {
        let multi = multiActionRule("Multi")
        let rig = try await Rig(seed: [multi])
        let unsupported: (String) -> MCPRuleWriteOutcome = { .invalid([MCPRuleIssue(field: $0, issue: "unsupported_type")]) }

        // A match patch, alone or with a name that would be fine, writes nothing at all.
        let match = MCPRuleSpec(name: nil, match: ["host": .string("other.test")], action: nil)
        #expect(await rig.adapter.update(id: multi.id, match, enable: nil, allowEnabledRule: true) == unsupported("match"))
        let both = MCPRuleSpec(name: "New name", match: ["mode": .string("none")], action: nil)
        #expect(await rig.adapter.update(id: multi.id, both, enable: true, allowEnabledRule: true) == unsupported("match"))
        // Neither is an action patch of either form: it would drop the other actions.
        let one = MCPRuleSpec(name: nil, match: nil, action: statusAction)
        #expect(await rig.adapter.update(id: multi.id, one, enable: nil, allowEnabledRule: true) == unsupported("action"))
        let many = MCPRuleSpec(name: nil, match: nil, action: nil, actions: [statusAction])
        #expect(await rig.adapter.update(id: multi.id, many, enable: nil, allowEnabledRule: true) == unsupported("actions"))
        // All of them at once are each named.
        let everything = MCPRuleSpec(name: "x", match: ["host": .string("h")], action: nil, actions: [statusAction])
        #expect(
            await rig.adapter.update(id: multi.id, everything, enable: nil, allowEnabledRule: true)
                == .invalid([MCPRuleIssue(field: "actions", issue: "unsupported_type"), MCPRuleIssue(field: "match", issue: "unsupported_type")]))

        #expect(rig.editor.rules == [multi] && rig.saves.value == 0 && rig.editor.revision == 1)
        #expect(rig.provider.rules == [multi])
    }

    @Test func updateRenamesAndEnablesAMultiActionRule() async throws {
        let multi = multiActionRule("Multi", mode: .any)
        let other = seedRule("Other", order: 1)
        let rig = try await Rig(seed: [multi, other])

        let renamed = await rig.adapter.update(
            id: multi.id, MCPRuleSpec(name: "Renamed", match: nil, action: nil), enable: true, allowEnabledRule: false)
        #expect(renamed == .saved(id: multi.id, enabled: true, revision: 2))
        // Only the name and the switch changed: every action, the rows in their order, the mode and the position stay.
        var expected = multi
        expected.name = "Renamed"
        expected.enabled = true
        #expect(rig.editor.rules == [expected, other])
        #expect(rig.provider.rules == [expected, other])

        // Enabled now, so a further change needs the permission; with it the rule can be switched off again.
        let rename = MCPRuleSpec(name: "Again", match: nil, action: nil)
        #expect(await rig.adapter.update(id: multi.id, rename, enable: nil, allowEnabledRule: false) == .ruleIsEnabled)
        let off = await rig.adapter.update(id: multi.id, rename, enable: false, allowEnabledRule: true)
        #expect(off == .saved(id: multi.id, enabled: false, revision: 3))
        expected.name = "Again"
        expected.enabled = false
        #expect(rig.editor.rules == [expected, other])
    }

    @Test func updateOfAMultiActionRuleWithATooLongNameIsInvalid() async throws {
        let multi = multiActionRule("Multi")
        let rig = try await Rig(seed: [multi])
        let outcome = await rig.adapter.update(
            id: multi.id, MCPRuleSpec(name: String(repeating: "n", count: 9000), match: nil, action: nil), enable: nil, allowEnabledRule: true)
        guard case .invalid(let issues) = outcome else {
            Issue.record("expected invalid, got \(outcome)")
            return
        }
        #expect(!issues.isEmpty)
        #expect(rig.editor.rules == [multi] && rig.saves.value == 0 && rig.editor.error == nil)
    }

    @Test func updateReplacesActionsOfASimpleRule() async throws {
        let group = RuleGroup(name: "Mine")
        var original = seedRule("Orig", host: "orig.test", order: 0)
        original.groupID = group.id
        original.conditions.mode = .any
        original.note = "keep me"
        let neighbour = seedRule("Neighbour", order: 1)
        let rig = try await Rig(seed: [original, neighbour], groups: [group])

        let spec = MCPRuleSpec(name: nil, match: nil, action: nil, actions: [remoteAction, headerAction, statusAction])
        let outcome = await rig.adapter.update(id: original.id, spec, enable: nil, allowEnabledRule: false)
        #expect(outcome == .saved(id: original.id, enabled: false, revision: 2))
        let rule = try #require(rig.editor.rules.first { $0.id == original.id })
        #expect(rule.actions.count == 3 && rule.actions.allSatisfy { !$0.isFinal })
        #expect(rule.actions.map(\.kind).first == .mapRemote(MapRemoteAction(targetScheme: "http", targetHost: "localhost", targetPort: 3000, path: .preserve)))
        // The match, the mode, the place and the note are the user's, and stay.
        #expect(rule.conditions == original.conditions)
        #expect(rule.name == "Orig" && rule.groupID == group.id && rule.note == "keep me" && rule.order == original.order)
        #expect(rig.editor.rules.map(\.id) == [original.id, neighbour.id] && rig.editor.rules[1] == neighbour)
        #expect(rig.editor.groups == [group])

        // The rule has several actions now, so the editor cannot state it and its match is not patched any more.
        let patch = MCPRuleSpec(name: nil, match: ["host": .string("new.test")], action: nil)
        #expect(
            await rig.adapter.update(id: original.id, patch, enable: nil, allowEnabledRule: false)
                == .invalid([MCPRuleIssue(field: "match", issue: "unsupported_type")]))

        // The whole list is replaced, not merged: one element leaves one action, and the rule is simple again.
        // A match patch in the same call applies to that new rule.
        let single = MCPRuleSpec(name: nil, match: ["host": .string("new.test")], action: nil, actions: [statusAction])
        #expect(savedID(await rig.adapter.update(id: neighbour.id, single, enable: nil, allowEnabledRule: false)) == neighbour.id)
        let again = try #require(rig.editor.rules.first { $0.id == neighbour.id })
        #expect(again.actions.map(\.kind) == [.rewriteStatus(RewriteStatusAction(status: 503))])
        #expect(again.simple?.matcher.hostPattern == "new.test" && again.simple?.mode == ConditionGroup.Mode.all)
        #expect(again.name == "Neighbour" && again.order == neighbour.order && again.groupID == nil)
    }

    @Test func updateActionsOfAFileOrBreakpointRuleIsUnsupported() async throws {
        var localID = UUID()
        let rig = try await Rig(seedWith: { fixture in
            let asset = try await fixture.assets.importFile(fixture.sourceFile("page.html", "<p>x</p>"), displayName: "page.html")
            let local = seedRule("Local", action: .mapLocal(MapLocalAction(assetID: asset.id, status: 200, headers: [])))
            let breakpoint = seedRule("Stop", order: 1, action: .breakpoint(direction: .request, mode: .headers))
            return [local, breakpoint]
        })
        localID = rig.editor.rules[0].id
        let breakpointID = rig.editor.rules[1].id
        let before = rig.editor.rules
        let spec = MCPRuleSpec(name: nil, match: nil, action: nil, actions: [statusAction])
        let unsupported = MCPRuleWriteOutcome.invalid([MCPRuleIssue(field: "action", issue: "unsupported_type")])
        #expect(await rig.adapter.update(id: localID, spec, enable: nil, allowEnabledRule: true) == unsupported)
        #expect(await rig.adapter.update(id: breakpointID, spec, enable: nil, allowEnabledRule: true) == unsupported)
        #expect(rig.editor.rules == before && rig.saves.value == 0)
    }

    @Test func updateWithActionsReportsIssuesLikeCreate() async throws {
        let original = seedRule("Orig")
        let rig = try await Rig(seed: [original])
        let badStatus: [String: JSONValue] = ["type": .string("rewrite_status"), "status": .int(99)]
        let outcome = await rig.adapter.update(
            id: original.id, MCPRuleSpec(name: nil, match: nil, action: nil, actions: [statusAction, badStatus]), enable: nil,
            allowEnabledRule: false)
        #expect(issueSet(outcome) == ["actions[1].status=invalidStatus"])
        let both = await rig.adapter.update(
            id: original.id, MCPRuleSpec(name: nil, match: nil, action: statusAction, actions: [statusAction]), enable: nil,
            allowEnabledRule: false)
        #expect(issueSet(both) == ["actions=conflicts_with_action"])
        #expect(rig.editor.rules == [original] && rig.saves.value == 0)
    }

    // MARK: list

    @Test func listSummarisesAMultiActionRule() async throws {
        let group = RuleGroup(name: "Mine")
        let multi = multiActionRule("Multi", mode: .any, groupID: group.id)
        let rig = try await Rig(seed: [multi], groups: [group])
        let listing = await rig.adapter.list(includeDisabled: true)
        let rule = try #require(listing.rules.first)
        #expect(rule.type == "multiple" && rule.direction == nil && rule.match == .null)
        #expect(rule.mode == "any")
        #expect(rule.groupID == group.id)
        #expect(
            rule.actions == [
                MCPRuleActionSummary(type: "map_remote", direction: nil, isFinal: false),
                MCPRuleActionSummary(type: "edit_headers", direction: "response", isFinal: false),
            ])
        #expect(rule.summary == "2 actions: map_remote, edit_headers on response; match: any of [host multi.test, method GET]")
        #expect(!rule.summary.contains("multiple ("))
    }

    @Test func listShowsTheCombinationModeOfEveryRule() async throws {
        // The same fields in each mode: only the mode tells which requests the rule applies to.
        func rule(_ name: String, _ mode: ConditionGroup.Mode, order: Int) -> Rule {
            var rule = seedRule(
                name, order: order, action: .rewriteStatus(RewriteStatusAction(status: 503)),
                matcher: RuleMatcher(scheme: "https", hostPattern: "a.test", method: "GET"))
            rule.conditions.mode = mode
            return rule
        }
        var empty = seedRule("Empty", order: 3, matcher: RuleMatcher())
        empty.conditions.mode = .none
        var directory = seedRule(
            "Dir none", order: 4, action: .mapLocalDirectory(MapLocalDirectoryAction(bookmark: Data([1, 2, 3]), displayName: "d")),
            matcher: RuleMatcher(hostPattern: "d.test", path: .prefix("/s/")))
        directory.conditions.mode = .none
        let rig = try await Rig(seed: [rule("All", .all, order: 0), rule("Any", .any, order: 1), rule("None", .none, order: 2), empty, directory])
        let listed = await rig.adapter.list(includeDisabled: true).rules
        #expect(listed.map(\.mode) == ["all", "any", "none", "none", "none"])
        // The fixed fields are listed the same way in every mode, so `mode` is what must be read with them: it is
        // a key of the listing and, unless it is the default, also said inside `match` where `create_rule` takes it.
        func fields(_ rule: MCPRuleSummary) -> [String: JSONValue] {
            var members = rule.match.objectValue ?? [:]
            members["mode"] = nil
            return members
        }
        #expect(fields(listed[0]) == fields(listed[1]) && fields(listed[1]) == fields(listed[2]))
        #expect(!fields(listed[0]).isEmpty)
        #expect(listed[0].match["mode"] == nil && listed[1].match["mode"] == .string("any") && listed[2].match["mode"] == .string("none"))
        #expect(listed.prefix(3).map(\.type) == ["rewrite_status", "rewrite_status", "rewrite_status"])
        // And the one-line summary says it too, so a client that reads only the summary is not misled.
        #expect(listed[0].summary == "rewrite_status on response: GET https://a.test/* -> status 503")
        #expect(listed[1].summary == "rewrite_status on response: any of [scheme https, host a.test, method GET] -> status 503")
        #expect(listed[2].summary == "rewrite_status on response: none of [scheme https, host a.test, method GET] -> status 503")
        // Without a field every mode matches every request, and the line says so.
        #expect(listed[3].summary == "edit_headers on request: any request (1 header change)")
        #expect(listed[3].match == .object(["mode": .string("none")]))
        // A rule whose summary does not show its match still says the mode; a file or directory rule is final by nature.
        #expect(listed[4].summary == "map_local_directory, match mode none")
        #expect(listed[4].actions == [MCPRuleActionSummary(type: "map_local_directory", direction: nil, isFinal: true)])
    }

    @Test func listSummarisesNonSimpleRulesWithoutPretendingTheyAreMultiple() async throws {
        let userFinal = Rule(
            id: UUID(), name: "Final", order: 0,
            conditions: ConditionGroup(rows: [ConditionRow(field: .host, op: .hostPattern, value: "f.test")]),
            actions: [RuleAction(.editHeaders(direction: .request, operations: [.set(name: "X-F", value: "1")]), isFinal: true)])
        let occurrence = Rule(
            id: UUID(), name: "Second hit", order: 1,
            conditions: ConditionGroup(occurrence: .times(2...3), rows: [ConditionRow(field: .host, op: .hostPattern, value: "o.test")]),
            actions: [RuleAction(.rewriteStatus(RewriteStatusAction(status: 500)))])
        let twoHosts = Rule(
            id: UUID(), name: "Two hosts", order: 2,
            conditions: ConditionGroup(
                mode: .any,
                rows: [
                    ConditionRow(field: .host, op: .hostPattern, value: "x.test"), ConditionRow(field: .host, op: .hostPattern, value: "y.test"),
                ]),
            actions: [RuleAction(.rewriteStatus(RewriteStatusAction(status: 500)))])
        let rig = try await Rig(seed: [userFinal, occurrence, twoHosts])
        let listed = await rig.adapter.list(includeDisabled: true).rules
        #expect(listed.map(\.type) == ["multiple", "multiple", "multiple"])
        #expect(listed.allSatisfy { $0.direction == nil && $0.match == .null })
        #expect(listed.map(\.mode) == ["all", "all", "any"])
        // One action is said to be one, and what makes the rule one the editor cannot state is said too.
        #expect(listed[0].summary == "1 action: edit_headers on request (final); match: *://f.test/*")
        #expect(listed[0].actions == [MCPRuleActionSummary(type: "edit_headers", direction: "request", isFinal: true)])
        #expect(listed[1].summary == "1 action: rewrite_status on response; match: *://o.test/*; occurrence 2-3")
        #expect(listed[2].summary == "1 action: rewrite_status on response; match: 2 condition rows, mode any")
        for rule in listed { #expect(!rule.summary.contains("multiple ("), "\(rule.summary)") }
    }

    @Test func listNeverShowsWhatTheActionsHoldBeyondTheirKind() async throws {
        let secret = Rule(
            id: UUID(), name: "Secrets", order: 0,
            conditions: ConditionGroup(rows: [ConditionRow(field: .host, op: .hostPattern, value: "s.test")]),
            actions: [
                RuleAction(.editHeaders(direction: .request, operations: [.set(name: "Authorization", value: "hunter2-secret")])),
                RuleAction(.rewriteBody(direction: .response, BodyRewriteAction(find: "find-secret", replacement: "replace-secret"))),
                RuleAction(.mapRemote(MapRemoteAction(targetScheme: "https", targetHost: "target-secret.test", targetPort: 443, path: .preserve))),
            ])
        let rig = try await Rig(seed: [secret])
        let rule = try #require(await rig.adapter.list(includeDisabled: true).rules.first)
        let text = "\(rule)"
        for forbidden in ["hunter2", "find-secret", "replace-secret", "target-secret", "Authorization"] {
            #expect(!text.contains(forbidden), "\(forbidden)")
        }
    }

    // MARK: switching and the breakpoint guard

    @Test func setEnabledOnAMultiActionRuleKeepsEveryAction() async throws {
        let multi = multiActionRule("Multi", mode: .none)
        let rig = try await Rig(seed: [multi])
        #expect(await rig.adapter.setEnabled(id: multi.id, true) == .saved(id: multi.id, enabled: true, revision: 2))
        var expected = multi
        expected.enabled = true
        #expect(rig.editor.rules == [expected] && rig.provider.rules == [expected])
        #expect(await rig.adapter.setEnabled(id: multi.id, false) == .saved(id: multi.id, enabled: false, revision: 3))
        #expect(rig.editor.rules == [multi])
    }

    @Test func breakpointInsideAMultiActionRuleCannotBeEnabledWhenNotLive() async throws {
        let breakpoint = RuleAction(.breakpoint(direction: .request, mode: .headers))
        let multi = multiActionRule("Stops", extra: [breakpoint])
        let rig = try await Rig(seed: [multi], liveBreakpoints: false)
        #expect(
            await rig.adapter.setEnabled(id: multi.id, true) == .invalid([MCPRuleIssue(field: "enabled", issue: "breakpoint_unavailable")]))
        #expect(rig.editor.rules == [multi] && rig.saves.value == 0 && rig.editor.error == nil)

        // A rename that also asks for the switch is saved, but stays off: the rule cannot go live yet.
        let renamed = await rig.adapter.update(
            id: multi.id, MCPRuleSpec(name: "Still stops", match: nil, action: nil), enable: true, allowEnabledRule: false)
        #expect(renamed == .saved(id: multi.id, enabled: false, revision: 2))
        #expect(rig.editor.rules.first?.enabled == false && rig.editor.rules.first?.name == "Still stops")

        // With the breakpoint window live the same switch works, and nothing but the switch changes.
        let live = try await Rig(seed: [multi], liveBreakpoints: true)
        #expect(await live.adapter.setEnabled(id: multi.id, true) == .saved(id: multi.id, enabled: true, revision: 2))
        #expect(live.editor.rules.first?.actions == multi.actions)
    }

    // MARK: external commit of a whole rule on the editor

    @Test func commitExternalRuleChecksNewnessTheSwitchAndValidity() async throws {
        let live = multiActionRule("Live", enabled: true, order: 0)
        let rig = try await Rig(seed: [live])
        let fresh = multiActionRule("Fresh")

        // A new rule cannot reuse a saved id; an existing one must exist.
        var reused = fresh
        reused.id = live.id
        #expect(await rig.editor.commitExternal(rule: reused, isNew: true, allowEnabledRule: true) == .conflict)
        #expect(await rig.editor.commitExternal(rule: fresh, isNew: false, allowEnabledRule: true) == .notFound)
        // An enabled rule is changed only when the caller may.
        var renamed = live
        renamed.name = "Renamed"
        #expect(await rig.editor.commitExternal(rule: renamed, isNew: false, allowEnabledRule: false) == .ruleIsEnabled)
        #expect(rig.editor.rules == [live] && rig.saves.value == 0)

        // A rule that does not validate is reported and nothing is written, nothing shown to the user.
        var broken = fresh
        broken.actions = []
        guard case .invalid = await rig.editor.commitExternal(rule: broken, isNew: true, allowEnabledRule: true) else {
            Issue.record("expected invalid")
            return
        }
        #expect(rig.saves.value == 0 && rig.editor.error == nil && rig.editor.issues.isEmpty)

        // A new rule is appended; an existing one is replaced in place, keeping its place and group.
        #expect(await rig.editor.commitExternal(rule: fresh, isNew: true, allowEnabledRule: false) == .saved(id: fresh.id, enabled: false, revision: 2))
        #expect(await rig.editor.commitExternal(rule: renamed, isNew: false, allowEnabledRule: true) == .saved(id: live.id, enabled: true, revision: 3))
        #expect(rig.editor.rules.map(\.id) == [live.id, fresh.id] && rig.editor.rules.map(\.order) == [0, 1])
        #expect(rig.editor.rules.first?.name == "Renamed")
    }

    @Test func commitExternalRuleLeavesADirtyOpenDraftAlone() async throws {
        let multi = multiActionRule("Multi")
        let plain = seedRule("Plain", order: 1)
        let rig = try await Rig(seed: [multi, plain])
        rig.editor.requestSelection(plain.id)
        var draft = try #require(rig.editor.draft)
        draft.name = "Half typed"
        rig.editor.setDraft(draft)
        #expect(rig.editor.isDraftDirty)

        var renamed = plain
        renamed.name = "AI name"
        #expect(await rig.editor.commitExternal(rule: renamed, isNew: false, allowEnabledRule: true) == .beingEdited)
        #expect(rig.editor.draft?.name == "Half typed" && rig.saves.value == 0)
        // Another rule is not blocked by the open draft.
        var other = multi
        other.name = "Multi renamed"
        #expect(await rig.editor.commitExternal(rule: other, isNew: false, allowEnabledRule: true) == .saved(id: multi.id, enabled: false, revision: 2))
        #expect(rig.editor.draft?.name == "Half typed" && rig.editor.isDraftDirty)
    }
}

@MainActor @Suite(.timeLimit(.minutes(2)), .productionChinese) struct MCPRulesAdapterAnnotationTests {
    private func markSpec(_ color: String, extra: [String: JSONValue] = [:]) -> MCPRuleSpec {
        MCPRuleSpec(
            name: "Mark", match: remoteMatch(),
            action: ["type": .string("mark"), "color": .string(color)].merging(extra) { $1 })
    }

    private func commentSpec(_ extra: [String: JSONValue] = [:]) -> MCPRuleSpec {
        MCPRuleSpec(
            name: "Note", match: remoteMatch(),
            action: ["type": .string("comment")].merging(extra) { $1 })
    }

    @Test func createMarkRuleFromAPresetName() async throws {
        let rig = try await Rig()
        let id = try #require(savedID(await rig.adapter.create(markSpec("red", extra: ["text": .string("slow")]), enable: false)))
        let rule = try #require(rig.editor.rules.first { $0.id == id })
        #expect(rule.actions.first?.kind == .mark(MarkAction(background: "#FF3B30", text: "slow")))
    }

    @Test func createMarkRuleFromHex() async throws {
        let rig = try await Rig()
        let outcome = await rig.adapter.create(markSpec("#00ff00", extra: ["text_color": .string("#ffffff")]), enable: false)
        let id = try #require(savedID(outcome))
        let rule = try #require(rig.editor.rules.first { $0.id == id })
        #expect(rule.actions.first?.kind == .mark(MarkAction(background: "#00FF00", foreground: "#FFFFFF")))
    }

    @Test func invalidColourIsAnIssueAtActionColor() async throws {
        let rig = try await Rig()
        let outcome = await rig.adapter.create(markSpec("chartreuse"), enable: false)
        #expect(issueSet(outcome).contains { $0.hasPrefix("action.color=") })
        #expect(rig.editor.rules.isEmpty && rig.saves.value == 0)
        let badText = await rig.adapter.create(markSpec("red", extra: ["text_color": .string("nope")]), enable: false)
        #expect(issueSet(badText).contains { $0.hasPrefix("action.text_color=") })
    }

    @Test func createCommentRuleInAppendMode() async throws {
        let rig = try await Rig()
        let outcome = await rig.adapter.create(commentSpec(["mode": .string("append"), "text": .string("checked")]), enable: false)
        let id = try #require(savedID(outcome))
        let rule = try #require(rig.editor.rules.first { $0.id == id })
        #expect(rule.actions.first?.kind == .comment(CommentAction(mode: .append, text: "checked")))
        let replace = await rig.adapter.create(
            commentSpec(["mode": .string("find_replace"), "text": .string("a"), "replace": .string("b")]), enable: false)
        let replaceID = try #require(savedID(replace))
        let stored = try #require(rig.editor.rules.first { $0.id == replaceID })
        #expect(stored.actions.first?.kind == .comment(CommentAction(mode: .findReplace, text: "a", replacement: "b")))
        let clear = await rig.adapter.create(commentSpec(["mode": .string("clear")]), enable: false)
        #expect(savedID(clear) != nil)
    }

    @Test func unknownCommentModeIsAnIssue() async throws {
        let rig = try await Rig()
        let outcome = await rig.adapter.create(commentSpec(["mode": .string("prepend"), "text": .string("x")]), enable: false)
        #expect(issueSet(outcome) == ["action.mode=invalid_value"])
        #expect(rig.editor.rules.isEmpty)
    }

    @Test func listShowsMarkCommentAndHideTypes() async throws {
        let matcher = RuleMatcher(hostPattern: "ann.test")
        let rules = [
            Rule(id: UUID(), name: "M", enabled: true, order: 0, matcher: matcher, annotation: .mark(MarkAction(background: "#FF3B30"))),
            Rule(id: UUID(), name: "C", enabled: true, order: 1, matcher: matcher, annotation: .comment(CommentAction(mode: .append, text: "x"))),
            Rule(id: UUID(), name: "H", enabled: true, order: 2, matcher: matcher, annotation: .hide),
        ]
        let rig = try await Rig(seed: rules)
        let listing = await rig.adapter.list(includeDisabled: true)
        #expect(listing.rules.map(\.type) == ["mark", "comment", "hide"])
        #expect(listing.rules.allSatisfy { $0.direction == nil })
        let hide = try #require(listing.rules.last)
        #expect(hide.match == .object(["host": .string("ann.test"), "syntax": .string("literal")]))
        #expect(hide.summary.hasPrefix("hide: "))
        #expect(hide.actions == [MCPRuleActionSummary(type: "hide", direction: nil, isFinal: true)])
    }

    @Test func updatePatchChangesAMarkRulesColour() async throws {
        let original = Rule(
            id: UUID(), name: "M", enabled: false, order: 0, matcher: RuleMatcher(hostPattern: "ann.test"),
            annotation: .mark(MarkAction(background: "#FF3B30", text: "keep")))
        let rig = try await Rig(seed: [original])
        let outcome = await rig.adapter.update(
            id: original.id, MCPRuleSpec(name: nil, match: nil, action: ["type": .string("mark"), "color": .string("blue")]),
            enable: nil, allowEnabledRule: false)
        #expect(savedID(outcome) == original.id)
        #expect(rig.editor.rules.first?.actions.first?.kind == .mark(MarkAction(background: "#007AFF", text: "keep")))
        #expect(rig.editor.rules.first?.conditions == original.conditions)
        // A hide rule can be renamed and switched, but MCP never re-matches or re-actions it.
        let hide = Rule(id: UUID(), name: "H", enabled: false, order: 1, matcher: RuleMatcher(hostPattern: "h.test"), annotation: .hide)
        let second = try await Rig(seed: [hide])
        let unsupported: (String) -> MCPRuleWriteOutcome = { .invalid([MCPRuleIssue(field: $0, issue: "unsupported_type")]) }
        let rematch = MCPRuleSpec(name: "Hidden", match: ["host": .string("other.test")], action: nil)
        #expect(await second.adapter.update(id: hide.id, rematch, enable: nil, allowEnabledRule: false) == unsupported("match"))
        let reaction = MCPRuleSpec(name: nil, match: nil, action: statusAction)
        #expect(await second.adapter.update(id: hide.id, reaction, enable: nil, allowEnabledRule: false) == unsupported("action"))
        let many = MCPRuleSpec(name: nil, match: nil, action: nil, actions: [statusAction])
        #expect(await second.adapter.update(id: hide.id, many, enable: nil, allowEnabledRule: false) == unsupported("action"))
        #expect(second.editor.rules.first?.name == "H")
        let renamed = await second.adapter.update(
            id: hide.id, MCPRuleSpec(name: "Hidden", match: nil, action: nil), enable: nil, allowEnabledRule: false)
        #expect(savedID(renamed) == hide.id)
        #expect(second.editor.rules.first?.actions.first?.kind == .hide)
        #expect(second.editor.rules.first?.name == "Hidden")
    }
}

// MARK: conditions (Rules 2.0 R3)

private let markRed: [String: JSONValue] = ["type": .string("mark"), "color": .string("red")]

private func conditionsSpec(
    _ rows: [MCPConditionRowSpec], mode: String? = nil, name: String = "Slow", action: [String: JSONValue]? = markRed,
    actions: [[String: JSONValue]]? = nil
) -> MCPRuleSpec {
    MCPRuleSpec(
        name: name, match: nil, action: actions == nil ? action : nil, actions: actions,
        conditions: MCPConditionsSpec(mode: mode, rows: rows))
}

private func conditionRow(
    _ field: String, name: String? = nil, _ op: String, _ value: String = "", caseSensitive: Bool = false
) -> MCPConditionRowSpec {
    MCPConditionRowSpec(field: field, name: name, op: op, value: value, caseSensitive: caseSensitive)
}

private let slowRow = conditionRow("durationMs", "greaterThan", "1000")

extension MCPRulesAdapterTests {
    @Test func createRuleWithConditionsRows() async throws {
        let rig = try await Rig()
        let outcome = await rig.adapter.create(
            conditionsSpec([slowRow, conditionRow("requestHeader", name: "X-Test", "equals", "1")], mode: "any"), enable: false)
        let id = try #require(savedID(outcome), "\(outcome)")
        let rule = try #require(rig.editor.rules.first { $0.id == id })
        #expect(rule.enabled == false && rule.name == "Slow")
        #expect(rule.conditions.mode == .any)
        #expect(
            rule.conditions.rows == [
                ConditionRow(field: .durationMs, op: .greaterThan, value: "1000"),
                ConditionRow(field: .requestHeader, name: "X-Test", op: .equals, value: "1"),
            ])
        #expect(rule.actions.count == 1)
        if case .mark(let mark) = rule.actions.first?.kind { #expect(mark.background.hasPrefix("#")) } else { Issue.record("not a mark") }
        // The same through an actions list.
        let many = await rig.adapter.create(
            conditionsSpec([conditionRow("method", "equals", "GET")], actions: [markRed, ["type": .string("comment"), "text": .string("hi")]]),
            enable: false)
        let second = try #require(savedID(many), "\(many)")
        #expect(rig.editor.rules.first { $0.id == second }?.actions.count == 2)
    }

    @Test func createRejectsMatchAndConditionsTogether() async throws {
        let rig = try await Rig()
        var spec = conditionsSpec([slowRow])
        spec.match = remoteMatch()
        #expect(issueSet(await rig.adapter.create(spec, enable: false)) == ["conditions=conflicts_with_match"])
        #expect(rig.editor.rules.isEmpty)
        // An update does the same.
        let seeded = seedRule("A")
        let second = try await Rig(seed: [seeded])
        #expect(
            issueSet(await second.adapter.update(id: seeded.id, spec, enable: nil, allowEnabledRule: false))
                == ["conditions=conflicts_with_match"])
    }

    @Test func legacyOnlyOperatorIsRejected() async throws {
        let rig = try await Rig()
        for op in ["hostPattern", "wildcard", "regexWhole"] {
            let outcome = await rig.adapter.create(conditionsSpec([slowRow, conditionRow("host", op, "a.test")]), enable: false)
            #expect(issueSet(outcome) == ["conditions.rows[1].op=invalid_value"], "\(op)")
        }
        #expect(rig.editor.rules.isEmpty)
    }

    @Test func unknownFieldIsAnIssueAtThatRow() async throws {
        let rig = try await Rig()
        let outcome = await rig.adapter.create(
            conditionsSpec([slowRow, conditionRow("bogus", "equals", "x"), conditionRow("method", "bogusOp", "x")], mode: "some"),
            enable: false)
        #expect(
            issueSet(outcome) == [
                "conditions.rows[1].field=invalid_value", "conditions.rows[2].op=invalid_value", "conditions.mode=invalid_value",
            ])
        #expect(rig.editor.rules.isEmpty)
    }

    @Test func rowProblemsAreNamedByMember() async throws {
        let rig = try await Rig()
        let outcome = await rig.adapter.create(
            conditionsSpec([
                conditionRow("queryParam", "equals", "1"), conditionRow("method", name: "X", "equals", "GET"),
                conditionRow("durationMs", "greaterThan", "slow"), conditionRow("statusCode", "greaterThan", "x"),
                conditionRow("sessionState", "contains", "failed"),
            ]), enable: false)
        #expect(
            issueSet(outcome) == [
                "conditions.rows[0].name=conditionNameRequired", "conditions.rows[1].name=unexpectedConditionName",
                "conditions.rows[2].value=invalidConditionValue", "conditions.rows[3].value=invalidConditionValue",
                "conditions.rows[4].op=invalidOperator",
            ])
    }

    @Test func completionRuleRejectsHeaderEditActions() async throws {
        let rig = try await Rig()
        let single = await rig.adapter.create(conditionsSpec([slowRow], action: headerAction), enable: false)
        #expect(issueSet(single) == ["action=actionNotAllowedAtCompletion"])
        let several = await rig.adapter.create(conditionsSpec([slowRow], actions: [markRed, headerAction]), enable: false)
        #expect(issueSet(several) == ["actions[1]=actionNotAllowedAtCompletion"])
        #expect(rig.editor.rules.isEmpty)
        // Marks and comments are fine at completion.
        let ok = await rig.adapter.create(conditionsSpec([slowRow]), enable: false)
        #expect(savedID(ok) != nil)
    }

    @Test func invalidRegexIsAnIssueAtTheRowValue() async throws {
        let rig = try await Rig()
        let outcome = await rig.adapter.create(
            conditionsSpec([conditionRow("method", "equals", "GET"), conditionRow("requestHeader", name: "X", "regex", "(")]),
            enable: false)
        #expect(issueSet(outcome) == ["conditions.rows[1].value=invalidRegex"])
        // The tool filter keeps the field path.
        let tool = CreateRuleTool(rules: rig.adapter)
        let issues = try await toolIssues(
            tool,
            [
                "name": .string("x"),
                "conditions": .object(["rows": .array([.object(["field": .string("requestHeader"), "name": .string("X"), "op": .string("regex"), "value": .string("(")])])]),
                "action": .object(markRed),
            ])
        #expect(issues.map { "\($0.field)=\($0.issue)" } == ["conditions.rows[0].value=invalidRegex"])
    }

    @Test func tooManyRowsIsAnIssue() async throws {
        let rig = try await Rig()
        let rows = Array(repeating: conditionRow("method", "equals", "GET"), count: 33)
        #expect(issueSet(await rig.adapter.create(conditionsSpec(rows), enable: false)) == ["conditions.rows=tooManyConditions"])
    }

    @Test func listRulesShowsConditionsForNewFieldRules() async throws {
        let rule = Rule(
            id: UUID(), name: "Slow", enabled: false, order: 0,
            conditions: ConditionGroup(
                mode: .any,
                rows: [
                    ConditionRow(field: .durationMs, op: .greaterThan, value: "1000"),
                    ConditionRow(field: .requestHeader, name: "X-Test", op: .contains, value: "a", caseSensitive: true),
                    ConditionRow(field: .host, op: .equals, value: "a.test"),
                ]),
            actions: [RuleAction(.mark(MarkAction(background: "#FF0000")))])
        let rig = try await Rig(seed: [rule])
        let listed = try #require(await rig.adapter.list(includeDisabled: true).rules.first)
        #expect(listed.type == "multiple" && listed.match == .null && listed.mode == "any")
        #expect(
            listed.conditions
                == .object([
                    "mode": .string("any"),
                    "rows": .array([
                        .object(["field": .string("durationMs"), "op": .string("greaterThan"), "value": .string("1000"), "case_sensitive": .bool(false)]),
                        .object([
                            "field": .string("requestHeader"), "name": .string("X-Test"), "op": .string("contains"),
                            "value": .string("a"), "case_sensitive": .bool(true),
                        ]),
                        .object(["field": .string("host"), "op": .string("equals"), "value": .string("a.test"), "case_sensitive": .bool(false)]),
                    ]),
                ]))
    }

    @Test func legacySingleMatchRulesListExactlyAsBefore() async throws {
        let rig = try await Rig(seed: [seedRule("A", host: "a.test"), multiActionRule("M")])
        let listing = await rig.adapter.list(includeDisabled: true)
        #expect(listing.rules.map(\.conditions) == [nil, nil])
        #expect(listing.rules[0].match == .object(["host": .string("a.test"), "syntax": .string("literal")]))
    }

    @Test func updatePatchCanReplaceConditions() async throws {
        let seeded = seedRule("A", host: "a.test")
        let rig = try await Rig(seed: [seeded])
        let spec = MCPRuleSpec(
            name: nil, match: nil, action: nil,
            conditions: MCPConditionsSpec(mode: "none", rows: [conditionRow("method", "equals", "POST")]))
        // A bad row changes nothing.
        let bad = MCPRuleSpec(name: nil, match: nil, action: nil, conditions: MCPConditionsSpec(mode: nil, rows: [conditionRow("nope", "equals", "x")]))
        #expect(issueSet(await rig.adapter.update(id: seeded.id, bad, enable: nil, allowEnabledRule: false)) == ["conditions.rows[0].field=invalid_value"])
        #expect(rig.editor.rules == [seeded])
        let outcome = await rig.adapter.update(id: seeded.id, spec, enable: nil, allowEnabledRule: false)
        #expect(savedID(outcome) == seeded.id, "\(outcome)")
        let rule = try #require(rig.editor.rules.first)
        #expect(rule.conditions.mode == .none)
        #expect(rule.conditions.rows == [ConditionRow(field: .method, op: .equals, value: "POST")])
        #expect(rule.actions == seeded.actions && rule.name == "A")
    }

    @Test func updateReplacesTheConditionsOfAMultiActionRule() async throws {
        var multi = multiActionRule("M", mode: .any)
        multi.conditions.occurrence = .times(2...3)
        let rig = try await Rig(seed: [multi])
        let spec = MCPRuleSpec(
            name: nil, match: nil, action: nil,
            conditions: MCPConditionsSpec(mode: nil, rows: [conditionRow("method", "equals", "POST")]))
        // A bad row changes nothing.
        let bad = MCPRuleSpec(
            name: nil, match: nil, action: nil, conditions: MCPConditionsSpec(mode: nil, rows: [conditionRow("nope", "equals", "x")]))
        #expect(issueSet(await rig.adapter.update(id: multi.id, bad, enable: nil, allowEnabledRule: false)) == ["conditions.rows[0].field=invalid_value"])
        #expect(rig.editor.rules == [multi] && rig.saves.value == 0)
        let outcome = await rig.adapter.update(id: multi.id, spec, enable: nil, allowEnabledRule: false)
        #expect(savedID(outcome) == multi.id, "\(outcome)")
        let rule = try #require(rig.editor.rules.first)
        #expect(rule.conditions.rows == [ConditionRow(field: .method, op: .equals, value: "POST")])
        // Mode (unset in the patch) and occurrence stay; actions and name are untouched.
        #expect(rule.conditions.mode == .any && rule.conditions.occurrence == .times(2...3))
        #expect(rule.actions == multi.actions && rule.name == "M")
        // Together with a match, an action or actions it is refused and nothing is written.
        let other = multiActionRule("N")
        let second = try await Rig(seed: [other])
        let rows = [conditionRow("method", "equals", "POST")]
        let withMatch = MCPRuleSpec(name: nil, match: ["host": .string("h")], action: nil, conditions: MCPConditionsSpec(mode: nil, rows: rows))
        #expect(await second.adapter.update(id: other.id, withMatch, enable: nil, allowEnabledRule: true)
            == .invalid([MCPRuleIssue(field: "conditions", issue: "conflicts_with_match")]))
        let withAction = MCPRuleSpec(name: nil, match: nil, action: statusAction, conditions: MCPConditionsSpec(mode: nil, rows: rows))
        #expect(issueSet(await second.adapter.update(id: other.id, withAction, enable: nil, allowEnabledRule: true))
            == ["action=unsupported_type", "conditions=unsupported_type"])
        let withActions = MCPRuleSpec(name: nil, match: nil, action: nil, actions: [statusAction], conditions: MCPConditionsSpec(mode: nil, rows: rows))
        #expect(issueSet(await second.adapter.update(id: other.id, withActions, enable: nil, allowEnabledRule: true))
            == ["actions=unsupported_type", "conditions=unsupported_type"])
        #expect(second.editor.rules == [other] && second.saves.value == 0)
    }

    @Test func updatingConditionsOfAnEnabledMultiActionRuleNeedsPermission() async throws {
        let multi = multiActionRule("M", enabled: true)
        let rig = try await Rig(seed: [multi])
        let spec = MCPRuleSpec(
            name: nil, match: nil, action: nil,
            conditions: MCPConditionsSpec(mode: nil, rows: [conditionRow("method", "equals", "POST")]))
        #expect(await rig.adapter.update(id: multi.id, spec, enable: nil, allowEnabledRule: false) == .ruleIsEnabled)
        #expect(rig.editor.rules == [multi] && rig.saves.value == 0)
        #expect(savedID(await rig.adapter.update(id: multi.id, spec, enable: nil, allowEnabledRule: true)) == multi.id)
        #expect(rig.editor.rules.first?.conditions.rows == [ConditionRow(field: .method, op: .equals, value: "POST")])
    }

    @Test func conditionsOnAHideRuleAreStillRefused() async throws {
        let hide = Rule(id: UUID(), name: "H", enabled: false, order: 0, matcher: RuleMatcher(hostPattern: "h.test"), annotation: .hide)
        let rig = try await Rig(seed: [hide])
        let spec = MCPRuleSpec(
            name: nil, match: nil, action: nil,
            conditions: MCPConditionsSpec(mode: nil, rows: [conditionRow("method", "equals", "POST")]))
        #expect(await rig.adapter.update(id: hide.id, spec, enable: nil, allowEnabledRule: true)
            == .invalid([MCPRuleIssue(field: "conditions", issue: "unsupported_type")]))
        #expect(rig.editor.rules == [hide])
    }

    @Test func conditionsCannotEnableARuleWithoutPermission() async throws {
        let rig = try await Rig()
        let tool = CreateRuleTool(rules: rig.adapter)
        let arguments: [String: JSONValue] = [
            "name": .string("Slow"),
            "conditions": .object(["rows": .array([.object(["field": .string("durationMs"), "op": .string("greaterThan"), "value": .string("1000")])])]),
            "action": .object(markRed), "enable": .bool(true),
        ]
        do {
            _ = try await tool.call(arguments, context: context(allowEnabling: false))
            Issue.record("expected permission_denied")
        } catch let error as MCPToolError {
            #expect(error.code == "permission_denied")
        }
        #expect(rig.editor.rules.isEmpty)
        let result = try await tool.call(arguments, context: context(allowEnabling: true))
        #expect(result["enabled"] == .bool(true))
        #expect(rig.editor.rules.first?.enabled == true)
    }

    @Test func conditionsOfAMultiActionHideRuleAreRefusedButRenameWorks() async throws {
        var hide = multiActionRule("H", extra: [RuleAction(.hide)])
        hide.name = "H"
        let rig = try await Rig(seed: [hide])
        let rows = [conditionRow("durationMs", "greaterThan", "5")]
        let spec = MCPRuleSpec(name: nil, match: nil, action: nil, conditions: MCPConditionsSpec(mode: nil, rows: rows))
        #expect(await rig.adapter.update(id: hide.id, spec, enable: nil, allowEnabledRule: true)
            == .invalid([MCPRuleIssue(field: "conditions", issue: "unsupported_type")]))
        #expect(rig.editor.rules == [hide])
        let renamed = await rig.adapter.update(
            id: hide.id, MCPRuleSpec(name: "Hidden", match: nil, action: nil), enable: true, allowEnabledRule: true)
        #expect(savedID(renamed) == hide.id)
    }
}

// MARK: Rules 2.0 R4: URL, query and cookie edits through MCP

private func r4Rule(_ name: String, _ kinds: [ActionKind], enabled: Bool = false, order: Int = 0) -> Rule {
    Rule(
        id: UUID(), name: name, enabled: enabled, order: order,
        conditions: ConditionGroup(rows: [ConditionRow(field: .host, op: .equals, value: "r4.test")]),
        actions: kinds.map { RuleAction($0) })
}

private let urlSetAction: [String: JSONValue] = [
    "type": .string("modify_url"), "mode": .string("set"), "replacement": .string("https://b.test/x?a=1"),
]
private let querySetAction: [String: JSONValue] = [
    "type": .string("modify_query"),
    "operations": .array([
        .object(["op": .string("set"), "name": .string("a"), "value": .string("1")]),
        .object(["op": .string("add"), "name": .string("b"), "value": .string("2")]),
        .object(["op": .string("remove"), "name": .string("c")]),
        .object(["op": .string("replace"), "name": .string("d"), "find": .string("x"), "replacement": .string("y"), "case_sensitive": .bool(true)]),
        .object(["op": .string("replace"), "find": .string("p"), "replacement": .string("q")]),
    ]),
]

private func r4Spec(_ action: [String: JSONValue], match: [String: JSONValue] = ["host": .string("api.test")]) -> MCPRuleSpec {
    MCPRuleSpec(name: "R4", match: match, action: action)
}

extension MCPRulesAdapterTests {
    @Test func createModifyURLRuleSavedDisabledByDefault() async throws {
        let rig = try await Rig()
        let outcome = await rig.adapter.create(r4Spec(urlSetAction), enable: false)
        let id = try #require(savedID(outcome), "\(outcome)")
        let rule = try #require(rig.editor.rules.first { $0.id == id })
        #expect(rule.enabled == false && rule.name == "R4")
        #expect(rule.actions == [RuleAction(.modifyURL(URLEditAction(mode: .set, replacement: "https://b.test/x?a=1")))])
        #expect(rule.actions.first?.isFinal == false)
        #expect(rule.conditions.rows.contains { $0.field == .host && $0.value == "api.test" })
        // The other modes and flags map one to one.
        let more = await rig.adapter.create(
            r4Spec([
                "type": .string("modify_url"), "mode": .string("regex"), "find": .string("v(\\d)"), "replacement": .string("w$1"),
                "case_sensitive": .bool(true), "preserve_credentials": .bool(true),
            ]), enable: false)
        let second = try #require(savedID(more), "\(more)")
        #expect(
            rig.editor.rules.first { $0.id == second }?.actions
                == [RuleAction(.modifyURL(URLEditAction(mode: .regex, find: "v(\\d)", replacement: "w$1", caseSensitive: true, preserveCredentials: true)))])
    }

    @Test func createModifyQueryRuleRoundTrips() async throws {
        let rig = try await Rig()
        let id = try #require(savedID(await rig.adapter.create(r4Spec(querySetAction), enable: false)))
        let rule = try #require(rig.editor.rules.first { $0.id == id })
        #expect(
            rule.actions == [
                RuleAction(.modifyQuery(QueryEditAction(operations: [
                    .set(name: "a", value: "1"), .add(name: "b", value: "2"), .remove(name: "c"),
                    .findReplace(name: "d", find: "x", replacement: "y", caseSensitive: true),
                    .findReplace(name: nil, find: "p", replacement: "q", caseSensitive: false),
                ])))
            ])
        // list shows it back in the shape create takes.
        let listed = try #require(await rig.adapter.list(includeDisabled: true).rules.first?.actions.first)
        #expect(listed.type == "modify_query" && listed.direction == "request" && listed.isFinal == false)
        #expect(listed.fields == .object(["operations": querySetAction["operations"]!.withCaseSensitive()]))
        #expect(listed.summary == "modify_query (5 operations)")
    }

    /// R8F2: every mode the engine gained is created, listed and re-created through MCP without loss.
    @Test func theNewEditModesRoundTripThroughCreateAndList() async throws {
        let rig = try await Rig()
        let urlAppend: [String: JSONValue] = ["type": .string("modify_url"), "mode": .string("append"), "replacement": .string("?x=1")]
        let query: [String: JSONValue] = [
            "type": .string("modify_query"),
            "operations": .array([
                .object(["op": .string("regex"), "name": .string("a"), "pattern": .string("(\\d)"), "replacement": .string("n$1"), "case_sensitive": .bool(true)]),
                .object(["op": .string("regex"), "pattern": .string("x"), "replacement": .string("y"), "case_sensitive": .bool(false)]),
                .object(["op": .string("add_if_missing"), "name": .string("b"), "value": .string("2")]),
                .object(["op": .string("append_to_value"), "name": .string("c"), "text": .string("!")]),
                .object(["op": .string("set"), "value": .string("all")]),
            ]),
        ]
        let cookies: [String: JSONValue] = [
            "type": .string("edit_cookies"), "direction": .string("response"),
            "operations": .array([.object(["op": .string("append_to_value"), "name": .string("sid"), "text": .string("-x")])]),
        ]
        let id = try #require(savedID(await rig.adapter.create(MCPRuleSpec(name: "R8F2", match: ["host": .string("a.test")], action: nil, actions: [urlAppend, query, cookies]), enable: false)))
        let rule = try #require(rig.editor.rules.first { $0.id == id })
        let expected: [ActionKind] = [
            .modifyURL(URLEditAction(mode: .append, replacement: "?x=1")),
            .modifyQuery(QueryEditAction(operations: [
                .regex(name: "a", pattern: "(\\d)", replacement: "n$1", caseSensitive: true),
                .regex(name: nil, pattern: "x", replacement: "y", caseSensitive: false),
                .addIfMissing(name: "b", value: "2"), .appendToValue(name: "c", text: "!"), .set(name: "", value: "all"),
            ])),
            .editCookies(direction: .response, operations: [.appendToValue(name: "sid", text: "-x")]),
        ]
        #expect(rule.actions.map(\.kind) == expected)

        // What list says is what create takes: feeding the listed fields back gives the same actions.
        let listed = try #require(await rig.adapter.list(includeDisabled: true).rules.first { $0.id == id }?.actions)
        #expect(listed.map(\.type) == ["modify_url", "modify_query", "edit_cookies"])
        let again = listed.map { action -> [String: JSONValue] in
            var members = action.fields?.objectValue ?? [:]
            members["type"] = .string(action.type)
            if let direction = action.direction, action.type == "edit_cookies" { members["direction"] = .string(direction) }
            return members
        }
        let second = try #require(savedID(await rig.adapter.create(MCPRuleSpec(name: "Again", match: ["host": .string("a.test")], action: nil, actions: again), enable: false)))
        #expect(rig.editor.rules.first { $0.id == second }?.actions.map(\.kind) == expected)
    }

    @Test func commentModesAndCaseThroughMCP() async throws {
        let rig = try await Rig()
        for (word, mode) in [("regex", CommentAction.Mode.regex), ("add_if_missing", .addIfMissing)] {
            let spec = MCPRuleSpec(
                name: word, match: ["host": .string("a.test")],
                action: ["type": .string("comment"), "mode": .string(word), "text": .string("a(.)"), "replace": .string("$1"), "case_sensitive": .bool(false)])
            let id = try #require(savedID(await rig.adapter.create(spec, enable: false)), "\(word)")
            guard case .comment(let stored)? = rig.editor.rules.first(where: { $0.id == id })?.actions.first?.kind else {
                Issue.record("expected a comment")
                return
            }
            #expect(stored.mode == mode && stored.text == "a(.)")
            if mode == .regex { #expect(stored.replacement == "$1" && stored.caseSensitive == false) }
            let listed = try #require(await rig.adapter.list(includeDisabled: true).rules.first { $0.id == id })
            #expect(listed.summary.contains(word), "\(listed.summary)")
        }
    }

    @Test func createEditCookiesRequestAndResponse() async throws {
        let rig = try await Rig()
        let operations: JSONValue = .array([
            .object(["op": .string("set"), "name": .string("sid"), "value": .string("1")]),
            .object(["op": .string("add_if_missing"), "name": .string("lang"), "value": .string("zh")]),
            .object(["op": .string("remove"), "name": .string("old")]),
            .object(["op": .string("replace"), "find": .string("a"), "replacement": .string("b")]),
            .object(["op": .string("regex"), "name": .string("t"), "pattern": .string("^a+"), "replacement": .string("c"), "case_sensitive": .bool(true)]),
        ])
        for direction in ["request", "response"] {
            let action: [String: JSONValue] = ["type": .string("edit_cookies"), "direction": .string(direction), "operations": operations]
            let id = try #require(savedID(await rig.adapter.create(r4Spec(action), enable: false)), "\(direction)")
            let rule = try #require(rig.editor.rules.first { $0.id == id })
            #expect(
                rule.actions == [
                    RuleAction(.editCookies(
                        direction: HTTPMessageDirection(rawValue: direction)!,
                        operations: [
                            .set(name: "sid", value: "1"), .addIfMissing(name: "lang", value: "zh"), .remove(name: "old"),
                            .findReplace(name: nil, find: "a", replacement: "b", caseSensitive: false),
                            .regex(name: "t", pattern: "^a+", replacement: "c", caseSensitive: true),
                        ]))
                ])
            let listed = try #require(await rig.adapter.list(includeDisabled: true).rules.first { $0.id == id }?.actions.first)
            #expect(listed.type == "edit_cookies" && listed.direction == direction)
        }
        // No direction given means the request.
        let plain = await rig.adapter.create(
            r4Spec(["type": .string("edit_cookies"), "operations": .array([.object(["op": .string("remove"), "name": .string("a")])])]),
            enable: false)
        let id = try #require(savedID(plain))
        #expect(rig.editor.rules.first { $0.id == id }?.actions.first?.kind.direction == .request)
    }

    @Test func newActionsWorkInActionsListsAndUpdate() async throws {
        let rig = try await Rig(seed: [seedRule("Old", host: "old.test")])
        let old = rig.editor.rules[0]
        let mixed = MCPRuleSpec(name: "Mixed", match: ["host": .string("m.test")], action: nil, actions: [headerAction, urlSetAction, querySetAction])
        let created = try #require(savedID(await rig.adapter.create(mixed, enable: false)))
        #expect(rig.editor.rules.first { $0.id == created }?.actions.count == 3)
        // A legacy single-action rule can be switched to a new type, by action or by actions.
        let byAction = await rig.adapter.update(id: old.id, MCPRuleSpec(name: nil, match: nil, action: urlSetAction), enable: nil, allowEnabledRule: false)
        #expect(savedID(byAction) == old.id, "\(byAction)")
        #expect(rig.editor.rules.first { $0.id == old.id }?.actions == [RuleAction(.modifyURL(URLEditAction(mode: .set, replacement: "https://b.test/x?a=1")))])
        // The rule is now of the new model; its actions and match are replaced as a whole.
        let again = await rig.adapter.update(
            id: old.id, MCPRuleSpec(name: nil, match: nil, action: nil, actions: [querySetAction]), enable: nil, allowEnabledRule: false)
        #expect(issueSet(again) == ["actions=unsupported_type"], "\(again)")
    }

    @Test func createdRuleValidatesLikeAnyRule() async throws {
        let rig = try await Rig()
        func issues(_ action: [String: JSONValue], match: [String: JSONValue] = ["host": .string("a.test")]) async -> Set<String> {
            issueSet(await rig.adapter.create(r4Spec(action, match: match), enable: false))
        }
        #expect(await issues(["type": .string("modify_url"), "mode": .string("set"), "replacement": .string("not a url")]) == ["action=invalidURLEdit"])
        #expect(await issues(["type": .string("modify_url"), "mode": .string("find_replace")]) == ["action=emptyEditFind"])
        #expect(await issues(["type": .string("modify_url"), "mode": .string("regex"), "find": .string("(")]) == ["action=invalidRegex"])
        #expect(await issues(["type": .string("modify_url"), "mode": .string("sideways")]) == ["action.mode=invalid_value"])
        #expect(
            await issues(["type": .string("modify_query"), "operations": .array([.object(["op": .string("set"), "name": .string("a&b"), "value": .string("1")])])])
                == ["action.operations=invalidQueryEdit"])
        #expect(await issues(["type": .string("modify_query")]) == ["action.operations=invalidQueryEdit"])
        #expect(
            await issues(["type": .string("edit_cookies"), "operations": .array([.object(["op": .string("set"), "name": .string("a;b"), "value": .string("1")])])])
                == ["action.operations=invalidCookieEdit"])
        #expect(
            await issues(["type": .string("edit_cookies"), "operations": .array([.object(["op": .string("sideways"), "name": .string("a")])])])
                == ["action.operations[0].op=invalid_value"])
        #expect(
            await issues(["type": .string("edit_cookies"), "direction": .string("up"), "operations": .array([])])
                .contains("action.direction=invalid_value"))
        // The match is checked once, with the rest.
        #expect(
            await issues(urlSetAction, match: ["scheme": .string("ftp")]).contains("match.scheme=invalid_value"))
        // In an actions list the element is named.
        let list = await rig.adapter.create(
            MCPRuleSpec(name: "L", match: ["host": .string("a.test")], action: nil, actions: [headerAction, ["type": .string("modify_url"), "mode": .string("find_replace")]]),
            enable: false)
        #expect(issueSet(list) == ["actions[1]=emptyEditFind"])
        // A response-side judgment cannot host a request-side edit; the whole-rule check says so.
        let late = await rig.adapter.create(
            MCPRuleSpec(
                name: "Late", match: nil, action: urlSetAction,
                conditions: MCPConditionsSpec(mode: nil, rows: [conditionRow("durationMs", "greaterThan", "10")])),
            enable: false)
        #expect(issueSet(late) == ["action=actionNotAllowedAtCompletion"], "\(late)")
        #expect(rig.editor.rules.isEmpty)
    }

    @Test func newActionIssuesReachTheToolFilterUnchanged() async throws {
        let rig = try await Rig()
        let found = try await toolIssues(
            CreateRuleTool(rules: rig.adapter),
            ["name": .string("X"), "match": .object([:]), "action": .object(["type": .string("modify_url"), "mode": .string("find_replace")])])
        #expect(found.map { "\($0.field)=\($0.issue)" } == ["action=emptyEditFind"])
    }

    // MARK: listing what MCP cannot create

    @Test func listRulesShowsReadOnlyTypesForNonCreatableActions() async throws {
        let kinds: [ActionKind] = [
            .returnHandwritten(HandwrittenResponse(text: "HTTP/1.1 200 OK\r\n\r\nSECRETBODY")),
            .returnPreset(PresetResponse(preset: .found302, location: "https://x.test/?token=LOCSECRET")),
            .closeConnection(.reset), .delay(milliseconds: 250),
        ]
        let seed = kinds.enumerated().map { r4Rule("N\($0.offset)", [$0.element], order: $0.offset) }
        let rig = try await Rig(seed: seed)
        let listed = await rig.adapter.list(includeDisabled: true).rules
        let types = listed.flatMap { $0.actions.map(\.type) }
        #expect(types == ["return_handwritten", "return_preset", "close_connection", "delay"])
        for rule in listed {
            let action = try #require(rule.actions.first)
            #expect(action.fields == nil, "\(action.type) lists no fields")
            #expect(action.summary?.isEmpty == false)
            #expect(!"\(rule)".contains("SECRETBODY") && !"\(rule)".contains("LOCSECRET"))
        }
        #expect(listed[3].actions[0].summary?.contains("250") == true)
    }

    @Test func wireTypeNamesArePinned() {
        let table: [(ActionKind, String)] = [
            (.returnFile(MapLocalAction(assetID: UUID(), status: 200, headers: [])), "map_local"),
            (.returnDirectory(MapLocalDirectoryAction(bookmark: Data([1]), displayName: "d"), pathPrefix: "/"), "map_local_directory"),
            (.mapRemote(MapRemoteAction(targetScheme: "http", targetHost: "h", targetPort: 80, path: .preserve)), "map_remote"),
            (.editHeaders(direction: .request, operations: []), "edit_headers"),
            (.breakpoint(direction: .request, mode: .headers), "breakpoint"),
            (.rewriteBody(direction: .request, BodyRewriteAction(find: "a", replacement: "b")), "rewrite_body"),
            (.rewriteStatus(RewriteStatusAction(status: 200)), "rewrite_status"),
            (.mark(MarkAction(background: "#FF0000")), "mark"),
            (.comment(CommentAction(mode: .clear)), "comment"),
            (.hide, "hide"),
            (.modifyURL(URLEditAction(mode: .set)), "modify_url"),
            (.modifyQuery(QueryEditAction(operations: [])), "modify_query"),
            (.editCookies(direction: .request, operations: []), "edit_cookies"),
            (.delay(milliseconds: 1), "delay"),
            (.returnHandwritten(HandwrittenResponse(text: "")), "return_handwritten"),
            (.returnPreset(PresetResponse(preset: .gif200)), "return_preset"),
            (.closeConnection(.graceful), "close_connection"),
            (.returnConnectTunnel, "return_connect_tunnel"),
            (.noDecrypt, "no_decrypt"),
        ]
        for (kind, name) in table { #expect(MCPRulesAdapter.summary(of: RuleAction(kind)).type == name, "\(name)") }
    }

    @Test func listRulesRedactsQueryValuesInURLEditSummary() async throws {
        let rule = r4Rule("Redirect", [
            .modifyURL(URLEditAction(mode: .set, replacement: "https://b.test/x?access_token=URLSECRET&page=2")),
            .modifyQuery(QueryEditAction(operations: [.set(name: "api_key", value: "QSECRET"), .set(name: "page", value: "7")])),
            .editCookies(direction: .request, operations: [.set(name: "sid", value: "CSECRET")]),
        ])
        let rig = try await Rig(seed: [rule])
        let result = try await ListRulesTool(rules: rig.adapter).call([:], context: context())
        let text = "\(result)"
        for secret in ["URLSECRET", "QSECRET", "CSECRET"] { #expect(!text.contains(secret), "\(secret)") }
        #expect(text.contains("page=2") && text.contains("[REDACTED]"))
        let actions = try #require(result["rules"]?.arrayValue?.first?["actions"]?.arrayValue)
        #expect(actions.map { $0["type"]?.stringValue } == ["modify_url", "modify_query", "edit_cookies"])
        #expect(actions[0]["replacement"]?.stringValue?.contains("page=2") == true)
    }

    // MARK: rules MCP cannot edit

    @Test func updateRuleRefusesToReplaceNonCreatableActions() async throws {
        let rule = r4Rule("Slow", [.delay(milliseconds: 100), .mark(MarkAction(background: "#FF0000"))])
        let rig = try await Rig(seed: [rule])
        let patches: [(String, MCPRuleSpec)] = [
            ("actions", MCPRuleSpec(name: nil, match: nil, action: nil, actions: [headerAction])),
            ("action", MCPRuleSpec(name: nil, match: nil, action: urlSetAction)),
            ("match", MCPRuleSpec(name: nil, match: ["host": .string("z.test")], action: nil)),
            ("conditions", MCPRuleSpec(name: nil, match: nil, action: nil, conditions: MCPConditionsSpec(mode: nil, rows: [conditionRow("method", "equals", "GET")]))),
        ]
        for (field, spec) in patches {
            let outcome = await rig.adapter.update(id: rule.id, spec, enable: nil, allowEnabledRule: true)
            #expect(outcome == .invalid([MCPRuleIssue(field: field, issue: "contains_non_creatable_action")]), "\(field): \(outcome)")
        }
        #expect(rig.editor.rules == [rule] && rig.saves.value == 0)
        // The same through the tool: the message says why.
        do {
            _ = try await UpdateRuleTool(rules: rig.adapter).call(
                ["id": .string(rule.id.uuidString), "actions": .array([.object(headerAction)])], context: context())
            Issue.record("expected rule_invalid")
        } catch let error as MCPToolError {
            #expect(error.code == "rule_invalid" && error.message.contains("only be edited in ProxyWoman"))
        }
    }

    @Test func updateRuleStillRenamesAndTogglesThem() async throws {
        let rule = r4Rule("Gone", [.noDecrypt])
        let rig = try await Rig(seed: [r4Rule("Other", [.closeConnection(.graceful)], order: 0), rule].enumerated().map { var r = $0.element; r.order = $0.offset; return r })
        let renamed = await rig.adapter.update(id: rule.id, MCPRuleSpec(name: "Renamed", match: nil, action: nil), enable: nil, allowEnabledRule: false)
        #expect(savedID(renamed) == rule.id, "\(renamed)")
        #expect(rig.editor.rules.first { $0.id == rule.id }?.name == "Renamed")
        #expect(rig.editor.rules.first { $0.id == rule.id }?.actions == rule.actions)
        let off = await rig.adapter.setEnabled(id: rule.id, false)
        #expect(savedID(off) == rule.id, "\(off)")
        #expect(rig.editor.rules.first { $0.id == rule.id }?.actions == rule.actions)
    }

    // MARK: what MCP can never produce

    @Test func mcpCannotProduceFinalOrConnectActions() async throws {
        let rig = try await Rig()
        let forbidden = [
            "delay", "return_handwritten", "return_preset", "close_connection", "return_connect_tunnel", "no_decrypt", "hide",
            "map_local", "Modify_URL", "modify_url ", "",
        ]
        for type in forbidden {
            let single = await rig.adapter.create(r4Spec(["type": .string(type)]), enable: false)
            #expect(issueSet(single) == ["action.type=unsupported_type"], "\(type): \(single)")
            let several = await rig.adapter.create(
                MCPRuleSpec(name: "X", match: [:], action: nil, actions: [urlSetAction, ["type": .string(type)]]), enable: false)
            #expect(issueSet(several) == ["actions[1].type=unsupported_type"], "\(type): \(several)")
        }
        // A final flag, milliseconds or a close mode are not members of any creatable action.
        let sneaky = await rig.adapter.create(
            r4Spec(urlSetAction.merging(["final": .bool(true), "milliseconds": .int(5), "mode": .string("set")]) { $1 }), enable: false)
        let id = try #require(savedID(sneaky), "\(sneaky)")
        for action in try #require(rig.editor.rules.first { $0.id == id }?.actions) {
            #expect(!action.isFinal && !action.kind.isIntrinsicallyFinal && !action.kind.isConnectOnly)
        }
        #expect(rig.editor.rules.count == 1)
        for rule in rig.editor.rules {
            for action in rule.actions {
                switch action.kind {
                case .modifyURL, .modifyQuery, .editCookies, .mapRemote, .editHeaders, .rewriteBody, .rewriteStatus, .mark, .comment: break
                default: Issue.record("MCP produced \(action.kind)")
                }
            }
        }
    }

    @Test func nonBooleanFlagsAreInvalidValuesNotDefaults() async throws {
        let rig = try await Rig()
        let url = await rig.adapter.create(r4Spec(urlSetAction.merging(["case_sensitive": .string("yes")]) { $1 }), enable: false)
        #expect(issueSet(url) == ["action.case_sensitive=invalid_value"], "\(url)")
        let cookies = await rig.adapter.create(
            r4Spec(["type": .string("edit_cookies"), "operations": .array([.object(["op": .string("remove"), "name": .string("a"), "case_sensitive": .int(1)])])]),
            enable: false)
        #expect(issueSet(cookies) == ["action.operations[0].case_sensitive=invalid_value"], "\(cookies)")
        #expect(rig.editor.rules.isEmpty)
    }

    @Test func singleActionSugarStillWorksForLegacyTypes() async throws {
        let rig = try await Rig()
        let id = try #require(savedID(await rig.adapter.create(remoteSpec(), enable: false)))
        let rule = try #require(rig.editor.rules.first { $0.id == id })
        #expect(rule.action == .mapRemote(MapRemoteAction(targetScheme: "http", targetHost: "localhost", targetPort: 3000, path: .preserve)))
        let listed = try #require(await rig.adapter.list(includeDisabled: true).rules.first)
        #expect(listed.type == "map_remote" && listed.actions.first?.summary == nil && listed.actions.first?.fields == nil)
    }
}

extension JSONValue {
    /// The operations as `list` states them: every operation spells out `case_sensitive` where it applies.
    fileprivate func withCaseSensitive() -> JSONValue {
        guard case .array(let items) = self else { return self }
        return .array(
            items.map { item in
                guard case .object(var members) = item else { return item }
                if members["op"]?.stringValue == "replace" { members["case_sensitive"] = members["case_sensitive"] ?? .bool(false) }
                return .object(members)
            })
    }
}


@Suite(.productionChinese) struct MCPRuleIssueCodeTests {
    /// The tool reports a draft issue by its raw value, so the new editor's issues and the engine's codes read the same
    /// to an AI client.
    @Test func mcpCodesUseRawValues() {
        let pairs: [(RuleDraftIssue, RuleValidationError.Code)] = [
            (.invalidOperator, .invalidOperator), (.tooManyConditions, .tooManyConditions),
            (.tooManyActions, .tooManyActions), (.noActions, .noActions),
            (.conditionNameRequired, .conditionNameRequired), (.unexpectedConditionName, .unexpectedConditionName),
            (.invalidConditionName, .invalidConditionName), (.invalidConditionValue, .invalidConditionValue),
        ]
        for (issue, code) in pairs { #expect(issue.rawValue == code.rawValue) }
        #expect(RuleDraftIssue.actionNotAllowedAtResponsePoint.rawValue == "actionNotAllowedAtResponsePoint")
        #expect(RuleDraftIssue.actionNotAllowedAtCompletionPoint.rawValue == "actionNotAllowedAtCompletionPoint")
        #expect(MCPRuleIssue(field: "x", issue: RuleDraftIssue.noActions.rawValue).issue == "noActions")
    }
}
