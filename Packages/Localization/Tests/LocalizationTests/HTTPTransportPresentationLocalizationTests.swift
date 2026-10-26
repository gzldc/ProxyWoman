import AppCore
import FlowStore
import Foundation
import Localization
import Testing

@Suite(.productionChinese) struct HTTPTransportPresentationLocalizationTests {
    @Test func injectedEnglishPreservesProtocolValuesAndEverySemanticLabel() throws {
        let url = try #require(Bundle.module.url(forResource: "Translations", withExtension: "bundle", subdirectory: "Fixtures"))
        let localizer = Localizer(bundle: try #require(Bundle(url: url)), preferredLanguages: ["en"])
        let transport = HTTPTransportMetadata(downstreamRequest: .http2, downstreamResponse: .http2,
            upstreamRequest: .http1_1, upstreamResponse: nil, downstreamStreamID: 3)
        #expect(HTTPTransportPresentation.summary(transport, localizer: localizer) == "Client: HTTP/2 (Stream 3) · Upstream: Request HTTP/1.1 / Response Unknown")
        let description = HTTPTransportPresentation.capabilityDescription(localizer: localizer)
        #expect(description.count > 200)
        #expect(description.contains("independently negotiate HTTP/2 or HTTP/1.1 through ALPN"))
        #expect(description.hasSuffix("h2c is not supported."))
        var flow = Flow(id: 1, scheme: "https", method: "GET", host: "example.test", port: 443, path: "/")
        flow.transport = transport
        flow.requestTrailers = [.init(name: "x-end", value: "a"), .init(name: "x-end", value: "b")]
        #expect(RawMessage.request(flow, localizer: localizer) == "<Reconstructed HTTP/2 text: generated from captured fields, not original binary frames>\r\n\r\nGET / HTTP/2\r\n\r\n\r\n\r\n<Captured trailers>\r\nx-end: a\r\nx-end: b")
        for key in ["summary", "unknown", "requestResponse", "stream", "reconstructed", "capturedTrailers", "capabilityTitle", "capabilityDescription"] {
            #expect(!L10n.string("httpTransport." + key).hasPrefix("httpTransport."))
            #expect(!localizer.string("httpTransport." + key).hasPrefix("httpTransport."))
        }
    }
}
