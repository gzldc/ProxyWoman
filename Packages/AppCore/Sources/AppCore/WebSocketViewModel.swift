import Foundation
import Observation
import FlowStore
import Viewers

@MainActor @Observable public final class WebSocketViewModel {
    public let token: WebSocketSessionToken
    public let store: FlowStore
    public private(set) var page: [WebSocketEventMetadata] = []
    public private(set) var summary: WebSocketSummary?
    public private(set) var selectedID: UInt64?
    public private(set) var prepared: WebSocketPreparedPayload?
    public private(set) var unavailable = false
    public private(set) var pending = false
    public var autoFollow = true {
        didSet {
            if oldValue && !autoFollow {
                // Keep the published window's anchor, including when a latest scan is in flight.
                loadSerial &+= 1
                pageTask?.cancel()
                // An abandoned follow scan never published; show the anchored page instead of
                // leaving a stale or empty one until the next Store update.
                if followScanInFlight {
                    followScanInFlight = false
                    let anchor = pageStart
                    Task { [weak self] in await self?.load(after: anchor) }
                }
            }
        }
    }
    public private(set) var generation: UInt64 = 0
    public private(set) var revision: UInt64 = 0
    public private(set) var nextCursor: UInt64?
    public private(set) var directions: Set<WebSocketDirection> = [.clientToServer, .serverToClient]
    public private(set) var kinds: Set<WebSocketEventKind> = [.text, .binary, .ping, .pong, .close, .opaqueFrame, .diagnostic]
    public private(set) var payloadKind: WebSocketPayloadKind = .application
    public private(set) var attemptBinaryUTF8 = false
    public var selectedEvent: WebSocketEventMetadata? { page.first { $0.id == selectedID } }
    // Payload-free scheduling seam; nil in production, outside all Store/writer locks.
    @ObservationIgnored var beforePreparation: (@Sendable () async -> Void)?
    // Payload-free seam awaited at each follow-scan yield; nil in production.
    @ObservationIgnored var beforeFollowYield: (@Sendable () async -> Void)?
    /// Store page scans performed (test instrumentation for session-filtered wakeups).
    @ObservationIgnored private(set) var performedLoads = 0
    @ObservationIgnored private var followScanInFlight = false
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var pageTask: Task<Void, Never>?
    @ObservationIgnored private var preparationTask: Task<Void, Never>?
    @ObservationIgnored private var loadSerial: UInt64 = 0
    @ObservationIgnored private var selectionSerial: UInt64 = 0
    @ObservationIgnored private var pageStart: UInt64?
    @ObservationIgnored private var cancelled = false

