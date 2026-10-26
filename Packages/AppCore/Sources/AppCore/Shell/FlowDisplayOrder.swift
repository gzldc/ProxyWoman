import FlowStore

/// The traffic list's row order with paused breakpoint flows on top.
public enum FlowDisplayOrder {
    /// The flows of `paused` that are in `visible` come first, in `paused` order (each once); every
    /// other flow keeps its relative order. With nothing paused the input is returned unchanged.
    public static func pausedFirst(_ visible: [Flow], paused: [Int]) -> [Flow] {
        guard !paused.isEmpty else { return visible }
        var rank: [Int: Int] = [:]
        for id in paused where rank[id] == nil { rank[id] = rank.count }
        var top: [Flow?] = Array(repeating: nil, count: rank.count)
        var rest: [Flow] = []
        rest.reserveCapacity(visible.count)
        for flow in visible {
            if let index = rank[flow.id], top[index] == nil { top[index] = flow } else { rest.append(flow) }
        }
        return top.compactMap { $0 } + rest
    }
}
