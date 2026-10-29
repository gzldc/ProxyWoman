import Foundation

/// Validation failures that leave system proxy settings unchanged.
public enum SystemProxyError: Error, Equatable, Sendable {
    case invalidPort(Int)
    case invalidBackup
}

/// What `disable()` / `recoverIfNeeded()` did.
public enum RestoreOutcome: Equatable, Sendable {
    /// There was no backup.
    case nothingToRestore
    /// Every endpoint that still pointed at us got its original setting back.
    case restored
    /// Retained for source compatibility. Corrupt backups now throw `SystemProxyError.invalidBackup`
    /// and remain on disk without changing system settings; this outcome is never emitted.
    case corruptBackupDiscarded
}

/// Switches the macOS system HTTP/HTTPS proxy to us, remembering the original per-service settings
/// in a backup file so they can be restored on disable, quit, or after a crash.
/// Restoring only touches endpoints that still point at us, and a bypass list only while it is still the one we
/// set; SOCKS is never touched.
public final class SystemProxyController: Sendable {
    private let runner: CommandRunner
    private let backupURL: URL

    public init(runner: CommandRunner, backupURL: URL) {
        self.runner = runner
        self.backupURL = backupURL
    }

    /// True while a backup file exists, i.e. the system settings may currently be ours.
    public var isEnabledByUs: Bool {
        FileManager.default.fileExists(atPath: backupURL.path)
    }

    /// Reads the current HTTP/HTTPS proxy settings and bypass list of every enabled network service.
    public func snapshot() throws -> [ServiceProxySnapshot] {
        let services = NetworkSetupParser.services(try runner.networksetup(["-listallnetworkservices"]))
        return try services.map { service in
            ServiceProxySnapshot(
                service: service,
                web: NetworkSetupParser.endpoint(try runner.networksetup(["-getwebproxy", service])),
                secureWeb: NetworkSetupParser.endpoint(try runner.networksetup(["-getsecurewebproxy", service])),
                bypassDomains: NetworkSetupParser.bypassDomains(
                    try runner.networksetup(["-getproxybypassdomains", service])))
        }
    }

    /// Points every service's HTTP and HTTPS proxy at `host:port`.
    /// The original settings are backed up first, but only if no backup exists yet.
    /// The backup records `host` and the exact ports pointed at so far, so restoring can tell
    /// our endpoints from ones someone else changed meanwhile.
    /// `bypass`: hosts appended to every service's bypass list while we manage it (taken from the first
    /// enable; a re-enable with a backup present keeps the hosts recorded then).
    public func enable(host: String, port: Int, bypass: [String] = []) throws {
        guard (1...65535).contains(port) else { throw SystemProxyError.invalidPort(port) }
        let original: ProxyBackup
        let targets: [ServiceProxySnapshot]
        if let loaded = try loadBackup() {
            var existing = loaded
            existing.ownPorts.insert(port)
            if existing != loaded { try writeBackup(existing) }
            original = existing
            targets = onlyExisting(existing.services)
        } else {
            let services = try snapshot()
            original = ProxyBackup(ownHost: host, ownPorts: [port], services: services, addedBypass: bypass)
            targets = services
            try writeBackup(original)
        }
        let groups = targets.map { snap in
            var commands = [
                ["-setwebproxy", snap.service, host, String(port)],
                ["-setsecurewebproxy", snap.service, host, String(port)],
            ]
            if !original.addedBypass.isEmpty {
                commands.append(
                    ["-setproxybypassdomains", snap.service]
                        + ProxyBackup.mergedBypass(snap.bypassDomains, adding: original.addedBypass))
            }
            return ServiceCommands(service: snap.service, commands: commands)
        }
        if let failure = apply(groups, independent: false, allowPrivileged: true).first {
            rollback(to: original)
            throw failure.error
        }
    }

