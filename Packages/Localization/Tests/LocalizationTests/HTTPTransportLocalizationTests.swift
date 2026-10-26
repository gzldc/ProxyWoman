import Foundation
import Localization
import Testing
@testable import ProxyCore

@Suite(.productionChinese) struct HTTPTransportLocalizationTests {
    @Test(arguments: [
        (HTTPTransportError.cancelled, "请求已取消"),
        (.closed, "连接已关闭"),
        (.acquisitionTimedOut, "等待上游连接超时"),
        (.capacityExceeded, "待处理请求超过连接容量上限"),
        (.pendingBytesExceeded, "待转发请求超过缓冲上限"),
    ])
    func productionTransportReasonsDoNotExposeInternalCodes(error: HTTPTransportError, expected: String) {
        #expect(UpstreamConnector.describe(error) == expected)
        #expect(!HTTPExchange.isRetryableTransportFailure(error))
    }
    @Test(arguments: [
        (HTTPTransportError.cancelled, "Request cancelled"),
        (.closed, "Connection closed"),
        (.acquisitionTimedOut, "Timed out waiting for an upstream connection"),
        (.capacityExceeded, "Pending request capacity exceeded"),
        (.pendingBytesExceeded, "Pending request buffer limit exceeded"),
    ])
    func injectedEnglishUsesTheSameProductionErrorMapping(error: HTTPTransportError, expected: String) throws {
        let localizer = try english()
        #expect(UpstreamConnector.describe(error, localizer: localizer) == expected)
        #expect(!HTTPExchange.isRetryableTransportFailure(error))
    }

    @Test func rawUnderlyingErrorsAreNotTranslatedOrRewritten() throws {
        let error = RawOriginError()
        #expect(UpstreamConnector.describe(error) == "origin raw: %50 / 协议")
        #expect(UpstreamConnector.describe(error, localizer: try english()) == "origin raw: %50 / 协议")
    }

    private func english() throws -> Localizer {
        let url = try #require(Bundle.module.url(forResource: "Translations", withExtension: "bundle", subdirectory: "Fixtures"))
        return Localizer(bundle: try #require(Bundle(url: url)), preferredLanguages: ["en"])
    }
}

private struct RawOriginError: Error, CustomStringConvertible {
    var description: String { "origin raw: %50 / 协议" }
}
