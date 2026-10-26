import FlowStore
import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOSSL
import Testing
import os
import RulesEngine
@testable import ProxyCore

@Test(.productionChinese) func exchangeByteCountsArePublishedWhileStreamingAtMostEvery250ms() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FlowStore(bodyDirectory: directory)
    let loop = EmbeddedEventLoop()
    let recorder = FlowRecorder(
        store: store, scheme: "http", method: "POST", host: "example.com", port: 80, path: "/",
        requestHeaders: HTTPHeaders(), client: nil, eventLoop: loop)
    let id = recorder.id

    recorder.recordRequestBody(ByteBuffer(repeating: 1, count: 10))
    recorder.recordResponseBody(ByteBuffer(repeating: 2, count: 100))
    #expect(store.flow(id)?.bytesReceived == 0)  // not per chunk
    loop.advanceTime(by: .milliseconds(249))
    #expect(store.flow(id)?.bytesReceived == 0)
    loop.advanceTime(by: .milliseconds(1))
    #expect(store.flow(id)?.bytesSent == 10)
    #expect(store.flow(id)?.bytesReceived == 100)
    #expect(store.flow(id)?.state == .inProgress)

    recorder.recordResponseBody(ByteBuffer(repeating: 3, count: 5))
    recorder.complete()  // the final count is published right away
    #expect(store.flow(id)?.bytesReceived == 105)
    #expect(store.flow(id)?.state == .completed)
    loop.advanceTime(by: .seconds(1))
    #expect(store.flow(id)?.bytesReceived == 105)
}

@Test(.productionChinese) func slowResponseShowsReceivedBytesBeforeItCompletes() async throws {
    try await withHTTP2ControlLoop { loop in
        let finish = loop.makePromise(of: Void.self)
        var released = false
        defer { if !released { finish.succeed(()) } } // setup failure before a transfer exists
        try await ProxyFixture.run(slowResponseBarrier: finish.futureResult) { fx in
            let url = "http://localhost:\(fx.origin.port)/slow"
            let transfer = Task.detached { try curl(["-x", fx.proxyURL, url]) }
            // Observe real publication of "first" before allowing the origin's second/END.
            // Independent origin500ms/proxy250ms timers cannot guarantee that observation.
            let partial: Flow
            do {
                partial = try await waitForFlow(fx.store) { $0.state == .inProgress && $0.bytesReceived == 5 }
            } catch {
                released = true
                finish.succeed(())
                _ = try? await transfer.value
                throw error
            }
            #expect(partial.path == "/slow")
            released = true
            finish.succeed(())
            let r = try await transfer.value
            #expect(r.text == "firstsecond")
            let done = try await waitForFlow(fx.store) { $0.state == .completed }
            #expect(done.bytesReceived == 11)
        }
    }
}

