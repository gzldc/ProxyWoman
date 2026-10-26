import Foundation

/// Host-name matching shared by the decryption policy and the upstream bypass list.
public enum HostPattern {
    /// `"a.com"` matches exactly; `"*.a.com"` matches any depth of subdomain but not `a.com`
    /// itself; `"*"` matches everything; an empty pattern matches nothing.
    /// Comparison is case-insensitive, ignores a trailing dot and IPv6 brackets.
    public static func matches(_ pattern: String, host: String) -> Bool {
        let pattern = normalize(pattern)
        if pattern.isEmpty { return false }
        if pattern == "*" { return true }
        let host = normalize(host)
        if pattern.hasPrefix("*.") {
            let suffix = pattern.dropFirst(1)  // ".a.com"
            return host.count > suffix.count && host.hasSuffix(suffix)
        }
        return host == pattern
    }

    /// The stored form of a pattern typed by the user, or nil when it is unusable: `"*"`, a host
    /// name, an IP address, or `"*."` followed by a host name. Rejects `"*."`, which `normalize`
    /// would turn into `"*"` (match everything), and anything containing a scheme, path, port or
    /// misplaced wildcard, since such a pattern would never match.
    public static func normalizedUserPattern(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "*" { return "*" }
        let pattern = normalize(trimmed)
        if pattern.contains(":") {
            var address = in6_addr()
            guard inet_pton(AF_INET6, pattern, &address) == 1 else { return nil }
            return pattern
        }
        let name = pattern.hasPrefix("*.") ? pattern.dropFirst(2) : Substring(pattern)
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        let isHostName = labels.allSatisfy { label in
            !label.isEmpty && label.unicodeScalars.allSatisfy(hostNameCharacters.contains)
        }
        return isHostName ? pattern : nil
    }

    private static let hostNameCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_")

    /// Trimmed, lowercased, IPv6 brackets and one trailing dot removed.
    public static func normalize(_ host: String) -> String {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if h.hasPrefix("["), h.hasSuffix("]") {
            h = String(h.dropFirst().dropLast())
        }
        if h.hasSuffix(".") { h.removeLast() }
        return h
    }
}
