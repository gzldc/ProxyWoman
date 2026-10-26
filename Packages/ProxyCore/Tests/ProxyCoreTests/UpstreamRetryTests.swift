import CertKit
import Atomics
import FlowStore
import Foundation
import Darwin
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOPosix
import NIOSSL
import Testing
import os
@testable import ProxyCore
import RulesEngine

// Keep this fixture-heavy suite bounded while the existing integration suites run concurrently.
@Suite(.serialized, .productionChinese) struct UpstreamRetryTests {
    // Removing the stale-reuse transition must turn the second response into 502.
    @Test func staleReusedGETRetriesOnFreshConnectionAndRecordsOneFlow() async throws {
        try await RetryFixture.run { fx in
            let client = try await RawClient.connect(port: fx.proxyPort)
            try await fx.prime(client)
            try await client.send(fx.request())
            let response = try await client.receive(until: "\r\n\r\n")
            #expect(response.contains("200 OK"), "\(response)")
            if response.contains("200 OK") {
                #expect(try await client.receive(until: "retried") == "retried")
            }
            try await client.close()
            #expect(fx.origin.state.withLock { $0.targetRequests } == 2)
            #expect(fx.origin.state.withLock { $0.connections } == 2)
            let flows = fx.store.allFlows().filter { $0.path == "/target" }
            #expect(flows.count == 1)
            #expect(flows.first?.statusCode == 200)
            #expect(flows.first?.state == .completed)
        }
    }
    @Test(arguments: ["HEAD", "DELETE", "OPTIONS", "TRACE"])
    func otherEligibleMethodsRetryStaleConnection(method: String) async throws {
        try await RetryFixture.run { fx in
            let client = try await RawClient.connect(port: fx.proxyPort)
            try await fx.prime(client)
            try await client.send(fx.request(method: method, extra: "Connection: close\r\n"))
            let response = try await client.receive(until: "\r\n\r\n")
            #expect(response.contains("200 OK"))
            if method != "HEAD", response.contains("200 OK") { _ = try await client.receive(until: "retried") }
            try await client.waitUntilClosed()
            try await client.close()
            #expect(fx.origin.state.withLock { $0.connections } == 2)
            #expect(fx.origin.state.withLock { $0.targetRequests } == 2)
        }
    }

    @Test func queuedRequestAfterRetryUsesCurrentExchangeAndFreshConnection() async throws {
        try await RetryFixture.run { fx in
            let client = try await RawClient.connect(port: fx.proxyPort)
            try await fx.prime(client)
            let next = "GET http://127.0.0.1:\(fx.origin.port)/after HTTP/1.1\r\nHost: 127.0.0.1:\(fx.origin.port)\r\nConnection: close\r\n\r\n"
            try await client.send(fx.request() + next)
            #expect(try await client.receive(until: "\r\n\r\n").contains("200 OK"))
            _ = try await client.receive(until: "retried")
            #expect(try await client.receive(until: "\r\n\r\n").contains("200 OK"))
            _ = try await client.receive(until: "after!!")
            try await client.waitUntilClosed()
            try await client.close()
            #expect(fx.origin.state.withLock { $0.connections } == 2)
            #expect(fx.origin.state.withLock { $0.targetRequests } == 2)
            #expect(fx.store.allFlows().filter { $0.state == .completed }.count == 3)
        }
    }

    @Test func completePUTReplaysBodyAndTrailersWithoutDoubleRecording() async throws {
        try await RetryFixture.run { fx in
            let client = try await RawClient.connect(port: fx.proxyPort)
            try await fx.prime(client)
            try await client.send(fx.request(method: "PUT", extra: "Transfer-Encoding: chunked\r\n", body: "3\r\nabc\r\n4\r\nXYZ!\r\n0\r\nX-Proof: exact\r\n\r\n"))
            let response = try await client.receive(until: "\r\n\r\n")
            #expect(response.contains("200 OK"))
            if response.contains("200 OK") { _ = try await client.receive(until: "retried") }
            try await client.close()
            let requests = fx.origin.state.withLock { $0.received }
            #expect(requests.count == 2)
            #expect(requests.allSatisfy { $0.body == Array("abcXYZ!".utf8) && $0.trailer == "exact" })
            let flow = try #require(fx.store.allFlows().first { $0.path == "/target" })
            #expect(flow.bytesSent == 7)
            #expect(try flow.requestBody?.load() == Data("abcXYZ!".utf8))
        }
    }

    @Test func failedRetryProducesOne502AndNoThirdAttempt() async throws {
        try await RetryFixture.run(behavior: .closeEveryTarget) { fx in
            let client = try await RawClient.connect(port: fx.proxyPort)
            try await fx.prime(client)
            try await client.send(fx.request(extra: "Connection: close\r\n"))
            let response = try await client.receive(until: "\r\n\r\n")
            #expect(response.contains("502 Bad Gateway"))
            try await client.waitUntilClosed()
            try await client.close()
            #expect(fx.origin.state.withLock { $0.connections } == 2)
            #expect(fx.origin.state.withLock { $0.targetRequests } == 2)
            #expect(fx.store.allFlows().filter { $0.path == "/target" }.count == 1)
        }
    }

