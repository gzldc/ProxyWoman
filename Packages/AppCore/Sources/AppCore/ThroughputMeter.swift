import Foundation

/// 由累计字节数的相邻两次采样算出每秒速度。计数变小（服务重建后从零开始）或时间没有前进时记为 0。
public struct ThroughputMeter: Sendable {
    /// 每秒字节数。
    public struct Rate: Equatable, Sendable {
        public var up: Double
        public var down: Double

        public static let zero = Rate(up: 0, down: 0)

        public init(up: Double, down: Double) {
            self.up = up
            self.down = down
        }
    }

    private var last: (up: Int64, down: Int64, time: TimeInterval)?

    public init() {}

    /// `time` 是单调时钟的秒数。
    public mutating func sample(up: Int64, down: Int64, at time: TimeInterval) -> Rate {
        defer { last = (up, down, time) }
        guard let last, time > last.time, up >= last.up, down >= last.down else { return .zero }
        let elapsed = time - last.time
        return Rate(up: Double(up - last.up) / elapsed, down: Double(down - last.down) / elapsed)
    }
}
