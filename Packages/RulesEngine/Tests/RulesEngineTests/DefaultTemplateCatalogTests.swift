import FlowStore
import Foundation
import Testing

@testable import RulesEngine

/// The catalog against the reference list (`DefaultTemplateReferenceTable`), read here with this file's own
/// decoding of the reference numbers, not the catalog's tables.
@Suite struct DefaultTemplateCatalogTests {
    private struct Table: Decodable {
        struct Group: Decodable { var index: Int; var parent: Int?; var priority: Int; var header: String; var enabled: Bool }
        struct Match: Decodable {
            var type: Int; var key: String?; var condition: String; var value: String
            var caseInsensitiveValue: Bool; var caseInsensitiveKey: Bool
        }
        struct Action: Decodable {
            var type: Int; var condition: String; var key: String; var value: String; var find: String; var lang: String?
        }
        struct Rule: Decodable {
            var index: Int; var group: Int; var priority: Int; var enabled: Bool; var comment: String; var mc: Int
            var matches: [Match]; var actions: [Action]
        }
        var groups: [Group]
        var rules: [Rule]
    }

    private static let table = try! JSONDecoder().decode(Table.self, from: Data(DefaultTemplateReferenceTable.json.utf8))
    private static let set = DefaultTemplateCatalog.build(groupName: { "G\($0.rawValue)" }, ruleName: { "R\($0.rawValue)" })
    private let limits = RulesLimits()

    // MARK: reading the reference numbers

    private func field(_ type: Int) -> ConditionField {
        switch type {
        case 2: .host
        case 4: .url
        case 6: .method
        case 7: .clientApp
        case 16: .responseHeader
        case 31: .appProtocol
        case 32: .allSessions
        default: preconditionFailure("unmapped match type \(type)")
        }
    }

    private func op(_ condition: String) -> ConditionOperator {
        switch condition {
        case "regexp": .regex
        case "contains": .contains
        case "eq", "": .equals
        case "doesnotcontain": .notContains
        default: preconditionFailure("unmapped condition \(condition)")
        }
    }

    private func protocolName(_ id: String) -> String {
        ["2": "websocket", "5": "rpc", "24": "grpc", "25": "sse", "26": "socketio"][id]!
    }

    private func mode(_ matchCondition: Int) -> ConditionGroup.Mode { [1: .all, 2: .any, 3: .none][matchCondition]! }

    private let logo = DefaultTemplateRules.logoDataURI

    private func expectedRow(_ match: Table.Match) -> ConditionRow {
        let f = field(match.type)
        let value = f == .appProtocol ? protocolName(match.value) : match.value
        let key = (match.key ?? "").isEmpty ? nil : match.key
        return ConditionRow(
            field: f, name: key, op: op(match.condition), value: value, caseSensitive: !match.caseInsensitiveValue,
            nameCaseSensitive: f.hasKeyCaseOption ? !match.caseInsensitiveKey : nil)
    }

    private func headers(_ direction: HTTPMessageDirection, _ action: Table.Action) -> ActionKind {
        let edit: HeaderEdit = action.condition == "remove"
            ? .remove(name: action.key, nameCaseSensitive: false)
            : .set(name: action.key, value: action.value, nameCaseSensitive: false)
        return .editHeaders(direction: direction, operations: [edit])
    }

    /// nil for the two actions whose content this app writes itself (checked separately).
    private func expectedAction(_ action: Table.Action) -> ActionKind? {
        let value = action.value.replacingOccurrences(of: "{LOGO}", with: logo)
        switch action.type {
        case 1: return .mark(MarkAction(background: ["fuchsia": "#FF19FFFF", "aqua": "#03FFFFFF"][action.value]!))
        case 2: return headers(.request, action)
        case 3: return headers(.response, action)
        case 5:
            return .rewriteBody(
                direction: .response,
                BodyRewriteAction(
                    find: action.find, replacement: value, syntax: action.condition == "regex" ? .regex : .text,
                    caseSensitive: false, editorLanguage: action.lang))
        case 6:
            let urlMode: URLEditAction.Mode = action.condition == "regex" ? .regex : .set
            return .modifyURL(URLEditAction(mode: urlMode, find: urlMode == .set ? "" : action.find, replacement: value))
        case 11, 12: return nil
        case 13: return .hide
        case 16: return .closeConnection(.reset)
        case 20: return .rewriteStatus(RewriteStatusAction.parse(action.value)!)
        case 22: return .returnConnectTunnel
        default: preconditionFailure("unmapped action \(action.type)")
        }
    }

