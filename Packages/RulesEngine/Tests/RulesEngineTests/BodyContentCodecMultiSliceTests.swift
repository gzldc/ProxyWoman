import Foundation
import Testing

@testable import RulesEngine

/// The decoder locates the end of a zlib/deflate stream in 4 KiB slices and then replays the last
/// slice byte by byte. Every other codec test has compressed input under 4 KiB, which never leaves
/// the first slice; these tests exercise the slice loop and the replay prefix.
extension TestCompression {
    /// A raw deflate stream made of one stored block, so its length is exactly `data.count + 5`.
    static func storedDeflate(_ data: Data) -> Data {
        precondition(data.count <= 0xffff)
        let length = UInt16(data.count)
        var out = Data([0x01, UInt8(length & 0xff), UInt8(length >> 8), UInt8(~length & 0xff), UInt8(~length >> 8)])
        out.append(data)
        return out
    }

    static func gzipWrapping(deflate: Data, of data: Data) -> Data {
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03])
        out.append(deflate)
        out.append(contentsOf: littleEndian(crc32(data)))
        out.append(contentsOf: littleEndian(UInt32(truncatingIfNeeded: data.count)))
        return out
    }

    static func zlibWrapping(deflate: Data, of data: Data) -> Data {
        var out = Data([0x78, 0x01])
        out.append(deflate)
        out.append(contentsOf: bigEndian(adler32(data)))
        return out
    }
}

/// Text that deflate cannot shrink much: deterministic, base64-like, so a ~100 KiB page stays well
/// above 64 KiB compressed.
func noisyText(bytes: Int, seed: UInt64 = 42) -> Data {
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
    var state = seed
    var out = Data(capacity: bytes)
    for _ in 0..<bytes {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        out.append(alphabet[Int((state >> 33) % 64)])
    }
    return out
}

private let sliceBytes = 4096

@Suite("BodyContentCodec multi-slice input")
struct BodyContentCodecMultiSliceTests {
    private let limit = 4 << 20
    private let page = noisyText(bytes: 160 * 1024)

    private func encoded(_ plain: Data) -> [(coding: String, body: Data)] {
        [
            ("gzip", TestCompression.gzip(plain)),
            ("deflate", TestCompression.zlibWrapped(plain)),
            ("deflate", TestCompression.rawDeflate(plain)),
            ("br", TestCompression.brotli(plain)),
        ]
    }

    @Test func largeCompressedInputRoundTripsForEveryCoding() throws {
        for (coding, body) in encoded(page) {
            #expect(body.count >= 64 * 1024, "\(coding) fixture is multi-slice (\(body.count) bytes)")
            let out = try BodyContentCodec.decode(body, contentEncoding: coding, maxOutputBytes: limit)
            #expect(out == page, "\(coding)")
        }
    }

    @Test func compressedInputJustOverOneSliceRoundTrips() throws {
        let plain = noisyText(bytes: 6200, seed: 7)
        for (coding, body) in encoded(plain) {
            #expect(body.count > sliceBytes && body.count < 2 * sliceBytes, "\(coding) \(body.count)")
            #expect(try BodyContentCodec.decode(body, contentEncoding: coding, maxOutputBytes: limit) == plain, "\(coding)")
        }
    }

    @Test func realisticMarkupPageRoundTrips() throws {
        var html = "<!doctype html><html><head><title>Shop</title></head><body>\n"
        for index in 0..<2500 {
            html += "<div class=\"item\" id=\"i\(index * 7919 % 100_003)\"><a href=\"/p/\(index * 31 % 9973)\">Item \(index)</a>"
                + "<span data-token=\"\(String(index &* 2_654_435_761, radix: 36))\">$\(index % 97).99</span></div>\n"
        }
        html += "</body></html>"
        let plain = Data(html.utf8)
        for (coding, body) in encoded(plain) {
            #expect(body.count > 3 * sliceBytes, "\(coding) \(body.count)")
            #expect(try BodyContentCodec.decode(body, contentEncoding: coding, maxOutputBytes: limit) == plain, "\(coding)")
        }
    }

