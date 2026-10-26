import FlowStore
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOConcurrencyHelpers
import Testing
@testable import ProxyCore
@testable import RulesEngine

@Suite(.productionChinese, .serialized) struct BreakpointBodyTests {
    // Removing full-body admission must fail before any transport acquisition.
    @Test func fullBodyAdmissionReservesBeforeOriginAcquisition() async throws {
        try await withConnectionFixture { f in
            let limits = RulesLimits()
            f.environment.bodyRuntime = BreakpointBodyRuntime(budgets: OwnedFileBudgets(limits: limits), limits: limits)
            let b = BreakpointCoordinator(clock: EmbeddedBreakpointClock(now: f.loop.now))
            var rule = TestRules.breakpoint(.request)
            rule.action = .breakpoint(direction: .request, mode: .fullBody)
            let c = f.context(rules: TestRules.provider([rule]), breakpoints: b)
            let w = RecordingResponseWriter(channel: f.client)
            let x = f.admit("/body", method: .POST, headers: .init([("Content-Length", "204800")]), writer: w, context: c)
            defer { x.cancel(reason: "test cleanup") }
            x.execute()
            #expect(x.localFailure == nil)
            #expect(b.snapshot().count == 1)
            #expect(f.connections.isEmpty)
            #expect(w.heads.isEmpty)
        }
    }
}

private func fullBodyRule(_ direction: HTTPMessageDirection) -> Rule {
    var rule = TestRules.breakpoint(direction)
    rule.action = .breakpoint(direction: direction, mode: .fullBody)
    return rule
}
private func bodyTicket(_ b: BreakpointCoordinator, on loop: EventLoop,
                        state: BreakpointTicketState = .pausedBody, unavailable: Bool = false) async throws -> BreakpointTicket {
    let promise = loop.makePromise(of: BreakpointTicket.self)
    let watcher = Task {
        for await _ in b.changes() {
            if let ticket = b.snapshot().first(where: { $0.state == state && (!unavailable || $0.bodyUnavailable != nil) }) { promise.succeed(ticket); return }
        }
    }
    defer { watcher.cancel() }
    return try await promise.futureResult.boundedGet()
}

extension BreakpointBodyTests {
    @Test func requestFullBodyCollectedBeforePause() async throws {
        let payload = String(repeating: "q", count: 204_800)
        try await requestRoundTrip(payload: payload, replacement: nil, chunked: false, upstreamH2: false, downstreamH2: false)
    }
    @Test(arguments: [false, true], [false, true])
    func requestBodyReplaceSendsNewLengthOnce(upstreamH2: Bool, downstreamH2: Bool) async throws {
        try await requestRoundTrip(payload: "original", replacement: Data("hello".utf8), chunked: !downstreamH2,
                                   upstreamH2: upstreamH2, downstreamH2: downstreamH2)
    }
    @Test func chunkedRequestUnchangedKeepsChunkedAndTrailers() async throws {
        try await requestRoundTrip(payload: "original", replacement: nil, chunked: true, upstreamH2: false, downstreamH2: false)
    }
    @Test func chunkedRequestEditedBecomesContentLengthTrailersDropped() async throws {
        try await requestRoundTrip(payload: "original", replacement: Data("hello".utf8), chunked: true, upstreamH2: false, downstreamH2: false)
    }
    private func requestRoundTrip(payload: String, replacement: Data?, chunked: Bool, upstreamH2: Bool, downstreamH2: Bool, withTrailers: Bool = false) async throws {
        let b = BreakpointCoordinator()
        try await HTTP2TestOrigin.withOrigin(protocols: upstreamH2 ? ["h2"] : ["http/1.1"]) { origin in
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: downstreamH2,
                rules: TestRules.provider([fullBodyRule(.request)]), breakpoints: b) { f, client in
                var fields = HTTPHeaders([("host", "localhost:\(origin.port)")])
                if chunked { fields.add(name: "transfer-encoding", value: "chunked"); fields.add(name: "trailer", value: "x-finish") }
                else { fields.add(name: "content-length", value: String(payload.utf8.count)) }
                let headers = fields
                let task = Task { try await client.request(headers: headers, path: "/body", method: .POST, body: payload,
                    trailers: (chunked || withTrailers) ? HTTPHeaders([("x-finish", "yes")]) : nil) }
                let ticket = try await bodyTicket(b, on: f.channel.eventLoop)
                #expect(ticket.bodyLength == Int64(payload.utf8.count))
                #expect(origin.counts.connections == 0)
                #expect(f.upstreams.withLock { $0.isEmpty })
                let preview = try await b.bodyPreview(token: ticket.token, offset: 0, maxBytes: 1_000_000)
                #expect(preview == Data(payload.utf8.prefix(65_536)))
                let originalFlow = try #require(f.store.allFlows().first { $0.path == "/body" })
                #expect(originalFlow.bytesSent == payload.utf8.count)
                #expect(originalFlow.messages[.upstreamRequest] == nil)
                let bodyEdit: BreakpointBodyEdit = replacement.map { .replace($0) } ?? .unchanged
                #expect(await b.perform(.continue(token: ticket.token, edit: .init(head: ticket.effectiveHead, body: bodyEdit))) == .accepted)
                let response = try await task.value
                #expect(response.status == 200)
                let counts = origin.counts
                #expect(counts.requests == 1 && counts.bodies["/body"] == (replacement.map { String(decoding: $0, as: UTF8.self) } ?? payload))
                let sent = try #require(counts.requestHeaders.first)
                if replacement != nil {
                    #expect(sent.first(name: "content-length") == String(replacement!.count))
                    #expect(!sent.contains(name: "transfer-encoding"))
                    #expect(counts.originalTrailers.allSatisfy { $0.isEmpty })
                } else if chunked || withTrailers {
                    #expect(sent.first(name: "transfer-encoding") == "chunked")
                    #expect(counts.originalTrailers.first?.first(name: "x-finish") == "yes")
                }
                let flow = try await waitForFlow(f.store) { $0.path == "/body" && $0.state == .completed }
                #expect(try flow.messages[.downstreamRequest]?.body?.load() == Data(payload.utf8))
                if replacement != nil {
                    #expect(try flow.messages[.upstreamRequest]?.body?.load() == replacement)
                }
                #expect(b.snapshot().isEmpty)
                #expect((flow.messages[.downstreamRequest]?.body?.ref == flow.messages[.upstreamRequest]?.body?.ref) == (replacement == nil || replacement == Data(payload.utf8)))
            }
        }
    }

    @Test(arguments: [false, true]) func responseFullBodyEditToH2ClientHasEndStream(upstreamH2: Bool) async throws {
        try await responseRoundTrip(upstreamH2: upstreamH2, downstreamH2: true, replacement: Data("hello".utf8))
    }
    @Test func gzipResponseUnchangedSendsOriginalBytes() async throws {
        try await responseRoundTrip(upstreamH2: false, downstreamH2: false, gzip: true)
    }
    @Test func gzipResponseEditedSendsIdentity() async throws {
        try await responseRoundTrip(upstreamH2: true, downstreamH2: false, replacement: Data("hello".utf8), gzip: true)
    }
    @Test func headResponseIgnoresEditedBody() async throws {
        try await responseRoundTrip(upstreamH2: false, downstreamH2: false, replacement: Data("hello".utf8), method: .HEAD)
    }
    private func responseRoundTrip(upstreamH2: Bool, downstreamH2: Bool, replacement: Data? = nil,
                                   gzip: Bool = false, method: HTTPMethod = .GET) async throws {
        let b = BreakpointCoordinator()
        let raw: [UInt8] = gzip ? [31,139,8,0,0,0,0,0,0,3,203,72,205,201,201,7,0,134,166,16,54,5,0,0,0] : Array("original".utf8)
        var response = HTTP2TestOrigin.Response()
        response.rawBody = raw
        if gzip { response.headers.add(name: "content-encoding", value: "gzip") }
        if method == .HEAD { response.headers.add(name: "content-length", value: "123") }
        try await HTTP2TestOrigin.withOrigin(protocols: upstreamH2 ? ["h2"] : ["http/1.1"], response: response) { origin in
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: downstreamH2,
                rules: TestRules.provider([fullBodyRule(.response)]), breakpoints: b) { f, client in
                let task = Task { try await client.request(headers: .init([("host", "localhost:\(origin.port)")]), path: "/response-body", method: method) }
                let ticket: BreakpointTicket
                do { ticket = try await bodyTicket(b, on: f.channel.eventLoop) }
                catch { throw WaitTimeout(description: "response collect: \(error); tickets=\(b.snapshot()); origin=\(origin.counts); flows=\(f.store.allFlows())") }
                #expect(ticket.bodyLength == (method == .HEAD ? 0 : Int64(raw.count)))
                let bytes = try await b.bodyPreview(token: ticket.token, offset: 0, maxBytes: 65_536)
                #expect(Array(bytes) == (method == .HEAD ? [] : raw))
                #expect(await b.perform(.continue(token: ticket.token, edit: .init(head: ticket.effectiveHead,
                    body: replacement.map { .replace($0) } ?? .unchanged,
                    bodyEncodingChoice: replacement == nil ? .unchanged : .removeEncoding))) == .accepted)
                let result: HTTP2TestClient.Response
                do { result = try await task.value }
                catch { throw WaitTimeout(description: "response continue: \(error); tickets=\(b.snapshot()); origin=\(origin.counts); flows=\(f.store.allFlows())") }
                #expect(result.bytes == (method == .HEAD ? [] : replacement.map(Array.init) ?? raw))
                if method != .HEAD, replacement == nil { #expect(result.trailers?.first(name: "x-finish") == "done") }
                if gzip { #expect(result.headers.first(name: "content-encoding") == (replacement == nil ? "gzip" : nil)) }
                if method == .HEAD { #expect(result.headers.first(name: "content-length") == "123") }
                if downstreamH2 { #expect(!result.headers.contains(name: "transfer-encoding")); #expect(result.status == 200) }
                let flow = try await waitForFlow(f.store) { $0.path == "/response-body" && $0.state == .completed }
                #expect(flow.messages[.downstreamResponse]?.transferState == .finished)
                #expect(flow.bytesReceived == (method == .HEAD ? 0 : raw.count))
                if method != .HEAD {
                    #expect(try flow.messages[.upstreamResponse]?.body?.load() == Data(raw))
                    #expect(try flow.messages[.downstreamResponse]?.body?.load() == (replacement ?? Data(raw)))
                    #expect((flow.messages[.upstreamResponse]?.body?.ref == flow.messages[.downstreamResponse]?.body?.ref) == (replacement == nil || replacement == Data(raw)))
                }
                #expect(b.snapshot().isEmpty)
            }
        }
    }
}