    // MARK: the table

    @Test func nineGroupsAndTwentyEightRules() {
        #expect(Self.table.groups.count == 9 && Self.set.groups.count == 9)
        #expect(Self.table.rules.count == 28 && Self.set.rules.count == 28)
        #expect(DefaultTemplateGroupKey.allCases.count == 9 && DefaultTemplateRuleKey.allCases.count == 28)
    }

    @Test(arguments: Array(0..<9)) func groupMatchesTheReference(_ index: Int) throws {
        let reference = Self.table.groups[index]
        let key = try #require(DefaultTemplateGroupKey(rawValue: index))
        let group = try #require(Self.set.groups.first { $0.id == DefaultTemplateCatalog.groupID(key) })
        #expect(group.name == "G\(index)")
        #expect(group.enabled == reference.enabled)
        #expect(group.parentID == reference.parent.flatMap(DefaultTemplateGroupKey.init).map(DefaultTemplateCatalog.groupID))
        #expect(group.order == reference.priority - 1)
    }

    @Test func groupIDsAreTheFixedOnes() {
        #expect(Self.set.rootGroupID == UUID(uuidString: "E5D57F79-22A5-43CF-810D-B25D57CA71A6"))
        #expect(Self.set.groups.first?.id == Self.set.rootGroupID)
        #expect(Set(Self.set.groups.map(\.id)).count == 9 && Set(Self.set.rules.map(\.id)).count == 28)
        // Built twice, the same ids and content.
        #expect(DefaultTemplateCatalog.build(groupName: { "G\($0.rawValue)" }, ruleName: { "R\($0.rawValue)" }) == Self.set)
    }

    @Test(arguments: Array(0..<28)) func ruleMatchesTheReference(_ index: Int) throws {
        let reference = Self.table.rules[index]
        let key = try #require(DefaultTemplateRuleKey(rawValue: index))
        let rule = try #require(Self.set.rules.first { $0.id == DefaultTemplateCatalog.ruleID(key) }, "\(reference.comment)")
        #expect(rule.name == "R\(index)")
        #expect(rule.enabled == reference.enabled, "\(reference.comment)")
        #expect(rule.groupID == DefaultTemplateGroupKey(rawValue: reference.group).map(DefaultTemplateCatalog.groupID))
        #expect(rule.order == reference.priority - 1)
        #expect(rule.conditions.mode == mode(reference.mc), "\(reference.comment)")
        #expect(rule.conditions.occurrence == .any)
        // A "return CONNECT tunnel" rule is judged at the CONNECT line, where this app takes no method row (the
        // action only runs there anyway), so the reference's "method contains CONNECT" row is not carried.
        let isTunnel = reference.actions.contains { $0.type == 22 }
        let rows = reference.matches.filter { !(isTunnel && $0.type == 6) }.map(expectedRow)
        // The reference lists "all sessions" with no comparison; this app stores it with `equals`.
        #expect(rule.conditions.rows == rows, "\(reference.comment)")
        #expect(rule.actions.count == reference.actions.count, "\(reference.comment)")
        for (action, expected) in zip(rule.actions, reference.actions) {
            switch expected.type {
            case 11:
                guard case .returnHandwritten(let response) = action.kind else { Issue.record("not a manual response"); continue }
                guard case .success(let parsed) = response.parse() else { Issue.record("manual response does not parse"); continue }
                #expect(parsed.response.status == 200 && parsed.warnings.isEmpty)
            case 12:
                guard case .returnFile(let file) = action.kind else { Issue.record("not a file"); continue }
                #expect(file.assetID == DefaultTemplateCatalog.exampleFilePlaceholderID && file.status == 200)
            default:
                #expect(action.kind == expectedAction(expected), "\(reference.comment)")
            }
            // Final by nature or not at all; the reference's flag is carried by the action itself.
            #expect(!action.isFinal)
        }
    }

