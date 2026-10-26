import Foundation

/// The match string of the "magic string" condition: the Classic auto-responder syntax, read against a
/// request's URL (spec section 12.5). Pure: parsing and matching never throw and read nothing but the
/// values handed in.
///
/// - plain text: the URL contains it, ignoring case
/// - `EXACT:text`: the URL equals it, with case
/// - `NOT:text`: the URL does not contain it, ignoring case
/// - `REGEX:pattern`: the pattern is found in the URL; ignoring case unless the pattern says `(?-i)`
/// - `HEADER:Name=Value`: a request header `Name` contains `Value` (ignoring case); `HEADER:Name`: it exists
/// - `*`: every session
/// - `METHOD:GET ` in front of any of these: the request method must be `GET` as well (a prefix with
///   nothing after it asks for the method alone)
///
/// An empty string, an empty argument after a prefix, a method that is not a token and a pattern that
/// does not compile are not valid. The keywords are matched ignoring case.
public struct MagicStringCondition: Sendable, Equatable {
    public enum Test: Sendable, Equatable {
        case all
        case contains(String)
        case exact(String)
        case notContains(String)
        case regex(String)
        /// `value == nil`: the header only has to exist.
        case header(name: String, value: String?)
    }

    /// The required request method (upper case), if the string names one.
    public var method: String?
    public var test: Test

    public init(method: String? = nil, test: Test) {
        self.method = method
        self.test = test
    }

    /// Whether matching runs a regular expression (it then costs the exchange's allowance).
    public var usesRegex: Bool {
        if case .regex = test { return true }
        return false
    }

    /// The pattern a `REGEX:` string runs, for compiling it ahead of time.
    public var regexPattern: String? {
        if case .regex(let pattern) = test { return pattern }
        return nil
    }

    /// Nil when the string is not valid. Regex patterns are not compiled here (see `ConditionRow` validation).
    public static func parse(_ written: String) -> MagicStringCondition? {
        let text = written.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var rest = Substring(text)
        var method: String?
        if let afterKeyword = strip("METHOD:", from: rest) {
            let name = afterKeyword.prefix { $0 != " " }
            guard !name.isEmpty, name.utf8.allSatisfy(isTokenByte) else { return nil }
            method = name.uppercased()
            rest = afterKeyword.dropFirst(name.count).drop { $0 == " " }
            if rest.isEmpty { return MagicStringCondition(method: method, test: .all) }
        }
        guard let test = parseTest(rest) else { return nil }
        return MagicStringCondition(method: method, test: test)
    }

    private static func parseTest(_ text: Substring) -> Test? {
        if text == "*" { return .all }
        if let argument = strip("EXACT:", from: text) { return argument.isEmpty ? nil : .exact(String(argument)) }
        if let argument = strip("NOT:", from: text) { return argument.isEmpty ? nil : .notContains(String(argument)) }
        if let argument = strip("REGEX:", from: text) { return argument.isEmpty ? nil : .regex(String(argument)) }
        if let argument = strip("HEADER:", from: text) {
            guard let equals = argument.firstIndex(of: "=") else {
                return argument.isEmpty ? nil : .header(name: String(argument), value: nil)
            }
            let name = argument[..<equals]
            guard !name.isEmpty else { return nil }
            return .header(name: String(name), value: String(argument[argument.index(after: equals)...]))
        }
        return text.isEmpty ? nil : .contains(String(text))
    }

    /// `text` without `keyword` (matched ignoring case) when it starts with it.
    private static func strip(_ keyword: String, from text: Substring) -> Substring? {
        guard text.utf8.count >= keyword.utf8.count else { return nil }
        let head = text.utf8.prefix(keyword.utf8.count)
        guard head.elementsEqual(keyword.utf8, by: { lower($0) == lower($1) }) else { return nil }
        return Substring(text.utf8.dropFirst(keyword.utf8.count))
    }

    private static func lower(_ byte: UInt8) -> UInt8 { (0x41...0x5A).contains(byte) ? byte + 0x20 : byte }

    private static func isTokenByte(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
            || byte == 0x2D || byte == 0x5F || byte == 0x2E
    }
}
