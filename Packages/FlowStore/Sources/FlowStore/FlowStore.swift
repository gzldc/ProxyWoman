import Foundation
import os

/// 一个批次。应用顺序：先 `cleared`，再删除 `removed`（被淘汰的旧记录，id 升序），最后 `upserted`。
public struct FlowChange: Sendable {
    public var cleared: Bool
    public var removed: [Int]
    public var upserted: [Flow]

    public init(cleared: Bool, removed: [Int] = [], upserted: [Flow]) {
        self.cleared = cleared
        self.removed = removed
        self.upserted = upserted
    }
}

/// 抓包数据层。代理引擎从任意线程写入，界面通过 `changes()` 订阅批量变更。
/// 用加锁的 `Sendable` 类而不是 actor，保证来自 NIO 线程的事件严格按调用顺序生效。
///
/// 最多保留 `maxFlows` 条记录、`maxSpilledBytes` 字节的落盘 body、`maxResidentBodyBytes` 字节的内存 body；
/// 超出时淘汰最旧的记录（id 最小）
/// 并删除它们的落盘文件，订阅者通过 `FlowChange.removed` 得知。
/// `maxActiveBodyBytes` 限制同一 store 的活动 capture 缓冲。两项内存预算只约束记录层保留量，
/// 不涵盖订阅者、UI、导出持有的副本、解码及网络缓冲，也不限制整个进程 RSS。
public final class FlowStore: Sendable {
    public static let defaultMaxFlows = 100_000
    public static let defaultMaxSpilledBytes = 2 * 1024 * 1024 * 1024
    public static let defaultMaxResidentBodyBytes = 128 * 1_048_576
    public static let defaultMaxActiveBodyBytes = 32 * 1_048_576

    struct State {
        var webSockets = WebSocketStore()
        var nextID = 1
        /// 现存记录的 id 是连续区间 `lowestID..<nextID`：只从最旧的一端淘汰，`clear()` 全部清掉。
        var lowestID = 1
        var flows: [Int: Flow] = [:]
        var removalActions: [Int: [@Sendable () -> Void]] = [:]
        /// 现存记录引用的落盘 body 的总字节数。
        var spilledBytes = 0
        /// 现存记录的请求和响应 `.memory` body 的总字节数。
        var residentBodyBytes = 0
        var pending: Set<Int> = []
        /// 已建档、但尚未向订阅者发布的 id（`begin(deferringPublication:)`）。
        var held: Set<Int> = []
        /// 已淘汰、尚未通知订阅者的 id，升序。
        var removed: [Int] = []
        var cleared = false
        /// 现存记录中 `isHidden` 的条数。
        var hiddenCount = 0
        var subscriber: Subscriber?
        /// Bumped by every change to the retained flows (begin, update, clear, eviction); see `changeStamp`.
        var mutationCount: UInt64 = 0
    }

    struct Subscriber {
        let id: UUID
        let continuation: AsyncStream<FlowChange>.Continuation
        let task: Task<Void, Never>
    }

    private let bodyDirectory: URL
    private let batchInterval: Duration
    private let maxFlows: Int
    private let maxSpilledBytes: Int
    private let maxCapturedBodyBytes: Int
    private let maxResidentBodyBytes: Int
    private let activeBodyBudget: BodyMemoryBudget
    /// Ownership table of the bodies this store created; the only source of deletion authority.
    let bodies = HTTPBodyRegistry()
    let state = OSAllocatedUnfairLock(initialState: State())

    public let webSocketLimits: WebSocketLimits
    public let webSocketBudget: WebSocketMemoryBudget