    @Test(arguments: ["POST", "PATCH"])
    func unsafeMethodsDoNotRetry(method: String) async throws {
        try await RetryFixture.run { fx in
            let client = try await RawClient.connect(port: fx.proxyPort)
            try await fx.prime(client)
            try await client.send(fx.request(method: method, extra: "Content-Length: 3\r\nConnection: close\r\n", body: "abc"))
            #expect(try await client.receive(until: "\r\n\r\n").contains("502"))
            try await client.waitUntilClosed()
            try await client.close()
            #expect(fx.origin.state.withLock { $0.connections } == 1)
        }
    }

    @Test(arguments: [100, 103])
    func informationalHeadThenEOFIsForwardedWithoutRetryOr502(status: Int) async throws {
        try await RetryFixture.run(behavior: .informationalThenClose(status)) { fx in
            let prime = "GET http://127.0.0.1:\(fx.origin.port)/prime HTTP/1.1\r\nHost: 127.0.0.1:\(fx.origin.port)\r\n\r\n"
            let bytes = try await collectResponseThroughEOF(port: fx.proxyPort, request: prime + fx.request())
            let response = try #require(String(bytes: bytes, encoding: .utf8))
            #expect(response.contains("primed"))
            #expect(response.contains("HTTP/1.1 \(status)"), "\(response)")
            #expect(!response.contains("502"), "unexpected local final response after interim: \(response)")
            #expect(fx.origin.state.withLock { $0.connections } == 1)
            let flow = try #require(fx.store.allFlows().first { $0.path == "/target" })
            #expect(flow.statusCode == nil)
            if case .failed = flow.state {} else { Issue.record("interim EOF must fail flow") }
        }
    }

    @Test(arguments: [100, 103])
    func informationalHeadThenFinalRecordsOnlyFinalResponse(status: Int) async throws {
        try await RetryFixture.run(behavior: .informationalThenFinal(status)) { fx in
            let client = try await RawClient.connect(port: fx.proxyPort)
            try await fx.prime(client)
            try await client.send(fx.request())
            #expect(try await client.receive(until: "\r\n\r\n").contains("HTTP/1.1 \(status)"))
            #expect(try await client.receive(until: "\r\n\r\n").contains("200 OK"))
            _ = try await client.receive(until: "retried")
            try await client.close()
            let flow = try #require(fx.store.allFlows().first { $0.path == "/target" })
            #expect(flow.statusCode == 200)
            #expect(flow.state == .completed)
            #expect(fx.origin.state.withLock { $0.connections } == 1)
        }
    }

    @Test(arguments: ["upgrade", "oversize"])
    func unreplayableCompleteRequestsDoNotRetry(kind: String) async throws {
        try await RetryFixture.run(behavior: kind == "upgrade" ? .closeEveryTarget : .closeFirstTarget) { fx in
            let client = try await RawClient.connect(port: fx.proxyPort)
            try await fx.prime(client)
            let request: String
            if kind == "upgrade" {
                request = fx.request(extra: "Connection: Upgrade\r\nUpgrade: websocket\r\n")
            } else {
                let body = String(repeating: "x", count: 1_048_576)
                request = fx.request(method: "PUT", extra: "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n", body: body)
            }
            try await client.send(request)
            #expect(try await client.receive(until: "\r\n\r\n").contains("502"))
            try await client.waitUntilClosed()
            try await client.close()
            #expect(fx.origin.state.withLock { $0.connections } == (kind == "upgrade" ? 2 : 1))
            #expect(fx.origin.state.withLock { $0.targetRequests } == 1)
        }
    }

    @Test func unfinishedPUTDoesNotRetryAfterOriginClosesOnHead() async throws {
        try await RetryFixture.run(behavior: .closeOnHead) { fx in
            let client = try await RawClient.connect(port: fx.proxyPort)
            try await fx.prime(client)
            try await client.send(fx.request(method: "PUT", extra: "Content-Length: 10\r\n", body: "abc"))
            #expect(try await client.receive(until: "\r\n\r\n").contains("502"))
            try await client.close()
            #expect(fx.origin.state.withLock { $0.connections } == 1)
        }
    }

    @Test(arguments: [false, true])
    func malformedOrStartedFinalResponseDoesNotRetry(finalHead: Bool) async throws {
        try await RetryFixture.run(behavior: finalHead ? .finalThenClose : .malformedResponse) { fx in
            let client = try await RawClient.connect(port: fx.proxyPort)
            try await fx.prime(client)
            try await client.send(fx.request(extra: "Connection: close\r\n"))
            let response = try await client.receive(until: "\r\n\r\n")
            #expect(response.contains(finalHead ? "200 OK" : "502"))
            try await client.waitUntilClosed()
            try await client.close()
            #expect(fx.origin.state.withLock { $0.connections } == 1)
            let flow = try #require(fx.store.allFlows().first { $0.path == "/target" })
            if case .failed = flow.state {} else { Issue.record("failed upstream must fail the flow") }
        }
    }

    @Test func clientCancellationBeforeStaleEOFDoesNotCreateAnotherConnection() async throws {
        try await RetryFixture.run(behavior: .holdTarget) { fx in
            let client = try await RawClient.connect(port: fx.proxyPort)
            try await fx.prime(client)
            try await client.send(fx.request())
            try await waitUntil("origin received target") { fx.origin.state.withLock { $0.targetRequests } == 1 }
            try await client.close()
            _ = try await waitForFlow(fx.store) {
                guard $0.path == "/target" else { return false }
                if case .failed = $0.state { return true }; return false
            }
            // Drain the origin close after the proxy has processed client cancellation, then
            // a new request proves the server still accepts work without resurrecting that flow.
            try await fx.origin.closeConnections()
            let next = try await RawClient.connect(port: fx.proxyPort)
            try await next.send(fx.request(extra: "Connection: close\r\n"))
            try await waitUntil("second client target") { fx.origin.state.withLock { $0.targetRequests } == 2 }
            try await next.close()
            #expect(fx.origin.state.withLock { $0.connections } == 2)
        }
    }

