import Foundation

/// Which bodies are text, and a lossless text view of them. Decoding is strict (an invalid byte
/// throws) and a byte-order mark stays in the text as U+FEFF, so `encode(decode(data)) == data`
/// holds and a rewrite never touches bytes outside its matches.
public enum BodyTextCodec {
    public enum Failure: Error, Sendable, Equatable {
        case unsupportedCharset
        case invalidBytes
        case unencodable
    }

    private static let textTypes: Set<String> = [
        "application/json", "application/xml", "application/javascript", "application/x-javascript",
        "application/ecmascript", "application/x-www-form-urlencoded", "application/graphql", "image/svg+xml",
    ]
    private static let streamingTypes: Set<String> = [
        "text/event-stream", "application/x-ndjson", "application/stream+json", "multipart/x-mixed-replace",
    ]

    /// Decided from the media type alone; the body is never sniffed. Streaming types are excluded
    /// because they have no end to wait for.
    public static func isTextLike(contentType: String?) -> Bool {
        guard let type = mediaType(contentType), !type.isEmpty else { return false }
        if streamingTypes.contains(type) || type.hasPrefix("application/grpc") { return false }
        if type.hasPrefix("text/") || textTypes.contains(type) { return true }
        return type.hasPrefix("application/") && (type.hasSuffix("+json") || type.hasSuffix("+xml"))
    }

    /// The `charset` parameter (UTF-8 when absent). Nil for a charset this codec does not handle.
    public static func encoding(contentType: String?) -> String.Encoding? {
        guard let contentType else { return .utf8 }
        let parameters = contentType.split(separator: ";", omittingEmptySubsequences: false).dropFirst()
        for parameter in parameters {
            let pair = parameter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "charset" else {
                continue
            }
            let name = pair[1].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            switch name {
            case "utf-8", "utf8": return .utf8
            case "us-ascii", "ascii": return .ascii
            case "iso-8859-1", "iso8859-1", "iso_8859-1", "latin1": return .isoLatin1
            case "utf-16": return .utf16
            case "utf-16le": return .utf16LittleEndian
            case "utf-16be": return .utf16BigEndian
            default: return nil
            }
        }
        return .utf8
    }

    /// `.utf16` follows the byte-order mark of `data` (big endian without one, per RFC 2781);
    /// anything else is returned as is. Use the result for both `decode` and `encode` so a
    /// rewrite keeps the body's byte order.
    public static func resolvedEncoding(_ encoding: String.Encoding, for data: Data) -> String.Encoding {
        guard encoding == .utf16 else { return encoding }
        return data.starts(with: [0xff, 0xfe]) ? .utf16LittleEndian : .utf16BigEndian
    }

    public static func decode(_ data: Data, as encoding: String.Encoding) throws -> String {
        switch encoding {
        case .utf8:
            // Repairing decode, then proof that nothing was repaired (`String(validating:)` needs macOS 15).
            let text = String(decoding: data, as: UTF8.self)
            guard text.utf8.elementsEqual(data) else { throw Failure.invalidBytes }
            return text
        case .ascii:
            guard !data.contains(where: { $0 >= 0x80 }) else { throw Failure.invalidBytes }
            return String(decoding: data, as: UTF8.self)
        case .isoLatin1:
            var scalars = String.UnicodeScalarView()
            scalars.append(contentsOf: data.lazy.map { Unicode.Scalar($0) })
            return String(scalars)
        case .utf16, .utf16LittleEndian, .utf16BigEndian:
            guard data.count.isMultiple(of: 2) else { throw Failure.invalidBytes }
            let littleEndian = resolvedEncoding(encoding, for: data) == .utf16LittleEndian
            var units: [UInt16] = []
            units.reserveCapacity(data.count / 2)
            var index = data.startIndex
            while index < data.endIndex {
                let first = UInt16(data[index]), second = UInt16(data[index + 1])
                units.append(littleEndian ? first | (second << 8) : (first << 8) | second)
                index += 2
            }
            let text = String(decoding: units, as: UTF16.self)
            guard text.utf16.elementsEqual(units) else { throw Failure.invalidBytes }
            return text
        default:
            throw Failure.unsupportedCharset
        }
    }

    /// `.utf16` writes little endian when the text starts with a byte-order mark and big endian
    /// otherwise; resolve the encoding with `resolvedEncoding` first to keep a big-endian body big endian.
    public static func encode(_ text: String, as encoding: String.Encoding) throws -> Data {
        switch encoding {
        case .utf8:
            return Data(text.utf8)
        case .ascii:
            var bytes: [UInt8] = []
            bytes.reserveCapacity(text.utf8.count)
            for byte in text.utf8 {
                guard byte < 0x80 else { throw Failure.unencodable }
                bytes.append(byte)
            }
            return Data(bytes)
        case .isoLatin1:
            var bytes: [UInt8] = []
            bytes.reserveCapacity(text.unicodeScalars.count)
            for scalar in text.unicodeScalars {
                guard scalar.value <= 0xff else { throw Failure.unencodable }
                bytes.append(UInt8(scalar.value))
            }
            return Data(bytes)
        case .utf16, .utf16LittleEndian, .utf16BigEndian:
            let littleEndian: Bool
            switch encoding {
            case .utf16LittleEndian: littleEndian = true
            case .utf16BigEndian: littleEndian = false
            default: littleEndian = text.unicodeScalars.first == "\u{feff}"
            }
            var bytes: [UInt8] = []
            bytes.reserveCapacity(text.utf16.count * 2)
            for unit in text.utf16 {
                let low = UInt8(unit & 0xff), high = UInt8(unit >> 8)
                if littleEndian { bytes.append(low); bytes.append(high) } else { bytes.append(high); bytes.append(low) }
            }
            return Data(bytes)
        default:
            throw Failure.unsupportedCharset
        }
    }

    private static func mediaType(_ contentType: String?) -> String? {
        guard let contentType else { return nil }
        let head = contentType.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
        return head.trimmingCharacters(in: .whitespaces).lowercased()
    }
}
