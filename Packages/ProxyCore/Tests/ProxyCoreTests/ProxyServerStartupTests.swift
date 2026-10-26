import Darwin
import Foundation
import RulesEngine
import CertKit
import FlowStore
import os
import Testing
import NIOPosix
@testable import ProxyCore

@Suite(.serialized, .productionChinese) struct ProxyServerStartupTests {
    // Omitting the pre-listener sweep leaves crash debris behind after start() returns.
    @Test func sweepOrphansRemovesOnlyOwnFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("spool")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let owned = [".spool-" + UUID().uuidString, UUID().uuidString + ".body"]
        let foreign = ["notes.txt", ".spool-not-a-uuid", UUID().uuidString.lowercased() + ".body"]
        for name in owned + foreign { try Data([1]).write(to: directory.appendingPathComponent(name)) }
        let outside = root.appendingPathComponent(UUID().uuidString + ".body")
        try Data([2]).write(to: outside)
        let link = UUID().uuidString + ".body"
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent(link), withDestinationURL: outside)
        let limits = RulesLimits()
        let runtime = BreakpointBodyRuntime(directory: directory, budgets: OwnedFileBudgets(limits: limits), limits: limits)
        try await withExpectProxy(runtime: runtime) { server, _, _ in
            #expect(server.boundPort != nil)
            let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            let untouched = try Data(contentsOf: outside)
            #expect(Set(files) == Set(foreign + [link, SpoolDirectoryOwner.markerName]))
            #expect(untouched == Data([2]))
        }
        // Restarts reuse the same runtime only after prior sources and pool have drained.
        try Data([3]).write(to: directory.appendingPathComponent(owned[0]))
        #expect(chmod(directory.path, 0o755) == 0)
        await #expect(throws: (any Error).self) {
            try await withExpectProxy(runtime: runtime) { _, _, _ in Issue.record("unsafe directory admitted") }
        }
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(owned[0]).path))
        var unsafeInfo = stat()
        #expect(lstat(directory.path, &unsafeInfo) == 0 && unsafeInfo.st_mode & 0o777 == 0o755)
        // A symlink to an otherwise safe directory must not turn its target into our ownership.
        #expect(chmod(directory.path, 0o700) == 0)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        let linked = BreakpointBodyRuntime(directory: alias, budgets: OwnedFileBudgets(limits: limits), limits: limits)
        await #expect(throws: (any Error).self) {
            try await withExpectProxy(runtime: linked) { _, _, _ in Issue.record("symlink directory admitted") }
        }
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(owned[0]).path))
        var linkInfo = stat()
        #expect(lstat(alias.path, &linkInfo) == 0 && linkInfo.st_mode & S_IFMT == S_IFLNK)
    }
}

