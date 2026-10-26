import Compression
import Foundation
import Testing

@testable import Viewers

@Suite(.productionChinese) struct BodyDecoderTests {
    // printf hello | gzip -n | xxd -i
    private let gz = Data([
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0xcb, 0x48, 0xcd, 0xc9, 0xc9,
        0x07, 0x00, 0x86, 0xa6, 0x10, 0x36, 0x05, 0x00, 0x00, 0x00,
    ])

    private func encode(_ input: Data, algorithm: compression_algorithm) -> Data {
        let cap = input.count + 1024
        var out = [UInt8](repeating: 0, count: cap)
        let n = input.withUnsafeBytes { src in
            compression_encode_buffer(
                &out, cap, src.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, algorithm)
        }
        return Data(out[0..<n])
    }

    @Test func outputCapStopsInflationAndKeepsTheInput() {
        let plain = Data(repeating: UInt8(ascii: "z"), count: 300_000)
        let deflated = encode(plain, algorithm: COMPRESSION_ZLIB)
        let capped = BodyDecoder.decode(deflated, contentEncoding: "deflate", maxOutputBytes: 100_000)
        #expect(capped.error != nil && capped.encoding == nil && capped.data == deflated)
        let exact = BodyDecoder.decode(deflated, contentEncoding: "deflate", maxOutputBytes: 300_000)
        #expect(exact.error == nil && exact.data == plain)
    }

    @Test func gunzip() {
        #expect(
            BodyDecoder.decode(gz, contentEncoding: "gzip")
                == DecodedBody(data: Data("hello".utf8), encoding: "gzip", error: nil))
    }

    @Test func xGzipReportsGzipAndIsCaseInsensitive() {
        #expect(
            BodyDecoder.decode(gz, contentEncoding: "  X-GZip ")
                == DecodedBody(data: Data("hello".utf8), encoding: "gzip", error: nil))
    }

    @Test func gzipWithFNAMEHeader() {
        // header with FNAME flag (0x08) and name "a\0"
        var d = Data([0x1f, 0x8b, 0x08, 0x08, 0, 0, 0, 0, 0, 0x03, 0x61, 0x00])
        d.append(gz.suffix(from: 10))
        #expect(BodyDecoder.decode(d, contentEncoding: "gzip").data == Data("hello".utf8))
    }

    @Test func brotliRoundTrip() {
        let plain = Data("hello hello hello".utf8)
        let br = encode(plain, algorithm: COMPRESSION_BROTLI)
        #expect(
            BodyDecoder.decode(br, contentEncoding: "br")
                == DecodedBody(data: plain, encoding: "br", error: nil))
    }

    @Test func deflateZlibWrapped() {
        let plain = Data("hello hello hello".utf8)
        let raw = encode(plain, algorithm: COMPRESSION_ZLIB)
        var wrapped = Data([0x78, 0x9c])
        wrapped.append(raw)
        wrapped.append(contentsOf: [0, 0, 0, 0])  // adler32 ignored
        #expect(
            BodyDecoder.decode(wrapped, contentEncoding: "deflate")
                == DecodedBody(data: plain, encoding: "deflate", error: nil))
    }

    @Test func deflateRaw() {
        let plain = Data("hello hello hello".utf8)
        let raw = encode(plain, algorithm: COMPRESSION_ZLIB)
        #expect(BodyDecoder.decode(raw, contentEncoding: "deflate").data == plain)
    }

    @Test func multipleCodingsDecodeInReverse() {
        // "gzip, br": gzip applied first, then br
        let br = encode(gz, algorithm: COMPRESSION_BROTLI)
        let r = BodyDecoder.decode(br, contentEncoding: "gzip, br")
        #expect(r.data == Data("hello".utf8))
        #expect(r.error == nil)
    }

    @Test func corruptGzipReturnsOriginalWithError() {
        var bad = gz
        bad.replaceSubrange(10..<14, with: [0xff, 0xff, 0xff, 0xff])
        let r = BodyDecoder.decode(bad, contentEncoding: "gzip")
        #expect(r.error == "解压失败（gzip）")
        #expect(r.data == bad)
        #expect(r.encoding == nil)
    }

    @Test func truncatedGzipHeaderFails() {
        let r = BodyDecoder.decode(Data([0x1f, 0x8b, 0x08]), contentEncoding: "gzip")
        #expect(r.error != nil)
        #expect(r.encoding == nil)
    }

    @Test func unknownEncodingPassThrough() {
        let d = Data("abc".utf8)
        #expect(
            BodyDecoder.decode(d, contentEncoding: "zstd")
                == DecodedBody(data: d, encoding: nil, error: "暂不支持的压缩格式：zstd"))
    }

    @Test func multipleCodingsWithUnsupportedReturnOriginal() {
        let r = BodyDecoder.decode(gz, contentEncoding: "zstd, gzip")
        // gzip (last) decodes first, then zstd is unsupported -> original returned
        #expect(r.data == gz)
        #expect(r.error == "暂不支持的压缩格式：zstd")
        #expect(r.encoding == nil)
    }

    @Test func identityAndNilPassThrough() {
        let d = Data("abc".utf8)
        let expected = DecodedBody(data: d, encoding: nil, error: nil)
        #expect(BodyDecoder.decode(d, contentEncoding: nil) == expected)
        #expect(BodyDecoder.decode(d, contentEncoding: "") == expected)
        #expect(BodyDecoder.decode(d, contentEncoding: " identity ") == expected)
    }

    @Test func outputCapIsEnforced() {
        // 101 MB of zeros compresses to a tiny deflate stream
        let plain = Data(count: 101 * 1024 * 1024)
        let raw = encode(plain, algorithm: COMPRESSION_ZLIB)
        let r = BodyDecoder.decode(raw, contentEncoding: "deflate")
        #expect(r.error == "解压后超过 100 MB，已停止")
        #expect(r.data == raw)
        #expect(r.encoding == nil)
    }
}

@Suite(.productionChinese) struct TextDecodingTests {
    private func gbk(_ s: String) -> Data {
        let enc = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        return s.data(using: String.Encoding(rawValue: enc))!
    }

    @Test func textDecodingCharset() {
        #expect(TextDecoding.string(from: gbk("中文"), contentType: "text/plain; charset=gbk") == "中文")
        #expect(
            TextDecoding.string(from: gbk("中文"), contentType: "text/plain; charset=\"GB2312\"")
                == "中文")
        #expect(TextDecoding.string(from: Data([0xff, 0xfe, 0xfd, 0x80, 0x81]), contentType: nil) == nil)
    }

    @Test func utf8DefaultAndBOM() {
        #expect(TextDecoding.string(from: Data("héllo".utf8), contentType: nil) == "héllo")
        let bom = Data([0xef, 0xbb, 0xbf]) + Data("hi".utf8)
        #expect(TextDecoding.string(from: bom, contentType: "text/plain") == "hi")
    }

    @Test func badCharsetFallsBackToUTF8() {
        #expect(
            TextDecoding.string(from: Data("hi".utf8), contentType: "text/plain; charset=nonsense")
                == "hi")
    }

    @Test func charsetDecodeFailureFallsBackToUTF8() {
        // valid UTF-8 that is not valid ASCII
        #expect(
            TextDecoding.string(from: Data("é".utf8), contentType: "text/plain; charset=us-ascii")
                == "é")
    }

    @Test func emptyData() {
        #expect(TextDecoding.string(from: Data(), contentType: "text/plain; charset=gbk") == "")
    }

    @Test func latin1() {
        #expect(
            TextDecoding.string(from: Data([0xe9]), contentType: "text/html; Charset=ISO-8859-1")
                == "é")
    }
}
