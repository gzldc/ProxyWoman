import AppCore
import Darwin
import Foundation
import Observation
import ProxyCore

/// The status bar's resource usage: the app's resident memory and the proxy's throughput,
/// sampled once a second while `run` is running.
@MainActor @Observable final class ResourceMonitor {
    private(set) var residentBytes: Int?
    private(set) var rate = ThroughputMeter.Rate.zero

    @ObservationIgnored private var meter = ThroughputMeter()

    /// Samples until the calling task is cancelled (the view's `.task` ends with the view).
    func run(trafficTotals: () -> TrafficTotals) async {
        meter = ThroughputMeter()
        while !Task.isCancelled {
            let totals = trafficTotals()
            rate = meter.sample(up: totals.bytesUp, down: totals.bytesDown, at: ProcessInfo.processInfo.systemUptime)
            residentBytes = Self.residentSize()
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private static func residentSize() -> Int? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size) : nil
    }
}