extension BreakpointBodyTests {
    @Test func bodyOver50MiBGives413ForRequestAnd502ForResponse() async throws {
        for direction in [HTTPMessageDirection.request, .response] {
            var limits = RulesLimits(); limits.breakpointBodyBytes = 1_048_576
            let b = BreakpointCoordinator(limits: limits)
            var response = HTTP2TestOrigin.Response(); response.body = String(repeating: "z", count: 1_048_577)
            try await HTTP2TestOrigin.withOrigin(protocols: ["http/1.1"], response: response) { origin in
                try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: false,
                    rules: TestRules.provider([fullBodyRule(direction)]), breakpoints: b) { f, client in
                    let result = try await client.request(headers: .init([("host", "localhost:\(origin.port)"), ("transfer-encoding", "chunked")]),
                        path: "/overflow", method: .POST, body: direction == .request ? String(repeating: "x", count: 1_048_577) : "")
                    #expect(result.status == (direction == .request ? 413 : 502))
                    #expect(result.body.contains("断点正文超出了收集上限"))
                    if direction == .request { #expect(origin.counts.connections == 0) }
                    #expect(b.snapshot().isEmpty)
                    await f.bodyRuntime.drain()
                    #expect(f.bodyRuntime.activePins == 0)
                    #expect(f.bodyRuntime.budgets.snapshot().reservedBytes == 0)
                    #expect(((try? FileManager.default.contentsOfDirectory(atPath: f.bodyRuntime.directory.path)) ?? []).isEmpty)
                }
            }
        }
    }
    @Test func spillToDiskAboveOneMiBAndCleanup() async throws {
        try await requestRoundTrip(payload: String(repeating: "s", count: 2_097_152), replacement: nil,
                                   chunked: false, upstreamH2: false, downstreamH2: false)
        for timeout in [false, true] {
            let h = BodyGateHarness()
            do {
                let gate = try await h.gate(expected: 2_097_152)
                for _ in 0..<32 { try await h.loop.flatSubmit { gate.value.append(ByteBuffer(repeating: 83, count: 65_536)) }.get() }
                #expect(h.files.count == 1)
                #expect(h.budgets.snapshot().bytes[.breakpoint] == 2_097_152)
                if timeout { h.clock.advance(by: .seconds(120)) }
                let t = try #require(h.coordinator.snapshot().first)
                let result = await h.coordinator.perform(.cancel(token: t.token))
                #expect(result == (timeout ? .expired : .accepted))
                try await h.loop.submit {}.get()
                await h.runtime.drain()
                #expect(h.runtime.activePins == 0 && h.budgets.snapshot().reservedBytes == 0)
                #expect(h.files.isEmpty)
                #expect(h.coordinator.snapshot().isEmpty)
                try await h.close()
            } catch { h.coordinator.shutdown(); try? await h.close(); throw error }
        }
    }
    @Test func timeoutDuringCollectionCountsFromMatch() async throws {
        let h = BodyGateHarness()
        do {
            let gate = try await h.gate(expected: 100)
            let t = try #require(h.coordinator.snapshot().first)
            h.clock.advance(by: .seconds(119))
            try await h.loop.flatSubmit { gate.value.append(ByteBuffer(string: "partial")) }.get()
            #expect(h.coordinator.snapshot().first?.deadline == t.deadline)
            #expect(h.coordinator.snapshot().first?.state == .collectingBody)
            h.clock.advance(by: .seconds(1))
            #expect(await h.coordinator.perform(.cancel(token: t.token)) == .expired)
            try await h.loop.submit {}.get()
            #expect(h.failures.withLockedValue { $0 } == [.expired])
            #expect(try await h.loop.submit { gate.value.timerCount }.get() == 0)
            await h.runtime.drain()
            #expect(h.budgets.snapshot().reservedBytes == 0)
            try await h.close()
        } catch { h.coordinator.shutdown(); try? await h.close(); throw error }
    }
}

private final class BodyGateHarness: Sendable {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let pool = NIOThreadPool(numberOfThreads: 2)
    let runtime: BreakpointBodyRuntime
    let budgets: OwnedFileBudgets
    let io: BodyFileIO
    let clock: EmbeddedBreakpointClock
    let coordinator: BreakpointCoordinator
    let failures = NIOLockedValueBox<[BreakpointEndReason]>([])
    let continued = NIOLockedValueBox<ExactBodySource?>(nil)
    let changedBody = NIOLockedValueBox<Bool?>(nil)
    let bodyErrors = NIOLockedValueBox(0)
    let resumed = NIOLockedValueBox(0)
    let cancelRegistered = NIOLockedValueBox(false)
    let publishedAfterCancel = NIOLockedValueBox(0)
    var loop: EventLoop { io.eventLoop }
    var files: [String] { (try? FileManager.default.contentsOfDirectory(atPath: runtime.directory.path)) ?? [] }
    init(limits: RulesLimits = .init(), hooks: BodyFileIOHooks = .init(), freeDiskBytes: (@Sendable (URL) -> Int64?)? = nil) {
        pool.start()
        budgets = freeDiskBytes.map { OwnedFileBudgets(limits: limits, freeDiskBytes: $0) } ?? OwnedFileBudgets(limits: limits)
        runtime = BreakpointBodyRuntime(budgets: budgets, limits: limits, hooks: hooks)
        io = runtime.makeIO(eventLoop: group.next(), pool: pool)
        clock = EmbeddedBreakpointClock(now: .now())
        coordinator = BreakpointCoordinator(clock: clock, limits: limits)
    }
    func gate(expected: Int64?, mode: BreakpointPauseMode = .fullBody, flowID: Int? = nil, beforeBodyCallback: (@Sendable (ExchangeBreakpointGate.BodyCallback) -> Void)? = nil) async throws -> NIOLoopBound<ExchangeBreakpointGate> {
        try await loop.submit { [self] in
            let fields = expected.map { [HeaderField(name: "Content-Length", value: String($0))] }
                ?? [HeaderField(name: "Transfer-Encoding", value: "chunked")]
            let head = HTTPMessageHead.request(.init(scheme: "http", host: "example.test", port: 80, method: "POST", pathAndQuery: "/"), headers: fields)
            let ticket = BreakpointTicket(token: .init(ticketID: .init(), generation: 0, revision: 1), contextID: UUID(), flowID: flowID,
                direction: .request, originalHead: head, effectiveHead: head, routeKind: .network, source: .passive, mode: mode,
                state: .pausedHeaders, matchedAt: clock.now, deadline: clock.now + .seconds(120), matches: .init(revision: 1, ruleIDs: [], total: 0))
            let gate = ExchangeBreakpointGate(loop: loop, coordinator: coordinator, io: io,
                beforeBodyCallback: beforeBodyCallback,
                changed: { if self.cancelRegistered.withLockedValue({ $0 }), self.coordinator.snapshot().contains(where: { $0.state == .pausedBody }) { self.publishedAfterCancel.withLockedValue { $0 += 1 } } },
                bodyFailure: { _ in self.bodyErrors.withLockedValue { $0 += 1 }; self.coordinator.shutdown() }, continueBody: { body in self.continued.withLockedValue { $0 = body.source }; self.changedBody.withLockedValue { $0 = body.bytesChanged } },
                resume: { _ in self.resumed.withLockedValue { $0 += 1 } }, fail: { reason in self.failures.withLockedValue { $0.append(reason) } })
            try gate.pause(ticket: ticket, continuation: .network(head: head, body: nil))
            return NIOLoopBound(gate, eventLoop: loop)
        }.get()
    }
    func close() async throws {
        coordinator.shutdown()
        continued.withLockedValue { $0?.cancel(); $0 = nil }
        try await loop.submit {}.get()
        await runtime.drain()
        try await pool.shutdownGracefully(); try await group.shutdownGracefully()
        try? FileManager.default.removeItem(at: runtime.directory)
    }
}