    public init(store: FlowStore, hub: WebSocketInvalidationHub, token: WebSocketSessionToken) {
        self.store = store; self.token = token
        let updates = hub.updates()
        updatesTask = Task { [weak self] in
            for await update in updates {
                guard !Task.isCancelled, let self else { break }
                // Store-wide invalidations wake every view; skip unless this session changed.
                if self.isCurrent(update) { continue }
                await self.load(after: self.autoFollow ? nil : self.pageStart)
            }
        }
    }
    public func load(after: UInt64?) async {
        guard !cancelled else { return }
        // Explicit navigation owns the requested anchor even if a hub refresh supersedes it.
        if !autoFollow { pageStart = after }
        loadSerial &+= 1; var serial = loadSerial
        pageTask?.cancel()
        let requested = serial
        pageTask = Task { [weak self] in await self?.performLoad(after: after, serial: requested) }
        await pageTask?.value
        // A coalesced source invalidation may supersede this scan. Callers still wait for
        // the current production page instead of observing the empty intermediate state.
        while !cancelled && serial != loadSerial {
            serial = loadSerial
            await pageTask?.value
        }
    }
    /// O(1): the session's own summary revision is unchanged since the published page.
    private func isCurrent(_ update: WebSocketInvalidation) -> Bool {
        guard performedLoads > 0, update.generation == generation else { return false }
        let current = store.webSocketSummary(token: token)
        return current?.revision == summary?.revision && (current == nil) == (summary == nil)
    }
    private func performLoad(after: UInt64?, serial: UInt64) async {
        performedLoads += 1
        if autoFollow && after == nil { await performFollowLoad(serial: serial); return }
        await performAnchoredLoad(after: after, serial: serial)
    }
    /// Latest window: reads backwards from the newest retained event until 200 filtered rows
    /// (or the start of retained history), instead of paging the whole history forwards.
    private func performFollowLoad(serial: UInt64) async {
        followScanInFlight = true
        defer { if serial == loadSerial { followScanInFlight = false } }
        var rows: [WebSocketEventMetadata] = []
        var before: UInt64?
        var newest: WebSocketPage?
        var reachedStart = false
        repeat {
            guard !cancelled, !Task.isCancelled, serial == loadSerial else { return }
            guard let snapshot = store.webSocketPage(token: token, before: before, limit: 200) else {
                publishUnavailable(); return
            }
            if newest == nil { newest = snapshot }
            rows.insert(contentsOf: snapshot.rows.filter { directions.contains($0.direction) && kinds.contains($0.kind) }, at: 0)
            if rows.count > 200 { rows.removeFirst(rows.count - 200) }
            guard rows.count < 200, let next = snapshot.nextCursor, next != before else { reachedStart = rows.count < 200; break }
            before = next
            await beforeFollowYield?()
            await Task.yield()
        } while true
        guard !cancelled, serial == loadSerial, let newest else { return }
        // The anchor is exclusive; nil when the window already starts at retained history.
        publish(rows, from: newest, windowStart: reachedStart ? nil : rows.first.map { $0.id - 1 }, nextCursor: newest.rows.last?.id)
    }
    private func publishUnavailable() {
        page = []; summary = nil; unavailable = true; pending = false
        preparationTask?.cancel(); prepared = nil
    }
    /// Explicit window: up to 200 filtered rows after the anchor.
    private func performAnchoredLoad(after: UInt64?, serial: UInt64) async {
        var cursor = after
        var rows: [WebSocketEventMetadata] = []
        var latest: WebSocketPage?
        repeat {
            guard !cancelled, !Task.isCancelled, serial == loadSerial else { return }
            guard let snapshot = store.webSocketPage(token: token, after: cursor, limit: 200 - rows.count) else {
                publishUnavailable(); return
            }
            latest = snapshot
            rows += snapshot.rows.filter { directions.contains($0.direction) && kinds.contains($0.kind) }
            guard let next = snapshot.nextCursor, next != cursor else { break }
            cursor = next
            if rows.count == 200 { break }
            await Task.yield()
        } while true
        guard !cancelled, serial == loadSerial, let latest else { return }
        publish(rows, from: latest, windowStart: after, nextCursor: cursor)
    }
    private func publish(_ rows: [WebSocketEventMetadata], from latest: WebSocketPage, windowStart: UInt64?, nextCursor cursor: UInt64?) {
        pageStart = windowStart
        page = rows; summary = latest.summary; generation = latest.generation; revision = latest.revision
        nextCursor = cursor
        if let selectedID {
            if rows.contains(where: { $0.id == selectedID }) { prepareSelection() }
            else {
                preparationTask?.cancel(); prepared = nil; pending = false
                unavailable = latest.firstAvailableEventID.map { selectedID < $0 } ?? rows.isEmpty
            }
        }
    }
    public func select(eventID: UInt64?) {
        selectedID = eventID; prepareSelection()
    }
    public func setPayload(kind: WebSocketPayloadKind, attemptBinaryUTF8: Bool) {
        payloadKind = kind; self.attemptBinaryUTF8 = attemptBinaryUTF8; prepareSelection()
    }
    private func prepareSelection() {
        selectionSerial &+= 1; let serial = selectionSerial
        preparationTask?.cancel(); preparationTask = nil; prepared = nil; unavailable = false; pending = false
        guard let row = selectedEvent else { return }
        let kind = payloadKind
        guard let snapshot = store.webSocketPayloadChunk(token: token, eventID: row.id, kind: kind, offset: 0, maxBytes: 262_144, expectedRevision: row.revision) else {
            pending = !row.isCaptureTerminal; unavailable = !pending; return
        }
        let attempt = attemptBinaryUTF8
        let beforePreparation = self.beforePreparation
        preparationTask = Task { [weak self] in
            await beforePreparation?()
            let value = await WebSocketPreparedPayload.prepare(snapshot: snapshot, event: row, kind: kind, attemptBinaryUTF8: attempt)
            guard !Task.isCancelled, let self, !self.cancelled, self.selectionSerial == serial,
                  self.selectedID == row.id, self.payloadKind == kind else { return }
            guard self.store.webSocketPayloadChunk(token: self.token, eventID: row.id, kind: kind, offset: 0, maxBytes: 0, expectedRevision: row.revision) != nil else {
                self.unavailable = true; return
            }
            self.prepared = value
        }
    }
    public func waitForPreparation() async { await preparationTask?.value }
    public func userDidScroll() { autoFollow = false }
    public func setFilters(directions: Set<WebSocketDirection>, kinds: Set<WebSocketEventKind>) {
        self.directions = directions; self.kinds = kinds; pageStart = nil
        preparationTask?.cancel(); prepared = nil
    }
    /// Revalidates the exact event revision and selected kind immediately before a preview action.
    public func validatedPreview() -> WebSocketPreparedPayload? {
        guard let row = selectedEvent, let prepared,
              store.webSocketPayloadChunk(token: token, eventID: row.id, kind: payloadKind, offset: 0, maxBytes: 0, expectedRevision: row.revision) != nil else {
            unavailable = true; self.prepared = nil; return nil
        }
        return prepared
    }
    public var isCancelled: Bool { cancelled }
    public func cancel() {
        cancelled = true; loadSerial &+= 1; selectionSerial &+= 1
        updatesTask?.cancel(); updatesTask = nil; pageTask?.cancel(); pageTask = nil; preparationTask?.cancel(); preparationTask = nil
        page = []; prepared = nil
    }
    deinit { updatesTask?.cancel(); pageTask?.cancel(); preparationTask?.cancel() }
}
