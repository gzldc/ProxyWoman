import Foundation
import os

public enum MCPCallOutcome: Sendable, Equatable {
    case ok
    case denied(Denial)
    case invalidArguments
    case failed(code: String)

    public enum Denial: Sendable, Equatable {
        case disabled
        case permission(tool: String)
        case enablingNotAllowed
    }
}

public struct MCPAuditEntry: Identifiable, Sendable, Equatable {
    public var id: UUID
    public var at: Date
    public var client: String?
    public var tool: String
    /// Already redacted and truncated by the caller (`MCPRedactor.summary`).
    public var arguments: String
    public var outcome: MCPCallOutcome
    public var durationMs: Int

    public init(
        id: UUID = UUID(), at: Date = Date(), client: String?, tool: String, arguments: String,
        outcome: MCPCallOutcome, durationMs: Int
    ) {
        self.id = id
        self.at = at
        self.client = client
        self.tool = tool
        self.arguments = arguments
        self.outcome = outcome
        self.durationMs = durationMs
    }
}

/// In-memory ring of the most recent calls (spec D16). Never persisted.
public final class MCPAuditLog: Sendable {
    public static let capacity = 200

    private struct State {
        var entries: [MCPAuditEntry] = []
        var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public func record(_ entry: MCPAuditEntry) {
        let subscribers = state.withLock { state -> [AsyncStream<Void>.Continuation] in
            state.entries.insert(entry, at: 0)
            if state.entries.count > Self.capacity {
                state.entries.removeLast(state.entries.count - Self.capacity)
            }
            return Array(state.subscribers.values)
        }
        subscribers.forEach { $0.yield() }
    }

    /// Newest first.
    public func snapshot() -> [MCPAuditEntry] {
        state.withLock { $0.entries }
    }

    public func clear() {
        let subscribers = state.withLock { state -> [AsyncStream<Void>.Continuation] in
            state.entries.removeAll()
            return Array(state.subscribers.values)
        }
        subscribers.forEach { $0.yield() }
    }

    /// Live `changes()` consumers (for tests and diagnostics).
    var subscriberCount: Int { state.withLock { $0.subscribers.count } }

    /// One signal per change; signals coalesce while the consumer is behind. Every call returns an
    /// independent stream; it is removed when the consumer stops iterating.
    public func changes() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        state.withLock { $0.subscribers[id] = continuation }
        continuation.onTermination = { [state] _ in
            state.withLock { _ = $0.subscribers.removeValue(forKey: id) }
        }
        return stream
    }
}
