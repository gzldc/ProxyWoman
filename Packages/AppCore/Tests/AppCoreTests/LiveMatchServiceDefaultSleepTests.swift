import FlowStore
import Foundation
import RulesEngine
import Testing

@testable import AppCore

/// The App builds the service with its default clock sleep; the injected-sleep tests never run that path.
@Suite(.productionChinese) struct LiveMatchServiceDefaultSleepTests {
    @Test func updatesRunsSeveralTicksWithTheDefaultSleep() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pw-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FlowStore(bodyDirectory: directory)
        store.begin { Flow(id: $0, scheme: "https", method: "GET", host: "a.test", port: 443, path: "/") }
        let group = ConditionGroup(rows: [ConditionRow(field: .host, op: .equals, value: "a.test")])
        let service = LiveMatchService(debounce: .milliseconds(1))
        var iterator = service.updates(group, store: store, interval: .milliseconds(1)).makeAsyncIterator()
        let first = await iterator.next()
        #expect(first != nil)
        // Later ticks find the store unchanged and take the `continue` path before sleeping again.
        try await Task.sleep(for: .milliseconds(50))
        store.begin { Flow(id: $0, scheme: "https", method: "GET", host: "a.test", port: 443, path: "/2") }
        let second = await iterator.next()
        #expect(second != nil)
    }
}