extension BreakpointBodyTests {
    @Test(arguments: [false, true]) func importedReplacementIsRevokedWithTicketEvenWhenCallerRetainsIt(expired: Bool) async throws {
        let h = BodyGateHarness()
        let external = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("external".utf8).write(to: external)
        defer { try? FileManager.default.removeItem(at: external) }
        do {
            let gate = try await h.gate(expected: 0)
            try await h.loop.submit { gate.value.finishBody(trailers: []) }.get()
            let ticket = try await bodyTicket(h.coordinator, on: h.loop)
            let imported = try await h.coordinator.replaceBodyFromFile(token: ticket.token, url: external)
            if expired { h.clock.advance(by: .seconds(120)) }
            #expect(await h.coordinator.perform(.cancel(token: ticket.token)) == (expired ? .expired : .accepted))
            await #expect(throws: OwnedFileError(.cancelled)) { _ = try await imported.read(offset: 0, maxBytes: 8) }
            imported.cancel() // always release on RED so the regression cannot hang cleanup
            await h.runtime.drain()
            #expect(h.files.isEmpty && h.budgets.snapshot().reservedBytes == 0)
            #expect(try Data(contentsOf: external) == Data("external".utf8))
            try await h.close()
        } catch { h.coordinator.shutdown(); try? await h.close(); throw error }
    }
    @Test func knownOversizeStaysPausedHeadersAndPreservesDeadline() async throws {
        var limits = RulesLimits(); limits.breakpointBodyBytes = 10
        let h = BodyGateHarness(limits: limits)
        do {
            let gate = try await h.gate(expected: 11)
            let t = try #require(h.coordinator.snapshot().first)
            #expect(t.state == .pausedHeaders && t.bodyUnavailable == .knownLengthTooLarge)
            #expect(h.budgets.snapshot().reservedBytes == 0 && h.files.isEmpty)
            #expect(await h.coordinator.perform(.collectBody(token: t.token)) == .unsupported)
            #expect(h.coordinator.snapshot().first?.deadline == t.deadline)
            #expect(await h.coordinator.perform(.continue(token: t.token, edit: .init(head: t.effectiveHead))) == .accepted)
            #expect(try await h.loop.submit { gate.value.timerCount }.get() == 0)
            try await h.close()
        } catch { h.coordinator.shutdown(); try? await h.close(); throw error }
    }
    @Test func eightMiBEditorReplacementAndFileReplacementAreExact() async throws {
        for fromFile in [false, true] {
            let h = BodyGateHarness()
            let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let data = Data(repeating: 65, count: fromFile ? 8_388_609 : 8_388_608)
            if fromFile { try data.write(to: path) }
            defer { try? FileManager.default.removeItem(at: path) }
            do {
                let gate = try await h.gate(expected: 0)
                try await h.loop.submit { gate.value.finishBody(trailers: []) }.get()
                let t = try await bodyTicket(h.coordinator, on: h.loop)
                let body: BreakpointBodyEdit
                if fromFile { body = .replaceSource(try await h.coordinator.replaceBodyFromFile(token: t.token, url: path)) }
                else { body = .replace(data) }
                #expect(await h.coordinator.perform(.continue(token: t.token, edit: .init(head: t.effectiveHead, body: body))) == .accepted)
                // Acceptance claims the ticket before the owner-loop continuation is published.
                try await h.loop.submit {}.get()
                let source = try #require(h.continued.withLockedValue { $0 })
                #expect(source.size == Int64(data.count))
                #expect(try await source.read(offset: source.size - 1, maxBytes: 65_536) == Data([65]))
                source.cancel()
                await h.runtime.drain()
                #expect(h.budgets.snapshot().reservedBytes == 0 && h.files.isEmpty)
                try await h.close()
            } catch { h.coordinator.shutdown(); try? await h.close(); throw error }
        }
    }
    @Test func queuedEditorValuesShareQuotaUntilTheirDeliveryReleasesThem() async throws {
        var limits = RulesLimits(); limits.editorMemoryBytes = 10; limits.editorBodyBytes = 8
        let h = BodyGateHarness(limits: limits)
        do {
            let first = try await h.gate(expected: 0), second = try await h.gate(expected: 0)
            try await h.loop.submit { first.value.finishBody(trailers: []); second.value.finishBody(trailers: []) }.get()
            let ready = h.loop.makePromise(of: Void.self)
            let watcher = Task {
                for await _ in h.coordinator.changes() {
                    if h.coordinator.snapshot().filter({ $0.state == .pausedBody }).count == 2 { ready.succeed(()); return }
                }
            }
            defer { watcher.cancel() }
            try await ready.futureResult.boundedGet()
            let tickets = h.coordinator.snapshot()
            let barrier = BlockingBodyWork()
            h.loop.execute { barrier.block() }
            try await barrier.waitEntered()
            let result = NIOLockedValueBox<BreakpointCommandResult?>(nil)
            h.coordinator.perform(.continue(token: tickets[0].token, edit: .init(head: tickets[0].effectiveHead, body: .replace(Data(repeating: 1, count: 8))))) { r in result.withLockedValue { $0 = r } }
            #expect(h.budgets.snapshot().bytes[.editor] == 8)
            #expect(await h.coordinator.perform(.continue(token: tickets[1].token, edit: .init(head: tickets[1].effectiveHead, body: .replace(Data(repeating: 2, count: 8))))) == .invalid)
            h.coordinator.shutdown()
            #expect(h.budgets.snapshot().bytes[.editor] == 8)
            #expect(h.runtime.activePins >= 1) // the queued Data pins this runtime even after the old bodies are revoked
            barrier.release.signal()
            try await h.loop.submit {}.get()
            #expect(!barrier.timedOut.withLockedValue { $0 })
            #expect(result.withLockedValue { $0 } == .invalid)
            await h.runtime.drain()
            #expect(h.budgets.snapshot().reservedBytes == 0)
            try await h.close()
        } catch { h.coordinator.shutdown(); try? await h.close(); throw error }
    }
}

private final class BlockingBodyWork: Sendable {
    private let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let timedOut = NIOLockedValueBox(false)
    func block() {
        entered.signal()
        if release.wait(timeout: .now() + 5) == .timedOut { timedOut.withLockedValue { $0 = true } }
    }
    func waitEntered() async throws {
        let result = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: self.entered.wait(timeout: .now() + 5) == .success) }
        }
        guard result else { throw WaitTimeout(description: "body work did not enter barrier") }
    }
}

extension BreakpointBodyTests {
    @Test func cancelledInflightWriteKeepsRuntimeAndBudgetUntilActualIOSettles() async throws {
        let barrier = BlockingBodyWork()
        let h = BodyGateHarness(hooks: .init(beforeWrite: { barrier.block() }))
        do {
            let gate = try await h.gate(expected: 4)
            let append = try await h.loop.submit { gate.value.append(ByteBuffer(string: "test")) }.get()
            try await barrier.waitEntered()
            #expect(try await h.loop.submit { !gate.value.canRead }.get())
            #expect(h.budgets.snapshot().bytes[.breakpoint] == 4)
            #expect((h.budgets.snapshot().bytes[.io] ?? 0) >= 4)
            h.coordinator.shutdown()
            try await h.loop.submit {}.get()
            #expect(h.runtime.activePins > 0)
            #expect(h.budgets.snapshot().bytes[.breakpoint] == 4)
            barrier.release.signal()
            await #expect(throws: (any Error).self) { try await append.get() }
            await h.runtime.drain()
            #expect(!barrier.timedOut.withLockedValue { $0 })
            #expect(h.runtime.activePins == 0 && h.files.isEmpty && h.budgets.snapshot().reservedBytes == 0)
            #expect(h.coordinator.snapshot().isEmpty)
            #expect(h.continued.withLockedValue { $0 } == nil)
            try await h.close()
        } catch { barrier.release.signal(); h.coordinator.shutdown(); try? await h.close(); throw error }
    }
    @Test func collectActionUsesSameTokenAndRejectsLateBodyReady() async throws {
        let h = BodyGateHarness()
        do {
            let gate = try await h.gate(expected: 4, mode: .headers)
            let t = try #require(h.coordinator.snapshot().first)
            #expect(await h.coordinator.perform(.collectBody(token: t.token)) == .accepted)
            #expect(h.coordinator.snapshot().first?.token == t.token)
            try await h.loop.flatSubmit { gate.value.append(ByteBuffer(string: "test")) }.get()
            h.coordinator.shutdown()
            try await h.loop.submit { gate.value.finishBody(trailers: []) }.get()
            await h.runtime.drain()
            #expect(h.coordinator.snapshot().isEmpty && h.continued.withLockedValue { $0 } == nil)
            #expect(h.budgets.snapshot().reservedBytes == 0)
            try await h.close()
        } catch { h.coordinator.shutdown(); try? await h.close(); throw error }
    }
    @Test func unsupportedFullBodyExpectFailsBeforeCollectionAndBeforeOrigin() async throws {
        try await withConnectionFixture { f in
            let limits = RulesLimits()
            let runtime = BreakpointBodyRuntime(budgets: OwnedFileBudgets(limits: limits), limits: limits)
            f.environment.bodyRuntime = runtime
            let b = BreakpointCoordinator()
            let c = f.context(rules: TestRules.provider([fullBodyRule(.request)]), breakpoints: b)
            let w = RecordingResponseWriter(channel: f.client)
            let x = f.admit("/expect", method: .POST, headers: .init([("expect", "fancy-expectation"), ("content-length", "4")]), writer: w, context: c)
            x.execute(); x.receiveRequest(.end(nil))
            #expect(x.localFailure == .ruleActionUnsupported && f.connections.isEmpty)
            #expect(w.heads.map(\.status.code) == [502])
            #expect(b.snapshot().isEmpty && runtime.activePins == 0 && runtime.budgets.snapshot().reservedBytes == 0)
        }
    }
}

private final class DeferredBodyWriter: DownstreamResponseWriter {
    let eventLoop: EventLoop
    let version: HTTPWireVersion = .http2
    let isWritable = true
    let isActive = true
    let bodySubmitted: EventLoopPromise<Void>
    var pending: EventLoopPromise<Void>?
    var bodyFlushes = 0
    init(loop: EventLoop) { eventLoop = loop; bodySubmitted = loop.makePromise() }
    func write(_ part: HTTPServerResponsePart) -> EventLoopFuture<Void> {
        if case .body = part {
            let promise = eventLoop.makePromise(of: Void.self)
            pending = promise; bodySubmitted.succeed(())
            return promise.futureResult
        }
        return eventLoop.makeSucceededVoidFuture()
    }
    func flush() { if pending != nil { bodyFlushes += 1 } }
    func setRequestReading(_ enabled: Bool) {}
    func responseFinished() {}
    func abort(_ error: Error) {}
    func release() { pending?.succeed(()); pending = nil }
}

