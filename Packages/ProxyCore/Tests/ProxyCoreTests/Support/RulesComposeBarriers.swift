import FlowStore
import Foundation
import NIOCore
import NIOHTTP1
import Testing
@testable import ProxyCore
@testable import RulesEngine

/// Event barriers for the rules/breakpoint/Compose end-to-end tests. Each wait is driven by the
/// production change feed (`BreakpointCoordinator.changes()`) or a polled real counter, and fails
/// after a bounded deadline instead of hanging; nothing waits by sleeping for a fixed time.
enum RulesComposeBarriers {
    /// The first published ticket matching `predicate` ("ticket created" / "body collected").
    static func ticket(_ coordinator: BreakpointCoordinator, on loop: EventLoop,
                       where predicate: @escaping @Sendable (BreakpointTicket) -> Bool = { _ in true }) async throws -> BreakpointTicket {
        let promise = loop.makePromise(of: BreakpointTicket.self)
        let watcher = Task {
            for await _ in coordinator.changes() {
                if let ticket = coordinator.snapshot().first(where: predicate) { promise.succeed(ticket); return }
            }
        }
        defer { watcher.cancel() }
        do { return try await promise.futureResult.boundedGet() }
        catch { throw WaitTimeout(description: "no matching ticket; tickets: \(coordinator.snapshot())") }
    }

    /// Exactly `count` tickets are published (in no particular order).
    static func tickets(_ coordinator: BreakpointCoordinator, count: Int, on loop: EventLoop) async throws -> [BreakpointTicket] {
        let promise = loop.makePromise(of: [BreakpointTicket].self)
        let watcher = Task {
            for await _ in coordinator.changes() {
                let tickets = coordinator.snapshot()
                if tickets.count == count { promise.succeed(tickets); return }
            }
        }
        defer { watcher.cancel() }
        do { return try await promise.futureResult.boundedGet() }
        catch { throw WaitTimeout(description: "expected \(count) tickets; tickets: \(coordinator.snapshot())") }
    }

    /// Every ticket ended (continued, cancelled, revoked, expired or shut down).
    static func noTickets(_ coordinator: BreakpointCoordinator, on loop: EventLoop) async throws {
        let promise = loop.makePromise(of: Void.self)
        let watcher = Task {
            for await _ in coordinator.changes() where coordinator.snapshot().isEmpty { promise.succeed(()); return }
        }
        defer { watcher.cancel() }
        do { try await promise.futureResult.boundedGet() }
        catch { throw WaitTimeout(description: "tickets still held: \(coordinator.snapshot())") }
    }

    /// Every client connection of `fixture` returned its pending quota, holds no exchange or pool
    /// acquisition, the coordinator holds no ticket, and no exact-body pin or I/O/breakpoint
    /// budget is held. Persistent asset bytes are not a transient resource and stay charged.
    static func expectIdle(_ fixture: HTTP2ProxyFixture, breakpoints: BreakpointCoordinator? = nil,
                           sourceLocation: SourceLocation = #_sourceLocation) async throws {
        await fixture.bodyRuntime.drain()
        for owner in fixture.connections.withLock({ $0 }) {
            let (connection, pool) = try await owner.eventLoop.submit {
                (owner.value.snapshot, owner.value.upstreamPool.snapshot)
            }.boundedGet()
            #expect(connection.pendingBytes == 0, "pending bytes", sourceLocation: sourceLocation)
            #expect(connection.exchanges.isEmpty, "live exchanges \(connection.exchanges.map(\.path))", sourceLocation: sourceLocation)
            #expect(pool.waiting == 0 && pool.connecting == 0 && pool.opening == 0 && pool.pending == 0,
                    "pool acquisitions", sourceLocation: sourceLocation)
            #expect(pool.sessions.allSatisfy { $0.activeStreams == 0 && $0.reservedStreams == 0 && $0.creatingStreams == 0 },
                    "h2 streams", sourceLocation: sourceLocation)
        }
        #expect(breakpoints?.snapshot().isEmpty ?? true, "tickets", sourceLocation: sourceLocation)
        let budget = fixture.bodyRuntime.budgets.snapshot()
        #expect([OwnedFileBudgetCategory.io, .breakpoint, .editor, .compose].allSatisfy { budget.bytes[$0, default: 0] == 0 }, "budgets \(budget.bytes)", sourceLocation: sourceLocation)
        #expect(fixture.bodyRuntime.activePins == 0, "body pins", sourceLocation: sourceLocation)
    }
}

/// One HTTP/1 response read off a raw socket, decoded independently of the proxy's codecs.
struct RawHTTP1Response {
    let head: String
    let body: [UInt8]
    var statusLine: String { String(head.prefix { $0 != "\r" }) }
    /// Values of `name` (case-insensitive) in the head.
    func header(_ name: String) -> [String] {
        head.components(separatedBy: "\r\n").dropFirst().compactMap { line in
            guard let colon = line.firstIndex(of: ":"), line[..<colon].lowercased() == name.lowercased() else { return nil }
            return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
    }

    /// Parses exactly one response (Content-Length or chunked) from `bytes`; nil if incomplete.
    static func parse(_ bytes: [UInt8]) -> (response: RawHTTP1Response, rest: [UInt8])? {
        let separator = Array("\r\n\r\n".utf8)
        guard let end = bytes.indices.first(where: { bytes[$0...].starts(with: separator) }) else { return nil }
        let head = String(decoding: bytes[..<end], as: UTF8.self)
        var index = end + separator.count
        let probe = RawHTTP1Response(head: head, body: [])
        if let length = probe.header("content-length").first.flatMap(Int.init) {
            guard bytes.count - index >= length else { return nil }
            return (RawHTTP1Response(head: head, body: Array(bytes[index..<index + length])), Array(bytes[(index + length)...]))
        }
        guard probe.header("transfer-encoding").contains(where: { $0.lowercased().contains("chunked") }) else {
            return (RawHTTP1Response(head: head, body: Array(bytes[index...])), [])
        }
        var body: [UInt8] = []
        let crlf = Array("\r\n".utf8)
        while true {
            guard let lineEnd = bytes[index...].indices.first(where: { bytes[$0...].starts(with: crlf) }) else { return nil }
            let sizeText = String(decoding: bytes[index..<lineEnd], as: UTF8.self).split(separator: ";").first ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else { return nil }
            index = lineEnd + 2
            if size == 0 {
                // Trailer lines, each ending in CRLF, up to the empty line.
                while true {
                    guard let next = bytes[index...].indices.first(where: { bytes[$0...].starts(with: crlf) }) else { return nil }
                    let empty = next == index
                    index = next + 2
                    if empty { break }
                }
                return (RawHTTP1Response(head: head, body: body), Array(bytes[index...]))
            }
            guard bytes.count >= index + size + 2 else { return nil }
            body += bytes[index..<index + size]
            index += size + 2
        }
    }
}
