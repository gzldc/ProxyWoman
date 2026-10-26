import FlowStore
import Foundation
import Testing

@testable import RulesEngine

private func json(_ kind: ActionKind) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(kind), as: UTF8.self)
}

private let assetID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

/// The kinds Rules 2.0 R1…R3 stored, with the bytes baseline 688abd4 wrote for them.
private let existingGoldens: [(ActionKind, String)] = [
    (
        .returnFile(MapLocalAction(assetID: assetID, status: 200, headers: [HeaderField(name: "A", value: "b")])),
        #"{"returnFile":{"_0":{"assetID":"00000000-0000-0000-0000-000000000001","headers":[{"name":"A","value":"b"}],"status":200}}}"#
    ),
    (
        .returnDirectory(MapLocalDirectoryAction(bookmark: Data([1]), displayName: "d"), pathPrefix: "/x/"),
        #"{"returnDirectory":{"_0":{"bookmark":"AQ==","displayName":"d","headers":[],"missing":"notFound","servesIndex":true},"pathPrefix":"\/x\/"}}"#
    ),
    (
        .mapRemote(MapRemoteAction(targetScheme: "https", targetHost: "b.test", targetPort: 443, path: .preserve)),
        #"{"mapRemote":{"_0":{"path":{"preserve":{}},"preserveCredentials":false,"targetHost":"b.test","targetPort":443,"targetScheme":"https"}}}"#
    ),
    (
        .editHeaders(direction: .request, operations: [.set(name: "A", value: "b"), .remove(name: "C")]),
        #"{"editHeaders":{"direction":"request","operations":[{"set":{"name":"A","value":"b"}},{"remove":{"name":"C"}}]}}"#
    ),
    (.breakpoint(direction: .response, mode: .fullBody), #"{"breakpoint":{"direction":"response","mode":"fullBody"}}"#),
    (
        .rewriteBody(direction: .response, BodyRewriteAction(find: "a", replacement: "b")),
        #"{"rewriteBody":{"_1":{"caseSensitive":true,"find":"a","replacement":"b","scope":"all","syntax":"text"},"direction":"response"}}"#
    ),
    (
        .rewriteStatus(RewriteStatusAction(status: 404)),
        #"{"rewriteStatus":{"_0":{"includeLocalResponses":false,"status":404}}}"#
    ),
    (.mark(MarkAction(background: "#FF3B30")), ##"{"mark":{"_0":{"background":"#FF3B30"}}}"##),
    (
        .comment(CommentAction(text: "x")),
        #"{"comment":{"_0":{"mode":"append","replacement":"","text":"x"}}}"#
    ),
    (.hide, #"{"hide":{}}"#),
]

/// The nine kinds R4 appends and their stored shapes.
private let newGoldens: [(ActionKind, String)] = [
    (
        .modifyURL(URLEditAction(mode: .set, replacement: "https://a.test/")),
        #"{"modifyURL":{"_0":{"caseSensitive":false,"find":"","mode":"set","preserveCredentials":false,"replacement":"https:\/\/a.test\/"}}}"#
    ),
    (
        .modifyQuery(QueryEditAction(operations: [.set(name: "a", value: "1")])),
        #"{"modifyQuery":{"_0":{"operations":[{"set":{"name":"a","value":"1"}}]}}}"#
    ),
    (
        .editCookies(direction: .response, operations: [.remove(name: "sid")]),
        #"{"editCookies":{"direction":"response","operations":[{"remove":{"name":"sid"}}]}}"#
    ),
    (.delay(milliseconds: 500), #"{"delay":{"milliseconds":500}}"#),
    (
        .returnHandwritten(HandwrittenResponse(text: "HTTP/1.1 200 OK")),
        #"{"returnHandwritten":{"_0":{"text":"HTTP\/1.1 200 OK"}}}"#
    ),
    (
        .returnPreset(PresetResponse(preset: .found302, location: "https://a.test/")),
        #"{"returnPreset":{"_0":{"location":"https:\/\/a.test\/","preset":"found302"}}}"#
    ),
    (.closeConnection(.reset), #"{"closeConnection":{"_0":"reset"}}"#),
    (.returnConnectTunnel, #"{"returnConnectTunnel":{}}"#),
    (.noDecrypt, #"{"noDecrypt":{}}"#),
]

@Suite struct ActionKindCodableR4Tests {
    @Test func newKindsHaveTheirGoldenShape() throws {
        #expect(newGoldens.count == 9)
        for (kind, golden) in newGoldens {
            #expect(try json(kind) == golden)
            #expect(try JSONDecoder().decode(ActionKind.self, from: Data(golden.utf8)) == kind)
        }
    }

    @Test func existingKindsKeepTheirShape() throws {
        #expect(existingGoldens.count == 10)
        for (kind, golden) in existingGoldens {
            #expect(try json(kind) == golden)
            #expect(try JSONDecoder().decode(ActionKind.self, from: Data(golden.utf8)) == kind)
        }
    }

    @Test func everyNewPayloadRoundTrips() throws {
        let kinds: [ActionKind] = [
            .modifyURL(URLEditAction(mode: .regex, find: "a(.)", replacement: "b$1", caseSensitive: true, preserveCredentials: true)),
            .modifyQuery(
                QueryEditAction(operations: [
                    .set(name: "a", value: "1"), .add(name: "b", value: "2"), .remove(name: "c"),
                    .findReplace(name: nil, find: "x", replacement: "y", caseSensitive: true),
                ])),
            .editCookies(
                direction: .request,
                operations: [
                    .set(name: "a", value: "1"), .addIfMissing(name: "b", value: "2"), .remove(name: "c"),
                    .findReplace(name: "d", find: "x", replacement: "y", caseSensitive: false),
                    .regex(name: nil, pattern: "x+", replacement: "y", caseSensitive: true),
                ]),
            .returnPreset(PresetResponse(preset: .unauthorized401, body: "no", challenge: "Basic realm=\"x\"")),
            .closeConnection(.graceful),
        ]
        for kind in kinds {
            #expect(try JSONDecoder().decode(ActionKind.self, from: JSONEncoder().encode(kind)) == kind)
        }
    }

    @Test func newKindsRoundTripInsideSchema4() throws {
        let rules = (newGoldens.map(\.0)).enumerated().map { index, kind in
            Rule(
                id: UUID(), name: "r\(index)", enabled: true, groupID: nil, order: index, conditions: ConditionGroup(),
                actions: [RuleAction(kind)], note: nil)
        }
        let configuration = RuleStorage.Configuration(snapshot: RuleSnapshot(revision: 7, rules: rules), assets: [])
        let encoded = try RuleStorage.encode(configuration)
        #expect(configuration.schemaVersion == 4)
        guard case .current(let decoded) = try RuleStorage.read(encoded, limits: RulesLimits()) else {
            Issue.record("expected a current schema file")
            return
        }
        #expect(decoded == configuration)
        #expect(decoded.schemaVersion == 4)
        #expect(decoded.rules.flatMap(\.actions).map(\.kind) == newGoldens.map(\.0))
    }

    @Test func derivedPropertiesOfNewKinds() {
        let kinds = newGoldens.map(\.0)
        for kind in kinds {
            if case .editCookies = kind {
                #expect(kind.direction == .response)
            } else if kind.runsAtResponsePoint {
                // Delay, manual and predefined responses and close work at either point (R8F2 final review).
                #expect(kind.direction == nil, "\(kind)")
            } else {
                #expect(kind.direction == .request, "\(kind)")
            }
        }
        #expect(ActionKind.editCookies(direction: .request, operations: []).direction == .request)

        let isFinal = kinds.filter(\.isIntrinsicallyFinal)
        #expect(
            isFinal == [
                .returnHandwritten(HandwrittenResponse(text: "HTTP/1.1 200 OK")),
                .returnPreset(PresetResponse(preset: .found302, location: "https://a.test/")),
                .closeConnection(.reset), .returnConnectTunnel, .noDecrypt,
            ])
        #expect(kinds.filter(\.isConnectOnly) == [.returnConnectTunnel, .noDecrypt])
        #expect(kinds.filter(\.isAnnotation).isEmpty)

        let annotations: [ActionKind] = [.mark(MarkAction(background: "#FF3B30")), .comment(CommentAction(text: "x")), .hide]
        for kind in annotations { #expect(kind.canRunAtConnect) }
        #expect(ActionKind.closeConnection(.graceful).canRunAtConnect)
        #expect(ActionKind.noDecrypt.canRunAtConnect && ActionKind.returnConnectTunnel.canRunAtConnect)
        #expect(!ActionKind.modifyURL(URLEditAction(mode: .set)).canRunAtConnect)
        #expect(!ActionKind.delay(milliseconds: 1).canRunAtConnect)
        #expect(!ActionKind.mapRemote(MapRemoteAction(targetScheme: "https", targetHost: "a", targetPort: 1, path: .preserve)).canRunAtConnect)
        // Nothing R1…R3 ships is connect-only.
        #expect(existingGoldens.allSatisfy { !$0.0.isConnectOnly })
    }

    @Test func limitsAndOutcomeCodes() {
        let limits = RulesLimits()
        #expect(limits.handwrittenResponseBytes == 65_536)
        #expect(limits.delayMillisecondsMax == 60_000)
        #expect(RuleOutcomeCode.skippedByTool.rawValue == "skippedByTool")
        #expect(RuleOutcomeCode.delayCapped.rawValue == "delayCapped")
        #expect(RequestRuleDecision(
            effectiveHead: .request(HTTPMessageTarget(scheme: "https", host: "a", port: 443, method: "GET", pathAndQuery: "/"), headers: []),
            route: .original, breakpoint: nil,
            matches: RuleMatchSummary(revision: 1, ruleIDs: [], total: 0)).delayMilliseconds == 0)
    }
}

// MARK: Rules 2.0 R5: header edit methods

@Suite struct HeaderEditCodableR5Tests {
    private static let newEdits: [HeaderEdit] = [
        .addIfMissing(name: "A", value: "1"), .appendToValue(name: "B", text: ",2"),
        .findReplace(name: "C", find: "x", replacement: "y", caseSensitive: false),
        .regex(name: "D", pattern: "x+", replacement: "y", caseSensitive: true),
    ]

    @Test func newHeaderEditsRoundTripInsideSchema4() throws {
        let kind = ActionKind.editHeaders(direction: .response, operations: Self.newEdits)
        #expect(try JSONDecoder().decode(ActionKind.self, from: JSONEncoder().encode(kind)) == kind)
        let rule = Rule(
            id: UUID(), name: "h", enabled: true, groupID: nil, order: 0, conditions: ConditionGroup(),
            actions: [RuleAction(kind)], note: nil)
        let configuration = RuleStorage.Configuration(snapshot: RuleSnapshot(revision: 7, rules: [rule]), assets: [])
        guard case .current(let decoded) = try RuleStorage.read(try RuleStorage.encode(configuration), limits: RulesLimits())
        else {
            Issue.record("expected a current schema file")
            return
        }
        #expect(decoded == configuration)
        for edit in Self.newEdits {
            #expect(try JSONDecoder().decode(HeaderEdit.self, from: JSONEncoder().encode(edit)) == edit)
        }
    }

    @Test func oldHeaderEditShapesAreUnchanged() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func text(_ edit: HeaderEdit) throws -> String { String(decoding: try encoder.encode(edit), as: UTF8.self) }
        #expect(try text(.set(name: "A", value: "b")) == #"{"set":{"name":"A","value":"b"}}"#)
        #expect(try text(.append(name: "A", value: "b")) == #"{"append":{"name":"A","value":"b"}}"#)
        #expect(try text(.remove(name: "C")) == #"{"remove":{"name":"C"}}"#)
    }

    @Test func accessorsCoverTheNewCases() {
        #expect(Self.newEdits.map(\.name) == ["A", "B", "C", "D"])
        #expect(Self.newEdits.map(\.value) == ["1", ",2", "y", "y"])
    }
}

@Suite struct BodyRewriteCodableR5Tests {
    @Test func bodyRewriteRoundTripsWithOperation() throws {
        for operation in BodyRewriteOperation.allCases {
            let kind = ActionKind.rewriteBody(
                direction: .request, BodyRewriteAction(find: "f", replacement: "r", operation: operation))
            #expect(try JSONDecoder().decode(ActionKind.self, from: JSONEncoder().encode(kind)) == kind)
            let rule = Rule(
                id: UUID(), name: "b", enabled: true, groupID: nil, order: 0, conditions: ConditionGroup(),
                actions: [RuleAction(kind)], note: nil)
            let configuration = RuleStorage.Configuration(snapshot: RuleSnapshot(revision: 7, rules: [rule]), assets: [])
            guard case .current(let decoded) = try RuleStorage.read(try RuleStorage.encode(configuration), limits: RulesLimits())
            else {
                Issue.record("expected a current schema file")
                return
            }
            #expect(decoded == configuration)
        }
    }
}
