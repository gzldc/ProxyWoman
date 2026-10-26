/// Where a request should go: parsed from an absolute-form URI (`http://host:port/path?query`),
/// from a CONNECT authority (`host:port`), or given directly for requests inside an intercepted
/// TLS connection.
struct RequestTarget: Equatable {
    /// As the client wrote it, without IPv6 brackets.
    var host: String
    var port: Int
    /// Path and query; at least "/" (empty for a CONNECT target).
    var originForm: String
    /// The scheme's default port, left out of a generated Host header.
    var defaultPort: Int

    init(host: String, port: Int, originForm: String, defaultPort: Int) {
        self.host = host
        self.port = port
        self.originForm = originForm
        self.defaultPort = defaultPort
    }

    /// Accepts `http://` URIs only. Userinfo and fragment are dropped.
    init?(absoluteForm uri: String) {
        guard let separator = uri.range(of: "://"), uri[..<separator.lowerBound].lowercased() == "http" else {
            return nil
        }
        let rest = uri[separator.upperBound...]
        let authorityEnd = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? rest.endIndex
        var authority = rest[..<authorityEnd]
        if let at = authority.lastIndex(of: "@") {
            authority = authority[authority.index(after: at)...]
        }
        guard let (host, port) = Self.parseAuthority(authority, defaultPort: 80) else { return nil }

        var path = rest[authorityEnd...]
        if let hash = path.firstIndex(of: "#") { path = path[..<hash] }
        self.init(
            host: host, port: port, originForm: path.hasPrefix("/") ? String(path) : "/" + path, defaultPort: 80)
    }

    /// The target of a CONNECT request: `host:port` (`[v6]:port`); the port is required.
    init?(authorityForm authority: String) {
        guard !authority.contains(where: { $0 == "/" || $0 == "@" || $0 == "?" || $0 == "#" }),
              let (host, port) = Self.parseAuthority(authority[...], defaultPort: nil)
        else { return nil }
        self.init(host: host, port: port, originForm: "", defaultPort: 443)
    }

    /// Splits `host[:port]`; a missing port is `defaultPort`, or invalid if that is nil.
    private static func parseAuthority(_ authority: Substring, defaultPort: Int?) -> (String, Int)? {
        let host: Substring
        var portText: Substring?
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return nil }
            host = authority[authority.index(after: authority.startIndex)..<close]
            let afterBracket = authority[authority.index(after: close)...]
            if !afterBracket.isEmpty {
                guard afterBracket.hasPrefix(":") else { return nil }
                portText = afterBracket.dropFirst()
            }
        } else if let colon = authority.lastIndex(of: ":") {
            host = authority[..<colon]
            portText = authority[authority.index(after: colon)...]
        } else {
            host = authority
        }
        guard !host.isEmpty else { return nil }

        guard let portText, !portText.isEmpty else {
            return defaultPort.map { (String(host), $0) }
        }
        guard let port = Int(portText), (1...65535).contains(port) else { return nil }
        return (String(host), port)
    }

    var bracketedHost: String { host.contains(":") ? "[\(host)]" : host }
    /// `host:port`: keys the reused upstream connection and names the origin in error pages.
    var authority: String { "\(bracketedHost):\(port)" }
    var hostHeader: String { port == defaultPort ? bracketedHost : authority }
}
