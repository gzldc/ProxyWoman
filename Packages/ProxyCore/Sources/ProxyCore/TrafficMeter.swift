import Atomics
import NIOCore

/// Bytes that went through the proxy's client connections.
public struct TrafficTotals: Sendable, Equatable {
    /// Read from clients (on their way to the origins).
    public var bytesUp: Int64
    /// Written to clients (from the origins, plus the proxy's own responses).
    public var bytesDown: Int64

    public init(bytesUp: Int64, bytesDown: Int64) {
        self.bytesUp = bytesUp
        self.bytesDown = bytesDown
    }
}

/// Cumulative byte counters shared by every client connection of one server. Lock-free, so the
/// per-buffer updates cost no more than an atomic add.
final class TrafficMeter: Sendable {
    private let up = ManagedAtomic<Int64>(0)
    private let down = ManagedAtomic<Int64>(0)

    var totals: TrafficTotals {
        TrafficTotals(bytesUp: up.load(ordering: .relaxed), bytesDown: down.load(ordering: .relaxed))
    }

    func addUp(_ count: Int) {
        up.wrappingIncrement(by: Int64(count), ordering: .relaxed)
    }

    func addDown(_ count: Int) {
        down.wrappingIncrement(by: Int64(count), ordering: .relaxed)
    }
}

/// The first handler of every client pipeline: counts the bytes on the client socket, so plain
/// HTTP, intercepted TLS and raw tunnels are all counted the same way, recorded or not.
final class TrafficCountingHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = IOData
    typealias OutboundOut = IOData

    private let meter: TrafficMeter

    init(meter: TrafficMeter) {
        self.meter = meter
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        meter.addUp(unwrapInboundIn(data).readableBytes)
        context.fireChannelRead(data)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        switch unwrapOutboundIn(data) {
        case .byteBuffer(let buffer): meter.addDown(buffer.readableBytes)
        case .fileRegion(let region): meter.addDown(region.readableBytes)
        }
        context.write(data, promise: promise)
    }
}
