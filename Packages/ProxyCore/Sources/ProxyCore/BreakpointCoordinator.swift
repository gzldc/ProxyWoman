import FlowStore
import Foundation
import NIOCore
import os
import RulesEngine

public struct BreakpointTicketID: Hashable, Sendable {
    public let raw: UUID
    public init(raw: UUID = UUID()) { self.raw = raw }
}
public struct BreakpointCommandToken: Hashable, Sendable {
    public let ticketID: BreakpointTicketID
    public let generation: UInt64
    public let revision: UInt64
    public init(ticketID: BreakpointTicketID, generation: UInt64, revision: UInt64) {
        self.ticketID = ticketID; self.generation = generation; self.revision = revision
    }
}
public enum BreakpointTicketState: Sendable { case pausedHeaders, collectingBody, pausedBody, forwarding, cancelled, expired, failed }
public enum BreakpointRouteKind: Sendable { case network, local }
public enum BreakpointBodyUnavailableReason: Sendable { case knownLengthTooLarge }
public enum BreakpointBodyEdit: Sendable { case unchanged, replace(Data), replaceSource(ExactBodySource) }
public struct BreakpointTicket: Sendable {
    public let token: BreakpointCommandToken
    public let contextID: UUID
    public let flowID: Int?
    public let direction: HTTPMessageDirection
    public let originalHead: HTTPMessageHead
    public var effectiveHead: HTTPMessageHead
    public let routeKind: BreakpointRouteKind
    public let source: FlowProvenance.Source
    public let mode: BreakpointPauseMode
    public var state: BreakpointTicketState
    public let matchedAt: NIODeadline
    public let deadline: NIODeadline
    public let matches: RuleMatchSummary
    public var bodyLength: Int64? = nil
    public var bodyUnavailable: BreakpointBodyUnavailableReason? = nil
}
public struct BreakpointEdit: Sendable {
    public var head: HTTPMessageHead
    public var body: BreakpointBodyEdit?
    var editorReservation: OwnedFileReservation?
    var editorPin: BreakpointBodyRuntime.Pin?
    public var bodyEncodingChoice: BodyEncodingChoice
    public init(head: HTTPMessageHead, body: BreakpointBodyEdit? = nil, bodyEncodingChoice: BodyEncodingChoice = .unchanged) {
        self.head = head; self.body = body; self.bodyEncodingChoice = bodyEncodingChoice
    }
}
public enum BreakpointCommand: Sendable {
    case `continue`(token: BreakpointCommandToken, edit: BreakpointEdit)
    case cancel(token: BreakpointCommandToken)
    case collectBody(token: BreakpointCommandToken)
    var token: BreakpointCommandToken {
        switch self { case .continue(let token, _), .cancel(let token), .collectBody(let token): token }
    }
}
public enum BreakpointCommandResult: Sendable, Equatable { case accepted, expired, invalid, unsupported }
public protocol BreakpointClock: Sendable { var now: NIODeadline { get } }
public struct SystemBreakpointClock: BreakpointClock {
    public init() {}
    public var now: NIODeadline { .now() }
}
public enum BreakpointEndReason: Sendable { case cancelled, expired }
public enum ExistingBreakpointPolicy: Sendable { case keep, cancel }
enum BreakpointReservationError: Error { case capacity }

