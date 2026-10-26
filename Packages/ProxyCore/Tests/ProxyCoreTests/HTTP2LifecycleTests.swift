import CertKit
import FlowStore
import Foundation
import NIOSSL
import NIOCore
import NIOHTTP1
import NIOHTTP2
import NIOHPACK
import Testing
import os
@testable import ProxyCore

@Suite(.productionChinese) struct HTTP2LifecycleTests {
    @Test func actualH2ParentRejectsNewWireStreamAfterAdmissionCutoffWithoutFlow() async throws {
        try await withHTTP2ControlLoop { loop in
            let run = ProxyRunConnections(loop: loop)
            try await HTTP2TestOrigin.withOrigin(protocols: ["h2"]) { origin in
                let fixture = try await HTTP2ProxyFixture.start(origin: origin, runConnections: run)
                let client = try await HTTP2TestClient.connect(origin: origin,
                    tls: TLSInterception(certificateAuthority: fixture.ca),
                    roots: .certificates([try NIOSSLCertificate(bytes: fixture.ca.rootCertificateDER, format: .der)]),
                    proxyPort: fixture.channel.localAddress!.port!)
                do {
                    #expect(try await client.rawRequest(headers: lifecycleHeaders(origin, "/before")).status == 200)
                    run.stopAdmission() // Synchronous cutoff; parent stays open, without GOAWAY.
                    #expect(client.channel.isActive)
                    // One complete HEADERS frame avoids racing a second DATA write with
                    // the expected immediate RST_STREAM from the server admission gate.
                    do {
                        _ = try await client.rawRequest(headers: lifecycleHeaders(origin, "/after"))
                        Issue.record("Post-cutoff wire stream succeeded")
                    } catch {
                        #expect(error is NIOHTTP2Errors.StreamClosed || (error as? HTTPTransportError) == .closed)
                    }
                    #expect(client.channel.isActive)
                    #expect(fixture.store.allFlows().map(\.path) == ["/before"])
                    #expect(origin.counts.paths == ["/before"])
                    print("Direct H2 cutoff: live TLS parent, new HEADERS rejected; no /after Flow or origin request")
                    try await client.stop(); try await run.drain().boundedGet(); try await fixture.stop()
                } catch {
                    try? await client.stop(); try? await run.drain().boundedGet(); try? await fixture.stop(); throw error
                }
            }
        }
    }

