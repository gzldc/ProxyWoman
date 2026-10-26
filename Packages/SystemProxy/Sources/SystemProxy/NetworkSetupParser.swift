import Foundation

/// Parsers for the plain-text output of `networksetup`.
public enum NetworkSetupParser {
    /// `-listallnetworkservices`: skips the leading explanation line and disabled (`*`-prefixed) services.
    public static func services(_ output: String) -> [String] {
        lines(output).dropFirst().filter { !$0.hasPrefix("*") }
    }

    /// `-listallnetworkservices` including disabled (`*`-prefixed) services, without the asterisk.
    /// A disabled service still exists, so its settings can (and must) still be restored.
    public static func allServices(_ output: String) -> [String] {
        lines(output).dropFirst().map { $0.hasPrefix("*") ? String($0.dropFirst()) : $0 }
    }

    /// `-getwebproxy` / `-getsecurewebproxy`: `Enabled:`, `Server:` and `Port:` lines.
    public static func endpoint(_ output: String) -> ProxyEndpoint {
        var endpoint = ProxyEndpoint(enabled: false, host: "", port: 0)
        for line in lines(output) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "Enabled": endpoint.enabled = value.lowercased() == "yes"
            case "Server": endpoint.host = value
            case "Port": endpoint.port = Int(value) ?? 0
            default: break
            }
        }
        return endpoint
    }

    /// `-getproxybypassdomains`: one domain per line; "There aren't any bypass domains set on X." means none.
    public static func bypassDomains(_ output: String) -> [String] {
        if output.contains("aren't any bypass domains") { return [] }
        return lines(output)
    }

    private static func lines(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
