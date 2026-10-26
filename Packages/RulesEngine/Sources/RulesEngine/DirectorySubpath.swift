import Foundation

/// The path below a Map Local directory prefix, resolved to safe segments or rejected as a whole.
/// Pure and total: every input is either `.safe` or `.unsafe`.
public enum DirectorySubpath: Sendable, Equatable {
    /// Decoded segments; an empty array is the directory root.
    case safe([String])
    /// Traversal, an encoded separator, a control byte (NUL, CR, LF, DEL, ...), a dot file, invalid UTF-8 or a malformed escape.
    case unsafe

    static let maxSegmentBytes = 255

    /// `prefix` must be a prefix of `pathAndQuery`; otherwise the result is `.unsafe`.
    public static func resolve(pathAndQuery: String, prefix: String) -> DirectorySubpath {
        let path = Array(pathAndQuery.utf8)
        let head = Array(prefix.utf8)
        guard path.starts(with: head) else { return .unsafe }
        var rest = path[head.count...]
        if let query = rest.firstIndex(of: UInt8(ascii: "?")) { rest = rest[..<query] }
        var segments: [String] = []
        for raw in rest.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: true) {
            guard let segment = decode(raw) else { return .unsafe }
            segments.append(segment)
        }
        return .safe(segments)
    }

    /// Strict percent decoding of one segment, then the F3 acceptance checks; nil = unsafe.
    private static func decode(_ raw: ArraySlice<UInt8>) -> String? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(raw.count)
        var index = raw.startIndex
        while index < raw.endIndex {
            let byte = raw[index]
            if byte == UInt8(ascii: "%") {
                guard index + 2 < raw.endIndex,
                    let high = hexValue(raw[index + 1]), let low = hexValue(raw[index + 2])
                else { return nil }
                bytes.append(high << 4 | low)
                index += 3
            } else {
                bytes.append(byte)
                index += 1
            }
        }
        guard !bytes.isEmpty, bytes.count <= maxSegmentBytes, bytes.first != UInt8(ascii: "."),
            !bytes.contains(where: { $0 < 0x20 || $0 == 0x7F }), !bytes.contains(UInt8(ascii: "/")), !bytes.contains(UInt8(ascii: "\\")),
            let text = String(bytes: bytes, encoding: .utf8)
        else { return nil }
        return text
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}