/// The registry owns reservations and command acknowledgements under a short lock. Delivery and
/// acknowledgement callbacks always run outside it; only the exchange loop validates an edit.
public final class BreakpointCoordinator: Sendable {
    typealias Reply = @Sendable (BreakpointCommandResult) -> Void
    enum Delivery: Sendable {
        case command(BreakpointCommand, operation: UUID)
        case end(BreakpointEndReason)
    }
    private struct Pending: Sendable { let id: UUID; let isCancel: Bool; let reply: Reply }
    private struct Entry: Sendable {
        var ticket: BreakpointTicket
        let deliver: @Sendable (Delivery) -> Void
        var pending: Pending?
        var body: ExactBodySource?
        var io: BodyFileIO?
        var imported: ExactBodySource?
    }
    private struct State: Sendable {
        var entries: [BreakpointTicketID: Entry] = [:]
        var observers: [UUID: AsyncStream<UInt64>.Continuation] = [:]
        var revision: UInt64 = 0
        var admission = true
        var stopped = false
        mutating func changed() {
            revision &+= 1
            for observer in observers.values { observer.yield(revision) }
        }
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    let clock: any BreakpointClock
    let limits: RulesLimits
    public init(clock: any BreakpointClock = SystemBreakpointClock(), limits: RulesLimits = RulesLimits()) {
        self.clock = clock; self.limits = limits
    }
    /// Unsupported request modes must fail before route preparation. Disabled policy permits
    /// normal preparation; reserve still makes the final, atomic policy/capacity decision.
    func validatePauseMode(_ mode: BreakpointPauseMode, bodySupported: Bool = false) throws {
        guard mode == .fullBody, !bodySupported else { return }
        try state.withLock { if $0.admission { throw ExchangeRuleFailure.unsupported("fullBodyBreakpoint") } }
    }
    @discardableResult
    func reserve(_ ticket: BreakpointTicket, deliver: @escaping @Sendable (Delivery) -> Void) throws -> BreakpointCommandToken? {
        return try state.withLock { state in
            guard !state.stopped else { throw BreakpointReservationError.capacity }
            // Disabled admission bypasses the pause, not the already-prepared Header/Map rules.
            // Policy and reservation linearize under the same short lock.
            guard state.admission else { return nil }
            try HTTPMutationValidator.validateBreakpointHeadBudget(ticket.originalHead, limits: limits)
            try HTTPMutationValidator.validateBreakpointHeadBudget(ticket.effectiveHead, limits: limits)
            guard state.entries[ticket.token.ticketID] == nil,
                  state.entries.count < limits.ticketCount,
                  state.entries.values.filter({ $0.ticket.contextID == ticket.contextID }).count < limits.ticketsPerContext
            else { throw BreakpointReservationError.capacity }
            state.entries[ticket.token.ticketID] = Entry(ticket: ticket, deliver: deliver)
            state.changed()
            return ticket.token
        }
    }
    public func perform(_ command: BreakpointCommand) async -> BreakpointCommandResult {
        await withCheckedContinuation { continuation in perform(command) { continuation.resume(returning: $0) } }
    }
    /// The same acknowledged operation, also used by deterministic owner-loop fixtures.
    func perform(_ command: BreakpointCommand, reply: @escaping Reply) {
        let operation = UUID()
        let outcome: (Entry?, BreakpointCommandResult?, BreakpointCommand?, Pending?) = state.withLock { state in
            var admitted = command
            guard var entry = state.entries[command.token.ticketID], entry.ticket.token == command.token else {
                return (nil, .invalid, nil, nil)
            }
            let isCancel: Bool
            if case .cancel = command { isCancel = true } else { isCancel = false }
            if clock.now >= entry.ticket.deadline {
                state.entries.removeValue(forKey: command.token.ticketID); state.changed()
                return (entry, .expired, nil, entry.pending)
            }
            if let pending = entry.pending, !isCancel || pending.isCancel { return (nil, .invalid, nil, nil) }
            switch command {
            case .cancel: break
            case .collectBody: guard entry.ticket.state == .pausedHeaders else { return (nil, .invalid, nil, nil) }
            case .continue: guard entry.ticket.state == .pausedHeaders || entry.ticket.state == .pausedBody else { return (nil, .invalid, nil, nil) }
            }
            if case .continue(let token, var edit) = command, case .replace(let data) = edit.body {
                guard entry.ticket.state == .pausedBody, data.count <= limits.editorBodyBytes,
                      let io = entry.io else { return (nil, .invalid, nil, nil) }
                do {
                    edit.editorReservation = try io.budgets.reserve(category: .editor, bytes: Int64(data.count))
                    edit.editorPin = try io.runtime?.pin()
                }
                catch { return (nil, .invalid, nil, nil) }
                admitted = .continue(token: token, edit: edit)
            }
            let superseded = entry.pending
            entry.pending = Pending(id: operation, isCancel: isCancel, reply: reply)
            state.entries[command.token.ticketID] = entry
            return (entry, nil, admitted, superseded)
        }
        if let result = outcome.1 {
            outcome.3?.reply(result)
            outcome.0?.body?.cancel(); outcome.0?.imported?.cancel()
            outcome.0?.deliver(.end(.expired))
            reply(result)
        } else {
            outcome.3?.reply(.invalid)
            outcome.0?.deliver(.command(outcome.2!, operation: operation))
        }
    }
    func isPending(_ token: BreakpointCommandToken, operation: UUID) -> Bool {
        state.withLock { state in
            guard let entry = state.entries[token.ticketID], entry.ticket.token == token else { return false }
            return entry.pending?.id == operation
        }
    }
    /// Linearizes an owner-loop validation against cancel/expiry/revoke. A successful claim removes
    /// the reservation before the continuation runs; late deliveries cannot claim it a second time.
    func complete(_ token: BreakpointCommandToken, operation: UUID, result: BreakpointCommandResult, retaining: Bool = false) -> Bool {
        let claim: (Entry?, Pending?, BreakpointCommandResult) = state.withLock { state in
            guard var entry = state.entries[token.ticketID], entry.ticket.token == token,
                  let pending = entry.pending, pending.id == operation else { return (nil, nil, result) }
            if clock.now >= entry.ticket.deadline {
                state.entries.removeValue(forKey: token.ticketID); state.changed()
                return (entry, pending, .expired)
            }
            if result == .invalid || result == .unsupported || retaining {
                entry.pending = nil
                state.entries[token.ticketID] = entry
            } else { state.entries.removeValue(forKey: token.ticketID); state.changed() }
            return (nil, pending, result)
        }
        claim.0?.body?.cancel(); claim.0?.imported?.cancel()
        claim.1?.reply(claim.2)
        claim.0?.deliver(.end(.expired))
        return claim.1 != nil && claim.0 == nil
    }

