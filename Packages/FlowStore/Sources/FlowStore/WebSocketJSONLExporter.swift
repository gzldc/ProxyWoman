import Foundation
import os

public enum WebSocketExportStatus: String, Sendable { case complete, partial, cancelled }
public enum WebSocketExportReason: String, Sendable {
    case activeAtCutoff, changedAfterCutoff, evicted, payloadUnavailable, unprocessed
    case cancelled, tokenInvalidated, ordinalExhausted, invalidPolicy, consumerLimit, metadataBudget, io
    var cancels: Bool { self == .cancelled || self == .tokenInvalidated || self == .ordinalExhausted }
}
public struct WebSocketExportEvidence: Sendable, Equatable {
    public let cause: WebSocketExportReason
    public let firstID: UInt64
    public var lastID: UInt64
    public var count: UInt64
}
public struct WebSocketExportUnknown: Sendable, Equatable {
    public let cause: WebSocketExportReason
    public let unknownIDCount: UInt64
}
public struct WebSocketExportResult: Sendable {
    public let status: WebSocketExportStatus
    public let cutoff: WebSocketExportCutoff
    public let exported: UInt64
    public let omittedAtCutoff: UInt64
    public let missing: UInt64
    public let trailerWritten: Bool
    public let lowerBound: Bool
    public let evidence: [WebSocketExportEvidence]
    public let unknown: [WebSocketExportUnknown]
    public let rangesComplete: Bool
}
public struct WebSocketExportFailure: Error, Sendable {
    public let reason: WebSocketExportReason
    public let progress: WebSocketExportResult?
    public let underlying: (any Error)?
    init(_ reason: WebSocketExportReason, progress: WebSocketExportResult? = nil, underlying: (any Error)? = nil) {
        self.reason = reason; self.progress = progress; self.underlying = underlying
    }
}
/// Mutable fields belong to S; gate belongs to the writer. Never acquires S while holding B/C.
/// The core owns neither a Store/session/cell nor an exporter Task.
enum WebSocketExportDependency: Sendable {
    case cutoff
    case selectedPayload(eventID: UInt64, expectedRevision: UInt64, kind: WebSocketPayloadKind)
    func includes(_ event: WebSocketStoredEvent, cutoff: WebSocketExportCutoff, committedThrough: UInt64) -> Bool {
        switch self {
        case .cutoff: return event.metadata.id > committedThrough && event.exportEligible(cutoff)
        case .selectedPayload(let id, _, _): return event.metadata.id == id
        }
    }
    var selectedKind: WebSocketPayloadKind? {
        if case .selectedPayload(_, _, let kind) = self { return kind }; return nil
    }
    var pendingMask: UInt8 { selectedKind.map { $0 == .application ? 1 : 2 } ?? 3 }
}
final class WebSocketExportCore: @unchecked Sendable {
    let dependency: WebSocketExportDependency
    let id = UUID()
    let gate = NSLock()
    let cutoff: WebSocketExportCutoff
    let metadata: WebSocketExportMetadata
    let charge: WebSocketCharge
    var reason: WebSocketExportReason?
    var committedThrough: UInt64 = 0
    var exported: UInt64 = 0
    var initial: [WebSocketExportEvidence] = []
    var initialUnknown: UInt64 = 0
    var final: [WebSocketExportEvidence] = []
    var finalUnknown: [WebSocketExportReason: UInt64] = [:]
    init(cutoff: WebSocketExportCutoff, metadata: WebSocketExportMetadata, charge: WebSocketCharge, dependency: WebSocketExportDependency = .cutoff) {
        self.dependency = dependency
        self.cutoff = cutoff; self.metadata = metadata; self.charge = charge
    }
    func invalidate(_ next: WebSocketExportReason, id: UInt64? = nil) {
        if reason == nil || (next.cancels && reason?.cancels != true) { reason = next }
        guard let id, !final.contains(where: { $0.firstID <= id && id <= $0.lastID }) else { return }
        let insertion = final.firstIndex { $0.firstID > id } ?? final.count
        if insertion > 0, final[insertion - 1].cause == next, final[insertion - 1].lastID != .max,
           final[insertion - 1].lastID + 1 == id {
            final[insertion - 1].lastID = id; final[insertion - 1].count += 1
            if insertion < final.count, final[insertion].cause == next, id != .max, id + 1 == final[insertion].firstID {
                final[insertion - 1].lastID = final[insertion].lastID
                final[insertion - 1].count += final[insertion].count; final.remove(at: insertion)
            }
        } else if insertion < final.count, final[insertion].cause == next, id != .max, id + 1 == final[insertion].firstID {
            let old = final[insertion]
            final[insertion] = .init(cause: next, firstID: id, lastID: old.lastID, count: old.count + 1)
        } else if final.count < 32 {
            final.insert(.init(cause: next, firstID: id, lastID: id, count: 1), at: insertion)
        } else { finalUnknown[next, default: 0] += 1 }
    }

    func addOmission(_ id: UInt64) {
        // Admission scans ascending IDs without an all-ID allocation.
        if let last = initial.last, last.lastID != .max && last.lastID + 1 == id {
            initial[initial.count - 1].lastID = id; initial[initial.count - 1].count += 1
        } else if initial.count < 32 { initial.append(.init(cause: .activeAtCutoff, firstID: id, lastID: id, count: 1)) }
        else { initialUnknown += 1 }
    }
}
/// Unique invocation lifetime; idempotent finish and fallback deinit release the unfinished slot.
final class WebSocketExportLease: Sendable {
    private struct State: Sendable { weak var store: FlowStore?; var core: WebSocketExportCore? }
    private let state: OSAllocatedUnfairLock<State>
    var core: WebSocketExportCore { state.withLock { $0.core! } }
    init(store: FlowStore, core: WebSocketExportCore) { state = .init(initialState: .init(store: store, core: core)) }
    func finish() {
        let old = state.withLock { state in
            let pair = (state.store, state.core); state.core = nil; return pair
        }
        if let core = old.1 { old.0?.finishWebSocketExport(core) }
    }
    func cancel() {
        let pair = state.withLock { ($0.store, $0.core) }
        if let core = pair.1 { pair.0?.revokeWebSocketExport(core, reason: .cancelled) }
    }
    deinit { finish() }
}

