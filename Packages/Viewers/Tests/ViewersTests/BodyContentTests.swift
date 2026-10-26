import AppKit
import Compression
import Foundation
import Testing

@testable import Viewers

@Suite(.productionChinese) struct BodyContentTests {
    private func deflate(_ input: Data) -> Data {
        let cap = input.count + 1024
        var out = [UInt8](repeating: 0, count: cap)
        let n = input.withUnsafeBytes { src in
            compression_encode_buffer(
                &out, cap, src.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_ZLIB)
        }
        return Data(out[0..<n])
    }

    private func png() -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    @Test func emptyBodyWithContentEncodingIsNotDecoded() {
        let content = BodyContent.make(data: Data(), contentType: "application/json", contentEncoding: "gzip")
        #expect(content.decodeError == nil)
        #expect(content.json == nil)
        #expect(content.image == nil)
    }

    @Test func compressedJSONIsDecodedParsedAndPrettyPrinted() throws {
        let json = Data(#"{"z":1,"a":{"m":[true,null]},"b":"x"}"#.utf8)
        let content = BodyContent.make(
            data: deflate(json), contentType: "application/json", contentEncoding: "deflate")
        #expect(content.decodeError == nil)
        #expect(content.data == json)
        let node = try #require(content.json)
        guard case .object(let members) = node else {
            Issue.record("expected object")
            return
        }
        #expect(members.map(\.key) == ["z", "a", "b"])
        #expect(content.text == node.prettyPrinted())
        #expect(content.isTextTruncated == false)
        #expect(content.modes == [.json, .text, .hex])
        #expect(content.defaultMode == .json)
    }

    @Test func corruptEncodingShowsErrorAndKeepsRawBytes() {
        let raw = Data("not gzip at all".utf8)
        let content = BodyContent.make(data: raw, contentType: "text/plain", contentEncoding: "gzip")
        #expect(content.decodeError == "解压失败（gzip）")
        #expect(content.data == raw)
        #expect(content.text == "not gzip at all")
    }

    @Test func plainTextDefaultsToRaw() {
        let content = BodyContent.make(
            data: Data("hello 世界".utf8), contentType: "text/plain; charset=utf-8", contentEncoding: nil)
        #expect(content.text == "hello 世界")
        #expect(content.json == nil)
        #expect(content.modes == [.text, .hex])
        #expect(content.defaultMode == .text)
    }

    @Test func scalarJSONIsNotShownAsTree() {
        let content = BodyContent.make(data: Data("123".utf8), contentType: "application/json", contentEncoding: nil)
        #expect(content.json == nil)
        #expect(content.defaultMode == .text)
    }

    @Test func undecodableBinaryDefaultsToHex() {
        let content = BodyContent.make(
            data: Data([0xff, 0xfe, 0x00, 0xc3, 0x28, 0x80]), contentType: "application/octet-stream",
            contentEncoding: nil)
        #expect(content.text == nil)
        #expect(content.modes == [.text, .hex])
        #expect(content.defaultMode == .hex)
    }

    @Test func imageDefaultsToImage() throws {
        let content = BodyContent.make(data: png(), contentType: "image/png", contentEncoding: nil)
        let image = try #require(content.image)
        #expect(image.pixelWidth == 2 && image.pixelHeight == 2)
        #expect(content.modes == [.text, .hex, .image])
        #expect(content.defaultMode == .image)
    }

    @Test func longTextIsTruncatedOnCharacterBoundary() throws {
        // 3-byte characters: the 2 MB limit falls inside one of them.
        let text = String(repeating: "中", count: BodyContent.textLimit / 3 + 10)
        let content = BodyContent.make(data: Data(text.utf8), contentType: "text/plain", contentEncoding: nil)
        let shown = try #require(content.text)
        #expect(content.isTextTruncated)
        #expect(shown.utf8.count <= BodyContent.textLimit)
        #expect(shown.utf8.count > BodyContent.textLimit - 3)
        #expect(shown.allSatisfy { $0 == "中" })
    }

    @Test func longPrettyPrintedJSONIsTruncated() throws {
        let items = Array(repeating: #""abcdefghij""#, count: BodyContent.textLimit / 12 + 1000)
        let json = Data(("[" + items.joined(separator: ",") + "]").utf8)
        let content = BodyContent.make(data: json, contentType: "application/json", contentEncoding: nil)
        #expect(content.json != nil)
        let shown = try #require(content.text)
        #expect(content.isTextTruncated)
        #expect(shown.utf8.count <= BodyContent.textLimit)
        #expect(shown.hasPrefix("[\n  \"abcdefghij\""))
    }

    @Test func jsonOverTreeLimitIsNotParsed() {
        let items = Array(repeating: "1", count: BodyContent.jsonLimit / 2 + 10)
        let json = Data(("[" + items.joined(separator: ",") + "]").utf8)
        #expect(json.count > BodyContent.jsonLimit)
        let content = BodyContent.make(data: json, contentType: "application/json", contentEncoding: nil)
        #expect(content.json == nil)
        #expect(content.defaultMode == .text)
        #expect(content.isTextTruncated)
    }

    @Test func truncatedInputIsNeitherDecodedNorParsedNorAnImage() {
        let compressedJSON = deflate(Data(#"{"a":1}"#.utf8))
        let content = BodyContent.make(
            data: compressedJSON, contentType: "application/json", contentEncoding: "deflate", isTruncated: true)
        #expect(content.decodeError == nil)
        #expect(content.data == compressedJSON)
        #expect(content.json == nil)
        #expect(content.isTruncated)

        let image = BodyContent.make(data: png(), contentType: "image/png", contentEncoding: nil, isTruncated: true)
        #expect(image.image == nil)
        #expect(!image.modes.contains(.image))
    }

    @Test func undecodableLongBodyIsNotMarkedTextTruncated() {
        let binary = Data(repeating: 0xff, count: BodyContent.textLimit + 10)
        let content = BodyContent.make(data: binary, contentType: nil, contentEncoding: nil)
        #expect(content.text == nil)
        #expect(content.isTextTruncated == false)
    }

    @Test func jsonRootsArePreparedWithTheContent() throws {
        let content = BodyContent.make(
            data: Data(#"{"b":1,"a":2}"#.utf8), contentType: "application/json", contentEncoding: nil)
        let roots = try #require(content.jsonRoots)
        #expect(roots.map(\.label) == ["b", "a"])
    }

    @Test func modeTitles() {
        #expect(BodyMode.allCases.map(\.title) == ["JSON", "原文", "Hex", "图片"])
    }
}

@Suite(.productionChinese) struct TruncationNoticeTests {
    @Test func completeBodyHasNoNotice() {
        #expect(
            BodyContent.truncationNotice(
                displayTruncated: false, captureTruncated: false, recordedBytes: 10, isEncoded: false) == nil)
    }

    @Test func displayLimitNotice() {
        let notice = BodyContent.truncationNotice(
            displayTruncated: true, captureTruncated: false, recordedBytes: 200 << 20, isEncoded: false)
        #expect(notice == "正文过大，仅显示前 100 MB")
        let encoded = BodyContent.truncationNotice(
            displayTruncated: true, captureTruncated: false, recordedBytes: 200 << 20, isEncoded: true)
        #expect(encoded == "正文过大，仅显示前 100 MB（未解压）")
    }

    @Test func captureLimitNoticeNamesTheRecordedSize() throws {
        let notice = try #require(
            BodyContent.truncationNotice(
                displayTruncated: false, captureTruncated: true, recordedBytes: 50 << 20, isEncoded: false))
        let size = ByteCountFormatter.string(fromByteCount: 50 << 20, countStyle: .file)
        #expect(notice == "正文过大，仅记录了前 \(size)")
        let encoded = BodyContent.truncationNotice(
            displayTruncated: false, captureTruncated: true, recordedBytes: 50 << 20, isEncoded: true)
        #expect(encoded == "正文过大，仅记录了前 \(size)（未解压）")
    }
}
