import AppCore
import FlowStore
import Foundation
import ProxyCore
import os
import RulesEngine

/// The AppCore breakpoint facade over the app's single `BreakpointCoordinator` (the one the proxy
/// server uses). It keeps no ticket state of its own: every call reads or commands the coordinator
/// and converts its types to Foundation-only copies.
final class ProxyBreakpointClient: BreakpointClient {
    private let coordinator: BreakpointCoordinator
    /// Must share the coordinator's monotonic timeline (the system clock in the app).
    private let clock: any BreakpointClock
    /// The latest file import per ticket: the AppCore handle and the proxy's spooled copy, which
    /// the coordinator owns (it is released when the ticket ends or a newer import replaces it).
    private let imports = OSAllocatedUnfairLock<[UUID: (handle: UUID, source: ExactBodySource)]>(initialState: [:])

    init(coordinator: BreakpointCoordinator, clock: any BreakpointClock = SystemBreakpointClock()) {
        self.coordinator = coordinator
        self.clock = clock
    }

    func tickets() async -> [BreakpointTicketSnapshot] {
        let now = clock.now.uptimeNanoseconds
        let wall = Date()
        let tickets = coordinator.snapshot()
        let live = Set(tickets.map(\.token.ticketID.raw))
        imports.withLock { $0 = $0.filter { live.contains($0.key) } }
        return tickets.map { Self.snapshot($0, now: now, wall: wall) }
    }

    func changes() -> AsyncStream<UInt64> {
        coordinator.changes()
    }

    /// Reads the collected body from its start in the coordinator's bounded chunks.
    func loadBody(_ token: BreakpointTicketToken, maxBytes: Int) async throws -> BreakpointBodyPreview {
        guard let ticket = coordinator.snapshot().first(where: { $0.token.ticketID.raw == token.id }),
              let total = ticket.bodyLength else { throw CancellationError() }
        let core = Self.coreToken(token)
        let limit = Int(min(Int64(max(0, maxBytes)), total))
        var data = Data()
        data.reserveCapacity(limit)
        while data.count < limit {
            try Task.checkCancellation()
            let chunk = try await coordinator.bodyPreview(token: core, offset: Int64(data.count), maxBytes: limit - data.count)
            guard !chunk.isEmpty else { break }
            data.append(chunk.prefix(limit - data.count))
        }
        return BreakpointBodyPreview(data: data, totalLength: total)
    }

    func perform(_ command: BreakpointClientCommand) async -> BreakpointClientResult {
        let result: BreakpointCommandResult
        switch command {
        case .continue(let token, let edit):
            let body: BreakpointBodyEdit
            switch edit.body {
            case .unchanged: body = .unchanged
            case .replace(let data): body = .replace(data)
            case .file(let file):
                let source = imports.withLock { imports -> ExactBodySource? in
                    guard let entry = imports[token.id], entry.handle == file.id else { return nil }
                    return entry.source
                }
                guard let source else { return .invalid }
                body = .replaceSource(source)
            }
            result = await coordinator.perform(.continue(
                token: Self.coreToken(token),
                edit: BreakpointEdit(head: edit.head, body: body, bodyEncodingChoice: edit.encodingChoice)))
        case .cancel(let token):
            result = await coordinator.perform(.cancel(token: Self.coreToken(token)))
        case .collectBody(let token):
            result = await coordinator.perform(.collectBody(token: Self.coreToken(token)))
        }
        switch result {
        case .accepted: return .accepted
        case .expired: return .expired
        case .invalid: return .invalid
        case .unsupported: return .unsupported
        }
    }

    /// The coordinator streams the regular file into this ticket's private spool on its file I/O
    /// pool (size-limited, change-checked); only the handle comes back.
    func replaceBodyFromFile(_ token: BreakpointTicketToken, url: URL) async throws -> BreakpointImportedBody {
        let source = try await coordinator.replaceBodyFromFile(token: Self.coreToken(token), url: url)
        let handle = UUID()
        imports.withLock { $0[token.id] = (handle, source) }
        return BreakpointImportedBody(id: handle, size: source.size, fileName: url.lastPathComponent)
    }

    func setAdmission(enabled: Bool, cancelExisting: Bool) async {
        coordinator.setAdmissionEnabled(enabled, existing: cancelExisting ? .cancel : .keep)
    }

    /// The same revocation a flow removal triggers; a ticket already ended is not touched again.
    func cancelTickets(forFlows flowIDs: Set<Int>) async {
        coordinator.revoke(flowIDs: flowIDs, reason: .cancelled)
    }

    // MARK: conversion

    private static func coreToken(_ token: BreakpointTicketToken) -> BreakpointCommandToken {
        BreakpointCommandToken(ticketID: BreakpointTicketID(raw: token.id), generation: token.generation, revision: token.revision)
    }

    private static func snapshot(_ ticket: BreakpointTicket, now: UInt64, wall: Date) -> BreakpointTicketSnapshot {
        func date(_ uptime: UInt64) -> Date {
            let delta = uptime >= now ? Double(uptime - now) : -Double(now - uptime)
            return wall.addingTimeInterval(delta / 1_000_000_000)
        }
        let phase: BreakpointTicketPhase
        switch ticket.state {
        case .pausedHeaders: phase = .pausedHeaders
        case .collectingBody: phase = .collectingBody
        case .pausedBody: phase = .pausedBody
        case .forwarding: phase = .forwarding
        case .cancelled, .expired, .failed: phase = .ended
        }
        let isCompose: Bool
        if case .compose = ticket.source { isCompose = true } else { isCompose = false }
        return BreakpointTicketSnapshot(
            token: BreakpointTicketToken(id: ticket.token.ticketID.raw, generation: ticket.token.generation, revision: ticket.token.revision),
            flowID: ticket.flowID, direction: ticket.direction, originalHead: ticket.originalHead, effectiveHead: ticket.effectiveHead,
            isLocalRoute: ticket.routeKind == .local, isCompose: isCompose, mode: ticket.mode, phase: phase,
            matchedAt: date(ticket.matchedAt.uptimeNanoseconds), deadline: date(ticket.deadline.uptimeNanoseconds),
            matchedRuleIDs: ticket.matches.ruleIDs, matchedRuleCount: ticket.matches.total,
            bodyLength: ticket.bodyLength, bodyTooLargeToCollect: ticket.bodyUnavailable == .knownLengthTooLarge)
    }
}