    /// Atomically arbitrate body failure against cancellation, expiry and newer operations.
    /// Resource cleanup and replies always run outside S.
    func claimBodyFailure(_ token: BreakpointCommandToken, operation: UUID?) -> BreakpointCommandResult? {
        let claim: (Entry, BreakpointCommandResult)? = state.withLock { state in
            guard let entry = state.entries[token.ticketID], entry.ticket.token == token else { return nil }
            let expired = clock.now >= entry.ticket.deadline
            if !expired {
                guard entry.pending?.isCancel != true else { return nil }
                if let operation { guard entry.pending?.id == operation else { return nil } }
                else { guard entry.ticket.state == .collectingBody else { return nil } }
            }
            state.entries.removeValue(forKey: token.ticketID); state.changed()
            return (entry, expired ? .expired : .invalid)
        }
        guard let (entry, result) = claim else { return nil }
        entry.body?.cancel(); entry.imported?.cancel()
        entry.pending?.reply(result)
        return result
    }

    /// An owner-loop callback/timer may request expiry only while this ticket is still live.
    /// A prior revoke already owns its delivery; absence is never a new terminal decision.
    func claimExpiry(_ token: BreakpointCommandToken) -> Bool {
        let removed = state.withLock { state -> Entry? in
            guard let entry = state.entries[token.ticketID], entry.ticket.token == token,
                  clock.now >= entry.ticket.deadline else { return nil }
            state.entries.removeValue(forKey: token.ticketID); state.changed()
            return entry
        }
        removed?.body?.cancel(); removed?.imported?.cancel()
        removed?.pending?.reply(.expired)
        return removed != nil
    }

