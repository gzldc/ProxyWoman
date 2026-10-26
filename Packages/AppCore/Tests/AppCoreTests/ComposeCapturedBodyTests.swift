import FlowStore
import Foundation
import os
import Testing
@testable import AppCore

// MARK: support

private let target = HTTPMessageTarget(scheme: "https", host: "api.test", port: 443, method: "POST", pathAndQuery: "/upload")
private let mib = 1_048_576

private func pattern(_ count: Int, seed: UInt8 = 7) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
}

private func requestSnapshot(
    boundary: HTTPMessageBoundary = .downstreamRequest, slice: HTTPBodySlice?, state: HTTPBodyState = .complete, observed: UInt64? = nil
) -> HTTPMessageSnapshot {
    HTTPMessageSnapshot(
        boundary: boundary, head: .request(target, headers: [HeaderField(name: "Content-Type", value: "application/octet-stream")]),
        body: slice, bodyState: state, observedBytes: observed ?? UInt64(slice?.count ?? 0), transferState: .finished)
}

private func flowWith(_ messages: [HTTPMessageBoundary: HTTPMessageSnapshot]) -> Flow {
    var flow = Flow(id: 5, scheme: "https", method: "POST", host: "api.test", port: 443, path: "/upload")
    flow.state = .completed
    flow.messages = messages
    return flow
}

/// A flow the store references (so its managed body is live and can be revoked by `clear()`).
@MainActor private func storedFlow(_ store: FlowStore, body: BodyRef, offset: Int = 0, count: Int? = nil) throws -> Flow {
    let slice = HTTPBodySlice(ref: body, offset: offset, count: count ?? body.size - offset)
    let id = store.begin { id in
        var flow = flowWith([.downstreamRequest: requestSnapshot(slice: slice)])
        flow = Flow(copying: flow, id: id)
        return flow
    }
    return try #require(store.flow(id))
}

private extension Flow {
    init(copying flow: Flow, id: Int) {
        self.init(id: id, startedAt: flow.startedAt, scheme: flow.scheme, method: flow.method, host: flow.host, port: flow.port,
                  path: flow.path, requestHeaders: flow.requestHeaders)
        state = flow.state
        messages = flow.messages
    }
}

private func makeStore() -> (FlowStore, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pw-captured-\(UUID().uuidString)")
    return (FlowStore(bodyDirectory: directory), directory)
}

/// A spilled (on-disk) managed body.
private func spilledBody(_ store: FlowStore, bytes: Data) throws -> BodyRef {
    let capture = store.makeBodyCapture()
    capture.append(bytes)
    return try #require(capture.finish().body)
}

/// Stands in for the managed asset store: drains `read` the way the real one does and records
/// every request. Can park at a chosen request, or just before returning the finished asset.
final class StreamingComposeFiles: ComposeBodyFiles, Sendable {
    struct Failure: Error {}

    private struct State {
        var requests: [(offset: Int64, maxBytes: Int)] = []
        var received = Data()
        var imported: [ComposeBodyFile] = []
        var discards: [Set<UUID>] = []
        var holdBeforeRequest: Int?
        var holdBeforeReturn = false
        var askBytes = 65_536
        var chunkSizes: [Int] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let reachedStream = AsyncStream<Void>.makeStream()
    private let releaseStream = AsyncStream<Void>.makeStream()

    var requests: [(offset: Int64, maxBytes: Int)] { state.withLock { $0.requests } }
    var received: Data { state.withLock { $0.received } }
    var chunkSizes: [Int] { state.withLock { $0.chunkSizes } }
    var imported: [ComposeBodyFile] { state.withLock { $0.imported } }
    var discards: [Set<UUID>] { state.withLock { $0.discards } }

    func hold(beforeRequest index: Int) { state.withLock { $0.holdBeforeRequest = index } }
    func holdBeforeReturning() { state.withLock { $0.holdBeforeReturn = true } }
    func ask(_ bytes: Int) { state.withLock { $0.askBytes = bytes } }

    /// Returns when the fake is parked at its hold point.
    func waitUntilParked() async {
        var iterator = reachedStream.stream.makeAsyncIterator()
        await iterator.next()
    }

    func release() { releaseStream.continuation.yield() }

