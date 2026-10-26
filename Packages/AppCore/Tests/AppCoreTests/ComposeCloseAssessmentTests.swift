import FlowStore
import Foundation
import os
import Testing
@testable import AppCore

// MARK: support

private let mib = 1_048_576

private func pattern(_ count: Int) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
}

private let okResponse = ComposeResponseSnapshot(
    status: 200, reason: "OK", headers: [], body: Data("ok".utf8), bodyBytes: 2, truncated: false, trailers: [])

private func capturedFlow(method: String = "GET", body: BodyRef? = nil, store: FlowStore? = nil) -> Flow {
    let target = HTTPMessageTarget(scheme: "https", host: "api.test", port: 443, method: method, pathAndQuery: "/x")
    let slice = body.map { HTTPBodySlice(ref: $0, offset: 0, count: $0.size) }
    var flow = Flow(id: 3, scheme: "https", method: method, host: "api.test", port: 443, path: "/x")
    flow.state = .completed
    flow.messages[.downstreamRequest] = HTTPMessageSnapshot(
        boundary: .downstreamRequest, head: .request(target, headers: [HeaderField(name: "Accept", value: "a")]), body: slice,
        bodyState: .complete, observedBytes: UInt64(slice?.count ?? 0), transferState: .finished)
    return flow
}

/// A flow the store references, so its managed body is live and can be leased.
@MainActor private func storedFlow(_ store: FlowStore, body: BodyRef) -> Flow {
    let template = capturedFlow(body: body)
    let id = store.begin { id in
        var flow = Flow(id: id, scheme: "https", method: "POST", host: "api.test", port: 443, path: "/x")
        flow.state = .completed
        flow.messages = template.messages
        return flow
    }
    return store.flow(id)!
}