    @Test func writeFailureAndCloseRaceClaimsOnlyOneFreshRetry() throws {
        let loop = EmbeddedEventLoop()
        let writes = ControlledUpstreamWrites()
        let first = try activeUpstream(loop: loop, writes: writes)
        let fresh = try activeUpstream(loop: loop)
        defer { writes.succeedAll(); _ = try? first.finish(); _ = try? fresh.finish() }
        var attempts = 0
        try withEmbeddedOwner(loop: loop, connectionFactory: { _, _, eventLoop in
            #expect(eventLoop === loop)
            attempts += 1
            return loop.makeSucceededFuture(attempts == 1 ? first : fresh)
        }) { _, client, store in
            try client.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 12345)).wait()
            try sendEmbeddedRequest(client, path: "/prime")
            try respondOK(first)
            _ = try drainResponseStatuses(client)
            let old = try #require(first.pipeline.syncOperations.handler(type: UpstreamResponseHandler.self).sink)
            writes.hold = true
            try sendEmbeddedRequest(client, path: "/target")
            try #require(!writes.pending.isEmpty)
            writes.pending.removeFirst().fail(IOError(errnoCode: EPIPE, reason: "stale write"))
            loop.run()
            // Deliberately deliver all losing callbacks after the fresh attempt is attached.
            old.upstreamClosed(error: nil)
            old.receiveResponse(.head(HTTPResponseHead(version: .http1_1, status: HTTPResponseStatus(statusCode: 103))))
            old.receiveResponse(.end(nil))
            old.upstreamWritabilityChanged(false)
            for promise in writes.takePending() { promise.fail(ChannelError.ioOnClosedChannel) }
            loop.run()
            #expect(attempts == 2)
            #expect(fresh.isActive)
            try respondOK(fresh)
            #expect(try drainResponseStatuses(client) == [200])
            #expect(store.allFlows().filter { $0.path == "/target" }.count == 1)
            #expect(store.allFlows().first { $0.path == "/target" }?.state == .completed)
        }
    }

    @Test func delayedWriteFailureFromPriorExchangeDoesNotSettleNextPipelinedExchange() throws {
        let loop = EmbeddedEventLoop()
        let writes = ControlledUpstreamWrites()
        writes.hold = true
        let upstream = try activeUpstream(loop: loop, writes: writes)
        defer { writes.succeedAll(); _ = try? upstream.finish() }
        var attempts = 0
        try withEmbeddedOwner(loop: loop, connectionFactory: { _, _, _ in
            attempts += 1
            return loop.makeSucceededFuture(upstream)
        }) { _, client, store in
            try client.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 12345)).wait()
            try sendEmbeddedRequest(client, path: "/first")
            let previousWrites = writes.takePending()
            try #require(!previousWrites.isEmpty)
            try sendEmbeddedRequest(client, path: "/second") // queued until first response ends
            try respondOK(upstream)
            #expect(try drainResponseStatuses(client) == [200])
            #expect(store.allFlows().first { $0.path == "/second" }?.state == .inProgress)
            for promise in previousWrites { promise.fail(IOError(errnoCode: EPIPE, reason: "delayed prior write")) }
            loop.run()
            #expect(attempts == 1)
            #expect(upstream.isActive)
            #expect(try drainResponseStatuses(client).isEmpty)
            try respondOK(upstream)
            #expect(try drainResponseStatuses(client) == [200])
            #expect(store.allFlows().allSatisfy { $0.state == .completed })
        }
    }

    @Test func clientCloseDuringPendingRetryClosesLateConnectedChannelWithoutNewFlow() throws {
        let loop = EmbeddedEventLoop()
        let first = try activeUpstream(loop: loop)
        let late = try activeUpstream(loop: loop)
        let pending = loop.makePromise(of: Channel.self)
        defer { _ = try? first.finish(); _ = try? late.finish() }
        var attempts = 0
        try withEmbeddedOwner(loop: loop, connectionFactory: { _, _, _ in
            attempts += 1
            return attempts == 1 ? loop.makeSucceededFuture(first) : pending.futureResult
        }) { _, client, store in
            try client.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 12345)).wait()
            try sendEmbeddedRequest(client, path: "/prime")
            try respondOK(first)
            _ = try drainResponseStatuses(client)
            let old = try #require(first.pipeline.syncOperations.handler(type: UpstreamResponseHandler.self).sink)
            try sendEmbeddedRequest(client, path: "/target")
            try first.close().wait()
            #expect(attempts == 2)
            try client.close().wait()
            pending.succeed(late)
            loop.run()
            old.upstreamClosed(error: nil)
            old.receiveResponse(.head(HTTPResponseHead(version: .http1_1, status: .ok)))
            loop.run()
            #expect(!late.isActive)
            #expect(attempts == 2)
            #expect(store.allFlows().count == 2)
            #expect(store.allFlows().allSatisfy { $0.state != .inProgress })
            #expect(try drainResponseStatuses(client).isEmpty)
        }
    }

    @Test func upstreamWriteFailuresAreReturnedForExchangeAndAttemptGuarding() throws {
        try withEmbeddedOwner { _, _, _ in
            let upstream = UpstreamResponseHandler()
            let channel = EmbeddedChannel(handlers: [RejectUpstreamWrites(), upstream])
            defer { _ = try? channel.finish() }
            for future in [upstream.write(.end(nil)), upstream.writeAndFlush(.end(nil))] {
                let write = try #require(future)
                do {
                    try write.wait()
                    Issue.record("write error was swallowed")
                } catch {
                    #expect((error as? IOError)?.errnoCode == EPIPE)
                }
            }
        }
    }

    @Test func lateHandlerCallbacksAfterClientCloseCannotEmitResponseOrOpenExchange() throws {
        let loop = EmbeddedEventLoop()
        let upstream = try activeUpstream(loop: loop)
        defer { _ = try? upstream.finish() }
        try withEmbeddedOwner(loop: loop, connectionFactory: { _, _, _ in loop.makeSucceededFuture(upstream) }) { _, client, _ in
            try client.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 12345)).wait()
            try sendEmbeddedRequest(client, path: "/closed")
            let old = try #require(upstream.pipeline.syncOperations.handler(type: UpstreamResponseHandler.self).sink)
            try client.close().wait()
            old.upstreamClosed(error: IOError(errnoCode: ECONNRESET, reason: "late reset"))
            old.receiveResponse(.head(HTTPResponseHead(version: .http1_1, status: .ok)))
            old.receiveResponse(.end(nil))
            old.upstreamWritabilityChanged(false)
            #expect(!client.isActive)
            #expect(try client.readOutbound(as: HTTPServerResponsePart.self) == nil)
        }
    }

    @Test func fileRegionAndDuplicateEndDiscardReplay() throws {
        let descriptor = dup(STDIN_FILENO)
        try #require(descriptor >= 0)
        let handle = NIOFileHandle(_deprecatedTakingOwnershipOfDescriptor: descriptor)
        defer { try? handle.close() }
        let head = HTTPRequestHead(version: .http1_1, method: .PUT, uri: "/")
        var file = RequestReplayBuffer(head: head)
        file.append(.body(.fileRegion(FileRegion(fileHandle: handle, readerIndex: 0, endIndex: 1))))
        file.append(.end(nil))
        #expect(file.replayParts == nil)
        var duplicateEnd = RequestReplayBuffer(head: head)
        duplicateEnd.append(.end(nil))
        duplicateEnd.append(.end(nil))
        #expect(duplicateEnd.replayParts == nil)
    }

    @Test func transportFailureWhitelistRejectsTimeoutTLSProtocolAndUnknown() {
        #expect(ProxyHandler.isRetryableTransportFailure(nil))
        for error: Error in [ChannelError.eof, ChannelError.ioOnClosedChannel, ChannelError.outputClosed,
                             IOError(errnoCode: ECONNRESET, reason: "reset"), IOError(errnoCode: EPIPE, reason: "pipe")] {
            #expect(ProxyHandler.isRetryableTransportFailure(error))
        }
        for error: Error in [TLSHandshakeTimeout(), NIOSSLError.uncleanShutdown, HTTPParserError.invalidStatus,
                             IOError(errnoCode: ETIMEDOUT, reason: "timeout"), NSError(domain: "unknown", code: 1)] {
            #expect(!ProxyHandler.isRetryableTransportFailure(error))
        }
    }

    @Test(arguments: [HTTPMethod.GET, .HEAD, .PUT, .DELETE, .OPTIONS, .TRACE])
    func eligibleCompleteMethodsCanReplay(method: HTTPMethod) throws {
        var replay = RequestReplayBuffer(head: HTTPRequestHead(version: .http1_1, method: method, uri: "/"))
        #expect(replay.replayParts == nil)
        replay.append(.end(nil))
        let parts = try #require(replay.replayParts)
        #expect(parts.count == 2)
    }

    @Test func replayCoalescesOwnedBinaryBodyAndPreservesTrailers() throws {
        var replay = RequestReplayBuffer(head: HTTPRequestHead(version: .http1_1, method: .PUT, uri: "/binary"))
        var allocation = ByteBuffer(repeating: 255, count: 2 << 20)
        allocation.setBytes([0, 128, 254], at: 123)
        replay.append(.body(.byteBuffer(try #require(allocation.getSlice(at: 123, length: 3)))))
        for _ in 0..<10000 { replay.append(.body(.byteBuffer(ByteBuffer(bytes: [7])))) }
        replay.append(.end(HTTPHeaders([("X-Proof", "exact")])))
        let parts = try #require(replay.replayParts)
        #expect(parts.count == 3)
        guard case .body(.byteBuffer(let body)) = parts[1], case .end(let trailers) = parts[2] else {
            Issue.record("missing coalesced body/trailers"); return
        }
        #expect(Array(body.readableBytesView.prefix(4)) == [0, 128, 254, 7])
        #expect(body.readableBytes == 10003)
        #expect(body.capacity < 1 << 20)
        #expect(trailers?.first(name: "X-Proof") == "exact")
    }

    @Test func replayLimitCountsUTF8HeadFieldOverheadBodyAndTrailers() {
        // PUT (3) + /é (3) + X (1) + é (2) + field overhead (32) = 41.
        let head = HTTPRequestHead(version: .http1_1, method: .PUT, uri: "/é", headers: HTTPHeaders([("X", "é")]))
        var exact = RequestReplayBuffer(head: head, limit: 77)
        exact.append(.body(.byteBuffer(ByteBuffer(bytes: [0])))) // 42
        exact.append(.end(HTTPHeaders([("T", "é")]))) // 77
        #expect(exact.replayParts != nil)
        var small = RequestReplayBuffer(head: head, limit: 76)
        small.append(.body(.byteBuffer(ByteBuffer(bytes: [0]))))
        small.append(.end(HTTPHeaders([("T", "é")])))
        #expect(small.replayParts == nil)
        var oversizedHead = RequestReplayBuffer(head: head, limit: 40)
        oversizedHead.append(.end(nil))
        #expect(oversizedHead.replayParts == nil)
        var bodyOverflow = RequestReplayBuffer(head: head, limit: 41)
        bodyOverflow.append(.body(.byteBuffer(ByteBuffer(bytes: [0]))))
        bodyOverflow.append(.end(nil))
        #expect(bodyOverflow.replayParts == nil)
    }

    @Test func unsafeUpgradeIncompleteAndMalformedSequencesCannotReplay() {
        for method in [HTTPMethod.POST, .PATCH, .CONNECT] {
            var replay = RequestReplayBuffer(head: HTTPRequestHead(version: .http1_1, method: method, uri: "/"))
            replay.append(.body(.byteBuffer(ByteBuffer(repeating: 1, count: 1 << 20))))
            replay.append(.end(nil))
            #expect(replay.replayParts == nil)
        }
        for headers in [HTTPHeaders([("Upgrade", "websocket")]), HTTPHeaders([("Connection", "keep-alive, Upgrade")])] {
            var replay = RequestReplayBuffer(head: HTTPRequestHead(version: .http1_1, method: .GET, uri: "/", headers: headers))
            replay.append(.end(nil))
            #expect(replay.replayParts == nil)
        }
        let head = HTTPRequestHead(version: .http1_1, method: .PUT, uri: "/")
        var unfinished = RequestReplayBuffer(head: head)
        unfinished.append(.body(.byteBuffer(ByteBuffer(string: "abc"))))
        #expect(unfinished.replayParts == nil)
        var duplicateHead = RequestReplayBuffer(head: head)
        duplicateHead.append(.head(head))
        duplicateHead.append(.end(nil))
        #expect(duplicateHead.replayParts == nil)
        var afterEnd = RequestReplayBuffer(head: head)
        afterEnd.append(.end(nil))
        afterEnd.append(.body(.byteBuffer(ByteBuffer(string: "abc"))))
        #expect(afterEnd.replayParts == nil)
    }

}

private struct RetryFixture {
    let origin: RetryOrigin
    let store: FlowStore
    let proxyPort: Int

    func request(method: String = "GET", extra: String = "", body: String = "") -> String {
        "\(method) http://127.0.0.1:\(origin.port)/target HTTP/1.1\r\nHost: 127.0.0.1:\(origin.port)\r\n\(extra)\r\n\(body)"
    }

    func prime(_ client: RawClient) async throws {
        try await client.send("GET http://127.0.0.1:\(origin.port)/prime HTTP/1.1\r\nHost: 127.0.0.1:\(origin.port)\r\n\r\n")
        _ = try await client.receive(until: "primed")
    }

    static func run(behavior: RetryOrigin.Behavior = .closeFirstTarget, _ body: (RetryFixture) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FlowStore(bodyDirectory: directory)
        var configuration = ProxyConfiguration()
        configuration.port = 0
        let authority = try CertificateAuthority.generate()
        let origin = try await RetryOrigin.start(behavior: behavior)
        // Only this new fixture uses a small listener group. The real production HTTP codec,
        // handler, connector, recorder, TLS environment, and transport are exercised unchanged.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let pool = NIOThreadPool(numberOfThreads: 1)
        pool.start()
        let environment = ProxyEnvironment(
            configuration: configuration,
            recording: FlowRecording(store: store, isEnabled: ManagedAtomic(true)),
            tls: TLSInterception(certificateAuthority: authority), passthrough: PassthroughRegistry(),
            clientLookup: ClientLookupBatcher(processLookup: .live, threadPool: pool))
        let traffic = TrafficMeter()
        var listener: Channel?
        do {
            let channel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 256)
                .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandlers([
                            TrafficCountingHandler(meter: traffic), HTTPResponseEncoder(),
                            ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)),
                            ProxyHandler(mode: .forwardProxy, environment: environment),
                        ])
                    }
                }.bind(host: "127.0.0.1", port: 0).get()
            listener = channel
            try await body(RetryFixture(origin: origin, store: store, proxyPort: try #require(channel.localAddress?.port)))
        } catch {
            try? await listener?.close().get()
            try? await group.shutdownGracefully()
            try? await pool.shutdownGracefully()
            try? await origin.stop()
            throw error
        }
        try await listener?.close().get()
        try await group.shutdownGracefully()
        try await pool.shutdownGracefully()
        try await origin.stop()
    }
}

