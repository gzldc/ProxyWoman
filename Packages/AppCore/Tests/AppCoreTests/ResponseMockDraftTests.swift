import FlowStore
import Foundation
import Localization
import os
import RulesEngine
import Testing
@testable import AppCore

// MARK: support

private let mib = 1_048_576

private func pattern(_ count: Int, seed: UInt8 = 11) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 29 &+ Int(seed)) })
}

private func field(_ name: String, _ value: String) -> HeaderField { HeaderField(name: name, value: value) }

private let originalTarget = HTTPMessageTarget(
    scheme: "https", host: "api.test", port: 8443, method: "GET", pathAndQuery: "/v1/Items%2Fa?id=1&id=2&ID=%7e")

/// A flow the store references (so a managed body is live and can be revoked by `clear()`).
@MainActor private func mockFlow(
    _ store: FlowStore, body: BodyRef?, offset: Int = 0, count: Int? = nil, status: Int = 200,
    headers: [HeaderField] = [field("Content-Type", "application/json")], target: HTTPMessageTarget = originalTarget,
    legacy: (host: String, path: String)? = nil, method: String = "GET", state: FlowState = .completed
) throws -> Flow {
    let slice = body.map { HTTPBodySlice(ref: $0, offset: offset, count: count ?? $0.size - offset) }
    let id = store.begin { id in
        var flow = Flow(id: id, scheme: "https", method: method, host: legacy?.host ?? target.host, port: target.port,
                        path: legacy?.path ?? target.pathAndQuery)
        flow.state = state
        flow.messages = [
            .downstreamRequest: HTTPMessageSnapshot(
                boundary: .downstreamRequest, head: .request(target, headers: []), bodyState: .complete, transferState: .finished),
            .downstreamResponse: HTTPMessageSnapshot(
                boundary: .downstreamResponse, head: .response(status: status, reason: nil, headers: headers), body: slice,
                bodyState: .complete, observedBytes: UInt64(slice?.count ?? 0), transferState: .finished),
        ]
        return flow
    }
    return try #require(store.flow(id))
}

private func makeStore() -> (FlowStore, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pw-mock-\(UUID().uuidString)")
    return (FlowStore(bodyDirectory: directory), directory)
}

private func spilledBody(_ store: FlowStore, bytes: Data) throws -> BodyRef {
    let capture = store.makeBodyCapture()
    capture.append(bytes)
    return try #require(capture.finish().body)
}

/// Remembers every lease opened for the copy, so a test can see it was released.
private final class MockLeaseLog: Sendable {
    private let leases = OSAllocatedUnfairLock(initialState: [HTTPBodyReadLease]())
    var all: [HTTPBodyReadLease] { leases.withLock { $0 } }
    func acquire(from store: FlowStore) -> BodyLeaseAcquirer {
        { [self] ref in
            let lease = try store.acquireBody(ref)
            leases.withLock { $0.append(lease) }
            return lease
        }
    }
}

/// Sits between the real asset store and the editor's `read` closure. It asks for far more than the
/// store would, so only the editor's own bound keeps a chunk small; can park before a chosen read.
private final class StreamProbe: Sendable {
    private struct State {
        var offsets: [Int64] = []
        var sizes: [Int] = []
        var received = Data()
        var holdBeforeRead: Int?
        var asked = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let reachedStream = AsyncStream<Void>.makeStream()
    private let releaseStream = AsyncStream<Void>.makeStream()

    var offsets: [Int64] { state.withLock { $0.offsets } }
    var sizes: [Int] { state.withLock { $0.sizes } }
    var received: Data { state.withLock { $0.received } }
    var reads: Int { state.withLock { $0.sizes.count } }
    func hold(beforeRead index: Int) { state.withLock { $0.holdBeforeRead = index } }
    func release() { releaseStream.continuation.yield() }

    /// Returns when the copy is parked at its hold point.
    func waitUntilParked() async {
        var iterator = reachedStream.stream.makeAsyncIterator()
        await iterator.next()
    }

