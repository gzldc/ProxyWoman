import Compression
import Foundation

/// Foundation-only `Content-Encoding` decoding with an output cap, used when a rule rewrites a
/// body. `Viewers.BodyDecoder` decodes for display (and needs Localization); the stream loop
/// below mirrors its core so RulesEngine stays free of that dependency.
public enum BodyContentCodec {
    public enum Failure: Error, Sendable, Equatable {
        case unsupported(String)
        case corrupt
        case tooLarge
    }

    /// Decodes `data` through every coding in `contentEncoding`, last one applied first.
    /// Empty or `identity` encodings return `data` as is, and so does empty input. Every stage
    /// stops with `.tooLarge` once its output passes `maxOutputBytes`.
    public static func decode(_ data: Data, contentEncoding: String?, maxOutputBytes: Int) throws -> Data {
        let codings = realCodings(contentEncoding)
        for coding in codings where !["gzip", "deflate", "br"].contains(coding) {
            throw Failure.unsupported(coding)
        }
        var current = data
        for coding in codings.reversed() {
            guard !current.isEmpty else { return current }
            current = try decodeOne(current, coding: coding, limit: maxOutputBytes)
        }
        return current
    }

    /// True when the header names a coding other than `identity`.
    public static func hasRealEncoding(_ contentEncoding: String?) -> Bool {
        !realCodings(contentEncoding).isEmpty
    }

    private static func realCodings(_ contentEncoding: String?) -> [String] {
        (contentEncoding ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && $0 != "identity" }
            .map { $0 == "x-gzip" ? "gzip" : $0 }
    }

    private static func decodeOne(_ data: Data, coding: String, limit: Int) throws -> Data {
        switch coding {
        case "gzip":
            guard let start = gzipPayloadStart(data) else { throw Failure.corrupt }
            let payload = data.dropFirst(start)
            let (output, unread) = try inflate(payload, algorithm: COMPRESSION_ZLIB, limit: limit)
            // Exactly the RFC 1952 trailer (CRC32, ISIZE) may follow. Anything more is another
            // gzip member or garbage, which this single-stream decoder would silently drop.
            guard unread == 8 else { throw Failure.corrupt }
            let trailer = [UInt8](payload.suffix(8))
            guard le32(trailer, 0) == crc32(output), le32(trailer, 4) == UInt32(truncatingIfNeeded: output.count) else {
                throw Failure.corrupt
            }
            return output
        case "deflate":
            var payload = data[...]
            var zlibWrapped = false
            // Servers send both zlib-wrapped and raw deflate; a valid zlib header marks the former.
            if data.count >= 2 {
                let b0 = Int(data[data.startIndex])
                let b1 = Int(data[data.startIndex + 1])
                if b0 & 0x0f == 8 && ((b0 << 8) | b1) % 31 == 0 {
                    payload = data.dropFirst(2)
                    zlibWrapped = true
                }
            }
            let (output, unread) = try inflate(payload, algorithm: COMPRESSION_ZLIB, limit: limit)
            // A zlib stream may end with its 4-byte Adler-32 (some servers omit it); raw deflate
            // ends with the stream. Any other leftover input is corrupt.
            if zlibWrapped && unread == 4 {
                let trailer = [UInt8](payload.suffix(4))
                guard be32(trailer) == adler32(output) else { throw Failure.corrupt }
            } else if unread != 0 {
                throw Failure.corrupt
            }
            return output
        case "br":
            let (output, unread) = try inflate(data[...], algorithm: COMPRESSION_BROTLI, limit: limit)
            guard unread == 0 else { throw Failure.corrupt }
            return output
        default:
            throw Failure.unsupported(coding)
        }
    }