private final class RetryOrigin: Sendable {
    enum Behavior: Sendable {
        case closeFirstTarget, closeEveryTarget, informationalThenClose(Int), informationalThenFinal(Int)
        case closeOnHead, finalThenClose, malformedResponse, holdTarget
    }
    struct Received: Sendable {
        var body: [UInt8]
        var trailer: String?
    }
    struct State {
        var received: [Received] = []
        var channels: [Channel] = []
        var connections = 0
        var targetRequests = 0
    }
    let state: OSAllocatedUnfairLock<State>
    let port: Int
    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel

    private init(group: MultiThreadedEventLoopGroup, channel: Channel, state: OSAllocatedUnfairLock<State>) {
        self.group = group
        self.channel = channel
        self.state = state
        self.port = channel.localAddress!.port!
    }

    static func start(behavior: Behavior) async throws -> RetryOrigin {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let state = OSAllocatedUnfairLock(initialState: State())
        do {
            let channel = try await ServerBootstrap(group: group).childChannelInitializer { channel in
                let number = state.withLock { $0.connections += 1; $0.channels.append(channel); return $0.connections }
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandlers([
                        ByteToMessageHandler(HTTPRequestDecoder()), RetryOriginHandler(number: number, state: state, behavior: behavior),
                    ])
                }
            }.bind(host: "127.0.0.1", port: 0).get()
            return RetryOrigin(group: group, channel: channel, state: state)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    func closeConnections() async throws {
        let channels = state.withLock { $0.channels }
        for channel in channels { try? await channel.close().get() }
    }

    func stop() async throws {
        try await closeConnections()
        try? await channel.close().get()
        try await group.shutdownGracefully()
    }
}

private final class RetryOriginHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    let number: Int
    let state: OSAllocatedUnfairLock<RetryOrigin.State>
    private var path = ""
    private var method: HTTPMethod = .GET
    private var body: [UInt8] = []
    private let behavior: RetryOrigin.Behavior

