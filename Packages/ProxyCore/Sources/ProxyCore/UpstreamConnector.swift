import Darwin
import Localization
import NIOCore
import NIOPosix
import NIOSSL
import RulesEngine

/// The single place that opens connections towards origins. With an upstream proxy configured
/// (the user's original system proxy) and a host not on its bypass list, the connection is a
/// CONNECT tunnel through that proxy; otherwise it is direct TCP. Callers cannot tell the
/// difference: either way they get a channel that talks to the origin, so plain HTTP requests are
/// sent origin-form inside the tunnel, and TLS to the origin starts once it stands.
struct UpstreamConnector: Sendable {
    var connectTimeout: TimeAmount
    var upstreamProxy: UpstreamProxy?
    /// Network conditions: an offline host fails at once, and every connection gets a download
    /// gate (`ConnectionPacer`) in front. nil: connections are opened exactly as before.
    var traffic: TrafficPolicyProvider?

    init(configuration: ProxyConfiguration, traffic: TrafficPolicyProvider? = nil) {
        connectTimeout = configuration.connectTimeout
        upstreamProxy = configuration.upstreamProxy
        self.traffic = traffic
    }

    /// Whether connections to `host` go through the upstream proxy's tunnel.
    func isTunneled(_ host: String) -> Bool {
        guard let upstreamProxy else { return false }
        return !upstreamProxy.shouldBypass(host)
    }

    /// Whether the network conditions currently make `host:port` offline (100 % loss). Used before a
    /// connection is opened and before an idle pooled one is reused: offline never sends a request.
    func isOffline(host: String, port: Int) -> Bool {
        traffic?.current().conditions.resolve(host: host, port: port)?.profile.isOffline == true
    }

    /// Opens a connection to `host:port` on `eventLoop` — the client connection's loop, so
    /// both halves of an exchange stay confined to one thread. `host` has no IPv6 brackets.
    /// Through the upstream proxy, connecting and the CONNECT exchange together are bounded by
    /// `connectTimeout`. Cancelling `attempt` closes every socket it opened, so the returned
    /// future fails at once instead of at the timeout.
    /// With network conditions, an offline `host:port` fails with `NetworkConditionError.offline`
    /// before any socket is opened, and an opened connection gets a `.download` gate first in its
    /// pipeline, bound to `host:port` (TLS added later goes in front of it).
    func connect(host: String, port: Int, on eventLoop: EventLoop,
                 attempt: UpstreamConnectAttempt? = nil) -> EventLoopFuture<Channel> {
        guard let traffic else { return open(host: host, port: port, on: eventLoop, attempt: attempt) }
        if isOffline(host: host, port: port) {
            return eventLoop.makeFailedFuture(NetworkConditionError.offline)
        }
        return open(host: host, port: port, on: eventLoop, attempt: attempt).flatMapThrowing { channel in
            // On the channel's loop: the connect future completes there.
            do {
                let pacer = ConnectionPacer(direction: .download, traffic: traffic)
                try channel.pipeline.syncOperations.addHandler(pacer, position: .first)
                pacer.bind(host: host, port: port)
            } catch {
                channel.close(promise: nil)
                throw error
            }
            return channel
        }
    }

    private func open(host: String, port: Int, on eventLoop: EventLoop,
                      attempt: UpstreamConnectAttempt?) -> EventLoopFuture<Channel> {
        guard let proxy = upstreamProxy, !proxy.shouldBypass(host) else {
            return openTCP(host: host, port: port, on: eventLoop, attempt: attempt)
        }
        let deadline = NIODeadline.now() + connectTimeout
        let proxyAuthority = Self.authority(host: proxy.host, port: proxy.port)
        return openTCP(host: proxy.host, port: proxy.port, on: eventLoop, attempt: attempt)
            .flatMapErrorThrowing { error in
                throw UpstreamProxyError.unreachable(proxy: proxyAuthority, underlying: error)
            }
            .flatMap { channel in
                let established = channel.eventLoop.makePromise(of: Void.self)
                do {
                    try channel.pipeline.syncOperations.addHandler(
                        UpstreamProxyHandshake(
                            host: host, port: port, timeout: deadline - .now(), promise: established))
                } catch {
                    channel.close(promise: nil)
                    return channel.eventLoop.makeFailedFuture(error)
                }
                return established.futureResult.map { channel }
            }
    }