@Suite(.productionChinese) struct FlowRecorderTests {
    @Test func recorderCapturesActualVersions() throws {
        try withTransportRecorder(transport: .init(downstreamRequest: .http2, downstreamStreamID: 3)) { recorder, store in
            // Versions are recorded when the writers accept the heads (write futures), not before.
            recorder.recordUpstreamWrite(
                .head(HTTPRequestHead(version: .http1_1, method: .POST, uri: "/")), version: .http1_1, streamID: 7,
                succeeded: true)
            recorder.recordResponseHead(HTTPResponseHead(version: .http1_0, status: .ok))
            recorder.recordDownstreamWrite(
                .head(HTTPResponseHead(version: .http2, status: .ok)), bodyStream: nil, succeeded: true)
            recorder.complete()
            let flow = try #require(store.flow(recorder.id))
            #expect(flow.transport == .init(downstreamRequest: .http2, downstreamResponse: .http2,
                                            upstreamRequest: .http1_1, upstreamResponse: .http1_0,
                                            downstreamStreamID: 3, upstreamStreamID: 7))
        }
    }

    @Test func explicitUpstreamVersionOverridesAdapterHeadAndUnknownStaysUnknown() throws {
        try withTransportRecorder { recorder, store in
            #expect(store.flow(recorder.id)?.transport == .init())
            recorder.recordResponseHead(HTTPResponseHead(version: .http1_1, status: .ok), upstreamVersion: .http2)
            #expect(store.flow(recorder.id)?.transport.upstreamResponse == .http2)
            #expect(store.flow(recorder.id)?.transport.downstreamResponse == nil)
            recorder.complete()
        }
    }

    @Test func trailersRemainOrderedAfterEarlyResponseAndFinishOnlyOnce() throws {
        try withTransportRecorder { recorder, store in
            recorder.recordRequestBody(ByteBuffer(string: "before"))
            recorder.recordResponseHead(HTTPResponseHead(version: .http1_0, status: .ok))
            recorder.recordResponseBody(ByteBuffer(string: "reply"))
            recorder.complete(trailers: HTTPHeaders([("X-End", "1"), ("X-Other", "2"), ("X-End", "3")]))
            // A keep-alive early response can complete before the rest of the upload arrives.
            recorder.recordRequestBody(ByteBuffer(string: "after"))
            recorder.finishRequest(trailers: HTTPHeaders([("X-Upload", "a"), ("X-Upload", "b")]))
            recorder.complete(trailers: HTTPHeaders([("Wrong", "late")]))
            recorder.finishRequest(trailers: HTTPHeaders([("Wrong", "late")]))
            recorder.fail("late failure")
            let flow = try #require(store.flow(recorder.id))
            #expect(flow.requestTrailers == [.init(name: "X-Upload", value: "a"), .init(name: "X-Upload", value: "b")])
            #expect(flow.responseTrailers == [.init(name: "X-End", value: "1"), .init(name: "X-Other", value: "2"), .init(name: "X-End", value: "3")])
            #expect(flow.requestHeaders.isEmpty)
            #expect(flow.responseHeaders.isEmpty)
            #expect(try flow.requestBody?.load() == Data("beforeafter".utf8))
            #expect(try flow.responseBody?.load() == Data("reply".utf8))
            #expect(flow.bytesSent == 11)
            #expect(flow.bytesReceived == 5)
            #expect(flow.state == .completed)
        }
    }

    @Test func tunnelTransportRemainsUnknown() throws {
        try withTransportRecorder { _, store in
            let id = TunnelRecorder.recordFailure(store: store, host: "example.com", port: 443,
                                                  client: nil, reason: "synthetic", note: nil)
            #expect(store.flow(id)?.transport == .init())
            let tunnel = TunnelRecorder(store: store, host: "example.com", port: 443, client: nil, eventLoop: EmbeddedEventLoop())
            tunnel.close()
            #expect(store.allFlows().allSatisfy { $0.transport == .init() })
        }
    }
}

private func withTransportRecorder(
    transport: HTTPTransportMetadata = .init(),
    _ body: (FlowRecorder, FlowStore) throws -> Void
) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FlowStore(bodyDirectory: directory)
    let recorder = FlowRecorder(store: store, scheme: "http", method: "POST", host: "example.com", port: 80,
                                path: "/", requestHeaders: HTTPHeaders(), client: nil,
                                eventLoop: EmbeddedEventLoop(), transport: transport)
    try body(recorder, store)
}

/// T12 (found end to end: Map Local + a response header rule). The exchange's rule provenance
/// does not know the generated response; recording it must not erase the recorder's own
/// generated-response source (asset and size).
/// R8F2 F4: a replacement that failed (a file that is missing) leaves the flow with no body, not the dropped origin's.
@Test(.productionChinese) func aDiscardedOriginsPartialBodyIsNotRecordedWhenTheReplacementFails() throws {
    try withTransportRecorder { recorder, store in
        recorder.recordResponseBody(ByteBuffer(repeating: 7, count: 20))
        recorder.discardOriginResponse()
        recorder.fail("the replacement file is missing")
        let flow = try #require(store.flow(recorder.id))
        #expect(flow.state == .failed("the replacement file is missing"))
        #expect(flow.responseBody == nil)
        #expect(!flow.responseBodyTruncated)
    }
}

@Test(.productionChinese) func ruleProvenanceUpdateKeepsTheGeneratedResponseSource() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FlowStore(bodyDirectory: directory)
    let recorder = FlowRecorder(
        store: store, scheme: "http", method: "GET", host: "example.com", port: 80, path: "/local",
        requestHeaders: HTTPHeaders(), client: nil, eventLoop: EmbeddedEventLoop())
    let asset = UUID()
    _ = recorder.beginGeneratedResponse(status: .ok, headers: HTTPHeaders(), assetID: asset, representationLength: 5)
    let matches = RuleMatchSummary(revision: 3, ruleIDs: [UUID(), UUID()], total: 2)
    recorder.setProvenance(FlowProvenance(ruleMatches: matches))
    let provenance = try #require(store.flow(recorder.id)?.provenance)
    #expect(provenance.generatedResponse == GeneratedResponseSource(assetID: asset, size: 5))
    #expect(provenance.ruleMatches == matches)
}

