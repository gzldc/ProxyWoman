import Foundation

/// Storage only: all access is confined to FlowStore's existing owner lock.
struct WebSocketStore: Sendable {
    var sessions: [Int: WebSocketStoredSession] = [:]
    var generation: UInt64 = 0
    var epoch: UInt64 = 0
    var enabled = true
    var recordingRevision: UInt64 = 0
    var revision: UInt64 = 0
    /// Bumped when a session opens or finishes closing (not per message), for `FlowStore.changeStamp`.
    var lifecycleRevision: UInt64 = 0
    var exportOrdinalsExhausted = false
    var exportConsumers: [UUID: WebSocketExportCore] = [:]
    // Cores invalidated by the S section in progress; taken before that section releases S.
    var newlyInvalidatedExports: [WebSocketExportCore] = []
    // Payload-free test probe, called outside S immediately before draining G.
    var exportDrainProbe: (@Sendable () -> Void)?
    var ingressSequence: UInt64 = 0
    /// Running total of retained events across sessions (the store-event cap), kept exact at
    /// every insertion, eviction and session removal.
    var retainedEventCount = 0
    /// Test-observed count of sessions and heap entries examined by eviction selection.
    var evictionExamined: UInt64 = 0
    var subscriber: WebSocketSubscriber?
    var lastNotifiedRevision: UInt64?
    func session(_ token: WebSocketSessionToken) -> WebSocketStoredSession? {
        guard let session = sessions[token.flowID], session.token == token else { return nil }
        return session
    }
    mutating func changed(_ session: WebSocketStoredSession? = nil) {
        var overflow = false
        wsSaturatingAdd(&revision, 1, lowerBound: &overflow)
        if revision == .max {
            exportOrdinalsExhausted = true
            for core in exportConsumers.values { invalidateExport(core, .ordinalExhausted) }
        }
        if let session { session.summary.revision = revision; session.summary.lowerBound = session.summary.lowerBound || overflow }
    }
}
final class WebSocketStoredSession: @unchecked Sendable {
    let token: WebSocketSessionToken
    var summary: WebSocketSummary
    let metadata: WebSocketCharge
    let handshakeCharge: WebSocketCharge
    let terminalCharge: WebSocketCharge
    var scratch: WebSocketCharge?
    var content: Bool
    var ended: Set<WebSocketDirection> = []
    var events = WebSocketEventLog()
    // One owner-lock registry for pending, retained and retiring cells. Each cell's
    // 512-byte metadata charge lives until its actual final owner releases it.
    var accumulators: [WebSocketAccumulatorKey: [ObjectIdentifier: WebSocketPayloadRegistration]] = [:]
    var cancellation: (@Sendable () -> Void)?
    var diagnosticCharges: [WebSocketDirection: WebSocketCharge] = [:]
    var terminalDiagnosticDirection: WebSocketDirection?
    var highestEventID: UInt64 = 0
    var evictedThrough: UInt64?
    var payloadBytes = 0
    init(token: WebSocketSessionToken, handshake: WebSocketHandshake, metadata: WebSocketCharge,
         handshakeCharge: WebSocketCharge, terminal: WebSocketCharge, scratch: WebSocketCharge?, content: Bool) {
        self.token = token; self.summary = .init(handshake: handshake); self.metadata = metadata
        self.handshakeCharge = handshakeCharge; self.terminalCharge = terminal; self.scratch = scratch; self.content = content
        if !content { summary.clientToServer.capture = .metadataOnly; summary.serverToClient.capture = .metadataOnly }
    }
    var registrations: [WebSocketPayloadRegistration] { accumulators.values.flatMap { $0.values } }
    func register(_ cell: WebSocketPayloadAccumulator) -> Bool {
        let key = WebSocketAccumulatorKey(eventID: cell.eventID, kind: cell.kind)
        guard accumulators[key]?.values.contains(where: { $0.phase == .pending }) != true else { return false }
        accumulators[key, default: [:]][ObjectIdentifier(cell)] = .init(cell: cell, phase: .pending)
        return true
    }
    func mark(_ payloads: [WebSocketPayloadKind: WebSocketStoredPayload], phase: WebSocketPayloadRegistration.Phase) {
        for payload in payloads.values {
            let cell = payload.cell, key = WebSocketAccumulatorKey(eventID: payload.cell.eventID, kind: payload.cell.kind)
            if accumulators[key]?[ObjectIdentifier(cell)] != nil { accumulators[key]?[ObjectIdentifier(cell)]?.phase = phase }
        }
    }
    func unregister(_ cell: WebSocketPayloadAccumulator) {
        let key = WebSocketAccumulatorKey(eventID: cell.eventID, kind: cell.kind)
        accumulators[key]?.removeValue(forKey: ObjectIdentifier(cell))
        if accumulators[key]?.isEmpty == true { accumulators.removeValue(forKey: key) }
    }
    func cancel() { registrations.forEach { $0.cell.forceRevoke() }; cancellation?() }
}
struct WebSocketPayloadRegistration: Sendable {
    enum Phase: Sendable { case pending, active, completed, retiring }
    let cell: WebSocketPayloadAccumulator
    var phase: Phase
}
struct WebSocketAccumulatorKey: Hashable { let eventID: UInt64; let kind: WebSocketPayloadKind }
struct WebSocketStoredEvent: Sendable {
    var metadata: WebSocketEventMetadata
    var lastChangeOrdinal: UInt64
    var firstCaptureTerminalOrdinal: UInt64?
    var pendingExportRevocations: UInt8 = 0
    let epoch: UInt64
    var payloads: [WebSocketPayloadKind: WebSocketStoredPayload]
    let charge: WebSocketCharge
    var payloadBytes: Int { payloads.values.reduce(0) { $0 + $1.count } }
}
struct WebSocketSubscriber: Sendable {
    let id: UUID
    let continuation: AsyncStream<WebSocketInvalidation>.Continuation
    let task: Task<Void, Never>
    let charge: WebSocketCharge
    func finish() { task.cancel(); continuation.finish() }
}
struct WebSocketCleanup {
    var sessions: [WebSocketStoredSession] = []
    var events: [WebSocketStoredEvent] = []
    var handles: [WebSocketPayloadAccumulator] = []
    var charges: [WebSocketCharge] = []
    var payloads: [WebSocketStoredPayload] = []
    var actions: [@Sendable () -> Void] = []
    var revocations: [WebSocketPayloadAccumulator] {
        handles + payloads.map(\.cell) + events.flatMap { $0.payloads.values.map(\.cell) }
    }
    func run() {
        sessions.forEach { $0.cancel() }; revocations.forEach { $0.forceRevoke() }; actions.forEach { $0() }
    }
}

