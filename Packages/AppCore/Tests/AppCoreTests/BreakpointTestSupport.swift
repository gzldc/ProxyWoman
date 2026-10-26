import FlowStore
import Foundation
import os
import RulesEngine
@testable import AppCore

struct AdmissionCall: Equatable, Sendable {
    var enabled: Bool
    var cancelExisting: Bool
}

/// A Foundation-only stand-in for the coordinator bridge. Every call is recorded; `publish`
/// replaces the tickets and notifies each `changes()` stream like the coordinator does.
final class FakeBreakpointClient: BreakpointClient, Sendable {
    struct State: Sendable {
        var tickets: [BreakpointTicketSnapshot] = []
        var bodies: [UUID: Data] = [:]
        var results: [BreakpointClientResult] = []
        var commands: [BreakpointClientCommand] = []
        var admissions: [AdmissionCall] = []
        var cancelledFlows: [Set<Int>] = []
        var events: [String] = []
        var changesCalls = 0
        var bodyLoads = 0
        var revision: UInt64 = 0
        var observers: [AsyncStream<UInt64>.Continuation] = []
        var imports: [URL] = []
        var importSizes: [URL: Int64] = [:]
    }

    let state = OSAllocatedUnfairLock(initialState: State())
    /// When set, the next reads copy the tickets first and then wait at this gate.
    let readGate = OSAllocatedUnfairLock<Gate?>(initialState: nil)
    /// Runs inside `perform` after the command is recorded and before its result is returned.
    let performHook = OSAllocatedUnfairLock<(@Sendable () async -> Void)?>(initialState: nil)

    init(tickets: [BreakpointTicketSnapshot] = []) {
        state.withLock { $0.tickets = tickets }
    }

    var commands: [BreakpointClientCommand] { state.withLock { $0.commands } }
    var admissions: [AdmissionCall] { state.withLock { $0.admissions } }
    var cancelledFlows: [Set<Int>] { state.withLock { $0.cancelledFlows } }
    var events: [String] { state.withLock { $0.events } }
    var changesCalls: Int { state.withLock { $0.changesCalls } }
    var bodyLoads: Int { state.withLock { $0.bodyLoads } }

    func setBody(_ data: Data, for id: UUID) { state.withLock { $0.bodies[id] = data } }
    /// A file `replaceBodyFromFile` imports with this size; any other URL fails to import.
    func setImportedSize(_ size: Int64, for url: URL) { state.withLock { $0.importSizes[url] = size } }
    var imports: [URL] { state.withLock { $0.imports } }
    /// A security scope that records when it is entered and left in `events`.
    var scopedAccess: ScopedFileAccess {
        ScopedFileAccess(start: { [self] _ in state.withLock { $0.events.append("scopeStart") }; return true },
                         stop: { [self] _ in state.withLock { $0.events.append("scopeStop") } })
    }
    func enqueue(_ result: BreakpointClientResult) { state.withLock { $0.results.append(result) } }

    func publish(_ tickets: [BreakpointTicketSnapshot]) {
        let (observers, revision) = state.withLock { state -> ([AsyncStream<UInt64>.Continuation], UInt64) in
            state.tickets = tickets
            state.revision += 1
            return (state.observers, state.revision)
        }
        for observer in observers { observer.yield(revision) }
    }

    func tickets() async -> [BreakpointTicketSnapshot] {
        let tickets = state.withLock { $0.tickets }
        await readGate.withLock { $0 }?.pass()
        return tickets
    }

    func changes() -> AsyncStream<UInt64> {
        let (stream, continuation) = AsyncStream.makeStream(of: UInt64.self, bufferingPolicy: .bufferingNewest(1))
        let revision = state.withLock { state -> UInt64 in
            state.changesCalls += 1
            state.observers.append(continuation)
            return state.revision
        }
        continuation.yield(revision)
        return stream
    }

    func loadBody(_ token: BreakpointTicketToken, maxBytes: Int) async throws -> BreakpointBodyPreview {
        let body = state.withLock { state -> Data? in
            state.bodyLoads += 1
            return state.bodies[token.id]
        }
        guard let body else { throw CancellationError() }
        return BreakpointBodyPreview(data: body.prefix(max(0, maxBytes)), totalLength: Int64(body.count))
    }

