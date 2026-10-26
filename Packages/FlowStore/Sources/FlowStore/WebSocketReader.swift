import Foundation
import os

public struct WebSocketInvalidation: Sendable, Equatable {
    public let generation: UInt64
    public let revision: UInt64
}
public struct WebSocketPage: Sendable {
    public let rows: [WebSocketEventMetadata]
    public let summary: WebSocketSummary
    public let generation: UInt64
    public let revision: UInt64
    public let firstAvailableEventID: UInt64?
    public let missingBeforeCursor: Bool
    public let nextCursor: UInt64?
}
public struct WebSocketPayloadSnapshot: Sendable, Equatable {
    public let bytes: Data
    public let token: WebSocketSessionToken
    public let eventID: UInt64
    public let revision: UInt64
    public let totalRetainedBytes: Int
    public let offset: Int
    public let complete: Bool
    public let truncated: Bool
    public let utf8: WebSocketUTF8Status
}

extension FlowStore {
    public func webSocketToken(flowID: Int) -> WebSocketSessionToken? { state.withLock { $0.webSockets.sessions[flowID]?.token } }
    public func webSocketSummary(token: WebSocketSessionToken) -> WebSocketSummary? {
        state.withLock { $0.webSockets.session(token)?.summary }
    }
    public func webSocketIsCurrent(token: WebSocketSessionToken, revision: UInt64) -> Bool {
        state.withLock { $0.webSockets.session(token) != nil && $0.webSockets.revision == revision }
    }
    public func webSocketPage(token: WebSocketSessionToken, after: UInt64?, limit: Int) -> WebSocketPage? {
        let count = max(0, min(limit, min(200, webSocketLimits.pageRows)))
        return state.withLock { state in
            guard let session = state.webSockets.session(token) else { return nil }
            // Ordered storage: seek past the cursor and copy at most one page.
            var rows: [WebSocketEventMetadata] = []
            if count > 0 {
                rows.reserveCapacity(count)
                session.events.forEachAscending(after: after) { rows.append($0.metadata); return rows.count < count }
            }
            let first = session.summary.firstAvailableEventID
            return WebSocketPage(rows: rows, summary: session.summary, generation: state.webSockets.generation,
                revision: state.webSockets.revision, firstAvailableEventID: first,
                missingBeforeCursor: session.evictedThrough.map { after == nil || after! < $0 } ?? false,
                nextCursor: rows.last?.id)
        }
    }
    /// The latest page: at most one page of the highest retained IDs below `before` (all when
    /// nil), returned in ascending order. `nextCursor` is the lowest returned ID, the `before`
    /// for the preceding page; `missingBeforeCursor` reports that some events at or below that
    /// window were evicted. Follow mode reads this directly instead of paging from the start.
    public func webSocketPage(token: WebSocketSessionToken, before: UInt64?, limit: Int) -> WebSocketPage? {
        let count = max(0, min(limit, min(200, webSocketLimits.pageRows)))
        return state.withLock { state in
            guard let session = state.webSockets.session(token) else { return nil }
            var rows: [WebSocketEventMetadata] = []
            if count > 0 {
                rows.reserveCapacity(count)
                session.events.forEachDescending(before: before) { rows.append($0.metadata); return rows.count < count }
                rows.reverse()
            }
            let floor = rows.first?.id ?? before
            return WebSocketPage(rows: rows, summary: session.summary, generation: state.webSockets.generation,
                revision: state.webSockets.revision, firstAvailableEventID: session.summary.firstAvailableEventID,
                missingBeforeCursor: session.evictedThrough.map { evicted in floor.map { evicted < $0 } ?? true } ?? false,
                nextCursor: rows.first?.id)
        }
    }
    public func webSocketPayload(token: WebSocketSessionToken, eventID: UInt64, kind: WebSocketPayloadKind, maxBytes: Int) -> WebSocketPayloadSnapshot? {
        payloadSnapshot(token: token, eventID: eventID, kind: kind, offset: 0, maxBytes: maxBytes, expectedRevision: nil)
    }
    public func webSocketPayloadChunk(token: WebSocketSessionToken, eventID: UInt64, kind: WebSocketPayloadKind,
                                      offset: Int, maxBytes: Int, expectedRevision: UInt64) -> WebSocketPayloadSnapshot? {
        payloadSnapshot(token: token, eventID: eventID, kind: kind, offset: offset, maxBytes: maxBytes, expectedRevision: expectedRevision)
    }
    private func payloadSnapshot(token: WebSocketSessionToken, eventID: UInt64, kind: WebSocketPayloadKind,
                                 offset: Int, maxBytes: Int, expectedRevision: UInt64?) -> WebSocketPayloadSnapshot? {
        let limit = max(0, min(maxBytes, min(262_144, webSocketLimits.readerPayloadBytes)))
        guard offset >= 0 else { return nil }
        return state.withLock { state in
            guard let event = state.webSockets.session(token)?.events[eventID],
                  expectedRevision == nil || event.metadata.revision == expectedRevision,
                  let payload = event.payloads[kind],
                  let copied = payload.cell.copyBytes(offset: offset, maxBytes: limit) else { return nil }
            return WebSocketPayloadSnapshot(bytes: copied.bytes, token: token, eventID: eventID, revision: event.metadata.revision,
                totalRetainedBytes: copied.total, offset: offset, complete: payload.complete,
                truncated: payload.truncated, utf8: event.metadata.utf8)
        }
    }
    public func webSocketChanges() -> AsyncStream<WebSocketInvalidation> {
        let (stream, continuation) = AsyncStream<WebSocketInvalidation>.makeStream(bufferingPolicy: .bufferingNewest(1))
        guard let reservation = webSocketBudget.reserve(category: .metadata, bytes: 128) else { continuation.finish(); return stream }
        let id = UUID()
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                self?.flushWebSocketChanges()
            }
        }
        let subscriber = WebSocketSubscriber(id: id, continuation: continuation, task: task, charge: reservation.consumeOwner())
        let previous = state.withLock { state in
            let old = state.webSockets.subscriber; state.webSockets.subscriber = subscriber
            state.webSockets.lastNotifiedRevision = nil
            return old
        }
        previous?.finish()
        continuation.onTermination = { [weak self] _ in
            task.cancel()
            let removed = self?.state.withLock { state -> WebSocketSubscriber? in
                guard state.webSockets.subscriber?.id == id else { return nil }
                let old = state.webSockets.subscriber; state.webSockets.subscriber = nil; return old
            }
            withExtendedLifetime(removed) {}
        }
        return stream
    }
    func flushWebSocketChanges() {
        let notification: (AsyncStream<WebSocketInvalidation>.Continuation, WebSocketInvalidation)? = state.withLock { state in
            guard let subscriber = state.webSockets.subscriber, state.webSockets.lastNotifiedRevision != state.webSockets.revision else { return nil }
            state.webSockets.lastNotifiedRevision = state.webSockets.revision
            return (subscriber.continuation, WebSocketInvalidation(generation: state.webSockets.generation, revision: state.webSockets.revision))
        }
        if let notification { notification.0.yield(notification.1) }
    }
}

