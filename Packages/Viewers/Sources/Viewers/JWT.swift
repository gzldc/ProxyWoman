import Foundation

/// A JSON Web Token found in a message. Only decoded for reading: the signature is never verified.
public struct DecodedJWT: Equatable, Sendable, Identifiable {
    /// Where the token was found, for example "Authorization" or "Cookie: session".
    public var source: String
    public var token: String
    /// Pretty-printed header and payload JSON.
    public var header: String
    public var payload: String
    public var algorithm: String?
    public var issuedAt: Date?
    public var notBefore: Date?
    public var expiresAt: Date?
    public var id: String { source + "\u{0}" + token }

    public func isExpired(now: Date = Date()) -> Bool { expiresAt.map { $0 <= now } ?? false }
}

public enum JWTDecoder {
    /// Header and payload must both be base64url JSON objects; a JWE (5 parts) or any other dotted
    /// string is not reported.
    public static func decode(_ token: String, source: String) -> DecodedJWT? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let headerData = base64URL(parts[0]), let payloadData = base64URL(parts[1]),
              let header = (try? JSONSerialization.jsonObject(with: headerData)) as? [String: Any],
              let payload = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any]
        else { return nil }
        return DecodedJWT(
            source: source, token: token, header: pretty(header), payload: pretty(payload),
            algorithm: header["alg"] as? String, issuedAt: date(payload["iat"]), notBefore: date(payload["nbf"]),
            expiresAt: date(payload["exp"]))
    }

    /// Every distinct JWT inside the given values (header values, cookie values, query values).
    public static func find(in values: [(source: String, value: String)]) -> [DecodedJWT] {
        var seen = Set<String>()
        var found: [DecodedJWT] = []
        for (source, value) in values {
            for match in value.matches(of: candidate) {
                let token = String(match.output)
                guard !seen.contains(token), let jwt = decode(token, source: source) else { continue }
                seen.insert(token)
                found.append(jwt)
            }
        }
        return found
    }

    // A JSON object header always base64url-encodes to "eyJ".
    nonisolated(unsafe) private static let candidate = /eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*/

    private static func base64URL(_ part: Substring) -> Data? {
        var text = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        return Data(base64Encoded: text)
    }

    private static func pretty(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func date(_ value: Any?) -> Date? {
        guard let seconds = (value as? NSNumber)?.doubleValue else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