    private func park() async {
        reachedStream.continuation.yield()
        var iterator = releaseStream.stream.makeAsyncIterator()
        // A cancelled task wakes up with nil: the hold ends without a release.
        await iterator.next()
    }

    func importFile(_ url: URL, displayName: String) async throws -> ComposeBodyFile { throw Failure() }

    func importStream(
        expectedSize: Int64, displayName: String,
        read: @escaping @Sendable (Int64, Int) async throws -> Data
    ) async throws -> ComposeBodyFile {
        var copied: Int64 = 0
        var index = 0
        while copied < expectedSize {
            if state.withLock({ $0.holdBeforeRequest }) == index { await park() }
            let position = copied
            let ask = state.withLock { min($0.askBytes, Int(min(Int64(Int.max), expectedSize - position))) }
            state.withLock { $0.requests.append((position, ask)) }
            let data = try await read(position, ask)
            guard !data.isEmpty else { throw Failure() }
            state.withLock { $0.received.append(data); $0.chunkSizes.append(data.count) }
            copied += Int64(data.count)
            index += 1
        }
        if state.withLock({ $0.holdBeforeReturn }) { await park() }
        let file = ComposeBodyFile(assetID: UUID(), displayName: displayName, size: expectedSize)
        state.withLock { $0.imported.append(file) }
        return file
    }