extension WebSocketHandshake {
    /// Count each retained occurrence without concatenation or temporary header/string arrays.
    func reservation(in budget: WebSocketMemoryBudget) -> WebSocketReservation? {
        guard diagnostics.count <= 8 && diagnostics.allSatisfy(\.bounded) else { return nil }
        var scalars = 3 // method, version, assessment
        var bytes = 0
        var valid = true
        func add(_ string: String) {
            let result = bytes.addingReportingOverflow(string.utf8.count)
            bytes = result.partialValue; valid = valid && !result.overflow
        }
        add(requestMethod); add(version); add(assessment.rawValue)
        if let requestURI { scalars += 1; add(requestURI) }
        for field in requestHeaders { add(field.name); add(field.value) }
        for field in responseHeaders { add(field.name); add(field.value) }
        for string in offeredProtocols { scalars += 1; add(string) }
        if let selectedProtocol { scalars += 1; add(selectedProtocol) }
        for string in offeredExtensions { scalars += 1; add(string) }
        for string in selectedExtensions { scalars += 1; add(string) }
        for diagnostic in diagnostics { scalars += 1; add(diagnostic.code); if let detail = diagnostic.detail { scalars += 1; add(detail) } }
        let (fields, overflow) = requestHeaders.count.addingReportingOverflow(responseHeaders.count)
        guard valid && !overflow else { return nil }
        return budget.reserveHandshakeMetadata(headCount: 2, headerFieldCount: fields, scalarStringCount: scalars,
            containerCount: 6, utf8Bytes: bytes)
    }
}