extension WebSocketStore {
    /// Logical invalidation under S. A core this call moves from valid to invalid is
    /// recorded so that the same mutation, and only it, drains that core's gate after S.
    mutating func invalidateExport(_ core: WebSocketExportCore, _ reason: WebSocketExportReason, id: UInt64? = nil) {
        let fresh = core.reason == nil
        core.invalidate(reason, id: id)
        if fresh { newlyInvalidatedExports.append(core) }
    }
    mutating func invalidateExportRow(_ event: WebSocketStoredEvent, token: WebSocketSessionToken, reason: WebSocketExportReason) {
        for core in exportConsumers.values where core.cutoff.token == token && core.dependency.includes(event, cutoff: core.cutoff, committedThrough: core.committedThrough) {
            invalidateExport(core, reason, id: event.metadata.id)
        }
    }
    mutating func invalidateExportToken(_ token: WebSocketSessionToken) {
        for core in exportConsumers.values where core.cutoff.token == token { invalidateExport(core, .tokenInvalidated) }
    }
    /// Ends one S mutation section: the cores it newly invalidated, to drain outside S.
    mutating func takeNewlyInvalidatedExports() -> [WebSocketExportCore] {
        defer { newlyInvalidatedExports.removeAll() }
        return newlyInvalidatedExports
    }
}
extension FlowStore {
    /// One Store mutation section under S. It returns the export cores this section newly
    /// invalidated; the caller drains exactly those after S (never under S).
    func mutateWebSocketState<T>(_ body: (inout State) throws -> T) rethrows -> (T, [WebSocketExportCore]) {
        try state.withLockUnchecked { state in
            assert(state.webSockets.newlyInvalidatedExports.isEmpty, "an earlier S section leaked its export drain set")
            let value = try body(&state)
            return (value, state.webSockets.takeNewlyInvalidatedExports())
        }
    }
    /// Waits for the current write of each given core. Network-path mutations pass only the
    /// cores they newly invalidated, so a stalled sink never blocks unrelated forwarding.
    func drainWebSocketExports(_ cores: [WebSocketExportCore]) {
        guard !cores.isEmpty else { return }
        state.withLock { $0.webSockets.exportDrainProbe }?()
        for core in cores { core.gate.lock(); core.gate.unlock() }
    }
    /// UI-initiated Clear/Pause barrier: every currently invalidated, unfinished core.
    func drainAllInvalidatedWebSocketExports(including cores: [WebSocketExportCore]) {
        let invalid = state.withLock { $0.webSockets.exportConsumers.values.filter { $0.reason != nil } }
        var seen = Set<ObjectIdentifier>()
        drainWebSocketExports((cores + invalid).filter { seen.insert(ObjectIdentifier($0)).inserted })
    }
    func beginWebSocketExport(token: WebSocketSessionToken, dependency: WebSocketExportDependency = .cutoff) throws -> WebSocketExportLease {
        guard webSocketLimits.pageRows > 0 && webSocketLimits.readerPayloadBytes > 0 else { throw WebSocketExportFailure(.invalidPolicy) }
        guard let reservation = webSocketBudget.reserve(category: .metadata, bytes: 8192) else { throw WebSocketExportFailure(.metadataBudget) }
        let charge = reservation.consumeOwner()
        let core: WebSocketExportCore = try state.withLock { state in
            guard state.webSockets.exportConsumers.count < 8 else { throw WebSocketExportFailure(.consumerLimit) }
            guard !state.webSockets.exportOrdinalsExhausted, let session = state.webSockets.session(token) else {
                throw WebSocketExportFailure(state.webSockets.exportOrdinalsExhausted ? .ordinalExhausted : .tokenInvalidated)
            }
            let cutoff: WebSocketExportCutoff
            switch dependency {
            case .cutoff:
                cutoff = state.webSockets.exportCutoff(token)!
                guard !session.events.values.contains(where: { $0.exportEligible(cutoff) && $0.pendingExportRevocations != 0 }) else {
                    throw WebSocketExportFailure(.payloadUnavailable)
                }
            case .selectedPayload(let id, let revision, let kind):
                guard let row = session.events[id] else { throw WebSocketExportFailure(.evicted) }
                guard row.metadata.isCaptureTerminal else { throw WebSocketExportFailure(.activeAtCutoff) }
                guard row.metadata.revision == revision else { throw WebSocketExportFailure(.changedAfterCutoff) }
                guard row.pendingExportRevocations & dependency.pendingMask == 0,
                      row.payloads[kind]?.cell.copyBytes(offset: 0, maxBytes: 0) != nil else { throw WebSocketExportFailure(.payloadUnavailable) }
                cutoff = .init(token: token, revision: state.webSockets.revision, eventID: id,
                    firstAvailableEventID: id, retainedAtCutoff: 1, eligibleAtCutoff: 1,
                    omittedAtCutoff: 0, priorEvictionObserved: false)
                guard row.exportEligible(cutoff) else { throw WebSocketExportFailure(.changedAfterCutoff) }
            }
            let core = WebSocketExportCore(cutoff: cutoff, metadata: WebSocketExportMetadata(session), charge: charge, dependency: dependency)
            // Only 32 ranges retained; walk actual sparse IDs with constant selection space.
            // Ascending storage gives the active IDs in order in one pass.
            if dependency.selectedKind == nil {
                session.events.forEachAscending(after: nil) { row in
                    guard !row.metadata.isCaptureTerminal else { return true }
                    let next = row.metadata.id
                    if core.initial.count == 32, let last = core.initial.last, last.lastID == .max || last.lastID + 1 != next {
                        core.initialUnknown = cutoff.omittedAtCutoff - core.initial.reduce(0) { $0 + $1.count }
                        return false
                    }
                    core.addOmission(next); return true
                }
            }
            state.webSockets.exportConsumers[core.id] = core
            return core
        }
        return WebSocketExportLease(store: self, core: core)
    }
    func selectedWebSocketExportRow(_ core: WebSocketExportCore) throws -> WebSocketExportRow {
        guard let reservation = webSocketBudget.reserve(category: .metadata, bytes: 128) else { throw WebSocketExportFailure(.metadataBudget) }
        let charge = reservation.consumeOwner()
        return try core.gate.withLock {
            try validateWebSocketExport(core)
            return try state.withLock { state in
                guard case .selectedPayload(let id, let revision, _) = core.dependency,
                      let row = state.webSockets.session(core.cutoff.token)?.events[id],
                      row.exportEligible(core.cutoff), row.metadata.revision == revision,
                      row.pendingExportRevocations & core.dependency.pendingMask == 0 else { throw WebSocketExportFailure(.changedAfterCutoff) }
                return WebSocketExportRow(row, cutoff: core.cutoff, pageCharge: charge)
            }
        }
    }
    func finishWebSocketExport(_ core: WebSocketExportCore) {
        core.gate.lock()
        let removed = state.withLock { state -> WebSocketExportCore? in
            core.invalidate(.cancelled)
            return state.webSockets.exportConsumers.removeValue(forKey: core.id)
        }
        core.gate.unlock()
        withExtendedLifetime(removed) {}
    }
    func revokeWebSocketExport(_ core: WebSocketExportCore, reason: WebSocketExportReason) {
        state.withLock { _ in core.invalidate(reason) }
        core.gate.lock(); core.gate.unlock()
    }
    /// Called with G held. S validates both payload cells, including zero-byte availability.
    func validateWebSocketExport(_ core: WebSocketExportCore, row: WebSocketExportRow? = nil, commit: Bool = false) throws {
        try state.withLock { state in
            guard state.webSockets.exportConsumers[core.id] === core,
                  let session = state.webSockets.session(core.cutoff.token) else { throw WebSocketExportFailure(.tokenInvalidated) }
            if let reason = core.reason { throw WebSocketExportFailure(reason) }
            if let row {
                guard let event = session.events[row.id], event.exportEligible(core.cutoff),
                      event.metadata.revision == row.metadata.revision, event.lastChangeOrdinal == row.changeOrdinal, event.pendingExportRevocations & core.dependency.pendingMask == 0 else {
                    core.invalidate(.changedAfterCutoff, id: row.id); throw WebSocketExportFailure(.changedAfterCutoff)
                }
                for (kind, identity, available) in [(WebSocketPayloadKind.application, row.application, row.applicationAvailable), (.wirePayload, row.wire, row.wireAvailable)] {
                    if let selected = core.dependency.selectedKind, selected != kind { continue }
                    let payload = event.payloads[kind]
                    guard payload.map({ ObjectIdentifier($0.cell) }) == identity,
                          (payload?.cell.copyBytes(offset: 0, maxBytes: 0) != nil) == available else {
                        core.invalidate(.payloadUnavailable, id: row.id); throw WebSocketExportFailure(.payloadUnavailable)
                    }
                }
                if commit { core.exported += 1; core.committedThrough = row.id }
            }
        }
    }
    func webSocketExportProgress(_ core: WebSocketExportCore, trailer: Bool, io: Bool = false) -> WebSocketExportResult {
        state.withLock { _ in
            let missing = core.cutoff.eligibleAtCutoff - core.exported
            var evidence: [WebSocketExportEvidence] = []
            var unknownCounts: [WebSocketExportReason: UInt64] = [:]
            // Fresh primitive reconstruction: no returned COW backing aliases the core.
            if core.initialUnknown > 0 { unknownCounts[.activeAtCutoff] = core.initialUnknown }
            for (cause, count) in core.finalUnknown { unknownCounts[cause] = count }
            let knownMissing = core.final.reduce(UInt64(0)) { $0 + $1.count } + core.finalUnknown.values.reduce(0, +)
            if missing > knownMissing { unknownCounts[.unprocessed] = missing - knownMissing }
            func copy(_ record: WebSocketExportEvidence) {
                if evidence.count < 32 {
                    evidence.append(.init(cause: record.cause, firstID: record.firstID, lastID: record.lastID, count: record.count))
                } else { unknownCounts[record.cause, default: 0] += record.count }
            }
            for record in core.initial { copy(record) }
            for record in core.final { copy(record) }
            // The total allowance includes unknown-cause records as well as ID ranges.
            while evidence.count + unknownCounts.count > 32, let removed = evidence.popLast() {
                unknownCounts[removed.cause, default: 0] += removed.count
            }
            var unknown: [WebSocketExportUnknown] = []
            for cause in unknownCounts.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                unknown.append(.init(cause: cause, unknownIDCount: unknownCounts[cause]!))
            }
            let status: WebSocketExportStatus = core.reason?.cancels == true ? .cancelled :
                (io || missing > 0 || core.cutoff.omittedAtCutoff > 0 || core.cutoff.priorEvictionObserved || core.reason != nil ? .partial : .complete)
            return .init(status: status, cutoff: core.cutoff, exported: core.exported, omittedAtCutoff: core.cutoff.omittedAtCutoff,
                missing: missing, trailerWritten: trailer, lowerBound: false, evidence: evidence, unknown: unknown, rangesComplete: unknown.isEmpty)
        }
    }
}