extension ProxyServerStartupTests {
    // The importer really holds the shared .io reservation across afterChunk; a separate runtime
    // budget would incorrectly let the collector allocate another twelve bytes here.
    @Test func singleBudgetSharedAcrossAssetsAndBreakpoints() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("input")
        try Data(repeating: 1, count: 12).write(to: source)
        var limits = RulesLimits(); limits.ioBufferBytes = 12; limits.ioChunkBytes = 12
        limits.assetStoreBytes = 12; limits.breakpointSpoolBytes = 4
        let budgets = OwnedFileBudgets(limits: limits)
        let reached = OSAllocatedUnfairLock(initialState: false)
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let assets = ManagedAssetStore(directory: root.appendingPathComponent("assets"), limits: limits, budgets: budgets, afterChunk: { _ in
            reached.withLock { $0 = true }
            if release.wait(timeout: .now() + 5) == .timedOut { timedOut.withLock { $0 = true } }
        })
        let importing = Task { try await assets.importFile(source, displayName: "asset") }
        do {
            try await waitUntil("asset import holds buffer") { reached.withLock { $0 } }
            #expect(budgets.snapshot().bytes[.asset] == 12 && budgets.snapshot().bytes[.io] == 12)
            let b = BreakpointCoordinator(limits: limits)
            var rule = TestRules.breakpoint(.request); rule.action = .breakpoint(direction: .request, mode: .fullBody)
            try await withExpectProxy(rules: TestRules.provider([rule]), breakpoints: b, assets: assets) { server, origin, store in
                let c = try await RawClient.connect(port: try #require(server.boundPort))
                var firstClosed = false
                do {
                    let head = "POST http://127.0.0.1:\(origin.port)/expect HTTP/1.1\r\nHost: localhost\r\nExpect: 100-continue\r\nContent-Length: 4\r\n\r\n"
                    try await c.send(head)
                    #expect(try await c.receive(until: "\r\n\r\n").contains("100 Continue"))
                    #expect(budgets.snapshot().bytes[.asset] == 12 && budgets.snapshot().bytes[.breakpoint] == 4)
                    try await c.send("data")
                    #expect(try await c.receive(until: "\r\n\r\n").contains("502 Bad Gateway"))
                    _ = try await waitForFlow(store) { $0.messages[.generatedResponse]?.status == 502 }
                    #expect(origin.acceptedConnections == 0)
                    firstClosed = true
                    try await c.close()
                    try await waitUntil("collector quota returned") { (budgets.snapshot().bytes[.breakpoint] ?? 0) == 0 }
                    #expect(budgets.snapshot().bytes[.io] == 12)
                    release.signal()
                    let asset = try await importing.value
                    #expect(budgets.snapshot().bytes[.asset] == 12 && (budgets.snapshot().bytes[.io] ?? 0) == 0)
                    // A clean new request succeeds after the importer relinquishes its buffer.
                    let next = try await RawClient.connect(port: try #require(server.boundPort))
                    do {
                        try await next.send(head)
                        #expect(try await next.receive(until: "\r\n\r\n").contains("100 Continue"))
                        try await next.send("data")
                        try await waitUntil("new body collected") { b.snapshot().first?.state == .pausedBody }
                        let t = try #require(b.snapshot().first)
                        #expect(await b.perform(.continue(token: t.token, edit: .init(head: t.effectiveHead))) == .accepted)
                        #expect(try await next.receive(until: "\r\n\r\n").contains("200 OK"))
                        #expect(try await next.receive(count: 4) == Array("data".utf8))
                        _ = try await waitForFlow(store) { $0.state == .completed }
                        try await next.close()
                    } catch { try? await next.close(); throw error }
                    await assets.discardImports([asset.id])
                } catch { release.signal(); if !firstClosed { try? await c.close() }; throw error }
            }
            #expect(budgets.snapshot().reservedBytes == 0)
            #expect(budgets.snapshot().peak[.io] == 12)
            #expect(!timedOut.withLock { $0 })
        } catch { release.signal(); _ = try? await importing.value; throw error }
    }
    @Test func configuredSpoolDirectorySweepsBeforeEachRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = root.appendingPathComponent("spool")
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let body = spool.appendingPathComponent(UUID().uuidString + ".body")
        let preserved = root.appendingPathComponent(UUID().uuidString + ".body")
        try Data([9]).write(to: preserved)
        var config = ProxyConfiguration(); config.port = 0
        let server = ProxyServer(configuration: config, certificateAuthority: try CertificateAuthority.generate(),
            store: FlowStore(bodyDirectory: root.appendingPathComponent("capture")), passthrough: PassthroughRegistry(),
            processLookup: .none, breakpointSpoolDirectory: spool)
        do {
            for _ in 0..<2 {
                try Data([1]).write(to: body)
                try await server.start()
                #expect(!FileManager.default.fileExists(atPath: body.path))
                #expect(try Data(contentsOf: preserved) == Data([9]))
                try await server.stop()
            }
        } catch { try? await server.stop(); throw error }
    }
}