extension BreakpointBodyTests {
    @Test func asynchronousResponseBodyFlushesOutsideOriginalReadBatch() async throws {
        let b = BreakpointCoordinator()
        try await HTTP2TestOrigin.withOrigin(protocols: ["http/1.1"]) { origin in
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true,
                rules: TestRules.provider([fullBodyRule(.response)]), breakpoints: b) { f, _ in
                let context = try #require(f.connections.withLock { $0.first })
                let bound = try await context.eventLoop.submit {
                    let writer = DeferredBodyWriter(loop: context.eventLoop)
                    let x = HTTPExchange(requestHead: .init(version: .http1_1, method: .GET, uri: "/deferred"),
                        target: RequestTarget(host: "localhost", port: origin.port, originForm: "/deferred", defaultPort: 443),
                        scheme: "https", downstream: writer, connection: context.value, transport: .init())
                    x.execute(); x.receiveRequest(.end(nil))
                    return NIOLoopBound((x, writer), eventLoop: context.eventLoop)
                }.get()
                let t = try await bodyTicket(b, on: context.eventLoop)
                // Keep the old transport's read-batch flag set across a user continuation.
                // The spool's future is an independent producer and must explicitly flush.
                try await context.eventLoop.submit { bound.value.0.responseReadStarted() }.get()
                #expect(await b.perform(.continue(token: t.token, edit: .init(head: t.effectiveHead))) == .accepted)
                let pending = try await context.eventLoop.submit { bound.value.1.bodySubmitted.futureResult }.get()
                try await pending.boundedGet()
                try await context.eventLoop.submit {
                    #expect(bound.value.1.bodyFlushes > 0)
                    #expect(f.bodyRuntime.activePins == 1)
                    bound.value.1.release()
                    bound.value.0.responseReadComplete()
                }.get()
                _ = try await waitForFlow(f.store) { $0.path == "/deferred" && $0.state == .completed }
                await f.bodyRuntime.drain()
                #expect(f.bodyRuntime.activePins == 0 && f.bodyRuntime.budgets.snapshot().reservedBytes == 0)
            }
        }
    }
}

extension BreakpointBodyTests {
    @Test func cancelledWriterRetainsExactSourceUntilWriteSettles() async throws {
        let b = BreakpointCoordinator()
        let released = NIOLockedValueBox(0)
        try await HTTP2TestOrigin.withOrigin(protocols: ["http/1.1"]) { origin in
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true,
                rules: TestRules.provider([fullBodyRule(.response)]), breakpoints: b,
                bodyHooks: .init(sourceReleased: { released.withLockedValue { $0 += 1 } })) { f, _ in
                let context = try #require(f.connections.withLock { $0.first })
                let bound = try await context.eventLoop.submit {
                    let writer = DeferredBodyWriter(loop: context.eventLoop)
                    let x = HTTPExchange(requestHead: .init(version: .http1_1, method: .GET, uri: "/leased"),
                        target: RequestTarget(host: "localhost", port: origin.port, originForm: "/leased", defaultPort: 443),
                        scheme: "https", downstream: writer, connection: context.value, transport: .init())
                    x.execute(); x.receiveRequest(.end(nil))
                    return NIOLoopBound((x, writer), eventLoop: context.eventLoop)
                }.get()
                let t = try await bodyTicket(b, on: context.eventLoop)
                #expect(await b.perform(.continue(token: t.token, edit: .init(head: t.effectiveHead))) == .accepted)
                let pending = try await context.eventLoop.submit { bound.value.1.bodySubmitted.futureResult }.get()
                try await pending.boundedGet()
                try await context.eventLoop.submit { bound.value.0.cancel(reason: "synthetic cancellation") }.get()
                #expect(released.withLockedValue { $0 } == 0)
                try await context.eventLoop.submit { bound.value.1.release() }.get()
                await f.bodyRuntime.drain()
                #expect(released.withLockedValue { $0 } == 1)
                #expect(f.bodyRuntime.budgets.snapshot().reservedBytes == 0)
            }
        }
    }
    @Test func byteIdenticalReplacementReusesOriginalBodyIdentity() async throws {
        let h = BodyGateHarness()
        do {
            let gate = try await h.gate(expected: 4)
            try await h.loop.flatSubmit { gate.value.append(ByteBuffer(string: "test")) }.get()
            try await h.loop.submit { gate.value.finishBody(trailers: []) }.get()
            let t = try await bodyTicket(h.coordinator, on: h.loop)
            #expect(await h.coordinator.perform(.continue(token: t.token, edit: .init(head: t.effectiveHead, body: .replace(Data("test".utf8))))) == .accepted)
            #expect(h.changedBody.withLockedValue { $0 } == false)
            try await h.close()
        } catch { h.coordinator.shutdown(); try? await h.close(); throw error }
    }
}

extension BreakpointBodyTests {
    @Test func cancelledFinishCannotPublishLateBodyReady() async throws {
        let barrier = BlockingBodyWork()
        let h = BodyGateHarness(hooks: .init(beforeFinish: { barrier.block() }))
        do {
            let gate = try await h.gate(expected: 4)
            try await h.loop.flatSubmit { gate.value.append(ByteBuffer(string: "test")) }.get()
            try await h.loop.submit { gate.value.finishBody(trailers: []) }.get()
            try await barrier.waitEntered()
            h.coordinator.shutdown()
            try await h.loop.submit {}.get()
            #expect(h.runtime.activePins == 1 && h.budgets.snapshot().bytes[.breakpoint] == 4)
            barrier.release.signal()
            await h.runtime.drain()
            #expect(!barrier.timedOut.withLockedValue { $0 })
            #expect(h.coordinator.snapshot().isEmpty && h.continued.withLockedValue { $0 } == nil)
            #expect(h.runtime.activePins == 0 && h.files.isEmpty && h.budgets.snapshot().reservedBytes == 0)
            try await h.close()
        } catch { barrier.release.signal(); h.coordinator.shutdown(); try? await h.close(); throw error }
    }
    @Test func cancelledPreviewRetainsReadOwnershipUntilFileWorkSettles() async throws {
        let barrier = BlockingBodyWork()
        let h = BodyGateHarness(hooks: .init(beforeRead: { barrier.block() }))
        do {
            let gate = try await h.gate(expected: 4)
            try await h.loop.flatSubmit { gate.value.append(ByteBuffer(string: "test")) }.get()
            try await h.loop.submit { gate.value.finishBody(trailers: []) }.get()
            let ticket = try await bodyTicket(h.coordinator, on: h.loop)
            let read = Task { try await h.coordinator.bodyPreview(token: ticket.token, offset: 0, maxBytes: 4) }
            try await barrier.waitEntered()
            h.coordinator.shutdown()
            try await h.loop.submit {}.get()
            #expect(h.runtime.activePins == 1 && h.budgets.snapshot().bytes[.breakpoint] == 4)
            #expect(h.budgets.snapshot().bytes[.io] == 4 && h.files.count == 1)
            barrier.release.signal()
            await #expect(throws: (any Error).self) { try await read.value }
            await h.runtime.drain()
            #expect(!barrier.timedOut.withLockedValue { $0 })
            #expect(h.coordinator.snapshot().isEmpty && h.runtime.activePins == 0)
            #expect(h.files.isEmpty && h.budgets.snapshot().reservedBytes == 0)
            try await h.close()
        } catch { barrier.release.signal(); h.coordinator.shutdown(); try? await h.close(); throw error }
    }
    @Test(arguments: [HTTPMessageDirection.request, .response])
    func mapLocalBodiesUseFrozenRouteAndPreservePersistentAsset(direction: HTTPMessageDirection) async throws {
        let original = Data("local original".utf8)
        try await withLocalAsset(original) { asset in
            let b = BreakpointCoordinator()
            try await HTTP2TestOrigin.withOrigin(protocols: ["h2"]) { origin in
                try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true,
                    // R1 intentional change class 1: a rule must rank above the Return File rule to act on its exchange.
                    rules: asset.rules(higher: [fullBodyRule(direction)]), assets: asset.store, breakpoints: b) { f, client in
                    let response = Task { try await client.request(headers: .init([("host", "localhost:\(origin.port)"), ("content-length", "4")]),
                        path: "/local-body", method: .POST, body: "test") }
                    let t = try await bodyTicket(b, on: f.channel.eventLoop)
                    #expect(try await b.bodyPreview(token: t.token, offset: 0, maxBytes: 65_536) == (direction == .request ? Data("test".utf8) : original))
                    let result = await b.perform(.continue(token: t.token, edit: .init(head: t.effectiveHead, body: .replace(Data("hello".utf8)))))
                    if direction == .request {
                        #expect(result == .invalid)
                        #expect(b.snapshot().first?.token == t.token && b.snapshot().first?.deadline == t.deadline)
                        #expect(await b.perform(.continue(token: t.token, edit: .init(head: t.effectiveHead))) == .accepted)
                    } else { #expect(result == .accepted) }
                    #expect(try await response.value.bytes == Array(direction == .request ? original : Data("hello".utf8)))
                    #expect(origin.counts.connections == 0)
                    let flow = try await waitForFlow(f.store) { $0.path == "/local-body" && $0.state == .completed }
                    #expect(try flow.messages[.generatedResponse]?.body?.load() == original)
                    #expect(flow.messages[.upstreamRequest] == nil)
                    await f.bodyRuntime.drain()
                    #expect(asset.budgets.snapshot().bytes[.breakpoint, default: 0] == 0)
                    #expect(asset.budgets.snapshot().bytes[.io, default: 0] == 0)
                    #expect(asset.budgets.snapshot().bytes[.asset] == Int64(original.count))
                    #expect(f.bodyRuntime.activePins == 0 && FileManager.default.fileExists(atPath: asset.copy.path))
                }
            }
        }
    }
}