    @Test func deflateEndingExactlyOnSliceBoundariesDecodes() throws {
        // The deflate stream is `data + 5` bytes; gzip/zlib append a trailer after it, raw deflate ends with it.
        for boundary in [2, 3, 16] {
            for delta in [-1, 0, 1] {
                let deflateLength = boundary * sliceBytes + delta
                let plain = noisyText(bytes: deflateLength - 5, seed: UInt64(boundary))
                let stored = TestCompression.storedDeflate(plain)
                #expect(stored.count == deflateLength)
                let label = "end at \(boundary)x4096\(delta >= 0 ? "+" : "")\(delta)"
                #expect(try BodyContentCodec.decode(stored, contentEncoding: "deflate", maxOutputBytes: limit) == plain, "raw \(label)")
                let zlib = TestCompression.zlibWrapping(deflate: stored, of: plain)
                #expect(try BodyContentCodec.decode(zlib, contentEncoding: "deflate", maxOutputBytes: limit) == plain, "zlib \(label)")
                let gzip = TestCompression.gzipWrapping(deflate: stored, of: plain)
                #expect(try BodyContentCodec.decode(gzip, contentEncoding: "gzip", maxOutputBytes: limit) == plain, "gzip \(label)")
            }
        }
    }

    @Test func trailingBytesAfterAnEndOnASliceBoundaryAreCorrupt() {
        let plain = noisyText(bytes: 3 * sliceBytes - 5)
        let stored = TestCompression.storedDeflate(plain)
        #expect(stored.count == 3 * sliceBytes)
        #expect(throws: BodyContentCodec.Failure.corrupt) {
            try BodyContentCodec.decode(stored + Data([1]), contentEncoding: "deflate", maxOutputBytes: limit)
        }
        #expect(throws: BodyContentCodec.Failure.corrupt) {
            try BodyContentCodec.decode(
                TestCompression.gzipWrapping(deflate: stored, of: plain) + Data([0]), contentEncoding: "gzip", maxOutputBytes: limit)
        }
    }

    @Test func secondGzipMemberStartingInALaterSliceIsCorrupt() {
        let firstPlain = noisyText(bytes: 6000, seed: 1)
        let first = TestCompression.gzip(firstPlain)
        #expect(first.count > sliceBytes + 8, "the second member starts in the second slice")
        let joined = first + TestCompression.gzip(noisyText(bytes: 9000, seed: 2))
        #expect(throws: BodyContentCodec.Failure.corrupt) {
            try BodyContentCodec.decode(joined, contentEncoding: "gzip", maxOutputBytes: limit)
        }
        // A large member followed by a small one.
        let big = TestCompression.gzip(page) + TestCompression.gzip(Data("tail".utf8))
        #expect(throws: BodyContentCodec.Failure.corrupt) {
            try BodyContentCodec.decode(big, contentEncoding: "gzip", maxOutputBytes: limit)
        }
    }

    @Test func trailingDataAfterALargeStreamIsCorruptForEveryCoding() {
        let tails = [Data([0]), Data(repeating: 0xab, count: 9), Data(repeating: 0, count: 3 * sliceBytes + 11)]
        for (coding, body) in encoded(page) {
            for tail in tails {
                #expect(throws: BodyContentCodec.Failure.corrupt, "\(coding) +\(tail.count)") {
                    try BodyContentCodec.decode(body + tail, contentEncoding: coding, maxOutputBytes: limit)
                }
            }
        }
    }

    @Test func largeZlibWithBadAdlerOrMissingTrailerBehavesAsInTheSmallPath() throws {
        let deflate = TestCompression.rawDeflate(page)
        var bad = Data([0x78, 0x9c]) + deflate
        bad.append(contentsOf: [0, 0, 0, 1])
        #expect(throws: BodyContentCodec.Failure.corrupt) {
            try BodyContentCodec.decode(bad, contentEncoding: "deflate", maxOutputBytes: limit)
        }
        // Some servers omit the Adler-32; the stream still decodes.
        let omitted = Data([0x78, 0x9c]) + deflate
        #expect(try BodyContentCodec.decode(omitted, contentEncoding: "deflate", maxOutputBytes: limit) == page)
    }

    @Test func largeTruncatedStreamIsCorruptAndLargeOutputOverTheLimitIsTooLarge() {
        for (coding, body) in encoded(page) {
            #expect(throws: BodyContentCodec.Failure.corrupt, "\(coding) truncated") {
                try BodyContentCodec.decode(body.dropLast(body.count / 2), contentEncoding: coding, maxOutputBytes: limit)
            }
            #expect(throws: BodyContentCodec.Failure.tooLarge, "\(coding) limit") {
                try BodyContentCodec.decode(body, contentEncoding: coding, maxOutputBytes: page.count - 1)
            }
        }
    }
}
