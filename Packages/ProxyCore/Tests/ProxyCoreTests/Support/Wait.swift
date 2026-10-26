import FlowStore
import Foundation

struct WaitTimeout: Error, CustomStringConvertible {
    let description: String
}

/// Polls `condition` until it holds, or throws `WaitTimeout`.
func waitUntil(
    timeout: Duration = .seconds(5),
    _ what: String = "condition",
    _ condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            throw WaitTimeout(description: "timed out after \(timeout) waiting for \(what)")
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}

/// Polls the store until a flow matches `predicate` and returns the first match.
func waitForFlow(
    _ store: FlowStore,
    timeout: Duration = .seconds(5),
    where predicate: (Flow) -> Bool
) async throws -> Flow {
    var match: Flow?
    try await waitUntil(timeout: timeout, "a matching flow; flows: \(store.allFlows())") {
        match = store.allFlows().first(where: predicate)
        return match != nil
    }
    return match!
}

/// Completion is recorded when the final downstream write settles, which may be just after the
/// client already read the response.
func waitForCompletedFlows(_ store: FlowStore, atLeast count: Int) async throws {
    try await waitUntil("\(count) completed flows; flows: \(store.allFlows())") {
        let flows = store.allFlows()
        return flows.count >= count && flows.allSatisfy { $0.state == .completed }
    }
}