extension BreakpointBodyTests {
    @Test(arguments: ["HEAD", "204", "304"])
    func localNoPayloadResponseCollectsEmptyEntity(caseName: String) async throws {
        try await withLocalAsset(Data("representation".utf8)) { asset in
            let b = BreakpointCoordinator()
            let reads = NIOLockedValueBox(0)
            try await HTTP2TestOrigin.withOrigin(protocols: ["h2"]) { origin in
                try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true,
                    // R1 intentional change class 1: a rule must rank above the Return File rule to act on its exchange.
                    rules: asset.rules(status: Int(caseName) ?? 200, higher: [fullBodyRule(.response)]), assets: asset.store, breakpoints: b,
                    localResponseHooks: .init(beforeRead: { _, _ in reads.withLockedValue { $0 += 1 } })) { f, client in
                    let response = Task { try await client.request(headers: .init([("host", "localhost:\(origin.port)")]),
                        path: "/no-body", method: caseName == "HEAD" ? .HEAD : .GET) }
                    let t = try await bodyTicket(b, on: f.channel.eventLoop)
                    #expect(t.bodyLength == 0 && reads.withLockedValue { $0 } == 0)
                    #expect(await b.perform(.continue(token: t.token, edit: .init(head: t.effectiveHead, body: .replace(Data("ignored".utf8))))) == .accepted)
                    let result = try await response.value
                    #expect(result.bytes.isEmpty)
                    #expect(result.headers.first(name: "content-length") == (caseName == "204" ? nil : "14"))
                    #expect(origin.counts.connections == 0)
                }
            }
        }
    }
}

extension BreakpointBodyTests {
    @Test(arguments: [false, true])
    func asynchronousReplacementCannotCrossOriginalDeadline(duringComparison: Bool) async throws {
        let barrier = BlockingBodyWork(), finishes = NIOLockedValueBox(0)
        let hooks = BodyFileIOHooks(beforeFinish: {
            let n = finishes.withLockedValue { $0 += 1; return $0 }
            if n == 2 && !duringComparison { barrier.block() }
        }, beforeRead: { if duringComparison { barrier.block() } })
        let h = BodyGateHarness(hooks: hooks)
        do {
            let gate = try await h.gate(expected: 4)
            try await h.loop.flatSubmit { gate.value.append(ByteBuffer(string: "test")) }.get()
            try await h.loop.submit { gate.value.finishBody(trailers: []) }.get()
            let t = try await bodyTicket(h.coordinator, on: h.loop)
            h.clock.advance(by: .seconds(119))
            let command = Task { await h.coordinator.perform(.continue(token: t.token,
                edit: .init(head: t.effectiveHead, body: .replace(Data("test".utf8))))) }
            try await barrier.waitEntered()
            h.clock.advance(by: .seconds(2))
            barrier.release.signal()
            // A comparison reads each source; only its first read needs to be gated.
            if duringComparison { barrier.release.signal() }
            #expect(await command.value == .expired)
            h.continued.withLockedValue { $0 }?.cancel() // RED cleanup if erroneously accepted
            await h.runtime.drain()
            #expect(!barrier.timedOut.withLockedValue { $0 })
            #expect(h.continued.withLockedValue { $0 } == nil && h.failures.withLockedValue { $0 } == [.expired])
            #expect(h.coordinator.snapshot().isEmpty && h.files.isEmpty && h.budgets.snapshot().reservedBytes == 0)
            try await h.close()
        } catch { barrier.release.signal(); barrier.release.signal(); h.coordinator.shutdown(); try? await h.close(); throw error }
    }
}

extension BreakpointBodyTests {
    @Test func comparisonChargesBothRetainedChunksToSharedIOBudget() async throws {
        let barrier = BlockingBodyWork(), reads = NIOLockedValueBox(0)
        let h = BodyGateHarness(hooks: .init(beforeRead: {
            if reads.withLockedValue({ $0 += 1; return $0 }) == 2 { barrier.block() }
        }))
        do {
            let gate = try await h.gate(expected: 4)
            try await h.loop.flatSubmit { gate.value.append(ByteBuffer(string: "test")) }.get()
            try await h.loop.submit { gate.value.finishBody(trailers: []) }.get()
            let t = try await bodyTicket(h.coordinator, on: h.loop)
            let command = Task { await h.coordinator.perform(.continue(token: t.token, edit: .init(head: t.effectiveHead, body: .replace(Data("test".utf8))))) }
            try await barrier.waitEntered()
            #expect(h.budgets.snapshot().bytes[.io] == 12) // two retained comparison chunks + the active T4 read
            h.coordinator.shutdown()
            #expect(h.budgets.snapshot().bytes[.editor] == 4)
            barrier.release.signal()
            #expect(await command.value == .invalid)
            await h.runtime.drain()
            #expect(!barrier.timedOut.withLockedValue { $0 })
            #expect(h.budgets.snapshot().reservedBytes == 0 && h.runtime.activePins == 0 && h.files.isEmpty)
            try await h.close()
        } catch { barrier.release.signal(); h.coordinator.shutdown(); try? await h.close(); throw error }
    }
}

extension BreakpointBodyTests {
    @Test(arguments: [false, true])
    func clearAndServerStopWaitForFinishingBodyWithoutResurrection(stop: Bool) async throws {
        let barrier = BlockingBodyWork()
        let limits = RulesLimits(), b = BreakpointCoordinator()
        let runtime = BreakpointBodyRuntime(budgets: OwnedFileBudgets(limits: limits), limits: limits,
            hooks: .init(beforeFinish: { barrier.block() }))
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            try await ProxyFixture.run(processLookup: .init(lookup: { _, _ in nil }),
                rules: TestRules.provider([fullBodyRule(.request)]), breakpoints: b, bodyRuntime: runtime,
                drainDeadline: .init(schedule: { loop, expire in loop.execute(expire); return {} })) { f in
                let client = try await RawClient.connect(port: f.proxyPort)
                do {
                    try await client.send("POST http://127.0.0.1:\(f.origin.port)/body HTTP/1.1\r\nHost: 127.0.0.1:\(f.origin.port)\r\nContent-Length: 4\r\nConnection: close\r\n\r\ntest")
                    try await barrier.waitEntered()
                    let ticket = try #require(b.snapshot().first)
                    let stopped = NIOLockedValueBox(false)
                    let stopping: Task<Void, Error>?
                    if stop { stopping = Task { try await f.server.stop(); stopped.withLockedValue { $0 = true } } }
                    else { f.store.clear(); stopping = nil }
                    let removed = group.next().makePromise(of: Void.self)
                    let watcher = Task {
                        for await _ in b.changes() { if b.snapshot().isEmpty { removed.succeed(()); return } }
                    }
                    defer { watcher.cancel() }
                    try await removed.futureResult.boundedGet()
                    #expect(runtime.activePins == 1 && runtime.budgets.snapshot().bytes[.breakpoint] == 4)
                    #expect(!stopped.withLockedValue { $0 })
                    #expect(f.origin.acceptedConnections == 0)
                    #expect(await b.perform(.continue(token: ticket.token, edit: .init(head: ticket.effectiveHead))) == .invalid)
                    barrier.release.signal()
                    if let stopping { try await stopping.value } else { await runtime.drain() }
                    #expect(!barrier.timedOut.withLockedValue { $0 })
                    #expect(runtime.activePins == 0 && runtime.budgets.snapshot().reservedBytes == 0)
                    #expect(((try? FileManager.default.contentsOfDirectory(atPath: runtime.directory.path)) ?? []).filter { $0 != SpoolDirectoryOwner.markerName }.isEmpty)
                    #expect(b.snapshot().isEmpty)
                    if !stop { #expect(f.store.allFlows().isEmpty) }
                    try await client.close()
                } catch { barrier.release.signal(); b.shutdown(); try? await client.close(); throw error }
            }
            try await group.shutdownGracefully()
        } catch { barrier.release.signal(); try? await group.shutdownGracefully(); throw error }
    }
    @Test func bodyQuotaIsSharedAcrossIndependentClientConnections() async throws {
        var limits = RulesLimits(); limits.breakpointSpoolBytes = 6
        let b = BreakpointCoordinator(limits: limits)
        let runtime = BreakpointBodyRuntime(budgets: OwnedFileBudgets(limits: limits), limits: limits)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            try await ProxyFixture.run(processLookup: .init(lookup: { _, _ in nil }),
                rules: TestRules.provider([fullBodyRule(.request)]), breakpoints: b, bodyRuntime: runtime) { f in
                let a = try await RawClient.connect(port: f.proxyPort), other = try await RawClient.connect(port: f.proxyPort)
                do {
                    let head = "POST http://127.0.0.1:\(f.origin.port)/cap HTTP/1.1\r\nHost: 127.0.0.1:\(f.origin.port)\r\nContent-Length: 4\r\nConnection: close\r\n\r\n"
                    try await a.send(head)
                    let ticket = try await bodyTicket(b, on: group.next(), state: .collectingBody)
                    try await other.send(head + "test")
                    try await other.waitUntilClosed()
                    #expect(String(decoding: other.remainingBytes(), as: UTF8.self).hasPrefix("HTTP/1.1 502"))
                    #expect(b.snapshot().map(\.token) == [ticket.token])
                    #expect(runtime.budgets.snapshot().bytes[.breakpoint] == 4 && f.origin.acceptedConnections == 0)
                    #expect(await b.perform(.cancel(token: ticket.token)) == .accepted)
                    await runtime.drain()
                    #expect(runtime.budgets.snapshot().reservedBytes == 0 && runtime.activePins == 0)
                    try await a.close(); try await other.close()
                } catch { b.shutdown(); try? await a.close(); try? await other.close(); throw error }
            }
            try await group.shutdownGracefully()
        } catch { try? await group.shutdownGracefully(); throw error }
    }
}

