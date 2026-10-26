import Foundation
import Testing

@testable import FlowStore

private func flow(
    scheme: String = "https",
    method: String = "GET",
    path: String = "/",
    status: Int? = nil,
    requestHeaders: [HeaderField] = [],
    responseContentType: String? = nil
) -> Flow {
    var f = Flow(
        id: 1, scheme: scheme, method: method, host: "x.com", port: scheme == "https" ? 443 : 80, path: path,
        requestHeaders: requestHeaders)
    f.statusCode = status
    if let responseContentType {
        f.responseHeaders = [HeaderField(name: "Content-Type", value: responseContentType)]
    }
    return f
}

private func requestType(_ value: String) -> [HeaderField] {
    [HeaderField(name: "content-type", value: value)]
}

@Suite struct FlowProtocolTests {
    @Test func httpIsTheRemainder() {
        #expect(FlowProtocol.of(flow(scheme: "http")) == .http)
        #expect(FlowProtocol.of(flow(scheme: "http", status: 200)) == .http)
    }

    @Test func httpsByScheme() {
        #expect(FlowProtocol.of(flow(scheme: "https", status: 200)) == .https)
    }

    @Test func httpsByConnectMethodEvenOnHttpScheme() {
        #expect(FlowProtocol.of(flow(scheme: "http", method: "CONNECT")) == .https)
    }

    @Test func generic101IsNotWebsocket() {
        #expect(FlowProtocol.of(flow(scheme: "http", status: 101)) == .http)
        #expect(FlowProtocol.of(flow(scheme: "https", status: 101)) == .https)
    }

    @Test func websocketByUpgradeHeader() {
        let upgrade = [HeaderField(name: "UPGRADE", value: " h2c, WebSocket "), HeaderField(name: "Connection", value: "keep-alive, UpGrade")]
        #expect(FlowProtocol.of(flow(scheme: "http", requestHeaders: upgrade)) == .websocket)
        #expect(FlowProtocol.of(flow(scheme: "https", requestHeaders: upgrade)) == .websocket)
    }

    @Test func exactCandidateTokensAndMethodRequired() {
        let valid = [HeaderField(name: "Upgrade", value: "websocket"), HeaderField(name: "Connection", value: "upgrade")]
        #expect(FlowProtocol.of(flow(scheme: "http", requestHeaders: [HeaderField(name: "Upgrade", value: "x-websocket-something")])) == .http)
        #expect(FlowProtocol.of(flow(scheme: "http", requestHeaders: [valid[0]])) == .http)
        #expect(FlowProtocol.of(flow(scheme: "http", method: "POST", requestHeaders: valid)) == .http)
    }

    @Test func tokensUseASCIIHTTPCaseRulesAcrossRepeatedFields() {
        let connection = HeaderField(name: "Connection", value: "upgrade")
        for value in ["websocKet", "webſocket", "\u{00A0}websocket\u{00A0}"] {
            #expect(FlowProtocol.of(flow(scheme: "http", requestHeaders: [HeaderField(name: "Upgrade", value: value), connection])) == .http)
        }
        let repeated = [HeaderField(name: "Upgrade", value: "h2c"), HeaderField(name: "Upgrade", value: "WEBSOCKET"), HeaderField(name: "Connection", value: "keep-alive"), connection]
        #expect(FlowProtocol.of(flow(scheme: "http", requestHeaders: repeated)) == .websocket)
    }

    @Test func otherUpgradeIsNotWebsocket() {
        let h2c = [HeaderField(name: "Upgrade", value: "h2c")]
        #expect(FlowProtocol.of(flow(scheme: "http", requestHeaders: h2c)) == .http)
    }

    @Test func allCasesOrder() {
        #expect(FlowProtocol.allCases == [.http, .https, .websocket])
    }