/// Synchronous FileHandle-compatible operations, invoked only under the writer gate.
protocol WebSocketExportSink: Sendable {
    func write(_ bytes: Data) throws
    func truncate(at offset: UInt64) throws
    func seek(to offset: UInt64) throws
    func close() throws
}
struct WebSocketFileSink: WebSocketExportSink {
    let handle: FileHandle
    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        handle = try FileHandle(forWritingTo: url)
    }
    func write(_ bytes: Data) throws { try handle.write(contentsOf: bytes) }
    func truncate(at offset: UInt64) throws { try handle.truncate(atOffset: offset) }
    func seek(to offset: UInt64) throws { try handle.seek(toOffset: offset) }
    func close() throws { try handle.close() }
}
enum WebSocketExportStage: Sendable { case manifest, metadata, metadataStringChunk, application, wirePayload, text, newline, end, read(Int), page(Int), written(Int) }
typealias WebSocketExportProbe = @Sendable (WebSocketExportStage) -> Void

public enum WebSocketJSONLExporter {
    public static func export(store: FlowStore, token: WebSocketSessionToken, to url: URL) async throws -> WebSocketExportResult {
        let lease = try store.beginWebSocketExport(token: token)
        let sink: WebSocketFileSink
        do { sink = try WebSocketFileSink(url: url) }
        catch {
            let progress = store.webSocketExportProgress(lease.core, trailer: false, io: true)
            lease.finish(); throw WebSocketExportFailure(.io, progress: progress, underlying: error)
        }
        return try await run(store: store, lease: lease, sink: sink, probe: nil)
    }
    static func export(store: FlowStore, token: WebSocketSessionToken, sink: any WebSocketExportSink,
                       probe: WebSocketExportProbe? = nil) async throws -> WebSocketExportResult {
        let lease: WebSocketExportLease
        do { lease = try store.beginWebSocketExport(token: token) }
        catch { try? sink.close(); throw error }
        return try await run(store: store, lease: lease, sink: sink, probe: probe)
    }
    private static func run(store: FlowStore, lease: WebSocketExportLease, sink: any WebSocketExportSink,
                            probe: WebSocketExportProbe?) async throws -> WebSocketExportResult {
        // The invocation owns Store; both the core and writer keep no strong Store edge.
        defer { withExtendedLifetime(store) {} }
        let writer = WebSocketJSONLWriter(store: store, core: lease.core, sink: sink, probe: probe)
        return try await withTaskCancellationHandler {
            defer { lease.finish() }
            return try await writer.run()
        } onCancel: { lease.cancel() }
    }
}

