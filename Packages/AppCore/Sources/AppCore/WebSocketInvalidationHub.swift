import Foundation
import FlowStore
import Observation

/// One source subscription for the app; each window owns only a newest-one continuation.
@MainActor @Observable public final class WebSocketInvalidationHub {
    public private(set) var revision: UInt64 = 0
    public private(set) var generation: UInt64 = 0
    public private(set) var sourceSubscriptionCount = 0
    public private(set) var subscriberCount = 0
    @ObservationIgnored private var continuations: [UUID: AsyncStream<WebSocketInvalidation>.Continuation] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var stopped = false
    public init(store: FlowStore) {
        let source = store.webSocketChanges()
        sourceSubscriptionCount = 1
        task = Task { [weak self] in
            for await update in source {
                guard !Task.isCancelled, let self else { break }
                self.revision = update.revision; self.generation = update.generation
                for continuation in self.continuations.values { continuation.yield(update) }
            }
        }
    }
    public func updates() -> AsyncStream<WebSocketInvalidation> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<WebSocketInvalidation>.makeStream(bufferingPolicy: .bufferingNewest(1))
        if stopped { continuation.finish(); return stream }
        continuations[id] = continuation
        subscriberCount = continuations.count
        continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.removeSubscriber(id) } }
        return stream
    }
    public func stop() {
        stopped = true; task?.cancel(); task = nil; sourceSubscriptionCount = 0
        for continuation in continuations.values { continuation.finish() }
        continuations.removeAll(); subscriberCount = 0
    }
    private func removeSubscriber(_ id: UUID) { continuations.removeValue(forKey: id); subscriberCount = continuations.count }
    deinit { task?.cancel() }
}
