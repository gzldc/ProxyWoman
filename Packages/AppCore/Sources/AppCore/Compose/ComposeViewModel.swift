import FlowStore
import Foundation
import Localization
import Observation

/// What the response area shows for one finished send.
public struct ComposeResultPresentation: Equatable, Sendable, Identifiable {
    public static let messageKeys = [
        "compose.response.partial", "compose.response.deliveryUnknown", "compose.response.summary",
        "compose.response.truncated",
    ]
    /// The label of a response that ended early: what arrived is shown, never as complete.
    public static var partialText: String { L10n.string("compose.response.partial") }
    public static var deliveryUnknownText: String { L10n.string("compose.response.deliveryUnknown") }

    /// The send this is the result of (a new one for every Send).
    public var id: UUID
    /// The recorded flow, for "show in flow list".
    public var flowID: Int?
    /// The complete response, or the part of one that arrived before a failure (`isPartial`).
    public var response: ComposeResponseSnapshot?
    public var isPartial: Bool
    public var failureCode: String?
    public var failureMessage: String?
    public var delivery: ComposeDeliveryState
    public var elapsed: Duration?

    public init(id: UUID, outcome: ComposeOutcome, elapsed: Duration?) {
        self.id = id
        flowID = outcome.flowID
        response = outcome.response ?? outcome.partialResponse
        isPartial = outcome.response == nil && outcome.partialResponse != nil
        failureCode = outcome.failure?.code
        failureMessage = outcome.failure?.message
        delivery = outcome.delivery
        self.elapsed = elapsed
    }

    public var partialNotice: String? { isPartial ? Self.partialText : nil }

    /// A failure after the request was handed upstream but before any response head.
    public var deliveryNotice: String? {
        failureMessage != nil && delivery == .unknown && response == nil ? Self.deliveryUnknownText : nil
    }
}

/// What a Replay does when its window opens (controller ruling, design RC-09): GET, HEAD and
/// OPTIONS are sent at once; any other method is only filled in and waits for the user's Send,
/// so a request with side effects is never repeated by one menu click.
public enum ComposeReplay {
    public static let messageKeys = ["compose.replay.held", "compose.replay.notSent"]

    /// Methods are case-sensitive (RFC 9110 §9.1): only the exact tokens are safe; "get" is an
    /// unknown method and opens the draft. The method itself is never rewritten.
    public static func sendsImmediately(method: String) -> Bool {
        method == "GET" || method == "HEAD" || method == "OPTIONS"
    }

    public static func heldNotice(method: String) -> String { L10n.format("compose.replay.held", method) }
    public static var notSentNotice: String { L10n.string("compose.replay.notSent") }
}

/// One Compose window: the draft, one send at a time and its result. Editing stays possible while
/// a send runs (the sent request was frozen when Send was clicked); a second Send waits until the
/// running one ended. The outcome is always the send's own result — a Cancel only asks.
@MainActor @Observable public final class ComposeViewModel: Identifiable {
    public enum Phase: Equatable, Sendable {
        case idle, sending, done, failed
    }

    public let id = UUID()
    public var draft: ComposeDraft
    public private(set) var phase: Phase = .idle
    /// The last finished send; kept while the next one runs.
    public private(set) var result: ComposeResultPresentation?
    /// Why an opened Replay was not sent; cleared by the next Send.
    public private(set) var notice: String?
    /// Why the last Choose / Replace file did not work (a localized sentence); cleared by the next try.
    public private(set) var fileError: String?
    /// True while a chosen file is being copied.
    public private(set) var isImportingFile = false
    /// Bytes copied so far and in all while a captured body is being imported; nil otherwise.
    public private(set) var importProgress: (done: Int64, total: Int64)?
    @ObservationIgnored private let client: any ComposeClient
    @ObservationIgnored private let files: (any ComposeBodyFiles)?
    @ObservationIgnored private let access: ScopedFileAccess
    @ObservationIgnored private let acquireBody: (@Sendable (BodyRef) throws -> HTTPBodyReadLease)?
    @ObservationIgnored private var importTask: Task<Void, Never>?
    /// The assets this window imported and has not discarded; a file that came with the draft is
    /// never in here, so it is never discarded by this window.
    @ObservationIgnored private var ownedAssets: Set<UUID> = []
    @ObservationIgnored private var isClosed = false
    @ObservationIgnored private var activeSendID: UUID?
    /// The draft as the window opened, then as of the last Send: what closing is compared with.
    @ObservationIgnored private var baseline: ComposeDraft
    private var hasEditedURL = false
    private var hasTriedToSend = false