    @Test func concurrentStopAndRestartWaitForRunCleanupDespiteCallerCancellation() async throws {
        try await withHTTP2ControlLoop { loop in
            let lookupStarted = loop.makePromise(of: Void.self)
            let lookupRelease = DispatchSemaphore(value: 0)
            let seen = loop.makePromise(of: Void.self)
            let responseRelease = loop.makePromise(of: Void.self)
            let deadlineStarted = loop.makePromise(of: Void.self)
            let expiry = loop.makePromise(of: Void.self)
            let scheduled = OSAllocatedUnfairLock(initialState: false)
            let deadline = ProxyDrainDeadline { target, action in
                if scheduled.withLock({ old in defer { old = true }; return !old }) { deadlineStarted.succeed(()) }
                expiry.futureResult.hop(to: target).whenSuccess { action() }
                return {}
            }
            var response = HTTP2TestOrigin.Response()
            response.requestsObserved = seen; response.barrier = responseRelease.futureResult
            try await HTTP2TestOrigin.withOrigin(protocols: ["h2"], response: response) { origin in
                let ca = try CertificateAuthority.generate(commonName: "Run join fixture")
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: directory) }
                let store = FlowStore(bodyDirectory: directory)
                var config = ProxyConfiguration(); config.port = 0
                config.upstreamTrustRoots = .certificates([try NIOSSLCertificate(bytes: origin.ca.rootCertificateDER, format: .der)])
                let server = ProxyServer(configuration: config, certificateAuthority: ca, store: store,
                    passthrough: PassthroughRegistry(), processLookup: ProcessLookup(lookup: { _, _ in
                        lookupStarted.succeed(())
                        lookupRelease.wait()
                        return nil
                    }), drainDeadline: deadline)
                try await server.start()
                let port: Int = try #require(server.boundPort)
                let client = try await HTTP2TestClient.connect(origin: origin, tls: TLSInterception(certificateAuthority: ca),
                    roots: .certificates([try NIOSSLCertificate(bytes: ca.rootCertificateDER, format: .der)]),
                    proxyPort: port)
                var released = false
                do {
                    let request = try await client.startRawRequest(headers: lifecycleHeaders(origin, "/held"))
                    try await request.end()
                    try await lookupStarted.futureResult.boundedGet()
                    try await seen.futureResult.boundedGet()
                    let stopped = OSAllocatedUnfairLock(initialState: false)
                    let restarted = OSAllocatedUnfairLock(initialState: false)
                    let first = Task { try await server.stop() }
                    try await deadlineStarted.futureResult.boundedGet()
                    let secondEntered = loop.makePromise(of: Void.self)
                    let restartEntered = loop.makePromise(of: Void.self)
                    let second = Task { secondEntered.succeed(()); try await server.stop(); stopped.withLock { $0 = true } }
                    let restart = Task { restartEntered.succeed(()); try await server.start(); restarted.withLock { $0 = true } }
                    try await secondEntered.futureResult.boundedGet()
                    try await restartEntered.futureResult.boundedGet()
                    first.cancel()
                    expiry.succeed(())
                    try await client.channel.closeFuture.boundedGet()
                    // The old run still owns a real lookup worker. Socket close is not stop completion.
                    #expect(!stopped.withLock { $0 })
                    #expect(!restarted.withLock { $0 })
                    #expect(server.boundPort == nil)
                    lookupRelease.signal(); released = true
                    responseRelease.succeed(())
                    try await first.value; try await second.value; try await restart.value
                    #expect(stopped.withLock { $0 } && restarted.withLock { $0 })
                    #expect(server.boundPort != nil)
                    do { _ = try await request.response.boundedGet(); Issue.record("Expired response succeeded") } catch {}
                    try await client.stop(); try await server.stop()
                } catch {
                    if !released { lookupRelease.signal(); responseRelease.succeed(()) }
                    try? await client.stop(); try? await server.stop(); throw error
                }
            }
        }
    }

    @Test func runExpiryRetainsActualH2ChildInitializationUntilItSettles() async throws {
        try await withHTTP2ControlLoop { loop in
            let childStarted = loop.makePromise(of: Void.self)
            let childRelease = loop.makePromise(of: Void.self)
            let deadlineStarted = loop.makePromise(of: Void.self)
            let expiry = loop.makePromise(of: Void.self)
            let run = ProxyRunConnections(loop: loop, deadline: ProxyDrainDeadline { target, action in
                deadlineStarted.succeed(())
                expiry.futureResult.hop(to: target).whenSuccess { action() }
                return {}
            })
            let joined = OSAllocatedUnfairLock(initialState: false)
            try await HTTP2TestOrigin.withOrigin(protocols: ["h2"]) { origin in
                let fixture = try await HTTP2ProxyFixture.start(origin: origin, streamCreationGate: { child in
                    childStarted.succeed(())
                    return childRelease.futureResult.hop(to: child.eventLoop)
                }, runConnections: run)
                var client: HTTP2TestClient?
                var released = false
                do {
                    let connected = try await HTTP2TestClient.connect(origin: origin,
                        tls: TLSInterception(certificateAuthority: fixture.ca),
                        roots: .certificates([try NIOSSLCertificate(bytes: fixture.ca.rootCertificateDER, format: .der)]),
                        proxyPort: fixture.channel.localAddress!.port!)
                    client = connected
                    let request = try await connected.startRawRequest(headers: lifecycleHeaders(origin, "/creating"))
                    try await request.end()
                    try await childStarted.futureResult.boundedGet()
                    run.stopAdmission()
                    let cleanup = run.drain()
                    cleanup.whenSuccess { joined.withLock { $0 = true } }
                    try await deadlineStarted.futureResult.boundedGet()
                    expiry.succeed(())
                    try await connected.channel.closeFuture.boundedGet()
                    let upstream = try #require(fixture.upstreams.withLock { $0.first })
                    try await upstream.closeFuture.boundedGet()
                    #expect(!joined.withLock { $0 })
                    childRelease.succeed(()); released = true
                    try await cleanup.boundedGet()
                    #expect(joined.withLock { $0 })
                    #expect(origin.counts.requests == 0)
                    #expect(fixture.store.allFlows().allSatisfy { $0.completedAt != nil && $0.state != .completed })
                    do { _ = try await request.response.boundedGet(); Issue.record("Expired request succeeded") } catch {}
                    try await connected.stop(); try await fixture.stop()
                } catch {
                    if !released { childRelease.succeed(()) }
                    if let client { try? await client.stop() }
                    try? await fixture.stop(); throw error
                }
            }
        }
    }

    @Test(arguments: [false, true])
    func actualControlFramesDuringCreationDoNotAdmitPastPeerState(goAway: Bool) async throws {
        try await withHTTP2ControlLoop { loop in
            let started = loop.makePromise(of: Void.self)
            let signalled = OSAllocatedUnfairLock(initialState: false)
            let gate = loop.makePromise(of: Void.self)
            try await HTTP2TestOrigin.withOrigin(protocols: ["h2"]) { origin in
                try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true,
                    streamCreationGate: { child in
                        if signalled.withLock({ value in if value { return false }; value = true; return true }) { started.succeed(()) }
                        return gate.futureResult.hop(to: child.eventLoop)
                    }) { fixture, client in
                    var released = false
                    defer { if !released { gate.succeed(()) } }
                    let pending = try await client.startRawRequest(headers: lifecycleHeaders(origin, "/pending"))
                    try await pending.end(); try await started.futureResult.boundedGet()
                    let parent = try #require(origin.counts.parents.first)
                    let upstream = try #require(fixture.upstreams.withLock { $0.first })
                    #expect(try await lifecycleSnapshot(fixture).sessions.first?.reservedStreams == 1)
                    if goAway {
                        let observed = try await HTTP2FixtureControlBarrier.install(on: upstream)
                        try await parent.writeAndFlush(HTTP2Frame(streamID: .rootStream,
                            payload: .goAway(lastStreamID: .rootStream, errorCode: .noError, opaqueData: nil))).boundedGet()
                        try await observed.boundedGet()
                    } else { try await lifecycleSetting(parent: parent, upstream: upstream, maximum: 0) }
                    let controlled = try await lifecycleSnapshot(fixture)
                    if goAway {
                        // The pool's session snapshot contains only live parents; an
                        // unsettled child can remain in opening after parent close.
                        #expect(controlled.pending == 0)
                        #expect(controlled.acquisitionTimers == 0)
                        #expect(controlled.opening <= 1)
                        if controlled.sessions.isEmpty {
                            #expect(!upstream.isActive)
                            try await upstream.closeFuture.boundedGet()
                            #expect(controlled.physicalSockets == 0)
                            #expect(controlled.socketReservations == 0)
                        } else {
                            #expect(controlled.sessions.reduce(0) { $0 + $1.reservedStreams } == controlled.opening)
                            #expect(controlled.sessions.reduce(0) { $0 + $1.creatingStreams } == controlled.opening)
                        }
                    } else { #expect(controlled.sessions.first?.reservedStreams == 1) }
                    print("HTTP2 gated control snapshot (GOAWAY=\(goAway)): \(controlled)")
                    #expect(origin.counts.requests == 0)
                    gate.succeed(()); released = true
                    if goAway {
                        #expect(try await pending.response.boundedGet().status == 502)
                        try await upstream.closeFuture.boundedGet()
                    } else {
                        try await HTTP2FlowControlFixture.ping(upstream)
                        #expect(origin.counts.requests == 0)
                        try await lifecycleSetting(parent: parent, upstream: upstream, maximum: 1)
                        #expect(try await pending.response.boundedGet().status == 200)
                        #expect(origin.counts.streamIDs == [1])
                    }
                    #expect(try await client.rawRequest(headers: lifecycleHeaders(origin, "/healthy")).status == 200)
                    #expect(origin.counts.paths == (goAway ? ["/healthy"] : ["/pending", "/healthy"]))
                    #expect(try await lifecycleSnapshot(fixture).opening == 0)
                    #expect(try await lifecycleSnapshot(fixture).pending == 0)
                    #expect(try await lifecycleSnapshot(fixture).acquisitionTimers == 0)
                }
            }
        }
    }

    @Test func failedCreationsConsumeLifetimeBudgetConservatively() throws {
        var limits = HTTPTransportLimits(); limits.upstreamStreamCreationsPerSession = 2
        let fixture = try HTTP2LifecycleFixture(limits: limits)
        defer { fixture.stop() }
        var failures = 0
        for index in 0..<2 {
            fixture.session.openStream(responseSink: PoolSink()).assumeIsolated().whenFailure { _ in failures += 1 }
            fixture.loop.run(); fixture.complete(index, fail: true)
        }
        #expect(failures == 2)
        #expect(fixture.session.snapshot.streamCreations == 2)
        #expect(fixture.session.snapshot.reservedStreams == 0)
        #expect(fixture.session.snapshot.creatingStreams == 0)
        #expect(fixture.session.isDraining)
        #expect(!fixture.parent.isActive)
    }

    @Test func actualStopDrainsAdmittedResponsesAfterGoAwayBeforeClosingClient() async throws {
        try await withHTTP2ControlLoop { loop in
            let seen = loop.makePromise(of: Void.self)
            let gate = loop.makePromise(of: Void.self)
            var response = HTTP2TestOrigin.Response()
            response.requestsObserved = seen; response.requestCountTarget = 2
            response.barrier = gate.futureResult
            try await HTTP2TestOrigin.withOrigin(protocols: ["h2"], response: response) { origin in
                let ca = try CertificateAuthority.generate(commonName: "Task6 stop fixture")
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: directory) }
                let store = FlowStore(bodyDirectory: directory)
                var config = ProxyConfiguration(); config.port = 0
                config.upstreamTrustRoots = .certificates([try NIOSSLCertificate(bytes: origin.ca.rootCertificateDER, format: .der)])
                let server = ProxyServer(configuration: config, certificateAuthority: ca, store: store,
                    passthrough: PassthroughRegistry(), processLookup: ProcessLookup(lookup: { _, _ in nil }))
                try await server.start()
                let port: Int = try #require(server.boundPort)
                let client = try await HTTP2TestClient.connect(origin: origin, tls: TLSInterception(certificateAuthority: ca),
                    roots: .certificates([try NIOSSLCertificate(bytes: ca.rootCertificateDER, format: .der)]),
                    proxyPort: port)
                var released = false
                do {
                    let first = Task { try await client.request(headers: HTTPHeaders([("host", "localhost:\(origin.port)")]), path: "/one") }
                    let second = Task { try await client.request(headers: HTTPHeaders([("host", "localhost:\(origin.port)")]), path: "/two") }
                    try await seen.futureResult.boundedGet()
                    let notified = try await HTTP2FixtureControlBarrier.install(on: client.channel)
                    let stopping = Task { try await server.stop() }
                    // Both old abort and graceful GOAWAY unblock this real wire barrier.
                    // Only graceful drain can deliver the origin responses released afterward.
                    do { try await notified.boundedGet() } catch { #expect(!(error is HTTP2FixtureDeadlineExceeded)) }
                    gate.succeed(()); released = true
                    #expect(server.boundPort == nil)
                    for request in [first, second] {
                        do { #expect(try await request.value.status == 200) }
                        catch { Issue.record("Admitted response aborted before grace completed: \(error)") }
                    }
                    try await stopping.value
                    try await client.channel.closeFuture.boundedGet()
                    #expect(store.allFlows().count == 2)
                    #expect(store.allFlows().allSatisfy { $0.completedAt != nil && $0.state == .completed })
                    try await client.stop()
                } catch {
                    if !released { gate.succeed(()) }
                    try? await client.stop(); try? await server.stop()
                    throw error
                }
            }
        }
    }

    @Test func actualProxyServerStopSettlesActiveH2FlowsAndClosesClient() async throws {
        try await withHTTP2ControlLoop { loop in
            let deadlineStarted = loop.makePromise(of: Void.self)
            let expire = loop.makePromise(of: Void.self)
            let deadline = ProxyDrainDeadline { targetLoop, action in
                deadlineStarted.succeed(())
                expire.futureResult.hop(to: targetLoop).whenSuccess { action() }
                return {}
            }
            let seen = loop.makePromise(of: Void.self)
            let gate = loop.makePromise(of: Void.self)
            var response = HTTP2TestOrigin.Response()
            response.requestsObserved = seen; response.requestCountTarget = 2
            response.barrier = gate.futureResult
            try await HTTP2TestOrigin.withOrigin(protocols: ["h2"], response: response) { origin in
                let ca = try CertificateAuthority.generate(commonName: "Task6 stop fixture")
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: directory) }
                let store = FlowStore(bodyDirectory: directory)
                var config = ProxyConfiguration(); config.port = 0
                config.upstreamTrustRoots = .certificates([try NIOSSLCertificate(bytes: origin.ca.rootCertificateDER, format: .der)])
                let server = ProxyServer(configuration: config, certificateAuthority: ca, store: store,
                    passthrough: PassthroughRegistry(), processLookup: ProcessLookup(lookup: { _, _ in nil }), drainDeadline: deadline)
                try await server.start()
                let port: Int = try #require(server.boundPort)
                let client = try await HTTP2TestClient.connect(origin: origin, tls: TLSInterception(certificateAuthority: ca),
                    roots: .certificates([try NIOSSLCertificate(bytes: ca.rootCertificateDER, format: .der)]),
                    proxyPort: port)
                var released = false
                do {
                    let first = try await client.startRawRequest(headers: lifecycleHeaders(origin, "/one"))
                    try await first.end()
                    let second = try await client.startRawRequest(headers: lifecycleHeaders(origin, "/two"))
                    try await second.end(); try await seen.futureResult.boundedGet()
                    let firstStop = Task { try await server.stop() }
                    try await deadlineStarted.futureResult.boundedGet()
                    let secondStop = Task { try await server.stop() }
                    firstStop.cancel() // the run owns cleanup; caller cancellation cannot abandon it.
                    expire.succeed(())
                    try await firstStop.value; try await secondStop.value
                    try await server.stop()
                    #expect(server.boundPort == nil)
                    for request in [first, second] {
                        do { _ = try await request.response.boundedGet(); Issue.record("Stopped request succeeded") } catch { #expect(!(error is HTTP2FixtureDeadlineExceeded)) }
                    }
                    try await client.channel.closeFuture.boundedGet()
                    #expect(store.allFlows().count == 2)
                    #expect(store.allFlows().allSatisfy { $0.completedAt != nil && $0.state != .completed })
                    gate.succeed(()); released = true
                    try await client.stop()
                } catch {
                    if !released { gate.succeed(()) }
                    try? await client.stop(); try? await server.stop()
                    throw error
                }
            }
        }
    }

    @Test func idleAndDrainDeadlinesRemoveTimersAndRetainUnsettledCreation() throws {
        var limits = HTTPTransportLimits()
        limits.idleTimeout = .seconds(1)
        let idle = try HTTP2LifecycleFixture(limits: limits)
        defer { idle.stop() }
        var lease: UpstreamLease?
        idle.session.openStream(responseSink: PoolSink()).assumeIsolated().whenSuccess { lease = $0 }
        idle.loop.run(); idle.complete(0)
        try #require(lease).release(reusable: true)
        #expect(idle.session.snapshot.idleTimers == 1)
        idle.loop.advanceTime(by: .seconds(1))
        #expect(!idle.parent.isActive)
        #expect(idle.session.snapshot.idleTimers == 0)
        limits.upstreamStreamCreationsPerSession = 1; limits.drainTimeout = .seconds(1)
        let drain = try HTTP2LifecycleFixture(limits: limits)
        defer { drain.stop() }
        var settlements = 0
        drain.session.openStream(responseSink: PoolSink()).assumeIsolated().whenComplete { _ in settlements += 1 }
        drain.loop.run()
        #expect(drain.session.snapshot.drainTimers == 1)
        drain.loop.advanceTime(by: .seconds(1))
        #expect(!drain.parent.isActive)
        #expect(drain.session.snapshot.reservedStreams == 1)
        #expect(drain.session.snapshot.drainTimers == 0)
        drain.complete(0)
        #expect(settlements == 1)
        #expect(drain.session.snapshot.reservedStreams == 0)
    }

    @Test func lifetimeLimitClampsToAllocatorSafeRange() {
        var limits = HTTPTransportLimits()
        #expect(limits.upstreamStreamCreationsPerSession == 1_073_741_823)
        // Tagged allocator starts at 1 and increments Int32 by 2 during allocation.
        // Last permitted allocation is 2_147_483_645, whose next value fits Int32.
        #expect(Int64(limits.upstreamStreamCreationsPerSession) * 2 + 1 == 2_147_483_647)
        limits.upstreamStreamCreationsPerSession = Int.max
        #expect(limits.upstreamStreamCreationsPerSession == 1_073_741_823)
        limits.upstreamStreamCreationsPerSession = 0
        #expect(limits.upstreamStreamCreationsPerSession == 1)
    }

    @Test(arguments: [false, true])
    func cancelledOpeningReleasesPendingQuotaButKeepsChildReservation(expires: Bool) async throws {
        try await withHTTP2ControlLoop { loop in
            let started = loop.makePromise(of: Void.self)
            let signalled = OSAllocatedUnfairLock(initialState: false)
            let gate = loop.makePromise(of: Void.self)
            let released = OSAllocatedUnfairLock(initialState: false)
            let releaseGate: @Sendable () -> Void = {
                if released.withLock({ value in if value { return false }; value = true; return true }) {
                    gate.succeed(())
                }
            }
            let cleanUp: @Sendable () -> Void = {
                releaseGate()
                if signalled.withLock({ value in if value { return false }; value = true; return true }) {
                    started.fail(HTTPTransportError.cancelled)
                }
            }
            // Setup and body failures both settle barriers before their loop shuts down.
            // The body must release before withProxy joins a held child on failure.
            defer { cleanUp() }
            try await HTTP2TestOrigin.withOrigin(protocols: ["h2"]) { origin in
                var limits = HTTPTransportLimits()
                limits.pendingAcquisitions = 1
                limits.totalUpstreamSockets = 1
                try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true, limits: limits,
                    streamCreationGate: { child in
                        // Only the first child needs a start signal. Every gate is resolved by
                        // the same future before fixture shutdown, including failure paths.
                        if signalled.withLock({ value in if value { return false }; value = true; return true }) { started.succeed(()) }
                        return gate.futureResult.hop(to: child.eventLoop)
                    }, connectTimeout: .seconds(3)) { fixture, client in
                    defer { cleanUp() }
                    let cancelled = try await client.startRawRequest(headers: lifecycleHeaders(origin, "/cancelled"))
                    do { try await started.futureResult.boundedGet() }
                    catch {
                        let owner = try #require(fixture.connections.withLock { $0.first })
                        let snapshot = try await fixture.channel.eventLoop.submit { owner.value.upstreamPool.snapshot }.boundedGet()
                        print("Child-start barrier failed (expires=\(expires)): \(snapshot); flow states: \(fixture.store.allFlows().map(\.state))")
                        throw error
                    }
                    try await cancelled.end()
                    if expires { #expect(try await cancelled.response.boundedGet().status == 502) }
                    else {
                        try? await cancelled.channel.close().boundedGet()
                        do { _ = try await cancelled.response.boundedGet(); Issue.record("Cancelled response succeeded") } catch { #expect(!(error is HTTP2FixtureDeadlineExceeded)) }
                    }
                    _ = try await waitForFlow(fixture.store) { $0.path == "/cancelled" && $0.completedAt != nil }
                    let owner = try #require(fixture.connections.withLock { $0.first })
                    let snapshot = try await fixture.channel.eventLoop.submit { owner.value.upstreamPool.snapshot }.boundedGet()
                    #expect(snapshot.pending == 0)
                    #expect(snapshot.opening == 1)
                    #expect(snapshot.acquisitionTimers == 0)
                    #expect(snapshot.physicalSockets == 1)
                    #expect(snapshot.sessions.first?.reservedStreams == 1)
                    let next = try await client.startRawRequest(headers: lifecycleHeaders(origin, "/next"))
                    try await next.end()
                    _ = try await waitForFlow(fixture.store) { $0.path == "/next" }
                    releaseGate()
                    #expect(try await next.response.boundedGet().status == 200)
                    let final = try await fixture.channel.eventLoop.submit { owner.value.upstreamPool.snapshot }.boundedGet()
                    #expect(final.pending == 0)
                    #expect(final.opening == 0)
                    #expect(final.acquisitionTimers == 0)
                    #expect(final.sessions.first?.reservedStreams == 0)
                    #expect(origin.counts.paths == ["/next"])
                    #expect(origin.counts.connections == 1)
                }
            }
        }
    }

    @Test(arguments: [false, true])
    func delayedInitializerFailureOrParentCloseReleasesReservationOnce(closeParent: Bool) throws {
        var limits = HTTPTransportLimits()
        limits.upstreamStreams = 2
        let fixture = try HTTP2LifecycleFixture(limits: limits)
        defer { fixture.stop() }
        let sink = PoolSink()
        let pending = fixture.session.openStream(responseSink: sink)
        fixture.loop.run()
        var settlements = 0
        pending.assumeIsolated().whenComplete { _ in settlements += 1 }
        #expect(fixture.session.snapshot.reservedStreams == 1)
        #expect(fixture.session.snapshot.creatingStreams == 1)
        if closeParent {
            fixture.session.close(error: HTTPTransportError.closed)
            #expect(fixture.session.snapshot.reservedStreams == 1)
            #expect(fixture.session.snapshot.drainTimers == 0)
        }
        fixture.complete(0, fail: !closeParent)
        #expect(settlements == 1)
        #expect(fixture.session.snapshot.reservedStreams == 0)
        #expect(fixture.session.snapshot.creatingStreams == 0)
        #expect(fixture.session.snapshot.activeStreams == 0)
        #expect(sink.closes <= 1)
        if !closeParent { #expect(fixture.session.availableStreams == 2) }
    }

    @Test func localCreationCapRetainsAlreadyReservedUnnumberedChild() throws {
        var limits = HTTPTransportLimits()
        limits.upstreamStreamCreationsPerSession = 1
        let fixture = try HTTP2LifecycleFixture(limits: limits)
        defer { fixture.stop() }
        let sink = PoolSink()
        let pending = fixture.session.openStream(responseSink: sink)
        fixture.loop.run()
        var lease: UpstreamLease?
        pending.assumeIsolated().whenSuccess { lease = $0 }
        #expect(fixture.session.isDraining)
        #expect(fixture.session.snapshot.reservedStreams == 1)
        #expect(fixture.session.snapshot.drainTimers == 1)
        fixture.complete(0)
        let accepted = try #require(lease)
        #expect((accepted as? HTTP2UpstreamLease)?.streamID == nil)
        #expect(sink.closes == 0)
        #expect(fixture.session.snapshot.activeStreams == 1)
        accepted.release(reusable: true)
        #expect(fixture.session.snapshot.reservedStreams == 0)
        #expect(fixture.session.snapshot.drainTimers == 0)
        #expect(!fixture.parent.isActive)
    }

    @Test func peerLimitDownshiftZeroAndRaiseKeepsActiveChildrenAndFIFO() async throws {
        try await withHTTP2ControlLoop { loop in
            let seen = loop.makePromise(of: Void.self)
            let ended = loop.makePromise(of: Void.self)
            let gate = loop.makePromise(of: Void.self)
            var response = HTTP2TestOrigin.Response()
            response.requestsObserved = seen
            response.endsObserved = ended; response.endsTarget = 2
            response.barriersByPath = ["/first": gate.futureResult, "/second": gate.futureResult]
            try await HTTP2TestOrigin.withOrigin(protocols: ["h2"], response: response) { origin in
                var limits = HTTPTransportLimits(); limits.totalUpstreamSockets = 1
                try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true, limits: limits) { fixture, client in
                    var released = false
                    defer { if !released { gate.succeed(()) } }
                    let first = try await client.startRawRequest(headers: lifecycleHeaders(origin, "/first"))
                    try await first.end(); try await seen.futureResult.boundedGet()
                    let parent = try #require(origin.counts.parents.first)
                    let upstream = try #require(fixture.upstreams.withLock { $0.first })
                    try await lifecycleSetting(parent: parent, upstream: upstream, maximum: 1)
                    let second = try await client.startRawRequest(headers: lifecycleHeaders(origin, "/second"))
                    try await second.end()
                    _ = try await waitForFlow(fixture.store) { $0.path == "/second" }
                    #expect(try await lifecycleSnapshot(fixture).waiting == 1)
                    #expect(origin.counts.paths == ["/first"])
                    try await lifecycleSetting(parent: parent, upstream: upstream, maximum: 2)
                    try await ended.futureResult.boundedGet()
                    try await lifecycleSetting(parent: parent, upstream: upstream, maximum: 0)
                    let third = try await client.startRawRequest(headers: lifecycleHeaders(origin, "/third"))
                    try await third.end()
                    _ = try await waitForFlow(fixture.store) { $0.path == "/third" }
                    let zero = try await lifecycleSnapshot(fixture)
                    #expect(zero.waiting == 1)
                    #expect(zero.sessions.first?.activeStreams == 2)
                    #expect(zero.acquisitionTimers == 1)
                    #expect(origin.counts.paths == ["/first", "/second"])
                    try await lifecycleSetting(parent: parent, upstream: upstream, maximum: 3)
                    #expect(try await third.response.boundedGet().status == 200)
                    gate.succeed(()); released = true
                    #expect(try await first.response.boundedGet().status == 200)
                    #expect(try await second.response.boundedGet().status == 200)
                    let final = try await lifecycleSnapshot(fixture)
                    #expect(final.pending == 0)
                    #expect(final.acquisitionTimers == 0)
                    #expect(final.sessions.first?.reservedStreams == 0)
                    #expect(origin.counts.connections == 1)
                    #expect(origin.counts.streamIDs == [1, 3, 5])
                }
            }
        }
    }

    @Test func repeatedLowerGoAwayRejectsOnlyNewerIDAndDrainsUnderSocketCap() async throws {
        try await withHTTP2ControlLoop { loop in
            let seen = loop.makePromise(of: Void.self)
            let gate = loop.makePromise(of: Void.self)
            var response = HTTP2TestOrigin.Response()
            response.requestsObserved = seen; response.requestCountTarget = 2
            response.barriersByPath = ["/low": gate.futureResult, "/high": gate.futureResult]
            try await HTTP2TestOrigin.withOrigin(protocols: ["h2"], response: response) { origin in
                var limits = HTTPTransportLimits(); limits.totalUpstreamSockets = 2
                try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true, limits: limits) { fixture, client in
                    var released = false
                    defer { if !released { gate.succeed(()) } }
                    let low = try await client.startRawRequest(headers: lifecycleHeaders(origin, "/low"))
                    try await low.end()
                    let high = try await client.startRawRequest(headers: lifecycleHeaders(origin, "/high"))
                    try await high.end(); try await seen.futureResult.boundedGet()
                    #expect(origin.counts.streamIDs == [1, 3])
                    let parent = try #require(origin.counts.parents.first)
                    let upstream = try #require(fixture.upstreams.withLock { $0.first })
                    for last in [3, 1] {
                        let observed = try await HTTP2FixtureControlBarrier.install(on: upstream)
                        try await parent.writeAndFlush(HTTP2Frame(streamID: .rootStream,
                            payload: .goAway(lastStreamID: HTTP2StreamID(last), errorCode: .noError, opaqueData: nil))).boundedGet()
                        try await observed.boundedGet()
                    }
                    #expect(try await high.response.boundedGet().status == 502)
                    let draining = try await lifecycleSnapshot(fixture)
                    #expect(draining.sessions.first?.activeStreams == 1)
                    #expect(draining.sessions.first?.drainTimers == 1)
                    #expect(try await client.rawRequest(headers: lifecycleHeaders(origin, "/new")).status == 200)
                    #expect(origin.counts.connections == 2)
                    #expect(fixture.upstreams.withLock { $0.filter(\.isActive).count } == 2)
                    gate.succeed(()); released = true
                    #expect(try await low.response.boundedGet().status == 200)
                    try await upstream.closeFuture.boundedGet()
                    #expect(origin.counts.paths == ["/low", "/high", "/new"])
                    #expect(origin.counts.streamIDs == [1, 3, 1])
                    #expect(fixture.store.allFlows().filter { $0.path == "/high" }.count == 1)
                    #expect(try await lifecycleSnapshot(fixture).acquisitionTimers == 0)
                }
            }
        }
    }

    // Removing session retirement must send /third on stream 5 of the old socket, failing
    // these independently chosen actual-origin IDs and physical-parent observations.
    @Test(arguments: [1, 2])
    func lifetimeCreationBudgetRotatesRealParentsAndRetainsAcceptedChild(totalSockets: Int) async throws {
        try await withHTTP2ControlLoop { loop in
            let seen = loop.makePromise(of: Void.self)
            let gate = loop.makePromise(of: Void.self)
            var response = HTTP2TestOrigin.Response()
            response.requestsObserved = seen
            response.barriersByPath = ["/held": gate.futureResult]
            try await HTTP2TestOrigin.withOrigin(protocols: ["h2"], response: response) { origin in
                var limits = HTTPTransportLimits()
                limits.upstreamStreamCreationsPerSession = 2
                limits.totalUpstreamSockets = totalSockets
                try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true, limits: limits) { fixture, client in
                    var released = false
                    defer { if !released { gate.succeed(()) } }
                    let held = Task { try await client.rawRequest(headers: lifecycleHeaders(origin, "/held")) }
                    try await seen.futureResult.boundedGet()
                    #expect(try await client.rawRequest(headers: lifecycleHeaders(origin, "/second")).status == 200)
                    #expect(origin.counts.streamIDs == [1, 3])
                    let original = try #require(fixture.upstreams.withLock { $0.first })
                    #expect(original.isActive)
                    let third = try await client.startRawRequest(headers: lifecycleHeaders(origin, "/third"))
                    try await third.end()
                    _ = try await waitForFlow(fixture.store) { $0.path == "/third" }
                    if totalSockets == 1 {
                        let blocked = try await lifecycleSnapshot(fixture)
                        #expect(blocked.waiting == 1)
                        #expect(blocked.physicalSockets == 1)
                        #expect(origin.counts.connections == 1)
                        gate.succeed(()); released = true
                    }
                    #expect(try await third.response.boundedGet().status == 200)
                    #expect(origin.counts.streamIDs == [1, 3, 1])
                    #expect(origin.counts.connections == 2)
                    #expect(fixture.upstreams.withLock { $0.filter(\.isActive).count } <= totalSockets)
                    if totalSockets == 2 {
                        #expect(origin.counts.responseOrder == ["/second", "/third"])
                        gate.succeed(()); released = true
                    }
                    #expect(try await held.value.status == 200)
                    try await original.closeFuture.boundedGet()
                    try await waitForCompletedFlows(fixture.store, atLeast: 3)
                    #expect(fixture.store.allFlows().allSatisfy { $0.state == .completed })
                }
            }
        }
    }
}

private func lifecycleHeaders(_ origin: HTTP2TestOrigin, _ path: String) -> HPACKHeaders {
    HPACKHeaders([ (":method", "GET"), (":scheme", "https"), (":authority", "localhost:\(origin.port)"), (":path", path) ])
}

private func lifecycleSnapshot(_ fixture: HTTP2ProxyFixture) async throws -> UpstreamPoolSnapshot {
    let owner = try #require(fixture.connections.withLock { $0.first })
    return try await fixture.channel.eventLoop.submit { owner.value.upstreamPool.snapshot }.boundedGet()
}

private func lifecycleSetting(parent: Channel, upstream: Channel, maximum: Int) async throws {
    let observed = try await HTTP2FixtureControlBarrier.install(on: upstream, maximum: maximum)
    try await parent.writeAndFlush(HTTP2Frame(streamID: .rootStream,
        payload: .settings(.settings([.init(parameter: .maxConcurrentStreams, value: maximum)])))).boundedGet()
    try await observed.boundedGet()
}
