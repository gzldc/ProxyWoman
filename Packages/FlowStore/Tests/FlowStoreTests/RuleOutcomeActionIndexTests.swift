import Foundation
import Testing

@testable import FlowStore

private let ruleID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!

/// A code a later module defines (`finalStop` lives in RulesEngine); FlowStore only knows the text.
private let finalStop = RuleOutcomeCode(rawValue: "finalStop")!

@Suite("RuleOutcomeActionIndex")
struct RuleOutcomeActionIndexTests {
    @Test func actionIndexDecodesNilFromOldJSON() throws {
        let json = #"{"ruleID":"00000000-0000-0000-0000-0000000000A1","code":"applied"}"#
        let decoded = try JSONDecoder().decode(RuleOutcome.self, from: Data(json.utf8))
        #expect(decoded.actionIndex == nil)
        #expect(decoded == RuleOutcome(ruleID: ruleID, code: .applied))

        let summary =
            #"{"revision":3,"ruleIDs":["00000000-0000-0000-0000-0000000000A1"],"total":1,"omitted":0,"#
            + #""outcomes":[{"ruleID":"00000000-0000-0000-0000-0000000000A1","code":"rejected"}]}"#
        let decodedSummary = try JSONDecoder().decode(RuleMatchSummary.self, from: Data(summary.utf8))
        #expect(decodedSummary.outcomes == [RuleOutcome(ruleID: ruleID, code: .rejected, actionIndex: nil)])
    }

    @Test func actionIndexRoundTrips() throws {
        for index in [0, 1, 15] {
            let value = RuleOutcome(ruleID: ruleID, code: finalStop, actionIndex: index)
            let decoded = try JSONDecoder().decode(RuleOutcome.self, from: JSONEncoder().encode(value))
            #expect(decoded == value)
            #expect(decoded.actionIndex == index)
        }
        let summary = RuleMatchSummary(
            revision: 9, ruleIDs: [ruleID], total: 1,
            outcomes: [
                RuleOutcome(ruleID: ruleID, code: .applied, actionIndex: 1),
                RuleOutcome(ruleID: ruleID, code: finalStop, actionIndex: 1),
            ])
        #expect(try JSONDecoder().decode(RuleMatchSummary.self, from: JSONEncoder().encode(summary)) == summary)
    }

    @Test func nilActionIndexIsNotEncoded() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let plain = String(decoding: try encoder.encode(RuleOutcome(ruleID: ruleID, code: .rejected)), as: UTF8.self)
        #expect(!plain.contains("actionIndex"))
        #expect(plain == #"{"code":"rejected","ruleID":"00000000-0000-0000-0000-0000000000A1"}"#)
        let indexed = String(
            decoding: try encoder.encode(RuleOutcome(ruleID: ruleID, code: .rejected, actionIndex: 0)), as: UTF8.self)
        #expect(indexed == #"{"actionIndex":0,"code":"rejected","ruleID":"00000000-0000-0000-0000-0000000000A1"}"#)
    }

    @Test func equalityIncludesActionIndex() {
        let none = RuleOutcome(ruleID: ruleID, code: .applied)
        let first = RuleOutcome(ruleID: ruleID, code: .applied, actionIndex: 0)
        let second = RuleOutcome(ruleID: ruleID, code: .applied, actionIndex: 1)
        #expect(none != first)
        #expect(first != second)
        #expect(first == RuleOutcome(ruleID: ruleID, code: .applied, actionIndex: 0))
        #expect(Set([none, first, second, first]).count == 3)
    }

    @Test func harOutcomesStayRuleIDAndCode() throws {
        var flow = Flow(id: 1, scheme: "https", method: "GET", host: "example.com", port: 443, path: "/")
        flow.provenance = FlowProvenance(
            ruleMatches: RuleMatchSummary(
                revision: 2, ruleIDs: [ruleID], total: 1,
                outcomes: [
                    RuleOutcome(ruleID: ruleID, code: .applied, actionIndex: 1),
                    RuleOutcome(ruleID: ruleID, code: finalStop, actionIndex: 1),
                ]),
            rulesModified: true)
        let data = try HARExporter.export([flow], creatorName: "Test", creatorVersion: "1")
        #expect(!String(decoding: data, as: UTF8.self).contains("actionIndex"))

        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entry = try #require(((root["log"] as? [String: Any])?["entries"] as? [[String: Any]])?.first)
        let provenance = try #require((entry["_proxywoman"] as? [String: Any])?["provenance"] as? [String: Any])
        let outcomes = try #require(provenance["ruleOutcomes"] as? [[String: String]])
        #expect(
            outcomes == [
                ["ruleID": ruleID.uuidString, "code": "applied"],
                ["ruleID": ruleID.uuidString, "code": "finalStop"],
            ])
    }

    @Test func provenanceRulesModifiedDefaultsFalse() {
        #expect(FlowProvenance().rulesModified == false)
        #expect(FlowProvenance.passive.rulesModified == false)
        #expect(FlowProvenance.unknown.rulesModified == false)
        let modified = FlowProvenance(rulesModified: true)
        #expect(modified.rulesModified)
        #expect(modified != .passive)
        var changed = FlowProvenance.passive
        changed.rulesModified = true
        #expect(changed == modified)
    }
}