    @Test func protocolsFilter() {
        let plain = flow(scheme: "http")
        let secure = flow(scheme: "https")
        let socket = flow(scheme: "https", status: 101, requestHeaders: [HeaderField(name: "Upgrade", value: "websocket"), HeaderField(name: "Connection", value: "upgrade")])
        var filter = FlowFilter()
        #expect([plain, secure, socket].allSatisfy(filter.matches))

        filter.protocols = [.https]
        #expect([plain, secure, socket].map(filter.matches) == [false, true, false])
        filter.protocols = [.http, .websocket]
        #expect([plain, secure, socket].map(filter.matches) == [true, false, true])
    }

    @Test func protocolsAndOtherDimensionsCombineWithAND() {
        var filter = FlowFilter()
        filter.protocols = [.https]
        filter.methods = ["POST"]
        #expect(!filter.matches(flow(scheme: "https", method: "GET")))
        #expect(filter.matches(flow(scheme: "https", method: "POST")))
    }
}

@Suite struct FormGraphQLKindTests {
    @Test func formByRequestContentType() {
        var filter = FlowFilter()
        filter.contentKinds = [.form]
        for type in ["application/x-www-form-urlencoded", "multipart/form-data; boundary=abc", "Application/X-WWW-Form-Urlencoded; charset=utf-8"] {
            #expect(filter.matches(flow(requestHeaders: requestType(type), responseContentType: "application/json")), "\(type)")
        }
        #expect(!filter.matches(flow(requestHeaders: requestType("application/json"), responseContentType: "application/json")))
    }

    @Test func formByResponseContentType() {
        var filter = FlowFilter()
        filter.contentKinds = [.form]
        #expect(filter.matches(flow(responseContentType: "application/x-www-form-urlencoded")))
        #expect(!filter.matches(flow(responseContentType: "text/plain")))
        #expect(!filter.matches(flow()))
    }

    @Test func graphqlByContentTypeEitherSide() {
        var filter = FlowFilter()
        filter.contentKinds = [.graphql]
        #expect(filter.matches(flow(requestHeaders: requestType("application/graphql"), responseContentType: "application/json")))
        #expect(filter.matches(flow(responseContentType: "application/graphql-response+json; charset=utf-8")))
        #expect(!filter.matches(flow(requestHeaders: requestType("application/json"), responseContentType: "application/json")))
    }

    @Test func graphqlByPathSuffixIgnoringQuery() {
        var filter = FlowFilter()
        filter.contentKinds = [.graphql]
        #expect(filter.matches(flow(method: "POST", path: "/graphql")))
        #expect(filter.matches(flow(method: "POST", path: "/api/v2/GraphQL")))
        #expect(filter.matches(flow(path: "/graphql?query=%7Ba%7D")))
        #expect(!filter.matches(flow(path: "/graphql/schema")))
        #expect(!filter.matches(flow(path: "/api?next=/graphql")))
        #expect(!filter.matches(flow(path: "/mygraphql")))
    }

    @Test func graphqlResponseJsonAlsoCountsAsJson() {
        var filter = FlowFilter()
        filter.contentKinds = [.json]
        #expect(filter.matches(flow(responseContentType: "application/graphql-response+json")))
    }

    @Test func aFlowMatchesAnyOfItsKinds() {
        let post = flow(method: "POST", path: "/graphql", requestHeaders: requestType("application/json"), responseContentType: "application/json")
        var filter = FlowFilter()
        filter.contentKinds = [.json]
        #expect(filter.matches(post))
        filter.contentKinds = [.graphql]
        #expect(filter.matches(post))
        filter.contentKinds = [.form]
        #expect(!filter.matches(post))
        filter.contentKinds = [.html, .graphql]
        #expect(filter.matches(post))
        filter.contentKinds = [.html, .css]
        #expect(!filter.matches(post))
    }

    @Test func otherKindsStayResponseOnly() {
        // 请求体是 JSON、响应是 HTML：JSON 不匹配，HTML 匹配。
        let flow = flow(method: "POST", requestHeaders: requestType("application/json"), responseContentType: "text/html")
        var filter = FlowFilter()
        filter.contentKinds = [.json]
        #expect(!filter.matches(flow))
        filter.contentKinds = [.html]
        #expect(filter.matches(flow))
    }

