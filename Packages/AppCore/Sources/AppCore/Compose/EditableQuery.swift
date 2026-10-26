import Foundation

/// A URL query kept as the exact bytes it was written with. The rows are only a view: `rawValue`
/// is always the original segments joined by `&` — order, duplicates, empty and doubled segments,
/// a missing `=`, `+`, every percent escape (`%2F` and `%2f` alike) and non-ASCII text stay
/// untouched. Each segment keeps its name and value bytes separately: editing one cell encodes
/// only that half (`setName` / `setValue`); the other half and the `=` stay byte for byte.
/// Within the edited half only the characters the user changed are encoded: the unchanged text
/// before and after the edit keeps its exact bytes (`a%2Bb` → `a%2Bbc`, never `a+bc`), and text
/// typed back to the half's original text restores its original bytes.
public struct EditableQuery: Equatable, Sendable {
    /// One `name[=value]` segment. `name`/`value` are what the table shows: percent escapes
    /// decoded (text that does not decode is shown as written), `+` shown as `+`. After an edit
    /// the edited half is exactly what the user typed.
    public struct Row: Identifiable, Equatable, Sendable {
        public let id: UUID
        public fileprivate(set) var name: String
        /// Nil when the segment has no `=`.
        public fileprivate(set) var value: String?
        /// The bytes of each half as they go into the URL.
        fileprivate var rawName: String
        fileprivate var rawValue: String?
        /// Each half as it was first read (or appended), restored when typed back exactly.
        fileprivate var originalName: (text: String, raw: String)
        fileprivate var originalValue: (text: String, raw: String)?

        fileprivate var raw: String { rawName + (rawValue.map { "=" + $0 } ?? "") }

        fileprivate init(id: UUID, raw: String) {
            self.id = id
            if let equals = raw.firstIndex(of: "=") {
                rawName = String(raw[..<equals])
                rawValue = String(raw[raw.index(after: equals)...])
            } else {
                rawName = raw
                rawValue = nil
            }
            name = Self.display(rawName)
            value = rawValue.map(Self.display)
            originalName = (name, rawName)
            originalValue = value.flatMap { value in rawValue.map { (value, $0) } }
        }

        fileprivate static func display(_ text: String) -> String {
            text.removingPercentEncoding ?? text
        }

        public static func == (lhs: Row, rhs: Row) -> Bool {
            lhs.id == rhs.id && lhs.name == rhs.name && lhs.value == rhs.value && lhs.rawName == rhs.rawName
                && lhs.rawValue == rhs.rawValue
        }
    }

    /// Every segment between `&`, empty ones included (they are kept, never shown as rows).
    private var segments: [Row]

    /// The query without `?` and without any fragment.
    public init(raw: String) {
        self.init(raw: raw, reusing: [])
    }

    /// Rows at the same position keep the identity of `previous`, so a table that is being
    /// edited does not lose its rows while the URL is typed.
    init(raw: String, reusing previous: [Row]) {
        var ids = previous.map(\.id).makeIterator()
        segments = raw.split(separator: "&", omittingEmptySubsequences: false).map { segment in
            segment.isEmpty ? Row(id: UUID(), raw: "") : Row(id: ids.next() ?? UUID(), raw: String(segment))
        }
        if raw.isEmpty { segments = [] }
    }

    public var rows: [Row] { segments.filter { !$0.raw.isEmpty } }

    public var rawValue: String { segments.map(\.raw).joined(separator: "&") }

    /// The user edited the name cell: only the name is encoded again.
    mutating func setName(_ id: UUID, _ name: String) {
        guard let index = rowIndex(id) else { return }
        let row = segments[index]
        segments[index].rawName = Self.reencode(name, shown: row.name, raw: row.rawName, original: row.originalName)
        segments[index].name = name
        keepNonEmpty(index)
    }

    /// The user edited the value cell: only the value is encoded again. Nil writes no `=`.
    mutating func setValue(_ id: UUID, _ value: String?) {
        guard let index = rowIndex(id) else { return }
        let row = segments[index]
        segments[index].rawValue = value.map { value in
            guard let shown = row.value, let raw = row.rawValue else {
                return row.originalValue?.text == value ? row.originalValue!.raw : Self.encode(value)
            }
            return Self.reencode(value, shown: shown, raw: raw, original: row.originalValue)
        }
        segments[index].value = value
        keepNonEmpty(index)
    }

