import Compression
import Foundation
import Testing

@testable import RulesEngine

/// Builds compressed fixtures with the same system framework the decoder uses.
enum TestCompression {
    static func rawDeflate(_ data: Data) -> Data { compress(data, algorithm: COMPRESSION_ZLIB) }
    static func brotli(_ data: Data) -> Data { compress(data, algorithm: COMPRESSION_BROTLI) }

    static func zlibWrapped(_ data: Data) -> Data {
        var out = Data([0x78, 0x9c])
        out.append(rawDeflate(data))
        out.append(contentsOf: bigEndian(adler32(data)))
        return out
    }

    static func gzip(_ data: Data) -> Data {
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03])
        out.append(rawDeflate(data))
        out.append(contentsOf: littleEndian(crc32(data)))
        out.append(contentsOf: littleEndian(UInt32(truncatingIfNeeded: data.count)))
        return out
    }

    /// A gzip member with a caller-chosen trailer, for corruption fixtures.
    static func gzip(_ data: Data, crc: UInt32? = nil, isize: UInt32? = nil) -> Data {
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03])
        out.append(rawDeflate(data))
        out.append(contentsOf: littleEndian(crc ?? crc32(data)))
        out.append(contentsOf: littleEndian(isize ?? UInt32(truncatingIfNeeded: data.count)))
        return out
    }

    private static func compress(_ data: Data, algorithm: compression_algorithm) -> Data {
        let capacity = data.count * 2 + 1024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }
        let written = data.withUnsafeBytes { raw -> Int in
            let source = raw.bindMemory(to: UInt8.self).baseAddress
                ?? UnsafePointer(bitPattern: 1)!  // empty input has no base address
            return compression_encode_buffer(destination, capacity, source, data.count, nil, algorithm)
        }
        precondition(written > 0 || data.isEmpty, "test fixture compression failed")
        return Data(bytes: destination, count: written)
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xedb8_8320 & (0 &- (crc & 1))) }
        }
        return ~crc
    }

    static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }

    static func littleEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xff), UInt8((value >> 8) & 0xff), UInt8((value >> 16) & 0xff), UInt8(value >> 24)]
    }

    static func bigEndian(_ value: UInt32) -> [UInt8] { littleEndian(value).reversed() }
}

@Suite("BodyContentCodec")
struct BodyContentCodecTests {
    private let plain = Data(String(repeating: "hello body, ", count: 50).utf8)
    private let limit = 1 << 20

    @Test func decodesGzip() throws {
        let out = try BodyContentCodec.decode(TestCompression.gzip(plain), contentEncoding: "gzip", maxOutputBytes: limit)
        #expect(out == plain)
        let alias = try BodyContentCodec.decode(TestCompression.gzip(plain), contentEncoding: " X-GZIP ", maxOutputBytes: limit)
        #expect(alias == plain)
    }

    @Test func decodesDeflateZlibWrapped() throws {
        let out = try BodyContentCodec.decode(
            TestCompression.zlibWrapped(plain), contentEncoding: "deflate", maxOutputBytes: limit)
        #expect(out == plain)
    }

    @Test func decodesDeflateRaw() throws {
        let out = try BodyContentCodec.decode(
            TestCompression.rawDeflate(plain), contentEncoding: "deflate", maxOutputBytes: limit)
        #expect(out == plain)
    }

    @Test func decodesBrotli() throws {
        let out = try BodyContentCodec.decode(TestCompression.brotli(plain), contentEncoding: "br", maxOutputBytes: limit)
        #expect(out == plain)
    }

    @Test func stackedEncodingsDecodeInReverseOrder() throws {
        // `Content-Encoding: gzip, br` means gzip was applied first and br last.
        let stacked = TestCompression.brotli(TestCompression.gzip(plain))
        let out = try BodyContentCodec.decode(stacked, contentEncoding: "gzip, br", maxOutputBytes: limit)
        #expect(out == plain)
        let wrongOrder = try? BodyContentCodec.decode(stacked, contentEncoding: "br, gzip", maxOutputBytes: limit)
        #expect(wrongOrder != plain)
    }

    @Test func identityAndNilPassThrough() throws {
        #expect(try BodyContentCodec.decode(plain, contentEncoding: nil, maxOutputBytes: limit) == plain)
        #expect(try BodyContentCodec.decode(plain, contentEncoding: "", maxOutputBytes: limit) == plain)
        #expect(try BodyContentCodec.decode(plain, contentEncoding: "identity", maxOutputBytes: limit) == plain)
        #expect(try BodyContentCodec.decode(plain, contentEncoding: "Identity, ", maxOutputBytes: limit) == plain)
    }

