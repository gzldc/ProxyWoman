import Foundation
import Localization
import Testing
@testable import ProxyCore

@Suite(.productionChinese) struct HTTP2TransportLocalizationTests {
    @Test(arguments: [
        (HTTP2TransportError.unsupportedALPN("test/%50"), "不支持协商的协议：test/%50", "Unsupported negotiated protocol: test/%50"),
        (.invalidAuthority, "HTTP/2 请求的目标地址无效", "Invalid HTTP/2 request authority"),
        (.headerLimitExceeded, "HTTP/2 首部超过容量上限", "HTTP/2 header limit exceeded"),
        (.draining, "HTTP/2 连接正在关闭，不再接受新请求", "HTTP/2 connection is draining"),
    ])
    func diagnosticsUseProductionAndInjectedFormatter(error: HTTP2TransportError, chinese: String, english: String) throws {
        let url = try #require(Bundle.module.url(forResource: "Translations", withExtension: "bundle", subdirectory: "Fixtures"))
        let localizer = Localizer(bundle: try #require(Bundle(url: url)), preferredLanguages: ["en"])
        #expect(UpstreamConnector.describe(error) == chinese)
        #expect(UpstreamConnector.describe(error, localizer: localizer) == english)
        #expect(!HTTPExchange.isRetryableTransportFailure(error))
    }
}