    /// Appends a row; a trailing empty segment (`a=1&`) is filled instead of doubling the `&`.
    mutating func appendRow(name: String, value: String?) -> UUID {
        var row = Row(id: UUID(), raw: "=")
        row.rawName = Self.encode(name)
        row.name = name
        if value == nil, !row.rawName.isEmpty {
            row.rawValue = nil
            row.value = nil
        } else {
            row.rawValue = Self.encode(value ?? "")
            row.value = value ?? ""
        }
        row.originalName = (row.name, row.rawName)
        row.originalValue = row.value.flatMap { value in row.rawValue.map { (value, $0) } }
        if let last = segments.indices.last, segments[last].raw.isEmpty {
            segments[last] = row
        } else {
            segments.append(row)
        }
        return row.id
    }

    private func rowIndex(_ id: UUID) -> Int? {
        segments.firstIndex { $0.id == id && !$0.raw.isEmpty }
    }

    /// A row is never stored empty (that would turn it into a bare `&`): an emptied row keeps `=`.
    private mutating func keepNonEmpty(_ index: Int) {
        guard segments[index].raw.isEmpty else { return }
        segments[index].rawValue = ""
        segments[index].value = ""
    }

    mutating func removeRow(_ id: UUID) {
        segments.removeAll { $0.id == id && !$0.raw.isEmpty }
    }

    /// RFC 3986 unreserved characters plus the sub-delimiters that mean nothing inside one
    /// segment; `&`, `=`, `#`, `%` and everything else is percent-encoded as UTF-8.
    private static let kept: Set<UInt8> = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$'()*+,;:@/?".utf8)

    /// The bytes of one half after its shown text `shown` (bytes `raw`) was edited to `text`.
    /// The original text gives back the original bytes; otherwise the unchanged leading and
    /// trailing characters keep their bytes and only the changed middle is encoded.
    static func reencode(_ text: String, shown: String, raw: String, original: (text: String, raw: String)?) -> String {
        if let original, original.text == text { return original.raw }
        guard let units = units(of: raw), units.map(\.shown) == Array(shown.unicodeScalars) else { return encode(text) }
        let typed = Array(text.unicodeScalars)
        var prefix = 0
        while prefix < units.count, prefix < typed.count, units[prefix].shown == typed[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < units.count - prefix, suffix < typed.count - prefix,
              units[units.count - 1 - suffix].shown == typed[typed.count - 1 - suffix] { suffix += 1 }
        var middle = String.UnicodeScalarView()
        middle.append(contentsOf: typed[prefix..<(typed.count - suffix)])
        return units[..<prefix].map(\.raw).joined() + encode(String(middle))
            + units[(units.count - suffix)...].map(\.raw).joined()
    }

    /// Each shown character of `raw` with the exact bytes that spell it, consistent with
    /// `Row.display`: escapes decoded as UTF-8; text that does not decode is shown as written.
    static func units(of raw: String) -> [(shown: Unicode.Scalar, raw: String)]? {
        guard let decoded = raw.removingPercentEncoding else {
            return raw.unicodeScalars.map { ($0, String($0)) }
        }
        var bytes: [(byte: UInt8, raw: String)] = []
        let source = Array(raw.utf8)
        var index = 0
        while index < source.count {
            if source[index] == UInt8(ascii: "%"), index + 2 < source.count,
               let byte = UInt8(String(decoding: source[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) {
                bytes.append((byte, String(decoding: source[index...(index + 2)], as: UTF8.self)))
                index += 3
            } else {
                bytes.append((source[index], ""))
                index += 1
            }
        }
        // A character is spelled either entirely by escapes or entirely literally (valid UTF-8
        // cannot mix them inside one character); anything else falls back to encoding the text.
        var units: [(shown: Unicode.Scalar, raw: String)] = []
        var start = 0
        for scalar in decoded.unicodeScalars {
            let length = String(scalar).utf8.count
            guard start + length <= bytes.count else { return nil }
            let piece = bytes[start..<(start + length)]
            guard Array(String(scalar).utf8) == piece.map(\.byte) else { return nil }
            if piece.allSatisfy({ $0.raw.isEmpty }) { units.append((scalar, String(scalar))) }
            else if piece.allSatisfy({ !$0.raw.isEmpty }) { units.append((scalar, piece.map(\.raw).joined())) }
            else { return nil }
            start += length
        }
        return start == bytes.count ? units : nil
    }

    static func encode(_ text: String) -> String {
        var result = ""
        for byte in text.utf8 {
            if kept.contains(byte) {
                result.unicodeScalars.append(UnicodeScalar(byte))
            } else {
                result += String(format: "%%%02X", byte)
            }
        }
        return result
    }
}
