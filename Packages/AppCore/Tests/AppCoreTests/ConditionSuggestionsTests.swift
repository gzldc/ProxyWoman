import FlowStore
import Foundation
import RulesEngine
import Testing

@testable import AppCore

@Suite(.productionChinese) struct ConditionSuggestionsTests {
    private func flow(
        _ id: Int, host: String, method: String = "GET", path: String = "/", status: Int? = nil,
        request: [HeaderField] = [], response: [HeaderField] = [], app: String? = nil
    ) -> Flow {
        var flow = Flow(id: id, scheme: "https", method: method, host: host, port: 443, path: path, requestHeaders: request)
        flow.statusCode = status
        flow.responseHeaders = response
        flow.client = app.map { ClientApp(pid: 1, name: $0) }
        return flow
    }

    @Test func hostsAreRankedByFrequency() {
        let flows = [
            flow(1, host: "b.com"), flow(2, host: "a.com"), flow(3, host: "b.com"), flow(4, host: "c.com"), flow(5, host: "b.com"),
            flow(6, host: "a.com"),
        ]
        #expect(ConditionSuggestions.values(field: .host, name: nil, in: flows, limit: 10) == ["b.com", "a.com", "c.com"])
        #expect(ConditionSuggestions.values(field: .method, name: nil, in: flows, limit: 10) == ["GET"])
        let statuses = [flow(1, host: "a", status: 404), flow(2, host: "a", status: 200), flow(3, host: "a", status: 404), flow(4, host: "a")]
        #expect(ConditionSuggestions.values(field: .statusCode, name: nil, in: statuses, limit: 10) == ["404", "200"])
        let paths = [flow(1, host: "a", path: "/x?q=1"), flow(2, host: "a", path: "/x?q=2")]
        #expect(ConditionSuggestions.values(field: .path, name: nil, in: paths, limit: 10) == ["/x"])
        #expect(ConditionSuggestions.values(field: .pathAndQuery, name: nil, in: paths, limit: 10).count == 2)
        let apps = [flow(1, host: "a", app: "Safari"), flow(2, host: "a", app: "Safari"), flow(3, host: "a", app: "curl")]
        #expect(ConditionSuggestions.values(field: .clientApp, name: "name", in: apps, limit: 10) == ["Safari", "curl"])
    }

    @Test func headerNamesComeFromTheRightSide() {
        let flows = [
            flow(1, host: "a", request: [HeaderField(name: "Accept", value: "*/*"), HeaderField(name: "X-Req", value: "1")],
                response: [HeaderField(name: "Server", value: "nginx")]),
            flow(2, host: "a", request: [HeaderField(name: "accept", value: "text/html")],
                response: [HeaderField(name: "SERVER", value: "nginx"), HeaderField(name: "X-Resp", value: "1")]),
        ]
        #expect(ConditionSuggestions.values(field: .requestHeader, name: nil, in: flows, limit: 10) == ["Accept", "X-Req"])
        #expect(ConditionSuggestions.values(field: .responseHeader, name: nil, in: flows, limit: 10) == ["Server", "X-Resp"])
        #expect(ConditionSuggestions.values(field: .requestHeader, name: "ACCEPT", in: flows, limit: 10).sorted() == ["*/*", "text/html"])
    }

    @Test func limitIsHonoured() {
        let flows = (0..<20).map { flow($0, host: "h\($0).com") }
        #expect(ConditionSuggestions.values(field: .host, name: nil, in: flows, limit: 5).count == 5)
        #expect(ConditionSuggestions.values(field: .host, name: nil, in: flows, limit: 0).isEmpty)
    }

    @Test func fieldsWithoutSuggestionsReturnEmpty() {
        let flows = [flow(1, host: "a.com", status: 200)]
        for field in [ConditionField.allSessions, .durationMs, .sessionState, .requestBody, .rulesModified] {
            #expect(ConditionSuggestions.values(field: field, name: nil, in: flows, limit: 10).isEmpty, "\(field)")
        }
    }