    init(number: Int, state: OSAllocatedUnfairLock<RetryOrigin.State>, behavior: RetryOrigin.Behavior) {
        self.behavior = behavior
        self.number = number
        self.state = state
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            path = head.uri; method = head.method; body = []
            if path == "/target", case .closeOnHead = behavior { context.close(promise: nil) }
        case .body(let buffer): body.append(contentsOf: buffer.readableBytesView)
        case .end(let trailers):
            if path == "/prime" {
                context.writeAndFlush(NIOAny(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\nprimed")), promise: nil)
            } else if path == "/after" {
                context.writeAndFlush(NIOAny(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 7\r\n\r\nafter!!")), promise: nil)
            } else {
                let receivedBody = body
                state.withLock {
                    $0.targetRequests += 1
                    $0.received.append(.init(body: receivedBody, trailer: trailers?.first(name: "X-Proof")))
                }
                let final = "HTTP/1.1 200 OK\r\nContent-Length: 7\r\n\r\n" + (method == .HEAD ? "" : "retried")
                switch behavior {
                case .closeFirstTarget where number == 1, .closeEveryTarget:
                    context.close(promise: nil)
                case .informationalThenClose(let status):
                    context.writeAndFlush(NIOAny(ByteBuffer(string: "HTTP/1.1 \(status) Interim\r\n\r\n"))).assumeIsolated().whenComplete { _ in
                        context.close(promise: nil)
                    }
                case .holdTarget:
                    break
                case .finalThenClose:
                    context.writeAndFlush(NIOAny(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n"))).assumeIsolated().whenComplete { _ in
                        context.close(promise: nil)
                    }
                case .malformedResponse:
                    context.writeAndFlush(NIOAny(ByteBuffer(string: "NOT HTTP\r\n\r\n"))).assumeIsolated().whenComplete { _ in
                        context.close(promise: nil)
                    }
                case .informationalThenFinal(let status):
                    context.writeAndFlush(NIOAny(ByteBuffer(string: "HTTP/1.1 \(status) Interim\r\n\r\n" + final)), promise: nil)
                default:
                    context.writeAndFlush(NIOAny(ByteBuffer(string: final)), promise: nil)
                }
            }
        }
    }
}

private func withEmbeddedOwner(
    loop: EmbeddedEventLoop = EmbeddedEventLoop(), connectionFactory: ProxyHandler.ConnectionFactory? = nil,
    _ body: (ProxyHandler, EmbeddedChannel, FlowStore) throws -> Void
) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pool = NIOThreadPool(numberOfThreads: 1)
    pool.start()
    defer { try? pool.syncShutdownGracefully() }
    let store = FlowStore(bodyDirectory: directory)
    let environment = ProxyEnvironment(
        configuration: ProxyConfiguration(),
        recording: FlowRecording(store: store, isEnabled: ManagedAtomic(true)),
        tls: TLSInterception(certificateAuthority: try CertificateAuthority.generate()),
        passthrough: PassthroughRegistry(),
        clientLookup: ClientLookupBatcher(processLookup: ProcessLookup(lookup: { _, _ in nil }), threadPool: pool))
    let owner = ProxyHandler(mode: .forwardProxy, environment: environment, connectionFactory: connectionFactory)
    let channel = EmbeddedChannel(handler: owner, loop: loop)
    defer { _ = try? channel.finish() }
    try body(owner, channel, store)
}

private final class RejectUpstreamWrites: ChannelOutboundHandler {
    typealias OutboundIn = HTTPClientRequestPart
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        promise?.fail(IOError(errnoCode: EPIPE, reason: "controlled broken transport"))
    }
}

private func activeUpstream(loop: EmbeddedEventLoop, writes: ControlledUpstreamWrites = ControlledUpstreamWrites()) throws -> EmbeddedChannel {
    let channel = EmbeddedChannel(handler: writes, loop: loop)
    try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 12346)).wait()
    return channel
}