    /// A cancelled attempt fails with `HTTPTransportError.cancelled`: at once when it was
    /// cancelled before the call, otherwise once its socket (or name resolution) settled.
    private func openTCP(host: String, port: Int, on eventLoop: EventLoop,
                         attempt: UpstreamConnectAttempt?) -> EventLoopFuture<Channel> {
        var bootstrap = ClientBootstrap(group: eventLoop)
            .connectTimeout(connectTimeout)
            .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
        guard let attempt else { return bootstrap.connect(host: host, port: port) }
        guard !attempt.isCancelled else { return eventLoop.makeFailedFuture(HTTPTransportError.cancelled) }
        let owner = NIOLoopBound(attempt, eventLoop: eventLoop)
        bootstrap = bootstrap.channelInitializer { channel in
            // Runs on `eventLoop` (the bootstrap's only loop), before the connect starts.
            owner.value.opened(channel)
            guard !owner.value.isCancelled else { return channel.eventLoop.makeFailedFuture(HTTPTransportError.cancelled) }
            return channel.eventLoop.makeSucceededVoidFuture()
        }
        return bootstrap.connect(host: host, port: port).flatMapErrorThrowing { error in
            // On `eventLoop`: the connect future completes there.
            throw owner.value.isCancelled ? HTTPTransportError.cancelled : error
        }
    }

    /// `host:port`, with IPv6 hosts in brackets.
    static func authority(host: String, port: Int) -> String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    /// A short reason for the 502 body and flow state. New transport reasons use the localizer;
    /// existing protocol/system error diagnostics retain their original representation.
    static func describe(_ error: Error, localizer: Localizer = L10n.localizer) -> String {
        switch error {
        case let error as HTTPTransportError:
            return error.description(localizer: localizer)
        case let error as HTTP2TransportError:
            return error.description(localizer: localizer)
        case let error as HTTPTranslationError:
            return error.description(localizer: localizer)
        case let error as NetworkConditionError:
            switch error {
            case .offline: return localizer.string("proxyLocalFailure.conditionOffline")
            }
        case let error as UpstreamProxyError:
            switch error {
            case .unreachable(let proxy, let underlying):
                return localizer.format("proxyFailure.upstreamProxyUnreachable", arguments: [proxy, describe(underlying, localizer: localizer)])
            case .rejected(let status):
                return localizer.format("proxyFailure.upstreamProxyRejected", arguments: [status])
            case .invalidResponse:
                return localizer.string("proxyFailure.upstreamProxyInvalidResponse")
            case .closed:
                return localizer.string("proxyFailure.upstreamProxyClosed")
            case .timedOut:
                return localizer.string("proxyFailure.upstreamProxyTimedOut")
            }
        case ChannelError.connectTimeout:
            return localizer.string("proxyFailure.connectTimeout")
        case NIOSSLError.handshakeFailed:
            return localizer.string("proxyFailure.tlsHandshakeFailed")
        case let error as NIOConnectionError:
            if let first = error.connectionErrors.first {
                return describe(first.error, localizer: localizer)
            }
            if error.dnsAError != nil || error.dnsAAAAError != nil {
                return localizer.string("proxyFailure.dnsFailed")
            }
            return "\(error)"
        case let error as IOError:
            switch error.errnoCode {
            case ECONNREFUSED: return localizer.string("proxyFailure.connectionRefused")
            case ECONNRESET: return localizer.string("proxyFailure.connectionReset")
            case ETIMEDOUT: return localizer.string("proxyFailure.connectTimeout")
            case ENETUNREACH, EHOSTUNREACH: return localizer.string("proxyFailure.networkUnreachable")
            default: return "\(error)"
            }
        default:
            return "\(error)"
        }
    }
}

/// The sockets of one connection attempt that has not completed yet. Cancelling it closes them, so
/// a connect (or an upstream proxy's CONNECT) in flight fails at once and never later hands a
/// connection to anyone. Confined to the event loop of the attempt.
final class UpstreamConnectAttempt {
    private var channels: [Channel] = []
    private(set) var isCancelled = false

    func opened(_ channel: Channel) {
        if isCancelled { channel.close(promise: nil) } else { channels.append(channel) }
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        let open = channels
        channels.removeAll()
        open.forEach { $0.close(promise: nil) }
    }
}