    // MARK: R8F2 final review

    @Test func valueRoleWithoutAKeyOffersValuesNotNames() {
        let flows = [
            flow(1, host: "a", path: "/p?token=abc&lang=en",
                request: [HeaderField(name: "Accept", value: "*/*"), HeaderField(name: "Cookie", value: "sid=42; theme=dark")],
                response: [HeaderField(name: "Server", value: "nginx"), HeaderField(name: "Set-Cookie", value: "ack=1; Path=/")]),
        ]
        func values(_ field: ConditionField, _ role: ConditionSuggestions.Role) -> [String] {
            ConditionSuggestions.values(field: field, name: nil, role: role, in: flows, limit: 20).sorted()
        }
        #expect(values(.requestHeader, .values) == ["*/*", "sid=42; theme=dark"])
        #expect(values(.requestHeader, .names) == ["Accept", "Cookie"])
        #expect(values(.responseHeader, .values) == ["ack=1; Path=/", "nginx"])
        #expect(values(.requestCookie, .values) == ["42", "dark"])
        #expect(values(.requestCookie, .names) == ["sid", "theme"])
        #expect(values(.responseCookie, .values) == ["1"])
        #expect(values(.cookie, .values) == ["1", "42", "dark"])
        #expect(values(.queryParam, .values) == ["abc", "en"])
        #expect(values(.queryParam, .names) == ["lang", "token"])
        // A key wins over the role.
        #expect(ConditionSuggestions.values(field: .requestHeader, name: "accept", role: .values, in: flows, limit: 5) == ["*/*"])
        // Non-keyed fields ignore the role.
        #expect(ConditionSuggestions.values(field: .host, name: nil, role: .values, in: flows, limit: 5) == ["a"])
    }

    @Test func versionTimeCommentAndSizeFieldsCollect() {
        var one = flow(1, host: "a", status: 200, request: [HeaderField(name: "Content-Length", value: " 12 ")])
        one.transport = HTTPTransportMetadata(
            downstreamRequest: .http2, upstreamRequest: .http1_1, downstreamTLSVersion: "TLS 1.3", upstreamTLSVersion: "TLS 1.2")
        one.comment = "note"
        one.bytesReceived = 345
        one.startedAt = Date(timeIntervalSince1970: 1_700_000_000.0625)
        one.completedAt = Date(timeIntervalSince1970: 1_700_000_000.0625 + 0.25)
        func values(_ field: ConditionField, _ flow: Flow) -> [String] { ConditionSuggestions.values(field: field, name: nil, in: [flow], limit: 5) }
        #expect(values(.clientHTTPVersion, one) == ["HTTP/2"])
        #expect(values(.upstreamHTTPVersion, one) == ["HTTP/1.1"])
        #expect(values(.clientTLSVersion, one) == ["TLS 1.3"])
        #expect(values(.upstreamTLSVersion, one) == ["TLS 1.2"])
        #expect(values(.tlsVersion, one).sorted() == ["TLS 1.2", "TLS 1.3"])
        #expect(values(.comment, one) == ["note"])
        #expect(values(.requestBodySize, one) == ["12"])
        #expect(values(.responseBodySize, one) == ["345"])
        #expect(values(.durationMs, one) == ["250"])
        let time = values(.requestTime, one)
        #expect(time.count == 1)
        #expect(time[0].count == 12 && time[0].hasSuffix(".062"))
        // Chunked or unanswered flows offer no size.
        var chunked = flow(2, host: "a", request: [HeaderField(name: "Transfer-Encoding", value: "chunked"), HeaderField(name: "Content-Length", value: "5")])
        #expect(values(.requestBodySize, chunked).isEmpty)
        #expect(values(.responseBodySize, chunked).isEmpty)
        chunked.transport = HTTPTransportMetadata()
        #expect(values(.clientHTTPVersion, chunked).isEmpty)
    }
}