// MARK: rule annotations and the publication hold

private let annotationRed = FlowMark(background: "#FF3B30", source: .rule(id: UUID(), name: "red"))!
private let annotationBlue = FlowMark(background: "#007AFF", source: .rule(id: UUID(), name: "blue"))!

private final class AnnouncedFlows: Sendable {
    private let seen = OSAllocatedUnfairLock(initialState: [Flow]())
    private let task: Task<Void, Never>

    init(_ store: FlowStore) {
        let stream = store.changes()
        let seen = seen
        task = Task { for await change in stream { seen.withLock { $0 += change.upserted } } }
    }

    func contains(_ id: Int) -> Bool { seen.withLock { $0.contains { $0.id == id } } }
    deinit { task.cancel() }
}

extension FlowRecorderTests {
    @Test func applyingAnnotationsWritesRuleMarkCommentAndHiddenInOrder() throws {
        try withTransportRecorder { recorder, store in
            recorder.apply([
                .mark(annotationRed), .comment(CommentAction(mode: .append, text: "a")), .mark(annotationBlue),
                .comment(CommentAction(mode: .append, text: "b")), .hide,
            ])
            let flow = try #require(store.flow(recorder.id))
            #expect(flow.ruleMark == annotationBlue)
            #expect(flow.comment == "a b")
            #expect(flow.isHidden)
            #expect(flow.manualMark == nil)
        }
    }

    @Test func emptyAnnotationsChangeNothing() throws {
        try withTransportRecorder { recorder, store in
            let before = try #require(store.flow(recorder.id))
            recorder.apply([])
            #expect(store.flow(recorder.id) == before)
        }
    }

    @Test func ruleAnnotationsLeaveAManualMarkAndAUserCommentOnTop() throws {
        try withTransportRecorder { recorder, store in
            let manual = FlowMark(background: "#34C759", source: .manual)!
            store.setManualMark(manual, for: recorder.id)
            store.setComment("mine", for: recorder.id)
            recorder.apply([.mark(annotationRed), .comment(CommentAction(mode: .append, text: "x"))])
            let flow = try #require(store.flow(recorder.id))
            #expect(flow.displayMark?.source == .manual)
            #expect(flow.displayMark?.background == "#34C759")
            #expect(flow.ruleMark == annotationRed)
            #expect(flow.comment == "mine x")
        }
    }

    @Test func setProvenanceLeavesTheUserFields() throws {
        try withTransportRecorder { recorder, store in
            store.setManualMark(FlowMark(background: "#34C759", source: .manual), for: recorder.id)
            store.setComment("mine", for: recorder.id)
            recorder.apply([.mark(annotationRed), .hide])
            var provenance = FlowProvenance.passive
            provenance.rulesModified = true
            recorder.setProvenance(provenance)
            let flow = try #require(store.flow(recorder.id))
            #expect(flow.provenance.rulesModified)
            #expect(flow.ruleMark == annotationRed)
            #expect(flow.manualMark?.background == "#34C759")
            #expect(flow.comment == "mine")
            #expect(flow.isHidden)
        }
    }

    @Test func recorderWithoutAHoldIsAnnouncedAtOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FlowStore(bodyDirectory: directory)
        let announced = AnnouncedFlows(store)
        let recorder = FlowRecorder(
            store: store, scheme: "http", method: "GET", host: "example.com", port: 80, path: "/",
            requestHeaders: HTTPHeaders(), client: nil, eventLoop: EmbeddedEventLoop())
        try await waitUntil("the flow is announced") { announced.contains(recorder.id) }
    }

    @Test func recorderWithAHoldIsAnnouncedAfterRelease() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FlowStore(bodyDirectory: directory)
        let announced = AnnouncedFlows(store)
        func make(hold: Bool, path: String) -> FlowRecorder {
            FlowRecorder(
                store: store, scheme: "http", method: "GET", host: "example.com", port: 80, path: path,
                requestHeaders: HTTPHeaders(), client: nil, eventLoop: EmbeddedEventLoop(), holdPublication: hold)
        }
        let held = make(hold: true, path: "/held")
        let fence = make(hold: false, path: "/fence")
        try await waitUntil("the fence is announced") { announced.contains(fence.id) }
        #expect(!announced.contains(held.id))
        #expect(store.flow(held.id) != nil) // readable directly all along
        held.releasePublication()
        held.releasePublication() // idempotent
        try await waitUntil("the held flow is announced") { announced.contains(held.id) }
    }
}

