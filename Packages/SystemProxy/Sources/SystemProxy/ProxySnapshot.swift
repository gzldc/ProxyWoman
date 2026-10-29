import Foundation

/// One proxy endpoint as reported by `networksetup -getwebproxy` / `-getsecurewebproxy`.
public struct ProxyEndpoint: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var host: String
    public var port: Int

    public init(enabled: Bool, host: String, port: Int) {
        self.enabled = enabled
        self.host = host
        self.port = port
    }
}

/// The HTTP/HTTPS proxy settings of one network service, captured before we change them.
public struct ServiceProxySnapshot: Codable, Equatable, Sendable {
    public var service: String
    public var web: ProxyEndpoint
    public var secureWeb: ProxyEndpoint
    public var bypassDomains: [String]

    public init(service: String, web: ProxyEndpoint, secureWeb: ProxyEndpoint, bypassDomains: [String]) {
        self.service = service
        self.web = web
        self.secureWeb = secureWeb
        self.bypassDomains = bypassDomains
    }
}

/// The backup file: the settings to restore, plus where we pointed the system, so that only
/// endpoints still pointing at us are restored (someone may have changed others meanwhile).
struct ProxyBackup: Codable, Equatable, Sendable {
    private struct LegacyPortRange: Decodable {
        var lower: Int
        var upper: Int
    }

    /// Bare-array backups predate endpoint ownership. Preserve their historical default ports.
    static let legacyOwnPorts = Set(9090...9099)
    static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

    var ownHost: String
    var ownPorts: Set<Int>
    var services: [ServiceProxySnapshot]
    /// Hosts we appended to each service's bypass list; restored away only while the list is still ours.
    var addedBypass: [String] = []

    init(ownHost: String, ownPorts: Set<Int>, services: [ServiceProxySnapshot], addedBypass: [String] = []) {
        self.ownHost = ownHost
        self.ownPorts = ownPorts
        self.services = services
        self.addedBypass = addedBypass
    }

    private enum CodingKeys: String, CodingKey { case ownHost, ownPorts, services, addedBypass }

    /// A service's bypass list while we manage it: its own entries, then ours that it lacks.
    static func mergedBypass(_ original: [String], adding added: [String]) -> [String] {
        let present = Set(original.map { $0.lowercased() })
        var result = original
        for host in added where !present.contains(host.lowercased()) && !result.contains(host) { result.append(host) }
        return result
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ownHost = try values.decode(String.self, forKey: .ownHost)
        services = try values.decode([ServiceProxySnapshot].self, forKey: .services)
        addedBypass = try values.decodeIfPresent([String].self, forKey: .addedBypass) ?? []
        let ports: [Int]
        if let exact = try? values.decode([Int].self, forKey: .ownPorts) {
            ports = exact
        } else {
            let old = try values.decode(LegacyPortRange.self, forKey: .ownPorts)
            // An old interval does not prove ownership of any intermediate port.
            ports = [old.lower, old.upper]
        }
        guard !ports.isEmpty, ports.allSatisfy({ (1...65535).contains($0) }) else {
            throw SystemProxyError.invalidBackup
        }
        ownPorts = Set(ports)
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(ownHost, forKey: .ownHost)
        try values.encode(ownPorts.sorted(), forKey: .ownPorts)
        try values.encode(services, forKey: .services)
        if !addedBypass.isEmpty { try values.encode(addedBypass, forKey: .addedBypass) }
    }

    /// Whether `endpoint` is currently switched on and points at an exact owned port.
    func isOurs(_ endpoint: ProxyEndpoint) -> Bool {
        let endpointHost = endpoint.host.lowercased()
        return endpoint.enabled && ownPorts.contains(endpoint.port)
            && (Self.loopbackHosts.contains(endpointHost) || endpointHost == ownHost.lowercased())
    }

    /// Accepts exact sets, old objects (only their endpoints), and historical bare service arrays.
    static func decode(_ data: Data) throws -> ProxyBackup {
        let decoder = JSONDecoder()
        if let backup = try? decoder.decode(ProxyBackup.self, from: data) { return backup }
        guard let services = try? decoder.decode([ServiceProxySnapshot].self, from: data) else {
            throw SystemProxyError.invalidBackup
        }
        return ProxyBackup(ownHost: "127.0.0.1", ownPorts: legacyOwnPorts, services: services)
    }
}
