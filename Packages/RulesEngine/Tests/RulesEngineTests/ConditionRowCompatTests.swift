import FlowStore
import Foundation
import Testing

@testable import RulesEngine

/// `ConditionRow` as it was before `nameCaseSensitive`: the synthesized Codable of the old declaration.
private struct OldConditionRow: Codable {
    var field: ConditionField
    var name: String?
    var op: ConditionOperator
    var value: String
    var caseSensitive: Bool
}

@Suite("ConditionRowCompat")
struct ConditionRowCompatTests {
    private func encode(_ row: ConditionRow) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return String(decoding: try encoder.encode(row), as: UTF8.self)
    }

    @Test func oldJSONWithoutTheKeyDecodesAndRoundTripsByteForByte() throws {
        let shapes = [
            #"{"caseSensitive":false,"field":"requestHeader","name":"Accept","op":"contains","value":"json"}"#,
            #"{"caseSensitive":true,"field":"url","op":"equals","value":"http://a/"}"#,
            #"{"caseSensitive":false,"field":"statusCode","op":"inRange","value":"200-299"}"#,
            #"{"caseSensitive":false,"field":"sessionState","op":"equals","value":"completed"}"#,
            #"{"caseSensitive":false,"field":"clientHTTPVersion","op":"equals","value":"h2"}"#,
        ]
        for json in shapes {
            let row = try JSONDecoder().decode(ConditionRow.self, from: Data(json.utf8))
            #expect(row.nameCaseSensitive == nil)
            #expect(try encode(row) == json)
        }
    }

    @Test func encodingMatchesTheOldSynthesizedEncodingKeyForKey() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let old = OldConditionRow(field: .requestHeader, name: "A", op: .contains, value: "v", caseSensitive: true)
        let new = ConditionRow(field: .requestHeader, name: "A", op: .contains, value: "v", caseSensitive: true)
        #expect(try encoder.encode(new) == encoder.encode(old))
        let nameless = OldConditionRow(field: .url, name: nil, op: .equals, value: "", caseSensitive: false)
        #expect(try encoder.encode(ConditionRow(field: .url, op: .equals)) == encoder.encode(nameless))
        // Unsorted too: the key order is the declaration order, as for the old struct.
        let plain = JSONEncoder()
        #expect(try plain.encode(new).count == plain.encode(old).count)
    }

    @Test func theNewKeyIsWrittenOnlyWhenSet() throws {
        var row = ConditionRow(field: .requestCookie, name: "SID", op: .equals, value: "1")
        #expect(!(try encode(row)).contains("nameCaseSensitive"))
        row.nameCaseSensitive = true
        let json = try encode(row)
        #expect(json == #"{"caseSensitive":false,"field":"requestCookie","name":"SID","nameCaseSensitive":true,"op":"equals","value":"1"}"#)
        #expect(try JSONDecoder().decode(ConditionRow.self, from: Data(json.utf8)) == row)
        // An explicit "without case" is a setting too: it is kept, not folded back into the old behaviour.
        row.nameCaseSensitive = false
        let off = try encode(row)
        #expect(off.contains(#""nameCaseSensitive":false"#))
        #expect(try JSONDecoder().decode(ConditionRow.self, from: Data(off.utf8)).nameCaseSensitive == false)
    }

    /// Ruling R8F2-T1a: a row saved before the setting existed keeps what its field did then (header names without case,
    /// cookie names with it); only a row that says so is read the other way.
    @Test func aSavedRowWithoutTheSettingKeepsTheOldComparison() throws {
        func hit(_ json: String, headers: [HeaderField]) throws -> Bool {
            let row = try JSONDecoder().decode(ConditionRow.self, from: Data(json.utf8))
            let input = ConditionInput(
                target: HTTPMessageTarget(scheme: "https", host: "a.test", port: 443, method: "GET", pathAndQuery: "/"),
                requestHeaders: headers, response: (200, headers), facts: ExchangeFacts())
            return ConditionGroup(rows: [row]).evaluate(
                input, allowance: RegexAllowance(total: .seconds(100)), cache: PatternCache(budget: RegexBudget(clock: { .zero })))
                .result == .matched
        }
        let cookie = [HeaderField(name: "Cookie", value: "Sid=1"), HeaderField(name: "Set-Cookie", value: "Sid=1")]
        let oldCookie = #"{"caseSensitive":false,"field":"requestCookie","name":"sid","op":"equals","value":"1"}"#
        #expect(try hit(oldCookie, headers: cookie) == false)  // Old behaviour: the cookie name is exact.
        let oldSetCookie = #"{"caseSensitive":false,"field":"responseCookie","name":"sid","op":"equals","value":"1"}"#
        #expect(try hit(oldSetCookie, headers: cookie) == false)
        let withoutCase = #"{"caseSensitive":false,"field":"requestCookie","name":"sid","nameCaseSensitive":false,"op":"equals","value":"1"}"#
        #expect(try hit(withoutCase, headers: cookie))
        let exact = #"{"caseSensitive":false,"field":"requestCookie","name":"Sid","nameCaseSensitive":true,"op":"equals","value":"1"}"#
        #expect(try hit(exact, headers: cookie))
        // Headers never compared names with case.
        let oldHeader = #"{"caseSensitive":false,"field":"requestHeader","name":"COOKIE","op":"contains","value":"1"}"#
        #expect(try hit(oldHeader, headers: cookie))
        // The combined cookie field is new: it has no old behaviour, so it ignores case.
        #expect(ConditionRow(field: .cookie, name: "sid", op: .equals).effectiveNameCaseSensitive == false)
        #expect(ConditionRow(field: .requestCookie, name: "sid", op: .equals).effectiveNameCaseSensitive)
        #expect(ConditionRow(field: .requestHeader, name: "sid", op: .equals).effectiveNameCaseSensitive == false)
        #expect(ConditionRow(field: .requestCookie, name: "sid", op: .equals, nameCaseSensitive: false).effectiveNameCaseSensitive == false)
    }

    @Test func newFieldsAndOperatorsRoundTrip() throws {
        let rows = [
            ConditionRow(field: .cookie, op: .exists),
            ConditionRow(field: .tlsVersion, op: .contains, value: "1.3"),
            ConditionRow(field: .magicString, op: .contains, value: "EXACT:http://a/"),
            ConditionRow(field: .requestDate, op: .afterOrEqual, value: "2026-10-25"),
            ConditionRow(field: .requestHeader, name: "X", op: .doesNotExist, nameCaseSensitive: true),
        ]
        for row in rows {
            #expect(try JSONDecoder().decode(ConditionRow.self, from: Data(try encode(row).utf8)) == row)
        }
    }

    @Test func aRowOfEveryOldFieldStillValidates() {
        // A saved row of each old shape passes the same validation as before.
        let rows = [
            ConditionRow(field: .requestHeader, name: "Accept", op: .notEquals, value: "x"),
            ConditionRow(field: .requestCookie, name: "sid", op: .isNotEmpty),
            ConditionRow(field: .clientApp, name: "pid", op: .inRange, value: "1-10"),
            ConditionRow(field: .clientApp, name: "name", op: .contains, value: "Saf"),
            ConditionRow(field: .requestDate, op: .inRange, value: "2026-01-01..2026-02-01"),
            ConditionRow(field: .sessionState, op: .notEquals, value: "failed"),
            ConditionRow(field: .appProtocol, op: .notEquals, value: "grpc"),
            ConditionRow(field: .clientHTTPVersion, op: .notEquals, value: "h1"),
            ConditionRow(field: .statusCode, op: .startsWith, value: "2"),
        ]
        for row in rows {
            #expect(row.validationIssue(limits: RulesLimits()) == nil, "\(row)")
        }
    }
}
