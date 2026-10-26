import Foundation
import os

@testable import FlowStore

/// 每个测试一个独立的临时 body 目录，用完即删。
struct TestEnvironment {
    let directory: URL
    let store: FlowStore

    init(
        batchInterval: Duration = .milliseconds(50),
        maxFlows: Int = FlowStore.defaultMaxFlows,
        maxSpilledBytes: Int = FlowStore.defaultMaxSpilledBytes,
        maxCapturedBodyBytes: Int = BodyCapture.defaultMaxCapturedBytes
    ) {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlowStoreTests-\(UUID().uuidString)", isDirectory: true)
        store = FlowStore(
            bodyDirectory: directory, batchInterval: batchInterval, maxFlows: maxFlows,
            maxSpilledBytes: maxSpilledBytes, maxCapturedBodyBytes: maxCapturedBodyBytes)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}

extension FlowStore {
    /// Test inspection: where a store-registered body lives on disk.
    func spillURL(of body: BodyRef) -> URL? {
        guard case .managed(let handle) = body else { return nil }
        return bodies.fileURL(for: handle)
    }
}

/// 在后台消费 `changes()`，把收到的批次累积起来供测试断言。
final class BatchRecorder: Sendable {
    private let batches = OSAllocatedUnfairLock<[FlowChange]>(initialState: [])
    private let task: Task<Void, Never>

    init(_ stream: AsyncStream<FlowChange>) {
        let batches = self.batches
        task = Task {
            for await change in stream {
                batches.withLock { $0.append(change) }
            }
        }
    }

    var received: [FlowChange] { batches.withLock { $0 } }

    /// 轮询直到条件成立或超时，返回条件最终是否成立。
    func wait(timeout: Duration = .seconds(1), until condition: @Sendable ([FlowChange]) -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition(received) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition(received)
    }

    func stop() { task.cancel() }
}
