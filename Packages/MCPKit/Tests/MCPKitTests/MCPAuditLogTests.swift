import Foundation
import Testing

@testable import MCPKit

@Suite struct MCPAuditLogTests {
    private func entry(_ n: Int, outcome: MCPCallOutcome = .ok) -> MCPAuditEntry {
        MCPAuditEntry(
            id: UUID(), at: Date(timeIntervalSince1970: Double(n)), client: "c", tool: "tool\(n)",
            arguments: "{}", outcome: outcome, durationMs: n)
    }

    @Test func keepsNewestFirstAndCapsAt200() {
        let log = MCPAuditLog()
        #expect(MCPAuditLog.capacity == 200)
        for n in 0..<250 { log.record(entry(n)) }
        let snapshot = log.snapshot()
        #expect(snapshot.count == 200)
        #expect(snapshot.first?.tool == "tool249")
        #expect(snapshot.last?.tool == "tool50")
    }

    @Test func clearEmpties() {
        let log = MCPAuditLog()
        log.record(entry(1, outcome: .denied(.permission(tool: "create_rule"))))
        #expect(log.snapshot().count == 1)
        log.clear()
        #expect(log.snapshot().isEmpty)
    }

    @Test func changesStreamSignalsOnRecordAndClear() async {
        let log = MCPAuditLog()
        let stream = log.changes()
        log.record(entry(1))
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        log.clear()
        _ = await iterator.next()
        #expect(log.snapshot().isEmpty)
    }

    @Test func eachChangesStreamIsIndependent() async {
        let log = MCPAuditLog()
        let a = log.changes()
        let b = log.changes()
        log.record(entry(1))
        var ia = a.makeAsyncIterator()
        var ib = b.makeAsyncIterator()
        #expect(await ia.next() != nil)
        // `a` already consumed its signal; `b` still has its own pending one.
        #expect(await ib.next() != nil)
        log.clear()
        #expect(await ia.next() != nil)
        #expect(await ib.next() != nil)
    }

    @Test func endedStreamIsRemovedFromSubscribers() async {
        let log = MCPAuditLog()
        #expect(log.subscriberCount == 0)
        do {
            let stream = log.changes()
            var iterator: AsyncStream<Void>.Iterator? = stream.makeAsyncIterator()
            log.record(entry(1))
            #expect(await iterator?.next() != nil)
            #expect(log.subscriberCount == 1)
            iterator = nil
        }
        // A cancelled consumer also unsubscribes.
        let task = Task { for await _ in log.changes() {} }
        while log.subscriberCount < 1 { await Task.yield() }
        task.cancel()
        await task.value
        #expect(log.subscriberCount == 0)
    }

    @Test func concurrentRecordAndClearStaysConsistent() async {
        let log = MCPAuditLog()
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    for n in 0..<100 {
                        log.record(MCPAuditEntry(client: nil, tool: "w\(worker)-\(n)", arguments: "", outcome: .ok, durationMs: 0))
                        if n % 25 == 0 { log.clear() }
                        _ = log.snapshot()
                    }
                }
            }
        }
        let snapshot = log.snapshot()
        #expect(snapshot.count <= MCPAuditLog.capacity)
        #expect(Set(snapshot.map(\.id)).count == snapshot.count)
    }
}