    func remove(_ token: BreakpointCommandToken, result: BreakpointCommandResult = .invalid) {
        let removed = state.withLock { state -> Entry? in
            guard state.entries[token.ticketID]?.ticket.token == token else { return nil }
            let entry = state.entries.removeValue(forKey: token.ticketID); state.changed(); return entry
        }
        removed?.body?.cancel(); removed?.imported?.cancel()
        removed?.pending?.reply(result)
    }
    func collecting(_ token: BreakpointCommandToken, io: BodyFileIO) -> Bool {
        state.withLock { state in
            guard var entry = state.entries[token.ticketID], entry.ticket.token == token,
                  entry.pending?.isCancel != true, clock.now < entry.ticket.deadline else { return false }
            entry.ticket.state = .collectingBody; entry.io = io
            state.entries[token.ticketID] = entry; state.changed(); return true
        }
    }
    func bodyReady(token: BreakpointCommandToken, source: ExactBodySource, originalTrailers: [HeaderField]) -> Bool {
        let accepted = state.withLock { state in
            guard var entry = state.entries[token.ticketID], entry.ticket.token == token,
                  entry.ticket.state == .collectingBody, entry.pending?.isCancel != true,
                  clock.now < entry.ticket.deadline else { return false }
            entry.body = source; entry.ticket.bodyLength = source.size; entry.ticket.state = .pausedBody
            state.entries[token.ticketID] = entry; state.changed(); return true
        }
        if !accepted { source.cancel() }
        return accepted
    }
    func bodyUnavailable(token: BreakpointCommandToken, reason: BreakpointBodyUnavailableReason) {
        state.withLock { state in
            guard var entry = state.entries[token.ticketID], entry.ticket.token == token,
                  entry.pending?.isCancel != true, clock.now < entry.ticket.deadline else { return }
            entry.ticket.bodyUnavailable = reason
            state.entries[token.ticketID] = entry; state.changed()
        }
    }
    public func bodyPreview(token: BreakpointCommandToken, offset: Int64, maxBytes: Int) async throws -> Data {
        let source = try state.withLock { state -> ExactBodySource in
            guard let entry = state.entries[token.ticketID], entry.ticket.token == token,
                  entry.ticket.state == .pausedBody, let body = entry.body else { throw OwnedFileError(.cancelled) }
            return body
        }
        let bytes = try await source.read(offset: offset, maxBytes: min(65_536, max(0, maxBytes)))
        guard state.withLock({ $0.entries[token.ticketID]?.ticket.token == token }) else { throw OwnedFileError(.cancelled) }
        return bytes
    }
    public func replaceBodyFromFile(token: BreakpointCommandToken, url: URL) async throws -> ExactBodySource {
        let io = try state.withLock { state -> BodyFileIO in
            guard let entry = state.entries[token.ticketID], entry.ticket.token == token,
                  entry.ticket.state == .pausedBody, let io = entry.io else { throw OwnedFileError(.cancelled) }
            return io
        }
        let source = try await io.importRegularFile(source: url, limit: Int64(limits.breakpointBodyBytes), category: .breakpoint)
        let old = state.withLock { state -> (Bool, ExactBodySource?) in
            guard var entry = state.entries[token.ticketID], entry.ticket.token == token,
                  entry.ticket.state == .pausedBody else { return (false, nil) }
            let old = entry.imported; entry.imported = source
            state.entries[token.ticketID] = entry; return (true, old)
        }
        old.1?.cancel()
        guard old.0 else { source.cancel(); throw OwnedFileError(.cancelled) }
        return source
    }
    func releaseImported(_ token: BreakpointCommandToken, preserving id: UUID? = nil) {
        let source = state.withLock { state -> ExactBodySource? in
            guard var entry = state.entries[token.ticketID], entry.ticket.token == token else { return nil }
            let source = entry.imported; entry.imported = nil
            state.entries[token.ticketID] = entry
            return source
        }
        if source?.lease.id != id { source?.cancel() }
    }
    func ownsReplacement(_ source: ExactBodySource, token: BreakpointCommandToken) -> Bool {
        state.withLock { $0.entries[token.ticketID]?.imported?.lease.id == source.lease.id }
    }
    public func snapshot() -> [BreakpointTicket] { state.withLock { $0.entries.values.map(\.ticket) } }
    public func changes() -> AsyncStream<UInt64> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            state.withLock { state in
                state.observers[id] = continuation
                continuation.yield(state.revision)
            }
            continuation.onTermination = { [weak self] _ in
                _ = self?.state.withLock { $0.observers.removeValue(forKey: id) }
            }
        }
    }
    public func revoke(flowIDs: Set<Int>, reason: BreakpointEndReason) {
        end(where: { $0.flowID.map(flowIDs.contains) ?? false }, reason: reason)
    }
    public func setAdmissionEnabled(_ enabled: Bool, existing: ExistingBreakpointPolicy) {
        end(where: { _ in existing == .cancel }, reason: .cancelled, update: { $0.admission = enabled })
    }
    /// Only a new server run reopens the run gate; the user's admission choice is independent.
    func beginRun() { state.withLock { $0.stopped = false } }
    public func shutdown() {
        end(where: { _ in true }, reason: .cancelled, update: { $0.stopped = true })
    }
    private func end(where predicate: @Sendable (BreakpointTicket) -> Bool, reason: BreakpointEndReason,
                     update: @Sendable (inout State) -> Void = { _ in }) {
        let entries = state.withLock { state in
            update(&state)
            let entries = state.entries.values.filter { predicate($0.ticket) }
            for entry in entries { state.entries.removeValue(forKey: entry.ticket.token.ticketID) }
            if !entries.isEmpty { state.changed() }
            return entries
        }
        for entry in entries {
            entry.body?.cancel(); entry.imported?.cancel()
            entry.pending?.reply(reason == .expired ? .expired : .invalid)
            entry.deliver(.end(reason))
        }
    }
}