    /// Restores the backed-up settings of every endpoint that is still switched on and pointing at us
    /// (an endpoint someone else changed meanwhile is left alone), then deletes the backup.
    /// No backup means nothing to do. Services that no longer exist are skipped; one failing service
    /// does not stop the others. On partial failure the backup is reduced to the services that still
    /// need restoring (after a privileged batch fails, to all still-existing services) so
    /// `recoverIfNeeded` can retry.
    /// Unreadable or malformed backups are retained and throw `SystemProxyError.invalidBackup`
    /// before any system commands run.
    @discardableResult
    public func disable() throws -> RestoreOutcome {
        guard let backup = try loadBackup() else { return .nothingToRestore }
        try restore(backup, allowPrivileged: true)
        return .restored
    }

    /// Crash recovery: a leftover backup means a previous run never restored the system settings.
    @discardableResult
    public func recoverIfNeeded() throws -> RestoreOutcome {
        guard isEnabledByUs else { return .nothingToRestore }
        return try disable()
    }

    /// The settings to chain through: the backup while one exists (the live settings may point at us,
    /// e.g. after a crash whose recovery failed), otherwise the live `snapshot()`.
    public func originalSettings() throws -> [ServiceProxySnapshot] {
        try loadBackup()?.services ?? snapshot()
    }

    /// The proxy the system was using before us, to chain through: the first service with HTTPS proxy
    /// enabled, otherwise the first with HTTP proxy enabled. Endpoints pointing at ourselves are ignored.
    public static func upstream(from snapshots: [ServiceProxySnapshot], ownPort: Int) -> (host: String, port: Int, bypass: [String])? {
        upstream(from: snapshots, ownPorts: ownPort...ownPort)
    }

    /// Like `upstream(from:ownPort:)`, treating a loopback endpoint on any port in `ownPorts` as ours
    /// (the listener may have fallen back to a later port).
    public static func upstream(
        from snapshots: [ServiceProxySnapshot], ownPorts: ClosedRange<Int>
    ) -> (host: String, port: Int, bypass: [String])? {
        func isForeign(_ e: ProxyEndpoint) -> Bool {
            guard e.enabled, !e.host.isEmpty else { return false }
            return !(ownPorts.contains(e.port) && ["127.0.0.1", "localhost", "::1"].contains(e.host.lowercased()))
        }
        if let s = snapshots.first(where: { isForeign($0.secureWeb) }) {
            return (s.secureWeb.host, s.secureWeb.port, s.bypassDomains)
        }
        if let s = snapshots.first(where: { isForeign($0.web) }) {
            return (s.web.host, s.web.port, s.bypassDomains)
        }
        return nil
    }

    // MARK: - Commands

    private static func restoreCommands(service: String, kind: String, endpoint: ProxyEndpoint) -> [[String]] {
        var commands: [[String]] = []
        // Setting the address also switches the proxy on, so a disabled one is switched off afterwards.
        if endpoint.enabled || !endpoint.host.isEmpty {
            commands.append(["-set\(kind)", service, endpoint.host, String(endpoint.port)])
        }
        if !endpoint.enabled {
            commands.append(["-set\(kind)state", service, "off"])
        }
        return commands
    }

    private struct ServiceCommands {
        let service: String
        let commands: [[String]]
    }

    private struct ServiceFailure {
        let service: String
        let error: CommandError
    }

    /// Runs each service's commands in order and returns the services that failed.
    /// If the very first command needs administrator rights, everything is re-run in one privileged batch
    /// (one authorization prompt); if that batch fails, every service counts as failed.
    /// With `independent`, a failing service does not stop the following ones; otherwise the first failure ends the run.
    private func apply(_ groups: [ServiceCommands], independent: Bool, allowPrivileged: Bool) -> [ServiceFailure] {
        var failures: [ServiceFailure] = []
        var isFirstCommand = true
        for group in groups {
            for command in group.commands {
                let wasFirst = isFirstCommand
                isFirstCommand = false
                do {
                    _ = try runner.networksetup(command)
                } catch {
                    if wasFirst, allowPrivileged, error == .needsAuthorization {
                        do {
                            try runner.networksetupPrivileged(groups: groups.map(\.commands))
                            return []
                        } catch {
                            return groups.map { ServiceFailure(service: $0.service, error: error) }
                        }
                    }
                    failures.append(ServiceFailure(service: group.service, error: error))
                    if !independent { return failures }
                    break  // skip this service's remaining commands, carry on with the next service
                }
            }
        }
        return failures
    }