private final class Leases: Sendable {
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

private let noAccess = ScopedFileAccess(start: { _ in false }, stop: { _ in })

// MARK: tests

@MainActor @Suite(.timeLimit(.minutes(1)), .productionChinese) struct ComposeCloseAssessmentTests {
    @Test func pristineBlankDraftNeedsNoConfirmation() {
        let model = ComposeViewModel(draft: ComposeDraft(), client: FakeComposeClient())
        #expect(model.closeAssessment == .none && !model.closeAssessment.needsConfirmation)
        #expect(ComposeCloseAssessment.none.messageKey == nil)
        for assessment in [ComposeCloseAssessment.confirmDiscard, .confirmCancelSend, .confirmBoth] {
            #expect(assessment.needsConfirmation && assessment.messageKey != nil)
        }
        #expect(ComposeCloseAssessment(isDirty: true, isInFlight: true) == .confirmBoth)
        #expect(ComposeCloseAssessment(isDirty: false, isInFlight: true) == .confirmCancelSend)
    }

    @Test func editingURLNeedsDiscardConfirmation() {
        let model = ComposeViewModel(draft: ComposeDraft(method: "GET", url: "https://h/a?x=1"), client: FakeComposeClient())
        #expect(model.closeAssessment == .none)
        model.setURL("https://h/b")
        #expect(model.closeAssessment == .confirmDiscard)
        // Back to the original text: nothing to lose any more.
        model.setURL("https://h/a?x=1")
        #expect(model.closeAssessment == .none)

        model.draft.method = "POST"
        #expect(model.closeAssessment == .confirmDiscard)
        model.draft.method = "GET"
        model.draft.headers.append(HeaderFieldRow(name: "X", value: "1"))
        #expect(model.closeAssessment == .confirmDiscard)
        model.draft.headers.removeAll()
        model.draft.body = .text("x")
        #expect(model.closeAssessment == .confirmDiscard)
        model.draft.body = .none
        model.draft.policy.applyRules = true
        #expect(model.closeAssessment == .confirmDiscard)
        model.draft.policy.applyRules = false
        // Query rows editing the URL count (and undoing them does not).
        _ = model.draft.appendQueryRow(name: "n", value: "v")
        #expect(model.closeAssessment == .confirmDiscard)
    }

    @Test func sendInFlightNeedsCancelSendConfirmation() async throws {
        let client = FakeComposeClient()
        let model = ComposeViewModel(draft: ComposeDraft(method: "GET", url: "https://h/"), client: client)
        let sending = Task { await model.send() }
        await client.waitForSends(1)
        // The frozen request is not an unsent edit.
        #expect(model.closeAssessment == .confirmCancelSend)
        let request = try #require(client.sent.first)
        client.finish(request.id, with: ComposeOutcome(flowID: 1, response: okResponse, delivery: .answered))
        await sending.value
        #expect(model.closeAssessment == .none)
    }

    @Test func editedAndSendingNeedsBoth() async throws {
        let client = FakeComposeClient()
        let model = ComposeViewModel(draft: ComposeDraft(method: "GET", url: "https://h/"), client: client)
        let sending = Task { await model.send() }
        await client.waitForSends(1)
        model.setURL("https://h/next")
        #expect(model.closeAssessment == .confirmBoth)
        let request = try #require(client.sent.first)
        client.finish(request.id, with: ComposeOutcome(flowID: 1, response: okResponse, delivery: .answered))
        await sending.value
        #expect(model.closeAssessment == .confirmDiscard)
    }

    @Test func sendResetsBaseline() async throws {
        let client = FakeComposeClient(answering: ComposeOutcome(flowID: 5, response: okResponse, delivery: .answered))
        let model = ComposeViewModel(draft: ComposeDraft(method: "POST", url: "https://h/"), client: client)
        model.setURL("https://h/changed")
        model.draft.body = .text("payload")
        #expect(model.closeAssessment == .confirmDiscard)
        await model.send()
        #expect(client.sent.count == 1 && model.phase == .done)
        // Closing right after a send needs no confirmation: the request is in the flow list.
        #expect(model.closeAssessment == .none)
        model.setURL("https://h/again")
        #expect(model.closeAssessment == .confirmDiscard)
        // A send that does not happen (draft with an error) leaves the baseline alone.
        model.setURL("not a url")
        await model.send()
        #expect(client.sent.count == 1 && model.closeAssessment == .confirmDiscard)
    }

    @Test func replayOpenedWindowIsPristine() async {
        let held = capturedFlow(method: "POST")
        let heldModel = ComposeViewModel(draft: ComposeDraft(from: held), client: FakeComposeClient())
        await heldModel.replayOnOpen()
        #expect(heldModel.notice != nil && heldModel.closeAssessment == .none)

        let safe = capturedFlow(method: "GET")
        let client = FakeComposeClient(answering: ComposeOutcome(flowID: 1, response: okResponse, delivery: .answered))
        let safeModel = ComposeViewModel(draft: ComposeDraft(from: safe), client: client)
        await safeModel.replayOnOpen()
        #expect(client.sent.count == 1 && safeModel.closeAssessment == .none)
        // An effective-request window is pristine too.
        #expect(ComposeViewModel(draft: ComposeDraft(from: safe, variant: .effective), client: client).closeAssessment == .none)
    }

    @Test func attachedFileCountsAsEdit() async throws {
        let file = ComposeBodyFile(assetID: UUID(), displayName: "a.zip", size: 10)
        let files = StreamingComposeFiles()
        let model = ComposeViewModel(draft: ComposeDraft(method: "POST", url: "https://h/"), client: FakeComposeClient(),
                                     files: files, access: noAccess)
        // Attach goes through the facade, which here only imports streams, so set the result the
        // way a successful attach does and remove it through the real call.
        model.draft.body = .file(file)
        #expect(model.closeAssessment == .confirmDiscard)
        await model.removeFile()
        #expect(model.draft.body == ComposeDraftBody.none && model.closeAssessment == .none)

        // A file that came with the draft is not an edit; removing it is.
        let carried = ComposeViewModel(draft: ComposeDraft(method: "POST", url: "https://h/", body: .file(file)),
                                       client: FakeComposeClient(), files: files, access: noAccess)
        #expect(carried.closeAssessment == .none)
        await carried.removeFile()
        #expect(carried.closeAssessment == .confirmDiscard)
    }

    @Test func attachingARealFileIsAnEditAndSendingMakesItBaseline() async throws {
        let imported = ComposeBodyFile(assetID: UUID(), displayName: "b.bin", size: 4)
        let files = ImportingFiles(result: imported)
        let client = FakeComposeClient(answering: ComposeOutcome(flowID: 1, response: okResponse, delivery: .answered))
        let model = ComposeViewModel(draft: ComposeDraft(method: "POST", url: "https://h/"), client: client, files: files, access: noAccess)
        await model.attachFile(URL(fileURLWithPath: "/nonexistent/b.bin"))
        #expect(model.draft.body == .file(imported) && model.closeAssessment == .confirmDiscard)
        await model.send()
        #expect(model.closeAssessment == .none)
    }

    @Test func importInProgressNeedsCancelConfirmation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pw-close-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FlowStore(bodyDirectory: directory)
        let flow = storedFlow(store, body: store.makeManagedBody(pattern(2 * mib)))
        let files = StreamingComposeFiles()
        files.hold(beforeRequest: 1)
        let model = ComposeViewModel(draft: ComposeDraft(from: flow), client: FakeComposeClient(), files: files, access: noAccess,
                                     acquireBody: Leases().acquire(from: store))
        // A captured body waiting to be copied is part of the draft as it was opened.
        #expect(model.draft.body.mode == nil && model.closeAssessment == .none)
        let importing = Task { await model.importCapturedBody() }
        await files.waitUntilParked()
        #expect(model.closeAssessment == .confirmCancelSend)
        files.release()
        await importing.value
        // The copy arrived with the draft: it is not an edit.
        let file = try #require(model.draft.body.file)
        #expect(files.imported == [file] && model.closeAssessment == .none)
        await model.close()
    }