    func wrap(_ client: inout RulesRepositoryClient) {
        let real = client.importStream
        client.importStream = { size, name, read in
            try await real(size, name) { [self] offset, _ in
                let index = state.withLock { state -> Int in
                    state.offsets.append(offset)
                    state.asked += 1
                    return state.asked - 1
                }
                if state.withLock({ $0.holdBeforeRead }) == index {
                    reachedStream.continuation.yield()
                    var iterator = releaseStream.stream.makeAsyncIterator()
                    // A cancelled task wakes up with nil: the hold ends without a release.
                    await iterator.next()
                }
                let data = try await read(offset, 4 * mib)
                state.withLock { $0.sizes.append(data.count); $0.received.append(data) }
                return data
            }
        }
    }
}

@MainActor private func waitUntil(_ what: Comment, _ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else {
            Issue.record(what)
            return
        }
        await Task.yield()
    }
}

@MainActor private func loadedModel(_ fixture: RulesFixture, probe: StreamProbe? = nil) async -> RulesEditorModel {
    var client = fixture.client()
    probe?.wrap(&client)
    let model = RulesEditorModel(client: client, limits: RulesLimits())
    await model.load()
    return model
}

private func headerPairs(_ rows: [HeaderFieldRow]?) -> [HeaderField]? {
    rows?.map { HeaderField(name: $0.name, value: $0.value) }
}

// MARK: tests