    public init(draft: ComposeDraft, client: any ComposeClient, files: (any ComposeBodyFiles)? = nil,
                access: ScopedFileAccess = .securityScoped,
                acquireBody: (@Sendable (BodyRef) throws -> HTTPBodyReadLease)? = nil) {
        self.draft = draft
        self.baseline = draft
        self.client = client
        self.files = files
        self.access = access
        self.acquireBody = acquireBody
    }

    /// "Importing the request body… 3 MB / 12 MB" while a captured body is copied.
    public var importProgressText: String? {
        importProgress.map {
            L10n.format("compose.body.importing", Formatting.size(Int(clamping: $0.done)), Formatting.size(Int(clamping: $0.total)))
        }
    }

    public var issues: [ComposeDraftIssue] { draft.validate() }

    /// The issues the window lists. An untouched empty URL is not reported yet: its error appears
    /// once the user edited the URL or pressed Send (phase fix F2); every other issue shows at once.
    public var shownIssues: [ComposeDraftIssue] {
        guard isURLPristine else { return issues }
        return issues.filter { $0.field != .url }
    }

    /// Send can be pressed when the draft is valid, or when the only errors are not shown yet
    /// (pressing it then shows them instead of sending).
    public var isSendEnabled: Bool {
        phase != .sending && (canSend || !shownIssues.contains { $0.severity == .error })
    }

    /// The URL field's edits; the URL counts as edited from now on.
    public func setURL(_ text: String) {
        hasEditedURL = true
        draft.setURL(text)
    }

    private var isURLPristine: Bool { !hasEditedURL && !hasTriedToSend && draft.url.isEmpty }

    public var isSending: Bool { phase == .sending }

    public var canSend: Bool {
        phase != .sending && !issues.contains { $0.severity == .error }
    }

    /// Freezes the draft into a new send (new id, new flow) and waits for its outcome.
    public func send() async {
        guard phase != .sending, !isClosed else { return }
        hasTriedToSend = true
        guard let request = draft.outgoingRequest(id: UUID()) else { return }
        // The request is frozen and recorded as a flow: it is no longer an unsent edit.
        baseline = draft
        notice = nil
        activeSendID = request.id
        phase = .sending
        let started = ContinuousClock.now
        let outcome = await client.send(request)
        let elapsed = started.duration(to: .now)
        guard activeSendID == request.id else { return }
        activeSendID = nil
        result = ComposeResultPresentation(id: request.id, outcome: outcome, elapsed: elapsed)
        phase = outcome.failure == nil ? .done : .failed
    }

    /// A window opened by Replay: sends a safe-method draft once, otherwise says why it did not.
    public func replayOnOpen() async {
        guard ComposeReplay.sendsImmediately(method: draft.method) else {
            notice = ComposeReplay.heldNotice(method: draft.method)
            return
        }
        guard canSend else {
            notice = ComposeReplay.notSentNotice
            return
        }
        await send()
    }

    /// Asks the running send to stop; its outcome (cancelled, or a response that already
    /// completed) arrives through `send`.
    public func cancel() {
        guard let id = activeSendID else { return }
        client.cancel(id)
    }

    // MARK: Closing

    /// What closing the window now would lose. A body copy that is running (a captured body or a
    /// chosen file) counts as in flight; a captured body that arrived with the draft is not an
    /// edit, but attaching or removing a file is.
    public var closeAssessment: ComposeCloseAssessment {
        ComposeCloseAssessment(
            isDirty: !draft.hasSameContent(as: baseline),
            isInFlight: phase == .sending || importTask != nil || isImportingFile)
    }

    /// The user confirmed closing: the running send is cancelled, the running import is cancelled
    /// and waited for, and every copy this window imported is discarded. Safe to call again.
    public func closeConfirmed() async {
        cancel()
        await close()
    }