    @Test func emptyInputYieldsEmptyOutput() throws {
        #expect(try BodyContentCodec.decode(Data(), contentEncoding: "gzip", maxOutputBytes: limit).isEmpty)
        #expect(try BodyContentCodec.decode(Data(), contentEncoding: "br", maxOutputBytes: limit).isEmpty)
        #expect(try BodyContentCodec.decode(Data(), contentEncoding: nil, maxOutputBytes: limit).isEmpty)
    }

    @Test func unknownEncodingThrowsUnsupported() {
        #expect(throws: BodyContentCodec.Failure.unsupported("zstd")) {
            try BodyContentCodec.decode(plain, contentEncoding: "zstd", maxOutputBytes: limit)
        }
    }

    @Test func corruptDataThrowsCorrupt() {
        let garbage = Data((0..<64).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) })
        for coding in ["gzip", "deflate", "br"] {
            #expect(throws: BodyContentCodec.Failure.corrupt) {
                try BodyContentCodec.decode(garbage, contentEncoding: coding, maxOutputBytes: limit)
            }
        }
        // A truncated stream is corrupt, not a short success.
        let truncated = TestCompression.gzip(plain).dropLast(12)
        #expect(throws: BodyContentCodec.Failure.corrupt) {
            try BodyContentCodec.decode(Data(truncated), contentEncoding: "gzip", maxOutputBytes: limit)
        }
    }

    @Test func outputOverLimitThrowsTooLarge() {
        let bomb = TestCompression.gzip(Data(count: 1 << 20))
        #expect(bomb.count < 4096)
        #expect(throws: BodyContentCodec.Failure.tooLarge) {
            try BodyContentCodec.decode(bomb, contentEncoding: "gzip", maxOutputBytes: 64 * 1024)
        }
        // Exactly at the limit is fine.
        #expect(throws: Never.self) {
            try BodyContentCodec.decode(bomb, contentEncoding: "gzip", maxOutputBytes: 1 << 20)
        }
    }

    @Test func singleMemberStillDecodes() throws {
        let out = try BodyContentCodec.decode(TestCompression.gzip(plain), contentEncoding: "gzip", maxOutputBytes: limit)
        #expect(out == plain)
        let explicit = TestCompression.gzip(plain, crc: nil, isize: nil)
        #expect(try BodyContentCodec.decode(explicit, contentEncoding: "gzip", maxOutputBytes: limit) == plain)
    }

    @Test func multiMemberGzipThrowsCorrupt() {
        let joined = TestCompression.gzip(Data("first ".utf8)) + TestCompression.gzip(Data("second".utf8))
        #expect(throws: BodyContentCodec.Failure.corrupt) {
            try BodyContentCodec.decode(joined, contentEncoding: "gzip", maxOutputBytes: limit)
        }
    }

    @Test func trailingGarbageAfterGzipThrowsCorrupt() {
        let padded = TestCompression.gzip(plain) + Data([0, 0, 0, 0])
        #expect(throws: BodyContentCodec.Failure.corrupt) {
            try BodyContentCodec.decode(padded, contentEncoding: "gzip", maxOutputBytes: limit)
        }
    }

    @Test func wrongISIZEThrowsCorrupt() {
        let bad = TestCompression.gzip(plain, isize: UInt32(plain.count) + 1)
        #expect(throws: BodyContentCodec.Failure.corrupt) {
            try BodyContentCodec.decode(bad, contentEncoding: "gzip", maxOutputBytes: limit)
        }
    }

    @Test func wrongCRCThrowsCorrupt() {
        let bad = TestCompression.gzip(plain, crc: 0xdead_beef)
        #expect(throws: BodyContentCodec.Failure.corrupt) {
            try BodyContentCodec.decode(bad, contentEncoding: "gzip", maxOutputBytes: limit)
        }
    }

    @Test func trailingBytesAfterDeflateAndBrotliThrowCorrupt() {
        let extra = Data([1, 2, 3, 4, 5, 6, 7, 8, 9])
        for (coding, body) in [
            ("deflate", TestCompression.rawDeflate(plain) + extra),
            ("deflate", TestCompression.zlibWrapped(plain) + extra),
            ("br", TestCompression.brotli(plain) + extra),
        ] {
            #expect(throws: BodyContentCodec.Failure.corrupt, "\(coding)") {
                try BodyContentCodec.decode(body, contentEncoding: coding, maxOutputBytes: limit)
            }
        }
    }

    @Test func hasRealEncodingIgnoresIdentity() {
        #expect(!BodyContentCodec.hasRealEncoding(nil))
        #expect(!BodyContentCodec.hasRealEncoding(""))
        #expect(!BodyContentCodec.hasRealEncoding("identity"))
        #expect(!BodyContentCodec.hasRealEncoding(" Identity , "))
        #expect(BodyContentCodec.hasRealEncoding("gzip"))
        #expect(BodyContentCodec.hasRealEncoding("identity, br"))
        #expect(BodyContentCodec.hasRealEncoding("zstd"))
    }
}
