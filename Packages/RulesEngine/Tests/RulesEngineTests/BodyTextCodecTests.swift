import Foundation
import Testing

@testable import RulesEngine

@Suite("BodyTextCodec")
struct BodyTextCodecTests {
    @Test func textLikeTable() {
        let yes = [
            "text/html", "TEXT/Plain; charset=UTF-8", "application/json", "application/vnd.api+json",
            "application/xml", "image/svg+xml", "application/x-www-form-urlencoded", "text/css",
            "application/javascript", "application/x-javascript", "application/ecmascript", "application/graphql",
            "application/atom+xml", "  application/json  ;charset=utf-8",
        ]
        let no = [
            "image/png", "application/octet-stream", "text/event-stream", "Text/Event-Stream; charset=utf-8",
            "application/x-ndjson", "application/stream+json", "multipart/x-mixed-replace; boundary=x",
            "application/grpc+proto", "application/grpc", "application/grpc-web+proto", "application/pdf", "", nil,
        ]
        for type in yes { #expect(BodyTextCodec.isTextLike(contentType: type), "\(type)") }
        for type in no { #expect(!BodyTextCodec.isTextLike(contentType: type), "\(String(describing: type))") }
    }

    @Test func charsetDefaultsToUTF8AndParsesQuoted() {
        #expect(BodyTextCodec.encoding(contentType: nil) == .utf8)
        #expect(BodyTextCodec.encoding(contentType: "text/html") == .utf8)
        #expect(BodyTextCodec.encoding(contentType: "text/html; charset=utf-8") == .utf8)
        #expect(BodyTextCodec.encoding(contentType: "text/html; Charset=\"UTF-8\"") == .utf8)
        #expect(BodyTextCodec.encoding(contentType: "text/html; boundary=x; charset = 'ISO-8859-1'") == .isoLatin1)
        #expect(BodyTextCodec.encoding(contentType: "text/html;charset=latin1") == .isoLatin1)
        #expect(BodyTextCodec.encoding(contentType: "text/html;charset=us-ascii") == .ascii)
        #expect(BodyTextCodec.encoding(contentType: "text/html;charset=utf-16") == .utf16)
        #expect(BodyTextCodec.encoding(contentType: "text/html;charset=UTF-16LE") == .utf16LittleEndian)
        #expect(BodyTextCodec.encoding(contentType: "text/html;charset=utf-16be") == .utf16BigEndian)
    }

    @Test func unsupportedCharsetIsNil() {
        #expect(BodyTextCodec.encoding(contentType: "text/html; charset=shift_jis") == nil)
        #expect(BodyTextCodec.encoding(contentType: "text/html; charset=") == nil)
        #expect(BodyTextCodec.encoding(contentType: "text/html; charset=utf-32") == nil)
    }

    @Test func invalidUTF8Throws() {
        #expect(throws: BodyTextCodec.Failure.invalidBytes) {
            try BodyTextCodec.decode(Data([0x61, 0xff, 0x62]), as: .utf8)
        }
        #expect(throws: BodyTextCodec.Failure.invalidBytes) {
            try BodyTextCodec.decode(Data([0xc3]), as: .utf8)
        }
        #expect(throws: BodyTextCodec.Failure.invalidBytes) {
            try BodyTextCodec.decode(Data([0x00, 0x61, 0x00]), as: .utf16BigEndian)
        }
        #expect(throws: BodyTextCodec.Failure.invalidBytes) {
            try BodyTextCodec.decode(Data([0x61, 0x80]), as: .ascii)
        }
        #expect(throws: BodyTextCodec.Failure.unsupportedCharset) {
            try BodyTextCodec.decode(Data([0x61]), as: .shiftJIS)
        }
    }

    @Test func roundTripIsByteExact() throws {
        let samples: [(String.Encoding, Data)] = [
            (.utf8, Data("héllo 世界 😀".utf8)),
            (.utf8, Data([0xef, 0xbb, 0xbf]) + Data("bom first".utf8)),
            (.utf8, Data()),
            (.isoLatin1, Data([0x63, 0x61, 0x66, 0xe9])),
            (.utf16, Data([0xff, 0xfe, 0x61, 0x00, 0x3d, 0xd8, 0x00, 0xde])),  // BOM LE: "a" + U+1F600
            (.utf16BigEndian, Data([0xfe, 0xff, 0x00, 0x61, 0x4e, 0x16])),
            (.utf16LittleEndian, Data([0x61, 0x00, 0x16, 0x4e])),
            (.ascii, Data("plain".utf8)),
        ]
        for (encoding, data) in samples {
            let text = try BodyTextCodec.decode(data, as: encoding)
            #expect(try BodyTextCodec.encode(text, as: encoding) == data, "\(encoding) \(Array(data))")
        }
        // A BOM is a character in the text, so a pattern sees it and a rewrite keeps it.
        #expect(try BodyTextCodec.decode(Data([0xef, 0xbb, 0xbf, 0x61]), as: .utf8) == "\u{feff}a")
    }

    @Test func utf16ResolvesByteOrderFromBOM() throws {
        let be = Data([0xfe, 0xff, 0x00, 0x61])
        #expect(try BodyTextCodec.decode(be, as: .utf16) == "\u{feff}a")
        #expect(BodyTextCodec.resolvedEncoding(.utf16, for: be) == .utf16BigEndian)
        #expect(BodyTextCodec.resolvedEncoding(.utf16, for: Data([0xff, 0xfe, 0x61, 0x00])) == .utf16LittleEndian)
        #expect(BodyTextCodec.resolvedEncoding(.utf16, for: Data([0x00, 0x61])) == .utf16BigEndian)
        #expect(BodyTextCodec.resolvedEncoding(.utf8, for: be) == .utf8)
        // Without a BOM, RFC 2781 says big endian.
        #expect(try BodyTextCodec.decode(Data([0x00, 0x61]), as: .utf16) == "a")
    }

    @Test func asciiRejectsNonASCIIOnEncode() {
        #expect(throws: BodyTextCodec.Failure.unencodable) { try BodyTextCodec.encode("é", as: .ascii) }
        #expect(throws: BodyTextCodec.Failure.unencodable) { try BodyTextCodec.encode("世", as: .isoLatin1) }
        #expect(throws: BodyTextCodec.Failure.unsupportedCharset) { try BodyTextCodec.encode("a", as: .shiftJIS) }
        #expect((try? BodyTextCodec.encode("é", as: .isoLatin1)) == Data([0xe9]))
    }
}