    /// Offset of the raw deflate data after the RFC 1952 header; nil when the header is invalid.
    private static func gzipPayloadStart(_ data: Data) -> Int? {
        let b = [UInt8](data)
        guard b.count >= 18, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else { return nil }
        let flags = b[3]
        var pos = 10
        if flags & 0x04 != 0 {  // FEXTRA
            guard pos + 2 <= b.count else { return nil }
            pos += 2 + Int(b[pos]) + (Int(b[pos + 1]) << 8)
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {  // FNAME, FCOMMENT
            guard pos < b.count, let zero = b[pos...].firstIndex(of: 0) else { return nil }
            pos = zero + 1
        }
        if flags & 0x02 != 0 { pos += 2 }  // FHCRC
        return pos < b.count ? pos : nil
    }

    private static func le32(_ b: [UInt8], _ at: Int) -> UInt32 {
        UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
    }

    private static func be32(_ b: [UInt8]) -> UInt32 {
        UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xedb8_8320 & (0 &- (crc & 1))) }
        }
        return ~crc
    }

    private static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }

    private static let outputChunk = 64 * 1024
    /// Input slice size for locating the end of a zlib/deflate stream (see `inflate`).
    private static let probeChunk = 4 * 1024

    /// Inflates one stream and also returns how many input bytes were left unread after its end.
    ///
    /// Apple's brotli decoder reports the unread input exactly, but its zlib decoder swallows the
    /// whole slice it was handed. For zlib the end is therefore found by feeding 4 KiB slices
    /// until the stream ends, then replaying that last slice one byte at a time.
    private static func inflate(
        _ input: Data.SubSequence, algorithm: compression_algorithm, limit: Int
    ) throws -> (output: Data, unread: Int) {
        guard !input.isEmpty else { throw Failure.corrupt }
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: outputChunk)
        defer { dst.deallocate() }
        let isBrotli = algorithm == COMPRESSION_BROTLI

        return try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { throw Failure.corrupt }
            var output = Data()
            let collect: (Int) throws -> Void = { produced in
                guard output.count + produced <= limit else { throw Failure.tooLarge }
                output.append(dst, count: produced)
            }

            if isBrotli {
                let unread = try withDecoder(algorithm, dst) { stream in
                    let ended = try drive(
                        stream, dst, base, raw.count, flags: Int32(COMPRESSION_STREAM_FINALIZE.rawValue), sink: collect)
                    guard ended else { throw Failure.corrupt }
                    return stream.pointee.src_size
                }
                return (output, unread)
            }

            // Pass 1: slice by slice until the stream ends; remember which slice held the end.
            var sliceStart = 0, sliceLength = 0
            var ended = false
            try withDecoder(algorithm, dst) { stream in
                var offset = 0
                while offset < raw.count, !ended {
                    let length = min(probeChunk, raw.count - offset)
                    ended = try drive(stream, dst, base + offset, length, flags: 0, sink: collect)
                    if ended { sliceStart = offset; sliceLength = length }
                    offset += length
                }
            }
            guard ended else { throw Failure.corrupt }

            // Pass 2: replay up to that slice, then byte by byte to learn the exact end.
            let consumed: Int = try withDecoder(algorithm, dst) { stream in
                if sliceStart > 0 {
                    guard try !drive(stream, dst, base, sliceStart, flags: 0, sink: { _ in }) else {
                        throw Failure.corrupt
                    }
                }
                for index in sliceStart..<(sliceStart + sliceLength)
                where try drive(stream, dst, base + index, 1, flags: 0, sink: { _ in }) {
                    return index + 1
                }
                throw Failure.corrupt
            }
            return (output, raw.count - consumed)
        }
    }

    private static func withDecoder<T>(
        _ algorithm: compression_algorithm, _ dst: UnsafeMutablePointer<UInt8>,
        _ body: (UnsafeMutablePointer<compression_stream>) throws -> T
    ) throws -> T {
        let streamPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPtr.deallocate() }
        streamPtr.initialize(
            to: compression_stream(dst_ptr: dst, dst_size: 0, src_ptr: UnsafePointer(dst), src_size: 0, state: nil))
        guard compression_stream_init(streamPtr, COMPRESSION_STREAM_DECODE, algorithm) == COMPRESSION_STATUS_OK else {
            throw Failure.corrupt
        }
        defer { compression_stream_destroy(streamPtr) }
        return try body(streamPtr)
    }

    /// Feeds `count` bytes and drains the output. True when the stream ended; false when it wants
    /// more input (a `FINALIZE` caller treats false as truncated). A stall with input left is corrupt.
    private static func drive(
        _ stream: UnsafeMutablePointer<compression_stream>, _ dst: UnsafeMutablePointer<UInt8>,
        _ src: UnsafePointer<UInt8>, _ count: Int, flags: Int32, sink: (Int) throws -> Void
    ) throws -> Bool {
        stream.pointee.src_ptr = src
        stream.pointee.src_size = count
        while true {
            stream.pointee.dst_ptr = dst
            stream.pointee.dst_size = outputChunk
            let srcBefore = stream.pointee.src_size
            let status = compression_stream_process(stream, flags)
            let produced = outputChunk - stream.pointee.dst_size
            if produced > 0 { try sink(produced) }
            switch status {
            case COMPRESSION_STATUS_END:
                return true
            case COMPRESSION_STATUS_OK:
                if produced == 0 && stream.pointee.src_size == srcBefore {
                    if flags == 0 && srcBefore == 0 { return false }
                    throw Failure.corrupt
                }
            default:
                throw Failure.corrupt
            }
        }
    }
}
