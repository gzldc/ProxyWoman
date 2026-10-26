import Foundation
import FlowStore
import NIOCore
import NIOHTTP1
import os

public struct WebSocketObservationClock: Sendable {
    public let wallNow: @Sendable () -> Date
    public let monotonicNow: @Sendable () -> UInt64
    public init(wallNow: @escaping @Sendable () -> Date, monotonicNow: @escaping @Sendable () -> UInt64) {
        self.wallNow = wallNow; self.monotonicNow = monotonicNow
    }
    public static let live = Self(wallNow: { Date() }, monotonicNow: { DispatchTime.now().uptimeNanoseconds })
}
enum WebSocketCoordinatorStage: Sendable {
    case beforeTaskPublication, afterCompletionSignal, beforeWorkerJoin, afterSupervisorPass, afterShutdownSnapshot
}
/// Optional scheduling probes have no payload or socket access. Production uses the empty value.
struct WebSocketObservationHooks: Sendable {
    var afterTake: (@Sendable () async -> Void)? = nil
    var afterChunk: (@Sendable () async -> Void)? = nil
    var beforeCleanup: (@Sendable () async -> Void)? = nil
    var afterParserStage: (@Sendable () async -> Void)? = nil
    var afterNativeStage: (@Sendable () async -> Void)? = nil
    var beforePublish: (@Sendable () -> Void)? = nil
    var beforeJobPublication: (@Sendable () -> Void)? = nil
    var coordinator: (@Sendable (WebSocketCoordinatorStage) async -> Void)? = nil
}

