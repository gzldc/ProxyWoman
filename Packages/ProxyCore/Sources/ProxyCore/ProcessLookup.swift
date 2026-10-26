import Darwin
import FlowStore

/// Resolves which local process owns the client end of a connection to the proxy, by
/// scanning every process's TCP sockets with libproc for one whose local port is the
/// client's port and whose foreign port is the proxy's port.
public struct ProcessLookup: Sendable {
    public var lookup: @Sendable (_ clientPort: Int, _ proxyPort: Int) -> ClientApp?
    /// Resolves many client ports of one proxy port at once; for `.live` that is a single
    /// process-table scan. Ports without an owner are absent from the result.
    public var lookupAll: @Sendable (_ clientPorts: Set<Int>, _ proxyPort: Int) -> [Int: ClientApp]

    /// `lookupAll` falls back to calling `lookup` once per port.
    public init(lookup: @escaping @Sendable (_ clientPort: Int, _ proxyPort: Int) -> ClientApp?) {
        self.lookup = lookup
        self.lookupAll = { clientPorts, proxyPort in
            var owners: [Int: ClientApp] = [:]
            for port in clientPorts {
                if let app = lookup(port, proxyPort) { owners[port] = app }
            }
            return owners
        }
    }

    public init(
        lookup: @escaping @Sendable (_ clientPort: Int, _ proxyPort: Int) -> ClientApp?,
        lookupAll: @escaping @Sendable (_ clientPorts: Set<Int>, _ proxyPort: Int) -> [Int: ClientApp]
    ) {
        self.lookup = lookup
        self.lookupAll = lookupAll
    }

    public static let live = ProcessLookup(
        lookup: { clientPort, proxyPort in
            liveLookupAll([clientPort], proxyPort)[clientPort]
        },
        lookupAll: liveLookupAll)

    public static let none = ProcessLookup(lookup: { _, _ in nil }, lookupAll: { _, _ in [:] })

    @Sendable private static func liveLookupAll(_ clientPorts: Set<Int>, _ proxyPort: Int) -> [Int: ClientApp] {
        guard let foreign = UInt16(exactly: proxyPort) else { return [:] }
        let locals = Set(clientPorts.compactMap { UInt16(exactly: $0) })
        guard !locals.isEmpty else { return [:] }
        let owners = LibprocScanner.findOwners(localPorts: locals, foreignPort: foreign)
        return Dictionary(uniqueKeysWithValues: owners.map { (Int($0.key), $0.value) })
    }

    /// Outermost `.app` component without its suffix; else outermost `.xpc` without its
    /// suffix; else the last path component.
    public static func appName(fromExecutablePath path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        for suffix in [".app", ".xpc"] {
            if let match = components.first(where: { $0.count > suffix.count && $0.hasSuffix(suffix) }) {
                return String(match.dropLast(suffix.count))
            }
        }
        return components.last.map(String.init) ?? path
    }
}

private enum LibprocScanner {
    /// One pass over every process; stops early once every port has an owner.
    static func findOwners(localPorts: Set<UInt16>, foreignPort: UInt16) -> [UInt16: ClientApp] {
        var owners: [UInt16: ClientApp] = [:]
        var fds: [proc_fdinfo] = []
        var info = socket_fdinfo()

        let pidCount = Int(proc_listallpids(nil, 0))
        guard pidCount > 0 else { return owners }
        // Headroom for processes spawned between the size query and the fill.
        var pids = [pid_t](repeating: 0, count: pidCount + 64)
        let filled = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride)))
        guard filled > 0 else { return owners }

        for pid in pids[0..<min(filled, pids.count)] where pid > 0 {
            let needed = Int(proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0))
            guard needed > 0 else { continue }  // permission denied or process gone
            let capacity = needed / MemoryLayout<proc_fdinfo>.stride + 8
            if fds.count < capacity {
                fds = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
            }
            let bytes = Int(proc_pidinfo(
                pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.stride)))
            guard bytes > 0 else { continue }
            let fdCount = min(bytes / MemoryLayout<proc_fdinfo>.stride, fds.count)

            for index in 0..<fdCount where fds[index].proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
                let size = Int32(MemoryLayout<socket_fdinfo>.stride)
                let got = proc_pidfdinfo(pid, fds[index].proc_fd, PROC_PIDFDSOCKETINFO, &info, size)
                guard got == size else { continue }
                let soi = info.psi
                guard soi.soi_kind == SOCKINFO_TCP,
                      soi.soi_family == AF_INET || soi.soi_family == AF_INET6 else { continue }
                let tcp = soi.soi_proto.pri_tcp.tcpsi_ini
                // Ports are stored in network byte order.
                let local = UInt16(truncatingIfNeeded: tcp.insi_lport).bigEndian
                guard UInt16(truncatingIfNeeded: tcp.insi_fport).bigEndian == foreignPort,
                      localPorts.contains(local), owners[local] == nil else { continue }
                owners[local] = makeClientApp(pid: pid)
                if owners.count == localPorts.count { return owners }
            }
        }
        return owners
    }

    private static func makeClientApp(pid: pid_t) -> ClientApp {
        var buffer = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
            let path = string(fromNulTerminated: buffer)
            return ClientApp(pid: pid, name: ProcessLookup.appName(fromExecutablePath: path), executablePath: path)
        }
        if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 {
            return ClientApp(pid: pid, name: string(fromNulTerminated: buffer), executablePath: nil)
        }
        return ClientApp(pid: pid, name: "pid \(pid)", executablePath: nil)
    }

    private static func string(fromNulTerminated buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