    /// The reference's "has a final action" flag: the actions that end evaluation by nature are those the
    /// reference marked final (close, hide, CONNECT tunnel); a manual response and a file are final here but
    /// were not in the reference (recorded difference).
    @Test func finalActionsFollowTheReferenceExceptManualResponseAndFile() {
        let differing: Set<Int> = [15, 17]
        for reference in Self.table.rules {
            let rule = Self.set.rules.first { $0.id == DefaultTemplateCatalog.ruleID(DefaultTemplateRuleKey(rawValue: reference.index)!) }!
            let isFinal = rule.actions.contains { $0.isFinalEffective }
            let referenceFinal = reference.actions.contains { [13, 16, 22].contains($0.type) }
            if differing.contains(reference.index) {
                #expect(isFinal && !referenceFinal)
            } else {
                #expect(isFinal == referenceFinal, "\(reference.comment)")
            }
        }
    }

    // MARK: validity

    @Test func everyRuleValidatesAndRoundTrips() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for rule in Self.set.rules {
            try rule.validate(limits: limits)
            let data = try encoder.encode(rule)
            #expect(try JSONDecoder().decode(Rule.self, from: data) == rule, "\(rule.name)")
        }
        for group in Self.set.groups {
            #expect(try JSONDecoder().decode(RuleGroup.self, from: encoder.encode(group)) == group)
        }
    }

    @Test func theTreeValidatesAndOnlyTheTopGroupOffSwitchesEverythingOff() throws {
        let snapshot = RuleSnapshot(revision: 1, groups: Self.set.groups, rules: Self.set.rules)
        try snapshot.validateStructure(limits: limits)
        #expect(snapshot.evaluationOrder.isEmpty, "the top group is disabled, so nothing can run")
        var enabled = snapshot
        enabled.groups = enabled.groups.map { var g = $0; if g.id == Self.set.rootGroupID { g.enabled = true }; return g }
        let running = enabled.evaluationOrder.map(\.name)
        // The rules of the two disabled "map local" subgroups stay off; the others are disabled rules.
        #expect(running.isEmpty)
    }

    @Test func orderInsideAGroupFollowsThePriority() {
        for key in DefaultTemplateGroupKey.allCases {
            let id = DefaultTemplateCatalog.groupID(key)
            let rules = Self.set.rules.filter { $0.groupID == id }
            let groups = Self.set.groups.filter { $0.parentID == id }
            let orders = rules.map(\.order) + groups.map(\.order)
            #expect(Set(orders).count == orders.count, "\(key): one number per sibling")
        }
    }

    // MARK: neutral content

    @Test func noReferenceBrandOrLocalPathSurvives() throws {
        let encoder = JSONEncoder()
        let text = String(decoding: try encoder.encode(Self.set.rules) + encoder.encode(Self.set.groups), as: UTF8.self)
        for word in ["Fiddler", "Telerik", "Progress", "wikimedia", "niliev", "/Users/", "ECS (sed"] {
            #expect(!text.localizedCaseInsensitiveContains(word), "\(word)")
        }
        #expect(Self.set.assets.count == 1)
        #expect(Self.set.assets[0].displayName == "example.dat")
        #expect(!String(decoding: Self.set.assets[0].data, as: UTF8.self).isEmpty)
    }

    @Test func theManualResponseIsAnExamplePage() throws {
        let text = DefaultTemplateRules.exampleResponse.text
        guard case .success(let parsed) = DefaultTemplateRules.exampleResponse.parse() else {
            Issue.record("does not parse")
            return
        }
        #expect(parsed.warnings.isEmpty && parsed.response.status == 200)
        #expect(text.contains("Example Page"))
    }

    @Test func theLogoIsAnInlineImage() {
        #expect(DefaultTemplateRules.logoDataURI.hasPrefix("data:image/svg+xml,"))
        #expect(!DefaultTemplateRules.logoDataURI.contains("<") && !DefaultTemplateRules.logoDataURI.contains("$"))
    }
}
