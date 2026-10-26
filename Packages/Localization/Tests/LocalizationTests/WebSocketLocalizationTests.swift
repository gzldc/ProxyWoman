import Foundation
import Testing
@testable import Localization

@Suite(.productionChinese) struct WebSocketLocalizationTests {
    @Test func productionSentencesAndPreviewLabelsResolve() {
        #expect(L10n.string("webSocket.capture.paused") == "已暂停保存 WebSocket 内容，连接继续转发")
        for key in ["messages", "handshake", "copyTextPreview", "copyHexPreview", "savePayload", "exportJSONL", "unavailable", "pending", "follow", "nextPage", "direction.clientToServer", "direction.serverToClient", "column.time", "column.preview", "capture.resumePendingBoundary", "capture.contentStoppedUntilReconnect", "status.truncated", "export.partial", "tableAccessibility"] {
            #expect(L10n.string("webSocket." + key) != "webSocket." + key)
        }
        #expect(Localizer(bundle: L10n.bundle, preferredLanguages: ["en"]).supportedLanguageCodes == ["en", "zh-Hans"])
    }
    @Test func defaultSaveFileNamesAreLocalizedResources() {
        // Phase fix 8: save panels propose resource-backed names, keeping their extensions.
        let jsonl = L10n.string("webSocket.defaultFileName.jsonl"), payload = L10n.string("webSocket.defaultFileName.payload")
        #expect(jsonl == "WebSocket 消息.jsonl" && payload == "WebSocket 载荷.bin")
    }
    @Test func englishWholeSentencesReorderAndPluralize() throws {
        let url = try #require(Bundle.module.url(forResource: "Translations", withExtension: "bundle", subdirectory: "Fixtures"))
        let l = Localizer(bundle: try #require(Bundle(url: url)), preferredLanguages: ["en"])
        #expect(l.format("webSocket.interval", arguments: ["START", "END"]) == "Observation ended at END after starting at START; times include milliseconds and the time zone.")
        for count in [0, 1, 200] {
            let value = l.format("webSocket.eventCount", arguments: [count])
            #expect(value == "Retained \(count) " + (count == 1 ? "message." : "messages."))
        }
    }
}
