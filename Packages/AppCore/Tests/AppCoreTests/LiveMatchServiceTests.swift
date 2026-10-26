import FlowStore
import Foundation
import RulesEngine
import Testing

@testable import AppCore

/// Holds every injected "sleep" until the test lets them go, so debouncing is observed without a clock.
private actor LiveCountSleepGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var arrivals = 0
    private var isOpen = false

    func wait() async {
        arrivals += 1
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private let host = ConditionGroup(rows: [ConditionRow(field: .host, op: .equals, value: "a.test")])

private func makeStore(_ count: Int, hiddenIDs: Set<Int> = []) -> (FlowStore, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pw-live-\(UUID().uuidString)")
    let store = FlowStore(bodyDirectory: directory)
    for _ in 0..<count {
        store.begin { id in
            var flow = Flow(id: id, scheme: "https", method: "GET", host: "a.test", port: 443, path: "/\(id)")
            flow.state = .completed
            flow.completedAt = flow.startedAt
            flow.isHidden = hiddenIDs.contains(id)
            return flow
        }
    }
    return (store, directory)
}

/// Each `tick()` returns once the test has given it a permit (no clock involved); cancellation ends the wait.
private actor LiveCountTicker {
    private var permits = 0
    private var waiter: CheckedContinuation<Void, Error>?
    /// How many times the loop has asked for a tick (it asks again only after finishing the previous pass).
    private(set) var entered = 0

    func tick() async throws {
        entered += 1
        if permits > 0 { permits -= 1; return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiter = $0 }
        } onCancel: {
            Task { await self.cancelWaiter() }
        }
    }

    func permit() {
        if let waiter { self.waiter = nil; waiter.resume() } else { permits += 1 }
    }

    private func cancelWaiter() {
        waiter?.resume(throwing: CancellationError())
        waiter = nil
    }
}

