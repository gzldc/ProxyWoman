import Foundation

/// Pure delivery planner for one direction of one connection, with no NIO dependency. The caller
/// supplies the monotonic `now` and the loss draw, so behaviour is deterministic.
public struct TrafficShaper: Sendable {
    public struct Config: Sendable, Equatable {
        /// nil or 0 means unlimited.
        public var bytesPerSecond: Int?
        /// Added to every chunk.
        public var latency: Duration
        public var lossPercent: Double

        public init(bytesPerSecond: Int?, latency: Duration, lossPercent: Double) {
            self.bytesPerSecond = bytesPerSecond
            self.latency = latency
            self.lossPercent = lossPercent
        }
    }

    public private(set) var config: Config
    /// When the serialised link becomes free again.
    private var freeAt: Duration = .zero
    /// Last scheduled delivery; later chunks never deliver before it (TCP order).
    private var lastDue: Duration = .zero

    public init(_ config: Config) {
        self.config = config
    }

    /// Changes the rate, latency and loss from now on. Delivery already scheduled is kept.
    public mutating func reconfigure(_ config: Config) {
        self.config = config
    }

    /// How long after `now` this chunk may be delivered. `lossDraw` is in [0, 1).
    public mutating func delay(forChunkOf bytes: Int, at now: Duration, lossDraw: Double) -> Duration {
        let start = max(freeAt, now)
        if let rate = config.bytesPerSecond, rate > 0, bytes > 0 {
            freeAt = start + .nanoseconds((Int64(bytes) * 1_000_000_000) / Int64(rate))
        } else {
            freeAt = start
        }
        var due = freeAt + config.latency
        if config.lossPercent > 0 {
            let packets = max(1, (bytes + 1447) / 1448)
            let probability = 1 - pow(1 - min(config.lossPercent / 100, 1), Double(packets))
            if lossDraw < probability {
                due += min(.seconds(3), max(.milliseconds(200), config.latency * 4))
            }
        }
        due = max(due, lastDue)
        lastDue = due
        return due - now
    }
}
