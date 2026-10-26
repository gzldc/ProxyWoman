import FlowStore
import Foundation
import Testing

@testable import RulesEngine

private func id(_ n: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
}

private let anyAction = RuleAction(.rewriteStatus(RewriteStatusAction(status: 500)))

private func rule(_ n: Int, order: Int, group: UUID? = nil, enabled: Bool = true) -> Rule {
    Rule(id: id(n), name: "r\(n)", enabled: enabled, groupID: group, order: order, actions: [anyAction])
}

private func group(_ n: Int, order: Int, parent: UUID? = nil, enabled: Bool = true) -> RuleGroup {
    RuleGroup(id: id(n), name: "g\(n)", enabled: enabled, parentID: parent, order: order)
}

private func sortedJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

private let sevenKinds: [ActionKind] = [
    .returnFile(MapLocalAction(assetID: id(900), status: 200, headers: [])),
    .returnDirectory(MapLocalDirectoryAction(bookmark: Data([1]), displayName: "dir"), pathPrefix: "/static/"),
    .mapRemote(MapRemoteAction(targetScheme: "https", targetHost: "b.test", targetPort: 443, path: .preserve)),
    .editHeaders(direction: .response, operations: [.set(name: "X-A", value: "1")]),
    .breakpoint(direction: .response, mode: .headers),
    .rewriteBody(direction: .response, BodyRewriteAction(find: "a", replacement: "b")),
    .rewriteStatus(RewriteStatusAction(status: 500)),
]

@Suite("Rules 2.0 model")
struct RuleModelTests {
    // MARK: Fields, operators, points

