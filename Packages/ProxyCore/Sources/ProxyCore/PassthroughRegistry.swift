import os

/// Thread-safe set of hosts that are tunnelled without decryption (e.g. certificate-pinned
/// apps). Hosts are normalized the same way as `HostPattern` (lowercase, no brackets/trailing dot).
public final class PassthroughRegistry: Sendable {
    private struct State: Sendable {
        var hosts: Set<String>
        var handler: (@Sendable (Set<String>) -> Void)?
    }

    private let state: OSAllocatedUnfairLock<State>

    public init(hosts: Set<String> = []) {
        state = OSAllocatedUnfairLock(
            initialState: State(hosts: Set(hosts.map(HostPattern.normalize)), handler: nil))
    }

    public func contains(_ host: String) -> Bool {
        let host = HostPattern.normalize(host)
        return state.withLock { $0.hosts.contains(host) }
    }

    /// Returns true only if the host was not already present.
    @discardableResult
    public func insert(_ host: String) -> Bool {
        let host = HostPattern.normalize(host)
        let change = state.withLock { s -> (Set<String>, (@Sendable (Set<String>) -> Void)?)? in
            guard s.hosts.insert(host).inserted else { return nil }
            return (s.hosts, s.handler)
        }
        guard let (snapshot, handler) = change else { return false }
        handler?(snapshot)
        return true
    }

    public func remove(_ host: String) {
        let host = HostPattern.normalize(host)
        let change = state.withLock { s -> (Set<String>, (@Sendable (Set<String>) -> Void)?)? in
            guard s.hosts.remove(host) != nil else { return nil }
            return (s.hosts, s.handler)
        }
        if let (snapshot, handler) = change { handler?(snapshot) }
    }

    public var hosts: Set<String> { state.withLock { $0.hosts } }

    /// Registers the single change handler (a later registration replaces the earlier one).
    /// Called outside the lock with the new host set after each effective insert/remove.
    public func onChange(_ handler: @escaping @Sendable (Set<String>) -> Void) {
        state.withLock { $0.handler = handler }
    }
}