public final class ObservationHandle: Sendable {
    private struct Entry: Sendable {
        var clientEnded = false
        var serverEnded = false
    }
    let token: WebSocketSessionToken
    private let store: FlowStore
    private let entry: OSAllocatedUnfairLock<Entry>
    /// H only copies/swaps references; cancel and recording never acquire E.
    private let observation: OSAllocatedUnfairLock<ObservationMailbox?>
    private let charge: WebSocketReservation
    private let clock: WebSocketObservationClock
    private let opaque: Bool
    private let hooks: WebSocketObservationHooks
    init(token: WebSocketSessionToken, store: FlowStore, mailbox: ObservationMailbox?, charge: consuming WebSocketReservation,
         clock: WebSocketObservationClock, opaque: Bool, hooks: WebSocketObservationHooks) {
        self.token = token; self.store = store; self.entry = .init(initialState: Entry())
        self.observation = .init(initialState: mailbox)
        self.charge = charge; self.clock = clock; self.opaque = opaque; self.hooks = hooks
    }
    /// E serializes whole read reserve/stamp/copy/commit and EOF. E→M/B/S are sequential,
    /// never nested among M/B/S. All wakeups and retirement happen after E is released.
    public func offer(_ buffer: ByteBuffer, direction: WebSocketDirection) {
        guard buffer.readableBytes > 0 else { return }
        var failed = false
        let mailbox: ObservationMailbox? = entry.withLockUnchecked { state in
            guard !(direction == .clientToServer ? state.clientEnded : state.serverEnded) else { return nil }
            let mailbox = observation.withLock { $0 }
            store.recordWebSocketState(.observedBytes(direction: direction, wire: UInt64(buffer.readableBytes), application: 0,
                lowerBound: opaque || mailbox == nil || mailbox?.isCancelled == true), token: token)
            guard let mailbox, !mailbox.isCancelled else { return mailbox }
            guard UInt32(exactly: buffer.readableBytes) != nil else { failed = true; return mailbox }
            let count = buffer.readableBytes
            let chunks = count / 32_768 + (count % 32_768 == 0 ? 0 : 1)
            guard let permit = mailbox.tryReserveRead(byteCount: count, chunkCount: chunks) else { failed = true; return mailbox }
            // Reserve every payload/control allocation before the first copy or Store stamp.
            var reservations: [ObservationReservations] = []
            for index in 0..<chunks {
                let size = min(32_768, count - index * 32_768)
                guard let metadata = store.webSocketBudget.reserve(category: .metadata, bytes: 512),
                      let payload = store.webSocketBudget.reserve(category: .mailbox, bytes: size) else { failed = true; return mailbox }
                reservations.append(.init(payload: payload, metadata: metadata))
            }
            guard let stamp = store.webSocketCaptureStamp(token: token) else { failed = true; return mailbox }
            let now = clock.wallNow(), monotonic = clock.monotonicNow()
            var prepared: [ObservationChunkStorage] = []
            for (index, reservation) in reservations.enumerated() {
                let offset = index * 32_768, size = min(32_768, count - offset)
                let bytes = buffer.withUnsafeReadableBytes { raw in Data(bytes: raw.baseAddress!.advanced(by: offset), count: size) }
                prepared.append(reservation.make(bytes: bytes, stamp: stamp, direction: direction, observedAt: now,
                    monotonic: monotonic, baseOffset: UInt32(offset)))
            }
            hooks.beforePublish?()
            if !mailbox.publishRead(.init(permit: permit, chunks: prepared)) { failed = true }
            return mailbox
        }
        if failed { cancel() }
        mailbox?.signal()
    }
    public func transportEnded(direction: WebSocketDirection) {
        let end = WebSocketTransportEnd(direction: direction, at: clock.wallNow(), monotonic: clock.monotonicNow())
        let result = entry.withLock { state -> (Bool, ObservationMailbox?) in
            if direction == .clientToServer {
                guard !state.clientEnded else { return (false, nil) }; state.clientEnded = true
            } else { guard !state.serverEnded else { return (false, nil) }; state.serverEnded = true }
            let mailbox = observation.withLock { $0 }
            mailbox?.markTransportEnded(end)
            return (true, mailbox)
        }
        guard result.0 else { return }
        if let mailbox = result.1 { mailbox.signal() } else { store.endWebSocket(token: token, transport: end) }
    }
    public func recordingChanged(epoch: UInt64) {
        let mailbox = observation.withLock { $0 }
        mailbox?.recordingChanged(epoch: epoch)
    }
    public func cancel() {
        let mailbox = observation.withLock { $0 }
        let drained = mailbox?.hasDeliveredBothEnds == true
        mailbox?.cancel(); mailbox?.signal()
        guard !drained else { return }
        for direction in [WebSocketDirection.clientToServer, .serverToClient] {
            store.recordWebSocketState(.observedBytes(direction: direction, wire: 0, application: 0, lowerBound: true), token: token)
        }
    }
    /// The raw relay never attached, or attached only one side: no glue will report transport
    /// ends, so end both directions here with one bounded diagnostic, then stop observation.
    /// Ends are marked before cancellation so the worker join (or Store directly) delivers them.
    public func relayFailed() {
        for direction in [WebSocketDirection.clientToServer, .serverToClient] {
            store.recordWebSocketState(.capture(direction: direction, state: .contentStoppedUntilReconnect,
                diagnostic: direction == .clientToServer ? WebSocketDiagnostic(code: "relayNotAttached") : nil), token: token)
            transportEnded(direction: direction)
        }
        cancel()
    }
    /// Only supervisor after actual Task.value. E also excludes a concurrent last EOF.
    func joined() {
        let mailbox = entry.withLock { _ in observation.withLock { state in let old = state; state = nil; return old } }
        if let mailbox {
            for end in mailbox.claimRemainingEnds() { store.endWebSocket(token: token, transport: end) }
            mailbox.finishWakeStream()
        }
    }
}
/// The producer owns these finite, pre-reserved chunk transactions only during one offer.
private final class ObservationReservations {
    var payload: WebSocketReservation?
    var metadata: WebSocketReservation?
    init(payload: consuming WebSocketReservation, metadata: consuming WebSocketReservation) {
        self.payload = consume payload; self.metadata = consume metadata
    }
    func make(bytes: Data, stamp: WebSocketCaptureStamp, direction: WebSocketDirection,
              observedAt: Date, monotonic: UInt64, baseOffset: UInt32) -> ObservationChunkStorage {
        let payload = self.payload.take()!, metadata = self.metadata.take()!
        return .init(bytes: bytes, payload: payload, metadata: metadata, stamp: stamp, direction: direction,
            observedAt: observedAt, monotonic: monotonic, baseOffset: baseOffset)
    }
}

