import FlowStore
import Foundation
import os
import Testing
@testable import AppCore

/// Records every import and discard; imports answer with a new asset each, or fail on demand.
final class FakeComposeBodyFiles: ComposeBodyFiles, Sendable {
    struct Failure: Error {}

    private struct State {
        var imported: [(url: URL, name: String, file: ComposeBodyFile)] = []
        var discards: [Set<UUID>] = []
        var failing = false
        var events: [String] = []
        var gated = false
        var held: [CheckedContinuation<Void, Never>] = []
        var arrivals: [CheckedContinuation<Void, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let size: Int64

    init(size: Int64 = 2048) {
        self.size = size
    }

    var importedFiles: [ComposeBodyFile] { state.withLock { $0.imported.map(\.file) } }
    var importedNames: [String] { state.withLock { $0.imported.map(\.name) } }
    var discards: [Set<UUID>] { state.withLock { $0.discards } }
    var events: [String] { state.withLock { $0.events } }

    func setFailing(_ failing: Bool) {
        state.withLock { $0.failing = failing }
    }

    func record(_ event: String) {
        state.withLock { $0.events.append(event) }
    }

    /// While gated, every import waits (after reaching the fake) until `releaseNext`.
    func setGated(_ gated: Bool) {
        state.withLock { $0.gated = gated }
    }

    /// Returns once `count` imports are held at the gate (no sleeping).
    func waitForHeld(_ count: Int) async {
        while state.withLock({ $0.held.count }) < count {
            await withCheckedContinuation { continuation in
                let ready = state.withLock { state -> Bool in
                    if state.held.count >= count { return true }
                    state.arrivals.append(continuation)
                    return false
                }
                if ready { continuation.resume() }
            }
        }
    }

    func releaseNext() {
        let next = state.withLock { $0.held.isEmpty ? nil : $0.held.removeFirst() }
        next?.resume()
    }

    func importFile(_ url: URL, displayName: String) async throws -> ComposeBodyFile {
        let gated = state.withLock { $0.gated }
        if gated {
            await withCheckedContinuation { continuation in
                let arrivals = state.withLock { state in
                    state.held.append(continuation)
                    defer { state.arrivals.removeAll() }
                    return state.arrivals
                }
                arrivals.forEach { $0.resume() }
            }
        }
        return try state.withLock { state in
            state.events.append("import")
            if state.failing { throw Failure() }
            let file = ComposeBodyFile(assetID: UUID(), displayName: displayName, size: size)
            state.imported.append((url, displayName, file))
            return file
        }
    }

    /// Not used by the file-body tests: drains the reader like a store would and answers a new asset.
    func importStream(
        expectedSize: Int64, displayName: String,
        read: @escaping @Sendable (Int64, Int) async throws -> Data
    ) async throws -> ComposeBodyFile {
        var copied: Int64 = 0
        while copied < expectedSize {
            let data = try await read(copied, Int(min(65_536, expectedSize - copied)))
            guard !data.isEmpty else { throw Failure() }
            copied += Int64(data.count)
        }
        return try state.withLock { state in
            state.events.append("importStream")
            if state.failing { throw Failure() }
            return ComposeBodyFile(assetID: UUID(), displayName: displayName, size: expectedSize)
        }
    }

    func discard(_ ids: Set<UUID>) async {
        state.withLock { state in
            state.events.append("discard")
            state.discards.append(ids)
        }
    }
}

private let report = URL(fileURLWithPath: "/Users/someone/Documents/report.pdf")
private let photo = URL(fileURLWithPath: "/Users/someone/Pictures/photo.png")

private func fileDraft(_ file: ComposeBodyFile) -> ComposeDraft {
    ComposeDraft(method: "POST", url: "https://h/upload", body: .file(file))
}

@MainActor @Suite(.timeLimit(.minutes(1)), .productionChinese) struct ComposeFileBodyTests {
    @Test func fileBodyBuildsAssetRequestWithEmptyData() throws {
        let file = ComposeBodyFile(assetID: UUID(), displayName: "report.pdf", size: 10)
        let request = try #require(fileDraft(file).outgoingRequest(id: UUID()))
        #expect(request.body == Data() && request.bodyAsset == file)
        let plain = try #require(ComposeDraft(method: "POST", url: "https://h/", body: .text("x")).outgoingRequest(id: UUID()))
        #expect(plain.bodyAsset == nil && plain.body == Data("x".utf8))
    }

    @Test func fileBodyIsNotInMemoryBytes() {
        let file = ComposeBodyFile(assetID: UUID(), displayName: "a", size: 1)
        let draft = fileDraft(file)
        #expect(draft.body.bytes == nil && draft.body.mode == .file)
        let codes = draft.validate().map(\.code)
        #expect(!codes.contains(.bodyOmitted) && !codes.contains(.invalidHex))
    }

    @Test func switchingFileToTextGivesEmptyBodyWithoutReadingFile() {
        let file = ComposeBodyFile(assetID: UUID(), displayName: "a", size: 1)
        var draft = fileDraft(file)
        #expect(draft.canSwitchBody(to: .text) && draft.canSwitchBody(to: .hex) && draft.canSwitchBody(to: .none))
        #expect(draft.switchBody(to: .text) && draft.body == .text(""))
        draft.body = .file(file)
        #expect(draft.switchBody(to: .hex) && draft.body == .hex(""))
        draft.body = .file(file)
        #expect(draft.switchBody(to: .none) && draft.body == ComposeDraftBody.none)
        draft.body = .file(file)
        #expect(draft.switchBody(to: .file) && draft.body == .file(file))
    }

    @Test func cannotSwitchToFileWithoutAttach() {
        for body in [ComposeDraftBody.none, .text("x"), .hex("00"), .omitted(.unreadable)] {
            var draft = ComposeDraft(method: "POST", url: "https://h/", body: body)
            #expect(!draft.canSwitchBody(to: .file))
            #expect(!draft.switchBody(to: .file) && draft.body == body)
        }
    }

    @Test func attachFileReplacesBodyAndDiscardsPreviousImport() async throws {
        let files = FakeComposeBodyFiles()
        let model = ComposeViewModel(draft: ComposeDraft(method: "POST", url: "https://h/", body: .text("old")),
                                     client: FakeComposeClient(), files: files, access: noScope)
        await model.attachFile(report)
        let first = try #require(files.importedFiles.first)
        #expect(model.draft.body == .file(first) && first.displayName == "report.pdf" && model.fileError == nil)
        #expect(files.discards.isEmpty)

        await model.attachFile(photo)
        let second = try #require(files.importedFiles.last)
        #expect(files.importedFiles.count == 2 && second.assetID != first.assetID)
        #expect(model.draft.body == .file(second))
        #expect(files.discards == [[first.assetID]])
    }

    @Test func attachFailureKeepsPreviousBodyAndReportsLocalizedError() async throws {
        let files = FakeComposeBodyFiles()
        let model = ComposeViewModel(draft: ComposeDraft(method: "POST", url: "https://h/", body: .text("keep")),
                                     client: FakeComposeClient(), files: files, access: noScope)
        files.setFailing(true)
        await model.attachFile(report)
        #expect(model.draft.body == .text("keep"))
        let message = try #require(model.fileError)
        #expect(!message.isEmpty && !message.hasPrefix("compose."))
        #expect(!model.isImportingFile && files.discards.isEmpty)

        // The next try starts clean, and a later failure keeps an attached file.
        files.setFailing(false)
        await model.attachFile(report)
        #expect(model.fileError == nil)
        let attached = model.draft.body
        files.setFailing(true)
        await model.attachFile(photo)
        #expect(model.draft.body == attached && model.fileError != nil && files.discards.isEmpty)
    }

    @Test func removeFileDiscardsAndClearsBody() async throws {
        let files = FakeComposeBodyFiles()
        let model = ComposeViewModel(draft: ComposeDraft(method: "POST", url: "https://h/"),
                                     client: FakeComposeClient(), files: files, access: noScope)
        await model.attachFile(report)
        let file = try #require(files.importedFiles.first)
        await model.removeFile()
        #expect(model.draft.body == ComposeDraftBody.none)
        #expect(files.discards == [[file.assetID]])
        // Nothing left to discard on close, and removing again does nothing.
        await model.removeFile()
        await model.close()
        #expect(files.discards.count == 1)
    }

    @Test func closeDiscardsEveryImportExactlyOnce() async throws {
        let files = FakeComposeBodyFiles()
        let model = ComposeViewModel(draft: ComposeDraft(method: "POST", url: "https://h/"),
                                     client: FakeComposeClient(), files: files, access: noScope)
        await model.attachFile(report)
        await model.attachFile(photo)
        let first = files.importedFiles[0], second = files.importedFiles[1]
        await model.close()
        #expect(files.discards == [[first.assetID], [second.assetID]])
        await model.close()
        #expect(files.discards.count == 2)
        // A closed window imports nothing more.
        await model.attachFile(report)
        #expect(files.importedFiles.count == 2)
    }

    @Test func captureNotOwnedByWindowIsNeverDiscarded() async throws {
        let carried = ComposeBodyFile(assetID: UUID(), displayName: "carried.bin", size: 5)
        let files = FakeComposeBodyFiles()
        let model = ComposeViewModel(draft: fileDraft(carried), client: FakeComposeClient(), files: files, access: noScope)
        await model.removeFile()
        #expect(model.draft.body == ComposeDraftBody.none && files.discards.isEmpty)

        model.draft.body = .file(carried)
        await model.attachFile(report)
        await model.close()
        let imported = try #require(files.importedFiles.first)
        #expect(files.discards == [[imported.assetID]])
        #expect(!files.discards.contains { $0.contains(carried.assetID) })

        let plain = ComposeViewModel(draft: fileDraft(carried), client: FakeComposeClient(), files: files, access: noScope)
        await plain.close()
        #expect(files.discards.count == 1)
    }

    @Test func sendWithFileBodyPassesAssetToClient() async throws {
        let client = FakeComposeClient(answering: ComposeOutcome(flowID: 1, delivery: .answered))
        let files = FakeComposeBodyFiles()
        let model = ComposeViewModel(draft: ComposeDraft(method: "POST", url: "https://h/upload"),
                                     client: client, files: files, access: noScope)
        await model.attachFile(report)
        let file = try #require(files.importedFiles.first)
        #expect(model.canSend)
        await model.send()
        let request = try #require(client.sent.first)
        #expect(request.bodyAsset == file && request.body == Data())
    }

    @Test func attachRunsInsideScopedAccess() async throws {
        let files = FakeComposeBodyFiles()
        let access = ScopedFileAccess(start: { _ in files.record("start"); return true }, stop: { _ in files.record("stop") })
        let model = ComposeViewModel(draft: ComposeDraft(), client: FakeComposeClient(), files: files, access: access)
        await model.attachFile(report)
        #expect(files.events == ["start", "import", "stop"])
        // A failing import still releases the scope.
        files.setFailing(true)
        await model.attachFile(photo)
        #expect(files.events == ["start", "import", "stop", "start", "import", "stop"])
    }

    @Test func noFilesFacadeShowsError() async throws {
        let model = ComposeViewModel(draft: ComposeDraft(method: "POST", url: "https://h/", body: .text("x")),
                                     client: FakeComposeClient(), access: noScope)
        await model.attachFile(report)
        let message = try #require(model.fileError)
        #expect(!message.isEmpty && !message.hasPrefix("compose."))
        #expect(model.draft.body == .text("x"))
        await model.close()
    }

    @Test func nonEmptyFileBodyWithoutContentTypeWarnsAndZeroSizeDoesNot() {
        let file = ComposeBodyFile(assetID: UUID(), displayName: "a.bin", size: 3)
        var draft = fileDraft(file)
        #expect(draft.validate().map(\.code) == [.missingContentType])
        // A Content-Type removes it; JSON checking stays text-only.
        draft.headers = [HeaderFieldRow(name: "Content-Type", value: "application/json")]
        #expect(draft.validate().isEmpty)
        // An empty file has no body to type.
        let empty = fileDraft(ComposeBodyFile(assetID: UUID(), displayName: "e", size: 0))
        #expect(empty.validate().isEmpty)
        // The warning never blocks sending.
        #expect(fileDraft(file).outgoingRequest(id: UUID()) != nil)
    }

    @Test func importFinishingAfterCloseIsDiscardedExactlyOnce() async throws {
        let files = FakeComposeBodyFiles()
        files.setGated(true)
        let model = ComposeViewModel(draft: ComposeDraft(method: "POST", url: "https://h/", body: .text("keep")),
                                     client: FakeComposeClient(), files: files, access: noScope)
        let attaching = Task { await model.attachFile(report) }
        await files.waitForHeld(1)
        await model.close()
        #expect(files.discards.isEmpty)
        files.releaseNext()
        await attaching.value
        let imported = try #require(files.importedFiles.first)
        #expect(files.discards == [[imported.assetID]])
        #expect(model.draft.body == .text("keep") && !model.isImportingFile)
        await model.close()
        #expect(files.discards.count == 1)
    }

    @Test func overlappingAttachIsIgnoredAndLeaksNothing() async throws {
        let files = FakeComposeBodyFiles()
        files.setGated(true)
        let model = ComposeViewModel(draft: ComposeDraft(method: "POST", url: "https://h/"),
                                     client: FakeComposeClient(), files: files, access: noScope)
        let first = Task { await model.attachFile(report) }
        await files.waitForHeld(1)
        #expect(model.isImportingFile)
        // A second choice while the first copy runs does nothing: no import, no discard.
        await model.attachFile(photo)
        #expect(files.importedFiles.isEmpty && files.discards.isEmpty)
        files.releaseNext()
        await first.value
        let attached = try #require(files.importedFiles.first)
        #expect(files.importedFiles.count == 1 && model.draft.body == .file(attached) && !model.isImportingFile)
        #expect(files.discards.isEmpty)
        await model.close()
        #expect(files.discards == [[attached.assetID]])
    }

    @Test func summaryNamesFileAndSize() {
        let file = ComposeBodyFile(assetID: UUID(), displayName: "report.pdf", size: 2048)
        #expect(file.summary.contains("report.pdf") && file.summary.contains("2"))
    }
}

private let noScope = ScopedFileAccess(start: { _ in false }, stop: { _ in })