extension FlowStore {
    /// Drains the exports this mutation newly invalidated (all invalidated ones for the
    /// UI-initiated Pause barrier), then physically disposes outside the owner lock.
    private func finishWebSocketCleanup(_ cleanup: WebSocketCleanup, invalidated: [WebSocketExportCore], drainAll: Bool = false) {
        if drainAll { drainAllInvalidatedWebSocketExports(including: invalidated) } else { drainWebSocketExports(invalidated) }
        let cells = cleanup.revocations
        cleanup.run() // Actual disposal precedes registry removal, outside the owner lock.
        state.withLockUnchecked { state in
            for cell in cells {
                state.webSockets.completeExportRevocation(cell)
                state.webSockets.session(cell.token)?.unregister(cell)
            }
        }
    }
    public func beginWebSocket(flowID: Int, handshake: WebSocketHandshake, contentAllowed: Bool = true) -> WebSocketSessionToken? {
        guard let handshakeReservation = handshake.reservation(in: webSocketBudget),
              let sessionReservation = webSocketBudget.reserve(category: .metadata, bytes: 2048),
              let terminal = webSocketBudget.reserve(category: .metadata, bytes: 512) else { return nil }
        let handshakeCharge = handshakeReservation.consumeOwner(), metadata = sessionReservation.consumeOwner(), terminalCharge = terminal.consumeOwner()
        let initialContent = state.withLockUnchecked { state in
            contentAllowed && state.webSockets.sessions.values.filter(\.content).count < max(0, webSocketLimits.observingSessions)
        }
        var scratch: WebSocketCharge?
        if initialContent, let reservation = webSocketBudget.reserve(category: .working, bytes: 32_768) { scratch = reservation.consumeOwner() }
        // All prospective ownership stays alive outside the lock even when installation fails.
        let (token, invalidated) = mutateWebSocketState { state -> WebSocketSessionToken? in
            guard state.flows[flowID] != nil && state.webSockets.sessions[flowID] == nil else { return nil }
            let content = initialContent && scratch != nil
                && state.webSockets.sessions.values.filter(\.content).count < max(0, webSocketLimits.observingSessions)
            let token = WebSocketSessionToken(flowID: flowID, sessionID: UUID(), generation: state.webSockets.generation)
            let session = WebSocketStoredSession(token: token, handshake: handshake, metadata: metadata,
                handshakeCharge: handshakeCharge, terminal: terminalCharge, scratch: content ? scratch : nil, content: content)
            if content && !state.webSockets.enabled {
                let capture: WebSocketCaptureState = handshake.assessment == .opaqueExtension ? .opaquePausedUntilReconnect : .paused
                session.summary.clientToServer.capture = capture; session.summary.serverToClient.capture = capture
            }
            state.webSockets.sessions[flowID] = session; state.webSockets.changed(session)
            state.webSockets.lifecycleRevision &+= 1
            return token
        }
        drainWebSocketExports(invalidated)
        return token
    }
    public func takeWebSocketScratchReservation(token: WebSocketSessionToken) -> WebSocketReservation? {
        let owner = state.withLockUnchecked { state -> WebSocketCharge? in
            guard let session = state.webSockets.session(token) else { return nil }
            let owner = session.scratch; session.scratch = nil; return owner
        }
        return owner.map { WebSocketReservation($0) }
    }
    public func webSocketRecordingState() -> WebSocketRecordingState {
        state.withLockUnchecked { .init(enabled: $0.webSockets.enabled, epoch: $0.webSockets.epoch, revision: $0.webSockets.recordingRevision) }
    }
    public func webSocketCaptureStamp(token: WebSocketSessionToken) -> WebSocketCaptureStamp? {
        state.withLockUnchecked { state in
            guard let session = state.webSockets.session(token), session.summary.lifecycle == .open else { return nil }
            guard state.webSockets.ingressSequence < .max else { session.summary.lowerBound = true; return nil }
            state.webSockets.ingressSequence += 1
            return .init(epoch: state.webSockets.epoch, enabled: state.webSockets.enabled, ingressSequence: state.webSockets.ingressSequence)
        }
    }
    public func makeWebSocketAccumulator(token: WebSocketSessionToken, eventID: UInt64, epoch: UInt64,
                                          kind: WebSocketPayloadKind) -> WebSocketPayloadAccumulator? {
        // A registered accumulator has its own conservative handle/cell allowance.
        guard let charge = webSocketBudget.reserve(category: .metadata, bytes: 512) else { return nil }
        let handle = WebSocketPayloadAccumulator(token: token, eventID: eventID, epoch: epoch, kind: kind,
            limit: kind == .application ? webSocketLimits.decodedPrefixBytes : webSocketLimits.wirePrefixBytes,
            budget: webSocketBudget, metadata: charge.consumeOwner())
        let accepted = state.withLockUnchecked { state in
            guard let session = state.webSockets.session(token), session.content, session.summary.lifecycle == .open,
                  state.webSockets.enabled && epoch == state.webSockets.epoch else { return false }
            guard session.events[eventID] != nil || eventID > session.highestEventID else { return false }
            return session.register(handle)
        }
        if !accepted { handle.forceRevoke(); return nil }
        return handle
    }
    public func setWebSocketRecording(enabled: Bool, revision: UInt64) {
        var cleanup = WebSocketCleanup()
        let ((), invalidated) = mutateWebSocketState { state -> Void in
            guard revision > state.webSockets.recordingRevision else { return }
            state.webSockets.recordingRevision = revision
            guard enabled != state.webSockets.enabled else { return }
            // At exhaustion fail closed rather than reuse an epoch for old queued messages.
            state.webSockets.enabled = enabled && state.webSockets.epoch < .max
            if state.webSockets.epoch < .max { state.webSockets.epoch += 1 }
            let now = Date()
            for session in state.webSockets.sessions.values {
                state.webSockets.changed(session)
                if !state.webSockets.enabled {
                    // Closed abandoned prefixes remain Pause-revocable even without public metadata changes.
                    for id in session.events.keys {
                        guard var row = session.events[id], row.metadata.completedAt == nil,
                              row.payloads.values.contains(where: { $0.cell.copyBytes(offset: 0, maxBytes: 0) != nil }) else { continue }
                        state.webSockets.invalidateExportRow(row, token: session.token, reason: .payloadUnavailable)
                        row.lastChangeOrdinal = state.webSockets.revision
                        session.events[id] = row
                    }
                    // Retiring work remains revocable even if transport end raced with
                    // a publisher that has not reached its outside-lock cleanup yet.
                    cleanup.handles += session.registrations.filter { $0.phase != .completed }.map(\.cell)
                }
                guard session.summary.lifecycle == .open else { continue }
                for direction in [WebSocketDirection.clientToServer, .serverToClient] {
                    let old = session.summary[direction].capture
                    if old == .contentStoppedUntilReconnect || old == .opaquePausedUntilReconnect || old == .metadataOnly { continue }
                    session.summary[direction].capture = !state.webSockets.enabled
                        ? (session.summary.handshake.assessment == .opaqueExtension ? .opaquePausedUntilReconnect : .paused)
                        : .resumePendingBoundary
                }
                if !state.webSockets.enabled {
                    for id in session.events.keys {
                        guard var event = session.events[id], event.metadata.completedAt == nil else { continue }
                        state.webSockets.invalidateExportRow(event, token: session.token, reason: .changedAfterCutoff)
                        cleanup.payloads += event.payloads.values
                        session.payloadBytes -= event.payloadBytes; event.payloads.removeAll()
                        event.metadata.retainedBytes = 0; event.metadata.integrity = .partialPaused
                        event.metadata.revision = state.webSockets.revision
                        event.lastChangeOrdinal = state.webSockets.revision
                        if event.firstCaptureTerminalOrdinal == nil { event.firstCaptureTerminalOrdinal = state.webSockets.revision }
                        session.events[id] = event
                    }
                    if session.summary.pausedIntervals.currentStartedAt == nil {
                        session.summary.pausedIntervals.currentStartedAt = now
                        session.summary.pausedIntervals.firstStartedAt = session.summary.pausedIntervals.firstStartedAt ?? now
                        session.summary.addPausedIntervalCount()
                    }
                } else {
                    session.summary.pausedIntervals.currentStartedAt = nil; session.summary.pausedIntervals.lastEndedAt = now
                }
                state.webSockets.changed(session)
            }
            state.webSockets.changed()
            state.webSockets.markExportRevocations(cleanup.revocations)
        }
        finishWebSocketCleanup(cleanup, invalidated: invalidated, drainAll: true)
    }
    public func registerWebSocketCancellation(token: WebSocketSessionToken, action: @escaping @Sendable () -> Void) -> Bool {
        let accepted = state.withLockUnchecked { state in
            guard let session = state.webSockets.session(token), session.content, session.cancellation == nil, session.summary.lifecycle == .open else { return false }
            session.cancellation = action; return true
        }
        if !accepted { action() }
        return accepted
    }
    public func publishWebSocket(_ batch: consuming WebSocketEventBatch, token: WebSocketSessionToken, captureEpoch: UInt64) -> StoreAcceptance {
        publishWebSocket(batch, token: token, captureEpoch: captureEpoch, barrier: nil)
    }
    enum WebSocketPublicationStage: Sendable { case prepared, accepted }
    func publishWebSocket(_ batch: consuming WebSocketEventBatch, token: WebSocketSessionToken, captureEpoch: UInt64,
                          barrier: (@Sendable (WebSocketPublicationStage) -> Void)?) -> StoreAcceptance {
        let metadata = batch.metadata, stamp = batch.stamp
        let application = batch.application, wire = batch.wirePayload
        var cleanup = WebSocketCleanup()
        let submittedHandles = Self.payloadHandles(application) + Self.payloadHandles(wire)
        var accepted = false
        var invalidated: [WebSocketExportCore] = []
        defer {
            if !accepted { cleanup.handles += submittedHandles }
            finishWebSocketCleanup(cleanup, invalidated: invalidated)
        }
        let preliminary = state.withLockUnchecked { state -> StoreAcceptance in
            guard let session = state.webSockets.session(token) else { return .revoked }
            guard state.webSockets.enabled && captureEpoch == state.webSockets.epoch && stamp.epoch == captureEpoch && stamp.enabled
                && metadata.order.ingressSequence == stamp.ingressSequence else { return .recordingPausedOrEpochChanged }
            guard session.content && session.summary.lifecycle == .open && session.summary[metadata.direction].capture.admitsContent else { return .captureBudgetExhausted }
            return .accepted
        }
        guard preliminary == .accepted else { return preliminary }
        guard metadata.fragments.count <= max(0, webSocketLimits.fragmentDescriptors), metadata.diagnostics.count <= 8,
              metadata.diagnostics.allSatisfy(\.bounded), metadata.id > 0 else { return .captureBudgetExhausted }
        var metadataCost = 512
        let (fragmentCost, overflow) = metadata.fragments.count.multipliedReportingOverflow(by: 64)
        let (withFragments, overflow2) = metadataCost.addingReportingOverflow(fragmentCost)
        guard !overflow && !overflow2 else { return .captureBudgetExhausted }
        metadataCost = withFragments
        for diagnostic in metadata.diagnostics {
            metadataCost += 128 + 2 * (diagnostic.code.utf8.count + (diagnostic.detail?.utf8.count ?? 0))
        }
        let (count, countOverflow) = Self.payloadCount(application).addingReportingOverflow(Self.payloadCount(wire))
        guard !countOverflow && count <= max(0, webSocketLimits.sessionPayloadBytes) else { return .captureBudgetExhausted }
        // Eviction is owner-lock-only; destruction and each subsequent reserve occur outside it.
        while !webSocketHasRoom(token: token, id: metadata.id, bytes: count) {
            guard evictWebSocketCompleted(token: token, excluding: metadata.id, sessionOnly: true, incomingBytes: count, epoch: captureEpoch) else { return .captureBudgetExhausted }
        }
        var charge: WebSocketCharge?
        while charge == nil {
            if let reservation = webSocketBudget.reserve(category: .metadata, bytes: metadataCost) { charge = reservation.consumeOwner() }
            else if !evictWebSocketCompleted(token: token, excluding: metadata.id, sessionOnly: false, epoch: captureEpoch) { return .captureBudgetExhausted }
        }
        let (required, requiredOverflow) = Self.payloadRetainedRequirement(application).addingReportingOverflow(Self.payloadRetainedRequirement(wire))
        guard !requiredOverflow else { return .captureBudgetExhausted }
        while required > max(0, webSocketLimits.retainedBytes) - webSocketBudget.usedBytes(category: .retained) {
            guard evictWebSocketCompleted(token: token, excluding: metadata.id, sessionOnly: false, epoch: captureEpoch) else { return .captureBudgetExhausted }
        }
        let preparedApplication = prepareWebSocketPayload(application, kind: .application, token: token, eventID: metadata.id, epoch: captureEpoch)
        let preparedWire = prepareWebSocketPayload(wire, kind: .wirePayload, token: token, eventID: metadata.id, epoch: captureEpoch)
        guard preparedApplication.valid && preparedWire.valid else { return .captureBudgetExhausted }
        var payloads: [WebSocketPayloadKind: WebSocketStoredPayload] = [:]
        if let value = preparedApplication.payload { payloads[.application] = value }
        if let value = preparedWire.payload { payloads[.wirePayload] = value }
        barrier?(.prepared)
        // Keep all candidate ownership outside the lock, including rejected publications.
        let (result, newlyInvalidated) = mutateWebSocketState { state -> StoreAcceptance in
            guard let session = state.webSockets.session(token) else { return .revoked }
            guard state.webSockets.enabled && captureEpoch == state.webSockets.epoch && stamp.enabled else { return .recordingPausedOrEpochChanged }
            guard session.content && session.summary.lifecycle == .open && session.summary[metadata.direction].capture.admitsContent,
                  roomForWebSocket(state.webSockets, session: session, id: metadata.id, bytes: count) else { return .captureBudgetExhausted }
            if let old = session.events[metadata.id] {
                guard old.epoch == captureEpoch && old.metadata.order == metadata.order && old.metadata.direction == metadata.direction,
                      !old.metadata.isCaptureTerminal else { return .recordingPausedOrEpochChanged }
                session.mark(old.payloads, phase: .retiring)
                cleanup.events.append(old); session.payloadBytes -= old.payloadBytes
            } else if metadata.id <= session.highestEventID { return .revoked }
            else { state.webSockets.retainedEventCount += 1 }
            var row = metadata
            state.webSockets.changed(session)
            row.revision = state.webSockets.revision; row.retainedBytes = UInt64(count)
            session.events[metadata.id] = WebSocketStoredEvent(metadata: row, lastChangeOrdinal: state.webSockets.revision, firstCaptureTerminalOrdinal: row.isCaptureTerminal ? state.webSockets.revision : nil, epoch: captureEpoch, payloads: payloads, charge: charge!)
            session.highestEventID = max(session.highestEventID, metadata.id)
            session.payloadBytes += count
            session.summary.firstAvailableEventID = session.events.firstID
            session.summary[metadata.direction].capture = .observing
            session.mark(payloads, phase: row.completedAt != nil ? .completed : .active)
            state.webSockets.markExportRevocations(cleanup.revocations)
            return .accepted
        }
        invalidated = newlyInvalidated
        accepted = result == .accepted
        if accepted { barrier?(.accepted) }
        return result
    }
    private static func payloadHandles(_ payload: borrowing WebSocketOwnedPayload?) -> [WebSocketPayloadAccumulator] {
        switch payload { case .some(let value): [value.cell]; case .none: [] }
    }
    private static func payloadCount(_ payload: borrowing WebSocketOwnedPayload?) -> Int {
        switch payload { case .some(let value): value.cell.retainedCount; case .none: 0 }
    }
    private static func payloadRetainedRequirement(_ payload: borrowing WebSocketOwnedPayload?) -> Int {
        switch payload { case .some(let value): value.cell.retainedRequirement; case .none: 0 }
    }
    private func prepareWebSocketPayload(_ payload: consuming WebSocketOwnedPayload?, kind: WebSocketPayloadKind,
                                          token: WebSocketSessionToken, eventID: UInt64, epoch: UInt64) -> (valid: Bool, payload: WebSocketStoredPayload?) {
        guard let payload else { return (true, nil) }
        guard payload.kind == kind && payload.cell.token == token && payload.cell.eventID == eventID && payload.cell.epoch == epoch,
              let retained = webSocketBudget.transferToRetained(payload) else { return (false, nil) }
        let stored = retained.prepared()
        return (stored != nil, stored)
    }
    private func roomForWebSocket(_ ws: WebSocketStore, session: WebSocketStoredSession, id: UInt64, bytes: Int) -> Bool {
        let existing = session.events[id]
        let additional = existing == nil ? 1 : 0
        return session.events.count <= max(0, webSocketLimits.sessionEvents) - additional
            && ws.retainedEventCount <= max(0, webSocketLimits.storeEvents) - additional
            && bytes <= max(0, webSocketLimits.sessionPayloadBytes) - (session.payloadBytes - (existing?.payloadBytes ?? 0))
    }
    private func webSocketHasRoom(token: WebSocketSessionToken, id: UInt64, bytes: Int) -> Bool {
        state.withLockUnchecked { state in
            guard let session = state.webSockets.session(token) else { return false }
            return roomForWebSocket(state.webSockets, session: session, id: id, bytes: bytes)
        }
    }
    private func evictWebSocketCompleted(token: WebSocketSessionToken, excluding: UInt64, sessionOnly: Bool, incomingBytes: Int = 0, epoch: UInt64) -> Bool {
        let (removed, invalidated) = mutateWebSocketState { state -> WebSocketStoredEvent? in
            guard let target = state.webSockets.session(token), state.webSockets.enabled,
                  state.webSockets.epoch == epoch else { return nil }
            // A per-session pressure must evict there; global pressure chooses global order.
            let existing = target.events[excluding]
            let localPressure = target.events.count > max(0, webSocketLimits.sessionEvents) - (existing == nil ? 1 : 0)
                || incomingBytes > max(0, webSocketLimits.sessionPayloadBytes) - (target.payloadBytes - (existing?.payloadBytes ?? 0))
            // Each session yields its oldest terminal row from its order heap; global pressure
            // compares those per-session candidates (O(sessions), not O(retained events)).
            var candidate: (WebSocketStoredSession, WebSocketStoredEvent)?
            var examined: UInt64 = 0
            func consider(_ session: WebSocketStoredSession) {
                examined &+= 1
                guard let event = session.events.oldestTerminal(excluding: session === target ? excluding : nil, examined: &examined) else { return }
                if candidate == nil || event.metadata.order < candidate!.1.metadata.order { candidate = (session, event) }
            }
            if sessionOnly && localPressure { consider(target) }
            else { for session in state.webSockets.sessions.values { consider(session) } }
            state.webSockets.evictionExamined &+= examined
            guard let (session, event) = candidate else { return nil }
            state.webSockets.invalidateExportRow(event, token: session.token, reason: .evicted)
            session.mark(event.payloads, phase: .retiring)
            session.events[event.metadata.id] = nil; session.payloadBytes -= event.payloadBytes
            state.webSockets.retainedEventCount -= 1
            session.evictedThrough = max(session.evictedThrough ?? 0, event.metadata.id)
            var directionSummary = session.summary[event.metadata.direction]
            wsSaturatingAdd(&directionSummary.droppedEvents, 1, lowerBound: &session.summary.lowerBound)
            session.summary[event.metadata.direction] = directionSummary
            session.summary.firstAvailableEventID = session.events.firstID
            state.webSockets.changed(session)
            return event
        }
        if let removed {
            var cleanup = WebSocketCleanup(); cleanup.events.append(removed)
            finishWebSocketCleanup(cleanup, invalidated: invalidated)
        }
        return removed != nil
    }
    public func recordWebSocketState(_ update: WebSocketMetadataOnlyUpdate, token: WebSocketSessionToken) {
        var candidate: WebSocketCharge?
        if case .capture(_, _, let diagnostic?) = update {
            guard diagnostic.bounded else { return }
            if let reservation = webSocketBudget.reserve(category: .metadata, bytes: 128 + 2 * (diagnostic.code.utf8.count + (diagnostic.detail?.utf8.count ?? 0))) {
                candidate = reservation.consumeOwner()
            }
        }
        var cleanup = WebSocketCleanup()
        let ((), invalidated) = mutateWebSocketState { state -> Void in
            guard let session = state.webSockets.session(token) else { return }
            state.webSockets.changed(session)
            switch update {
            case .capture(let direction, let capture, let diagnostic):
                let current = session.summary[direction].capture
                // The metadata path cannot reopen stopped/opaque/paused payload admission.
                if current == .contentStoppedUntilReconnect || current == .opaquePausedUntilReconnect { return }
                if capture.admitsContent && (!state.webSockets.enabled || !current.admitsContent) { return }
                session.summary[direction].capture = capture
                if capture == .contentStoppedUntilReconnect || capture == .opaquePausedUntilReconnect {
                    abandonWebSocketRows(session, direction: direction, ws: &state.webSockets)
                }
                if let old = session.diagnosticCharges.removeValue(forKey: direction) { cleanup.charges.append(old) }
                session.summary[direction].diagnostic = nil
                if let candidate {
                    session.diagnosticCharges[direction] = candidate
                    session.summary[direction].diagnostic = diagnostic
                } else if let diagnostic, session.terminalDiagnosticDirection == nil {
                    // The admission-reserved terminal slot guarantees one bounded code even
                    // when metadata is full. Omit detail; subsequent failures still stop capture.
                    session.terminalDiagnosticDirection = direction
                    session.summary[direction].diagnostic = WebSocketDiagnostic(code: diagnostic.code)
                }
            case .observedBytes(let direction, let wire, let application, let lowerBound):
                var directionSummary = session.summary[direction]
                wsSaturatingAdd(&directionSummary.wireBytes, wire, lowerBound: &session.summary.lowerBound)
                wsSaturatingAdd(&directionSummary.applicationBytes, application, lowerBound: &session.summary.lowerBound)
                session.summary[direction] = directionSummary
                session.summary.lowerBound = session.summary.lowerBound || lowerBound
            case .pausedInterval(let start, let end):
                if session.summary.pausedIntervals.currentStartedAt == nil && end == nil {
                    session.summary.addPausedIntervalCount()
                }
                session.summary.pausedIntervals.firstStartedAt = session.summary.pausedIntervals.firstStartedAt ?? start
                session.summary.pausedIntervals.currentStartedAt = end == nil ? start : nil
                session.summary.pausedIntervals.lastEndedAt = end ?? session.summary.pausedIntervals.lastEndedAt
            case .droppedEvents(let direction, let count): session.summary.addDroppedEvents(count, direction: direction)
            case .closeCode(let direction, let code): session.summary[direction].closeCode = code
            case .closeFrame(let direction, let code):
                session.summary[direction].completedClose = true; session.summary[direction].closeCode = code
            }
            state.webSockets.changed(session)
            state.webSockets.markExportRevocations(cleanup.revocations)
        }
        finishWebSocketCleanup(cleanup, invalidated: invalidated)
    }
    /// Called only after the real worker Task.value join, or a fully unstarted unwind.
    /// It releases observation capacity without inventing a transport end.
    public func releaseWebSocketObservation(token: WebSocketSessionToken) {
        var cleanup = WebSocketCleanup()
        var registration: (@Sendable () -> Void)?
        let ((), invalidated) = mutateWebSocketState { state -> Void in
            guard let session = state.webSockets.session(token), session.content else { return }
            state.webSockets.changed(session)
            session.content = false
            registration = session.cancellation; session.cancellation = nil
            if let scratch = session.scratch { cleanup.charges.append(scratch); session.scratch = nil }
            cleanup.handles += session.registrations.filter { $0.phase == .pending || $0.phase == .retiring }.map(\.cell)
            for direction in [WebSocketDirection.clientToServer, .serverToClient] {
                abandonWebSocketRows(session, direction: direction, ws: &state.webSockets)
                if session.summary[direction].capture.admitsContent || session.summary[direction].capture == .paused {
                    session.summary[direction].capture = .contentStoppedUntilReconnect
                }
            }
            state.webSockets.changed(session)
            state.webSockets.markExportRevocations(cleanup.revocations)
        }
        finishWebSocketCleanup(cleanup, invalidated: invalidated)
        withExtendedLifetime(registration) {} // Drop outside owner lock, without calling it.
    }
    private func abandonWebSocketRows(_ session: WebSocketStoredSession, direction: WebSocketDirection, ws: inout WebSocketStore) {
        for id in session.events.keys {
            guard var row = session.events[id], row.metadata.direction == direction, !row.metadata.isCaptureTerminal else { continue }
            ws.invalidateExportRow(row, token: session.token, reason: .changedAfterCutoff)
            row.lastChangeOrdinal = ws.revision
            row.firstCaptureTerminalOrdinal = ws.revision
            row.metadata.captureAbandoned = true
            if row.metadata.integrity == .transportComplete || row.metadata.integrity == .captureTruncated {
                row.metadata.integrity = .observationStopped
            }
            row.metadata.revision = row.metadata.revision == .max ? .max : row.metadata.revision + 1
            session.events[id] = row
        }
    }
    public func endWebSocket(token: WebSocketSessionToken, transport: WebSocketTransportEnd) {
        var cleanup = WebSocketCleanup()
        let ((), invalidated) = mutateWebSocketState { state -> Void in
            guard let session = state.webSockets.session(token), session.ended.insert(transport.direction).inserted else { return }
            state.webSockets.changed(session)
            session.summary[transport.direction].capture = .contentStoppedUntilReconnect
            for id in session.events.keys {
                guard var event = session.events[id], event.metadata.direction == transport.direction, !event.metadata.isCaptureTerminal else { continue }
                state.webSockets.invalidateExportRow(event, token: session.token, reason: .changedAfterCutoff)
                event.lastChangeOrdinal = state.webSockets.revision
                event.firstCaptureTerminalOrdinal = state.webSockets.revision
                event.metadata.completedAt = transport.at; event.metadata.monotonicEnd = transport.monotonic
                if event.metadata.integrity != .partialPaused { event.metadata.integrity = .incompleteTransport }
                event.metadata.revision = state.webSockets.revision == .max ? .max : state.webSockets.revision + 1
                session.events[id] = event
                session.mark(event.payloads, phase: .completed)
            }
            if session.ended.count == 2 {
                session.summary.closedAt = transport.at
                session.summary.lifecycle = session.summary.clientToServer.completedClose && session.summary.serverToClient.completedClose ? .transportClosed : .transportEndedWithoutClose
                session.content = false
                state.webSockets.lifecycleRevision &+= 1
                cleanup.handles += session.registrations.filter { $0.phase == .pending || $0.phase == .retiring }.map(\.cell)
                if let scratch = session.scratch { cleanup.charges.append(scratch); session.scratch = nil }
                if let action = session.cancellation { cleanup.actions.append(action); session.cancellation = nil }
            }
            state.webSockets.changed(session)
            state.webSockets.markExportRevocations(cleanup.revocations)
        }
        finishWebSocketCleanup(cleanup, invalidated: invalidated)
    }
}

// The marker covers the logical-to-physical revoke interval without retaining another cell.
extension WebSocketStore {
    mutating func markExportRevocations(_ cells: [WebSocketPayloadAccumulator]) {
        for cell in cells {
            guard let session = session(cell.token), var row = session.events[cell.eventID],
                  row.payloads[cell.kind]?.cell === cell, cell.copyBytes(offset: 0, maxBytes: 0) != nil else { continue }
            let bit: UInt8 = cell.kind == .application ? 1 : 2
            guard row.pendingExportRevocations & bit == 0 else { continue }
            invalidateExportRow(row, token: cell.token, reason: .payloadUnavailable)
            changed(session)
            row.lastChangeOrdinal = revision
            row.pendingExportRevocations |= bit
            session.events[cell.eventID] = row
        }
    }
    func completeExportRevocation(_ cell: WebSocketPayloadAccumulator) {
        guard let session = session(cell.token), var row = session.events[cell.eventID],
              row.payloads[cell.kind]?.cell === cell, cell.copyBytes(offset: 0, maxBytes: 0) == nil else { return }
        let bit: UInt8 = cell.kind == .application ? 1 : 2
        row.pendingExportRevocations &= ~bit
        session.events[cell.eventID] = row
    }
}
