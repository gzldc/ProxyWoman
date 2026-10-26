import Foundation
import Testing

@testable import Viewers

@MainActor @Suite(.productionChinese) struct BodyViewStyleTests {
    @Test func displayPreferencesInvalidateEquatableView() {
        let original = BodyView(data: Data("hello".utf8), contentType: "text/plain", contentEncoding: nil)
        for style in [
            ViewerStyle(fontSize: 16), ViewerStyle(monospaced: false),
            ViewerStyle(wrapsLines: false), ViewerStyle(showsInvisibles: true),
        ] {
            #expect(
                original
                    != BodyView(data: Data("hello".utf8), contentType: "text/plain", contentEncoding: nil, style: style)
            )
        }
    }

    @Test func treeTabInvalidatesViewWithoutChangingBody() {
        let data = Data("{\"a\":1}".utf8)
        #expect(
            BodyView(data: data, contentType: nil, contentEncoding: nil)
                != BodyView(data: data, contentType: nil, contentEncoding: nil, treeOnly: true))
    }
}
