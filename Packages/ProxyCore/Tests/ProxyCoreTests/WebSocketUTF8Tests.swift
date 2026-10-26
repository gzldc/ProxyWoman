import Foundation
import Testing
@testable import ProxyCore

@Suite(.productionChinese) struct WebSocketUTF8Tests {
    @Test func byteAtATimeAndCompletePrefix() {
        let bytes = Data("Aé中😀Z".utf8)
        let validator = WebSocketUTF8Validator()
        for b in bytes { #expect(validator.feed(Data([b]))) }
        #expect(validator.finish())
        for n in 0...bytes.count {
            let prefix = Data(bytes.prefix(n))
            let length = validator.completePrefixLength(in: prefix)
            #expect(String(data: prefix.prefix(length), encoding: .utf8) != nil)
            #expect(length <= n && n - length <= 3)
        }
        #expect(validator.completePrefixLength(in: Data([0xF0, 0x9F, 0x98])) == 0)
        #expect(validator.finish()) // Prefix trimming does not alter full-message validation.
    }
    @Test(arguments: [[UInt8]([0xC0, 0xAF]), [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80], [0xF5, 0x80, 0x80, 0x80], [0x80], [0xE0, 0x9F, 0xBF], [0xF0, 0x8F, 0xBF, 0xBF], [0xE2, 0x28, 0xA1]])
    func invalid(_ bytes: [UInt8]) {
        let v = WebSocketUTF8Validator()
        var valid = true
        for b in bytes { valid = v.feed(Data([b])) && valid }
        #expect(!valid)
        #expect(!v.finish())
        #expect(!v.feed(Data("ok".utf8)))
    }
    @Test(arguments: [[UInt8]([0xC2, 0x80]), [0xDF, 0xBF], [0xE0, 0xA0, 0x80], [0xED, 0x9F, 0xBF], [0xF0, 0x90, 0x80, 0x80], [0xF4, 0x8F, 0xBF, 0xBF]])
    func scalarRangeEndpoints(_ bytes: [UInt8]) {
        let v = WebSocketUTF8Validator()
        for byte in bytes { #expect(v.feed(Data([byte]))) }
        #expect(v.finish())
        #expect(v.completePrefixLength(in: Data(bytes)) == bytes.count)
    }

    @Test func truncatedScalarIsIncomplete() {
        let v = WebSocketUTF8Validator()
        #expect(v.feed(Data([0xF0, 0x9F, 0x98])))
        #expect(!v.finish())
        #expect(v.feed(Data([0x80])))
        #expect(v.finish())
    }
}