    public init(
        bodyDirectory: URL,
        batchInterval: Duration = .milliseconds(100),
        maxFlows: Int = FlowStore.defaultMaxFlows,
        maxSpilledBytes: Int = FlowStore.defaultMaxSpilledBytes,
        maxCapturedBodyBytes: Int = BodyCapture.defaultMaxCapturedBytes,
        maxResidentBodyBytes: Int = FlowStore.defaultMaxResidentBodyBytes,
        maxActiveBodyBytes: Int = FlowStore.defaultMaxActiveBodyBytes,
        webSocketLimits: WebSocketLimits = .init()
    ) {
        self.webSocketLimits = webSocketLimits
        self.webSocketBudget = WebSocketMemoryBudget(limits: webSocketLimits)
        self.bodyDirectory = bodyDirectory
        self.batchInterval = batchInterval
        self.maxFlows = max(0, maxFlows)
        self.maxSpilledBytes = max(0, maxSpilledBytes)
        self.maxCapturedBodyBytes = maxCapturedBodyBytes
        self.maxResidentBodyBytes = max(0, maxResidentBodyBytes)
        self.activeBodyBudget = BodyMemoryBudget(limit: maxActiveBodyBytes)
    }

    deinit {
        let old = state.withLock { state in
            let sessions = Array(state.webSockets.sessions.values)
            for token in state.webSockets.sessions.values.map(\.token) { state.webSockets.invalidateExportToken(token) }
            state.webSockets.sessions.removeAll()
            return (sessions, state.webSockets.subscriber, state.subscriber)
        }
        old.0.forEach { $0.cancel() }; old.1?.finish(); old.2?.continuation.finish()
    }

    /// `make` 收到新分配的 id，必须返回使用该 id 的 Flow。它在锁内执行，不要在里面回调 store。
    ///
    /// `deferringPublication: true`：记录照常建立，直接读取都读得到，但不进入给订阅者的批次，
    /// 直到 `publish(_:)`，或它的 `state` 离开 `.inProgress`。
    @discardableResult
    public func begin(deferringPublication: Bool = false, _ make: (Int) -> Flow) -> Int {
        var revoked: [WebSocketStoredSession] = []
        var removalActions: [@Sendable () -> Void] = []
        let ((id, evictedFiles), invalidated) = mutateWebSocketState { state in
            let id = state.nextID
            state.nextID += 1
            var flow = make(id)
            precondition(flow.id == id, "begin(_:) must return a Flow with the id it was given")
            retainBodies(of: &flow, in: &state)
            state.flows[id] = flow
            state.mutationCount &+= 1
            if flow.isHidden { state.hiddenCount += 1 }
            if deferringPublication { state.held.insert(id) } else { state.pending.insert(id) }
            return (id, evict(&state, revoked: &revoked, removalActions: &removalActions))
        }
        // Plain HTTP progress drains only exports this call invalidated (flow eviction).
        removalActions.forEach { $0() }
        drainWebSocketExports(invalidated)
        revoked.forEach { $0.cancel() }
        HTTPBodyRegistry.discard(evictedFiles)
        return id
    }

    /// 对不存在的 id（已被 `clear()` 清掉或被淘汰）不记录，只放弃这次更新带来的、store 自己创建的 body。
    /// 借用的 `.file` 永远不会被删除。`mutate` 在锁内执行。
    /// 返回 true 表示记录存在且已更新；false 表示记录已不存在（行为同上，仍放弃带来的 body）。
    @discardableResult
    public func update(_ id: Int, _ mutate: (inout Flow) -> Void) -> Bool {
        var found = true
        var revoked: [WebSocketStoredSession] = []
        var removalActions: [@Sendable () -> Void] = []
        let (reclaims, invalidated) = mutateWebSocketState { state -> [HTTPBodyRegistry.Reclaim] in
            guard var flow = state.flows[id] else {
                found = false
                var scratch = Flow(id: id, scheme: "", method: "", host: "", port: 0, path: "")
                mutate(&scratch)
                return abandonRejectedBodies(of: scratch)
            }
            let old = flow
            mutate(&flow)
            // Acquire the new references before dropping the old ones so an unchanged alias never dips to zero.
            retainBodies(of: &flow, in: &state)
            state.flows[id] = flow
            state.mutationCount &+= 1
            if old.isHidden != flow.isHidden { state.hiddenCount += flow.isHidden ? 1 : -1 }
            var reclaims = releaseBodies(of: old, in: &state)
            if state.held.contains(id), flow.state != .inProgress { state.held.remove(id) }
            if !state.held.contains(id) { state.pending.insert(id) }
            reclaims += evict(&state, revoked: &revoked, removalActions: &removalActions)
            return reclaims
        }
        removalActions.forEach { $0() }
        drainWebSocketExports(invalidated)
        revoked.forEach { $0.cancel() }
        HTTPBodyRegistry.discard(reclaims)
        return found
    }