// Removing directory ownership or first-use parent preparation breaks these real requests.
extension ProxyServerStartupTests {
    @Test func competingServerCannotSweepAnActiveSpool() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = root.appendingPathComponent("spool")
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let entered = OSAllocatedUnfairLock(initialState: false)
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let limits = RulesLimits()
        let runtime = BreakpointBodyRuntime(directory: spool, budgets: OwnedFileBudgets(limits: limits), limits: limits,
            hooks: .init(beforeFinish: {
                entered.withLock { $0 = true }
                if release.wait(timeout: .now() + 5) == .timedOut { timedOut.withLock { $0 = true } }
            }))
        var config = ProxyConfiguration(); config.port = 0
        let other = ProxyServer(configuration: config, certificateAuthority: try CertificateAuthority.generate(),
            store: FlowStore(bodyDirectory: root.appendingPathComponent("other-capture")), passthrough: PassthroughRegistry(),
            processLookup: .none, breakpointSpoolDirectory: spool)
        let b = BreakpointCoordinator()
        var rule = TestRules.breakpoint(.request); rule.action = .breakpoint(direction: .request, mode: .fullBody)
        do {
            try await withExpectProxy(rules: TestRules.provider([rule]), breakpoints: b, runtime: runtime) { server, origin, store in
                let client = try await RawClient.connect(port: try #require(server.boundPort))
                do {
                    try await client.send("POST http://127.0.0.1:\(origin.port)/expect HTTP/1.1\r\nHost: localhost\r\nExpect: 100-continue\r\nContent-Length: 4\r\n\r\n")
                    #expect(try await client.receive(until: "\r\n\r\n").contains("100 Continue"))
                    try await client.send("data")
                    try await waitUntil("unfinished spool exists") { entered.withLock { $0 } }
                    let active = try FileManager.default.contentsOfDirectory(atPath: spool.path).filter { $0.hasPrefix(".spool-") }
                    #expect(active.count == 1)
                    var refused = false
                    do { try await other.start() } catch { refused = true }
                    #expect(refused && other.boundPort == nil)
                    let sweepGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
                    let sweepPool = NIOThreadPool(numberOfThreads: 1); sweepPool.start()
                    let standalone = BodyFileIO(directory: spool, eventLoop: sweepGroup.next(), budgets: OwnedFileBudgets(limits: limits),
                        limits: limits, threadPool: sweepPool)
                    await standalone.sweepOrphans()
                    try await sweepPool.shutdownGracefully()
                    try await sweepGroup.shutdownGracefully()
                    #expect(active.allSatisfy { FileManager.default.fileExists(atPath: spool.appendingPathComponent($0).path) })
                    release.signal()
                    try await finishStartupUpload(client, coordinator: b, store: store)
                    #expect(!timedOut.withLock { $0 })
                } catch { release.signal(); try? await client.close(); throw error }
                try await client.close()
            }
            // Once A drains/stops, B may acquire the stable directory and recover real debris.
            try await other.stop() // also closes the erroneously admitted server during RED
            let leftover = spool.appendingPathComponent(".spool-" + UUID().uuidString)
            try Data([9]).write(to: leftover)
            try await other.start()
            #expect(!FileManager.default.fileExists(atPath: leftover.path))
            try await other.stop()
        } catch { release.signal(); try? await other.stop(); throw error }
    }

    @Test func firstSmallExpectUploadCreatesMissingCacheParents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cache = root.appendingPathComponent("Caches/ProxyWoman")
        let spool = cache.appendingPathComponent("BreakpointSpool")
        // URL-only FlowStore initialization cannot supply the missing parent for a small capture.
        let capture = FlowStore(bodyDirectory: cache.appendingPathComponent("Bodies"))
        #expect(capture.allFlows().isEmpty && !FileManager.default.fileExists(atPath: cache.path))
        let limits = RulesLimits()
        let runtime = BreakpointBodyRuntime(directory: spool, budgets: OwnedFileBudgets(limits: limits), limits: limits)
        let b = BreakpointCoordinator()
        var rule = TestRules.breakpoint(.request); rule.action = .breakpoint(direction: .request, mode: .fullBody)
        try await withExpectProxy(rules: TestRules.provider([rule]), breakpoints: b, runtime: runtime) { server, origin, store in
            let client = try await RawClient.connect(port: try #require(server.boundPort))
            do {
                try await client.send("POST http://127.0.0.1:\(origin.port)/expect HTTP/1.1\r\nHost: localhost\r\nExpect: 100-continue\r\nContent-Length: 4\r\n\r\n")
                #expect(try await client.receive(until: "\r\n\r\n").contains("100 Continue"))
                try await client.send("data")
                try await finishStartupUpload(client, coordinator: b, store: store)
                #expect(!FileManager.default.fileExists(atPath: cache.appendingPathComponent("Bodies").path))
            } catch { try? await client.close(); throw error }
            try await client.close()
        }
    }
}

private func finishStartupUpload(_ client: RawClient, coordinator: BreakpointCoordinator, store: FlowStore) async throws {
    try await waitUntil("body ready or actual upload failure") {
        coordinator.snapshot().first?.state == .pausedBody || store.allFlows().contains { $0.messages[.generatedResponse]?.status == 502 }
    }
    if let ticket = coordinator.snapshot().first, ticket.state == .pausedBody {
        #expect(await coordinator.perform(.continue(token: ticket.token, edit: .init(head: ticket.effectiveHead))) == .accepted)
    }
    let response = try await client.receive(until: "\r\n\r\n")
    #expect(response.contains("200 OK"))
    if response.contains("200 OK") {
        #expect(try await client.receive(count: 4) == Array("data".utf8))
        _ = try await waitForFlow(store) { $0.state == .completed }
    }
}