/// Why a tunnel through the upstream proxy could not be opened.
enum UpstreamProxyError: Error {
    /// The proxy itself (`host:port`) could not be reached.
    case unreachable(proxy: String, underlying: any Error)
    /// The proxy answered the CONNECT with a non-2xx status.
    case rejected(status: Int)
    /// Not an HTTP response head, or a head over `UpstreamProxyHandshake.maxHeadSize`.
    case invalidResponse
    /// The proxy closed the connection before answering.
    case closed
    /// No answer within the connect timeout.
    case timedOut
}

/// The first handler on a connection to the upstream proxy: sends `CONNECT host:port`, reads the
/// response head, and on a 2xx completes `promise` and removes itself. Bytes that arrived after
/// the head (an origin that speaks first) are passed on to the handlers the connector's caller
/// added in the meantime. Any other outcome fails `promise` and closes the channel.
final class UpstreamProxyHandshake: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundOut = ByteBuffer

    static let maxHeadSize = 16 * 1024
    private static let headTerminator = Array("\r\n\r\n".utf8)

    private let target: String
    private let timeout: TimeAmount
    private let promise: EventLoopPromise<Void>
    private var context: ChannelHandlerContext?
    private var buffered = ByteBuffer()
    private var timer: Scheduled<Void>?
    private var started = false
    private var finished = false

    init(host: String, port: Int, timeout: TimeAmount, promise: EventLoopPromise<Void>) {
        self.target = UpstreamConnector.authority(host: host, port: port)
        self.timeout = timeout
        self.promise = promise
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        if context.channel.isActive { start(context: context) }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        // Removed without an answer (e.g. the pipeline was torn down): never leak the promise.
        if !finished {
            finished = true
            timer?.cancel()
            promise.fail(UpstreamProxyError.closed)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        start(context: context)
        context.fireChannelActive()
    }

    private func start(context: ChannelHandlerContext) {
        guard !started else { return }
        started = true
        timer = context.eventLoop.assumeIsolated().scheduleTask(in: timeout) {
            self.fail(UpstreamProxyError.timedOut)
        }
        let request = "CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\n\r\n"
        context.writeAndFlush(wrapOutboundOut(ByteBuffer(string: request)), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !finished else {
            context.fireChannelRead(data)
            return
        }
        var incoming = unwrapInboundIn(data)
        buffered.writeBuffer(&incoming)
        guard let headLength = headLength() else {
            if buffered.readableBytes > Self.maxHeadSize { fail(UpstreamProxyError.invalidResponse) }
            return
        }
        guard headLength <= Self.maxHeadSize, let status = statusCode(headLength: headLength) else {
            fail(UpstreamProxyError.invalidResponse)
            return
        }
        guard (200..<300).contains(status) else {
            fail(UpstreamProxyError.rejected(status: status))
            return
        }
        finished = true
        timer?.cancel()
        buffered.moveReaderIndex(forwardBy: headLength)
        // Callbacks run inline: the caller's handlers are in place before this one leaves.
        promise.succeed(())
        context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
    }

    func removeHandler(context: ChannelHandlerContext, removalToken: ChannelHandlerContext.RemovalToken) {
        if finished, buffered.readableBytes > 0 {
            let leftover = buffered
            buffered = ByteBuffer()
            context.fireChannelRead(wrapInboundOut(leftover))
            context.fireChannelReadComplete()
        }
        context.leavePipeline(removalToken: removalToken)
    }

    func channelInactive(context: ChannelHandlerContext) {
        fail(UpstreamProxyError.closed)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        guard !finished else {
            context.fireErrorCaught(error)
            return
        }
        fail(error)
    }

    private func fail(_ error: Error) {
        guard !finished else { return }
        finished = true
        timer?.cancel()
        promise.fail(error)
        context?.close(promise: nil)
    }

    /// The length of the response head including its terminating blank line, once it is complete.
    private func headLength() -> Int? {
        let bytes = buffered.readableBytesView
        let terminator = Self.headTerminator
        guard bytes.count >= terminator.count else { return nil }
        var index = bytes.startIndex
        while index <= bytes.endIndex - terminator.count {
            if bytes[index..<index + terminator.count].elementsEqual(terminator) {
                return index - bytes.startIndex + terminator.count
            }
            index += 1
        }
        return nil
    }

    /// The status code from the status line (`HTTP/1.x SSS reason`), or nil if it is malformed.
    private func statusCode(headLength: Int) -> Int? {
        guard let head = buffered.getString(at: buffered.readerIndex, length: headLength),
              let statusLine = head.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first
        else { return nil }
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), parts[1].count == 3, let status = Int(parts[1])
        else { return nil }
        return status
    }
}