    /// 解除发布闸，让这条记录以当前状态进入下一批。未知 id、没被扣住的 id 是空操作；幂等。
    public func publish(_ id: Int) {
        state.withLock { state in
            guard state.held.remove(id) != nil, state.flows[id] != nil else { return }
            state.pending.insert(id)
        }
    }

    /// Registers once against a retained flow. Removal extracts callbacks under S and invokes
    /// them after unlocking, before any export drain or file cleanup can block.
    public func registerFlowRemoval(flowID: Int, action: @escaping @Sendable () -> Void) -> Bool {
        state.withLock { state in
            guard state.flows[flowID] != nil else { return false }
            state.removalActions[flowID, default: []].append(action)
            return true
        }
    }

    public func flow(_ id: Int) -> Flow? {
        state.withLock { $0.flows[id] }
    }

    /// 按 id 升序。
    public func allFlows() -> [Flow] {
        // Copy under the lock, sort outside it: capture's begin/update take the same lock.
        let flows = state.withLock { Array($0.flows.values) }
        return flows.sorted { $0.id < $1.id }
    }

    /// Number of retained flows; O(1).
    public var flowCount: Int {
        state.withLock { $0.flows.count }
    }

    /// 清空记录，并在解锁后删除只由这些记录拥有的、store 自己登记的 body 文件（读取者读完后回收）。
    /// 调用方借用的 `.file` 永不删除；新记录和活动 capture 的文件不受影响；旧 id 迟到更新的 body 由 update 放弃。id 不回绕。
    public func clear() {
        clear(beforeRemovingFiles: {})
    }

    /// Internal cleanup barrier: invoked after resetting state, outside all locks.
    /// The public path uses a no-op; tests can hold cleanup while captures progress.
    func clear(beforeRemovingFiles: @Sendable () -> Void) {
        let ((clearedFiles, revoked, removalActions), invalidated) = mutateWebSocketState { state in
            let oldFlows = Array(state.flows.values)
            var files: [HTTPBodyRegistry.Reclaim] = []
            for flow in oldFlows { files += releaseBodies(of: flow, in: &state) }
            state.flows.removeAll()
            state.mutationCount &+= 1
            state.lowestID = state.nextID
            state.spilledBytes = 0
            state.residentBodyBytes = 0
            state.hiddenCount = 0
            state.pending.removeAll()
            state.held.removeAll()
            state.removed.removeAll()
            state.cleared = true
            let revoked = Array(state.webSockets.sessions.values)
            for token in state.webSockets.sessions.values.map(\.token) { state.webSockets.invalidateExportToken(token) }
            state.webSockets.sessions.removeAll(); state.webSockets.retainedEventCount = 0
            if state.webSockets.generation < .max { state.webSockets.generation += 1 }
            state.webSockets.changed()
            let actions = state.removalActions.values.flatMap { $0 }
            state.removalActions.removeAll()
            return (files, revoked, actions)
        }
        removalActions.forEach { $0() }
        drainAllInvalidatedWebSocketExports(including: invalidated)
        revoked.forEach { $0.cancel() }
        beforeRemovingFiles()
        HTTPBodyRegistry.discard(clearedFiles)
    }

    public func makeBodyCapture() -> BodyCapture {
        BodyCapture(
            directory: bodyDirectory, maxCapturedBytes: maxCapturedBodyBytes, budget: activeBodyBudget,
            registry: bodies)
    }

