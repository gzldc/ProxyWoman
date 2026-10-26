import FlowStore
import Foundation
import NIOHTTP1
import RulesEngine
import Testing
@testable import ProxyCore

@Suite(.productionChinese) struct BreakpointFramingTests {
    struct Case: Sendable {
        let name: String
        var source: HTTPWireVersion = .http1_1
        var target: HTTPWireVersion = .http1_1
        var direction: HTTPMessageDirection = .response
        var method = "GET"
        var status = 200
        var headers = [HeaderField(name: "Content-Length", value: "3")]
        var editedLength: Int64? = nil
        var suppliedLength: String? = nil
        var expectedLength: String? = "3"
        var chunked = false
        var trailers = false
        var payload = true
        var close = false
    }
    static let cases: [Case] = [
        .init(name: "h1 length unchanged"),
        .init(name: "h1 chunked trailers", headers: [.init(name: "Transfer-Encoding", value: "chunked"), .init(name: "Trailer", value: "x-end")], expectedLength: nil, chunked: true, trailers: true),
        .init(name: "h1 edited chunked", headers: [.init(name: "Transfer-Encoding", value: "chunked"), .init(name: "Trailer", value: "x-end")], editedLength: 5, expectedLength: "5"),
        .init(name: "h1 to h2", target: .http2, headers: [.init(name: "Transfer-Encoding", value: "chunked"), .init(name: "Trailer", value: "x-end")], trailers: true),
        .init(name: "h2 to h1", source: .http2),
        .init(name: "h2 trailers to h1", source: .http2, headers: [.init(name: "Trailer", value: "x-end")], expectedLength: nil, chunked: true, trailers: true),
        .init(name: "h2 to h2", source: .http2, target: .http2),
        .init(name: "empty edit", editedLength: 0, expectedLength: "0"),
        .init(name: "HEAD representation retained", method: "HEAD", editedLength: 5, payload: false),
        .init(name: "204", status: 204, headers: [], editedLength: 5, expectedLength: nil, payload: false),
        .init(name: "304 representation retained", status: 304, editedLength: 5, payload: false),
        .init(name: "HTTP10 close preserved", source: .http1_0, target: .http1_0, headers: [], expectedLength: nil, close: true),
        .init(name: "HTTP10 edit length", source: .http1_0, target: .http1_0, headers: [], editedLength: 5, expectedLength: "5"),
        .init(name: "deleted length", suppliedLength: "", expectedLength: "3"),
        .init(name: "false length", suppliedLength: "999", expectedLength: "3"),
        .init(name: "request h2 to h1", source: .http2, direction: .request, method: "POST", editedLength: 5, expectedLength: "5"),
        .init(name: "request h1 to h2", target: .http2, direction: .request, method: "POST", editedLength: 5, expectedLength: "5")
    ]
    @Test(arguments: cases) func matrix(c: Case) throws {
        let target = HTTPMessageTarget(scheme: "https", host: "example.test", port: 443, method: c.method, pathAndQuery: "/")
        let original: HTTPMessageHead = c.direction == .request ? .request(target, headers: c.headers)
            : .response(status: c.status, reason: nil, headers: c.headers)
        var edited = original
        if let supplied = c.suppliedLength {
            var fields = c.headers.filter { $0.name.lowercased() != "content-length" }
            if !supplied.isEmpty { fields.append(.init(name: "Content-Length", value: supplied)) }
            edited = c.direction == .request ? .request(target, headers: fields) : .response(status: c.status, reason: nil, headers: fields)
        }
        let trailers = c.headers.contains { $0.name.lowercased() == "trailer" } ? [HeaderField(name: "x-end", value: "yes")] : []
        let plan = try BreakpointFraming.plan(original: original, edited: edited,
            body: .init(length: c.editedLength ?? 3, complete: true, changed: c.editedLength != nil, trailers: trailers),
            source: c.source, target: c.target, requestMethod: c.method)
        let fields = HTTPHeaders(fields: plan.head.headers)
        #expect(fields.first(name: "content-length") == c.expectedLength, "\(c.name)")
        #expect((fields.first(name: "transfer-encoding") == "chunked") == c.chunked, "\(c.name)")
        #expect(!plan.trailers.isEmpty == c.trailers, "\(c.name)")
        #expect(plan.bodyAllowed == c.payload, "\(c.name)")
        #expect(plan.closeDelimited == c.close, "\(c.name)")
        if c.target == .http2 { #expect(!fields.contains(name: "connection") && !fields.contains(name: "keep-alive")) }
    }
    @Test func changedEncodingRequiresExplicitChoiceAndDropsIntegrity() throws {
        let head = HTTPMessageHead.response(status: 200, reason: nil, headers: [
            .init(name: "Content-Encoding", value: "gzip"), .init(name: "ETag", value: "old"), .init(name: "Digest", value: "old")])
        #expect(throws: HTTPMutationError.self) {
            try BreakpointFraming.plan(original: head, edited: head, body: .init(length: 5, complete: true, changed: true), source: .http1_1, target: .http2, requestMethod: "GET")
        }
        let plan = try BreakpointFraming.plan(original: head, edited: head,
            body: .init(length: 5, complete: true, changed: true, encodingChoice: .removeEncoding), source: .http1_1, target: .http2, requestMethod: "GET")
        #expect(plan.head.headers.map { $0.name.lowercased() } == ["content-length"])
    }
}

extension BreakpointFramingTests {
    @Test func bodyOutcomesBelongOnlyToMatchedBreakpointRules() throws {
        let header = TestRules.headers(.request, [.set(name: "X-Edit", value: "yes")])
        let breakpoint = TestRules.breakpoint(.request)
        let original = HTTPMessageHead.request(.init(scheme: "http", host: "example.test", port: 80, method: "POST", pathAndQuery: "/"), headers: [])
        let session = ExchangeRuleSession(snapshot: RuleSnapshot(revision: 1, rules: [header, breakpoint]),
                                          hits: nil, originalRequest: original, provenance: .init())
        _ = try session.prepareRequest()
        session.recordBodyOutcomes([.breakpointLengthCorrected], direction: .request)
        #expect(session.provenance.ruleMatches?.outcomes.filter { $0.code == .breakpointLengthCorrected }.map(\.ruleID) == [breakpoint.id])
    }

    @Test func magicStringBreakpointRecordsBodyOutcomesLikeAPlainOne() throws {
        let magic = Rule(name: "bpu", actions: [RuleAction(.magicString("*bpu"))])
        let plain = TestRules.breakpoint(.request)
        let original = HTTPMessageHead.request(.init(scheme: "http", host: "example.test", port: 80, method: "POST", pathAndQuery: "/"), headers: [])
        func outcomes(_ rule: Rule) throws -> [RuleOutcomeCode] {
            let session = ExchangeRuleSession(snapshot: RuleSnapshot(revision: 1, rules: [rule]),
                                              hits: nil, originalRequest: original, provenance: .init())
            _ = try session.prepareRequest()
            session.recordBodyOutcomes([.breakpointLengthCorrected], direction: .request)
            return try #require(session.provenance.ruleMatches).outcomes.map(\.code)
        }
        let viaMagic = try outcomes(magic)
        #expect(viaMagic.contains(.breakpointLengthCorrected))
        #expect(viaMagic == (try outcomes(plain)))
    }
}