    @Test func failedOrCancelledImportIsNotAnEdit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pw-close-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FlowStore(bodyDirectory: directory)
        let flow = storedFlow(store, body: store.makeManagedBody(pattern(2 * mib)))
        let files = StreamingComposeFiles()
        files.hold(beforeRequest: 1)
        let model = ComposeViewModel(draft: ComposeDraft(from: flow), client: FakeComposeClient(), files: files, access: noAccess,
                                     acquireBody: Leases().acquire(from: store))
        let importing = Task { await model.importCapturedBody() }
        await files.waitUntilParked()
        model.cancelImport()
        await importing.value
        #expect(model.draft.body == .omitted(.importFailed) && model.closeAssessment == .none)
        // Choosing another body is an edit.
        let switched = model.draft.switchBody(to: .text)
        #expect(switched)
        #expect(model.closeAssessment == .confirmDiscard)
    }

    @Test func closeConfirmedCancelsSendAndDiscardsImports() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pw-close-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FlowStore(bodyDirectory: directory)
        let flow = storedFlow(store, body: store.makeManagedBody(pattern(2 * mib)))
        let files = StreamingComposeFiles()
        let leases = Leases()
        let client = FakeComposeClient()
        let model = ComposeViewModel(draft: ComposeDraft(from: flow), client: client, files: files, access: noAccess,
                                     acquireBody: leases.acquire(from: store))
        // The imported copy is window-owned; start a send with it, then confirm closing.
        await model.importCapturedBody()
        let file = try #require(model.draft.body.file)
        let sending = Task { await model.send() }
        await client.waitForSends(1)
        let request = try #require(client.sent.first)
        #expect(model.closeAssessment == .confirmCancelSend)

        await model.closeConfirmed()
        #expect(client.cancelled == [request.id])
        #expect(files.discards == [[file.assetID]])
        let failure = ComposeOutcomeFailure(code: "compose.cancelled", message: "x", isCancellation: true)
        client.finish(request.id, with: ComposeOutcome(flowID: 4, failure: failure, delivery: .unknown))
        await sending.value

        // A running import is cancelled and waited for, and no asset is left.
        let parked = StreamingComposeFiles()
        parked.hold(beforeRequest: 1)
        let leaseLog = Leases()
        let importer = ComposeViewModel(draft: ComposeDraft(from: flow), client: FakeComposeClient(), files: parked, access: noAccess,
                                        acquireBody: leaseLog.acquire(from: store))
        let importing = Task { await importer.importCapturedBody() }
        await parked.waitUntilParked()
        await importer.closeConfirmed()
        await importing.value
        #expect(parked.imported.isEmpty && importer.importProgress == nil)
        let lease = try #require(leaseLog.all.first)
        await #expect(throws: HTTPBodyError.cancelled) { _ = try await lease.read(offset: 0, maxBytes: 1) }
    }

    @Test func closeConfirmedIsIdempotent() async throws {
        let files = StreamingComposeFiles()
        let file = ComposeBodyFile(assetID: UUID(), displayName: "a", size: 1)
        let client = FakeComposeClient()
        let model = ComposeViewModel(draft: ComposeDraft(method: "POST", url: "https://h/"), client: client, files: files, access: noAccess)
        // Nothing running, nothing owned: closing twice does nothing at all.
        await model.closeConfirmed()
        await model.closeConfirmed()
        #expect(client.cancelled.isEmpty && files.discards.isEmpty)

        let owner = ImportingFiles(result: file)
        let attached = ComposeViewModel(draft: ComposeDraft(method: "POST", url: "https://h/"), client: client, files: owner, access: noAccess)
        await attached.attachFile(URL(fileURLWithPath: "/nonexistent/a"))
        await attached.closeConfirmed()
        await attached.closeConfirmed()
        await attached.close()
        #expect(owner.discards == [[file.assetID]])
        // A closed window sends nothing any more.
        attached.setURL("https://h/")
        await attached.send()
        #expect(client.sent.isEmpty)
    }
}

/// Imports a chosen file as `result` at once and records discards.
private final class ImportingFiles: ComposeBodyFiles, Sendable {
    let result: ComposeBodyFile
    private let log = OSAllocatedUnfairLock(initialState: [Set<UUID>]())
    init(result: ComposeBodyFile) { self.result = result }
    var discards: [Set<UUID>] { log.withLock { $0 } }
    func importFile(_ url: URL, displayName: String) async throws -> ComposeBodyFile { result }
    func importStream(expectedSize: Int64, displayName: String,
                      read: @escaping @Sendable (Int64, Int) async throws -> Data) async throws -> ComposeBodyFile { result }
    func discard(_ ids: Set<UUID>) async { log.withLock { $0.append(ids) } }
}