    /// Opens a bounded, revocable read lease. Managed bodies are revoked when the store drops them;
    /// borrowed `.memory`/`.file` inputs are read-only and never owned.
    public func acquireBody(_ body: BodyRef) throws -> HTTPBodyReadLease {
        switch body {
        case .managed(let handle):
            return try handle.registry.acquire(handle)
        case .memory(let data):
            return HTTPBodyReadLease(size: data.count, source: .memory(data), owner: nil)
        case .file(let url, let size):
            let descriptor = try HTTPBodyReadLease.openBorrowedFile(url)
            return HTTPBodyReadLease(size: max(0, size), source: .file(descriptor), owner: nil)
        }
    }

    /// Wraps bytes the caller produced as a store-owned body. Nothing is charged until a flow
    /// stores it; a handle nobody stores is discarded when its last copy dies.
    public func makeManagedBody(_ data: Data) -> BodyRef {
        .managed(bodies.registerMemory(data))
    }

    func bodyOwnershipSnapshot() -> HTTPBodyRegistry.OwnershipSnapshot { bodies.snapshot() }

    /// 单订阅者：再次调用会结束旧的流并替换它。
    public func changes() -> AsyncStream<FlowChange> {
        let (stream, continuation) = AsyncStream<FlowChange>.makeStream()
        let interval = batchInterval
        let subscriberID = UUID()
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                self.flush(subscriberID: subscriberID, to: continuation)
            }
        }

        let previous = state.withLock { state in
            let previous = state.subscriber
            state.subscriber = Subscriber(id: subscriberID, continuation: continuation, task: task)
            // 重新同步：新订阅者（空的 FlowCollection）的第一个批次包含全部现有记录，
            // 也覆盖旧订阅者被取消时丢失的批次。
            state.pending.formUnion(Set(state.flows.keys).subtracting(state.held))
            return previous
        }
        previous?.task.cancel()
        previous?.continuation.finish()

        continuation.onTermination = { [weak self] _ in
            task.cancel()
            self?.state.withLock { state in
                // 只清理自己；已被新订阅替换时不要动新的。
                if state.subscriber?.id == subscriberID { state.subscriber = nil }
            }
        }
        return stream
    }

    private func flush(subscriberID: UUID, to continuation: AsyncStream<FlowChange>.Continuation) {
        let change: FlowChange? = state.withLock { state in
            // 只有当前订阅者的任务可以取走批次。
            guard state.subscriber?.id == subscriberID else { return nil }
            guard state.cleared || !state.pending.isEmpty || !state.removed.isEmpty else { return nil }
            let upserted = state.pending.sorted().compactMap { state.flows[$0] }
            let change = FlowChange(cleared: state.cleared, removed: state.removed, upserted: upserted)
            state.pending.removeAll()
            state.removed.removeAll()
            state.cleared = false
            return change
        }
        if let change { continuation.yield(change) }
    }

    // MARK: - Limits

    /// Drops the oldest flows while a limit is exceeded; returns the owned files to unlink
    /// once the lock is released.
    private func evict(_ state: inout State, revoked: inout [WebSocketStoredSession],
                       removalActions: inout [@Sendable () -> Void]) -> [HTTPBodyRegistry.Reclaim] {
        var files: [HTTPBodyRegistry.Reclaim] = []
        while !state.flows.isEmpty,
            state.flows.count > maxFlows || state.spilledBytes > maxSpilledBytes
                || state.residentBodyBytes > maxResidentBodyBytes
        {
            let id = state.lowestID
            state.lowestID += 1
            guard let flow = state.flows.removeValue(forKey: id) else { continue }
            if flow.isHidden { state.hiddenCount -= 1 }
            removalActions += state.removalActions.removeValue(forKey: id) ?? []
            files += releaseBodies(of: flow, in: &state)
            state.pending.remove(id)
            state.held.remove(id)
            state.removed.append(id)
            if let session = state.webSockets.sessions.removeValue(forKey: id) {
                state.webSockets.retainedEventCount -= session.events.count
                state.webSockets.invalidateExportToken(session.token)
                revoked.append(session); state.webSockets.changed()
            }
        }
        return files
    }

    // MARK: - Body ownership (called under lock S; the registry does no disk I/O)

    /// Every body slot of a flow: the legacy request/response fields and the boundary slices.
    private static func bodies(of flow: Flow) -> [BodyRef] {
        [flow.requestBody, flow.responseBody].compactMap { $0 } + flow.messages.values.compactMap { $0.body?.ref }
            + [flow.executeOverlay?.request?.body?.ref, flow.executeOverlay?.response?.body?.ref].compactMap { $0 }
    }

    /// Charges borrowed bodies per slot and managed bodies once per unique body. A managed handle
    /// the store refuses (dead or foreign) is dropped from its slot instead of being stored uncharged.
    private func retainBodies(of flow: inout Flow, in state: inout State) {
        let id = flow.id
        flow.requestBody = retained(flow.requestBody, flowID: id, in: &state)
        flow.responseBody = retained(flow.responseBody, flowID: id, in: &state)
        for (boundary, snapshot) in flow.messages {
            guard let slice = snapshot.body else { continue }
            if retained(slice.ref, flowID: id, in: &state) == nil {
                flow.messages[boundary]?.body = nil
                flow.messages[boundary]?.bodyState = .unavailable
            }
        }
        if let slice = flow.executeOverlay?.request?.body, retained(slice.ref, flowID: id, in: &state) == nil {
            flow.executeOverlay?.request?.body = nil
            flow.executeOverlay?.request?.bodyState = .unavailable
        }
        if let slice = flow.executeOverlay?.response?.body, retained(slice.ref, flowID: id, in: &state) == nil {
            flow.executeOverlay?.response?.body = nil
            flow.executeOverlay?.response?.bodyState = .unavailable
        }
    }

    /// Borrowed `.memory`/`.file` inputs are charged per slot (a caller that puts the same borrowed
    /// value in two slots pays twice); only managed bodies are shared and charged once.
    private func retained(_ body: BodyRef?, flowID: Int, in state: inout State) -> BodyRef? {
        guard let body else { return nil }
        switch body {
        case .memory(let data): state.residentBodyBytes += data.count
        case .file(_, let size): state.spilledBytes += size
        case .managed(let handle):
            switch bodies.retainForFlow(handle, flowID: flowID) {
            case .rejected: return nil
            case .first:
                if handle.isOnDisk { state.spilledBytes += handle.size } else { state.residentBodyBytes += handle.size }
            case .alias: break
            }
        }
        return body
    }

    private func releaseBodies(of flow: Flow, in state: inout State) -> [HTTPBodyRegistry.Reclaim] {
        var reclaims: [HTTPBodyRegistry.Reclaim] = []
        for body in Self.bodies(of: flow) {
            switch body {
            case .memory(let data): state.residentBodyBytes -= data.count
            case .file(_, let size): state.spilledBytes -= size
            case .managed(let handle):
                let outcome = bodies.releaseForFlow(handle, flowID: flow.id)
                if let reclaim = outcome.reclaim { reclaims.append(reclaim) }
                guard outcome.unreferenced else { continue }
                if handle.isOnDisk { state.spilledBytes -= handle.size } else { state.residentBodyBytes -= handle.size }
            }
        }
        return reclaims
    }

    /// Managed bodies brought by a write to a removed flow: release the producer's claim so a
    /// store-created file is reclaimed. Borrowed files are untouched.
    private func abandonRejectedBodies(of flow: Flow) -> [HTTPBodyRegistry.Reclaim] {
        var reclaims: [HTTPBodyRegistry.Reclaim] = []
        for case .managed(let handle) in Self.bodies(of: flow) where handle.registry === bodies {
            if let reclaim = bodies.abandonProducer(handle.id) { reclaims.append(reclaim) }
        }
        return reclaims
    }
}
