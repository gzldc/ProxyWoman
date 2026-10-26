import Foundation
import Testing

@testable import RulesEngine

@Suite("FiddlerConditionOperators")
struct FiddlerConditionOperatorTests {
    private typealias Op = ConditionOperator

    private let text: [[Op]] = [
        [.equals, .notEquals], [.contains, .notContains], [.startsWith, .endsWith], [.isEmpty, .isNotEmpty], [.regex],
    ]
    private var keyValue: [[Op]] { Array(text[0..<4]) + [[.exists, .doesNotExist]] + [text[4]] }
    private let number: [[Op]] = [
        [.equals, .notEquals], [.greaterOrEqual, .greaterThan], [.lessOrEqual, .lessThan], [.isEmpty, .isNotEmpty],
        [.regex],
    ]
    private let date: [[Op]] = [
        [.equals, .notEquals], [.afterOrEqual, .after], [.beforeOrEqual, .before], [.isEmpty, .isNotEmpty],
    ]

    @Test func newRawValuesAreAppended() {
        let all = Op.allCases.map(\.rawValue)
        #expect(Array(all.suffix(4)) == ["exists", "doesNotExist", "afterOrEqual", "beforeOrEqual"])
        #expect(all.firstIndex(of: "after")! < all.firstIndex(of: "exists")!)
        let fields = ConditionField.allCases.map(\.rawValue)
        #expect(Array(fields.suffix(3)) == ["cookie", "tlsVersion", "magicString"])
        #expect(fields.firstIndex(of: "comment")! == fields.count - 4)
    }

    @Test func operatorSetsFollowTheSpecTable() {
        var table: [(ConditionField, String?, [[Op]])] = [
            (.allSessions, nil, []), (.magicString, nil, []),
            (.scheme, nil, [[.equals]]), (.appProtocol, nil, [[.equals]]), (.sessionState, nil, [[.equals]]),
            (.rulesModified, nil, [[.equals]]),
            (.requestDate, nil, date),
            (.clientApp, nil, text), (.clientApp, "pid", number),
        ]
        for field in [
            ConditionField.url, .host, .path, .method, .clientHTTPVersion, .upstreamHTTPVersion, .requestBody,
            .responseBody, .requestTime, .clientIP, .remoteIP, .clientTLSVersion, .upstreamTLSVersion, .tlsVersion,
            .comment,
        ] { table.append((field, nil, text)) }
        for field in [ConditionField.requestHeader, .responseHeader, .requestCookie, .responseCookie, .cookie] {
            table.append((field, nil, keyValue))
        }
        for field in [ConditionField.statusCode, .requestBodySize, .responseBodySize, .durationMs] {
            table.append((field, nil, number))
        }
        for (field, name, expected) in table {
            #expect(Op.fiddlerOperators(for: field, name: name) == expected, "\(field) \(name ?? "")")
        }
    }