/// Invocation-confined serializer. Only cancellation touches the core concurrently, under S/G.
/// Every string is escaped byte by byte; no full JSON line, escaped string or base64 copy exists.
private final class WebSocketJSONLWriter {
    private weak var owner: FlowStore?
    private var store: FlowStore { owner! } // The enclosing invocation holds its lifetime through run().
    let core: WebSocketExportCore
    let sink: any WebSocketExportSink
    let probe: WebSocketExportProbe?
    var buffer = Data()
    var offset: UInt64 = 0
    var lineStart: UInt64 = 0
    var row: WebSocketExportRow?
    var trailerWritten = false
    var revokedEndAttempted = false
    let formatter: ISO8601DateFormatter
    init(store: FlowStore, core: WebSocketExportCore, sink: any WebSocketExportSink, probe: WebSocketExportProbe?) {
        self.owner = store; self.core = core; self.sink = sink; self.probe = probe
        buffer.reserveCapacity(32_768)
        formatter = ISO8601DateFormatter(); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }
    func check() throws {
        if Task.isCancelled {
            store.revokeWebSocketExport(core, reason: .cancelled)
            throw WebSocketExportFailure(.cancelled)
        }
    }
    func stage(_ value: WebSocketExportStage) throws { probe?(value); try check() }
    func validate() throws {
        try check()
        try core.gate.withLock { try store.validateWebSocketExport(core, row: row) }
    }
    func checkedOffset(adding count: Int) throws -> UInt64 {
        guard let count = UInt64(exactly: count) else { throw CocoaError(.fileWriteUnknown) }
        let (next, overflow) = offset.addingReportingOverflow(count)
        guard !overflow else { throw CocoaError(.fileWriteUnknown) }
        return next
    }
    func flush() throws {
        try check()
        guard !buffer.isEmpty else { return }
        try core.gate.withLock {
            try store.validateWebSocketExport(core, row: row)
            let next = try checkedOffset(adding: buffer.count)
            try sink.write(buffer)
            offset = next
        }
        let written = buffer.count
        buffer.removeAll(keepingCapacity: true)
        try stage(.written(written))
    }
    func byte(_ value: UInt8) throws {
        if buffer.count == 32_768 { try flush() }
        buffer.append(value)
    }
    func raw(_ value: String) throws { for value in value.utf8 { try byte(value) } }
    func string(_ value: String) throws {
        try byte(34)
        var chunkBytes = 0
        for value in value.utf8 {
            try escapedByte(value)
            if probe != nil {
                chunkBytes += 1
                if chunkBytes == 32_768 { try stage(.metadataStringChunk); chunkBytes = 0 }
            }
        }
        try byte(34)
    }
    func escapedByte(_ value: UInt8) throws {
        switch value {
        case 34: try raw("\\\"")
        case 92: try raw("\\\\")
        case 0..<32:
            let hex: StaticString = "0123456789abcdef"
            try raw("\\u00")
            try byte(hex.utf8Start[Int(value >> 4)]); try byte(hex.utf8Start[Int(value & 15)])
        default: try byte(value)
        }
    }
    func number<T: BinaryInteger>(_ value: T) throws { try raw(String(value)) }
    func bool(_ value: Bool) throws { try raw(value ? "true" : "false") }
    func optional(_ value: String?) throws { if let value { try string(value) } else { try raw("null") } }
    func date(_ value: Date?) throws { if let value { try string(formatter.string(from: value)) } else { try raw("null") } }
    func key(_ value: String) throws { try string(value); try byte(58) }
    func field(_ name: String, _ value: String) throws { try byte(44); try key(name); try string(value) }
    func field<T: BinaryInteger>(_ name: String, _ value: T) throws { try byte(44); try key(name); try number(value) }
    func field(_ name: String, _ value: Bool) throws { try byte(44); try key(name); try bool(value) }
    func time(_ name: String, _ value: Date?) throws { try byte(44); try key(name); try date(value) }
    func begin(_ type: String) throws { try raw("{\"schemaVersion\":1,\"type\":"); try string(type) }
    func newline() throws {
        try flush(); try stage(.newline)
        try core.gate.withLock {
            try store.validateWebSocketExport(core, row: row)
            let next = try checkedOffset(adding: 1)
            try sink.write(Data([10])); offset = next
            // A mutation may win S while the write executes. Commit is still under G.
            try store.validateWebSocketExport(core, row: row, commit: row != nil)
            lineStart = offset
        }
    }
    func strings(_ values: [String]) throws {
        try byte(91)
        for (index, value) in values.enumerated() { if index > 0 { try byte(44) }; try string(value) }
        try byte(93)
    }
    func headers(_ values: [HeaderField]) throws {
        try byte(91)
        for (index, value) in values.enumerated() {
            if index > 0 { try byte(44) }
            try raw("{\"name\":"); try string(value.name); try field("value", value.value); try byte(125)
        }
        try byte(93)
    }
    func diagnostics(_ values: [WebSocketDiagnostic]) throws {
        try byte(91)
        for (index, value) in values.enumerated() {
            if index > 0 { try byte(44) }
            try raw("{\"code\":"); try string(value.code); try raw(",\"detail\":"); try optional(value.detail); try byte(125)
        }
        try byte(93)
    }
    func direction(_ summary: WebSocketDirectionSummary) throws {
        try raw("{\"capture\":"); try string(summary.capture.rawValue)
        try field("wireBytes", summary.wireBytes); try field("applicationBytes", summary.applicationBytes)
        try field("droppedEvents", summary.droppedEvents); try field("completedClose", summary.completedClose)
        try raw(",\"closeCode\":"); if let code = summary.closeCode { try number(code) } else { try raw("null") }
        try raw(",\"diagnostics\":"); try diagnostics(summary.diagnostic.map { [$0] } ?? []); try byte(125)
    }
    func evidence(_ records: [WebSocketExportEvidence]) throws {
        try byte(91)
        for (index, record) in records.enumerated() {
            if index > 0 { try byte(44) }
            try raw("{\"cause\":"); try string(record.cause.rawValue)
            try field("firstID", record.firstID); try field("lastID", record.lastID); try field("count", record.count); try byte(125)
        }
        try byte(93)
    }
    func manifest() throws {
        try stage(.manifest); try begin("manifest")
        let cutoff = core.cutoff, summary = core.metadata.summary, handshake = summary.handshake
        try raw(",\"session\":{\"flowID\":"); try number(cutoff.token.flowID)
        try field("sessionID", cutoff.token.sessionID.uuidString); try field("generation", cutoff.token.generation)
        try field("lifecycle", summary.lifecycle.rawValue); try time("openedAt", summary.openedAt); try time("closedAt", summary.closedAt)
        try field("lowerBound", summary.lowerBound)
        try raw(",\"clientToServer\":"); try direction(summary.clientToServer)
        try raw(",\"serverToClient\":"); try direction(summary.serverToClient)
        try raw(",\"pausedIntervals\":{\"totalCount\":"); try number(summary.pausedIntervals.totalCount)
        try time("firstStartedAt", summary.pausedIntervals.firstStartedAt); try time("lastEndedAt", summary.pausedIntervals.lastEndedAt)
        try time("currentStartedAt", summary.pausedIntervals.currentStartedAt); try raw("}}")
        try raw(",\"handshake\":{\"requestMethod\":"); try string(handshake.requestMethod)
        try field("version", handshake.version); try raw(",\"requestURI\":"); try optional(handshake.requestURI)
        try field("responseStatus", handshake.responseStatus); try field("assessment", handshake.assessment.rawValue)
        try raw(",\"requestHeaders\":"); try headers(handshake.requestHeaders)
        try raw(",\"responseHeaders\":"); try headers(handshake.responseHeaders)
        try raw(",\"offeredProtocols\":"); try strings(handshake.offeredProtocols)
        try raw(",\"selectedProtocol\":"); try optional(handshake.selectedProtocol)
        try raw(",\"offeredExtensions\":"); try strings(handshake.offeredExtensions)
        try raw(",\"selectedExtensions\":"); try strings(handshake.selectedExtensions)
        try raw(",\"diagnostics\":"); try diagnostics(handshake.diagnostics); try byte(125)
        try raw(",\"cutoff\":{\"revision\":"); try number(cutoff.revision); try field("eventID", cutoff.eventID)
        try raw(",\"firstAvailableEventID\":"); if let id = cutoff.firstAvailableEventID { try number(id) } else { try raw("null") }
        try field("retainedAtCutoff", cutoff.retainedAtCutoff); try field("eligibleAtCutoff", cutoff.eligibleAtCutoff)
        try field("omittedAtCutoff", cutoff.omittedAtCutoff); try field("priorEvictionObserved", cutoff.priorEvictionObserved); try byte(125)
        try raw(",\"limits\":{\"decodedPrefixBytes\":"); try number(store.webSocketLimits.decodedPrefixBytes)
        try field("wirePrefixBytes", store.webSocketLimits.wirePrefixBytes)
        try field("messageWireBytes", store.webSocketLimits.messageWireBytes)
        try field("messageExpandedBytes", store.webSocketLimits.messageExpandedBytes)
        try field("messageFrames", store.webSocketLimits.messageFrames)
        try field("fragmentDescriptors", store.webSocketLimits.fragmentDescriptors)
        try field("sessionEvents", store.webSocketLimits.sessionEvents)
        try field("sessionPayloadBytes", store.webSocketLimits.sessionPayloadBytes)
        try field("storeEvents", store.webSocketLimits.storeEvents)
        try field("retainedBytes", store.webSocketLimits.retainedBytes)
        try field("observingSessions", store.webSocketLimits.observingSessions)
        try field("sessionMailboxBytes", store.webSocketLimits.sessionMailboxBytes)
        try field("mailboxBytes", store.webSocketLimits.mailboxBytes)
        try field("workingBytes", store.webSocketLimits.workingBytes)
        try field("nativeBytes", store.webSocketLimits.nativeBytes)
        try field("metadataBytes", store.webSocketLimits.metadataBytes)
        try field("quantumBytes", store.webSocketLimits.quantumBytes)
        try field("quantumFrames", store.webSocketLimits.quantumFrames)
        try field("quantumNativeOperations", store.webSocketLimits.quantumNativeOperations)
        try field("sessionFramesPerSecond", store.webSocketLimits.sessionFramesPerSecond)
        try field("sessionExpandedPerSecond", store.webSocketLimits.sessionExpandedPerSecond)
        try field("storeExpandedPerSecond", store.webSocketLimits.storeExpandedPerSecond)
        try field("sessionNativePerSecond", store.webSocketLimits.sessionNativePerSecond)
        try field("storeNativePerSecond", store.webSocketLimits.storeNativePerSecond)
        try field("pageRows", store.webSocketLimits.pageRows)
        try field("readerPayloadBytes", store.webSocketLimits.readerPayloadBytes)
        try field("effectivePageRows", min(200, store.webSocketLimits.pageRows))
        try field("effectiveReaderPayloadBytes", min(262_144, store.webSocketLimits.readerPayloadBytes))
        try field("writeBytes", 32_768); try byte(125)
        try field("omissionPolicy", "activeAtCutoffNeverAdded;missingIsEligibleMinusCommitted;noHistoricalSnapshot")
        try field("wireByteDomain", "observedDecryptedPostHTTPIncludingFrameAndMask")
        try field("applicationByteDomain", "decodedTextBinaryExcludingControl")
        // The core's initial evidence is immutable after admission and owns its charge.
        try raw(",\"initialOmissions\":"); try evidence(core.initial)
        try field("unknownOmittedIDCount", core.initialUnknown)
        try byte(125); try newline()
    }
    func event(_ descriptor: WebSocketExportRow) throws {
        row = descriptor
        defer { row = nil }
        try stage(.metadata); try validate(); try begin("event")
        let value = descriptor.metadata
        try field("id", value.id); try field("revision", value.revision)
        try raw(",\"order\":{\"ingressSequence\":"); try number(value.order.ingressSequence); try field("offset", value.order.offset); try byte(125)
        try field("direction", value.direction.rawValue); try field("kind", value.kind.rawValue); try field("opcode", value.opcode)
        try time("firstObservedAt", value.firstObservedAt); try time("lastObservedAt", value.lastObservedAt); try time("completedAt", value.completedAt)
        try field("monotonicStart", value.monotonicStart); try field("monotonicEnd", value.monotonicEnd)
        try field("integrity", value.integrity.rawValue); try field("utf8", value.utf8.rawValue); try field("captureAbandoned", value.captureAbandoned)
        try field("wirePayloadBytes", value.wirePayloadBytes); try field("decodedBytes", value.decodedBytes); try field("retainedBytes", value.retainedBytes)
        try field("lowerBound", value.lowerBound); try field("compressed", value.compressed)
        try field("fragmentCount", value.fragmentCount); try field("descriptorTruncated", value.descriptorTruncated)
        try raw(",\"closeCode\":"); if let code = value.closeCode { try number(code) } else { try raw("null") }
        try raw(",\"diagnostics\":"); try diagnostics(value.diagnostics)
        try raw(",\"fragments\":[")
        for (index, fragment) in value.fragments.enumerated() {
            if index > 0 { try byte(44) }
            try raw("{\"opcode\":"); try number(fragment.opcode); try field("fin", fragment.fin); try field("rsv", fragment.rsv)
            try field("masked", fragment.masked); try field("length", fragment.length); try time("observedAt", fragment.observedAt); try byte(125)
        }
        try byte(93)
        try raw(",\"application\":"); try payload(.application, descriptor: descriptor)
        try raw(",\"wirePayload\":"); try payload(.wirePayload, descriptor: descriptor)
        try optionalText(descriptor)
        try byte(125); try newline()
    }
    func read(_ kind: WebSocketPayloadKind, descriptor: WebSocketExportRow, offset: Int) throws -> WebSocketPayloadSnapshot {
        try validate()
        guard let snapshot = store.webSocketPayloadChunk(token: core.cutoff.token, eventID: descriptor.id, kind: kind,
            offset: offset, maxBytes: min(262_144, store.webSocketLimits.readerPayloadBytes), expectedRevision: descriptor.metadata.revision) else {
            store.revokeWebSocketExport(core, reason: .payloadUnavailable); throw WebSocketExportFailure(.payloadUnavailable)
        }
        try stage(.read(snapshot.bytes.count))
        return snapshot
    }
    func payload(_ kind: WebSocketPayloadKind, descriptor: WebSocketExportRow) throws {
        try stage(kind == .application ? .application : .wirePayload)
        let identity = kind == .application ? descriptor.application : descriptor.wire
        let available = kind == .application ? descriptor.applicationAvailable : descriptor.wireAvailable
        guard available else {
            try raw("{\"available\":false,\"unavailableReason\":")
            try string(identity == nil ? "notCaptured" : "unavailableAtBinding"); try byte(125); return
        }
        try raw("{\"available\":true,\"encoding\":\"base64\"")
        var position = 0
        var carry: UInt32 = 0
        var count = 0
        let alphabet: StaticString = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        while true {
            // Scope ends before the next read; only one independent bounded payload exists.
            let finished: Bool = try {
                let snapshot = try read(kind, descriptor: descriptor, offset: position)
                if position == 0 {
                    try field("retainedBytes", snapshot.totalRetainedBytes); try field("complete", snapshot.complete); try field("truncated", snapshot.truncated)
                    try raw(",\"data\":\"")
                }
                for value in snapshot.bytes {
                    carry = (carry << 8) | UInt32(value); count += 1
                    if count == 3 {
                        for shift in [18, 12, 6, 0] { try byte(alphabet.utf8Start[Int((carry >> shift) & 63)]) }
                        carry = 0; count = 0
                    }
                }
                position += snapshot.bytes.count
                return position == snapshot.totalRetainedBytes
            }()
            if finished { break }
            try check()
        }
        if count > 0 {
            carry <<= UInt32((3 - count) * 8)
            try byte(alphabet.utf8Start[Int((carry >> 18) & 63)]); try byte(alphabet.utf8Start[Int((carry >> 12) & 63)])
            try byte(count == 2 ? alphabet.utf8Start[Int((carry >> 6) & 63)] : 61); try byte(61)
        }
        try raw("\"}")
    }
    func optionalText(_ descriptor: WebSocketExportRow) throws {
        let value = descriptor.metadata
        guard value.kind == .text, value.utf8 == .valid, value.integrity == .transportComplete,
              value.completedAt != nil, !value.captureAbandoned, !value.lowerBound,
              value.decodedBytes <= UInt64(min(262_144, store.webSocketLimits.readerPayloadBytes)), descriptor.applicationAvailable else { return }
        let snapshot = try read(.application, descriptor: descriptor, offset: 0)
        guard snapshot.complete && !snapshot.truncated && UInt64(snapshot.totalRetainedBytes) == value.decodedBytes,
              snapshot.bytes.count == snapshot.totalRetainedBytes, Self.validUTF8(snapshot.bytes) else { return }
        try stage(.text); try raw(",\"text\":\"")
        for value in snapshot.bytes { try escapedByte(value) }
        try byte(34)
    }
    /// Strict validation without allocating a String or replacing malformed code points.
    static func validUTF8(_ bytes: Data) -> Bool {
        var remaining = 0, scalar: UInt32 = 0, minimum: UInt32 = 0
        for value in bytes {
            if remaining == 0 {
                if value < 0x80 { continue }
                if (0xC2...0xDF).contains(value) { remaining = 1; scalar = UInt32(value & 31); minimum = 0x80 }
                else if (0xE0...0xEF).contains(value) { remaining = 2; scalar = UInt32(value & 15); minimum = 0x800 }
                else if (0xF0...0xF4).contains(value) { remaining = 3; scalar = UInt32(value & 7); minimum = 0x10000 }
                else { return false }
            } else {
                guard (0x80...0xBF).contains(value) else { return false }
                scalar = (scalar << 6) | UInt32(value & 63); remaining -= 1
                if remaining == 0 && (scalar < minimum || scalar > 0x10FFFF || (0xD800...0xDFFF).contains(scalar)) { return false }
            }
        }
        return remaining == 0
    }
    func normalEnd() throws {
        try stage(.end); let result = store.webSocketExportProgress(core, trailer: false)
        try begin("end"); try counts(result)
        try field("rangesComplete", result.rangesComplete); try raw(",\"evidence\":"); try evidence(result.evidence)
        try raw(",\"unknown\":[")
        for (index, unknown) in result.unknown.enumerated() {
            if index > 0 { try byte(44) }; try raw("{\"cause\":"); try string(unknown.cause.rawValue)
            try field("unknownIDCount", unknown.unknownIDCount); try byte(125)
        }
        try raw("]}"); try newline(); trailerWritten = true
    }
    func counts(_ result: WebSocketExportResult) throws {
        try field("status", result.status.rawValue); try field("exported", result.exported)
        try field("omittedAtCutoff", result.omittedAtCutoff); try field("missing", result.missing); try field("lowerBound", result.lowerBound)
    }
    func rollback() throws {
        buffer.removeAll(keepingCapacity: true)
        try core.gate.withLock { try sink.truncate(at: lineStart); try sink.seek(to: lineStart); offset = lineStart }
    }
    /// Sole post-revocation exception: one fixed scalar terminal record, never metadata/content.
    func finishRevoked(_ reason: WebSocketExportReason) throws {
        guard !revokedEndAttempted else { return }; revokedEndAttempted = true
        let result = store.webSocketExportProgress(core, trailer: false)
        let terminal = "{\"schemaVersion\":1,\"type\":\"end\",\"status\":\"\(result.status.rawValue)\",\"reason\":\"\(reason.rawValue)\",\"exported\":\(result.exported),\"omittedAtCutoff\":\(result.omittedAtCutoff),\"missing\":\(result.missing),\"lowerBound\":\(result.lowerBound),\"rangesUnavailable\":true}\n"
        let bytes = Data(terminal.utf8); precondition(bytes.count <= 1024)
        try core.gate.withLock { try sink.write(bytes) }; trailerWritten = true
    }
    func run() async throws -> WebSocketExportResult {
        var primary: (any Error)?
        do {
            try manifest()
            var cursor: UInt64?
            while true {
                try validate()
                let finished: Bool = try {
                    guard let page = store.webSocketExportPage(cutoff: core.cutoff, after: cursor, limit: 200) else {
                        try validate(); throw WebSocketExportFailure(.metadataBudget)
                    }
                    try stage(.page(page.rows.count))
                    for descriptor in page.rows {
                        if descriptor.qualification == .eligible { try event(descriptor) }
                        else if descriptor.qualification == .changedAfterCutoff {
                            throw WebSocketExportFailure(.changedAfterCutoff)
                        }
                    }
                    cursor = page.nextCursor
                    return page.finished
                }()
                if finished { break }
                await Task.yield(); try check()
            }
            try normalEnd()
        } catch {
            let failure = error as? WebSocketExportFailure
            let reason = failure?.reason ?? .io
            store.revokeWebSocketExport(core, reason: reason)
            if failure == nil || reason == .io { primary = error }
            do { try rollback(); try finishRevoked(reason) }
            catch { if primary == nil { primary = error } }
        }
        do { try core.gate.withLock { try sink.close() } }
        catch { if primary == nil { primary = error } }
        let result = store.webSocketExportProgress(core, trailer: trailerWritten, io: primary != nil)
        if let primary { throw WebSocketExportFailure(.io, progress: result, underlying: primary) }
        return result
    }
}


