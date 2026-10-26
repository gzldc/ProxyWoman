import Foundation

/// One session's retained events, confined to FlowStore's owner lock like the rest of
/// `WebSocketStore`. Stored event IDs only increase on insertion (publication rejects an ID at
/// or below the session's highest admitted ID), so an append-only ID list gives ascending order;
/// removed IDs stay behind as skipped holes until the list is compacted. Capture-terminal rows
/// are additionally kept in a min-heap keyed by `(order, id)` so the eviction candidate — the
/// oldest terminal row by ingress order — is found without scanning the session.
struct WebSocketEventLog: Sendable {
    private struct Entry: Sendable { let order: WebSocketOrder; let id: UInt64 }
    private var rows: [UInt64: WebSocketStoredEvent] = [:]
    private var ids: [UInt64] = []
    private var head = 0
    private var terminal: [Entry] = []

    var count: Int { rows.count }
    var isEmpty: Bool { rows.isEmpty }
    /// Lowest retained ID, O(1).
    var firstID: UInt64? { head < ids.count ? ids[head] : nil }

    subscript(id: UInt64) -> WebSocketStoredEvent? {
        get { rows[id] }
        set {
            guard let newValue else { remove(id); return }
            let old = rows.updateValue(newValue, forKey: id)
            if old == nil {
                precondition(ids.last.map { id > $0 } ?? true, "WebSocket event IDs must be inserted in ascending order")
                ids.append(id)
            }
            if newValue.metadata.isCaptureTerminal && old?.metadata.isCaptureTerminal != true {
                push(Entry(order: newValue.metadata.order, id: id))
            }
        }
    }

    /// Retained IDs, ascending. Callers that mutate rows while iterating use this copy.
    var keys: [UInt64] { ids[head...].filter { rows[$0] != nil } }
    /// Retained rows, ascending ID.
    var values: [WebSocketStoredEvent] { ids[head...].compactMap { rows[$0] } }

    /// Visits retained rows with ID > `after` (all when nil) in ascending order until `body` returns false.
    func forEachAscending(after: UInt64?, _ body: (WebSocketStoredEvent) -> Bool) {
        var index = after.map { lowerBound(greaterThan: $0) } ?? head
        while index < ids.count {
            if let row = rows[ids[index]], !body(row) { return }
            index += 1
        }
    }
    /// Visits retained rows with ID < `before` (all when nil) in descending order until `body` returns false.
    func forEachDescending(before: UInt64?, _ body: (WebSocketStoredEvent) -> Bool) {
        var index = (before.map { lowerBound(greaterThan: $0 == 0 ? 0 : $0 - 1) } ?? ids.count) - 1
        while index >= head {
            if let row = rows[ids[index]], !body(row) { return }
            index -= 1
        }
    }

    /// The oldest capture-terminal row by `(order, id)`, skipping `excluding`. Amortized
    /// O(log n); `examined` counts heap entries inspected (complexity guard instrumentation).
    mutating func oldestTerminal(excluding: UInt64?, examined: inout UInt64) -> WebSocketStoredEvent? {
        var setAside: [Entry] = []
        defer { for entry in setAside { push(entry) } }
        while let top = terminal.first {
            examined &+= 1
            guard let row = rows[top.id], row.metadata.isCaptureTerminal, row.metadata.order == top.order else {
                popTop(); continue // Stale: removed, replaced or duplicate entry.
            }
            if top.id == excluding { setAside.append(top); popTop(); continue }
            return row
        }
        return nil
    }

    private mutating func remove(_ id: UInt64) {
        guard rows.removeValue(forKey: id) != nil else { return }
        while head < ids.count, rows[ids[head]] == nil { head += 1 }
        while let last = ids.last, ids.count > head, rows[last] == nil { ids.removeLast() }
        if head == ids.count { ids.removeAll(keepingCapacity: true); head = 0 }
        // Holes: removed IDs between head and tail. Compact once they outnumber live rows.
        let holes = ids.count - head - rows.count
        if head > 64 && head > ids.count / 2 || holes > 64 && holes > rows.count {
            ids = ids[head...].filter { rows[$0] != nil }; head = 0
        }
        if terminal.count > 2 * rows.count + 64 {
            terminal = []
            for id in ids[head...] { if let row = rows[id], row.metadata.isCaptureTerminal { push(Entry(order: row.metadata.order, id: id)) } }
        }
    }
    /// First index in `ids[head...]` whose ID is greater than `value`.
    private func lowerBound(greaterThan value: UInt64) -> Int {
        var low = head, high = ids.count
        while low < high {
            let mid = (low + high) / 2
            if ids[mid] <= value { low = mid + 1 } else { high = mid }
        }
        return low
    }
    private static func precedes(_ a: Entry, _ b: Entry) -> Bool { a.order < b.order || (a.order == b.order && a.id < b.id) }
    private mutating func push(_ entry: Entry) {
        terminal.append(entry)
        var child = terminal.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard Self.precedes(terminal[child], terminal[parent]) else { break }
            terminal.swapAt(child, parent); child = parent
        }
    }
    private mutating func popTop() {
        let last = terminal.removeLast()
        guard !terminal.isEmpty else { return }
        terminal[0] = last
        var parent = 0
        while true {
            let left = 2 * parent + 1, right = left + 1
            var smallest = parent
            if left < terminal.count && Self.precedes(terminal[left], terminal[smallest]) { smallest = left }
            if right < terminal.count && Self.precedes(terminal[right], terminal[smallest]) { smallest = right }
            if smallest == parent { return }
            terminal.swapAt(parent, smallest); parent = smallest
        }
    }
}