extension BreakpointBodyTests {
    @Test func truncatedCollectedResponseFailsWithoutForwardingPrefix() async throws {
        let b = BreakpointCoordinator()
        var reply = HTTP2TestOrigin.Response(); reply.body = "partial"; reply.truncateAfterBody = true
        try await HTTP2TestOrigin.withOrigin(protocols: ["http/1.1"], response: reply) { origin in
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true,
                rules: TestRules.provider([fullBodyRule(.response)]), breakpoints: b) { f, client in
                let response = try await client.request(headers: .init([("host", "localhost:\(origin.port)")]), path: "/truncated")
                #expect(response.status == 502 && !response.body.contains("partial"))
                #expect(response.body.contains("无法完整收集断点正文"))
                await f.bodyRuntime.drain()
                #expect(f.bodyRuntime.activePins == 0 && f.bodyRuntime.budgets.snapshot().reservedBytes == 0)
                #expect(b.snapshot().isEmpty)
            }
        }
    }
    @Test func previewAndReplacementCollisionKeepsTicketUsable() async throws {
        let barrier = BlockingBodyWork(), reads = NIOLockedValueBox(0)
        let h = BodyGateHarness(hooks: .init(beforeRead: {
            if reads.withLockedValue({ $0 += 1; return $0 }) == 1 { barrier.block() }
        }))
        do {
            let gate = try await h.gate(expected: 4)
            try await h.loop.flatSubmit { gate.value.append(ByteBuffer(string: "test")) }.get()
            try await h.loop.submit { gate.value.finishBody(trailers: []) }.get()
            let t = try await bodyTicket(h.coordinator, on: h.loop)
            let preview = Task { try await h.coordinator.bodyPreview(token: t.token, offset: 0, maxBytes: 4) }
            try await barrier.waitEntered()
            #expect(await h.coordinator.perform(.continue(token: t.token, edit: .init(head: t.effectiveHead, body: .replace(Data("test".utf8))))) == .invalid)
            #expect(h.coordinator.snapshot().first?.token == t.token && h.coordinator.snapshot().first?.deadline == t.deadline)
            barrier.release.signal()
            #expect(try await preview.value == Data("test".utf8))
            #expect(await h.coordinator.perform(.continue(token: t.token, edit: .init(head: t.effectiveHead))) == .accepted)
            #expect(!barrier.timedOut.withLockedValue { $0 })
            try await h.close()
        } catch { barrier.release.signal(); h.coordinator.shutdown(); try? await h.close(); throw error }
    }
}

extension BreakpointBodyTests {
    @Test func identicalReplacementStillDropsFramingAndTrailers() async throws {
        try await requestRoundTrip(payload: "original", replacement: Data("original".utf8), chunked: true, upstreamH2: false, downstreamH2: false)
    }
    @Test(arguments: [false, true]) func exactCollectionLimitPreservesEveryByte(known: Bool) async throws {
        var limits = RulesLimits(); limits.breakpointBodyBytes = 10
        let h = BodyGateHarness(limits: limits)
        do {
            let gate = try await h.gate(expected: known ? 10 : nil)
            try await h.loop.flatSubmit { gate.value.append(ByteBuffer(string: "0123456789")) }.get()
            try await h.loop.submit { gate.value.finishBody(trailers: []) }.get()
            let t = try await bodyTicket(h.coordinator, on: h.loop)
            #expect(t.bodyLength == 10)
            #expect(try await h.coordinator.bodyPreview(token: t.token, offset: 0, maxBytes: 100) == Data("0123456789".utf8))
            #expect(await h.coordinator.perform(.continue(token: t.token, edit: .init(head: t.effectiveHead))) == .accepted)
            try await h.close()
            #expect(h.budgets.snapshot().reservedBytes == 0 && h.runtime.activePins == 0)
        } catch { h.coordinator.shutdown(); try? await h.close(); throw error }
    }
    @Test(arguments: [false, true]) func diskFailureAndZeroIOCannotSendCollectedPrefix(zeroIO: Bool) async throws {
        var limits = RulesLimits(); if zeroIO { limits.ioBufferBytes = 0 }
        let budgets = OwnedFileBudgets(limits: limits, freeDiskBytes: { _ in zeroIO ? Int64.max : 0 })
        let runtime = BreakpointBodyRuntime(budgets: budgets, limits: limits), b = BreakpointCoordinator(limits: limits)
        try await ProxyFixture.run(processLookup: .init(lookup: { _, _ in nil }),
            rules: TestRules.provider([fullBodyRule(.request)]), breakpoints: b, bodyRuntime: runtime) { f in
            let client = try await RawClient.connect(port: f.proxyPort)
            do {
                try await client.send("POST http://127.0.0.1:\(f.origin.port)/failure HTTP/1.1\r\nHost: 127.0.0.1:\(f.origin.port)\r\nContent-Length: 4\r\nConnection: close\r\n\r\ntest")
                try await client.waitUntilClosed()
                let wire = String(decoding: client.remainingBytes(), as: UTF8.self)
                #expect(wire.hasPrefix("HTTP/1.1 502") && wire.contains("无法完整收集断点正文"))
                #expect(f.origin.acceptedConnections == 0 && b.snapshot().isEmpty)
                await runtime.drain()
                #expect(runtime.activePins == 0 && budgets.snapshot().reservedBytes == 0)
                #expect(((try? FileManager.default.contentsOfDirectory(atPath: runtime.directory.path)) ?? []).filter { $0 != SpoolDirectoryOwner.markerName }.isEmpty)
                try await client.close()
            } catch { b.shutdown(); try? await client.close(); throw error }
        }
    }
}

extension BreakpointBodyTests {
    @Test(arguments: [false, true]) func http10CloseDelimitedCollectionWaitsForEOFAndClosesDownstream(edited: Bool) async throws {
        let b = BreakpointCoordinator(), group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            try await ProxyFixture.run(processLookup: .init(lookup: { _, _ in nil }),
                rules: TestRules.provider([fullBodyRule(.response)]), breakpoints: b) { f in
                let client = try await RawClient.connect(port: f.proxyPort)
                do {
                    try await client.send("GET http://127.0.0.1:\(f.origin.port)/close-delimited-10 HTTP/1.0\r\nHost: 127.0.0.1:\(f.origin.port)\r\nConnection: keep-alive\r\n\r\n")
                    let t = try await bodyTicket(b, on: group.next())
                    #expect(t.bodyLength == 18 && client.remainingBytes().isEmpty && client.isActive)
                    #expect(try await b.bodyPreview(token: t.token, offset: 0, maxBytes: 100) == Data("complete after EOF".utf8))
                    #expect(await b.perform(.continue(token: t.token, edit: .init(head: t.effectiveHead,
                        body: edited ? .replace(Data("hello".utf8)) : .unchanged))) == .accepted)
                    try await client.waitUntilClosed()
                    let wire = String(decoding: client.remainingBytes(), as: UTF8.self)
                    let split = wire.components(separatedBy: "\r\n\r\n")
                    #expect(split.count == 2 && split[0].hasPrefix("HTTP/1.0 200 OK"))
                    #expect(!split[0].lowercased().contains("transfer-encoding") && !split[0].lowercased().contains("trailer:"))
                    #expect(split[0].lowercased().contains("content-length: 5") == edited)
                    #expect(split[1] == (edited ? "hello" : "complete after EOF"))
                    let flow = try await waitForFlow(f.store) { $0.state == .completed }
                    #expect(flow.transport.upstreamResponse == .http1_0 && flow.transport.downstreamResponse == .http1_0)
                    #expect(try flow.messages[.upstreamResponse]?.body?.load() == Data("complete after EOF".utf8))
                    #expect(f.origin.acceptedConnections == 1 && b.snapshot().isEmpty)
                    try await client.close()
                } catch { b.shutdown(); try? await client.close(); throw error }
            }
            try await group.shutdownGracefully()
        } catch { try? await group.shutdownGracefully(); throw error }
    }
}

extension BreakpointBodyTests {
    @Test func unchangedH2TrailersSurviveH1RequestAndResponseTranslation() async throws {
        try await requestRoundTrip(payload: "original", replacement: nil, chunked: false,
            upstreamH2: false, downstreamH2: true, withTrailers: true)
        try await responseRoundTrip(upstreamH2: true, downstreamH2: false)
    }
}

extension BreakpointBodyTests {
    @Test(arguments: ["queued", "write", "compare", "expiredWrite"])
    func cancelPreemptsPendingBodyCommandWithoutEarlyMemoryRelease(phase: String) async throws {
        let barrier = BlockingBodyWork(), writes = NIOLockedValueBox(0)
        let h = BodyGateHarness(hooks: .init(beforeWrite: {
            let n = writes.withLockedValue { $0 += 1; return $0 }
            if n == 2 && (phase == "write" || phase == "expiredWrite") { barrier.block() }
        }, beforeRead: { if phase == "compare" { barrier.block() } }))
        do {
            let gate = try await h.gate(expected: 4)
            try await h.loop.flatSubmit { gate.value.append(ByteBuffer(string: "test")) }.get()
            try await h.loop.submit { gate.value.finishBody(trailers: []) }.get()
            let t = try await bodyTicket(h.coordinator, on: h.loop)
            if phase == "queued" { h.loop.execute { barrier.block() }; try await barrier.waitEntered() }
            let old = NIOLockedValueBox<[BreakpointCommandResult]>([]), cancelled = NIOLockedValueBox<[BreakpointCommandResult]>([])
            h.coordinator.perform(.continue(token: t.token, edit: .init(head: t.effectiveHead, body: .replace(Data("test".utf8))))) { value in old.withLockedValue { $0.append(value) } }
            if phase != "queued" { try await barrier.waitEntered() }
            if phase == "expiredWrite" { h.clock.advance(by: .seconds(121)) }
            h.coordinator.perform(.cancel(token: t.token)) { value in cancelled.withLockedValue { $0.append(value) } }
            #expect(old.withLockedValue { $0 } == [phase == "expiredWrite" ? .expired : .invalid])
            if phase == "queued" {
                #expect(await h.coordinator.perform(.cancel(token: t.token)) == .invalid)
            } else {
                try await h.loop.submit {}.get()
                #expect(cancelled.withLockedValue { $0 } == [phase == "expiredWrite" ? .expired : .accepted])
            }
            #expect(h.budgets.snapshot().bytes[.editor] == 4 && h.runtime.activePins > 0)
            barrier.release.signal(); if phase == "compare" { barrier.release.signal() }
            try await h.loop.submit {}.get()
            #expect(cancelled.withLockedValue { $0 } == [phase == "expiredWrite" ? .expired : .accepted])
            h.coordinator.shutdown() // bounded RED cleanup if the old pending command was incorrectly retained
            h.continued.withLockedValue { $0 }?.cancel()
            await h.runtime.drain()
            #expect(!barrier.timedOut.withLockedValue { $0 })
            #expect(h.continued.withLockedValue { $0 } == nil)
            #expect(h.failures.withLockedValue { $0 } == [phase == "expiredWrite" ? .expired : .cancelled])
            #expect(old.withLockedValue { $0.count } == 1 && cancelled.withLockedValue { $0.count } == 1)
            #expect(try await h.loop.submit { gate.value.timerCount }.get() == 0)
            #expect(h.runtime.activePins == 0 && h.files.isEmpty && h.budgets.snapshot().reservedBytes == 0)
            try await h.close()
        } catch { barrier.release.signal(); barrier.release.signal(); h.coordinator.shutdown(); try? await h.close(); throw error }
    }
}

