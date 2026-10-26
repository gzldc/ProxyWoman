import Darwin
import NIOCore
import os

/// The socket addresses this server's listener holds: registered as soon as the listener is
/// bound (before the run counts as running) and released only once it closed, so a starting or
/// stopping run is still recognised. A remapped request must never be sent back to one of them.
final class ProxyListenerEndpoints: Sendable {
    private let addresses = OSAllocatedUnfairLock<[SocketAddress]>(initialState: [])

    func add(_ address: SocketAddress?) {
        guard let address, address.port != nil else { return }
        addresses.withLock { $0.append(address) }
    }

    func removeAll() { addresses.withLock { $0.removeAll() } }

    /// Before connecting: `host` (no brackets) names a listener endpoint literally — `localhost`,
    /// a loopback address, or the listener's own address on its port.
    func containsLiteral(host: String, port: Int) -> Bool {
        let host = host.lowercased()
        let literal = Self.ipBytes(host)
        let loopback = host == "localhost" || literal.map(Self.isLoopback) == true
        return addresses.withLock { addresses in
            addresses.contains { address in
                guard address.port == port, let bound = address.ipAddress.flatMap(Self.ipBytes) else { return false }
                if let literal, literal == bound { return true }
                return loopback && (Self.isLoopback(bound) || Self.isUnspecified(bound))
            }
        }
    }

    /// After connecting directly (whatever the resolver chose): the socket reached a listener.
    func isListener(remote: SocketAddress?, local: SocketAddress?) -> Bool {
        guard let remote, let port = remote.port, let peer = remote.ipAddress.flatMap(Self.ipBytes) else { return false }
        let own = local?.ipAddress.flatMap(Self.ipBytes)
        return addresses.withLock { addresses in
            addresses.contains { address in
                guard address.port == port, let bound = address.ipAddress.flatMap(Self.ipBytes) else { return false }
                if peer == bound { return true }
                return Self.isUnspecified(bound) && (Self.isLoopback(peer) || peer == own)
            }
        }
    }

    /// IPv4 addresses are compared as IPv4-mapped IPv6 bytes, so both families meet.
    private static func ipBytes(_ text: String) -> [UInt8]? {
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            return [UInt8](repeating: 0, count: 10) + [0xff, 0xff] + withUnsafeBytes(of: v4.s_addr) { Array($0) }
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, text, &v6) == 1 else { return nil }
        return withUnsafeBytes(of: v6) { Array($0) }
    }

    private static func isLoopback(_ bytes: [UInt8]) -> Bool {
        bytes == [UInt8](repeating: 0, count: 15) + [1] || (bytes.prefix(12).elementsEqual(mappedPrefix) && bytes[12] == 127)
    }

    private static func isUnspecified(_ bytes: [UInt8]) -> Bool {
        bytes.allSatisfy { $0 == 0 } || bytes == mappedPrefix + [0, 0, 0, 0]
    }

    private static let mappedPrefix = [UInt8](repeating: 0, count: 10) + [0xff, 0xff]
}

/// A remapped connection reached this proxy's own listener.
struct ProxySelfTargetError: Error {
    let authority: String
}