private func sendEmbeddedRequest(_ client: EmbeddedChannel, path: String) throws {
    let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "http://retry.invalid" + path)
    try client.writeInbound(HTTPServerRequestPart.head(head))
    try client.writeInbound(HTTPServerRequestPart.end(nil))
}

private func respondOK(_ upstream: EmbeddedChannel) throws {
    try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
}

private func drainResponseStatuses(_ client: EmbeddedChannel) throws -> [UInt] {
    var statuses: [UInt] = []
    while let part = try client.readOutbound(as: HTTPServerResponsePart.self) {
        if case .head(let head) = part { statuses.append(head.status.code) }
    }
    return statuses
}

/// Forward actual encoded bytes but control when the originating socket-write promises settle.
private final class ControlledUpstreamWrites: ChannelOutboundHandler {
    typealias OutboundIn = ByteBuffer
    var hold = false
    var pending: [EventLoopPromise<Void>] = []

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        if hold, let promise {
            pending.append(promise)
            context.write(data, promise: nil)
        } else {
            context.write(data, promise: promise)
        }
    }

    func takePending() -> [EventLoopPromise<Void>] {
        defer { pending.removeAll() }
        return pending
    }

    func succeedAll() {
        for promise in takePending() { promise.succeed(()) }
    }
}

/// Reads every byte through real socket EOF, so an erroneous second response cannot hide after
/// the first informational head. The fixture speaks ASCII; callers require valid UTF-8 explicitly.
private func collectResponseThroughEOF(port: Int, request: String) async throws -> [UInt8] {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let bytes = OSAllocatedUnfairLock<[UInt8]>(initialState: [])
    var opened: Channel?
    do {
        let channel = try await ClientBootstrap(group: group).channelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(CapturedRawResponseHandler(bytes: bytes))
            }
        }.connect(host: "127.0.0.1", port: port).get()
        opened = channel
        try await channel.writeAndFlush(ByteBuffer(string: request)).get()
        try await waitUntil("proxy EOF after informational response") { !channel.isActive }
        let result = bytes.withLock { $0 }
        try await group.shutdownGracefully()
        return result
    } catch {
        try? await opened?.close().get()
        try? await group.shutdownGracefully()
        throw error
    }
}