extension BreakpointBodyTests {
    @Test func knownOversizeContinuesCompleteBodyOnRealWire() async throws {
        var limits = RulesLimits(); limits.breakpointBodyBytes = 10
        let b = BreakpointCoordinator(limits: limits), group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            try await ProxyFixture.run(processLookup: .init(lookup: { _, _ in nil }),
                rules: TestRules.provider([fullBodyRule(.request)]), breakpoints: b) { f in
                let client = try await RawClient.connect(port: f.proxyPort)
                do {
                    let payload = "complete oversize body"
                    try await client.send("POST http://127.0.0.1:\(f.origin.port)/echo HTTP/1.1\r\nHost: 127.0.0.1:\(f.origin.port)\r\nContent-Length: \(payload.utf8.count)\r\nConnection: close\r\n\r\n")
                    let t = try await bodyTicket(b, on: group.next(), state: .pausedHeaders, unavailable: true)
                    #expect(t.bodyUnavailable == .knownLengthTooLarge && f.origin.acceptedConnections == 0)
                    #expect(await b.perform(.continue(token: t.token, edit: .init(head: t.effectiveHead))) == .accepted)
                    try await client.send(payload)
                    try await client.waitUntilClosed()
                    let wire = String(decoding: client.remainingBytes(), as: UTF8.self)
                    #expect(wire.hasPrefix("HTTP/1.1 200") && wire.hasSuffix(payload))
                    let flow = try await waitForFlow(f.store) { $0.state == .completed }
                    #expect(try flow.messages[.upstreamRequest]?.body?.load() == Data(payload.utf8))
                    #expect(b.snapshot().isEmpty && f.origin.acceptedConnections == 1)
                    try await client.close()
                } catch { b.shutdown(); try? await client.close(); throw error }
            }
            try await group.shutdownGracefully()
        } catch { try? await group.shutdownGracefully(); throw error }
    }
}

extension BreakpointBodyTests {
    @Test(arguments: ["normal", "expired", "shutdown"])
    func cancelPreemptsCollectAndSettlesDuplicateExpiryOrShutdownOnce(order: String) async throws {
        let h = BodyGateHarness(), barrier = BlockingBodyWork()
        do {
            let gate = try await h.gate(expected: 4, mode: .headers)
            let t = try #require(h.coordinator.snapshot().first)
            h.loop.execute { barrier.block() }; try await barrier.waitEntered()
            let old = NIOLockedValueBox<[BreakpointCommandResult]>([]), cancel = NIOLockedValueBox<[BreakpointCommandResult]>([])
            h.coordinator.perform(.collectBody(token: t.token)) { r in old.withLockedValue { $0.append(r) } }
            h.coordinator.perform(.cancel(token: t.token)) { r in cancel.withLockedValue { $0.append(r) } }
            #expect(old.withLockedValue { $0 } == [.invalid])
            if order == "expired" {
                h.clock.advance(by: .seconds(121))
                #expect(await h.coordinator.perform(.cancel(token: t.token)) == .expired)
            } else if order == "shutdown" { h.coordinator.shutdown() }
            else { #expect(await h.coordinator.perform(.cancel(token: t.token)) == .invalid) }
            barrier.release.signal()
            try await h.loop.submit {}.get()
            #expect(cancel.withLockedValue { $0 } == [order == "expired" ? .expired : (order == "shutdown" ? .invalid : .accepted)])
            #expect(h.failures.withLockedValue { $0 } == [order == "expired" ? .expired : .cancelled])
            #expect(h.coordinator.snapshot().isEmpty && h.continued.withLockedValue { $0 } == nil)
            #expect(try await h.loop.submit { gate.value.timerCount }.get() == 0)
            await h.runtime.drain()
            #expect(!barrier.timedOut.withLockedValue { $0 })
            #expect(h.runtime.activePins == 0 && h.files.isEmpty && h.budgets.snapshot().reservedBytes == 0)
            try await h.close()
        } catch { barrier.release.signal(); h.coordinator.shutdown(); try? await h.close(); throw error }
    }
}


extension BreakpointBodyTests {
    @Test(arguments: [false, true])
    func opaqueFullBodyEOFKeepsCodingOrRejectsHTTP10(compound: Bool) async throws {
        let b = BreakpointCoordinator(), group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            try await ProxyFixture.run(processLookup: .init(lookup: { _, _ in nil }),
                rules: TestRules.provider([fullBodyRule(.response)]), breakpoints: b) { f in
                let client = try await RawClient.connect(port: f.proxyPort)
                do {
                    let path = compound ? "/opaque-compound-full-body" : "/opaque-full-body"
                    try await client.send("GET http://127.0.0.1:\(f.origin.port)\(path) HTTP/1.\(compound ? 0 : 1)\r\nHost: 127.0.0.1:\(f.origin.port)\r\n\r\n")
                    let t = try await bodyTicket(b, on: group.next())
                    #expect(t.bodyLength == 6 && client.remainingBytes().isEmpty)
                    #expect(await b.perform(.continue(token: t.token, edit: .init(head: t.effectiveHead, body: .unchanged))) == .accepted)
                    let headers = try await client.receive(until: "\r\n\r\n")
                    if compound {
                        #expect(headers.hasPrefix("HTTP/1.0 502"))
                        #expect(!headers.lowercased().contains("transfer-encoding: gzip"))
                    } else {
                        #expect(headers.lowercased().contains("transfer-encoding: gzip\r\n"))
                        #expect(!headers.lowercased().contains("content-length:"))
                        #expect(headers.lowercased().contains("connection: close\r\n"))
                        // Close is part of the assertion, not teardown or a timeout-as-success.
                        if headers.lowercased().contains("connection: close") { try await client.waitUntilClosed() }
                        #expect(!client.isActive)
                        #expect(String(decoding: client.remainingBytes(), as: UTF8.self) == "opaque")
                    }
                    let flow = try await waitForFlow(f.store) { flow in
                        if compound { if case .failed = flow.state { return true }; return false }; return flow.state == .completed
                    }
                    #expect(try flow.messages[.upstreamResponse]?.body?.load() == Data("opaque".utf8))
                    try await client.close()
                } catch { b.shutdown(); try? await client.close(); throw error }
            }
            try await group.shutdownGracefully()
        } catch { try? await group.shutdownGracefully(); throw error }
    }

    @Test(arguments: [false, true], [false, true])
    func effectiveHEADFullBodyReplacementMatchesSelectedEmptySource(upstreamH2: Bool, downstreamH2: Bool) async throws {
        let b = BreakpointCoordinator()
        var response = HTTP2TestOrigin.Response()
        response.headers = HTTPHeaders([("content-length", "5")]); response.body = "hello"; response.trailers = nil
        try await HTTP2TestOrigin.withOrigin(protocols: upstreamH2 ? ["h2"] : ["http/1.1"], response: response) { origin in
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: downstreamH2,
                rules: TestRules.provider([TestRules.breakpoint(.request), fullBodyRule(.response)]), breakpoints: b) { f, client in
                let pending = Task { try await client.request(headers: .init([("host", "localhost:\(origin.port)")]), method: .GET) }
                do {
                    let request = try await bodyTicket(b, on: f.channel.eventLoop, state: .pausedHeaders)
                    guard case .request(var target, let fields) = request.effectiveHead else { throw HTTPTransportError.closed }
                    target.method = "HEAD"
                    #expect(await b.perform(.continue(token: request.token, edit: .init(head: .request(target, headers: fields)))) == .accepted)
                    let response = try await bodyTicket(b, on: f.channel.eventLoop)
                    #expect(response.bodyLength == 0)
                    #expect(await b.perform(.continue(token: response.token, edit: .init(head: response.effectiveHead, body: .replace(Data("hello".utf8))))) == .accepted)
                    let result = try await pending.value
                    #expect(result.status == 200 && result.bytes.isEmpty && result.headers["content-length"] == ["0"])
                    let flow = try await waitForFlow(f.store) { $0.state == .completed }
                    #expect(flow.messages[.upstreamResponse]?.observedBytes == 0)
                    #expect(flow.messages[.downstreamResponse]?.observedBytes == 0)
                    #expect(flow.messages[.upstreamResponse]?.head.headers.first { $0.name.lowercased() == "content-length" }?.value == "5")
                    #expect(flow.provenance.ruleMatches?.outcomes.contains { $0.code == .breakpointBodyIgnored } == true)
                } catch { b.shutdown(); _ = try? await pending.value; throw error }
            }
        }
    }
}