public struct WebSocketPayloadSaveResult: Sendable {
    public let retainedBytes: Int
    public let complete: Bool
    public let truncated: Bool
}
/// Raw retained-prefix orchestration over the JSONL registry, dependency predicate and writer.
public enum WebSocketPayloadExporter {
    public static func save(store: FlowStore, token: WebSocketSessionToken, eventID: UInt64,
                            kind: WebSocketPayloadKind, expectedRevision: UInt64, to url: URL) async throws -> WebSocketPayloadSaveResult {
        let lease = try store.beginWebSocketExport(token: token, dependency: .selectedPayload(eventID: eventID, expectedRevision: expectedRevision, kind: kind))
        let sink: WebSocketFileSink
        do { sink = try WebSocketFileSink(url: url) }
        catch {
            let progress = store.webSocketExportProgress(lease.core, trailer: false, io: true)
            lease.finish(); throw WebSocketExportFailure(.io, progress: progress, underlying: error)
        }
        return try await run(store: store, lease: lease, sink: sink, probe: nil)
    }
    static func save(store: FlowStore, token: WebSocketSessionToken, eventID: UInt64,
                     kind: WebSocketPayloadKind, expectedRevision: UInt64, sink: any WebSocketExportSink,
                     probe: WebSocketExportProbe? = nil) async throws -> WebSocketPayloadSaveResult {
        let lease: WebSocketExportLease
        do { lease = try store.beginWebSocketExport(token: token, dependency: .selectedPayload(eventID: eventID, expectedRevision: expectedRevision, kind: kind)) }
        catch { try? sink.close(); throw error }
        return try await run(store: store, lease: lease, sink: sink, probe: probe)
    }
    private static func run(store: FlowStore, lease: WebSocketExportLease, sink: any WebSocketExportSink,
                            probe: WebSocketExportProbe?) async throws -> WebSocketPayloadSaveResult {
        defer { withExtendedLifetime(store) {} }
        let writer = WebSocketJSONLWriter(store: store, core: lease.core, sink: sink, probe: probe)
        return try await withTaskCancellationHandler {
            defer { lease.finish() }
            return try await writer.runRaw()
        } onCancel: { lease.cancel() }
    }
}