// These controls catch a process-local lock, premature release, unsafe path following and bind leaks.
extension ProxyServerStartupTests {
    @Test func directoryOwnerSurvivesOtherProcessesAndRecoversAfterTheirExit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = root.appendingPathComponent("spool")
        let a = try startupServer(spool: spool)
        // The OS /var alias and physical /private/var spelling must share one kernel lock.
        let physical = URL(fileURLWithPath: spool.path.hasPrefix("/var/") ? "/private" + spool.path : spool.path)
        let b = try startupServer(spool: physical)
        let independent = try startupServer(spool: root.appendingPathComponent("independent"))
        let child = Process()
        let input = Pipe(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        let script = "open(my $f, '+<', $ARGV[0]) or exit 3; flock($f, 6) or exit 2; if ($ARGV[1] eq 'hold') { $|=1; print 'L'; sysread(STDIN, my $x, 1); } exit 0;"
        child.arguments = ["-e", script, spool.appendingPathComponent(SpoolDirectoryOwner.markerName).path, "hold"]
        child.standardInput = input; child.standardOutput = output
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        do {
            try await a.start()
            #expect(a.boundPort != nil)
            try await independent.start()
            #expect(independent.boundPort != nil)
            await #expect(throws: (any Error).self) { try await b.start() }
            #expect(b.boundPort == nil)
            let marker = spool.appendingPathComponent(SpoolDirectoryOwner.markerName)
            var before = stat(); #expect(lstat(marker.path, &before) == 0)
            let probe = Process(); probe.executableURL = child.executableURL
            probe.arguments = ["-e", script, marker.path, "probe"]
            try probe.run(); probe.waitUntilExit()
            #expect(probe.terminationReason == .exit && probe.terminationStatus == 2)
            try await a.stop()
            try child.run()
            try #require(output.fileHandleForReading.readData(ofLength: 1) == Data("L".utf8))
            let orphan = spool.appendingPathComponent(".spool-" + UUID().uuidString)
            try Data([7]).write(to: orphan)
            await #expect(throws: (any Error).self) { try await b.start() }
            #expect(FileManager.default.fileExists(atPath: orphan.path))
            // Kernel ownership vanishes on process termination, despite the persistent marker.
            child.terminate(); child.waitUntilExit()
            #expect(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGTERM)
            try await b.start()
            #expect(!FileManager.default.fileExists(atPath: orphan.path))
            var after = stat(); #expect(lstat(marker.path, &after) == 0)
            #expect(before.st_ino == after.st_ino && before.st_dev == after.st_dev)
            try await b.stop(); try await independent.stop()
        } catch {
            if child.isRunning { child.terminate(); child.waitUntilExit() }
            try? await a.stop(); try? await b.stop(); try? await independent.stop(); throw error
        }
    }

