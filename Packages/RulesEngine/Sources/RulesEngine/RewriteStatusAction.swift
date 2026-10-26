import Foundation

/// Replaces the status code of a response. The reason phrase follows the new status (or is the one
/// written here); the body and every other header stay as they are.
public struct RewriteStatusAction: Sendable, Equatable, Hashable, Codable {
    /// 200...599.
    public var status: Int
    /// Also rewrite responses the proxy produced itself (Map Local, local error pages). Off: only
    /// responses that came from the origin are rewritten.
    public var includeLocalResponses: Bool
    /// The reason phrase to write on an HTTP/1.1 status line; nil keeps the conventional one for the
    /// code. HTTP/2 has no reason phrase, so it is ignored there. Not written to a file when nil.
    public var reason: String?

    /// The longest text of the one status field ("404 Not Found").
    public static let maxTextCharacters = 200

    public init(status: Int, includeLocalResponses: Bool = false, reason: String? = nil) {
        self.status = status
        self.includeLocalResponses = includeLocalResponses
        self.reason = reason.flatMap { $0.isEmpty ? nil : $0 }  // an empty phrase is no phrase
    }

    private enum CodingKeys: String, CodingKey { case status, includeLocalResponses, reason }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(Int.self, forKey: .status)
        includeLocalResponses = try container.decode(Bool.self, forKey: .includeLocalResponses)
        reason = try container.decodeIfPresent(String.self, forKey: .reason).flatMap { $0.isEmpty ? nil : $0 }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encode(includeLocalResponses, forKey: .includeLocalResponses)
        try container.encodeIfPresent(reason, forKey: .reason)
    }

    /// The status field as typed: `404` or `404 Not Found`.
    public var text: String {
        guard let reason, !reason.isEmpty else { return String(status) }
        return "\(status) \(reason)"
    }

    /// Reads the one status field: a code of 200...599, optionally followed by a space and a reason
    /// phrase (visible text, at most `maxTextCharacters` characters in all). Nil when it does not read.
    public static func parse(_ text: String, includeLocalResponses: Bool = false) -> RewriteStatusAction? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count <= maxTextCharacters else { return nil }
        let bytes = Array(trimmed.utf8)
        let digits = bytes.prefix { $0 >= 48 && $0 <= 57 }
        guard digits.count == 3, let status = Int(String(decoding: digits, as: UTF8.self)),
            (200...599).contains(status)
        else { return nil }
        let rest = bytes.dropFirst(digits.count)
        guard !rest.isEmpty else { return RewriteStatusAction(status: status, includeLocalResponses: includeLocalResponses) }
        guard rest.first == 32 || rest.first == 9 else { return nil }
        let phrase = String(decoding: rest, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        guard HTTPMutationValidator.isValidValue(phrase) else { return nil }
        return RewriteStatusAction(
            status: status, includeLocalResponses: includeLocalResponses, reason: phrase.isEmpty ? nil : phrase)
    }
}