private final class CapturedRawResponseHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    let bytes: OSAllocatedUnfairLock<[UInt8]>
    init(bytes: OSAllocatedUnfairLock<[UInt8]>) { self.bytes = bytes }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        bytes.withLock { $0.append(contentsOf: buffer.readableBytesView) }
    }
}

/// Rules run once per exchange: an implicit HTTP/1 replay resends exactly the effective request
/// (rewritten target, edited headers) on the same effective route, and nothing of the original.
@Suite(.productionChinese) struct RuleReplayTests {
    private static let mapped = TestRules.mapRemote(host: "mapped.test", port: 8080, path: .replace("/mapped?v=1"))
    private static let edits = TestRules.headers(.request, [.set(name: "X-Edited", value: "new"), .remove(name: "X-Secret")])

    /// Leaves one idle connection to the mapped route in the pool.
    private func prime(_ fixture: ConnectionFixture, _ context: ClientConnectionContext) throws -> EmbeddedChannel {
        let exchange = fixture.admit("/prime", writer: RecordingResponseWriter(channel: fixture.client), context: context)
        exchange.receiveRequest(.end(nil))
        exchange.execute()
        let upstream = try fixture.connect(0)
        _ = try fixture.written(upstream)
        try upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
        fixture.loop.run()
        return upstream
    }

    @Test func replayResendsTheEffectiveRequestOnceOnTheMappedRoute() async throws {
        try await withConnectionFixture { fixture in
            fixture.expectedEndpoint = (host: "mapped.test", port: 8080)
            let rules = TestRules.provider([Self.edits, Self.mapped])
            let context = fixture.context(rules: rules)
            let old = try prime(fixture, context)
            let writer = RecordingResponseWriter(channel: fixture.client)
            let exchange = fixture.admit("/original?q=old", method: .PUT, headers: HTTPHeaders([
                ("X-Edited", "old"), ("X-Secret", "s"), ("Authorization", "Basic a"), ("Content-Length", "4"),
            ]), writer: writer, context: context)
            exchange.receiveRequest(.body(ByteBuffer(string: "data")))
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            let first = try fixture.written(old)
            #expect(first.hasPrefix("PUT /mapped?v=1 HTTP/1.1\r\n"), "\(first)")
            #expect(first.contains("\r\nHost: mapped.test:8080\r\n"))
            #expect(first.contains("\r\nX-Edited: new\r\n"))
            #expect(first.hasSuffix("\r\n\r\ndata"))
            for leaked in ["old", "X-Secret", "Authorization", "example.test", "/original"] {
                #expect(!first.contains(leaked), "\(leaked)")
            }
            try old.close().wait()
            #expect(fixture.connections.count == 2)
            let fresh = try fixture.connect(1)
            #expect(try fixture.written(fresh) == first)
            #expect(fixture.connectedEndpoints == ["mapped.test:8080", "mapped.test:8080"])
            // One replay only: a second failure is a 502, never a third attempt.
            try fresh.close().wait()
            fixture.loop.run()
            #expect(fixture.connections.count == 2)
            #expect(writer.heads.map(\.status.code) == [502])
            let matches = try #require(try fixture.flow("/original?q=old").provenance.ruleMatches)
            #expect(matches.outcomes.count == 2)
        }
    }