    // MARK: File body

    /// Copies `url` into the managed store (inside its security scope) and makes it the body. Only a
    /// successful import replaces the body; the copy it replaces is discarded. A failure keeps the
    /// old body and sets `fileError`.
    public func attachFile(_ url: URL) async {
        guard !isClosed, !isImportingFile else { return }
        fileError = nil
        guard let files else {
            fileError = L10n.string("compose.body.file.noFiles")
            return
        }
        isImportingFile = true
        let imported: ComposeBodyFile?
        do {
            let name = url.lastPathComponent
            imported = try await access.withAccess(to: url) { try await files.importFile(url, displayName: name) }
        } catch {
            imported = nil
        }
        isImportingFile = false
        guard let imported else {
            fileError = L10n.string("compose.body.file.importFailed")
            return
        }
        guard !isClosed else {
            await files.discard([imported.assetID])
            return
        }
        let stale = ownedAssets
        ownedAssets = [imported.assetID]
        // A choice made while a captured body was still being copied replaces it.
        importTask?.cancel()
        draft.body = .file(imported)
        if !stale.isEmpty { await files.discard(stale) }
    }

    /// Drops the file body: the body becomes empty and this window's copies are discarded.
    public func removeFile() async {
        guard draft.body.file != nil else { return }
        draft.body = .none
        fileError = nil
        await discardOwned()
    }

    /// The window is going away: a running import is cancelled and waited for, and every copy this
    /// window imported is discarded. Safe to call again.
    public func close() async {
        isClosed = true
        let running = importTask
        running?.cancel()
        await running?.value
        await discardOwned()
    }

    // MARK: Captured body

    /// Copies a pending captured body into a managed asset, 64 KiB at a time, through a read lease.
    /// Success makes the body a file this window owns; a lease that was revoked (the flow was
    /// cleared), a full store, an error or a cancel leaves the body omitted as `importFailed`. The
    /// lease is always released. Does nothing unless the body is pending.
    public func importCapturedBody() async {
        guard !isClosed, importTask == nil, case .pending(let captured) = draft.body else { return }
        let task = Task { await self.runImport(captured) }
        importTask = task
        await task.value
        importTask = nil
    }

    /// Stops a running import; its body becomes omitted as `importFailed`.
    public func cancelImport() {
        importTask?.cancel()
    }

    private func runImport(_ captured: CapturedBodyImport) async {
        importProgress = (0, captured.size)
        defer { importProgress = nil }
        var imported: ComposeBodyFile?
        if let files, let acquireBody, let lease = try? acquireBody(captured.slice.ref) {
            let base = captured.slice.offset
            let chunk = HTTPBodyReadLease.maxReadBytes
            let total = captured.size
            imported = try? await files.importStream(expectedSize: total, displayName: captured.displayName) { offset, maxBytes in
                await self.setImportProgress(done: offset, total: total)
                return try await lease.read(offset: base + Int(offset), maxBytes: min(maxBytes, chunk))
            }
            lease.cancel()
        }
        guard let imported, let files else {
            if draft.body == .pending(captured) { arrive(.omitted(.importFailed), replacing: captured) }
            return
        }
        // The window closed, or the user picked another body, while the copy ran.
        guard !isClosed, draft.body == .pending(captured), !Task.isCancelled else {
            await files.discard([imported.assetID])
            if !isClosed, draft.body == .pending(captured) { arrive(.omitted(.importFailed), replacing: captured) }
            return
        }
        ownedAssets.insert(imported.assetID)
        arrive(.file(imported), replacing: captured)
    }

    /// The captured body came (or failed to come) into the draft: not an edit by the user, so the
    /// baseline follows when it still holds the pending body.
    private func arrive(_ body: ComposeDraftBody, replacing captured: CapturedBodyImport) {
        draft.body = body
        if baseline.body == .pending(captured) { baseline.body = body }
    }

    private func setImportProgress(done: Int64, total: Int64) {
        importProgress = (done, total)
    }

    private func discardOwned() async {
        let owned = ownedAssets
        ownedAssets = []
        guard !owned.isEmpty, let files else { return }
        await files.discard(owned)
    }
}