    func discard(_ ids: Set<UUID>) async {
        state.withLock { $0.discards.append(ids) }
    }
}

/// Remembers every lease the window opens, so a test can see whether it was released.
private final class LeaseLog: Sendable {
    private let leases = OSAllocatedUnfairLock(initialState: [HTTPBodyReadLease]())
    var all: [HTTPBodyReadLease] { leases.withLock { $0 } }
    func acquire(from store: FlowStore) -> @Sendable (BodyRef) throws -> HTTPBodyReadLease {
        { [self] ref in
            let lease = try store.acquireBody(ref)
            leases.withLock { $0.append(lease) }
            return lease
        }
    }
}

@MainActor private func model(for flow: Flow, store: FlowStore, files: StreamingComposeFiles, leases: LeaseLog) -> ComposeViewModel {
    ComposeViewModel(draft: ComposeDraft(from: flow), client: FakeComposeClient(), files: files,
                     access: ScopedFileAccess(start: { _ in false }, stop: { _ in }), acquireBody: leases.acquire(from: store))
}

private func replayReason(_ flow: Flow) -> ReplayBlockReason? {
    if case .failure(let reason) = ReplayEligibility.evaluate(flow: flow) { reason } else { nil }
}

// MARK: tests

@MainActor @Suite(.timeLimit(.minutes(1)), .productionChinese) struct ComposeCapturedBodyTests {
    @Test func largeCompleteBodyBecomesPending() throws {
        let (store, directory) = makeStore(); defer { try? FileManager.default.removeItem(at: directory) }
        // 2 MiB in memory (managed), 2 MiB spilled to disk, and a borrowed on-disk reference.
        let memory = try storedFlow(store, body: store.makeManagedBody(pattern(2 * mib)))
        let disk = try storedFlow(store, body: spilledBody(store, bytes: pattern(2 * mib)))
        let borrowed = try storedFlow(store, body: .file(URL(fileURLWithPath: "/nonexistent/x.body"), size: 4))
        for flow in [memory, disk, borrowed] {
            let slice = try #require(flow.messages[.downstreamRequest]?.body)
            #expect(ComposeImportEligibility.evaluate(flow: flow, boundary: .downstreamRequest) == .importable(slice))
            let draft = ComposeDraft(from: flow)
            #expect(draft.body == .pending(CapturedBodyImport(slice: slice, displayName: "request-body.bin", size: Int64(slice.count))))
            #expect(draft.body.mode == nil && draft.body.bytes == nil)
        }
        // Exactly at the in-memory ceiling stays inline; one byte more is imported.
        let atLimit = try storedFlow(store, body: store.makeManagedBody(pattern(mib)))
        #expect(ComposeImportEligibility.evaluate(flow: atLimit, boundary: .downstreamRequest) == .inline)
        let over = try storedFlow(store, body: store.makeManagedBody(pattern(mib + 1)))
        if case .importable = ComposeImportEligibility.evaluate(flow: over, boundary: .downstreamRequest) {} else { Issue.record("not importable") }
    }

    @Test func eligibilityWorksForAnyRequestBoundaryAndLegacyFlows() throws {
        let big = HTTPBodySlice(ref: .memory(pattern(2 * mib)), offset: 0, count: 2 * mib)
        let flow = flowWith([
            .downstreamRequest: requestSnapshot(slice: nil),
            .upstreamRequest: requestSnapshot(boundary: .upstreamRequest, slice: big),
        ])
        #expect(ComposeImportEligibility.evaluate(flow: flow, boundary: .upstreamRequest) == .importable(big))
        #expect(ComposeImportEligibility.evaluate(flow: flow, boundary: .downstreamRequest) == .inline)

        // No snapshot of the boundary: only the downstream request falls back to the legacy fields.
        var legacy = Flow(id: 1, scheme: "https", method: "POST", host: "h", port: 443, path: "/")
        legacy.state = .completed
        legacy.requestBody = .memory(pattern(2 * mib))
        legacy.bytesSent = 2 * mib
        if case .importable(let slice) = ComposeImportEligibility.evaluate(flow: legacy, boundary: .downstreamRequest) {
            #expect(slice.offset == 0 && slice.count == 2 * mib)
        } else { Issue.record("legacy body not importable") }
        #expect(ComposeImportEligibility.evaluate(flow: legacy, boundary: .upstreamRequest) == .blocked(.bodyIncomplete))
        #expect(ComposeImportEligibility.evaluate(flow: flow, boundary: .composeSubmitted) == .blocked(.bodyIncomplete))

        legacy.requestBodyTruncated = true
        #expect(ComposeImportEligibility.evaluate(flow: legacy, boundary: .downstreamRequest) == .blocked(.bodyTruncated))
        legacy.requestBodyTruncated = false
        legacy.bytesSent = 3
        #expect(ComposeImportEligibility.evaluate(flow: legacy, boundary: .downstreamRequest) == .blocked(.bodyIncomplete))
        legacy.bytesSent = 600 * mib
        #expect(ComposeImportEligibility.evaluate(flow: legacy, boundary: .downstreamRequest) == .blocked(.bodyTooLarge))
    }

    @Test func inlineExactlyWhereReplayIsAllowed() {
        // Every shape Replay accepts is inline; everything Replay refuses is imported or blocked.
        let small = HTTPBodySlice(ref: .memory(Data([1, 2, 3])), offset: 0, count: 3)
        let big = HTTPBodySlice(ref: .memory(pattern(mib + 1)), offset: 0, count: mib + 1)
        let disk = HTTPBodySlice(ref: .file(URL(fileURLWithPath: "/nonexistent/y"), size: 2), offset: 0, count: 2)
        let flows: [Flow] = [
            flowWith([.downstreamRequest: requestSnapshot(slice: nil)]),
            flowWith([.downstreamRequest: requestSnapshot(slice: small)]),
            flowWith([.downstreamRequest: requestSnapshot(slice: big)]),
            flowWith([.downstreamRequest: requestSnapshot(slice: disk)]),
            flowWith([.downstreamRequest: requestSnapshot(slice: small, state: .truncated, observed: 9)]),
            flowWith([.downstreamRequest: requestSnapshot(slice: nil, state: .incomplete, observed: 4)]),
            flowWith([.downstreamRequest: requestSnapshot(slice: small, observed: 2)]),
        ]
        for flow in flows {
            let replayAllowed: Bool
            if case .success = ReplayEligibility.evaluate(flow: flow) { replayAllowed = true } else { replayAllowed = false }
            #expect((ComposeImportEligibility.evaluate(flow: flow, boundary: .downstreamRequest) == .inline) == replayAllowed)
        }
    }

    @Test func replayEligibilityUnchanged() throws {
        let (store, directory) = makeStore(); defer { try? FileManager.default.removeItem(at: directory) }
        let memory = try storedFlow(store, body: store.makeManagedBody(pattern(2 * mib)))
        let disk = try storedFlow(store, body: spilledBody(store, bytes: pattern(2 * mib)))
        #expect(replayReason(memory) == .bodyTooLarge)
        #expect(replayReason(disk) == .bodyOnDisk)
        // Replay and Repeat entries still refuse them; plain Edit opens the draft.
        #expect(ComposeEntry.replay(memory) == .body(.bodyTooLarge))
        #expect(ComposeEntry.replay(disk) == .body(.bodyOnDisk))
        #expect(ComposeEntry.edit(memory) == nil && ComposeEntry.edit(disk) == nil)
    }

    @Test func smallBodyStaysInline() throws {
        let (store, directory) = makeStore(); defer { try? FileManager.default.removeItem(at: directory) }
        let flow = try storedFlow(store, body: store.makeManagedBody(Data("hello".utf8)))
        #expect(ComposeImportEligibility.evaluate(flow: flow, boundary: .downstreamRequest) == .inline)
        #expect(ComposeDraft(from: flow).body == .text("hello"))
    }

    @Test func truncatedBodyStillBlocked() {
        let big = HTTPBodySlice(ref: .memory(pattern(2 * mib)), offset: 0, count: 2 * mib)
        let flow = flowWith([.downstreamRequest: requestSnapshot(slice: big, state: .truncated, observed: UInt64(3 * mib))])
        #expect(ComposeImportEligibility.evaluate(flow: flow, boundary: .downstreamRequest) == .blocked(.bodyTruncated))
        #expect(ComposeDraft(from: flow).body == .omitted(.replay(.bodyTruncated)))
        let incomplete = flowWith([.downstreamRequest: requestSnapshot(slice: big, state: .incomplete)])
        #expect(ComposeDraft(from: incomplete).body == .omitted(.replay(.bodyIncomplete)))
    }

    @Test func bodyOver512MiBStillBlocked() {
        let observed = UInt64(512 * mib) + 1
        let flow = flowWith([.downstreamRequest: requestSnapshot(slice: nil, observed: observed)])
        #expect(ComposeImportEligibility.evaluate(flow: flow, boundary: .downstreamRequest) == .blocked(.bodyTooLarge))
        #expect(ComposeDraft(from: flow).body == .omitted(.replay(.bodyTooLarge)))
        // Exactly 512 MiB is still importable.
        let ref = BodyRef.file(URL(fileURLWithPath: "/nonexistent/z"), size: 512 * mib)
        let limit = flowWith([.downstreamRequest: requestSnapshot(slice: HTTPBodySlice(ref: ref, offset: 0, count: 512 * mib))])
        if case .importable = ComposeImportEligibility.evaluate(flow: limit, boundary: .downstreamRequest) {} else { Issue.record("limit") }
    }

    @Test func pendingBlocksSendWithBodyImportingIssue() async throws {
        let (store, directory) = makeStore(); defer { try? FileManager.default.removeItem(at: directory) }
        let flow = try storedFlow(store, body: store.makeManagedBody(pattern(2 * mib)))
        let client = FakeComposeClient()
        let window = ComposeViewModel(draft: ComposeDraft(from: flow), client: client)
        let issue = try #require(window.issues.first { $0.code == .bodyImporting })
        #expect(issue.severity == .error && issue.field == .body)
        #expect(!issue.localizedDescription.isEmpty && !issue.localizedDescription.hasPrefix("compose."))
        #expect(!window.canSend && !window.isSendEnabled)
        await window.send()
        #expect(client.sent.isEmpty && window.phase == .idle)
        #expect(window.draft.outgoingRequest(id: UUID()) == nil)
    }

    @Test func replayOnOpenDoesNotSendPendingDraft() async throws {
        let (store, directory) = makeStore(); defer { try? FileManager.default.removeItem(at: directory) }
        let flow = try storedFlow(store, body: store.makeManagedBody(pattern(2 * mib)))
        let pending = try #require(ComposeDraft(from: flow).body.pendingImport)
        let draft = ComposeDraft(method: "GET", url: "https://api.test/x", body: .pending(pending))
        let client = FakeComposeClient()
        let window = ComposeViewModel(draft: draft, client: client)
        await window.replayOnOpen()
        #expect(client.sent.isEmpty && window.phase == .idle && window.notice != nil)
    }

    @Test func importReadsOnlyInBoundedChunks() async throws {
        let (store, directory) = makeStore(); defer { try? FileManager.default.removeItem(at: directory) }
        let size = 2 * mib + 123
        let flow = try storedFlow(store, body: store.makeManagedBody(pattern(size)))
        let files = StreamingComposeFiles()
        // The fake asks for 1 MiB at a time; the window must still read at most 64 KiB per call.
        files.ask(mib)
        let window = model(for: flow, store: store, files: files, leases: LeaseLog())
        await window.importCapturedBody()
        #expect(files.received == pattern(size))
        // Every chunk the window handed over was at most 64 KiB, however much was asked for.
        #expect(files.chunkSizes.max()! <= 65_536)
        #expect(files.requests.count == (size + 65_535) / 65_536)
        #expect(window.draft.body.file?.size == Int64(size))
    }

    @Test func importSuccessTurnsBodyIntoFile() async throws {
        let (store, directory) = makeStore(); defer { try? FileManager.default.removeItem(at: directory) }
        let size = 2 * mib
        let flow = try storedFlow(store, body: spilledBody(store, bytes: pattern(size)))
        let files = StreamingComposeFiles()
        files.hold(beforeRequest: 1)
        let leases = LeaseLog()
        let window = model(for: flow, store: store, files: files, leases: leases)
        #expect(window.importProgress == nil)

        let importing = Task { await window.importCapturedBody() }
        await files.waitUntilParked()
        let progress = try #require(window.importProgress)
        #expect(progress.total == Int64(size) && progress.done >= 0 && progress.done < progress.total)
        #expect(window.importProgressText?.isEmpty == false && window.importProgressText?.hasPrefix("compose.") == false)
        #expect(window.draft.body.mode == nil && !window.canSend)
        files.release()
        await importing.value

        #expect(window.importProgress == nil && window.importProgressText == nil)
        let file = try #require(files.imported.first)
        #expect(window.draft.body == .file(file) && file.size == Int64(size) && file.displayName == "request-body.bin")
        #expect(files.received == pattern(size))
        #expect(window.canSend)
        // The lease was released, and the finished asset belongs to this window.
        let lease = try #require(leases.all.first)
        await #expect(throws: HTTPBodyError.cancelled) { _ = try await lease.read(offset: 0, maxBytes: 1) }
        await window.close()
        #expect(files.discards == [[file.assetID]])
    }

    @Test func importOffsetsRespectSliceOffset() async throws {
        let (store, directory) = makeStore(); defer { try? FileManager.default.removeItem(at: directory) }
        let whole = pattern(3 * mib)
        let offset = 1_000, count = 2 * mib + 5
        let flow = try storedFlow(store, body: store.makeManagedBody(whole), offset: offset, count: count)
        let files = StreamingComposeFiles()
        let window = model(for: flow, store: store, files: files, leases: LeaseLog())
        await window.importCapturedBody()
        #expect(files.received == whole.subdata(in: offset..<offset + count))
        #expect(files.requests.first?.offset == 0)
        #expect(files.requests.map { Int($0.offset) + $0.maxBytes }.max()! <= count)
        #expect(files.chunkSizes.max()! <= 65_536)
        #expect(window.draft.body.file?.size == Int64(count))
    }

    @Test func evictedBodyBecomesImportFailedOmission() async throws {
        let (store, directory) = makeStore(); defer { try? FileManager.default.removeItem(at: directory) }
        // Cleared before the window starts copying: the lease cannot even be opened.
        let early = try storedFlow(store, body: store.makeManagedBody(pattern(2 * mib)))
        store.clear()
        let files = StreamingComposeFiles()
        let first = model(for: early, store: store, files: files, leases: LeaseLog())
        await first.importCapturedBody()
        #expect(first.draft.body == .omitted(.importFailed) && first.importProgress == nil)
        #expect(first.draft.body.omissionReason == ComposeBodyOmission.importFailed.localizedDescription)
        #expect(first.draft.validate().contains { $0.code == .bodyOmitted })

        // Cleared while the copy is running: the lease is revoked and the copy fails.
        let live = try storedFlow(store, body: store.makeManagedBody(pattern(2 * mib)))
        let parked = StreamingComposeFiles()
        parked.hold(beforeRequest: 2)
        let leases = LeaseLog()
        let second = model(for: live, store: store, files: parked, leases: leases)
        let importing = Task { await second.importCapturedBody() }
        await parked.waitUntilParked()
        store.clear()
        parked.release()
        await importing.value
        #expect(second.draft.body == .omitted(.importFailed) && second.importProgress == nil)
        #expect(parked.imported.isEmpty)
        let lease = try #require(leases.all.first)
        await #expect(throws: HTTPBodyError.self) { _ = try await lease.read(offset: 0, maxBytes: 1) }
    }

    @Test func closeCancelsImportAndDiscards() async throws {
        let (store, directory) = makeStore(); defer { try? FileManager.default.removeItem(at: directory) }
        let flow = try storedFlow(store, body: store.makeManagedBody(pattern(2 * mib)))

        // Closed while parked on the second chunk: the task ends, the lease is released, no asset exists.
        let files = StreamingComposeFiles()
        files.hold(beforeRequest: 1)
        let leases = LeaseLog()
        let window = model(for: flow, store: store, files: files, leases: leases)
        let importing = Task { await window.importCapturedBody() }
        await files.waitUntilParked()
        await window.close()
        await importing.value
        #expect(window.importProgress == nil && files.imported.isEmpty)
        let lease = try #require(leases.all.first)
        await #expect(throws: HTTPBodyError.cancelled) { _ = try await lease.read(offset: 0, maxBytes: 1) }
        #expect(files.requests.count <= 2)

        // A copy that still finishes after the window closed is discarded, once.
        let racing = StreamingComposeFiles()
        racing.holdBeforeReturning()
        let racingModel = model(for: flow, store: store, files: racing, leases: LeaseLog())
        let task = Task { await racingModel.importCapturedBody() }
        await racing.waitUntilParked()
        await racingModel.close()
        await task.value
        let finished = try #require(racing.imported.first)
        #expect(racing.discards == [[finished.assetID]])
        #expect(racingModel.draft.body.file == nil)
        await racingModel.close()
        #expect(racing.discards.count == 1)
    }

    @Test func userCancelOmitsBodyAndAnotherChoiceDiscardsTheCopy() async throws {
        let (store, directory) = makeStore(); defer { try? FileManager.default.removeItem(at: directory) }
        let flow = try storedFlow(store, body: store.makeManagedBody(pattern(2 * mib)))
        let files = StreamingComposeFiles()
        files.hold(beforeRequest: 1)
        let window = model(for: flow, store: store, files: files, leases: LeaseLog())
        let importing = Task { await window.importCapturedBody() }
        await files.waitUntilParked()
        window.cancelImport()
        await importing.value
        #expect(window.draft.body == .omitted(.importFailed) && window.importProgress == nil)

        // Switching to another body while it copies: the finished copy is thrown away.
        let racing = StreamingComposeFiles()
        racing.holdBeforeReturning()
        let other = model(for: flow, store: store, files: racing, leases: LeaseLog())
        let task = Task { await other.importCapturedBody() }
        await racing.waitUntilParked()
        let switched = other.draft.switchBody(to: .text)
        #expect(switched)
        racing.release()
        await task.value
        let finished = try #require(racing.imported.first)
        #expect(racing.discards == [[finished.assetID]] && other.draft.body == .text(""))
    }

    @Test func importDoesNothingForNonPendingDraftsOrWithoutFacades() async throws {
        let files = StreamingComposeFiles()
        let text = ComposeViewModel(draft: ComposeDraft(method: "POST", url: "https://h/", body: .text("x")), client: FakeComposeClient(),
                                    files: files, acquireBody: { _ in throw StreamingComposeFiles.Failure() })
        await text.importCapturedBody()
        #expect(text.draft.body == .text("x") && files.requests.isEmpty)

        // Without a body facade the pending body cannot be read: it is omitted, not left importing.
        let slice = HTTPBodySlice(ref: .memory(pattern(2 * mib)), offset: 0, count: 2 * mib)
        let pending = ComposeDraftBody.pending(CapturedBodyImport(slice: slice, displayName: "request-body.bin", size: Int64(slice.count)))
        let blind = ComposeViewModel(draft: ComposeDraft(method: "POST", url: "https://h/", body: pending), client: FakeComposeClient(), files: files)
        await blind.importCapturedBody()
        #expect(blind.draft.body == .omitted(.importFailed) && files.requests.isEmpty)
    }
}

private extension ComposeDraftBody {
    var pendingImport: CapturedBodyImport? {
        if case .pending(let captured) = self { captured } else { nil }
    }
}