    func replaceBodyFromFile(_ token: BreakpointTicketToken, url: URL) async throws -> BreakpointImportedBody {
        let size = state.withLock { state -> Int64? in
            state.imports.append(url)
            state.events.append("import")
            return state.importSizes[url]
        }
        guard let size else { throw CancellationError() }
        return BreakpointImportedBody(id: UUID(), size: size, fileName: url.lastPathComponent)
    }

    func perform(_ command: BreakpointClientCommand) async -> BreakpointClientResult {
        let result = state.withLock { state in
            state.commands.append(command)
            state.events.append("perform")
            return state.results.isEmpty ? .accepted : state.results.removeFirst()
        }
        if let hook = performHook.withLock({ $0 }) { await hook() }
        return result
    }

    func setAdmission(enabled: Bool, cancelExisting: Bool) async {
        state.withLock { $0.admissions.append(AdmissionCall(enabled: enabled, cancelExisting: cancelExisting)) }
    }

    func cancelTickets(forFlows flowIDs: Set<Int>) async {
        state.withLock { state in
            state.cancelledFlows.append(flowIDs)
            state.events.append("cancel")
            state.tickets.removeAll { $0.flowID.map(flowIDs.contains) ?? false }
        }
    }
}

let mebibyte = 1_048_576

func requestTicket(
    id: UUID = UUID(), flowID: Int? = 1, phase: BreakpointTicketPhase = .pausedHeaders,
    url path: String = "/items?id=1", headers: [HeaderField] = [HeaderField(name: "Accept", value: "*/*")],
    bodyLength: Int64? = nil, local: Bool = false, deadline: Date = Date(timeIntervalSinceNow: 120)
) -> BreakpointTicketSnapshot {
    let target = HTTPMessageTarget(scheme: "http", host: "origin.test", port: 8080, method: "POST", pathAndQuery: path)
    let head = HTTPMessageHead.request(target, headers: headers)
    return BreakpointTicketSnapshot(
        token: BreakpointTicketToken(id: id, generation: 1, revision: 1), flowID: flowID, direction: .request,
        originalHead: head, effectiveHead: head, isLocalRoute: local, isCompose: false, mode: .headers, phase: phase,
        matchedAt: deadline.addingTimeInterval(-120), deadline: deadline, matchedRuleIDs: [UUID()], matchedRuleCount: 1,
        bodyLength: bodyLength, bodyTooLargeToCollect: false)
}

func responseTicket(
    id: UUID = UUID(), flowID: Int? = 1, phase: BreakpointTicketPhase = .pausedBody,
    headers: [HeaderField] = [HeaderField(name: "Content-Type", value: "text/plain")], bodyLength: Int64? = nil
) -> BreakpointTicketSnapshot {
    let head = HTTPMessageHead.response(status: 200, reason: "OK", headers: headers)
    let deadline = Date(timeIntervalSinceNow: 120)
    return BreakpointTicketSnapshot(
        token: BreakpointTicketToken(id: id, generation: 1, revision: 1), flowID: flowID, direction: .response,
        originalHead: head, effectiveHead: head, isLocalRoute: false, isCompose: false, mode: .fullBody, phase: phase,
        matchedAt: deadline.addingTimeInterval(-120), deadline: deadline, matchedRuleIDs: [], matchedRuleCount: 0,
        bodyLength: bodyLength, bodyTooLargeToCollect: false)
}

/// Resumes once when the queue model finished a refresh, or fails after `seconds`.
@MainActor
func awaitRefresh(_ model: BreakpointQueueModel, seconds: Double = 5, after trigger: () -> Void) async throws {
    let waiter = OnceWaiter()
    model.refreshObserver = { waiter.resume(true) }
    let timeout = Task { try? await Task.sleep(for: .seconds(seconds)); waiter.resume(false) }
    trigger()
    let refreshed = await waiter.value()
    timeout.cancel()
    model.refreshObserver = nil
    guard refreshed else { throw RefreshTimeout() }
}

struct RefreshTimeout: Error {}

/// A one-shot latch; later resumes are ignored.
final class OnceWaiter: Sendable {
    private let state = OSAllocatedUnfairLock<(Bool?, CheckedContinuation<Bool, Never>?)>(initialState: (nil, nil))

    func resume(_ value: Bool) {
        let continuation = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            guard state.0 == nil else { return nil }
            state.0 = value
            let continuation = state.1
            state.1 = nil
            return continuation
        }
        continuation?.resume(returning: value)
    }

    func value() async -> Bool {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> Bool? in
                if let value = state.0 { return value }
                state.1 = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}
