import FlowStore

/// One ordered header operation. Names compare case-insensitively; other fields keep their order.
public enum HeaderEdit: Sendable, Equatable, Hashable, Codable {
    // Every case ends with `nameCaseSensitive`: nil is the original behaviour (names compare
    // case-insensitively) and is not written to the file; true matches the name's exact case; false is
    // case-insensitive as nil is. Added in R8F2.
    /// Removes every old field of that name and puts one field at the first old position
    /// (at the end when there was none).
    case set(name: String, value: String, nameCaseSensitive: Bool? = nil)
    /// Adds one field at the end.
    case append(name: String, value: String, nameCaseSensitive: Bool? = nil)
    /// Removes every field of that name.
    case remove(name: String, nameCaseSensitive: Bool? = nil)
    /// Adds a field only when none of that name exists.
    case addIfMissing(name: String, value: String, nameCaseSensitive: Bool? = nil)
    /// Puts `text` after the value of every field of that name, as written (no separator is added).
    case appendToValue(name: String, text: String, nameCaseSensitive: Bool? = nil)
    /// Replaces every occurrence of `find` in the value of every field of that name.
    case findReplace(name: String, find: String, replacement: String, caseSensitive: Bool, nameCaseSensitive: Bool? = nil)
    /// Replaces every match of the regular expression in the value of every field of that name;
    /// `replacement` is a template (`$1`).
    case regex(name: String, pattern: String, replacement: String, caseSensitive: Bool, nameCaseSensitive: Bool? = nil)

    public var name: String {
        switch self {
        case .set(let name, _, _), .append(let name, _, _), .remove(let name, _), .addIfMissing(let name, _, _),
            .appendToValue(let name, _, _), .findReplace(let name, _, _, _, _), .regex(let name, _, _, _, _):
            name
        }
    }

    /// The text this edit writes: the value, the appended text or the replacement.
    public var value: String? {
        switch self {
        case .set(_, let value, _), .append(_, let value, _), .addIfMissing(_, let value, _): value
        case .appendToValue(_, let text, _): text
        case .findReplace(_, _, let replacement, _, _), .regex(_, _, let replacement, _, _): replacement
        case .remove: nil
        }
    }

    /// The name match flag as stored: nil means the original behaviour.
    public var nameCaseSensitive: Bool? {
        switch self {
        case .set(_, _, let flag), .append(_, _, let flag), .remove(_, let flag), .addIfMissing(_, _, let flag),
            .appendToValue(_, _, let flag), .findReplace(_, _, _, _, let flag), .regex(_, _, _, _, let flag):
            flag
        }
    }

    /// Whether the name must match in exact case (header names are case-insensitive unless this is set).
    public var matchesNameExactly: Bool { nameCaseSensitive == true }

    /// Whether a field called `fieldName` is the one this edit's `name` selects.
    func isNamed(_ fieldName: String, _ name: String) -> Bool {
        matchesNameExactly ? bytesEqual(fieldName, name) : fieldName.caseInsensitiveCompare(name) == .orderedSame
    }

    /// The same edit with the name match flag set.
    public func settingNameCaseSensitive(_ flag: Bool?) -> HeaderEdit {
        switch self {
        case .set(let n, let v, _): .set(name: n, value: v, nameCaseSensitive: flag)
        case .append(let n, let v, _): .append(name: n, value: v, nameCaseSensitive: flag)
        case .remove(let n, _): .remove(name: n, nameCaseSensitive: flag)
        case .addIfMissing(let n, let v, _): .addIfMissing(name: n, value: v, nameCaseSensitive: flag)
        case .appendToValue(let n, let t, _): .appendToValue(name: n, text: t, nameCaseSensitive: flag)
        case .findReplace(let n, let f, let r, let c, _):
            .findReplace(name: n, find: f, replacement: r, caseSensitive: c, nameCaseSensitive: flag)
        case .regex(let n, let p, let r, let c, _):
            .regex(name: n, pattern: p, replacement: r, caseSensitive: c, nameCaseSensitive: flag)
        }
    }
}

extension Array where Element == HeaderField {
    /// The fields after applying the old three methods of `operations` in order (the R5 methods need
    /// `applying(_:allowance:cache:)`). Pure; validation is the caller's job.
    public func applying(_ operations: [HeaderEdit]) -> [HeaderField] {
        var fields = self
        for operation in operations {
            switch operation {
            case .append(let name, let value, _):
                fields.append(HeaderField(name: name, value: value))
            case .remove(let name, _):
                fields.removeAll { operation.isNamed($0.name, name) }
            case .set(let name, let value, _):
                let matches = fields.indices.filter { operation.isNamed(fields[$0].name, name) }
                guard let first = matches.first else {
                    fields.append(HeaderField(name: name, value: value))
                    continue
                }
                fields[first] = HeaderField(name: name, value: value)
                for index in matches.dropFirst().reversed() { fields.remove(at: index) }
            case .addIfMissing, .appendToValue, .findReplace, .regex:
                // Only `applying(_:allowance:cache:)` runs the R5 methods; this variant keeps the old three.
                continue
            }
        }
        return fields
    }
}
