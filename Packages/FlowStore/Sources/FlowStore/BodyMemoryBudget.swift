import os

/// 同一 store 的活动 capture 共享的缓冲预算；所有计数操作都在锁内，不在锁内做文件 IO。
final class BodyMemoryBudget: Sendable {
    private let limit: Int
    private let used = OSAllocatedUnfairLock(initialState: 0)

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    var usedBytes: Int { used.withLock { $0 } }

    func reserve(_ bytes: Int) -> Bool {
        guard bytes >= 0 else { return false }
        return used.withLock { used in
            guard bytes <= limit - used else { return false }
            used += bytes
            return true
        }
    }

    func release(_ bytes: Int) {
        used.withLock { used in
            precondition(bytes >= 0 && bytes <= used, "Cannot release unreserved body memory")
            used -= bytes
        }
    }
}
