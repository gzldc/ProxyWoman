import Foundation

/// One change to the request's `Cookie` header or the response's `Set-Cookie` fields.
///
/// An empty name (`nil` for the look-up methods) means "all keys": `set` gives every cookie that value,
/// `remove` removes every cookie, the look-up methods work on every cookie. `addIfMissing` needs a name.
public enum CookieEdit: Codable, Sendable, Equatable, Hashable {
    // Every case ends with `nameCaseSensitive` (R8F2): nil is the original behaviour (names match in exact
    // case) and is not written to the file; true is the same; false matches names case-insensitively.
    case set(name: String, value: String, nameCaseSensitive: Bool? = nil)
    case addIfMissing(name: String, value: String, nameCaseSensitive: Bool? = nil)
    case remove(name: String, nameCaseSensitive: Bool? = nil)
    case findReplace(name: String?, find: String, replacement: String, caseSensitive: Bool, nameCaseSensitive: Bool? = nil)
    case regex(name: String?, pattern: String, replacement: String, caseSensitive: Bool, nameCaseSensitive: Bool? = nil)
    /// Puts `text` after the value of every cookie of that name, as written. Appended in R8F2.
    case appendToValue(name: String, text: String, nameCaseSensitive: Bool? = nil)

    /// The name match flag as stored: nil means the original behaviour.
    public var nameCaseSensitive: Bool? {
        switch self {
        case .set(_, _, let flag), .addIfMissing(_, _, let flag), .appendToValue(_, _, let flag), .remove(_, let flag),
            .findReplace(_, _, _, _, let flag), .regex(_, _, _, _, let flag):
            flag
        }
    }

    /// Whether names match in exact case (the default; only an explicit `false` ignores case).
    public var matchesNameExactly: Bool { nameCaseSensitive != false }

    /// The same edit with the name match flag set.
    public func settingNameCaseSensitive(_ flag: Bool?) -> CookieEdit {
        switch self {
        case .set(let n, let v, _): .set(name: n, value: v, nameCaseSensitive: flag)
        case .addIfMissing(let n, let v, _): .addIfMissing(name: n, value: v, nameCaseSensitive: flag)
        case .appendToValue(let n, let t, _): .appendToValue(name: n, text: t, nameCaseSensitive: flag)
        case .remove(let n, _): .remove(name: n, nameCaseSensitive: flag)
        case .findReplace(let n, let f, let r, let c, _):
            .findReplace(name: n, find: f, replacement: r, caseSensitive: c, nameCaseSensitive: flag)
        case .regex(let n, let p, let r, let c, _):
            .regex(name: n, pattern: p, replacement: r, caseSensitive: c, nameCaseSensitive: flag)
        }
    }
}
