import Foundation
import Localization
import Testing
@testable import ProxyCore

@Suite(.productionChinese) struct HTTPTranslationLocalizationTests {
    @Test(arguments: [
        (HTTPTranslationError.invalidHeader, "HTTP 消息头字段无效", "Invalid HTTP header field"),
        (.invalidContentLength, "HTTP 正文长度无效", "Invalid HTTP content length"),
        (.unsupportedTransferCoding, "目标协议不支持此 HTTP 传输编码", "HTTP transfer coding is unsupported by the destination"),
        (.requestLengthRequired, "HTTP/1.0 请求正文需要明确长度", "HTTP/1.0 request body requires a known length"),
        (.invalidFraming, "HTTP 消息分帧无效", "Invalid HTTP message framing"),
    ])
    func translationReasonsUseTheExistingFormatter(error: HTTPTranslationError, chinese: String, english: String) throws {
        let url = try #require(Bundle.module.url(forResource: "Translations", withExtension: "bundle", subdirectory: "Fixtures"))
        let localizer = Localizer(bundle: try #require(Bundle(url: url)), preferredLanguages: ["en"])
        #expect(UpstreamConnector.describe(error) == chinese)
        #expect(UpstreamConnector.describe(error, localizer: localizer) == english)
        #expect(!HTTPExchange.isRetryableTransportFailure(error))
    }
}