@Test(.productionChinese) func setConnectionInfoWritesOnlyNonNilFields() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FlowStore(bodyDirectory: directory)
    let recorder = FlowRecorder(
        store: store, scheme: "https", method: "GET", host: "example.com", port: 443, path: "/",
        requestHeaders: HTTPHeaders(), client: nil, eventLoop: EmbeddedEventLoop(),
        transport: .init(downstreamRequest: .http1_1, downstreamTLSVersion: "TLS 1.3"))
    let certificate = CertificateSummary(
        subject: "CN=example.com", issuer: "CN=CA", serialNumber: "01", sha256Fingerprint: String(repeating: "A", count: 64),
        notBefore: Date(timeIntervalSince1970: 0), notAfter: Date(timeIntervalSince1970: 100))
    recorder.setConnectionInfo(FlowConnectionInfo(clientIP: "10.0.0.2", remoteIP: "93.184.216.34", upstreamTLSVersion: "TLS 1.2", upstreamCertificate: certificate))
    var flow = try #require(store.flow(recorder.id))
    #expect(flow.clientIP == "10.0.0.2")
    #expect(flow.remoteIP == "93.184.216.34")
    #expect(flow.transport.downstreamTLSVersion == "TLS 1.3")  // nil in the info: left as it was
    #expect(flow.transport.upstreamTLSVersion == "TLS 1.2")
    #expect(flow.upstreamCertificate == certificate)

    recorder.setConnectionInfo(FlowConnectionInfo(downstreamTLSVersion: "TLS 1.2"))
    flow = try #require(store.flow(recorder.id))
    #expect(flow.clientIP == "10.0.0.2")
    #expect(flow.remoteIP == "93.184.216.34")
    #expect(flow.transport.downstreamTLSVersion == "TLS 1.2")
    #expect(flow.transport.upstreamTLSVersion == "TLS 1.2")
    #expect(flow.upstreamCertificate == certificate)
}

@Test(.productionChinese) func setConnectionInfoIsOneStoreUpdate() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FlowStore(bodyDirectory: directory)
    let recorder = FlowRecorder(
        store: store, scheme: "https", method: "GET", host: "example.com", port: 443, path: "/",
        requestHeaders: HTTPHeaders(), client: nil, eventLoop: EmbeddedEventLoop())
    // Drain the begin publication; one call must then reach subscribers as one flow carrying every field.
    var changes = store.changes().makeAsyncIterator()
    _ = await changes.next()
    recorder.setConnectionInfo(FlowConnectionInfo(
        clientIP: "10.0.0.2", remoteIP: "1.1.1.1", downstreamTLSVersion: "TLS 1.3", upstreamTLSVersion: "TLS 1.2"))
    let change = try #require(await changes.next())
    #expect(change.upserted.map(\.id) == [recorder.id])
    let published = try #require(change.upserted.first)
    #expect(published.clientIP == "10.0.0.2")
    #expect(published.remoteIP == "1.1.1.1")
    #expect(published.transport.downstreamTLSVersion == "TLS 1.3")
    #expect(published.transport.upstreamTLSVersion == "TLS 1.2")
}

@Test(.productionChinese) func tlsVersionTextNamesEachVersion() {
    #expect(TLSVersionText.text(for: .tlsv1) == "TLS 1.0")
    #expect(TLSVersionText.text(for: .tlsv11) == "TLS 1.1")
    #expect(TLSVersionText.text(for: .tlsv12) == "TLS 1.2")
    #expect(TLSVersionText.text(for: .tlsv13) == "TLS 1.3")
}

// MARK: completion hook (Rules 2.0 R3, P3)

private let completionMark = FlowMark(background: "#FF0000", source: .manual)!

extension FlowRecorderTests {
    private func hooked(
        _ body: (FlowRecorder, FlowStore, OSAllocatedUnfairLock<[FlowCompletionInput]>, OSAllocatedUnfairLock<[Flow?]>) throws -> Void
    ) throws {
        try withTransportRecorder { recorder, store in
            let inputs = OSAllocatedUnfairLock(initialState: [FlowCompletionInput]())
            let seen = OSAllocatedUnfairLock(initialState: [Flow?]())
            let id = recorder.id
            recorder.completionHook = { input in
                inputs.withLock { $0.append(input) }
                seen.withLock { $0.append(store.flow(id)) }
                return FlowCompletionOutput(annotations: [.mark(completionMark), .comment(CommentAction(mode: .set, text: "p3"))],
                                            provenance: nil)
            }
            try body(recorder, store, inputs, seen)
        }
    }