@Suite(.productionChinese) struct LiveMatchServiceTests {
    @Test func updatesReportsFlowsThatChangeState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pw-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FlowStore(bodyDirectory: directory)
        let id = store.begin { Flow(id: $0, scheme: "https", method: "GET", host: "a.test", port: 443, path: "/") }
        let paused = ConditionGroup(rows: [ConditionRow(field: .sessionState, op: .equals, value: "paused")])
        let ticker = LiveCountTicker()
        await ticker.permit()
        let service = LiveMatchService(debounce: .zero, sleep: { _ in try await ticker.tick() })
        var iterator = service.updates(paused, store: store).makeAsyncIterator()
        // The first pass sees an open session; the session then pauses before the next pass is allowed.
        let first = await iterator.next()
        #expect(first?.matchedIDs == [])
        store.update(id) { $0.isPausedAtBreakpoint = true }
        await ticker.permit()
        let second = await iterator.next()
        #expect(second?.matchedIDs == [id])
    }

    @Test func updatesSkipTheEvaluationWhileTheStoreIsUnchanged() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pw-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FlowStore(bodyDirectory: directory)
        let id = store.begin { Flow(id: $0, scheme: "https", method: "GET", host: "a.test", port: 443, path: "/") }
        let evaluations = LockedBox<Int>(0)
        let ticker = LiveCountTicker()
        var service = LiveMatchService(debounce: .zero, sleep: { _ in try await ticker.tick() })
        service.evaluationProbe = { evaluations.withValue { $0 += 1 } }
        let paused = ConditionGroup(rows: [ConditionRow(field: .sessionState, op: .equals, value: "paused")])
        await ticker.permit()
        var iterator = service.updates(paused, store: store).makeAsyncIterator()
        _ = await iterator.next()
        #expect(evaluations.value == 1)
        // A tick with nothing changed: the loop finishes it (and asks for the next) without a pass.
        await ticker.permit()
        while await ticker.entered < 3 { await Task.yield() }
        #expect(evaluations.value == 1)
        store.update(id) { $0.isPausedAtBreakpoint = true }
        await ticker.permit()
        let changed = await iterator.next()
        #expect(changed?.matchedIDs == [id])
        #expect(evaluations.value == 2)
    }

    @Test func openWebSocketSessionIsOpenedUntilItCloses() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pw-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FlowStore(bodyDirectory: directory)
        let id = store.begin {
            var flow = Flow(id: $0, scheme: "https", method: "GET", host: "a.test", port: 443, path: "/ws")
            flow.statusCode = 101
            flow.state = .completed
            flow.completedAt = flow.startedAt
            return flow
        }
        let token = try #require(store.beginWebSocket(flowID: id, handshake: .init()))
        func group(_ state: String) -> ConditionGroup {
            ConditionGroup(rows: [ConditionRow(field: .sessionState, op: .equals, value: state)])
        }
        let service = LiveMatchService(sleep: { _ in })
        #expect(try await service.count(group("opened"), store: store).value.matchedIDs == [id])
        #expect(try await service.count(group("closed"), store: store).value.matchedIDs.isEmpty)
        // The live stream notices the session closing without any flow update.
        let ticker = LiveCountTicker()
        let live = LiveMatchService(debounce: .zero, sleep: { _ in try await ticker.tick() })
        await ticker.permit()
        var iterator = live.updates(group("closed"), store: store).makeAsyncIterator()
        #expect(await iterator.next()?.matchedIDs == [])
        for (index, direction) in [WebSocketDirection.clientToServer, .serverToClient].enumerated() {
            store.endWebSocket(token: token, transport: .init(direction: direction, at: Date(), monotonic: UInt64(index)))
        }
        await ticker.permit()
        #expect(await iterator.next()?.matchedIDs == [id])
        #expect(try await service.count(group("opened"), store: store).value.matchedIDs.isEmpty)
    }

    @Test func debouncesRapidCalls() async throws {
        let (store, directory) = makeStore(3)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = LiveCountSleepGate()
        let service = LiveMatchService(debounce: .milliseconds(300), sleep: { _ in await gate.wait() })
        let first = service.count(host, store: store)
        let second = service.count(host, store: store)
        let third = service.count(host, store: store)
        await gate.open()
        for stale in [first, second] {
            await #expect(throws: CancellationError.self) { try await stale.value }
        }
        let report = try await third.value
        #expect(report.matchedIDs == [1, 2, 3])
        #expect(await gate.arrivals >= 1)
    }

    @Test func theDebounceIntervalIsPassedToTheSleep() async throws {
        let (store, directory) = makeStore(1)
        defer { try? FileManager.default.removeItem(at: directory) }
        let seen = LockedBox<[Duration]>([])
        let service = LiveMatchService(debounce: .milliseconds(123), sleep: { duration in seen.append(duration) })
        _ = try await service.count(host, store: store).value
        #expect(seen.value == [.milliseconds(123)])
    }

    @Test func resultComesFromRecentFlows() async throws {
        let (store, directory) = makeStore(5, hiddenIDs: [2])
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = LiveMatchService(sleep: { _ in })
        let report = try await service.count(host, store: store).value
        // Hidden flows never reach the matcher.
        #expect(report.matchedIDs == [1, 3, 4, 5] && report.scanned == 4)
    }

    @Test func neverReadsMoreThanTheLimit() async throws {
        let (store, directory) = makeStore(6000)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = LiveMatchService(sleep: { _ in })
        let report = try await service.count(ConditionGroup(), store: store).value
        #expect(report.scanned <= 5000)
        #expect(report.matchedIDs.first == 1001 && report.matchedIDs.last == 6000)
    }

    @Test func cancelledTaskDoesNotPublish() async throws {
        let (store, directory) = makeStore(3)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = LiveCountSleepGate()
        let service = LiveMatchService(sleep: { _ in await gate.wait() })
        let task = service.count(host, store: store)
        task.cancel()
        await gate.open()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

private final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func withValue(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
    func append<Element>(_ element: Element) where Value == [Element] { lock.withLock { stored.append(element) } }
}
