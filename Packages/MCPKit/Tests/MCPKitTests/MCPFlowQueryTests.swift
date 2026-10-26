import FlowStore
import Foundation
import MCPWire
import Testing

@testable import MCPKit

@Suite struct MCPFlowQueryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let raw = MCPRedactor(MCPRedactionSettings(enabled: false))

    private func parse(_ arguments: [String: JSONValue]) throws -> MCPFlowQuery {
        try MCPFlowQuery.parse(arguments, now: now)
    }

    private func invalidField(_ arguments: [String: JSONValue]) -> String? {
        do {
            _ = try parse(arguments)
            return nil
        } catch let error as MCPToolError {
            return error.code == "invalid_arguments" ? error.message : "wrong code \(error.code)"
        } catch {
            return "wrong error"
        }
    }

    @Test func queryParsesStatusForms() throws {
        #expect(try parse(["status": .string("404")]).status == .exact(404))
        #expect(try parse(["status": .int(404)]).status == .exact(404))
        #expect(try parse(["status": .string("4xx")]).status == .range(400...499))
        #expect(try parse(["status": .string("5XX")]).status == .range(500...599))
        #expect(try parse(["status": .string("400-499")]).status == .range(400...499))
        #expect(try parse(["status": .string("400 - 499")]).status == .range(400...499))
        #expect(try parse(["status": .string(" 404 ")]).status == .exact(404))
        #expect(try parse(["status": .double(404)]).status == .exact(404))
        #expect(try parse([:]).status == nil)
        for bad: JSONValue in [
            .string("99"), .string("600"), .string("6xx"), .string("0xx"), .string("abc"), .string("500-400"),
            .string("400-"), .string("-1"), .double(404.5), .string("4 04"), .int(99), .bool(true), .string("4xxx"),
        ] {
            #expect(invalidField(["status": bad])?.contains("status") == true, "\(bad)")
        }
    }

    @Test func queryParsesRelativeAndISOTimes() throws {
        #expect(try parse(["since": .string("15m")]).since == now.addingTimeInterval(-900))
        #expect(try parse(["since": .string("2h")]).since == now.addingTimeInterval(-7200))
        #expect(try parse(["until": .string("1d")]).until == now.addingTimeInterval(-86400))
        #expect(try parse(["since": .string("30s")]).since == now.addingTimeInterval(-30))
        #expect(try parse(["since": .string("2H")]).since == now.addingTimeInterval(-7200))
        #expect(try parse(["since": .string("5M")]).since == now.addingTimeInterval(-300))
        let iso = try parse(["since": .string("2026-10-22T10:00:00Z")]).since
        #expect(iso == Date(timeIntervalSince1970: 1_792_663_200))
        let fractional = try parse(["since": .string("2026-10-22T10:00:00.500Z")]).since
        #expect(fractional == Date(timeIntervalSince1970: 1_792_663_200.5))
        let offset = try parse(["until": .string("2026-10-22T18:00:00+08:00")]).until
        #expect(offset == Date(timeIntervalSince1970: 1_792_663_200))
        for bad in ["yesterday", "m", "-5m", "1.5h", "99999999d", "2026-13-45"] {
            #expect(invalidField(["since": .string(bad)])?.contains("since") == true, "\(bad)")
        }
        #expect(invalidField(["until": .string("soon")])?.contains("until") == true)
    }

    @Test func queryRejectsBadTypesNamingTheField() {
        let cases: [(String, JSONValue)] = [
            ("host", .int(1)), ("method", .bool(true)), ("text", .array([])), ("limit", .string("5")),
            ("limit", .double(1.5)), ("before_id", .string("x")), ("since", .int(5)), ("until", .object([:])),
            ("host", .string(String(repeating: "a", count: 300))),
        ]
        for (field, value) in cases {
            let message = invalidField([field: value])
            #expect(message?.contains(field) == true, "\(field)=\(value) -> \(message ?? "accepted")")
        }
    }

    @Test func limitIsClampedTo200() throws {
        #expect(try parse([:]).limit == 50)
        #expect(try parse(["limit": .int(1000)]).limit == 200)
        #expect(try parse(["limit": .int(0)]).limit == 1)
        #expect(try parse(["limit": .int(-4)]).limit == 1)
        #expect(try parse(["limit": .int(75)]).limit == 75)
        #expect(try parse(["limit": .double(10.0)]).limit == 10)
        #expect(MCPFlowQuery(limit: 9999).limit == 200)
    }

    @Test func blankFilterValuesMeanNotGiven() throws {
        let query = try parse(["host": .string("  "), "text": .null, "method": .string("get")])
        #expect(query.host == nil)
        #expect(query.text == nil)
        #expect(query.method == "GET")
    }

    @Test func textMatchesUrlMethodStatusHostAndClientCaseInsensitively() {
        var flow = Flow(
            id: 1, scheme: "https", method: "POST", host: "api.example.com", port: 443, path: "/Users?id=7")
        flow.statusCode = 503
        flow.client = ClientApp(pid: 1, name: "Safari")
        for needle in ["users", "post", "503", "API.EXAMPLE", "safari", "id=7"] {
            #expect(MCPFlowQuery(text: needle).matches(flow, redactor: raw), "\(needle)")
        }
        #expect(!MCPFlowQuery(text: "chrome").matches(flow, redactor: raw))
        // Bodies and headers are not part of the text semantics.
        flow.requestHeaders = [HeaderField(name: "X-Thing", value: "zzz")]
        #expect(!MCPFlowQuery(text: "zzz").matches(flow, redactor: raw))
    }
}