    @Test func completionHookRunsOnceBeforeTheFinalCommit() throws {
        try hooked { recorder, store, inputs, seen in
            recorder.complete()
            #expect(inputs.withLock { $0.count } == 1)
            let before = try #require(seen.withLock { $0 }.first ?? nil)
            #expect(before.state == .inProgress && before.ruleMark == nil)
            let after = try #require(store.flow(recorder.id))
            #expect(after.state == .completed)
            #expect(after.ruleMark == completionMark)
            #expect(after.comment == "p3")
        }
    }

    @Test func hookReceivesStateDurationAndWireBytes() throws {
        try hooked { recorder, _, inputs, _ in
            recorder.recordResponseHead(HTTPResponseHead(version: .http1_1, status: .ok))
            recorder.recordResponseBody(ByteBuffer(repeating: 1, count: 7))
            recorder.complete()
            let input = try #require(inputs.withLock { $0.first })
            #expect(input.state == .completed && input.responseWireBytes == 7 && input.durationMilliseconds >= 0)
        }
        try hooked { recorder, _, inputs, _ in
            recorder.fail("boom")
            let input = try #require(inputs.withLock { $0.first })
            #expect(input.state == .failed && input.responseWireBytes == nil)
        }
    }

    @Test func hookAnnotationsLandInTheSameUpdateAsTheState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FlowStore(bodyDirectory: directory)
        let recorder = FlowRecorder(store: store, scheme: "http", method: "GET", host: "example.com", port: 80, path: "/",
                                    requestHeaders: HTTPHeaders(), client: nil, eventLoop: EmbeddedEventLoop())
        recorder.completionHook = { _ in FlowCompletionOutput(annotations: [.mark(completionMark)], provenance: nil) }
        var changes = store.changes().makeAsyncIterator()
        _ = await changes.next()
        recorder.complete()
        let change = try #require(await changes.next())
        let flow = try #require(change.upserted.first)
        #expect(flow.state == .completed)
        #expect(flow.ruleMark == completionMark, "the first terminal change already carries the mark")
    }

    @Test func hookProvenanceIsRecordedWithTheState() throws {
        try withTransportRecorder { recorder, store in
            let matches = RuleMatchSummary(revision: 4, ruleIDs: [UUID()], total: 1)
            recorder.completionHook = { _ in
                FlowCompletionOutput(annotations: [], provenance: FlowProvenance(ruleMatches: matches))
            }
            recorder.complete()
            #expect(store.flow(recorder.id)?.provenance.ruleMatches == matches)
        }
    }

    @Test func hookProvenanceKeepsTheRecordersOwnFields() throws {
        try withTransportRecorder { recorder, store in
            let asset = UUID()
            _ = recorder.beginGeneratedResponse(status: .ok, headers: HTTPHeaders(), assetID: asset, representationLength: 5)
            recorder.mergeTools { $0.noCaching = true; $0.networkCondition = "slow" }
            recorder.completionHook = { _ in
                FlowCompletionOutput(annotations: [], provenance: FlowProvenance(
                    ruleMatches: RuleMatchSummary(revision: 1, ruleIDs: [UUID()], total: 1), rulesModified: true))
            }
            recorder.complete()
            let provenance = try #require(store.flow(recorder.id)?.provenance)
            #expect(provenance.generatedResponse?.assetID == asset)
            #expect(provenance.tools.noCaching && provenance.tools.networkCondition == "slow")
            #expect(provenance.rulesModified && provenance.ruleMatches != nil)
        }
    }

    @Test func hookIsNotCalledTwiceOnLateFail() throws {
        try hooked { recorder, store, inputs, _ in
            recorder.complete()
            recorder.fail("late")
            #expect(inputs.withLock { $0.count } == 1)
            #expect(store.flow(recorder.id)?.state == .completed)
        }
    }

    @Test func noHookNoChange() throws {
        try withTransportRecorder { recorder, store in
            recorder.complete()
            let flow = try #require(store.flow(recorder.id))
            #expect(flow.ruleMark == nil && flow.comment == nil && !flow.isHidden && flow.provenance == .passive)
        }
    }
}

// MARK: TunnelRecorder and the CONNECT point (R4 T11)