/// A scalar observation, not a historical snapshot or a resource lease.
public struct WebSocketExportCutoff: Sendable, Equatable {
    public let token: WebSocketSessionToken
    public let revision: UInt64
    public let eventID: UInt64
    public let firstAvailableEventID: UInt64?
    public let retainedAtCutoff: UInt64
    public let eligibleAtCutoff: UInt64
    public let omittedAtCutoff: UInt64
    public let priorEvictionObserved: Bool
}
public enum WebSocketExportQualification: String, Sendable { case eligible, activeAtCutoff, changedAfterCutoff }
/// Test-owned scalar instrumentation. S may acquire this leaf lock; it never calls back.
/// The optional two installed IDs only control the first candidates, not the selector.
final class WebSocketExportPageProbe: Sendable {
    struct Counts: Sendable { var live = 0; var peak = 0; var constructed = 0; var reserved = 0 }
    let firstCandidateIDs: (UInt64, UInt64)?
    private let counts = OSAllocatedUnfairLock(initialState: Counts())
    var snapshot: Counts { counts.withLock { $0 } }
    init(firstCandidateIDs: (UInt64, UInt64)? = nil) { self.firstCandidateIDs = firstCandidateIDs }
    func reserved(_ slots: Int) { counts.withLock { $0.reserved = slots } }
    func constructed() { counts.withLock { $0.live += 1; $0.peak = max($0.peak, $0.live); $0.constructed += 1 } }
    func destroyed() { counts.withLock { $0.live -= 1 } }
}
/// Metadata never leaves its exact charge owners. Payload identities are scalars, not cells.
public final class WebSocketExportRow: Sendable {
    let metadata: WebSocketEventMetadata
    let changeOrdinal: UInt64
    let application: ObjectIdentifier?
    let wire: ObjectIdentifier?
    let applicationAvailable: Bool
    let wireAvailable: Bool
    private let probe: WebSocketExportPageProbe?
    private let eventCharge: WebSocketCharge
    private let pageCharge: WebSocketCharge
    public var id: UInt64 { metadata.id }
    public let qualification: WebSocketExportQualification
    init(_ row: WebSocketStoredEvent, cutoff: WebSocketExportCutoff, pageCharge: WebSocketCharge, probe: WebSocketExportPageProbe? = nil) {
        self.probe = probe
        metadata = row.metadata; changeOrdinal = row.lastChangeOrdinal
        application = row.payloads[.application].map { ObjectIdentifier($0.cell) }
        wire = row.payloads[.wirePayload].map { ObjectIdentifier($0.cell) }
        eventCharge = row.charge; self.pageCharge = pageCharge
        if row.firstCaptureTerminalOrdinal == nil || row.firstCaptureTerminalOrdinal! > cutoff.revision { qualification = .activeAtCutoff }
        else if row.lastChangeOrdinal > cutoff.revision { qualification = .changedAfterCutoff }
        else { qualification = .eligible }
        applicationAvailable = qualification == .eligible && row.pendingExportRevocations & 1 == 0 && row.payloads[.application]?.cell.copyBytes(offset: 0, maxBytes: 0) != nil
        wireAvailable = qualification == .eligible && row.pendingExportRevocations & 2 == 0 && row.payloads[.wirePayload]?.cell.copyBytes(offset: 0, maxBytes: 0) != nil
        probe?.constructed()
    }
    deinit { probe?.destroyed() }
}
public struct WebSocketExportPage: Sendable {
    public let rows: [WebSocketExportRow]
    public let nextCursor: UInt64?
    public let finished: Bool
}
/// Aliases canonical metadata charges, but never the stored session or its cells.
final class WebSocketExportMetadata: Sendable {
    let summary: WebSocketSummary
    private let charges: [WebSocketCharge]
    init(_ session: WebSocketStoredSession) {
        summary = session.summary
        charges = [session.handshakeCharge, session.terminalCharge] + Array(session.diagnosticCharges.values)
    }
}
extension WebSocketStoredEvent {
    func exportEligible(_ cutoff: WebSocketExportCutoff) -> Bool {
        metadata.id <= cutoff.eventID && metadata.isCaptureTerminal
            && firstCaptureTerminalOrdinal.map { $0 <= cutoff.revision } == true && lastChangeOrdinal <= cutoff.revision
    }
}
extension WebSocketStore {
    func exportCutoff(_ token: WebSocketSessionToken) -> WebSocketExportCutoff? {
        guard !exportOrdinalsExhausted, let session = session(token) else { return nil }
        let eligible = session.events.values.reduce(UInt64(0)) { $0 + ($1.metadata.isCaptureTerminal ? 1 : 0) }
        let retained = UInt64(session.events.count)
        return .init(token: token, revision: revision, eventID: session.highestEventID,
            firstAvailableEventID: session.summary.firstAvailableEventID, retainedAtCutoff: retained,
            eligibleAtCutoff: eligible, omittedAtCutoff: retained - eligible, priorEvictionObserved: session.evictedThrough != nil)
    }
}
extension FlowStore {
    public func webSocketExportCutoff(token: WebSocketSessionToken) -> WebSocketExportCutoff? {
        state.withLock { $0.webSockets.exportCutoff(token) }
    }
    public func webSocketExportPage(cutoff: WebSocketExportCutoff, after: UInt64?, limit: Int) -> WebSocketExportPage? {
        webSocketExportPage(cutoff: cutoff, after: after, limit: limit, probe: nil)
    }
    func webSocketExportPage(cutoff: WebSocketExportCutoff, after: UInt64?, limit: Int, probe: WebSocketExportPageProbe?) -> WebSocketExportPage? {
        let count = max(0, min(limit, min(200, webSocketLimits.pageRows)))
        guard count > 0, let reservation = webSocketBudget.reserve(category: .metadata, bytes: count * 128) else { return nil }
        let charge = reservation.consumeOwner()
        probe?.reserved(count)
        return state.withLock { state in
            guard !state.webSockets.exportOrdinalsExhausted, let session = state.webSockets.session(cutoff.token) else { return nil }
            var rows: [WebSocketExportRow] = []
            var examined = 0
            func consider(_ row: WebSocketStoredEvent) {
                guard row.metadata.id <= cutoff.eventID && (after == nil || row.metadata.id > after!) else { return }
                examined += 1
                let insertion = rows.firstIndex { $0.id > row.metadata.id } ?? rows.count
                if insertion < count {
                    // Drop the displaced descriptor before allocating its replacement slot.
                    // Canonical row and shared page charges remain owned under S.
                    if rows.count == count { rows.removeLast() }
                    rows.insert(WebSocketExportRow(row, cutoff: cutoff, pageCharge: charge, probe: probe), at: insertion)
                }
            }
            if let pair = probe?.firstCandidateIDs {
                guard pair.0 != pair.1, let first = session.events[pair.0], let second = session.events[pair.1] else { return nil }
                consider(first); consider(second)
                for row in session.events.values where row.metadata.id != pair.0 && row.metadata.id != pair.1 { consider(row) }
            } else {
                // Ascending storage: the page is the first `count` IDs in (after, cutoff]; one
                // further in-range ID proves the page is not finished.
                session.events.forEachAscending(after: after) { row in
                    guard row.metadata.id <= cutoff.eventID else { return false }
                    consider(row); return examined <= count
                }
            }
            return .init(rows: rows, nextCursor: rows.last?.id, finished: examined <= count)
        }
    }
}