public final class WebSocketCaptureCoordinator: Sendable {
    private final class Job: Sendable {
        let handle: ObservationHandle
        let mailbox: ObservationMailbox
        let observer: WebSocketObservation
        init(handle: ObservationHandle, mailbox: ObservationMailbox, observer: WebSocketObservation) {
            self.handle = handle; self.mailbox = mailbox; self.observer = observer
        }
    }
    private struct Slot: Sendable { var job: Job?; var complete = false }
    private struct State: Sendable { var accepting = true; var shuttingDown = false; var slots: [UUID: Slot] = [:]; var begins = 0 }
    private final class Supervisor: Sendable {
        let state = OSAllocatedUnfairLock(initialState: State())
        let stream: AsyncStream<Void>
        let wake: AsyncStream<Void>.Continuation
        let store: FlowStore
        let limiter: WebSocketWorkLimiter
        let controller: WebSocketRecordingController?
        let hooks: WebSocketObservationHooks
        init(store: FlowStore, limiter: WebSocketWorkLimiter, controller: WebSocketRecordingController?, hooks: WebSocketObservationHooks) {
            self.hooks = hooks
            self.store = store; self.limiter = limiter; self.controller = controller
            (stream, wake) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        }
        func run() async {
            var tasks: [UUID: Task<Void, Never>] = [:]
            for await _ in stream {
                var ready = state.withLock { $0.slots.compactMap { key, slot in slot.job.map { (key, $0, slot.complete) } } }
                for (id, job, _) in ready where tasks[id] == nil {
                    let worker = Task {
                        await job.observer.drain()
                        self.state.withLock { $0.slots[id]?.complete = true }
                        self.wake.yield(())
                        await self.hooks.coordinator?(.afterCompletionSignal)
                    }
                    // The local Task owns the worker even if completion signals before insertion.
                    await hooks.coordinator?(.beforeTaskPublication)
                    tasks[id] = worker
                }
                for (id, job, complete) in ready where complete {
                    await hooks.coordinator?(.beforeWorkerJoin)
                    await tasks[id]?.value
                    tasks.removeValue(forKey: id)
                    job.handle.joined()
                    store.releaseWebSocketObservation(token: job.handle.token)
                    limiter.remove(session: job.handle.token.sessionID)
                    controller?.unregister(job.handle.token)
                    let removed = state.withLock { $0.slots.removeValue(forKey: id) }
                    withExtendedLifetime(removed) {}
                }
                ready.removeAll()
                if state.withLock({ $0.shuttingDown && $0.begins == 0 && $0.slots.isEmpty }) { break }
                // This probe observes the real keep-running decision, not a substitute gate.
                await hooks.coordinator?(.afterSupervisorPass)
            }
            wake.finish()
        }
    }
    private let store: FlowStore
    private let clock: WebSocketObservationClock
    private let hooks: WebSocketObservationHooks
    private let supervisor: Supervisor
    private let task: Task<Void, Never>
    public convenience init(store: FlowStore, clock: WebSocketObservationClock = .live) {
        self.init(store: store, clock: clock, hooks: .init())
    }
    init(store: FlowStore, clock: WebSocketObservationClock = .live, hooks: WebSocketObservationHooks,
         controller: WebSocketRecordingController? = nil) {
        self.store = store; self.clock = clock; self.hooks = hooks
        var limits = store.webSocketLimits
        limits.quantumBytes = min(limits.quantumBytes, 32_768)
        limits.quantumNativeOperations = min(limits.quantumNativeOperations, 64)
        let limiter = WebSocketWorkLimiter(limits: limits, budget: store.webSocketBudget, now: clock.monotonicNow)
        let supervisor = Supervisor(store: store, limiter: limiter, controller: controller, hooks: hooks)
        self.supervisor = supervisor; task = Task { await supervisor.run() }
    }
    var activeWorkerCount: Int { supervisor.state.withLock { $0.slots.count } }
    public func begin(flowID: Int, request: HTTPRequestHead, response: HTTPResponseHead, eventLoop: EventLoop) -> ObservationHandle? {
        let admitted = supervisor.state.withLock { state in
            guard state.accepting else { return false }; state.begins += 1; return true
        }
        guard admitted else { return nil }
        defer { supervisor.state.withLock { $0.begins -= 1 }; supervisor.wake.yield(()) }
        guard let staging = WebSocketPendingHandshake.reserve(request: request, response: response, budget: store.webSocketBudget, staging: true),
              let handleCharge = store.webSocketBudget.reserve(category: .metadata, bytes: 512) else { return nil }
        defer { _ = staging.bytes }
        guard request.headers[canonicalForm: "upgrade"].contains(where: { $0.lowercased() == "websocket" })
            || response.headers[canonicalForm: "upgrade"].contains(where: { $0.lowercased() == "websocket" }) else { return nil }
        let assessment = WebSocketHandshakeAssessment.evaluate(request: request, response: response)
        let slotID = UUID()
        let hasSlot = supervisor.state.withLock { state in
            guard state.accepting, assessment.mode != .disabled, state.slots.count < max(0, store.webSocketLimits.observingSessions) else { return false }
            state.slots[slotID] = Slot(); return true
        }
        var published = false
        defer {
            if hasSlot && !published { let old = supervisor.state.withLock { $0.slots.removeValue(forKey: slotID) }; withExtendedLifetime(old) {} }
        }
        guard let token = store.beginWebSocket(flowID: flowID, handshake: assessment.handshake, contentAllowed: hasSlot) else { return nil }
        guard hasSlot, let summary = store.webSocketSummary(token: token), summary.clientToServer.capture != .metadataOnly,
              let jobCharge = store.webSocketBudget.reserve(category: .metadata, bytes: 2048) else {
            store.releaseWebSocketObservation(token: token)
            store.recordWebSocketState(.observedBytes(direction: .clientToServer, wire: 0, application: 0, lowerBound: true), token: token)
            return ObservationHandle(token: token, store: store, mailbox: nil, charge: handleCharge, clock: clock, opaque: true, hooks: .init())
        }
        let mailbox = ObservationMailbox(limits: store.webSocketLimits, envelope: jobCharge)
        let handle = ObservationHandle(token: token, store: store, mailbox: mailbox, charge: handleCharge, clock: clock,
            opaque: assessment.mode == .opaqueFrames, hooks: hooks)
        let observer = WebSocketObservation(token: token, store: store, assessment: assessment, mailbox: mailbox,
            limiter: supervisor.limiter, clock: clock, hooks: hooks)
        let job = Job(handle: handle, mailbox: mailbox, observer: observer)
        _ = store.registerWebSocketCancellation(token: token) { [weak handle] in handle?.cancel() }
        supervisor.controller?.register(handle)
        hooks.beforeJobPublication?()
        let stopping = supervisor.state.withLock { state in state.slots[slotID]?.job = job; return !state.accepting }
        published = true
        if stopping { handle.cancel() }
        supervisor.wake.yield(())
        return handle
    }
    public func stopAdmission() { supervisor.state.withLock { $0.accepting = false } }
    public func shutdown() async {
        var jobs = supervisor.state.withLock { state in
            state.accepting = false; state.shuttingDown = true
            return state.slots.values.compactMap(\.job)
        }
        for job in jobs { job.handle.cancel() }
        jobs.removeAll()
        supervisor.wake.yield(())
        await hooks.coordinator?(.afterShutdownSnapshot)
        await task.value
    }
}
