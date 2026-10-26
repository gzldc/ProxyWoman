import FlowStore
import NIOCore
import NIOPosix
import os

/// Coalesces client-app lookups: at most one process-table scan runs at a time (on the thread
/// pool), and it resolves every connection that was waiting when it started. Connections that
/// arrive during a scan wait for the next one. A page load that opens dozens of connections
/// therefore costs a couple of scans instead of one each.
final class ClientLookupBatcher: Sendable {
    private struct Waiter: Sendable {
        var clientPort: Int
        var proxyPort: Int
        var promise: EventLoopPromise<ClientApp?>
    }

    private struct State: Sendable {
        var waiting: [Waiter] = []
        var scanning = false
    }

    private let processLookup: ProcessLookup
    private let threadPool: NIOThreadPool
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(processLookup: ProcessLookup, threadPool: NIOThreadPool) {
        self.processLookup = processLookup
        self.threadPool = threadPool
    }

    /// The returned future never fails; it yields nil when no owner was found.
    func lookup(clientPort: Int, proxyPort: Int, on eventLoop: EventLoop) -> EventLoopFuture<ClientApp?> {
        let promise = eventLoop.makePromise(of: ClientApp?.self)
        let startScan = state.withLock { state in
            state.waiting.append(Waiter(clientPort: clientPort, proxyPort: proxyPort, promise: promise))
            guard !state.scanning else { return false }
            state.scanning = true
            return true
        }
        if startScan {
            threadPool.submit { workState in
                switch workState {
                case .active: self.scanUntilIdle()
                case .cancelled: self.resolveAllWithoutScanning()
                }
            }
        }
        return promise.futureResult
    }

    /// Runs on the thread pool. Keeps scanning while connections queued up during the last scan.
    private func scanUntilIdle() {
        while let batch = takeBatch() {
            for (proxyPort, waiters) in Dictionary(grouping: batch, by: \.proxyPort) {
                let owners = processLookup.lookupAll(Set(waiters.map(\.clientPort)), proxyPort)
                for waiter in waiters { waiter.promise.succeed(owners[waiter.clientPort]) }
            }
        }
    }

    /// The pool is shutting down: answer everyone with nil so no promise is left dangling.
    private func resolveAllWithoutScanning() {
        while let batch = takeBatch() {
            for waiter in batch { waiter.promise.succeed(nil) }
        }
    }

    /// Hands out everything waiting, or ends the scanning phase when nothing is.
    private func takeBatch() -> [Waiter]? {
        state.withLock { state in
            guard !state.waiting.isEmpty else {
                state.scanning = false
                return nil
            }
            defer { state.waiting.removeAll() }
            return state.waiting
        }
    }
}
