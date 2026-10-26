import NIOCore
import NIOSSL
import RulesEngine

/// The network-condition gate of one direction of one connection: `.upload` on a client channel
/// (installed by `ProxyServer.bind`), `.download` on an upstream channel (`UpstreamConnector`).
/// It sits near the front of the pipeline and paces the inbound bytes the handlers behind it see.
///
/// Used only on its channel's event loop, like any `ChannelHandler`.
///
/// - Fast path: with no usable condition and nothing queued, `read` and `channelRead` are
///   forwarded as they are (no copy), so the bytes and events are exactly those without a gate.
/// - With a condition, inbound data is cut into slices of at most `sliceBytes`, each given a due
///   time by the direction's `TrafficShaper`, and queued in order. `channelReadComplete`, user
///   events, errors and `channelInactive` that arrive while the queue is not empty join the same
///   queue, so the end of the stream never overtakes undelivered bytes. One scheduled task at a
///   time delivers what is due.
/// - Pull model: only the outbound `read` is intercepted (autoRead is never changed). Queued data
///   is delivered while the downstream reads: it asked with `read()` (one read cycle, up to the
///   next `channelReadComplete`), or its channel's autoRead is on. While neither holds the gate
///   re-checks every `pausedRecheck`, because re-enabling autoRead never reaches the pipeline.
///   A read is passed to the socket only while fewer than `maxQueuedBytes` are queued; a read
///   withheld at the cap is passed on once deliveries bring the queue below it. Re-enabling
///   autoRead starts a socket read directly (never through the pipeline), so `Channel.setAutoRead`
///   hands a re-enable to the gate while the queue is at the cap (`holdsAutoRead(_:)`), and the
///   gate applies it once below. Worst case per direction and connection: just under the cap
///   plus one NIO read cycle (`maxMessagesPerRead` buffers, 4 x 64 KiB by default).
/// - Live changes: every `read`/`channelRead` compares `TrafficPolicyProvider.revision` and
///   re-resolves on a change. Without a condition the queue is delivered first, then the fast
///   path resumes; a change to offline closes the channel at the next read.
/// - The origin's end of input (download only): NIO closes a channel at the peer's FIN and tears
///   its pipeline down right after, and a teardown hands the whole queue on at once, which would
///   end the pacing for everything below the read cap (a close-delimited answer of a few hundred
///   KiB would arrive unthrottled). While shaping, the gate therefore asks the channel for half
///   closure (`allowRemoteHalfClosure`; NIOSSL honours it for a close_notify too), receives the
///   FIN as `ChannelEvent.inputClosed`, queues it behind the bytes and closes the channel itself
///   once they are all delivered. Without a condition the option stays off and the FIN is the
///   ordinary close it always was. When the TLS layer in front reported a ragged end (the origin
///   dropped TCP without a close_notify), the close goes out through `UpstreamSocketCloser`,
///   skipping the TLS layer: a graceful TLS close would wait (~5 s) for a close_notify that never
///   comes, where an unshaped FIN closes at once. The upload gate never does this: a client that disconnects is
///   gone, so what it sent is released in order at once (prompt cancellation).
/// - Removal (including pipeline teardown after the channel closed) cancels the timer and hands
///   whatever is still queued to the next handler at once, in order: bytes already read are never
///   dropped and the end of the stream always arrives (a held end of input becomes a close).
final class ConnectionPacer: ChannelDuplexHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    enum Direction { case upload, download }

    static let sliceBytes = 16_384
    static let maxQueuedBytes = 262_144
    /// How often a paused downstream (no read requested, autoRead off) is checked again.
    static let pausedRecheck: TimeAmount = .milliseconds(10)

    private enum Item {
        case data(ByteBuffer, due: Duration)
        case readComplete
        case userEvent(Any)
        case error(Error)
        case inactive
        /// The origin's FIN, held behind the bytes read before it; becomes a channel close.
        case endOfInput
    }

    private enum Mode { case passthrough, shaping, offline }

    private let direction: Direction
    private let traffic: TrafficPolicyProvider
    private let clock: () -> Duration
    private let random: @Sendable () -> Double
    /// Whether the downstream reads continuously. Tests replace it: an `EmbeddedChannel` always
    /// reports autoRead on.
    var autoReadProbe: (ChannelHandlerContext) -> Bool = { context in
        (try? context.channel.syncOptions?.getOption(ChannelOptions.autoRead)) ?? true
    }

    private var context: ChannelHandlerContext?
    private var target: (host: String, port: Int)?
    private var seenRevision: UInt64 = 0
    private var mode = Mode.passthrough {
        didSet { if mode != oldValue { updateHalfClosure() } }
    }
    /// This gate switched `allowRemoteHalfClosure` on, so it owns the `inputClosed` it brings.
    private var halfClosureRequested = false
    /// The TLS layer in front reported an unclean EOF (no close_notify) before the end of input.
    private var raggedTLSEnd = false
    private var shaper: TrafficShaper?
    private var queue = CircularBuffer<Item>()
    private(set) var queuedBytes = 0
    /// The downstream asked for one read cycle that has not been delivered yet.
    private var readRequested = false
    /// A downstream read that has not been passed to the socket yet (held at the cap).
    private var socketReadOwed = false
    private var deliveredSinceComplete = false
    /// The downstream turned autoRead on while the queue was at the cap; applied once below it.
    private(set) var autoReadHeld = false
    private var timer: Scheduled<Void>?
    private var timerDeadline: NIODeadline?
    private var pumping = false

    var hasPendingTimer: Bool { timer != nil }

    init(direction: Direction, traffic: TrafficPolicyProvider,
         clock: @escaping () -> Duration = { .nanoseconds(Int64(NIODeadline.now().uptimeNanoseconds)) },
         random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }) {
        self.direction = direction
        self.traffic = traffic
        self.clock = clock
        self.random = random
    }

    /// The connection now carries traffic for `host:port` (on the loop); resolves the condition.
    /// An offline host does not close the connection here: that connect fails locally on its own
    /// (`NetworkConditionError.offline`), and the client keeps its connection for other hosts.
    func bind(host: String, port: Int) {
        target = (host, port)
        seenRevision = traffic.revision
        resolve(closingWhenOffline: false)
    }

    /// Called by `Channel.setAutoRead` on the loop before it changes the option. Returns true when
    /// the gate keeps a re-enable for later (queue at the cap): the caller then leaves autoRead
    /// off, and deliveries continue as if it were on. Turning autoRead off drops a held re-enable.
    func holdsAutoRead(_ enabled: Bool) -> Bool {
        guard enabled, queuedBytes >= Self.maxQueuedBytes, context != nil else {
            autoReadHeld = false
            return false
        }
        autoReadHeld = true
        // Reading counts as resumed: deliver what is due now (and release below the cap).
        if let context { pump(context) }
        return true
    }

    // MARK: ChannelHandler

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        cancelTimer()
        let pending = queue
        queue.removeAll()
        queuedBytes = 0
        for item in pending { release(item, context: context) }
        if deliveredSinceComplete { completeCycle(context) }
        if socketReadOwed, context.channel.isActive {
            socketReadOwed = false
            context.read()
        }
        releaseAutoRead(context)
        self.context = nil
    }

    func read(context: ChannelHandlerContext) {
        refresh()
        switch mode {
        case .offline:
            goOffline(context)
            return
        case .passthrough where queue.isEmpty:
            context.read()
            return
        case .passthrough, .shaping:
            readRequested = true
            socketReadOwed = true
            pump(context)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        refresh()
        switch mode {
        case .offline:
            goOffline(context)
            return
        case .passthrough where queue.isEmpty:
            context.fireChannelRead(data)
            return
        case .passthrough, .shaping:
            enqueue(unwrapInboundIn(data))
            pump(context)
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        guard !queue.isEmpty else {
            context.fireChannelReadComplete()
            return
        }
        queue.append(.readComplete)
        pump(context)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if halfClosureRequested, let channelEvent = event as? ChannelEvent, channelEvent == .inputClosed {
            // The origin's FIN: the close it would have been, once what precedes it is delivered.
            queue.append(.endOfInput)
            pump(context)
            return
        }
        guard !queue.isEmpty else {
            context.fireUserInboundEventTriggered(event)
            return
        }
        queue.append(.userEvent(event))
        pump(context)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if halfClosureRequested, case NIOSSLError.uncleanShutdown = error { raggedTLSEnd = true }
        guard !queue.isEmpty else {
            context.fireErrorCaught(error)
            return
        }
        queue.append(.error(error))
        pump(context)
    }

    func channelInactive(context: ChannelHandlerContext) {
        guard !queue.isEmpty else {
            context.fireChannelInactive()
            return
        }
        queue.append(.inactive)
        pump(context)
    }

    // MARK: Conditions

    private func refresh() {
        let revision = traffic.revision
        guard revision != seenRevision else { return }
        seenRevision = revision
        resolve(closingWhenOffline: true)
    }

    /// `closingWhenOffline`: a published change made the bound host offline, so this existing
    /// connection closes at its next read.
    private func resolve(closingWhenOffline: Bool) {
        guard let target, let resolved = traffic.current().conditions.resolve(host: target.host, port: target.port) else {
            mode = .passthrough
            return
        }
        let profile = resolved.profile
        if profile.isOffline {
            mode = closingWhenOffline ? .offline : .passthrough
            return
        }
        let kbps = direction == .upload ? profile.uploadKbps : profile.downloadKbps
        let config = TrafficShaper.Config(
            bytesPerSecond: kbps.flatMap { $0 > 0 ? min($0, Int.max / 125) * 125 : nil },
            latency: .milliseconds(max(0, profile.latencyMs)),
            lossPercent: max(0, profile.lossPercent))
        guard config.bytesPerSecond != nil || config.latency > .zero || config.lossPercent > 0 else {
            mode = .passthrough
            return
        }
        mode = .shaping
        if shaper == nil { shaper = TrafficShaper(config) } else { shaper?.reconfigure(config) }
    }

    /// Half closure is asked for only while a download is shaped (see the type comment).
    private func updateHalfClosure() {
        guard direction == .download, let context else { return }
        let wanted = mode == .shaping
        guard wanted != halfClosureRequested else { return }
        guard (try? context.channel.syncOptions?.setOption(ChannelOptions.allowRemoteHalfClosure, value: wanted)) != nil else { return }
        halfClosureRequested = wanted
    }

    /// Simulated loss of connectivity: what is queued is discarded with the connection.
    private func goOffline(_ context: ChannelHandlerContext) {
        cancelTimer()
        queue.removeAll()
        queuedBytes = 0
        readRequested = false
        socketReadOwed = false
        deliveredSinceComplete = false
        autoReadHeld = false
        context.close(promise: nil)
    }

    // MARK: Queue

    private func enqueue(_ buffer: ByteBuffer) {
        var buffer = buffer
        let now = clock()
        repeat {
            let length = min(buffer.readableBytes, Self.sliceBytes)
            let slice = buffer.readSlice(length: length)!
            var due = now
            if mode == .shaping {
                let draw = (shaper?.config.lossPercent ?? 0) > 0 ? random() : 1
                if let delay = shaper?.delay(forChunkOf: length, at: now, lossDraw: draw) { due = now + delay }
            }
            queue.append(.data(slice, due: due))
            queuedBytes += length
        } while buffer.readableBytes > 0
    }

    /// Delivers everything that is due while the downstream reads, then arms the timer for the
    /// next due item (or the paused re-check) and passes an owed read to the socket.
    private func pump(_ context: ChannelHandlerContext) {
        guard !pumping else { return }
        pumping = true
        defer { pumping = false }
        var wake: Duration?
        delivery: while let item = queue.first {
            switch item {
            case .data(let buffer, let due):
                let now = clock()
                if due > now {
                    wake = due
                    break delivery
                }
                guard readRequested || autoReadHeld || autoReadProbe(context) else {
                    wake = now + .nanoseconds(Self.pausedRecheck.nanoseconds)
                    break delivery
                }
                queue.removeFirst()
                queuedBytes -= buffer.readableBytes
                deliveredSinceComplete = true
                context.fireChannelRead(wrapInboundOut(buffer))
            case .readComplete:
                queue.removeFirst()
                if deliveredSinceComplete { completeCycle(context) }
            case .userEvent, .error, .inactive, .endOfInput:
                queue.removeFirst()
                release(item, context: context)
            }
            // A callout removed this handler; its removal already released the rest.
            guard self.context != nil else { return }
        }
        // Each delivery burst ends a downstream read cycle, so what was delivered is flushed now.
        if wake != nil, deliveredSinceComplete { completeCycle(context) }
        arm(wake, context: context)
        if socketReadOwed, queuedBytes < Self.maxQueuedBytes {
            socketReadOwed = false
            context.read()
        }
        if queuedBytes < Self.maxQueuedBytes { releaseAutoRead(context) }
    }

    /// Applies a held autoRead re-enable (the downstream's own request, deferred at the cap).
    private func releaseAutoRead(_ context: ChannelHandlerContext) {
        guard autoReadHeld else { return }
        autoReadHeld = false
        try? context.channel.syncOptions?.setOption(ChannelOptions.autoRead, value: true)
    }

    private func completeCycle(_ context: ChannelHandlerContext) {
        deliveredSinceComplete = false
        readRequested = false
        context.fireChannelReadComplete()
    }

    /// Hands one queued item on without looking at its due time.
    private func release(_ item: Item, context: ChannelHandlerContext) {
        switch item {
        case .data(let buffer, _):
            deliveredSinceComplete = true
            context.fireChannelRead(wrapInboundOut(buffer))
        case .readComplete:
            if deliveredSinceComplete { completeCycle(context) }
        case .userEvent(let event): context.fireUserInboundEventTriggered(event)
        case .error(let error): context.fireErrorCaught(error)
        case .inactive: context.fireChannelInactive()
        case .endOfInput:
            if raggedTLSEnd, let closer = try? context.pipeline.syncOperations.handler(type: UpstreamSocketCloser.self) {
                closer.closeSocket()
            } else {
                context.close(promise: nil)
            }
        }
    }

    // MARK: Timer

    private func arm(_ wake: Duration?, context: ChannelHandlerContext) {
        guard let wake else {
            cancelTimer()
            return
        }
        let deadline = Self.deadline(wake)
        if timer != nil, timerDeadline == deadline { return }
        cancelTimer()
        timerDeadline = deadline
        timer = context.eventLoop.assumeIsolated().scheduleTask(deadline: deadline) { [weak self] in
            guard let self else { return }
            self.timer = nil
            self.timerDeadline = nil
            guard let context = self.context else { return }
            self.pump(context)
        }
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
        timerDeadline = nil
    }

    /// A point on the injected clock (the uptime clock by default) as a loop deadline.
    private static func deadline(_ point: Duration) -> NIODeadline {
        let components = point.components
        let nanoseconds = components.seconds * 1_000_000_000 + components.attoseconds / 1_000_000_000
        return .uptimeNanoseconds(UInt64(max(0, nanoseconds)))
    }
}

/// Sits right behind the socket, in front of any TLS layer of an upstream channel that has a
/// download gate. Closing through its own context skips the TLS layer, so no graceful TLS shutdown
/// (which waits for the peer's close_notify) runs on a connection the peer has already dropped.
final class UpstreamSocketCloser: ChannelOutboundHandler {
    typealias OutboundIn = NIOAny
    private var context: ChannelHandlerContext?

    func handlerAdded(context: ChannelHandlerContext) { self.context = context }
    func handlerRemoved(context: ChannelHandlerContext) { self.context = nil }

    /// On the channel's loop.
    func closeSocket() { context?.close(promise: nil) }
}

/// A connection the network conditions do not let start (offline: 100 % loss).
enum NetworkConditionError: Error {
    case offline
}
