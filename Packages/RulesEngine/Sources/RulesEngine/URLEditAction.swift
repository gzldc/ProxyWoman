import Foundation

/// Rewrites the request's full URL (`scheme://host[:port]/path?query`).
public struct URLEditAction: Codable, Sendable, Equatable, Hashable {
    public enum Mode: String, Codable, Sendable, CaseIterable {
        case set, findReplace, regex
        /// Puts `replacement` after the whole URL text. Appended in R8F2.
        case append
    }

    public var mode: Mode
    /// What to look for (`findReplace`, `regex`); ignored by `set`.
    public var find: String
    /// The new URL (`set`), or the replacement text / template.
    public var replacement: String
    public var caseSensitive: Bool
    /// Keep the request's credentials when the edit moves the request to another origin.
    public var preserveCredentials: Bool

    public init(
        mode: Mode, find: String = "", replacement: String = "", caseSensitive: Bool = false,
        preserveCredentials: Bool = false
    ) {
        self.mode = mode
        self.find = find
        self.replacement = replacement
        self.caseSensitive = caseSensitive
        self.preserveCredentials = preserveCredentials
    }
}
