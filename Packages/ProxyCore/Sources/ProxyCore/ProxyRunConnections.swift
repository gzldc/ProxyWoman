import NIOCore
import os

/// Scheduling is injectable at the ownership boundary; production retains its finite 30 s grace.
struct ProxyDrainDeadline: Sendable {
    let schedule: @Sendable (EventLoop, @escaping @Sendable () -> Void) -> @Sendable () -> Void
    static let standard = ProxyDrainDeadline { loop, expire in
        let task = loop.scheduleTask(in: .seconds(30), expire)
        return { task.cancel() }
    }
}

/// One accepted/live/closing registry per server run. The lock only protects admission and
/// handles; context operations, completion callbacks and cancellation always run outside it.
/// Contexts retain their own pools and are removed only after their actual cleanup joins.
final class ProxyRunConnections: Sendable {
    private struct Entry: Sendable {
        let channel: Channel
        var context: NIOLoopBound<ClientConnectionContext>?
    }
    private struct State: Sendable {
        var accepting = true
        var draining = false
        var deadlineReady = false
        var completed = false
        var entries: [ObjectIdentifier: Entry] = [:]
        var cancelDeadline: (@Sendable () -> Void)?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let loop: EventLoop
    private let deadline: ProxyDrainDeadline
    private let completion: EventLoopPromise<Void>
    init(loop: EventLoop, deadline: ProxyDrainDeadline = .standard) {
        self.loop = loop; self.deadline = deadline; completion = loop.makePromise()
    }
    var permitsExchange: Bool { state.withLock { $0.accepting } }

    func accept(_ channel: Channel) -> Bool {
        let admitted = state.withLock { state in
            guard state.accepting else { return false }
            state.entries[ObjectIdentifier(channel)] = Entry(channel: channel)
            return true
        }
        if admitted {
            channel.closeFuture.whenComplete { [self] _ in
                let unattached = state.withLock { $0.entries[ObjectIdentifier(channel)]?.context == nil }
                if unattached { remove(channel) }
            }
        }
        return admitted
    }
    func attach(_ context: ClientConnectionContext) {
        let channel = context.channel
        let owner = NIOLoopBound(context, eventLoop: channel.eventLoop)
        let retained = state.withLock { state in
            guard state.entries[ObjectIdentifier(channel)] != nil else { return false }
            state.entries[ObjectIdentifier(channel)]?.context = owner
            return true
        }
        context.cleanupFuture.whenComplete { [self] _ in remove(channel) }
        if !retained { context.forceClose() }
    }
    func stopAdmission() { state.withLock { $0.accepting = false } }

    /// Idempotent; no caller cancellation can abandon the registry's cleanup.
    func drain() -> EventLoopFuture<Void> {
        let start = state.withLock { state in
            guard !state.draining else { return false }
            state.accepting = false; state.draining = true
            return true
        }
        guard start else { return completion.futureResult }
        let cancel = deadline.schedule(loop) { [self] in
            let entries = state.withLock { Array($0.entries.values) }
            for entry in entries {
                entry.channel.eventLoop.execute {
                    if let context = entry.context { context.value.forceClose() }
                    else { entry.channel.close(promise: nil) }
                }
            }
        }
        let entries = state.withLock { state in state.cancelDeadline = cancel; state.deadlineReady = true; return Array(state.entries.values) }
        for entry in entries {
            entry.channel.eventLoop.execute {
                if let context = entry.context { context.value.beginDrain() }
                else { entry.channel.close(promise: nil) }
            }
        }
        finishIfEmpty()
        return completion.futureResult
    }
    private func remove(_ channel: Channel) {
        _ = state.withLock { $0.entries.removeValue(forKey: ObjectIdentifier(channel)) }
        finishIfEmpty()
    }
    private func finishIfEmpty() {
        let action: (Bool, (@Sendable () -> Void)?) = state.withLock { state in
            guard state.draining, state.deadlineReady, state.entries.isEmpty, !state.completed else { return (false, nil) }
            state.completed = true
            let cancel = state.cancelDeadline; state.cancelDeadline = nil
            return (true, cancel)
        }
        action.1?()
        if action.0 { completion.succeed(()) }
    }
}