    /// Names of all network services that currently exist, disabled ones included.
    /// `nil` if they cannot be listed, in which case nothing is filtered out.
    private func existingServices() -> Set<String>? {
        guard let output = try? runner.networksetup(["-listallnetworkservices"]) else { return nil }
        return Set(NetworkSetupParser.allServices(output))
    }

    private func onlyExisting(_ snapshots: [ServiceProxySnapshot]) -> [ServiceProxySnapshot] {
        guard let existing = existingServices() else { return snapshots }
        return snapshots.filter { existing.contains($0.service) }
    }

    private func restore(_ backup: ProxyBackup, allowPrivileged: Bool) throws {
        let present = onlyExisting(backup.services)
        var failures: [ServiceFailure] = []
        var groups: [ServiceCommands] = []
        for snap in present {
            do {
                let web = NetworkSetupParser.endpoint(try runner.networksetup(["-getwebproxy", snap.service]))
                let secure = NetworkSetupParser.endpoint(try runner.networksetup(["-getsecurewebproxy", snap.service]))
                var commands: [[String]] = []
                if backup.isOurs(web) {
                    commands += Self.restoreCommands(service: snap.service, kind: "webproxy", endpoint: snap.web)
                }
                if backup.isOurs(secure) {
                    commands += Self.restoreCommands(service: snap.service, kind: "securewebproxy", endpoint: snap.secureWeb)
                }
                if !backup.addedBypass.isEmpty {
                    // Only a list that is still exactly what we set; one someone changed meanwhile is left alone.
                    let current = NetworkSetupParser.bypassDomains(
                        try runner.networksetup(["-getproxybypassdomains", snap.service]))
                    if current == ProxyBackup.mergedBypass(snap.bypassDomains, adding: backup.addedBypass) {
                        commands.append(
                            ["-setproxybypassdomains", snap.service]
                                + (snap.bypassDomains.isEmpty ? ["Empty"] : snap.bypassDomains))
                    }
                }
                if !commands.isEmpty { groups.append(ServiceCommands(service: snap.service, commands: commands)) }
            } catch {
                failures.append(ServiceFailure(service: snap.service, error: error))
            }
        }
        failures += apply(groups, independent: true, allowPrivileged: allowPrivileged)
        guard let first = failures.first else {
            try removeBackup()
            return
        }
        let failed = Set(failures.map(\.service))
        var remaining = backup
        remaining.services = present.filter { failed.contains($0.service) }
        try? writeBackup(remaining)
        throw first.error
    }

    /// Best effort after a failed `enable`: put the original settings back, never prompting again.
    /// If that fails but the system already matches the backup (e.g. the user cancelled authorization
    /// before anything changed), the backup is dropped so we do not claim to own the settings.
    private func rollback(to original: ProxyBackup) {
        do {
            try restore(original, allowPrivileged: false)
        } catch {
            if let current = try? snapshot(), current == original.services {
                try? removeBackup()
            }
        }
    }

    // MARK: - Backup file

    /// Never guess ownership from an unreadable or malformed backup.
    private func loadBackup() throws -> ProxyBackup? {
        guard isEnabledByUs else { return nil }
        do {
            return try ProxyBackup.decode(Data(contentsOf: backupURL))
        } catch {
            throw SystemProxyError.invalidBackup
        }
    }

    private func writeBackup(_ backup: ProxyBackup) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(backup).write(to: backupURL, options: .atomic)
    }

    private func removeBackup() throws {
        try FileManager.default.removeItem(at: backupURL)
    }
}