@MainActor @Suite(.timeLimit(.minutes(2)), .productionChinese) struct ResponseMockDraftTests {
    @Test func mockDraftHasMatcherFromOriginalFullURL() async throws {
        let (store, directory) = makeStore(); defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = RulesFixture(); defer { fixture.remove() }
        let flow = try mockFlow(store, body: store.makeManagedBody(Data("{}".utf8)))
        let model = await loadedModel(fixture)
        #expect(await model.beginMockDraft(from: flow, acquireBody: MockLeaseLog().acquire(from: store)) == nil)
        let draft = try #require(model.draft)
        #expect(draft.kind == .mapLocal && model.isDraftNew)
        let expected = RuleEditorDraft.fromFlow(flow, kind: .mapLocal).match
        #expect(draft.match == expected)
        #expect(draft.match.scheme == .https && draft.match.host == "api.test" && draft.match.port == "8443")
        #expect(draft.match.method == "GET" && draft.match.pathMode == .exact)
        // Duplicate parameters, their order, case and the percent spelling are kept as captured.
        #expect(draft.match.path == "/v1/Items%2Fa?id=1&id=2&ID=%7e")
    }

    @Test func mockDraftCanBeDeliveredToTheEditorSessionInstead() async throws {
        let (store, directory) = makeStore(); defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = RulesFixture(); defer { fixture.remove() }
        let flow = try mockFlow(store, body: store.makeManagedBody(Data("{}".utf8)))
        let model = await loadedModel(fixture)
        var delivered: RuleEditorDraft?
        #expect(await model.beginMockDraft(from: flow, acquireBody: MockLeaseLog().acquire(from: store)) { delivered = $0 } == nil)
        // The model keeps no draft of its own, and the copied file stays for whoever took the draft.
        let draft = try #require(delivered)
        #expect(model.draft == nil && draft.kind == .mapLocal && fixture.assetFiles().count == 1)
        let session = RuleEditorSession(model: model)
        session.openSeed(draft)
        #expect(session.isNew && session.document?.actions.first?.file.asset == draft.mapLocal.asset)
        session.discard()
        await session.settled()
        #expect(fixture.assetFiles().isEmpty)
    }

    @Test func mockDraftNeverUsesRemappedTarget() async throws {
        let (store, directory) = makeStore(); defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = RulesFixture(); defer { fixture.remove() }
        // The recorded (legacy) fields describe a Map Remote target; the client asked for api.test.
        let flow = try mockFlow(store, body: nil, legacy: (host: "mapped.test", path: "/other"))
        #expect(flow.host == "mapped.test")
        let model = await loadedModel(fixture)
        #expect(await model.beginMockDraft(from: flow, acquireBody: nil) == nil)
        let draft = try #require(model.draft)
        #expect(draft.match.host == "api.test" && draft.match.path == originalTarget.pathAndQuery)
        #expect(draft.name == L10n.format("rules.mock.draftName", "api.test"))
        #expect(draft.name.contains("api.test") && !draft.name.hasPrefix("rules."))
    }

    @Test func mockDraftCarriesStatusAndFilteredHeaders() async throws {
        let (store, directory) = makeStore(); defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = RulesFixture(); defer { fixture.remove() }
        let headers = [
            field("Connection", "keep-alive"), field("Set-Cookie", "a=1"), field("Content-Length", "2"),
            field("Content-Type", "application/json"), field("Transfer-Encoding", "chunked"), field("Set-Cookie", "b=2"),
            field("Cache-Control", "no-store"),
        ]
        let flow = try mockFlow(store, body: store.makeManagedBody(Data("{}".utf8)), status: 404, headers: headers)
        let model = await loadedModel(fixture)
        #expect(await model.beginMockDraft(from: flow, acquireBody: MockLeaseLog().acquire(from: store)) == nil)
        let draft = try #require(model.draft)
        #expect(draft.mapLocal.status == "404")
        #expect(headerPairs(draft.mapLocal.headers) == [
            field("Set-Cookie", "a=1"), field("Content-Type", "application/json"), field("Set-Cookie", "b=2"),
            field("Cache-Control", "no-store"),
        ])
        let asset = try #require(draft.mapLocal.asset)
        #expect(asset.size == 2 && asset.displayName == "response-body.bin")
        // The headers carry the type; the file name must not add a second Content-Type.
        #expect(draft.mapLocal.headers.filter { $0.name == "Content-Type" }.count == 1)
    }

    @Test func largeBodyIsCopiedInBoundedChunks() async throws {
        let (store, directory) = makeStore(); defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = RulesFixture(); defer { fixture.remove() }
        let whole = pattern(3 * mib)
        let offset = 1_000, count = 2 * mib + 123
        let flow = try mockFlow(store, body: store.makeManagedBody(whole), offset: offset, count: count)
        let probe = StreamProbe()
        let model = await loadedModel(fixture, probe: probe)
        #expect(await model.beginMockDraft(from: flow, acquireBody: MockLeaseLog().acquire(from: store)) == nil)
        // The probe asked for 4 MiB every time; the editor handed back at most 64 KiB, never past the slice.
        #expect(probe.sizes.max()! <= 65_536)
        #expect(probe.reads == (count + 65_535) / 65_536)
        #expect(probe.offsets.first == 0)
        #expect(probe.received == whole.subdata(in: offset..<offset + count))
        let asset = try #require(model.draft?.mapLocal.asset)
        #expect(asset.size == Int64(count))
        #expect(fixture.assetFiles() == [asset.id.uuidString + ".asset"])
    }

    @Test func spooledBodyOnDiskIsCopiedWithoutLoadingWhole() async throws {
        let (store, directory) = makeStore(); defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = RulesFixture(); defer { fixture.remove() }
        let size = 2 * mib
        let bytes = pattern(size, seed: 3)
        let flow = try mockFlow(store, body: spilledBody(store, bytes: bytes))
        let probe = StreamProbe()
        let model = await loadedModel(fixture, probe: probe)
        #expect(await model.beginMockDraft(from: flow, acquireBody: MockLeaseLog().acquire(from: store)) == nil)
        #expect(probe.reads == size / 65_536 && Set(probe.sizes) == [65_536])
        #expect(probe.received == bytes)
        #expect(model.draft?.mapLocal.asset?.size == Int64(size))

        // A borrowed on-disk file is read the same way.
        let file = directory.appendingPathComponent("borrowed.body")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.write(to: file)
        let borrowed = try mockFlow(store, body: .file(file, size: size))
        let second = await loadedModel(fixture, probe: probe)
        #expect(await second.beginMockDraft(from: borrowed, acquireBody: MockLeaseLog().acquire(from: store)) == nil)
        #expect(probe.reads == 2 * (size / 65_536) && probe.sizes.max()! <= 65_536)
    }

    @Test func importedAssetIsSessionImportAndDiscardedWithDraft() async throws {
        let (store, directory) = makeStore(); defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = RulesFixture(); defer { fixture.remove() }
        let flow = try mockFlow(store, body: store.makeManagedBody(Data("body".utf8)))
        let model = await loadedModel(fixture)
        #expect(await model.beginMockDraft(from: flow, acquireBody: MockLeaseLog().acquire(from: store)) == nil)
        let asset = try #require(model.draft?.mapLocal.asset)
        #expect(fixture.assetFiles() == [asset.id.uuidString + ".asset"])
        #expect(model.isDraftDirty)
        // Abandoning the unsaved draft drops its copy.
        model.discardChanges()
        #expect(model.draft == nil)
        try await waitUntil("abandoned mock copy discarded") { fixture.assetFiles().isEmpty }
    }

    @Test func savedRuleKeepsAsset() async throws {
        let (store, directory) = makeStore(); defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = RulesFixture(); defer { fixture.remove() }
        let flow = try mockFlow(store, body: store.makeManagedBody(Data("kept".utf8)), status: 201)
        let model = await loadedModel(fixture)
        #expect(await model.beginMockDraft(from: flow, acquireBody: MockLeaseLog().acquire(from: store)) == nil)
        let asset = try #require(model.draft?.mapLocal.asset)
        #expect(model.canSave)
        #expect(await model.save())
        #expect(!model.isDraftDirty)
        guard case .mapLocal(let action) = model.rules.first?.action else { Issue.record("not a Map Local rule"); return }
        #expect(action.assetID == asset.id && action.status == 201)
        // Leaving the saved draft does not discard the copy the rule uses.
        model.discardChanges()
        model.requestSelection(nil)
        for _ in 0..<50 { await Task.yield() }
        #expect(fixture.assetFiles() == [asset.id.uuidString + ".asset"])
        #expect(model.reusableAssets == [asset])
    }

    @Test func blockedFlowReturnsReasonAndCreatesNoDraft() async throws {
        let (store, directory) = makeStore(); defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = RulesFixture(); defer { fixture.remove() }
        let model = await loadedModel(fixture)
        let acquired = CallCounter()
        let acquire: BodyLeaseAcquirer = { ref in acquired.increment(); return try store.acquireBody(ref) }

        let upgrade = try mockFlow(store, body: nil, status: 101)
        #expect(await model.beginMockDraft(from: upgrade, acquireBody: acquire) == .upgrade)
        let tunnel = try mockFlow(store, body: nil, method: "CONNECT", state: .tunnel)
        #expect(await model.beginMockDraft(from: tunnel, acquireBody: acquire) == .tunnel)
        let big = try mockFlow(store, body: store.makeManagedBody(Data("x".utf8)), status: 100)
        #expect(await model.beginMockDraft(from: big, acquireBody: acquire) == .statusNotMockable)
        #expect(model.draft == nil && model.selection == nil && model.error == nil)
        #expect(model.importState == .idle && model.mockImportProgress == nil)
        #expect(acquired.value == 0 && fixture.assetFiles().isEmpty)
        for reason in MockBlockReason.allCases {
            #expect(reason.localizationKey == "rules.mock.blocked." + reason.rawValue)
            #expect(!reason.localizedDescription.isEmpty && !reason.localizedDescription.hasPrefix("rules."))
        }
    }

    @Test func revokedLeaseFailsWithImportErrorAndNoDraft() async throws {
        let (store, directory) = makeStore(); defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = RulesFixture(); defer { fixture.remove() }

        // Cleared before the copy starts: the lease cannot even be opened.
        let early = try mockFlow(store, body: store.makeManagedBody(pattern(2 * mib)))
        store.clear()
        let model = await loadedModel(fixture)
        #expect(await model.beginMockDraft(from: early, acquireBody: MockLeaseLog().acquire(from: store)) == nil)
        #expect(model.error == .importFailed(.ioFailure))
        #expect(model.draft == nil && model.importState == .idle && model.mockImportProgress == nil)
        #expect(fixture.assetFiles().isEmpty)

        // Cleared while the copy runs: the lease is revoked mid-way and the partial copy is removed.
        model.dismissError()
        let live = try mockFlow(store, body: store.makeManagedBody(pattern(2 * mib)))
        let probe = StreamProbe()
        probe.hold(beforeRead: 2)
        let parked = await loadedModel(fixture, probe: probe)
        let leases = MockLeaseLog()
        let running = Task { await parked.beginMockDraft(from: live, acquireBody: leases.acquire(from: store)) }
        await probe.waitUntilParked()
        store.clear()
        probe.release()
        #expect(await running.value == nil)
        #expect(parked.error == .importFailed(.ioFailure))
        #expect(parked.draft == nil && parked.importState == .idle && parked.mockImportProgress == nil)
        #expect(fixture.assetFiles().isEmpty)
        let lease = try #require(leases.all.first)
        await #expect(throws: HTTPBodyError.self) { _ = try await lease.read(offset: 0, maxBytes: 1) }
    }

    @Test func missingAcquirerForNonEmptyBodyFails() async throws {
        let (store, directory) = makeStore(); defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = RulesFixture(); defer { fixture.remove() }
        let flow = try mockFlow(store, body: store.makeManagedBody(Data("x".utf8)))
        let model = await loadedModel(fixture)
        #expect(await model.beginMockDraft(from: flow, acquireBody: nil) == nil)
        #expect(model.error == .importFailed(.ioFailure) && model.draft == nil && fixture.assetFiles().isEmpty)
    }

    @Test func cancelStopsImportAndLeavesNoAsset() async throws {
        let (store, directory) = makeStore(); defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = RulesFixture(); defer { fixture.remove() }
        let flow = try mockFlow(store, body: store.makeManagedBody(pattern(2 * mib)))
        let probe = StreamProbe()
        probe.hold(beforeRead: 1)
        let model = await loadedModel(fixture, probe: probe)
        let leases = MockLeaseLog()
        let running = Task { await model.beginMockDraft(from: flow, acquireBody: leases.acquire(from: store)) }
        await probe.waitUntilParked()
        #expect(model.importState == .importing)
        model.cancelMockImport()
        #expect(model.importState == .idle && model.mockImportProgress == nil)
        probe.release()
        #expect(await running.value == nil)
        #expect(model.draft == nil && model.error == nil && model.importState == .idle)
        #expect(probe.reads <= 2)
        #expect(fixture.assetFiles().isEmpty)
        let lease = try #require(leases.all.first)
        await #expect(throws: HTTPBodyError.cancelled) { _ = try await lease.read(offset: 0, maxBytes: 1) }
    }

    @Test func leaseAlwaysCancelled() async throws {
        let (store, directory) = makeStore(); defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = RulesFixture(); defer { fixture.remove() }
        let leases = MockLeaseLog()
        let model = await loadedModel(fixture)
        let flow = try mockFlow(store, body: store.makeManagedBody(pattern(200_000)))
        #expect(await model.beginMockDraft(from: flow, acquireBody: leases.acquire(from: store)) == nil)
        #expect(model.draft != nil)
        let lease = try #require(leases.all.first)
        await #expect(throws: HTTPBodyError.cancelled) { _ = try await lease.read(offset: 0, maxBytes: 1) }
        // A body the extractor refuses never opens a lease at all.
        var limits = RulesLimits()
        limits.assetFileBytes = 10
        let tight = RulesFixture(); defer { tight.remove() }
        let tightModel = RulesEditorModel(client: tight.client(), limits: limits)
        await tightModel.load()
        #expect(await tightModel.beginMockDraft(from: flow, acquireBody: leases.acquire(from: store)) == .bodyTooLarge)
        #expect(leases.all.count == 1)
    }

    @Test func dirtyDraftAsksConfirmationBeforeReplacing() async throws {
        let (store, directory) = makeStore(); defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = RulesFixture(); defer { fixture.remove() }
        let flow = try mockFlow(store, body: store.makeManagedBody(Data("mock".utf8)))
        let model = await loadedModel(fixture)
        model.beginDraft(kind: .editHeaders)
        let dirty = try #require(model.draft)
        #expect(model.isDraftDirty)

        #expect(await model.beginMockDraft(from: flow, acquireBody: MockLeaseLog().acquire(from: store)) == nil)
        // The unsaved draft stays until the user confirms; the mock waits as the pending navigation.
        #expect(model.draft == dirty)
        guard case .draft(let pending) = model.pendingNavigation else { Issue.record("no pending navigation"); return }
        #expect(pending.kind == .mapLocal && pending.mapLocal.asset != nil)
        let asset = try #require(pending.mapLocal.asset)
        #expect(fixture.assetFiles() == [asset.id.uuidString + ".asset"])

        // Declining drops the waiting copy.
        model.cancelPendingNavigation()
        #expect(model.draft == dirty && model.pendingNavigation == nil)
        try await waitUntil("declined mock copy discarded") { fixture.assetFiles().isEmpty }

        // Confirming replaces the draft; the copy now belongs to it and goes when the draft is abandoned.
        #expect(await model.beginMockDraft(from: flow, acquireBody: MockLeaseLog().acquire(from: store)) == nil)
        guard case .draft(let again) = model.pendingNavigation, let second = again.mapLocal.asset else {
            Issue.record("no pending navigation"); return
        }
        model.confirmPendingNavigation()
        #expect(model.draft == again && model.pendingNavigation == nil)
        #expect(fixture.assetFiles() == [second.id.uuidString + ".asset"])
        model.discardChanges()
        try await waitUntil("replaced draft's mock copy discarded") { fixture.assetFiles().isEmpty }
    }

    @Test func emptyBodyStillCreatesZeroByteAsset() async throws {
        let (store, directory) = makeStore(); defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = RulesFixture(); defer { fixture.remove() }
        let flow = try mockFlow(store, body: nil, status: 204, headers: [field("X-Empty", "1")])
        let model = await loadedModel(fixture)
        let acquired = CallCounter()
        let acquire: BodyLeaseAcquirer = { ref in acquired.increment(); return try store.acquireBody(ref) }
        #expect(await model.beginMockDraft(from: flow, acquireBody: acquire) == nil)
        let asset = try #require(model.draft?.mapLocal.asset)
        #expect(asset.size == 0 && model.draft?.mapLocal.status == "204")
        #expect(fixture.assetFiles() == [asset.id.uuidString + ".asset"])
        #expect(acquired.value == 0)
        #expect(await model.save())
    }

    @Test func importProgressReportedThenNil() async throws {
        let (store, directory) = makeStore(); defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = RulesFixture(); defer { fixture.remove() }
        let size = 2 * mib
        let flow = try mockFlow(store, body: store.makeManagedBody(pattern(size)))
        let probe = StreamProbe()
        probe.hold(beforeRead: 3)
        let model = await loadedModel(fixture, probe: probe)
        #expect(model.mockImportProgress == nil)
        let running = Task { await model.beginMockDraft(from: flow, acquireBody: MockLeaseLog().acquire(from: store)) }
        await probe.waitUntilParked()
        let progress = try #require(model.mockImportProgress)
        #expect(progress.total == Int64(size) && progress.done >= 0 && progress.done < progress.total)
        #expect(model.mockImportProgressText?.isEmpty == false && model.mockImportProgressText?.hasPrefix("rules.") == false)
        probe.release()
        #expect(await running.value == nil)
        #expect(model.mockImportProgress == nil && model.mockImportProgressText == nil && model.draft != nil)
    }

    @Test func cannotSaveWhileImporting() async throws {
        let (store, directory) = makeStore(); defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = RulesFixture(); defer { fixture.remove() }
        let flow = try mockFlow(store, body: store.makeManagedBody(pattern(mib)))
        let probe = StreamProbe()
        probe.hold(beforeRead: 1)
        let model = await loadedModel(fixture, probe: probe)
        model.beginDraft(kind: .editHeaders)
        let running = Task { await model.beginMockDraft(from: flow, acquireBody: MockLeaseLog().acquire(from: store)) }
        await probe.waitUntilParked()
        #expect(model.importState == .importing && !model.isBusy && model.canMutate)
        #expect(!model.canSave)
        #expect(await model.save() == false)
        probe.release()
        #expect(await running.value == nil)
        #expect(model.importState == .idle)
    }

    @Test func mockRuleMatchesTheFlowAfterSaveRoundTrip() async throws {
        let (store, directory) = makeStore(); defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = RulesFixture(); defer { fixture.remove() }
        let flow = try mockFlow(
            store, body: store.makeManagedBody(Data("{\"ok\":true}".utf8)), status: 200,
            headers: [field("Content-Type", "application/json"), field("Set-Cookie", "a=1"), field("Set-Cookie", "b=2")])
        let model = await loadedModel(fixture)
        #expect(await model.beginMockDraft(from: flow, acquireBody: MockLeaseLog().acquire(from: store)) == nil)
        #expect(await model.save())

        let reloaded = try await RulesFixture(root: fixture.root).repository.load()
        let rule = try #require(reloaded.rules.first)
        #expect(rule.matcher.matches(originalTarget, status: nil))
        var other = originalTarget
        other.pathAndQuery = "/v1/Items%2Fa?id=1&id=2&ID=%7E"
        #expect(!rule.matcher.matches(other, status: nil))
        other = originalTarget
        other.method = "POST"
        #expect(!rule.matcher.matches(other, status: nil))
        guard case .mapLocal(let action) = rule.action else { Issue.record("not a Map Local rule"); return }
        #expect(action.status == 200)
        #expect(action.headers == [field("Content-Type", "application/json"), field("Set-Cookie", "a=1"), field("Set-Cookie", "b=2")])
    }
}