    @Test func directoryOwnerIsHeldUntilCancelledFinishActuallyDrains() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = root.appendingPathComponent("spool")
        let entered = OSAllocatedUnfairLock(initialState: false)
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let limits = RulesLimits(), b = BreakpointCoordinator()
        let runtime = BreakpointBodyRuntime(directory: spool, budgets: OwnedFileBudgets(limits: limits), limits: limits,
            hooks: .init(beforeFinish: {
                entered.withLock { $0 = true }
                if release.wait(timeout: .now() + 5) == .timedOut { timedOut.withLock { $0 = true } }
            }))
        let successor = try startupServer(spool: spool)
        var rule = TestRules.breakpoint(.request); rule.action = .breakpoint(direction: .request, mode: .fullBody)
        do {
            try await ProxyFixture.run(processLookup: .none, rules: TestRules.provider([rule]), breakpoints: b,
                bodyRuntime: runtime, drainDeadline: .init(schedule: { loop, expire in loop.execute(expire); return {} })) { f in
                let client = try await RawClient.connect(port: f.proxyPort)
                do {
                    try await client.send("POST http://127.0.0.1:\(f.origin.port)/expect HTTP/1.1\r\nHost: localhost\r\nContent-Length: 4\r\n\r\ndata")
                    try await waitUntil("finishing file work entered") { entered.withLock { $0 } }
                    let stopped = OSAllocatedUnfairLock(initialState: false)
                    let stopping = Task { try await f.server.stop(); stopped.withLock { $0 = true } }
                    do {
                        try await waitUntil("stop revoked collection") { b.snapshot().isEmpty }
                        #expect(runtime.activePins == 1 && !stopped.withLock { $0 })
                        await #expect(throws: (any Error).self) { try await successor.start() }
                        #expect(successor.boundPort == nil)
                        let files = try FileManager.default.contentsOfDirectory(atPath: spool.path)
                        #expect(files.filter { $0.hasPrefix(".spool-") }.count == 1)
                        release.signal()
                        try await stopping.value
                        #expect(runtime.activePins == 0 && runtime.budgets.snapshot().reservedBytes == 0)
                        #expect(!timedOut.withLock { $0 })
                        #expect(try FileManager.default.contentsOfDirectory(atPath: spool.path) == [SpoolDirectoryOwner.markerName])
                        try await successor.start()
                        try await successor.stop()
                    } catch { release.signal(); _ = try? await stopping.value; throw error }
                } catch { release.signal(); try? await client.close(); throw error }
                try await client.close()
            }
        } catch { release.signal(); try? await successor.stop(); throw error }
    }

    @Test func failedBindReleasesDirectoryOwnerBeforeRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let occupied = try await TestOriginServer.start()
        let spool = root.appendingPathComponent("spool")
        let failed = try startupServer(spool: spool, port: occupied.port)
        let successor = try startupServer(spool: spool)
        do {
            await #expect(throws: ProxyServerError.portUnavailable) { try await failed.start() }
            #expect(failed.boundPort == nil)
            try await successor.start()
            #expect(successor.boundPort != nil)
            try await successor.stop()
            failed.updateConfiguration { $0.port = 0 }
            try await failed.start()
            #expect(failed.boundPort != nil)
            try await failed.stop()
        } catch { try? await successor.stop(); try? await failed.stop(); try? await occupied.stop(); throw error }
        try await occupied.stop()
    }

    @Test(arguments: ["parent-file", "parent-symlink", "marker-symlink", "marker-hardlink", "unsafe-marker"])
    func startupRefusesUnsafePathsWithoutMutatingThem(kind: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let untouched = target.appendingPathComponent(UUID().uuidString + ".body")
        try Data([8]).write(to: untouched)
        let parent = root.appendingPathComponent("parent")
        let spool: URL
        if kind == "parent-file" {
            try Data([1, 2]).write(to: parent); spool = parent.appendingPathComponent("spool")
        } else if kind == "parent-symlink" {
            try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: target)
            spool = parent.appendingPathComponent("spool")
        } else {
            spool = target
            let marker = spool.appendingPathComponent(SpoolDirectoryOwner.markerName)
            if kind == "marker-symlink" { try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: untouched) }
            else if kind == "marker-hardlink" { #expect(link(untouched.path, marker.path) == 0) }
            else { try Data([3]).write(to: marker); #expect(chmod(marker.path, 0o644) == 0) }
        }
        let server = try startupServer(spool: spool)
        await #expect(throws: (any Error).self) { try await server.start() }
        #expect(server.boundPort == nil)
        #expect(try Data(contentsOf: untouched) == Data([8]))
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("spool").path))
        if kind == "parent-file" { #expect(try Data(contentsOf: parent) == Data([1, 2])) }
        if kind == "parent-symlink" {
            var info = stat(); #expect(lstat(parent.path, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK)
        }
        if kind == "unsafe-marker" {
            var info = stat(); #expect(lstat(target.appendingPathComponent(SpoolDirectoryOwner.markerName).path, &info) == 0)
            #expect(info.st_mode & 0o777 == 0o644)
        }
        try await server.stop()
    }

    @Test func preparingMissingChildrenPreservesExistingParentModeAndFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(chmod(root.path, 0o755) == 0)
        let untouched = root.appendingPathComponent(UUID().uuidString + ".body")
        try Data([2]).write(to: untouched)
        let spool = root.appendingPathComponent("ProxyWoman/BreakpointSpool")
        let server = try startupServer(spool: spool)
        do {
            try await server.start()
            var parentInfo = stat(), spoolInfo = stat()
            #expect(lstat(root.path, &parentInfo) == 0 && parentInfo.st_mode & 0o777 == 0o755)
            #expect(lstat(spool.path, &spoolInfo) == 0 && spoolInfo.st_mode & 0o777 == 0o700 && spoolInfo.st_uid == getuid())
            #expect(try Data(contentsOf: untouched) == Data([2]))
        } catch { try? await server.stop(); throw error }
        try await server.stop()
    }
}

private func startupServer(spool: URL, port: Int = 0) throws -> ProxyServer {
    var config = ProxyConfiguration(); config.port = port; config.portFallbackCount = 0
    return ProxyServer(configuration: config, certificateAuthority: try CertificateAuthority.generate(),
        store: FlowStore(bodyDirectory: spool.deletingLastPathComponent().appendingPathComponent("capture")),
        passthrough: PassthroughRegistry(), processLookup: .none, breakpointSpoolDirectory: spool)
}
