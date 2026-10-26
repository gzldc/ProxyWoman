import FlowStore
import Testing
@testable import AppCore

@Suite(.productionChinese) struct HTTPTransportPresentationTests {
    @Test func unknownTunnelNeverInventsVersion() {
        #expect(HTTPTransportPresentation.summary(.init()) == "客户端：未知 · 上游：未知")
    }
    @Test func equalLegsAreCompactButConversionRemainsVisible() {
        let metadata = HTTPTransportMetadata(downstreamRequest: .http1_1, downstreamResponse: .http1_1,
            upstreamRequest: .http2, upstreamResponse: .http2, upstreamStreamID: 7)
        #expect(HTTPTransportPresentation.summary(metadata) == "客户端：HTTP/1.1 · 上游：HTTP/2（流 7）")
    }
    @Test func asymmetricAndMissingBoundariesAreExplicit() {
        let metadata = HTTPTransportMetadata(downstreamRequest: .http2, downstreamResponse: nil,
            upstreamRequest: .http1_1, upstreamResponse: .http1_0, downstreamStreamID: 11)
        #expect(HTTPTransportPresentation.summary(metadata) == "客户端：请求 HTTP/2 / 响应 未知（流 11） · 上游：请求 HTTP/1.1 / 响应 HTTP/1.0")
    }
    @Test func capabilitiesDescribeIndependentHTTPSNegotiation() {
        let text = HTTPTransportPresentation.capabilityDescription()
        #expect(text.contains("HTTPS"))
        #expect(text.contains("ALPN"))
        #expect(text.contains("各自"))
        #expect(text.contains("HTTP/1.1"))
        #expect(text.contains("h2c"))
    }
}
