import Foundation
import Testing

@testable import FlowStore

@Suite struct FlowRecentTests {
    private func fill(_ store: FlowStore, count: Int) {
        for _ in 0..<count {
            store.begin { Flow(id: $0, scheme: "https", method: "GET", host: "x.com", port: 443, path: "/") }
        }
    }

    private func make() -> (FlowStore, TestEnvironment) {
        let env = TestEnvironment()
        return (env.store, env)
    }

    @Test func returnsTheNewestFlowsInAscendingOrder() {
        let (store, env) = make(); defer { env.cleanUp() }
        fill(store, count: 10)
        #expect(store.recentFlows(limit: 3).map(\.id) == [8, 9, 10])
    }

    @Test func limitLargerThanCountReturnsAll() {
        let (store, env) = make(); defer { env.cleanUp() }
        fill(store, count: 4)
        #expect(store.recentFlows(limit: 100).map(\.id) == [1, 2, 3, 4])
    }

    @Test func zeroOrNegativeLimitReturnsNothing() {
        let (store, env) = make(); defer { env.cleanUp() }
        fill(store, count: 4)
        #expect(store.recentFlows(limit: 0).isEmpty)
        #expect(store.recentFlows(limit: -3).isEmpty)
    }

    @Test func hiddenFlowsAreSkippedByDefault() {
        let (store, env) = make(); defer { env.cleanUp() }
        fill(store, count: 10)
        store.update(9) { $0.isHidden = true }
        #expect(store.recentFlows(limit: 3).map(\.id) == [7, 8, 10])
    }

    @Test func includeHiddenReturnsThem() {
        let (store, env) = make(); defer { env.cleanUp() }
        fill(store, count: 10)
        store.update(9) { $0.isHidden = true }
        #expect(store.recentFlows(limit: 3, includeHidden: true).map(\.id) == [8, 9, 10])
    }

    @Test func emptyStoreReturnsNothing() {
        let (store, env) = make(); defer { env.cleanUp() }
        #expect(store.recentFlows(limit: 5).isEmpty)
    }

    @Test func evictedRangeIsRespected() {
        let env = TestEnvironment(maxFlows: 5); defer { env.cleanUp() }
        fill(env.store, count: 8)
        #expect(env.store.recentFlows(limit: 10).map(\.id) == [4, 5, 6, 7, 8])
    }

    @Test func neverCopiesTheWholeStore() {
        let (store, env) = make(); defer { env.cleanUp() }
        fill(store, count: 5000)
        #expect(store.recentFlows(limit: 5).map(\.id) == [4996, 4997, 4998, 4999, 5000])
    }
}
