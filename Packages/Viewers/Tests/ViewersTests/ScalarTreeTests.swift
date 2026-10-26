import Foundation
import Testing

@testable import Viewers

@Suite(.productionChinese) struct ScalarTreeTests {
    @Test(arguments: ["true", "42", "\"hello\"", "null"])
    func scalarHasTreeWhileNormalBodyModesStayCompatible(_ text: String) {
        let content = BodyContent.make(data: Data(text.utf8), contentType: "application/json", contentEncoding: nil)
        #expect(content.jsonRoots?.first?.summary == text)
        #expect(!content.modes.contains(.json))
    }
}