@Test(.productionChinese) func tunnelRecorderAppliesAnnotationsAndProvenance() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tunnel-rules-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FlowStore(bodyDirectory: directory)
    let ruleID = UUID()
    let mark = try #require(MarkAction(background: "#FF0000").flowMark(ruleID: ruleID, ruleName: "plain"))
    let matches = RuleMatchSummary(revision: 3, ruleIDs: [ruleID], total: 1,
                                   outcomes: [RuleOutcome(ruleID: ruleID, code: .applied)])
    let recorder = TunnelRecorder(store: store, host: "example.com", port: 443, client: nil, eventLoop: EmbeddedEventLoop(),
                                  holdPublication: true)
    let id = try #require(store.allFlows().first?.id)
    recorder.apply(annotations: [.mark(mark), .comment(CommentAction(mode: .set, text: "tunnelled")), .hide],
                   provenance: FlowProvenance(ruleMatches: matches))
    let flow = try #require(store.flow(id))
    #expect(flow.ruleMark == mark)
    #expect(flow.comment == "tunnelled")
    #expect(flow.isHidden)
    #expect(flow.provenance.ruleMatches == matches)
    #expect(flow.state == .tunnel)
    #expect(flow.method == "CONNECT")

    // A failed CONNECT row takes them in the same record.
    let failed = TunnelRecorder.recordFailure(store: store, host: "example.com", port: 443, client: nil, reason: "closed",
                                              note: nil, provenance: FlowProvenance(ruleMatches: matches),
                                              annotations: [.mark(mark), .hide])
    let failedFlow = try #require(store.flow(failed))
    #expect(failedFlow.ruleMark == mark && failedFlow.isHidden)
    #expect(failedFlow.state == .failed("closed"))
    #expect(failedFlow.provenance.ruleMatches == matches)
}

@Test(.productionChinese) func tunnelRecorderApplyAfterCloseIsHarmless() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tunnel-rules-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FlowStore(bodyDirectory: directory)
    let loop = EmbeddedEventLoop()
    let recorder = TunnelRecorder(store: store, host: "example.com", port: 443, client: nil, eventLoop: loop)
    let id = try #require(store.allFlows().first?.id)
    recorder.addSent(7)
    recorder.addReceived(70)
    recorder.close()
    let closed = try #require(store.flow(id))
    recorder.apply(annotations: [.hide], provenance: FlowProvenance())
    loop.advanceTime(by: .seconds(1))
    let flow = try #require(store.flow(id))
    #expect(flow.state == .tunnel)
    #expect(flow.completedAt == closed.completedAt)
    #expect(flow.bytesSent == 7 && flow.bytesReceived == 70)
    #expect(flow.isHidden)
}

/// A tunnel row the CONNECT point's rules hid is never announced before the hide is on it.
@Test(.productionChinese) func heldTunnelRowIsAnnouncedWithItsAnnotations() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tunnel-rules-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FlowStore(bodyDirectory: directory)
    let announced = AnnouncedFlows(store)
    let held = TunnelRecorder(store: store, host: "held.example", port: 443, client: nil, eventLoop: EmbeddedEventLoop(),
                              holdPublication: true)
    _ = TunnelRecorder(store: store, host: "fence.example", port: 443, client: nil, eventLoop: EmbeddedEventLoop())
    let heldID = try #require(store.allFlows().first { $0.host == "held.example" }?.id)
    let fenceID = try #require(store.allFlows().first { $0.host == "fence.example" }?.id)
    try await waitUntil("the fence is announced") { announced.contains(fenceID) }
    #expect(!announced.contains(heldID))
    held.apply(annotations: [.hide], provenance: FlowProvenance())
    try await waitUntil("the held row is announced") { announced.contains(heldID) }
    #expect(store.flow(heldID)?.isHidden == true)
}

@Test(.productionChinese, arguments: [false, true])
func finishingWhilePausedClearsThePauseFlagInTheSameCommit(failure: Bool) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FlowStore(bodyDirectory: directory)
    let recorder = FlowRecorder(
        store: store, scheme: "http", method: "GET", host: "example.com", port: 80, path: "/",
        requestHeaders: HTTPHeaders(), client: nil, eventLoop: EmbeddedEventLoop())
    let id = recorder.id
    recorder.setPausedAtBreakpoint(true)
    #expect(store.flow(id)?.isPausedAtBreakpoint == true)
    let before = store.changeStamp
    if failure { recorder.fail("boom") } else { recorder.complete() }
    let after = try #require(store.flow(id))
    #expect(after.isPausedAtBreakpoint == false)
    #expect(after.state != .inProgress)
    // One commit: no separate update just to clear the flag. (fail also closes the request side first.)
    #expect(store.changeStamp.flows - before.flows <= (failure ? 2 : 1))
}
