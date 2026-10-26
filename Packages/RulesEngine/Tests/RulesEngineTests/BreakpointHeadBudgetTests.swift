import FlowStore
import Testing
@testable import RulesEngine

struct BreakpointHeadBudgetTests {
    @Test func exact64KiBCombinedHeadPassesAndOneByteMoreFails() throws {
        let target = HTTPMessageTarget(scheme: "http", host: "a", port: 80, method: "GET", pathAndQuery: "/")
        // 11 metadata bytes + x(1) + field overhead(32) + value(65492) = 65536.
        let exact = HTTPMessageHead.request(target, headers: [.init(name: "x", value: String(repeating: "a", count: 65_492))])
        let over = HTTPMessageHead.request(target, headers: [.init(name: "x", value: String(repeating: "a", count: 65_493))])
        try HTTPMutationValidator.validateBreakpointHeadBudget(exact)
        #expect(throws: HTTPMutationError(code: .headerBlockTooLarge, field: .headers)) {
            try HTTPMutationValidator.validateBreakpointHeadBudget(over)
        }
    }

    @Test func everyStructuredRequestMetadataFieldSharesTheBudget() throws {
        let base = HTTPMessageTarget(scheme: "http", host: "a", port: 80, method: "GET", pathAndQuery: "/")
        let headers = [HeaderField(name: "x", value: "ab")]
        let limits = RulesLimits(headerBytes: 46)
        try HTTPMutationValidator.validateBreakpointHeadBudget(.request(base, headers: headers), limits: limits)
        let targets = [
            HTTPMessageTarget(scheme: "https", host: "a", port: 80, method: "GET", pathAndQuery: "/"),
            HTTPMessageTarget(scheme: "http", host: "aa", port: 80, method: "GET", pathAndQuery: "/"),
            HTTPMessageTarget(scheme: "http", host: "a", port: 800, method: "GET", pathAndQuery: "/"),
            HTTPMessageTarget(scheme: "http", host: "a", port: 80, method: "POST", pathAndQuery: "/"),
            HTTPMessageTarget(scheme: "http", host: "a", port: 80, method: "GET", pathAndQuery: "/a"),
        ]
        for target in targets {
            #expect(throws: HTTPMutationError(code: .headerBlockTooLarge, field: .headers)) {
                try HTTPMutationValidator.validateBreakpointHeadBudget(.request(target, headers: headers), limits: limits)
            }
        }
    }

    @Test func responseStatusReasonAndUTF8BytesAreChargedEvenWithoutHeaders() throws {
        let head = HTTPMessageHead.response(status: 200, reason: "好", headers: [.init(name: "x", value: "é")])
        // decimal status(3) + UTF8 reason(3) + name(1) + UTF8 value(2) + 32 = 41.
        try HTTPMutationValidator.validateBreakpointHeadBudget(head, limits: .init(headerBytes: 41))
        #expect(throws: HTTPMutationError(code: .headerBlockTooLarge, field: .headers)) {
            try HTTPMutationValidator.validateBreakpointHeadBudget(head, limits: .init(headerBytes: 40))
        }
        #expect(throws: HTTPMutationError(code: .headerBlockTooLarge, field: .headers)) {
            try HTTPMutationValidator.validateBreakpointHeadBudget(.response(status: 200, reason: nil, headers: []),
                                                                   limits: .init(headerBytes: 2))
        }
    }

    @Test func onlyRegularHeaderFieldsConsumeThe256FieldCount() throws {
        let exact = Array(repeating: HeaderField(name: "x", value: ""), count: 256)
        try HTTPMutationValidator.validateBreakpointHeadBudget(.response(status: 200, reason: "OK", headers: exact))
        #expect(throws: HTTPMutationError(code: .tooManyHeaderFields, field: .headers)) {
            try HTTPMutationValidator.validateBreakpointHeadBudget(.response(status: 200, reason: "OK", headers: exact + [.init(name: "y", value: "")]))
        }
    }

    @Test func ordinaryValidationKeepsItsExistingHeaderOnlyBudget() throws {
        let head = HTTPMessageHead.response(status: 200, reason: "OK",
            headers: [.init(name: "x", value: String(repeating: "a", count: 65_503))])
        try HTTPMutationValidator.validate(head: head, body: .init(length: nil, complete: false, changed: false))
        #expect(throws: HTTPMutationError(code: .headerBlockTooLarge, field: .headers)) {
            try HTTPMutationValidator.validateBreakpointHeadBudget(head)
        }
    }
}