    @Test func neverRetryPolicyDisablesTheReplay() async throws {
        try await withConnectionFixture { fixture in
            fixture.expectedEndpoint = (host: "mapped.test", port: 8080)
            let context = fixture.context(rules: TestRules.provider([Self.mapped]))
            let old = try prime(fixture, context)
            let writer = RecordingResponseWriter(channel: fixture.client)
            let exchange = fixture.admit("/never", writer: writer, context: context,
                                         policy: HTTPExecutionPolicy(retry: .never))
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            #expect(try fixture.written(old).hasPrefix("GET /mapped?v=1 HTTP/1.1\r\n"))
            try old.close().wait()
            fixture.loop.run()
            #expect(fixture.connections.count == 1)
            #expect(writer.heads.map(\.status.code) == [502])
        }
    }

    /// An interim response is a response: no replay afterwards, and the final-response rules never ran.
    @Test(arguments: [100, 103])
    func interimResponseDisablesReplayOfTheEffectiveRequest(status: Int) async throws {
        try await withConnectionFixture { fixture in
            fixture.expectedEndpoint = (host: "mapped.test", port: 8080)
            let context = fixture.context(rules: TestRules.provider([
                Self.mapped, TestRules.headers(.response, [.set(name: "X-Resp", value: "1")]),
            ]))
            let old = try prime(fixture, context)
            let writer = RecordingResponseWriter(channel: fixture.client)
            let exchange = fixture.admit("/interim", writer: writer, context: context)
            exchange.receiveRequest(.end(nil))
            exchange.execute()
            _ = try fixture.written(old)
            try old.writeInbound(ByteBuffer(string: "HTTP/1.1 \(status) Interim\r\n\r\n"))
            try old.close().wait()
            fixture.loop.run()
            #expect(fixture.connections.count == 1)
            #expect(writer.heads.map(\.status.code) == [UInt(status)])
            #expect(writer.heads.first?.headers["X-Resp"].isEmpty == true)
            let matches = try #require(try fixture.flow("/interim").provenance.ruleMatches)
            #expect(matches.outcomes.count == 1)
        }
    }
}

extension UpstreamRetryTests {
    // A small file-first exact source must not accidentally opt into automatic retry. With a
    // local 100, the same EOF must close the stream without retrying or inventing another 100.
    @Test(arguments: [false, true]) func collectedSmallSpoolNeverRetriesStaleConnection(local100: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FlowStore(bodyDirectory: root)
        let b = BreakpointCoordinator()
        var rule = TestRules.breakpoint(.request, matcher: .init(path: .exact("/target")))
        rule.action = .breakpoint(direction: .request, mode: .fullBody)
        let origin = try await RetryOrigin.start(behavior: .closeFirstTarget)
        var config = ProxyConfiguration(); config.port = 0
        let server = ProxyServer(configuration: config, certificateAuthority: try CertificateAuthority.generate(),
            store: store, passthrough: PassthroughRegistry(), processLookup: .none,
            rules: TestRules.provider([rule]), breakpoints: b)
        var client: RawClient?
        do {
            try await server.start()
            let c = try await RawClient.connect(port: try #require(server.boundPort)); client = c
            try await c.send("GET http://127.0.0.1:\(origin.port)/prime HTTP/1.1\r\nHost: localhost\r\n\r\n")
            _ = try await c.receive(until: "primed")
            let expectation = local100 ? "Expect: 100-continue\r\n" : ""
            try await c.send("GET http://127.0.0.1:\(origin.port)/target HTTP/1.1\r\nHost: localhost\r\nContent-Length: 3\r\n\(expectation)\r\n")
            if local100 { #expect(try await c.receive(until: "\r\n\r\n").contains("100 Continue")) }
            try await c.send("abc")
            try await waitUntil("collected stale-connection request") { b.snapshot().first?.state == .pausedBody }
            let t = try #require(b.snapshot().first)
            #expect(t.bodyLength == 3)
            #expect(await b.perform(.continue(token: t.token, edit: .init(head: t.effectiveHead))) == .accepted)
            if local100 { try await c.waitUntilClosed(); #expect(c.remainingBytes().isEmpty) }
            else { #expect(try await c.receive(until: "\r\n\r\n").contains("502 Bad Gateway")) }
            let flow = try await waitForFlow(store) { $0.path == "/target" && $0.state != .inProgress }
            #expect(origin.state.withLock { $0.connections } == 1)
            #expect(origin.state.withLock { $0.targetRequests } == 1)
            #expect(flow.messages[.upstreamRequest]?.headers.value(for: "expect") == nil)
            #expect(try flow.requestBody?.load() == Data("abc".utf8))
            try await c.close(); client = nil
            try await server.stop(); try await origin.stop()
        } catch {
            if let client { try? await client.close() }
            b.shutdown(); try? await server.stop(); try? await origin.stop(); throw error
        }
    }
}
