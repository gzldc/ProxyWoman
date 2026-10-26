import Foundation

extension FlowStore {
    /// The newest `limit` flows, ascending by id. Walks back from the tail of the contiguous id
    /// range `lowestID..<nextID` under the lock and copies only the flows it returns, so the cost
    /// is O(limit) (plus skipped hidden flows) regardless of how many flows are retained.
    /// `limit` counts visible flows unless `includeHidden` is true.
    public func recentFlows(limit: Int, includeHidden: Bool = false) -> [Flow] {
        guard limit > 0 else { return [] }
        let newestFirst = state.withLock { state -> [Flow] in
            var result: [Flow] = []
            result.reserveCapacity(min(limit, state.flows.count))
            var id = state.nextID - 1
            while id >= state.lowestID, result.count < limit {
                if let flow = state.flows[id], includeHidden || !flow.isHidden { result.append(flow) }
                id -= 1
            }
            return result
        }
        return newestFirst.reversed()
    }

    /// Ids of all visible (non-hidden) flows, ascending. Collects only ids under the lock; no
    /// `Flow` is copied.
    public func visibleFlowIDs() -> [Int] {
        state.withLock { state in
            var ids: [Int] = []
            ids.reserveCapacity(state.flows.count)
            var id = state.lowestID
            while id < state.nextID {
                if let flow = state.flows[id], !flow.isHidden { ids.append(id) }
                id += 1
            }
            return ids
        }
    }

    /// Changes whenever a retained flow changes or a WebSocket session opens or finishes closing. Two equal stamps
    /// mean nothing a live count reads has moved; it costs one lock and no copying, so a poller can gate on it.
    public var changeStamp: FlowChangeStamp {
        state.withLock { FlowChangeStamp(flows: $0.mutationCount, webSocketLifecycle: $0.webSockets.lifecycleRevision) }
    }

    /// Ids of flows whose WebSocket session is still open (its 101 exchange may long be complete).
    public func openWebSocketFlowIDs() -> Set<Int> {
        state.withLock { state in
            Set(state.webSockets.sessions.compactMap { $0.value.summary.lifecycle == .open ? $0.key : nil })
        }
    }
}

public struct FlowChangeStamp: Sendable, Equatable {
    public let flows: UInt64
    public let webSocketLifecycle: UInt64
}
