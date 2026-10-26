import CertKit
import FlowStore
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import RulesEngine
import Testing
import os
@testable import ProxyCore

/// Compose sends through a real `ProxyServer`: the server-owned service, its virtual client, the
/// production upstream pool/connector/TLS path and the real recorder. Origins are loopback only.
@Suite(.serialized, .timeLimit(.minutes(3)), .productionChinese) struct ComposeServiceTests {
    @Test func sendGetRecordsFlowAndReturnsResponse() async throws {
        try await ComposeFixture.run { fx in
            let request = ComposeRequest(method: "GET", url: fx.url("/hello"), sourceFlowID: 41)
            let result = await fx.compose.send(request)
            #expect(result.failure == nil)
            let response = try #require(result.response)
            #expect(response.status == 200)
            #expect(response.body == Data("hello".utf8))
            #expect(response.bodyBytes == 5)
            #expect(!response.truncated)
            #expect(response.headers.contains(HeaderField(name: "X-Origin", value: "compose-fixture")))
            #expect(result.delivery == .answered)
            #expect(result.partialResponse == nil)
            let flowID = try #require(result.flowID)
            let flow = try await waitForFlow(fx.store) { $0.id == flowID && $0.state == .completed }
            guard case .compose(let sendID, let sourceFlowID, let boundary) = flow.provenance.source else {
                Issue.record("not a Compose flow: \(flow.provenance)"); return
            }
            #expect(sendID == request.id)
            #expect(sourceFlowID == 41)
            #expect(boundary == nil)
            #expect(flow.statusCode == 200)
            #expect(flow.messages[.composeSubmitted] != nil)
            #expect(flow.messages[.composeDelivered]?.transferState == .finished)
            #expect(flow.messages[.upstreamRequest]?.transferState == .finished)
            #expect(flow.messages[.downstreamRequest] == nil)
            #expect(flow.messages[.downstreamResponse] == nil)
            #expect(flow.transport.downstreamRequest == nil)
            #expect(flow.transport.downstreamResponse == nil)
            #expect(flow.clientVisibleMessage(.response) != nil)
            #expect(fx.origin.state.withLock { $0.requests["/hello"] } == 1)
            fx.expectIdle()
        }
    }

    @Test func headersOrderAndDuplicatesPreserved() async throws {
        try await ComposeFixture.run { fx in
            let headers = [HeaderField(name: "X-Dup", value: "1"), HeaderField(name: "X-Other", value: "a"),
                           HeaderField(name: "x-dup", value: "2"), HeaderField(name: "Accept", value: "*/*")]
            let result = await fx.compose.send(ComposeRequest(method: "GET", url: fx.url("/headers?q=1&q=2"), headers: headers))
            #expect(result.failure == nil)
            let seen = try #require(fx.origin.state.withLock { $0.heads.last })
            #expect(seen.uri == "/headers?q=1&q=2")
            let names = seen.headers.map { "\($0.name): \($0.value)" }
            #expect(names.filter { !$0.lowercased().hasPrefix("host:") } == ["X-Dup: 1", "X-Other: a", "x-dup: 2", "Accept: */*"])
            #expect(seen.headers["host"] == ["127.0.0.1:\(fx.origin.port)"])
            fx.expectIdle()
        }
    }

    @Test func postBodyBytesAndFileAsset() async throws {
        let bytes = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        try await ComposeFixture.run(withAssets: true) { fx in
            let small = Data("x=1&y=two".utf8)
            let first = await fx.compose.send(ComposeRequest(method: "POST", url: fx.url("/echo"),
                headers: [HeaderField(name: "Content-Type", value: "text/plain"), HeaderField(name: "Content-Length", value: "999")],
                body: .bytes(small)))
            #expect(first.failure == nil)
            #expect(first.response?.body == small)
            #expect(fx.origin.state.withLock { $0.bodies.last } == [UInt8](small))
            // A stale declared length is replaced by the exact length, in place.
            let firstHead = try #require(fx.origin.state.withLock { $0.heads.last })
            #expect(firstHead.headers["content-length"] == [String(small.count)])
            #expect(firstHead.headers.map(\.name).first == "Content-Type")

            let asset = try await fx.importAsset(bytes)
            let assetRequest = ComposeRequest(method: "PUT", url: fx.url("/echo"), body: .asset(asset.id))
            let second = await fx.compose.send(assetRequest)
            #expect(second.failure == nil)
            #expect(second.response?.bodyBytes == UInt64(bytes.count))
            #expect(second.response?.body == bytes)
            #expect(fx.lifetimes.bodyBytesRead(assetRequest.id) == bytes.count)
            #expect(fx.origin.state.withLock { $0.bodies.last } == [UInt8](bytes))
            let flowID = try #require(second.flowID)
            let flow = try await waitForFlow(fx.store) { $0.id == flowID && $0.state == .completed }
            #expect(try flow.requestBody?.load() == bytes)
            #expect(flow.messages[.upstreamRequest]?.transferState == .finished)
            try await fx.expectReleased(assetRequest.id)
            #expect(fx.budgets?.snapshot().bytes[.io, default: 0] == 0)

            let missing = await fx.compose.send(ComposeRequest(method: "PUT", url: fx.url("/echo"), body: .asset(UUID())))
            #expect(missing.failure?.code == ComposeFailureCode.bodyUnavailable.rawValue)
            #expect(missing.flowID == nil)
            #expect(fx.origin.state.withLock { $0.requests["/echo"] } == 2)
            fx.expectIdle()
        }
    }

    @Test func httpsViaUpstreamTLS() async throws {
        let originCA = try CertificateAuthority.generate(commonName: "Compose origin CA")
        let roots = NIOSSLTrustRoots.certificates([try NIOSSLCertificate(bytes: originCA.rootCertificateDER, format: .der)])
        try await ComposeFixture.run(originTLS: try originCA.leaf(for: "localhost"), configure: { $0.upstreamTrustRoots = roots }) { fx in
            let result = await fx.compose.send(ComposeRequest(method: "GET", url: try #require(URL(string: "https://localhost:\(fx.origin.port)/hello"))))
            #expect(result.failure == nil)
            #expect(result.response?.body == Data("hello".utf8))
            let flowID = try #require(result.flowID)
            let flow = try await waitForFlow(fx.store) { $0.id == flowID && $0.state == .completed }
            #expect(flow.scheme == "https")
            #expect(flow.transport.upstreamRequest == .http1_1)
            fx.expectIdle()
        }
        // The same origin with an untrusted root fails at the real upstream TLS verification.
        try await ComposeFixture.run(originTLS: try originCA.leaf(for: "localhost")) { fx in
            let result = await fx.compose.send(ComposeRequest(method: "GET", url: try #require(URL(string: "https://localhost:\(fx.origin.port)/hello"))))
            #expect(result.response == nil)
            #expect(result.failure?.code == "upstream.tlsFailed")
            #expect(fx.origin.state.withLock { $0.requests["/hello"] } == nil)
            fx.expectIdle()
        }
    }

    @Test func h2OriginThroughUpstreamTLS() async throws {
        let origin = try await HTTP2TestOrigin.start(protocols: ["h2"])
        do {
            let roots = NIOSSLTrustRoots.certificates([try NIOSSLCertificate(bytes: origin.ca.rootCertificateDER, format: .der)])
            try await ComposeFixture.run(configure: { $0.upstreamTrustRoots = roots }) { fx in
                let result = await fx.compose.send(ComposeRequest(method: "GET",
                    url: try #require(URL(string: "https://localhost:\(origin.port)/h2"))))
                #expect(result.failure == nil)
                #expect(result.response?.status == 200)
                #expect(result.response?.body == Data("fixture-body".utf8))
                #expect(result.response?.trailers.contains(HeaderField(name: "x-finish", value: "done")) == true)
                let flowID = try #require(result.flowID)
                let flow = try await waitForFlow(fx.store) { $0.id == flowID && $0.state == .completed }
                #expect(flow.transport.upstreamRequest == .http2)
                #expect(origin.counts.negotiated == [.http2])
                fx.expectIdle()
            }
            try await origin.stop()
        } catch { try? await origin.stop(); throw error }
    }

    @Test func noRetryOnConnectionReset() async throws {
        try await ComposeFixture.run { fx in
            let request = ComposeRequest(method: "GET", url: fx.url("/reset"))
            let result = await fx.compose.send(request)
            #expect(result.response == nil)
            #expect(result.failure?.code == "upstream.unreachable")
            // The head was handed to the upstream before it closed: what the origin did is unknown.
            #expect(result.delivery == .unknown)
            #expect(result.partialResponse == nil)
            #expect(fx.origin.state.withLock { $0.requests["/reset"] } == 1)
            #expect(fx.origin.state.withLock { $0.connections } == 1)
            let flowID = try #require(result.flowID)
            let flow = try await waitForFlow(fx.store) { $0.id == flowID }
            if case .failed = flow.state {} else { Issue.record("flow not failed: \(flow.state)") }
            try await fx.expectReleased(request.id)
        }
    }

    @Test func redirectNotFollowed() async throws {
        try await ComposeFixture.run { fx in
            let result = await fx.compose.send(ComposeRequest(method: "GET", url: fx.url("/redirect")))
            #expect(result.failure == nil)
            #expect(result.response?.status == 302)
            #expect(result.response?.headers.contains(HeaderField(name: "Location", value: "/target")) == true)
            #expect(result.response?.body == Data("moved".utf8))
            #expect(fx.origin.state.withLock { $0.requests["/target"] } == nil)
            fx.expectIdle()
        }
    }

    @Test func concurrencyCappedAtConfiguredLimitWithQueue() async throws {
        try await ComposeFixture.run(limits: .init(concurrentSends: 4)) { fx in
            let sends = (0..<6).map { index in
                Task { await fx.compose.send(ComposeRequest(method: "GET", url: fx.url("/hold?n=\(index)"))) }
            }
            try await waitUntil("four held at the origin and two queued") {
                fx.origin.state.withLock { $0.concurrent } == 4 && fx.compose.resources.queued == 2
            }
            #expect(fx.compose.resources.active == 4)
            fx.origin.releaseHeld()
            var statuses: [Int] = []
            for send in sends { statuses.append(await send.value.response?.status ?? 0) }
            #expect(statuses == Array(repeating: 200, count: 6))
            #expect(fx.origin.state.withLock { $0.maxConcurrent } == 4)
            #expect(fx.origin.state.withLock { $0.requests["/hold"] } == 6)
            fx.expectIdle()
        }
    }

    /// Repeat sends (spec D13) rely on the default limit admitting ten sends at once.
    @Test func tenConcurrentSendsAreAllAdmittedWithoutBusy() async throws {
        #expect(ComposeService.Limits().concurrentSends == 10)
        #expect(ComposeService.Limits().queuedSends == 16)
        try await ComposeFixture.run { fx in
            let sends = (0..<10).map { index in
                Task { await fx.compose.send(ComposeRequest(method: "GET", url: fx.url("/hold?n=\(index)"))) }
            }
            try await waitUntil("ten held at the origin") { fx.origin.state.withLock { $0.maxConcurrent } == 10 }
            #expect(fx.compose.resources.active == 10)
            #expect(fx.compose.resources.queued == 0)
            fx.origin.releaseHeld()
            var results: [ComposeResult] = []
            for send in sends { results.append(await send.value) }
            #expect(results.allSatisfy { $0.failure == nil && $0.response?.status == 200 })
            #expect(fx.origin.state.withLock { $0.requests["/hold"] } == 10)
            #expect(fx.compose.resources == ComposeResources())
            fx.expectIdle()
        }
    }

    @Test func repeatTagIsRecordedInProvenance() async throws {
        try await ComposeFixture.run { fx in
            let tag = RepeatRunTag(runID: UUID(), index: 3, total: 9)
            let tagged = ComposeRequest(method: "GET", url: fx.url("/hello"), sourceFlowID: 5, repeatTag: tag)
            let plain = ComposeRequest(method: "GET", url: fx.url("/hello"))
            #expect(plain.repeatTag == nil)
            let taggedResult = await fx.compose.send(tagged)
            let plainResult = await fx.compose.send(plain)
            #expect(taggedResult.failure == nil && plainResult.failure == nil)
            let taggedID = try #require(taggedResult.flowID)
            let plainID = try #require(plainResult.flowID)
            let taggedFlow = try await waitForFlow(fx.store) { $0.id == taggedID && $0.state == .completed }
            let plainFlow = try await waitForFlow(fx.store) { $0.id == plainID && $0.state == .completed }
            #expect(taggedFlow.provenance.tools.repeatRun == tag)
            #expect(taggedFlow.provenance.isRepeat && taggedFlow.provenance.isCompose)
            guard case .compose(let sendID, let sourceFlowID, _) = taggedFlow.provenance.source else {
                Issue.record("not a Compose flow: \(taggedFlow.provenance)"); return
            }
            #expect(sendID == tagged.id && sourceFlowID == 5)
            #expect(plainFlow.provenance.tools.repeatRun == nil && !plainFlow.provenance.isRepeat)
            fx.expectIdle()
        }
    }

    @Test func queueOverflowFailsFast() async throws {
        try await ComposeFixture.run(limits: .init(concurrentSends: 1, queuedSends: 1)) { fx in
            let held = Task { await fx.compose.send(ComposeRequest(method: "GET", url: fx.url("/hold"))) }
            try await waitUntil("one held") { fx.origin.state.withLock { $0.concurrent } == 1 }
            let queued = Task { await fx.compose.send(ComposeRequest(method: "GET", url: fx.url("/hold"))) }
            try await waitUntil("one queued") { fx.compose.resources.queued == 1 }
            let overflow = await fx.compose.send(ComposeRequest(method: "GET", url: fx.url("/hello")))
            #expect(overflow.failure?.code == ComposeFailureCode.busy.rawValue)
            #expect(overflow.failure?.message.isEmpty == false)
            #expect(overflow.flowID == nil)
            #expect(fx.origin.state.withLock { $0.requests["/hello"] } == nil)
            fx.origin.releaseHeld()
            #expect(await held.value.response?.status == 200)
            #expect(await queued.value.response?.status == 200)
            fx.expectIdle()
        }
    }

    @Test func recordsEvenWhenRecordingPaused() async throws {
        try await ComposeFixture.run(configure: { $0.recordingEnabled = false }) { fx in
            let result = await fx.compose.send(ComposeRequest(method: "GET", url: fx.url("/hello")))
            #expect(result.response?.status == 200)
            let flowID = try #require(result.flowID)
            let flow = try await waitForFlow(fx.store) { $0.id == flowID && $0.state == .completed }
            #expect(flow.provenance.isCompose)
            #expect(try flow.responseBody?.load() == Data("hello".utf8))
            fx.expectIdle()
        }
    }

    @Test func responseOverCapTruncatedButCompleted() async throws {
        try await ComposeFixture.run(limits: .init(responseBodyBytes: 1_000)) { fx in
            let result = await fx.compose.send(ComposeRequest(method: "GET", url: fx.url("/big?bytes=200000")))
            #expect(result.failure == nil)
            let response = try #require(result.response)
            #expect(response.status == 200)
            #expect(response.truncated)
            #expect(response.body == Data(repeating: 0x62, count: 1_000))
            #expect(response.bodyBytes == 200_000)
            let flowID = try #require(result.flowID)
            let flow = try await waitForFlow(fx.store) { $0.id == flowID && $0.state == .completed }
            #expect(try flow.responseBody?.load().count == 200_000)
            #expect(flow.messages[.composeDelivered]?.transferState == .finished)
            fx.expectIdle()
        }
    }

    @Test func shutdownCancelsInflightAndQueued() async throws {
        try await ComposeFixture.run(limits: .init(concurrentSends: 1, queuedSends: 2)) { fx in
            let sends = (0..<3).map { _ in Task { await fx.compose.send(ComposeRequest(method: "GET", url: fx.url("/hold"))) } }
            try await waitUntil("one held and two queued") {
                fx.origin.state.withLock { $0.concurrent } == 1 && fx.compose.resources.queued == 2
            }
            try await fx.server.stop()
            var codes: [String?] = []
            for send in sends { codes.append(await send.value.failure?.code) }
            #expect(codes == Array(repeating: ComposeFailureCode.shutdown.rawValue, count: 3))
            #expect(fx.origin.state.withLock { $0.requests["/hold"] } == 1)
            fx.expectIdle()
            let afterStop = await fx.compose.send(ComposeRequest(method: "GET", url: fx.url("/hello")))
            #expect(afterStop.failure?.code == "proxy.serviceUnavailable")
            #expect(afterStop.flowID == nil)
            let flow = try await waitForFlow(fx.store) { $0.path == "/hold" }
            if case .failed = flow.state {} else { Issue.record("held flow not failed: \(flow.state)") }
        }
    }

    @Test func selfTargetRejected() async throws {
        try await ComposeFixture.run { fx in
            let port = try #require(fx.server.boundPort)
            for host in ["127.0.0.1", "localhost"] {
                let result = await fx.compose.send(ComposeRequest(method: "GET", url: try #require(URL(string: "http://\(host):\(port)/loop"))))
                #expect(result.response == nil)
                #expect(result.failure?.code == "rule.selfTarget")
            }
            fx.expectIdle()
        }
    }

    @Test func cancelRemovesQueuedAndEndsInflight() async throws {
        try await ComposeFixture.run(limits: .init(concurrentSends: 1, queuedSends: 1)) { fx in
            let first = ComposeRequest(method: "GET", url: fx.url("/hold")), second = ComposeRequest(method: "GET", url: fx.url("/hold"))
            let held = Task { await fx.compose.send(first) }
            try await waitUntil("one held") { fx.origin.state.withLock { $0.concurrent } == 1 }
            let queued = Task { await fx.compose.send(second) }
            try await waitUntil("one queued") { fx.compose.resources.queued == 1 }
            fx.compose.cancel(second.id)
            #expect(await queued.value.failure?.code == ComposeFailureCode.cancelled.rawValue)
            fx.compose.cancel(first.id)
            #expect(await held.value.failure?.code == ComposeFailureCode.cancelled.rawValue)
            #expect(fx.origin.state.withLock { $0.requests["/hold"] } == 1)
            fx.expectIdle()
        }
    }

    // Controller ruling (design RC-09): rules apply to a Compose send only when switched on.
    @Test func rulesAreNotAppliedByDefault() async throws {
        let rule = TestRules.headers(.request, [.set(name: "X-Rule", value: "applied")])
        try await ComposeFixture.run(rules: TestRules.provider([rule], revision: 7)) { fx in
            let result = await fx.compose.send(ComposeRequest(method: "GET", url: fx.url("/hello")))
            #expect(result.response?.status == 200)
            let seen = try #require(fx.origin.state.withLock { $0.heads.last })
            #expect(seen.headers["X-Rule"] == [])
            let flowID = try #require(result.flowID)
            let flow = try await waitForFlow(fx.store) { $0.id == flowID && $0.state == .completed }
            #expect(flow.provenance.isCompose)
            #expect(flow.provenance.rulesDisabled)
            #expect(flow.provenance.ruleMatches == nil)
            fx.expectIdle()
        }
    }

    @Test func rulesApplyWhenEnabled() async throws {
        let rule = TestRules.headers(.request, [.set(name: "X-Rule", value: "applied")])
        try await ComposeFixture.run(rules: TestRules.provider([rule], revision: 7)) { fx in
            let result = await fx.compose.send(ComposeRequest(method: "GET", url: fx.url("/hello"), policy: ComposePolicy(applyRules: true)))
            #expect(result.response?.status == 200)
            let seen = try #require(fx.origin.state.withLock { $0.heads.last })
            #expect(seen.headers["X-Rule"] == ["applied"])
            let flowID = try #require(result.flowID)
            let flow = try await waitForFlow(fx.store) { $0.id == flowID && $0.state == .completed }
            #expect(flow.provenance.isCompose)
            #expect(!flow.provenance.rulesDisabled)
            #expect(flow.provenance.ruleMatches?.revision == 7)
            #expect(flow.provenance.ruleMatches?.ruleIDs == [rule.id])
            fx.expectIdle()
        }
    }

    // Fix round 1 (M7): the caller's task owns only its own admission.
    @Test func callerTaskCancellationEndsSend() async throws {
        try await ComposeFixture.run { fx in
            let request = ComposeRequest(method: "GET", url: fx.url("/hold"))
            let send = Task { await fx.compose.send(request) }
            try await waitUntil("held") { fx.origin.state.withLock { $0.concurrent } == 1 }
            send.cancel()
            #expect(await send.value.failure?.code == ComposeFailureCode.cancelled.rawValue)
            try await fx.expectReleased(request.id)
        }
    }

    @Test func cancelledCallerReusingAnIDLeavesTheOriginalSendAlone() async throws {
        try await ComposeFixture.run { fx in
            let request = ComposeRequest(method: "GET", url: fx.url("/hold"))
            let original = Task { await fx.compose.send(request) }
            try await waitUntil("held") { fx.origin.state.withLock { $0.concurrent } == 1 }
            let reused = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return await fx.compose.send(request)
            }
            #expect(await reused.value.failure?.code == ComposeFailureCode.cancelled.rawValue)
            #expect(fx.compose.resources.active == 1)
            #expect(fx.origin.state.withLock { $0.concurrent } == 1)
            fx.origin.releaseHeld()
            #expect(await original.value.response?.status == 200)
            try await fx.expectReleased(request.id)
        }
    }

    // Fix round 1 (I-1): a finished send must not keep its virtual client or exchange alive.
    @Test func successReleasesContextAndExchange() async throws {
        try await ComposeFixture.run { fx in
            let request = ComposeRequest(method: "GET", url: fx.url("/hello"))
            #expect(await fx.compose.send(request).response?.status == 200)
            try await fx.expectReleased(request.id)
        }
    }

    @Test func localFailureReleasesContextAndExchange() async throws {
        try await ComposeFixture.run { fx in
            let port = try #require(fx.server.boundPort)
            let request = ComposeRequest(method: "GET", url: try #require(URL(string: "http://127.0.0.1:\(port)/loop")))
            #expect(await fx.compose.send(request).failure?.code == "rule.selfTarget")
            try await fx.expectReleased(request.id)
        }
    }

    @Test func cancelReleasesContextAndExchange() async throws {
        try await ComposeFixture.run { fx in
            let request = ComposeRequest(method: "GET", url: fx.url("/hold"))
            let send = Task { await fx.compose.send(request) }
            try await waitUntil("held") { fx.origin.state.withLock { $0.concurrent } == 1 }
            fx.compose.cancel(request.id)
            #expect(await send.value.failure?.code == ComposeFailureCode.cancelled.rawValue)
            try await fx.expectReleased(request.id)
        }
    }

    @Test func shutdownReleasesContextAndExchange() async throws {
        try await ComposeFixture.run { fx in
            let request = ComposeRequest(method: "GET", url: fx.url("/hold"))
            let send = Task { await fx.compose.send(request) }
            try await waitUntil("held") { fx.origin.state.withLock { $0.concurrent } == 1 }
            try await fx.server.stop()
            #expect(await send.value.failure?.code == ComposeFailureCode.shutdown.rawValue)
            try await fx.expectReleased(request.id)
        }
    }

    @Test func invalidRequestsAreRejectedBeforeAnyFlow() async throws {
        try await ComposeFixture.run { fx in
            let bad = [
                ComposeRequest(method: "GET", url: try #require(URL(string: "ftp://127.0.0.1/x"))),
                ComposeRequest(method: "GET", url: try #require(URL(string: "http://user@127.0.0.1:\(fx.origin.port)/x"))),
                ComposeRequest(method: "BAD METHOD", url: fx.url("/hello")),
                ComposeRequest(method: "GET", url: fx.url("/hello"), headers: [HeaderField(name: "X-Bad", value: "a\r\nInjected: 1")]),
                ComposeRequest(method: "GET", url: fx.url("/hello"), headers: [HeaderField(name: "Upgrade", value: "websocket"),
                                                                               HeaderField(name: "Connection", value: "Upgrade")]),
            ]
            for request in bad {
                let result = await fx.compose.send(request)
                #expect(result.failure?.code == ComposeFailureCode.invalidRequest.rawValue, "\(request.method) \(request.url)")
                #expect(result.failure?.detail?.isEmpty == false)
                #expect(result.delivery == .notSent)
                #expect(result.flowID == nil)
            }
            #expect(fx.origin.state.withLock { $0.connections } == 0)
            #expect(fx.store.allFlows().isEmpty)
            fx.expectIdle()
        }
    }
}

// MARK: - Fixture

struct ComposeFixture {
    let server: ProxyServer
    let store: FlowStore
    let origin: ComposeOrigin
    let assets: ManagedAssetStore?
    let budgets: OwnedFileBudgets?
    let directory: URL
    let lifetimes: ComposeLifetimeProbe
    let breakpoints: BreakpointCoordinator?
    var compose: ComposeService { server.compose }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(origin.port)\(path)")! }

    func importAsset(_ bytes: Data) async throws -> ManagedAsset {
        let source = directory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: source)
        return try await #require(assets).importFile(source, displayName: "compose-body")
    }

    /// The send's virtual client and its exchange were created and are deallocated once the
    /// service quiesced (weak references only; the poll waits for in-flight loop callbacks).
    func expectReleased(_ id: UUID, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let created = lifetimes.alive(id)
        #expect(created.tracked && created.exchangeCreated, sourceLocation: sourceLocation)
        try await waitUntil("context and exchange of the send deallocated") {
            let alive = lifetimes.alive(id)
            return !alive.context && !alive.exchange
        }
        expectIdle(sourceLocation: sourceLocation)
    }

    /// Every terminal path returns pending quota, upstream sockets/leases, file leases and
    /// breakpoint tickets.
    func expectIdle(sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(compose.resources == ComposeResources(), sourceLocation: sourceLocation)
        #expect(breakpoints?.snapshot().isEmpty ?? true, sourceLocation: sourceLocation)
        #expect(budgets?.snapshot().bytes[.io, default: 0] ?? 0 == 0, sourceLocation: sourceLocation)
    }

    /// A send that never left the queue created no virtual client at all.
    func expectNeverStarted(_ id: UUID, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(!lifetimes.alive(id).tracked, sourceLocation: sourceLocation)
        expectIdle(sourceLocation: sourceLocation)
    }

    static func run(
        limits: ComposeService.Limits = .init(), withAssets: Bool = false, originTLS: LeafIdentity? = nil,
        rules: RuleSnapshotProvider? = nil, breakpoints: BreakpointCoordinator? = nil,
        traffic: TrafficPolicyProvider? = nil,
        configure: (inout ProxyConfiguration) -> Void = { _ in }, _ body: (ComposeFixture) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("compose-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FlowStore(bodyDirectory: directory.appendingPathComponent("capture"))
        var configuration = ProxyConfiguration()
        configuration.port = 0
        configuration.portFallbackCount = 0
        configure(&configuration)
        let rulesLimits = RulesLimits()
        let budgets = withAssets ? OwnedFileBudgets(limits: rulesLimits) : nil
        let assets = budgets.map { ManagedAssetStore(directory: directory.appendingPathComponent("assets"), limits: rulesLimits, budgets: $0) }
        let origin = try await ComposeOrigin.start(tls: originTLS)
        let lifetimes = ComposeLifetimeProbe()
        let server = ProxyServer(configuration: configuration, certificateAuthority: try CertificateAuthority.generate(),
            store: store, passthrough: PassthroughRegistry(), processLookup: .none, drainDeadline: .standard,
            rules: rules, assets: assets, breakpoints: breakpoints, breakpointSpoolDirectory: directory.appendingPathComponent("spool"), composeLimits: limits,
            composeLifetimes: lifetimes, traffic: traffic)
        do {
            try await server.start()
            try await body(ComposeFixture(server: server, store: store, origin: origin, assets: assets, budgets: budgets, directory: directory,
                                         lifetimes: lifetimes, breakpoints: breakpoints))
        } catch {
            origin.releaseHeld()
            try? await server.stop()
            try? await origin.stop()
            throw error
        }
        origin.releaseHeld()
        try await server.stop()
        try await origin.stop()
    }
}

/// A loopback origin with fixed routes:
/// - `/hello` → "hello"; `/headers` → 200; `/echo` → the request body
/// - `/redirect` → 302 to /target; `/big?bytes=N` → N bytes of "b"
/// - `/reset` → the connection closes on the head, before any response
/// - `/hold` → answered only after `releaseHeld()`, counting concurrent holds
/// - `/stream` → a 200 head declaring 10 bytes and "hello" at once; "world" only after `releaseHeld()`
/// `closed` counts connections that ended.
final class ComposeOrigin: Sendable {
    struct State {
        var connections = 0
        var closed = 0
        var requests: [String: Int] = [:]
        var heads: [HTTPRequestHead] = []
        var bodies: [[UInt8]] = []
        var concurrent = 0
        var maxConcurrent = 0
    }
    let state: OSAllocatedUnfairLock<State>
    let port: Int
    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel
    private let release: EventLoopPromise<Void>

    private init(group: MultiThreadedEventLoopGroup, channel: Channel, state: OSAllocatedUnfairLock<State>, release: EventLoopPromise<Void>) {
        self.group = group
        self.channel = channel
        self.state = state
        self.release = release
        self.port = channel.localAddress!.port!
    }

    static func start(tls: LeafIdentity?) async throws -> ComposeOrigin {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let state = OSAllocatedUnfairLock(initialState: State())
        let release = group.next().makePromise(of: Void.self)
        do {
            let context = try tls.map { identity -> NIOSSLContext in
                var configuration = TLSConfiguration.makeServerConfiguration(
                    certificateChain: [.certificate(try NIOSSLCertificate(bytes: identity.certificateDER, format: .der))],
                    privateKey: .privateKey(try NIOSSLPrivateKey(bytes: identity.privateKeyDER, format: .der)))
                configuration.applicationProtocols = ["http/1.1"]
                return try NIOSSLContext(configuration: configuration)
            }
            let held = release.futureResult
            let channel = try await ServerBootstrap(group: group).childChannelInitializer { channel in
                state.withLock { $0.connections += 1 }
                return channel.eventLoop.makeCompletedFuture {
                    if let context { try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: context)) }
                    try channel.pipeline.syncOperations.addHandlers([
                        HTTPResponseEncoder(), ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)),
                        ComposeOriginHandler(state: state, held: held),
                    ])
                }
            }.bind(host: "127.0.0.1", port: 0).get()
            return ComposeOrigin(group: group, channel: channel, state: state, release: release)
        } catch {
            release.fail(ChannelError.ioOnClosedChannel)
            try? await group.shutdownGracefully()
            throw error
        }
    }

    func releaseHeld() { release.succeed(()) }

    func stop() async throws {
        release.succeed(())
        try? await channel.close().get()
        try await group.shutdownGracefully()
    }
}

private final class ComposeOriginHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private let state: OSAllocatedUnfairLock<ComposeOrigin.State>
    private let held: EventLoopFuture<Void>
    private var head: HTTPRequestHead?
    private var body: [UInt8] = []

    init(state: OSAllocatedUnfairLock<ComposeOrigin.State>, held: EventLoopFuture<Void>) {
        self.state = state
        self.held = held
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            let path = String(head.uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
            state.withLock { $0.requests[path, default: 0] += 1; $0.heads.append(head) }
            if path == "/reset" { context.close(promise: nil); return }
            self.head = head
            body = []
        case .body(let bytes): body.append(contentsOf: bytes.readableBytesView)
        case .end:
            guard let head else { return }
            self.head = nil
            let received = body
            state.withLock { $0.bodies.append(received) }
            respond(head, body: received, context: context)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }

    func channelInactive(context: ChannelHandlerContext) {
        state.withLock { $0.closed += 1 }
        context.fireChannelInactive()
    }

    private func respond(_ head: HTTPRequestHead, body: [UInt8], context: ChannelHandlerContext) {
        let parts = head.uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(parts[0])
        let query = parts.count > 1 ? String(parts[1]) : ""
        switch path {
        case "/hello", "/headers": send(.ok, ByteBuffer(string: path == "/hello" ? "hello" : "headers"), context: context)
        case "/echo": send(.ok, ByteBuffer(bytes: body), context: context)
        case "/redirect": send(.found, ByteBuffer(string: "moved"), extra: [("Location", "/target")], context: context)
        case "/big":
            let count = query.split(separator: "&").compactMap { $0.hasPrefix("bytes=") ? Int($0.dropFirst(6)) : nil }.first ?? 0
            send(.ok, ByteBuffer(repeating: 0x62, count: count), context: context)
        case "/hold":
            state.withLock { $0.concurrent += 1; $0.maxConcurrent = max($0.maxConcurrent, $0.concurrent) }
            let channel = context.channel
            held.hop(to: context.eventLoop).assumeIsolated().whenComplete { [state] _ in
                state.withLock { $0.concurrent -= 1 }
                guard channel.isActive else { return }
                self.send(.ok, ByteBuffer(string: "held"), context: context)
            }
        case "/stream":
            let headers = HTTPHeaders([("X-Origin", "compose-fixture"), ("Content-Length", "10")])
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: "hello")))), promise: nil)
            let channel = context.channel
            held.hop(to: context.eventLoop).assumeIsolated().whenComplete { _ in
                guard channel.isActive else { return }
                context.write(self.wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: "world")))), promise: nil)
                context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }
        default: send(.notFound, ByteBuffer(string: "not found"), context: context)
        }
    }

    private func send(_ status: HTTPResponseStatus, _ body: ByteBuffer, extra: [(String, String)] = [], context: ChannelHandlerContext) {
        var headers = HTTPHeaders([("X-Origin", "compose-fixture"), ("Content-Length", String(body.readableBytes))])
        headers.add(contentsOf: extra)
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
}