extension BreakpointBodyTests {
    @Test(arguments: ["writeError", "finishError", "compareError", "collectError", "collectSuccess", "writeSuccess", "finishSuccess", "compareSuccess"], ["cancel", "expire", "clear", "shutdown"])
    func registeredCancelWinsBeforeOldBodyCallbackContinues(phase: String, termination: String) async throws {
        let barrier = BlockingBodyWork(), armed = NIOLockedValueBox(false), diskFails = NIOLockedValueBox(false)
        defer { barrier.release.signal() }
        let directory = NIOLockedValueBox<URL?>(nil)
        let fileError = NIOLockedValueBox<String?>(nil)
        let hooks = BodyFileIOHooks(beforeFinish: {
            guard phase == "finishError", armed.withLockedValue({ $0 }), let directory = directory.withLockedValue({ $0 }) else { return }
            do {
                for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) where name.hasPrefix(".spool-") {
                    try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
                }
            } catch { fileError.withLockedValue { $0 = String(describing: error) } }
        }, beforeRead: {
            guard phase == "compareError", armed.withLockedValue({ $0 }), let directory = directory.withLockedValue({ $0 }) else { return }
            do {
                for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) where name.hasSuffix(".body") {
                    let handle = try FileHandle(forWritingTo: directory.appendingPathComponent(name))
                    try handle.truncate(atOffset: 0); try handle.close()
                }
            } catch { fileError.withLockedValue { $0 = String(describing: error) } }
        })
        let h = BodyGateHarness(hooks: hooks, freeDiskBytes: { _ in diskFails.withLockedValue { $0 } ? 0 : Int64.max })
        directory.withLockedValue { $0 = h.runtime.directory }
        do {
            let callback: ExchangeBreakpointGate.BodyCallback = phase.hasPrefix("write") ? .replacementWrite
                : (phase.hasPrefix("finish") ? .replacementFinish : (phase.hasPrefix("compare") ? .comparison
                    : (phase == "collectError" ? .collectionAppend : .collectionFinish)))
            let gate = try await h.gate(expected: phase == "collectSuccess" ? 0 : 4, beforeBodyCallback: { kind in
                if kind == callback, armed.withLockedValue({ $0 }) { barrier.block() }
            })
            let old = NIOLockedValueBox<[BreakpointCommandResult]>([]), cancel = NIOLockedValueBox<[BreakpointCommandResult]>([])
            if !phase.hasPrefix("collect") {
                try await h.loop.flatSubmit { gate.value.append(ByteBuffer(string: "body")) }.get()
                try await h.loop.submit { gate.value.finishBody(trailers: []) }.get()
                _ = try await bodyTicket(h.coordinator, on: h.loop)
            }
            let t = try #require(h.coordinator.snapshot().first)
            armed.withLockedValue { $0 = true }
            if phase == "collectSuccess" { h.loop.execute { gate.value.finishBody(trailers: []) } }
            else if phase == "collectError" { h.loop.execute { gate.value.append(ByteBuffer(string: "too-long")) } }
            else {
                diskFails.withLockedValue { $0 = phase == "writeError" }
                h.coordinator.perform(.continue(token: t.token, edit: .init(head: t.effectiveHead, body: .replace(Data("edit".utf8))))) { result in old.withLockedValue { $0.append(result) } }
            }
            // The old callback is already executing on the loop, before its state/terminal decision.
            try await barrier.waitEntered()
            h.coordinator.perform(.cancel(token: t.token)) { result in cancel.withLockedValue { $0.append(result) } }
            h.cancelRegistered.withLockedValue { $0 = true }
            #expect(cancel.withLockedValue { $0.isEmpty })
            #expect(old.withLockedValue { $0 } == (phase.hasPrefix("collect") ? [] : [.invalid]))
            if termination == "expire" { h.clock.advance(by: .seconds(121)) }
            if termination == "clear" { h.coordinator.setAdmissionEnabled(false, existing: .cancel) }
            if termination == "shutdown" { h.coordinator.shutdown() }
            barrier.release.signal()
            try await h.loop.submit {}.get()
            #expect(cancel.withLockedValue { $0 } == [termination == "cancel" ? .accepted : (termination == "expire" ? .expired : .invalid)])
            #expect(h.bodyErrors.withLockedValue { $0 } == 0)
            #expect(h.publishedAfterCancel.withLockedValue { $0 } == 0)
            #expect(h.failures.withLockedValue { $0 } == [termination == "expire" ? .expired : .cancelled])
            #expect(h.resumed.withLockedValue { $0 } == 0 && h.continued.withLockedValue { $0 } == nil)
            #expect(try await h.loop.submit { gate.value.timerCount }.get() == 0)
            await h.runtime.drain()
            #expect(h.runtime.activePins == 0 && h.files.isEmpty && h.budgets.snapshot().reservedBytes == 0)
            #expect(!barrier.timedOut.withLockedValue { $0 } && fileError.withLockedValue { $0 } == nil)
            try await h.close()
        } catch { barrier.release.signal(); h.coordinator.shutdown(); try? await h.close(); throw error }
    }
}


extension BreakpointBodyTests {
    @Test func opaqueCompoundFullBodyFailsBeforeSendingH2Entity() async throws {
        let b = BreakpointCoordinator()
        var response = HTTP2TestOrigin.Response()
        response.h1TransferCoding = "gzip, chunked"; response.body = "opaque"; response.trailers = nil
        try await HTTP2TestOrigin.withOrigin(protocols: ["http/1.1"], response: response) { origin in
            try await HTTP2ProxyFixture.withProxy(origin: origin, downstreamH2: true,
                rules: TestRules.provider([fullBodyRule(.response)]), breakpoints: b) { f, client in
                let pending = Task { try await client.request(headers: .init([("host", "localhost:\(origin.port)")])) }
                do {
                    let t = try await bodyTicket(b, on: f.channel.eventLoop)
                    #expect(t.bodyLength == 6)
                    #expect(await b.perform(.continue(token: t.token, edit: .init(head: t.effectiveHead, body: .unchanged))) == .accepted)
                    let result = try await pending.value
                    #expect(result.status == 502 && result.body != "opaque")
                    #expect(!result.headers.contains(name: "transfer-encoding"))
                    let flow = try await waitForFlow(f.store) { if case .failed = $0.state { return true }; return false }
                    #expect(try flow.messages[.upstreamResponse]?.body?.load() == Data("opaque".utf8))
                    #expect(flow.provenance.generatedResponse != nil)
                } catch { b.shutdown(); _ = try? await pending.value; throw error }
            }
        }
    }
}


extension BreakpointBodyTests {
    @Test(arguments: ["clear", "revoke", "shutdown", "live"], [false, true])
    func revokedBodyCallbackCannotReplaceChosenCancellationWithExpiry(termination: String, pendingCancel: Bool) async throws {
        for callback in [ExchangeBreakpointGate.BodyCallback.collectionFinish, .replacementFinish, .comparison] {
            let h = BodyGateHarness(), barrier = BlockingBodyWork(), armed = NIOLockedValueBox(false)
            defer { barrier.release.signal() }
            do {
                let gate = try await h.gate(expected: 4, flowID: 73, beforeBodyCallback: { kind in
                    if kind == callback, armed.withLockedValue({ $0 }) { barrier.block() }
                })
                try await h.loop.flatSubmit { gate.value.append(ByteBuffer(string: "body")) }.get()
                if callback != .collectionFinish {
                    try await h.loop.submit { gate.value.finishBody(trailers: []) }.get()
                    _ = try await bodyTicket(h.coordinator, on: h.loop)
                }
                let t = try #require(h.coordinator.snapshot().first)
                let old = NIOLockedValueBox<[BreakpointCommandResult]>([]), cancelled = NIOLockedValueBox<[BreakpointCommandResult]>([])
                armed.withLockedValue { $0 = true }
                if callback == .collectionFinish { h.loop.execute { gate.value.finishBody(trailers: []) } }
                else {
                    h.coordinator.perform(.continue(token: t.token, edit: .init(head: t.effectiveHead, body: .replace(Data("edit".utf8))))) { result in old.withLockedValue { $0.append(result) } }
                }
                try await barrier.waitEntered()
                #expect(h.clock.now < t.deadline)
                if pendingCancel { h.coordinator.perform(.cancel(token: t.token)) { result in cancelled.withLockedValue { $0.append(result) } } }
                switch termination {
                case "clear": h.coordinator.setAdmissionEnabled(false, existing: .cancel)
                case "revoke": h.coordinator.revoke(flowIDs: [73], reason: .cancelled)
                case "shutdown": h.coordinator.shutdown()
                default: break
                }
                h.cancelRegistered.withLockedValue { $0 = true }
                if termination != "live" {
                    #expect(h.coordinator.snapshot().isEmpty)
                    #expect(cancelled.withLockedValue { $0 } == (pendingCancel ? [.invalid] : []))
                }
                #expect(h.runtime.activePins > 0 && (h.budgets.snapshot().bytes[.breakpoint] ?? 0) >= 4)
                // Revocation has already selected cancelled; only now does the old deadline pass.
                h.clock.advance(by: .seconds(121))
                #expect(h.clock.now >= t.deadline)
                barrier.release.signal()
                try await h.loop.submit {}.get()
                #expect(h.failures.withLockedValue { $0 } == [termination == "live" ? .expired : .cancelled])
                #expect(cancelled.withLockedValue { $0 } == (pendingCancel ? [termination == "live" ? .expired : .invalid] : []))
                if callback != .collectionFinish {
                    #expect(old.withLockedValue { $0 } == [termination == "live" && !pendingCancel ? .expired : .invalid])
                }
                #expect(h.bodyErrors.withLockedValue { $0 } == 0 && h.publishedAfterCancel.withLockedValue { $0 } == 0)
                #expect(h.resumed.withLockedValue { $0 } == 0 && h.continued.withLockedValue { $0 } == nil)
                #expect(try await h.loop.submit { gate.value.timerCount }.get() == 0)
                await h.runtime.drain()
                #expect(h.runtime.activePins == 0 && h.files.isEmpty && h.budgets.snapshot().reservedBytes == 0)
                #expect(h.coordinator.snapshot().isEmpty && !barrier.timedOut.withLockedValue { $0 })
                try await h.close()
            } catch { barrier.release.signal(); h.coordinator.shutdown(); try? await h.close(); throw error }
        }
    }
}