    @Test func fieldAndOperatorRawValuesArePinned() {
        #expect(
            ConditionField.allCases.prefix(7).map(\.rawValue)
                == ["allSessions", "scheme", "host", "port", "method", "pathAndQuery", "statusCode"])
        #expect(
            ConditionOperator.allCases.prefix(6).map(\.rawValue)
                == ["equals", "startsWith", "inRange", "hostPattern", "wildcard", "regexWhole"])
        #expect(ConditionGroup.Mode.allCases.map(\.rawValue) == ["all", "any", "none"])
    }

    @Test func newFieldsEncodeAsTheirNames() throws {
        let row = ConditionRow(field: .requestHeader, name: "X-A", op: .notContains, value: "v")
        let json = String(decoding: try JSONEncoder().encode(row), as: UTF8.self)
        #expect(json.contains("\"requestHeader\""))
        #expect(json.contains("\"notContains\""))
        for field in ConditionField.allCases {
            let data = try JSONEncoder().encode(ConditionRow(field: field, op: .equals))
            #expect(try JSONDecoder().decode(ConditionRow.self, from: data).field == field)
        }
        for op in ConditionOperator.allCases {
            let data = try JSONEncoder().encode(ConditionRow(field: .url, op: op))
            #expect(try JSONDecoder().decode(ConditionRow.self, from: data).op == op)
        }
    }

    @Test func unknownFieldRawValueFailsToDecode() {
        let json = Data(#"{"field":"nope","op":"equals","value":"","caseSensitive":false}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ConditionRow.self, from: json) }
        let op = Data(#"{"field":"url","op":"nope","value":"","caseSensitive":false}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ConditionRow.self, from: op) }
    }

    @Test func ruleWithNewFieldsRoundTrips() throws {
        let rule = Rule(
            name: "slow",
            conditions: ConditionGroup(
                mode: .any,
                rows: [
                    ConditionRow(field: .durationMs, op: .greaterThan, value: "1000"),
                    ConditionRow(field: .requestHeader, name: "X-A", op: .regex, value: "a.*", caseSensitive: true),
                    ConditionRow(field: .requestDate, op: .inRange, value: "2026-10-01..2026-10-31"),
                ]),
            actions: [RuleAction(.hide)])
        let data = try JSONEncoder().encode(rule)
        #expect(try JSONDecoder().decode(Rule.self, from: data) == rule)
    }

    @Test func knowablePointsFollowTheSpecTable() {
        #expect(ConditionField.allSessions.knowablePoint == .connect)
        #expect(ConditionField.scheme.knowablePoint == .connect)
        #expect(ConditionField.host.knowablePoint == .connect)
        #expect(ConditionField.port.knowablePoint == .connect)
        #expect(ConditionField.method.knowablePoint == .connect)
        #expect(ConditionField.pathAndQuery.knowablePoint == .request)
        #expect(ConditionField.statusCode.knowablePoint == .response)
        #expect(EvaluationPoint.connect < .request)
        #expect(EvaluationPoint.request < .response)
        #expect(EvaluationPoint.response < .completion)
        #expect(!(EvaluationPoint.response < .request))
    }

    // MARK: Codable shapes

    @Test func groupRoundTripsThroughSortedJSON() throws {
        let group = ConditionGroup(
            mode: .any, occurrence: .times(2...3),
            rows: [ConditionRow(field: .host, op: .hostPattern, value: "*.a.test")])
        let text = try sortedJSON(group)
        #expect(
            text
                == #"{"mode":"any","occurrence":{"times":{"_0":[2,3]}},"rows":[{"caseSensitive":false,"field":"host","op":"hostPattern","value":"*.a.test"}]}"#
        )
        #expect(try JSONDecoder().decode(ConditionGroup.self, from: Data(text.utf8)) == group)
    }

    @Test func occurrenceAnyAndDefaultsEncodeAsPinned() throws {
        #expect(try sortedJSON(ConditionGroup()) == #"{"mode":"all","occurrence":{"any":{}},"rows":[]}"#)
        let row = ConditionRow(field: .method, name: "n", op: .equals, value: "GET", caseSensitive: true)
        #expect(
            try sortedJSON(row)
                == #"{"caseSensitive":true,"field":"method","name":"n","op":"equals","value":"GET"}"#)
    }

    @Test func actionKindJSONShapeIsPinned() throws {
        let kind = ActionKind.rewriteStatus(RewriteStatusAction(status: 500))
        let text = try sortedJSON(kind)
        #expect(text == #"{"rewriteStatus":{"_0":{"includeLocalResponses":false,"status":500}}}"#)
        #expect(try JSONDecoder().decode(ActionKind.self, from: Data(text.utf8)) == kind)
    }

    /// The stored form of every action kind is part of `rules.json`: a changed key or shape would make a
    /// file written by this version unreadable by the next. Pinned exactly, with non-default values so a
    /// dropped field shows.
    @Test func everyActionKindJSONShapeIsPinned() throws {
        let directory = ActionKind.returnDirectory(
            MapLocalDirectoryAction(
                bookmark: Data([1, 2, 3]), displayName: "dir", servesIndex: false, missing: .network,
                headers: [HeaderField(name: "X-A", value: "1")]),
            pathPrefix: "/static/")
        let expectedDirectory =
            #"{"returnDirectory":{"_0":{"bookmark":"AQID","displayName":"dir","headers":[{"name":"X-A","value":"1"}],"missing":"network","servesIndex":false},"pathPrefix":"\/static\/"}}"#
        let mapRemote = ActionKind.mapRemote(
            MapRemoteAction(
                targetScheme: "https", targetHost: "b.test", targetPort: 8443, path: .replace("/v2"),
                preserveCredentials: true))
        let expectedMapRemote =
            #"{"mapRemote":{"_0":{"path":{"replace":{"_0":"\/v2"}},"preserveCredentials":true,"targetHost":"b.test","targetPort":8443,"targetScheme":"https"}}}"#
        let preserving = ActionKind.mapRemote(
            MapRemoteAction(targetScheme: "http", targetHost: "c.test", targetPort: 80, path: .preserve))
        let expectedPreserving =
            #"{"mapRemote":{"_0":{"path":{"preserve":{}},"preserveCredentials":false,"targetHost":"c.test","targetPort":80,"targetScheme":"http"}}}"#
        let breakpoint = ActionKind.breakpoint(direction: .response, mode: .fullBody)
        let expectedBreakpoint = #"{"breakpoint":{"direction":"response","mode":"fullBody"}}"#
        // Two values: the direction keeps its label, the body search is the unlabeled second one.
        let rewrite = ActionKind.rewriteBody(
            direction: .request,
            BodyRewriteAction(find: "a.*", replacement: "$1", syntax: .regex, caseSensitive: false, scope: .first))
        let expectedRewrite =
            #"{"rewriteBody":{"_1":{"caseSensitive":false,"find":"a.*","replacement":"$1","scope":"first","syntax":"regex"},"direction":"request"}}"#
        let returnFile = ActionKind.returnFile(
            MapLocalAction(assetID: id(900), status: 201, headers: [HeaderField(name: "X-B", value: "2")]))
        let expectedReturnFile =
            #"{"returnFile":{"_0":{"assetID":"00000000-0000-0000-0000-000000000900","headers":[{"name":"X-B","value":"2"}],"status":201}}}"#
        let headers = ActionKind.editHeaders(direction: .request, operations: [.set(name: "X-A", value: "1")])
        let expectedHeaders =
            #"{"editHeaders":{"direction":"request","operations":[{"set":{"name":"X-A","value":"1"}}]}}"#

        for (kind, expected) in [
            (directory, expectedDirectory), (mapRemote, expectedMapRemote), (preserving, expectedPreserving),
            (breakpoint, expectedBreakpoint), (rewrite, expectedRewrite), (returnFile, expectedReturnFile),
            (headers, expectedHeaders),
        ] {
            let text = try sortedJSON(kind)
            #expect(text == expected)
            #expect(try JSONDecoder().decode(ActionKind.self, from: Data(text.utf8)) == kind)
        }
    }

    @Test func ruleActionJSONShapeIsKindAndIsFinal() throws {
        let action = RuleAction(.breakpoint(direction: .request, mode: .headers), isFinal: true)
        let text = try sortedJSON(action)
        #expect(text == #"{"isFinal":true,"kind":{"breakpoint":{"direction":"request","mode":"headers"}}}"#)
        #expect(try JSONDecoder().decode(RuleAction.self, from: Data(text.utf8)) == action)
        #expect(
            try sortedJSON(RuleAction(.rewriteStatus(RewriteStatusAction(status: 404))))
                == #"{"isFinal":false,"kind":{"rewriteStatus":{"_0":{"includeLocalResponses":false,"status":404}}}}"#)
    }

    @Test func groupAndRuleJSONShapesArePinned() throws {
        let group = RuleGroup(id: id(10), name: "g", enabled: false, parentID: id(9), order: 2)
        let groupText = try sortedJSON(group)
        #expect(
            groupText
                == #"{"enabled":false,"id":"00000000-0000-0000-0000-000000000010","name":"g","order":2,"parentID":"00000000-0000-0000-0000-000000000009"}"#
        )
        #expect(try JSONDecoder().decode(RuleGroup.self, from: Data(groupText.utf8)) == group)

        let rule = Rule(
            id: id(1), name: "a", enabled: false, groupID: id(10), order: 4,
            conditions: ConditionGroup(mode: .none, occurrence: .times(2...3), rows: [
                ConditionRow(field: .statusCode, op: .inRange, value: "400-499")
            ]),
            actions: [RuleAction(.rewriteStatus(RewriteStatusAction(status: 500)), isFinal: true)], note: "n")
        let ruleText = try sortedJSON(rule)
        #expect(
            ruleText
                == #"{"actions":[{"isFinal":true,"kind":{"rewriteStatus":{"_0":{"includeLocalResponses":false,"status":500}}}}],"conditions":{"mode":"none","occurrence":{"times":{"_0":[2,3]}},"rows":[{"caseSensitive":false,"field":"statusCode","op":"inRange","value":"400-499"}]},"enabled":false,"groupID":"00000000-0000-0000-0000-000000000010","id":"00000000-0000-0000-0000-000000000001","name":"a","note":"n","order":4}"#
        )
        #expect(try JSONDecoder().decode(Rule.self, from: Data(ruleText.utf8)) == rule)

        // The snapshot carries a non-empty group list in the same shape, beside the cache-free fields.
        let snapshot = RuleSnapshot(revision: 9, groups: [group], rules: [])
        #expect(
            try sortedJSON(snapshot)
                == #"{"groups":[{"enabled":false,"id":"00000000-0000-0000-0000-000000000010","name":"g","order":2,"parentID":"00000000-0000-0000-0000-000000000009"}],"revision":9,"rules":[],"schemaVersion":4,"templatesInstalled":false}"#
        )
    }

    @Test func everyKindRoundTrips() throws {
        for kind in sevenKinds {
            let action = RuleAction(kind, isFinal: true)
            let data = try JSONEncoder().encode(action)
            #expect(try JSONDecoder().decode(RuleAction.self, from: data) == action)
        }
    }

    @Test func ruleGroupAndSnapshotRoundTrip() throws {
        let noticePair = MigrationPair(changeClass: .finalAction, higherRuleID: id(1), lowerRuleID: id(2))
        let notice = MigrationNotice(
            report: MigrationReport(pairs: [noticePair]), migratedFromSchema: 3, acknowledged: false)
        let rules = [
            Rule(
                id: id(1), name: "a", enabled: true, groupID: id(10), order: 4,
                conditions: ConditionGroup(
                    mode: .none, occurrence: .times(1...1),
                    rows: [
                        ConditionRow(field: .statusCode, op: .inRange, value: "400-499")
                    ]),
                actions: [RuleAction(sevenKinds[3]), RuleAction(sevenKinds[0], isFinal: false)], note: "n")
        ]
        let snapshot = RuleSnapshot(
            revision: 9, groups: [group(10, order: 0)], rules: rules, templatesInstalled: true,
            migrationNotice: notice)
        let data = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(RuleSnapshot.self, from: data) == snapshot)
        #expect(snapshot.schemaVersion == 4)
    }

    @Test func absentOptionalFieldsAreOmittedFromJSON() throws {
        let plain = Rule(id: id(1), name: "p", actions: [anyAction])
        let text = try sortedJSON(plain)
        #expect(!text.contains("groupID"))
        #expect(!text.contains("note"))
        #expect(!(try sortedJSON(RuleGroup(id: id(2), name: "g"))).contains("parentID"))
    }

    // MARK: Actions

    @Test func intrinsicFinalKindsAreTheTwoReturnKinds() {
        let finals = sevenKinds.map(\.isIntrinsicallyFinal)
        #expect(finals == [true, true, false, false, false, false, false])
        let ticked = RuleAction(.rewriteStatus(RewriteStatusAction(status: 500)), isFinal: true)
        #expect(ticked.isFinalEffective)
        #expect(!anyAction.isFinalEffective)
        #expect(RuleAction(sevenKinds[0]).isFinalEffective)
        #expect(RuleAction(sevenKinds[1], isFinal: false).isFinalEffective)
    }

    @Test func directionOfEveryKind() {
        #expect(
            sevenKinds.map(\.direction) == [nil, .request, .request, .response, .response, .response, .response])
        // Return File works at either point (a rule judged at the response answers there), so it has no side.
        #expect(ActionKind.editHeaders(direction: .request, operations: []).direction == .request)
        #expect(ActionKind.breakpoint(direction: .request, mode: .fullBody).direction == .request)
        #expect(
            ActionKind.rewriteBody(direction: .request, BodyRewriteAction(find: "a", replacement: "b")).direction
                == .request)
    }

    // MARK: Evaluation order

    private func orderedIDs(_ snapshot: RuleSnapshot) -> [UUID] { snapshot.evaluationOrder.map(\.id) }

    @Test func evaluationOrderIsDepthFirstByOrderThenPosition() {
        let g1 = group(101, order: 1)
        let r0 = rule(0, order: 0)
        let r1 = rule(1, order: 0, group: g1.id)
        let r2 = rule(2, order: 1, group: g1.id)
        let r3 = rule(3, order: 2)
        // Stored out of order on purpose: the order numbers, not the array, decide.
        let snapshot = RuleSnapshot(revision: 1, groups: [g1], rules: [r3, r2, r0, r1])
        #expect(orderedIDs(snapshot) == [r0.id, r1.id, r2.id, r3.id])
    }

    @Test func rulesAndGroupsShareOneOrderSpace() {
        let g = group(101, order: 1)
        let inside = rule(1, order: 0, group: g.id)
        let sibling = rule(2, order: 1)
        // Equal order: the rule comes before the group, whatever the array positions are.
        #expect(
            orderedIDs(RuleSnapshot(revision: 1, groups: [g], rules: [inside, sibling]))
                == [sibling.id, inside.id])
        // A lower group order puts the whole group first.
        let early = group(102, order: 0)
        let inEarly = rule(3, order: 5, group: early.id)
        #expect(
            orderedIDs(RuleSnapshot(revision: 1, groups: [early], rules: [sibling, inEarly]))
                == [inEarly.id, sibling.id])
    }

    @Test func equalOrderKeepsArrayPosition() {
        let a = rule(1, order: 0)
        let b = rule(2, order: 0)
        let c = rule(3, order: 0)
        #expect(orderedIDs(RuleSnapshot(revision: 1, rules: [b, c, a])) == [b.id, c.id, a.id])
        let g1 = group(101, order: 7)
        let g2 = group(102, order: 7)
        let inG1 = rule(4, order: 0, group: g1.id)
        let inG2 = rule(5, order: 0, group: g2.id)
        #expect(
            orderedIDs(RuleSnapshot(revision: 1, groups: [g2, g1], rules: [inG1, inG2]))
                == [inG2.id, inG1.id])
    }

    @Test func disabledGroupSkipsItsWholeSubtree() {
        let g1 = group(101, order: 1, enabled: false)
        let g2 = group(102, order: 0, parent: g1.id)
        let direct = rule(1, order: 0, group: g1.id)
        let nested = rule(2, order: 0, group: g2.id)
        let outside = rule(3, order: 2)
        let snapshot = RuleSnapshot(revision: 1, groups: [g1, g2], rules: [direct, nested, outside])
        #expect(orderedIDs(snapshot) == [outside.id])
    }

    @Test func disabledRuleNeverAppears() {
        let g = group(101, order: 0)
        let off = rule(1, order: 0, enabled: false)
        let offInGroup = rule(2, order: 0, group: g.id, enabled: false)
        let on = rule(3, order: 1)
        #expect(orderedIDs(RuleSnapshot(revision: 1, groups: [g], rules: [off, offInGroup, on])) == [on.id])
    }

    @Test func nestedGroupsAreWalkedDepthFirst() {
        let outer = group(101, order: 0)
        let inner = group(102, order: 1, parent: outer.id)
        let a = rule(1, order: 0, group: outer.id)
        let b = rule(2, order: 0, group: inner.id)
        let c = rule(3, order: 2, group: outer.id)
        let d = rule(4, order: 1)
        let snapshot = RuleSnapshot(revision: 1, groups: [inner, outer], rules: [d, c, b, a])
        #expect(orderedIDs(snapshot) == [a.id, b.id, c.id, d.id])
    }

    @Test func badDataNeitherLoopsNorRepeatsRules() {
        // A parent cycle and a self-parent are unreachable from the root; a duplicated group id
        // must not list its rules twice.
        let loopA = group(101, order: 0, parent: id(102))
        let loopB = group(102, order: 0, parent: id(101))
        let selfParent = group(103, order: 0, parent: id(103))
        let twinA = group(104, order: 0)
        let twinB = group(104, order: 1)
        let unreachable = rule(1, order: 0, group: loopA.id)
        let alsoUnreachable = rule(2, order: 0, group: selfParent.id)
        let orphan = rule(3, order: 0, group: id(999))
        let once = rule(4, order: 0, group: twinA.id)
        let snapshot = RuleSnapshot(
            revision: 1, groups: [loopA, loopB, selfParent, twinA, twinB],
            rules: [unreachable, alsoUnreachable, orphan, once])
        #expect(orderedIDs(snapshot) == [once.id])
    }

    /// A group id listed twice can close a loop that is reachable from the root: group 101 holds group
    /// 102, which holds another group that also has the id 101. Entering an id once ends the walk and
    /// lists each rule once.
    @Test func aCycleReachableThroughADuplicatedGroupIDEndsAndListsEachRuleOnce() {
        let outer = group(101, order: 0)
        let inner = group(102, order: 0, parent: outer.id)
        let again = group(101, order: 0, parent: inner.id)
        let inOuter = rule(1, order: 1, group: outer.id)
        let inInner = rule(2, order: 1, group: inner.id)
        let snapshot = RuleSnapshot(revision: 1, groups: [outer, inner, again], rules: [inOuter, inInner])
        #expect(orderedIDs(snapshot) == [inInner.id, inOuter.id])
        // Listing the duplicate first changes nothing: the walk starts from the root, not from the array.
        let reordered = RuleSnapshot(revision: 1, groups: [again, inner, outer], rules: [inOuter, inInner])
        #expect(orderedIDs(reordered) == [inInner.id, inOuter.id])
    }

    // MARK: Snapshot and limits

    @Test func snapshotIsSchema4() {
        let snapshot = RuleSnapshot(revision: 3, rules: [])
        #expect(snapshot.schemaVersion == 4)
        #expect(snapshot.revision == 3)
        #expect(snapshot.groups.isEmpty)
        #expect(!snapshot.templatesInstalled)
        #expect(snapshot.migrationNotice == nil)
        #expect(snapshot.evaluationOrder.isEmpty)
    }

    @Test func migrationReportIsEmptyOnlyWithoutPairs() {
        #expect(MigrationReport(pairs: []).isEmpty)
        let pair = MigrationPair(changeClass: .sequentialRewrite, higherRuleID: id(1), lowerRuleID: id(2))
        #expect(!MigrationReport(pairs: [pair]).isEmpty)
        #expect(
            [MigrationChangeClass.finalAction, .laterSeesEarlier, .sequentialRewrite].map(\.rawValue) == [1, 2, 3])
    }

    @Test func limitsDefaultsMatchTheSpecTable() {
        let limits = RulesLimits()
        #expect(limits.ruleActions == 16)
        #expect(limits.ruleConditionRows == 32)
        #expect(limits.ruleCount == 500)
        #expect(limits.groupDepth == 3)
        // The existing defaults do not move.
        #expect(limits.configBytes == 8_388_608)
        #expect(limits.fieldBytes == 8_192)
        #expect(limits.recordedMatches == 256)
        #expect(limits.headerBytes == 65_536)
        #expect(limits.headerFields == 256)
        #expect(limits.rewriteBodyBytes == 8_388_608)
        #expect(limits.rewriteSeconds == 30)
        #expect(limits.rewriteTotalSeconds == 600)
        let shrunk = RulesLimits(ruleActions: 2, ruleConditionRows: 3, ruleCount: 4, groupDepth: 1)
        #expect(shrunk.ruleActions == 2 && shrunk.ruleConditionRows == 3)
        #expect(shrunk.ruleCount == 4 && shrunk.groupDepth == 1)
    }

    // MARK: Annotation actions

    @Test func annotationKindsEncodeToPinnedJSON() throws {
        let full = ActionKind.mark(MarkAction(background: "#FF3B30", foreground: "#FFFFFF", text: "slow"))
        #expect(
            try sortedJSON(full)
                == ##"{"mark":{"_0":{"background":"#FF3B30","foreground":"#FFFFFF","text":"slow"}}}"##)
        let bare = ActionKind.mark(MarkAction(background: "#FF3B30"))
        #expect(try sortedJSON(bare) == ##"{"mark":{"_0":{"background":"#FF3B30"}}}"##)
        let comment = ActionKind.comment(CommentAction(mode: .append, text: "x"))
        #expect(
            try sortedJSON(comment) == #"{"comment":{"_0":{"mode":"append","replacement":"","text":"x"}}}"#)
        #expect(try sortedJSON(ActionKind.hide) == #"{"hide":{}}"#)
        for kind in [full, bare, comment, ActionKind.hide] {
            let text = try sortedJSON(kind)
            #expect(try JSONDecoder().decode(ActionKind.self, from: Data(text.utf8)) == kind)
        }
    }

    @Test func hideIsIntrinsicallyFinalAndTheThreeHaveNoDirection() {
        let mark = ActionKind.mark(MarkAction(background: "#FF3B30"))
        let comment = ActionKind.comment(CommentAction(text: "x"))
        #expect(ActionKind.hide.isIntrinsicallyFinal)
        #expect(!mark.isIntrinsicallyFinal)
        #expect(!comment.isIntrinsicallyFinal)
        for kind in [mark, comment, ActionKind.hide] {
            #expect(kind.direction == nil)
            #expect(kind.isAnnotation)
        }
        #expect(RuleAction(mark, isFinal: true).isFinalEffective)
        #expect(!RuleAction(mark).isFinalEffective)
    }

    @Test func existingKindsKeepTheirDirections() {
        for kind in sevenKinds {
            #expect(!kind.isAnnotation)
            switch kind {
            case .returnFile: #expect(kind.direction == nil)  // Either point (R8F2 final review).
            case .returnDirectory, .mapRemote: #expect(kind.direction == .request)
            case .rewriteStatus: #expect(kind.direction == .response)
            case .editHeaders(let direction, _), .breakpoint(let direction, _), .rewriteBody(let direction, _):
                #expect(kind.direction == direction)
            case .mark, .comment, .hide, .modifyURL, .modifyQuery, .editCookies, .delay, .returnHandwritten,
                .returnPreset, .closeConnection, .returnConnectTunnel, .noDecrypt, .magicString:
                Issue.record("not an existing kind")
            }
        }
    }

    @Test func snapshotReportsWhetherARequestPointRuleCanHide() {
        func hider(_ n: Int, rows: [ConditionRow] = [], enabled: Bool = true, group: UUID? = nil) -> Rule {
            Rule(
                id: id(n), name: "h\(n)", enabled: enabled, groupID: group,
                conditions: ConditionGroup(rows: rows), actions: [RuleAction(.hide)])
        }
        let statusRow = ConditionRow(field: .statusCode, op: .inRange, value: "404-404")
        let hostRow = ConditionRow(field: .host, op: .hostPattern, value: "a.test")
        #expect(!RuleSnapshot(revision: 1, rules: []).canHideAtRequestPoint)
        #expect(RuleSnapshot(revision: 1, rules: [hider(1, rows: [hostRow])]).canHideAtRequestPoint)
        #expect(!RuleSnapshot(revision: 1, rules: [hider(1, rows: [hostRow, statusRow])]).canHideAtRequestPoint)
        #expect(!RuleSnapshot(revision: 1, rules: [hider(1, enabled: false)]).canHideAtRequestPoint)
        let off = RuleGroup(id: id(50), name: "g", enabled: false)
        #expect(!RuleSnapshot(revision: 1, groups: [off], rules: [hider(1, group: id(50))]).canHideAtRequestPoint)
        let markOnly = Rule(id: id(2), name: "m", actions: [RuleAction(.mark(MarkAction(background: "#FF3B30")))])
        #expect(!RuleSnapshot(revision: 1, rules: [markOnly]).canHideAtRequestPoint)
        #expect(RuleSnapshot(revision: 1, rules: [markOnly, hider(3)]).canHideAtRequestPoint)
    }
}
