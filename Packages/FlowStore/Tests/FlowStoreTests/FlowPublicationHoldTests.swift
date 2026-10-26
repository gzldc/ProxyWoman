import Foundation
import Testing

@testable import FlowStore

private func makeFlow(_ id: Int) -> Flow {
    Flow(id: id, scheme: "https", method: "GET", host: "h", port: 443, path: "/\(id)")
}

private func announced(_ id: Int, in batches: [FlowChange]) -> Bool {
    batches.contains { $0.upserted.contains { $0.id == id } }
}

@Suite struct FlowPublicationHoldTests {
    @Test func heldFlowIsNotAnnouncedUntilPublished() async {
        let env = TestEnvironment(batchInterval: .milliseconds(20))
        defer { env.cleanUp() }
        let recorder = BatchRecorder(env.store.changes())
        defer { recorder.stop() }
        let a = env.store.begin(deferringPublication: true, makeFlow)
        let b = env.store.begin(deferringPublication: true, makeFlow)
        env.store.update(a) { $0.statusCode = 200 }
        env.store.publish(b)
        #expect(await recorder.wait { announced(b, in: $0) })
        #expect(!announced(a, in: recorder.received))
        env.store.publish(a)
        #expect(await recorder.wait { batches in
            batches.contains { $0.upserted.contains { $0.id == a && $0.statusCode == 200 } }
        })
    }

    @Test func heldFlowIsVisibleToDirectReads() {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let a = env.store.begin(deferringPublication: true, makeFlow)
        #expect(env.store.flow(a)?.id == a)
        #expect(env.store.allFlows().map(\.id) == [a])
        #expect(env.store.visibleFlow(a) != nil)
        #expect(env.store.flowCount == 1)
    }

    @Test func publishingAnUnknownOrUnheldIdIsANoOp() async {
        let env = TestEnvironment(batchInterval: .milliseconds(20))
        defer { env.cleanUp() }
        let recorder = BatchRecorder(env.store.changes())
        defer { recorder.stop() }
        let plain = env.store.begin(makeFlow)
        #expect(await recorder.wait { announced(plain, in: $0) })
        let count = recorder.received.count
        env.store.publish(999)
        env.store.publish(plain)
        env.store.publish(plain)
        let fence = env.store.begin(makeFlow)
        #expect(await recorder.wait { announced(fence, in: $0) })
        let later = recorder.received.dropFirst(count)
        #expect(!later.contains { $0.upserted.contains { $0.id == plain } })
        #expect(!later.contains { $0.upserted.contains { $0.id == 999 } })
    }

    @Test func finishingAHeldFlowReleasesIt() async {
        let env = TestEnvironment(batchInterval: .milliseconds(20))
        defer { env.cleanUp() }
        let recorder = BatchRecorder(env.store.changes())
        defer { recorder.stop() }
        let a = env.store.begin(deferringPublication: true, makeFlow)
        env.store.update(a) { $0.state = .failed("x") }
        #expect(await recorder.wait { batches in
            batches.contains { $0.upserted.contains { $0.id == a && $0.state == .failed("x") } }
        })
    }

    @Test func newSubscriberBaselineSkipsHeldFlows() async {
        let env = TestEnvironment(batchInterval: .milliseconds(20))
        defer { env.cleanUp() }
        let a = env.store.begin(deferringPublication: true, makeFlow)
        let recorder = BatchRecorder(env.store.changes())
        defer { recorder.stop() }
        let b = env.store.begin(makeFlow)
        #expect(await recorder.wait { announced(b, in: $0) })
        #expect(!announced(a, in: recorder.received))
        env.store.publish(a)
        #expect(await recorder.wait { announced(a, in: $0) })
    }

    @Test func evictingAHeldFlowDoesNotLeakTheHold() async {
        let env = TestEnvironment(batchInterval: .milliseconds(20), maxFlows: 1)
        defer { env.cleanUp() }
        let recorder = BatchRecorder(env.store.changes())
        defer { recorder.stop() }
        let a = env.store.begin(deferringPublication: true, makeFlow)
        let b = env.store.begin(makeFlow)
        #expect(env.store.flow(a) == nil)
        env.store.publish(a)
        #expect(await recorder.wait { announced(b, in: $0) })
        #expect(!announced(a, in: recorder.received))
        #expect(env.store.state.withLock { $0.held.isEmpty })
    }

    @Test func publishedFlowCarriesTheLatestState() async {
        let env = TestEnvironment(batchInterval: .milliseconds(20))
        defer { env.cleanUp() }
        let recorder = BatchRecorder(env.store.changes())
        defer { recorder.stop() }
        let a = env.store.begin(deferringPublication: true, makeFlow)
        env.store.update(a) { $0.isHidden = true }
        env.store.publish(a)
        #expect(await recorder.wait { announced(a, in: $0) })
        let first = recorder.received.flatMap(\.upserted).first { $0.id == a }
        #expect(first?.isHidden == true)
    }

    @Test func clearDropsEveryHold() async {
        let env = TestEnvironment(batchInterval: .milliseconds(20))
        defer { env.cleanUp() }
        let recorder = BatchRecorder(env.store.changes())
        defer { recorder.stop() }
        let a = env.store.begin(deferringPublication: true, makeFlow)
        env.store.clear()
        #expect(env.store.state.withLock { $0.held.isEmpty })
        env.store.publish(a)
        let b = env.store.begin(makeFlow)
        #expect(await recorder.wait { announced(b, in: $0) })
        #expect(!announced(a, in: recorder.received))
    }
}
