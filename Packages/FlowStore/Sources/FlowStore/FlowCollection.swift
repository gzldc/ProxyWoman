import Foundation

/// UI 侧的值类型镜像：把 `FlowStore.changes()` 的批次应用上去，得到按 id 升序的列表。
public struct FlowCollection: Sendable {
    public private(set) var flows: [Flow] = []

    public init() {}

    public mutating func apply(_ change: FlowChange) {
        if change.cleared { flows.removeAll() }
        flows.removeFlows(withIDs: change.removed)
        for flow in change.upserted {
            let index = flows.insertionIndex(forID: flow.id)
            if index < flows.count, flows[index].id == flow.id {
                flows[index] = flow
            } else {
                flows.insert(flow, at: index)
            }
        }
    }

    public func flow(id: Int) -> Flow? {
        flows.index(ofID: id).map { flows[$0] }
    }
}

extension Array where Element == Flow {
    /// 在按 id 升序的数组里二分查找第一个 id >= 目标的位置。
    public func insertionIndex(forID id: Int) -> Int {
        var low = 0
        var high = count
        while low < high {
            let mid = (low + high) / 2
            if self[mid].id < id { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// 从按 id 升序的数组里删掉这些 id（不存在的忽略）。只处理 id 最小值到最大值之间的那一段：
    /// 淘汰总是发生在最旧的一端，这一段就是数组开头。
    public mutating func removeFlows(withIDs ids: [Int]) {
        guard let lowest = ids.min(), let highest = ids.max() else { return }
        let range = insertionIndex(forID: lowest)..<insertionIndex(forID: highest + 1)
        guard !range.isEmpty else { return }
        let removed = Set(ids)
        let kept = self[range].filter { !removed.contains($0.id) }
        replaceSubrange(range, with: kept)
    }

    /// 在按 id 升序的数组里二分查找该 id 的下标。
    public func index(ofID id: Int) -> Int? {
        let index = insertionIndex(forID: id)
        return index < count && self[index].id == id ? index : nil
    }
}
