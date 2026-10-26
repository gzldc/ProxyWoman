import Foundation
import NIOCore
import NIOSSL

/// Which hosts get TLS-decrypted (MITM). Excluded hosts are tunnelled untouched.
public struct DecryptionPolicy: Sendable, Equatable, Codable {
    public var enabled: Bool = true
    /// `HostPattern` syntax (`"a.com"`, `"*.apple.com"`).
    public var excludedHosts: [String] = []

    /// Retained exclusions that the user temporarily unchecked in the SSL list.
    public var disabledExcludedHosts: [String] = []

    public init(enabled: Bool = true, excludedHosts: [String] = [], disabledExcludedHosts: [String] = []) {
        self.enabled = enabled
        self.excludedHosts = excludedHosts
        self.disabledExcludedHosts = disabledExcludedHosts
    }

    public func shouldDecrypt(_ host: String) -> Bool {
        enabled
            && !excludedHosts.contains { pattern in
                !disabledExcludedHosts.contains { HostPattern.normalize($0) == HostPattern.normalize(pattern) }
                    && HostPattern.matches(pattern, host: host)
            }
    }

    /// Context menus toggle only a currently active exact rule; wildcard actions stay separate.
    public func hasActiveExactExclusion(for host: String) -> Bool {
        let host = HostPattern.normalize(host)
        guard !host.isEmpty, !host.contains("*") else { return false }
        return excludedHosts.contains {
            HostPattern.normalize($0) == host
                && !disabledExcludedHosts.contains { HostPattern.normalize($0) == host }
        }
    }

    /// The user's enable action must remove both possible barriers for the next connection.
    /// Callers confirm removal of matching wildcard exclusions before invoking this operation.
    public mutating func enableDecryption(for host: String, passthrough: PassthroughRegistry) {
        enabled = true
        excludedHosts.removeAll { HostPattern.matches($0, host: host) }
        disabledExcludedHosts.removeAll { HostPattern.matches($0, host: host) }
        passthrough.remove(host)
    }
    private enum CodingKeys: String, CodingKey { case enabled, excludedHosts, disabledExcludedHosts }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        excludedHosts = try c.decodeIfPresent([String].self, forKey: .excludedHosts) ?? []
        disabledExcludedHosts = try c.decodeIfPresent([String].self, forKey: .disabledExcludedHosts) ?? []
    }
}

public struct ProxyConfiguration: Sendable {
    /// Used in the pages the proxy serves itself (status page, 502). The app sets it from
    /// `AppInfo.name`; this default is the only place ProxyCore spells the product name.
    public var productName = "ProxyWoman"
    public var listenHost = "127.0.0.1"
    public var port = 9090
    /// On `EADDRINUSE`, ports `port+1 ... port+portFallbackCount` are tried in order.
    public var portFallbackCount = 9
    public var upstreamProxy: UpstreamProxy? = nil
    public var decryption = DecryptionPolicy()
    /// The app sets this to true only once the root certificate is trusted; otherwise every
    /// handshake would fail and poison the passthrough list.
    public var autoPassthroughOnHandshakeFailure = false
    public var upstreamTrustRoots: NIOSSLTrustRoots = .default
    public var connectTimeout: TimeAmount = .seconds(15)
    /// While false, new exchanges and tunnels are proxied as usual but not recorded (no flow, no
    /// body capture); those already in progress are recorded to their end.
    public var recordingEnabled = true

    public init() {}
}
