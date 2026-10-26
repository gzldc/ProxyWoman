import Compression
import Foundation
import Localization

public struct DecodedBody: Sendable, Equatable {
    public var data: Data
    public var encoding: String?
    public var error: String?

    public init(data: Data, encoding: String?, error: String?) {
        self.data = data
        self.encoding = encoding
        self.error = error
    }
}

/// 按 Content-Encoding 解压 Body（gzip / x-gzip / deflate / br）。
public enum BodyDecoder {
    public static let outputLimit = 100 * 1024 * 1024

    private enum Failure: Error {
        case unsupported(String)
        case corrupt(String)
        case tooLarge
    }

    /// Every decoding stage stops (with an error, returning `data` unchanged) once its output
    /// exceeds `maxOutputBytes`, so a caller can bound the memory a decode may take.
    public static func decode(_ data: Data, contentEncoding: String?, maxOutputBytes: Int = outputLimit) -> DecodedBody {
        let codings = (contentEncoding ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && $0 != "identity" }
        guard !codings.isEmpty else { return DecodedBody(data: data, encoding: nil, error: nil) }

        var current = data
        var applied: [String] = []
        do {
            for coding in codings.reversed() {
                let name = coding == "x-gzip" ? "gzip" : coding
                current = try decodeOne(current, coding: name, limit: maxOutputBytes)
                applied.insert(name, at: 0)
            }
        } catch let failure as Failure {
            let message: String
            switch failure {
            case .unsupported(let name): message = L10n.format("bodyDecoder.unsupportedEncoding", name)
            case .corrupt(let name): message = L10n.format("bodyDecoder.corruptEncoding", name)
            case .tooLarge: message = L10n.string("bodyDecoder.outputLimit")
            }
            return DecodedBody(data: data, encoding: nil, error: message)
        } catch {
            return DecodedBody(data: data, encoding: nil, error: L10n.string("bodyDecoder.decodeFailed"))
        }
        return DecodedBody(data: current, encoding: applied.joined(separator: ", "), error: nil)
    }

    private static func decodeOne(_ data: Data, coding: String, limit: Int) throws -> Data {
        switch coding {
        case "gzip":
            guard let start = gzipPayloadStart(data) else { throw Failure.corrupt(coding) }
            return try inflate(data.dropFirst(start), algorithm: COMPRESSION_ZLIB, name: coding, limit: limit)
        case "deflate":
            var payload = data[...]
            if data.count >= 2 {
                let b0 = Int(data[data.startIndex])
                let b1 = Int(data[data.startIndex + 1])
                if b0 & 0x0f == 8 && ((b0 << 8) | b1) % 31 == 0 { payload = data.dropFirst(2) }
            }
            return try inflate(payload, algorithm: COMPRESSION_ZLIB, name: coding, limit: limit)
        case "br":
            return try inflate(data[...], algorithm: COMPRESSION_BROTLI, name: coding, limit: limit)
        default:
            throw Failure.unsupported(coding)
        }
    }

    /// 解析 gzip 头（RFC 1952），返回原始 deflate 数据的起始偏移；头不合法返回 nil。
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
            guard let zero = b[min(pos, b.count)...].firstIndex(of: 0) else { return nil }
            pos = zero + 1
        }
        if flags & 0x02 != 0 { pos += 2 }  // FHCRC
        return pos < b.count ? pos : nil
    }

    private static func inflate(
        _ input: Data.SubSequence, algorithm: compression_algorithm, name: String, limit: Int
    ) throws -> Data {
        guard !input.isEmpty else { throw Failure.corrupt(name) }

        let chunkSize = 64 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { dst.deallocate() }
        let streamPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPtr.deallocate() }
        streamPtr.initialize(
            to: compression_stream(
                dst_ptr: dst, dst_size: 0, src_ptr: UnsafePointer(dst), src_size: 0, state: nil))
        guard
            compression_stream_init(streamPtr, COMPRESSION_STREAM_DECODE, algorithm)
                == COMPRESSION_STATUS_OK
        else { throw Failure.corrupt(name) }
        defer { compression_stream_destroy(streamPtr) }

        var output = Data()
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            streamPtr.pointee.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress!
            streamPtr.pointee.src_size = raw.count
            while true {
                streamPtr.pointee.dst_ptr = dst
                streamPtr.pointee.dst_size = chunkSize
                let srcBefore = streamPtr.pointee.src_size
                let status = compression_stream_process(
                    streamPtr, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunkSize - streamPtr.pointee.dst_size
                if produced > 0 {
                    guard output.count + produced <= limit else { throw Failure.tooLarge }
                    output.append(dst, count: produced)
                }
                switch status {
                case COMPRESSION_STATUS_END:
                    return
                case COMPRESSION_STATUS_OK:
                    if produced == 0 && streamPtr.pointee.src_size == srcBefore {
                        throw Failure.corrupt(name)
                    }
                default:
                    throw Failure.corrupt(name)
                }
            }
        }
        return output
    }
}
