import Foundation
import MCPKit
import Observation
import Testing
@testable import AppCore

private func entry(_ tool: String, outcome: MCPCallOutcome = .ok) -> MCPAuditEntry {
    MCPAuditEntry(client: "test", tool: tool, arguments: "{}", outcome: outcome, durationMs: 1)
}

/// Suspends until `model.entries` changes (no sleeping, no polling): the tracking is registered before the
/// caller can yield, and both sides run on the main actor.
@MainActor private func nextChange(of model: MCPActivityModel) async {
    await withCheckedContinuation { continuation in
        withObservationTracking { _ = model.entries } onChange: { continuation.resume() }
    }
}

@MainActor private func waitForEntries(_ model: MCPActivityModel, count: Int) async {
    while model.entries.count != count { await nextChange(of: model) }
}

@MainActor @Suite(.timeLimit(.minutes(1)), .productionChinese) struct MCPActivityModelTests {
    @Test func entriesFollowLogAndClear() async {
        let log = MCPAuditLog()
        let model = MCPActivityModel(log: log)
        #expect(model.entries.isEmpty)
        let running = Task { @MainActor in await model.start() }

        log.record(entry("list_flows"))
        await waitForEntries(model, count: 1)
        #expect(model.entries.map(\.tool) == ["list_flows"])

        log.record(entry("get_flow", outcome: .failed(code: "not_found")))
        await waitForEntries(model, count: 2)
        // Newest first, as the log keeps them.
        #expect(model.entries.map(\.tool) == ["get_flow", "list_flows"])
        #expect(model.entries == log.snapshot())

        model.clear()
        #expect(model.entries.isEmpty && log.snapshot().isEmpty)

        // The model keeps following after a clear, and a clear made by someone else reaches it too.
        log.record(entry("search_flows"))
        await waitForEntries(model, count: 1)
        log.clear()
        await waitForEntries(model, count: 0)
        running.cancel()
        await running.value
    }

    @Test func startShowsWhatTheLogAlreadyHolds() async {
        let log = MCPAuditLog()
        log.record(entry("a"))
        log.record(entry("b"))
        let model = MCPActivityModel(log: log)
        let running = Task { @MainActor in await model.start() }
        await waitForEntries(model, count: 2)
        #expect(model.entries.map(\.tool) == ["b", "a"])
        running.cancel()
        await running.value
    }

    @Test func cancellingStartStopsFollowingAndReleasesTheSubscription() async {
        let log = MCPAuditLog()
        let model = MCPActivityModel(log: log)
        let running = Task { @MainActor in await model.start() }
        log.record(entry("a"))
        await waitForEntries(model, count: 1)
        running.cancel()
        await running.value
        log.record(entry("b"))
        // Not followed any more (the model only changes through start or clear).
        #expect(model.entries.map(\.tool) == ["a"])
        model.clear()
        #expect(model.entries.isEmpty)
    }
}
