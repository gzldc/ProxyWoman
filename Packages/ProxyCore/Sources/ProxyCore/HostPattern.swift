import Foundation
import RulesEngine

/// The host matcher lives in RulesEngine so rule matching and the decryption/bypass lists share it.
public typealias HostPattern = RulesEngine.HostPattern

/// The user's existing upstream proxy (e.g. Clash at 127.0.0.1:7897) and its exception list.
public struct UpstreamProxy: Sendable, Equatable {
    public var host: String
    public var port: Int
    /// macOS exception-list syntax: exact host, `*.suffix` wildcard, IPv4 CIDR (`192.168.0.0/16`),
    /// bare IP, or `<local>` (a host name without any dot).
    public var bypass: [String]
    /// Loopback (localhost, 127.0.0.0/8, ::1) always goes direct. Only tests turn this off.
    public var alwaysBypassLoopback = true

    public init(host: String, port: Int, bypass: [String]) {
        self.host = host
        self.port = port
        self.bypass = bypass
    }

    public func shouldBypass(_ host: String) -> Bool {
        let host = HostPattern.normalize(host)
        let address = IPAddress(host)
        if alwaysBypassLoopback, host == "localhost" || address?.isLoopback == true {
            return true
        }
        return bypass.contains { Self.entry($0, matches: host, address: address) }
    }

    private static func entry(_ raw: String, matches host: String, address: IPAddress?) -> Bool {
        let entry = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if entry.isEmpty { return false }
        if entry == "<local>" {
            return !host.isEmpty && !host.contains(".") && address == nil
        }
        if let slash = entry.firstIndex(of: "/") {
            // IPv4 CIDR; applies to IPv4-literal hosts only.
            guard case .v4(let hostBits)? = address,
                case .v4(let netBits)? = IPAddress(String(entry[..<slash])),
                let prefix = UInt8(entry[entry.index(after: slash)...]), prefix <= 32
            else { return false }
            let mask: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << (32 - UInt32(prefix))
            return hostBits & mask == netBits & mask
        }
        if let entryAddress = IPAddress(HostPattern.normalize(entry)) {
            return entryAddress == address
        }
        return HostPattern.matches(entry, host: host)
    }
}

/// An IP literal parsed with `inet_pton`, so different spellings of one address compare equal.
private enum IPAddress: Equatable {
    case v4(UInt32)
    case v6([UInt8])

    init?(_ string: String) {
        var v4 = in_addr()
        if inet_pton(AF_INET, string, &v4) == 1 {
            self = .v4(UInt32(bigEndian: v4.s_addr))
            return
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, string, &v6) == 1 {
            self = .v6(withUnsafeBytes(of: &v6) { Array($0) })
            return
        }
        return nil
    }

    var isLoopback: Bool {
        switch self {
        case .v4(let bits): return bits >> 24 == 127
        case .v6(let bytes): return bytes == [UInt8](repeating: 0, count: 15) + [1]
        }
    }
}