    @Test func defaultsAreContainsForTextAndEqualsForTheRest() {
        for field in ConditionField.allCases {
            let sets = Op.fiddlerOperators(for: field, name: nil).flatMap { $0 }
            let expected: Op = sets.contains(.contains) || field == .magicString ? .contains : .equals
            #expect(Op.defaultOperator(for: field, name: nil) == expected, "\(field)")
            if !sets.isEmpty { #expect(sets.contains(Op.defaultOperator(for: field, name: nil)), "\(field)") }
        }
        #expect(Op.defaultOperator(for: .clientApp, name: "pid") == .equals)
    }

    @Test func allowedKeepsWhatSavedRowsUsed() {
        // Operators each field accepted before R8F2; they must stay accepted.
        let oldText: [Op] = [.equals, .notEquals, .contains, .notContains, .startsWith, .endsWith, .isEmpty, .isNotEmpty, .regex]
        let oldNumber: [Op] = [.equals, .notEquals, .greaterThan, .greaterOrEqual, .lessThan, .lessOrEqual, .inRange]
        let oldDate: [Op] = [.equals, .notEquals, .before, .after, .inRange]
        let oldFixed: [Op] = [.equals, .notEquals]
        var table: [(ConditionField, String?, [Op])] = [
            (.scheme, nil, oldFixed), (.appProtocol, nil, oldFixed), (.sessionState, nil, oldFixed),
            (.clientHTTPVersion, nil, oldFixed), (.upstreamHTTPVersion, nil, oldFixed),
            (.rulesModified, nil, oldFixed), (.requestDate, nil, oldDate), (.port, nil, oldNumber),
            (.statusCode, nil, oldNumber + [.contains, .startsWith, .regex]),
            (.clientApp, "pid", oldNumber), (.clientApp, "name", oldText), (.certificate, "subject", oldText),
        ]
        for field in [ConditionField.requestBodySize, .responseBodySize, .durationMs] { table.append((field, nil, oldNumber)) }
        for field in [
            ConditionField.url, .host, .path, .method, .queryString, .pathAndQuery, .queryParam, .requestHeader,
            .responseHeader, .requestCookie, .responseCookie, .requestBody, .responseBody, .requestTime,
            .clientTLSVersion, .upstreamTLSVersion, .clientIP, .remoteIP, .comment,
        ] { table.append((field, nil, oldText)) }
        for (field, name, old) in table {
            let allowed = Op.allowed(for: field, name: name)
            for op in old { #expect(allowed.contains(op), "\(field) \(op)") }
            #expect(Set(allowed).count == allowed.count, "\(field) has no duplicates")
        }
    }

    @Test func legacyClassification() {
        #expect(Op.isLegacyForField(.inRange, field: .requestBodySize, name: nil))
        #expect(Op.isLegacyForField(.inRange, field: .requestDate, name: nil))
        #expect(Op.isLegacyForField(.notEquals, field: .scheme, name: nil))
        #expect(Op.isLegacyForField(.contains, field: .statusCode, name: nil))
        #expect(!Op.isLegacyForField(.regex, field: .statusCode, name: nil))
        #expect(!Op.isLegacyForField(.contains, field: .url, name: nil))
        #expect(!Op.isLegacyForField(.exists, field: .requestHeader, name: nil))
        #expect(!Op.isLegacyForField(.exists, field: .url, name: nil))  // not allowed at all, so not "legacy"
        #expect(!Op.allowed(for: .url, name: nil).contains(.exists))
        #expect(Op.allowed(for: .requestHeader, name: nil).contains(.exists))
        #expect(Op.allowed(for: .allSessions, name: nil).isEmpty)
    }

    @Test func valueKindsFollowTheSpec() {
        #expect(ConditionField.clientHTTPVersion.valueKind(name: nil) == .text)
        #expect(ConditionField.upstreamHTTPVersion.valueKind(name: nil) == .text)
        #expect(ConditionField.appProtocol.valueKind(name: nil)
            == .choice(["http", "websocket", "rpc", "grpc", "sse", "socketio"]))
        #expect(ConditionField.sessionState.valueKind(name: nil) == .choice(["opened", "closed", "paused"]))
        #expect(ConditionField.scheme.valueKind(name: nil) == .choice(["https", "http"]))
        #expect(ConditionField.clientApp.valueKind(name: nil) == .text)
        #expect(ConditionField.clientApp.valueKind(name: "pid") == .number)
        #expect(ConditionField.cookie.valueKind(name: nil) == .text)
        #expect(ConditionField.tlsVersion.valueKind(name: nil) == .text)
        #expect(ConditionField.magicString.valueKind(name: nil) == .text)
        #expect(ConditionField.magicString.knowablePoint == .request)
        #expect(ConditionField.magicString.side == .both)
        #expect(ConditionField.cookie.side == .both)
        #expect(ConditionField.tlsVersion.side == .both)
    }

    @Test func sessionStateJudgmentPointFollowsTheValue() {
        func point(_ value: String) -> EvaluationPoint {
            ConditionRow(field: .sessionState, op: .equals, value: value).knowablePoint
        }
        #expect(point("opened") == .request)
        #expect(point("paused") == .request)
        #expect(point("closed") == .completion)
        for old in ["completed", "failed", "tunnel"] { #expect(point(old) == .completion) }
    }

    @Test func rowValidationAcceptsNewShapesAndOldValues() {
        func issue(_ row: ConditionRow) -> RuleValidationError? { row.validationIssue(limits: RulesLimits()) }
        // Empty header / cookie / process keys are fine now.
        for field in [ConditionField.requestHeader, .responseHeader, .requestCookie, .responseCookie, .cookie] {
            #expect(issue(ConditionRow(field: field, op: .exists)) == nil, "\(field)")
            #expect(issue(ConditionRow(field: field, name: "X", op: .doesNotExist)) == nil)
        }
        #expect(issue(ConditionRow(field: .clientApp, op: .contains, value: "Saf")) == nil)
        #expect(issue(ConditionRow(field: .queryParam, op: .equals, value: "1"))?.code == .conditionNameRequired)
        #expect(issue(ConditionRow(field: .url, name: "x", op: .contains))?.code == .unexpectedConditionName)
        #expect(issue(ConditionRow(field: .url, op: .exists))?.code == .invalidOperator)
        // New date and number comparisons.
        #expect(issue(ConditionRow(field: .requestDate, op: .afterOrEqual, value: "2026-10-25")) == nil)
        #expect(issue(ConditionRow(field: .requestDate, op: .beforeOrEqual, value: "nope"))?.code == .invalidConditionValue)
        #expect(issue(ConditionRow(field: .requestDate, op: .isNotEmpty)) == nil)
        #expect(issue(ConditionRow(field: .durationMs, op: .regex, value: "^1")) == nil)
        #expect(issue(ConditionRow(field: .durationMs, op: .isEmpty)) == nil)
        // Choices.
        for value in ["opened", "closed", "paused", "completed", "failed", "tunnel"] {
            #expect(issue(ConditionRow(field: .sessionState, op: .equals, value: value)) == nil, "\(value)")
        }
        #expect(issue(ConditionRow(field: .sessionState, op: .equals, value: "open"))?.code == .invalidConditionValue)
        #expect(issue(ConditionRow(field: .appProtocol, op: .equals, value: "rpc")) == nil)
        for field in [ConditionField.clientHTTPVersion, .upstreamHTTPVersion] {
            for value in ["h1", "h2", "HTTP/1.1", "HTTP/2", "anything"] {
                #expect(issue(ConditionRow(field: field, op: .equals, value: value)) == nil, "\(value)")
            }
        }
        #expect(issue(ConditionRow(field: .tlsVersion, op: .contains, value: "1.3")) == nil)
        #expect(issue(ConditionRow(field: .cookie, name: "sid", op: .regex, value: "["))?.code == .invalidRegex)
    }
}