    @Test func formRequestWithoutResponseTypeIsNotOther() {
        let flow = flow(method: "POST", requestHeaders: requestType("application/x-www-form-urlencoded"))
        var filter = FlowFilter()
        filter.contentKinds = [.form]
        #expect(filter.matches(flow))
        // 原有“只看响应”的类别不变：没有响应类型的流仍属于“其他”。
        filter.contentKinds = [.other]
        #expect(filter.matches(flow))
    }

    @Test func classifyRecognizesFormAndGraphQLMimeTypes() {
        #expect(ContentKind.classify(contentType: "application/x-www-form-urlencoded") == .form)
        #expect(ContentKind.classify(contentType: "multipart/form-data; boundary=x") == .form)
        #expect(ContentKind.classify(contentType: "application/graphql") == .graphql)
        #expect(ContentKind.classify(contentType: "application/graphql-response+json") == .json)
    }
}

@Suite struct CurlOptionsTests {
    private func post() -> Flow {
        var f = Flow(
            id: 1, scheme: "https", method: "POST", host: "x.com", port: 443, path: "/p",
            requestHeaders: [
                HeaderField(name: "Content-Type", value: "application/json"),
                HeaderField(name: "Content-Length", value: "7"),
            ])
        f.requestBody = .memory(Data("{\"a\":1}".utf8))
        return f
    }

    @Test func defaultOptionsEqualLegacySignature() {
        #expect(CurlExporter.command(for: post(), options: CurlOptions()) == CurlExporter.command(for: post()))
    }

    @Test func proxyLineIsAppendedLast() {
        var options = CurlOptions()
        options.proxy = "http://127.0.0.1:9090"
        #expect(
            CurlExporter.command(for: post(), options: options)
                == "curl -X POST 'https://x.com/p' \\\n  -H 'Content-Type: application/json' \\\n  --data-binary '{\"a\":1}' \\\n  --proxy 'http://127.0.0.1:9090'")
    }

    @Test func proxyWithoutBodyOrHeaders() {
        let get = Flow(id: 1, scheme: "https", method: "GET", host: "x.com", port: 443, path: "/")
        var options = CurlOptions()
        options.proxy = "http://127.0.0.1:9090"
        #expect(CurlExporter.command(for: get, options: options) == "curl 'https://x.com/' \\\n  --proxy 'http://127.0.0.1:9090'")
    }

    @Test func proxyStaysEffectiveWithBinaryBodyComment() {
        var f = post()
        f.requestBody = .memory(Data([0xFF, 0xFE, 0x00]))
        var options = CurlOptions()
        options.proxy = "http://127.0.0.1:9090"
        let command = CurlExporter.command(for: f, options: options)
        #expect(command.contains("--proxy 'http://127.0.0.1:9090'"))
        // 注释行必须在最后，否则 --proxy 会被注释掉。
        #expect(command.hasSuffix("# request body omitted: binary (3 bytes)"))
    }

    @Test func preserveOriginalHeadersKeepsContentLength() {
        var options = CurlOptions()
        options.preserveOriginalHeaders = true
        #expect(
            CurlExporter.command(for: post(), options: options)
                == "curl -X POST 'https://x.com/p' \\\n  -H 'Content-Type: application/json' \\\n  -H 'Content-Length: 7' \\\n  --data-binary '{\"a\":1}'")
        #expect(!CurlExporter.command(for: post()).contains("Content-Length"))
    }

    @Test func proxyIsQuoted() {
        let get = Flow(id: 1, scheme: "https", method: "GET", host: "x.com", port: 443, path: "/")
        var options = CurlOptions()
        options.proxy = "http://u'x@127.0.0.1:9090"
        #expect(CurlExporter.command(for: get, options: options).hasSuffix("--proxy 'http://u'\\''x@127.0.0.1:9090'"))
    }
}