private extension WebSocketJSONLWriter {
    func runRaw() async throws -> WebSocketPayloadSaveResult {
        var closed = false
        do {
            row = try store.selectedWebSocketExportRow(core)
            guard let row, let kind = core.dependency.selectedKind else { throw WebSocketExportFailure(.invalidPolicy) }
            var position = 0
            var result: WebSocketPayloadSaveResult?
            repeat {
                try validate()
                guard let chunk = store.webSocketPayloadChunk(token: core.cutoff.token, eventID: row.id, kind: kind,
                    offset: position, maxBytes: 262_144, expectedRevision: row.metadata.revision) else { throw WebSocketExportFailure(.payloadUnavailable) }
                try stage(.read(chunk.bytes.count))
                if result == nil {
                    let complete = chunk.complete && !chunk.truncated && row.metadata.completedAt != nil && !row.metadata.captureAbandoned && row.metadata.integrity == .transportComplete && !row.metadata.lowerBound
                    result = .init(retainedBytes: chunk.totalRetainedBytes, complete: complete,
                                   truncated: chunk.truncated || row.metadata.integrity == .captureTruncated)
                }
                for value in chunk.bytes { try byte(value) }
                try flush()
                position += chunk.bytes.count
                if position >= chunk.totalRetainedBytes { break }
                guard !chunk.bytes.isEmpty else { throw WebSocketExportFailure(.payloadUnavailable) }
                await Task.yield()
            } while true
            try check()
            try core.gate.withLock {
                // Linearize the selected save under S while rollback is still possible.
                // A later logical invalidation observes a committed save; closing does no S I/O.
                try store.validateWebSocketExport(core, row: row, commit: true)
                closed = true; try sink.close()
            }
            return result!
        } catch {
            let failure = error as? WebSocketExportFailure
            let reason = failure?.reason ?? .io
            store.revokeWebSocketExport(core, reason: reason)
            var cleanupError: (any Error)?
            do { try rollback() } catch { cleanupError = error }
            if !closed { do { try core.gate.withLock { try sink.close() } } catch { if cleanupError == nil { cleanupError = error } } }
            let progress = store.webSocketExportProgress(core, trailer: false, io: reason == .io || cleanupError != nil)
            if reason == .io { throw WebSocketExportFailure(.io, progress: progress, underlying: failure?.underlying ?? error) }
            if let cleanupError { throw WebSocketExportFailure(.io, progress: progress, underlying: cleanupError) }
            throw WebSocketExportFailure(reason, progress: progress)
        }
    }
}
