import FlowStore
import Foundation
import Localization
import NIOCore
import NIOHTTP1
import RulesEngine

/// These interfaces and their implementations are confined to the event loop that owns the exchange.
typealias UpstreamConnectionFactory = (String, Int, EventLoop) -> EventLoopFuture<Channel>

/// Part of the pool key: a route that offers only http/1.1 never shares a connection (or an h2
/// session) with an automatic one.
enum UpstreamProtocolPolicy: Hashable {
    case automatic
    /// An Upgrade request: http/1.1 by ALPN and a dedicated connection.
    case http1OnlyUpgrade
    /// The sender chose HTTP/1.1 (Compose `http1Only`): http/1.1 by ALPN.
    case http1Only
}
/// Drives DNS, the upstream-proxy bypass and CONNECT target, TLS server name and verification,
/// ALPN and the pool key. `host` has no IPv6 brackets.
struct UpstreamRoute: Hashable {
    let scheme: String
    let host: String
    let port: Int
    let policy: UpstreamProtocolPolicy
    /// A rule chose this destination: a direct connection that reaches this proxy's own
    /// listener is closed before TLS or any request byte.
    var rejectsListener = false
}

/// What an admitted exchange forwards: `HTTPExchange.forwardUnchanged`, or what its rule session
/// (and later a breakpoint) decided.
struct HTTPRequestDecision {
    /// The head to forward and replay; `HTTPExchange.requestHead` stays the original prepared head.
    var head: HTTPRequestHead
    /// Where the request goes; the route is derived from it once, before acquisition.
    var target: RequestTarget
    /// The target's scheme; nil keeps the exchange's own.
    var scheme: String? = nil
    /// A rule replaced the original target: the route refuses this proxy's own listener endpoints.
    var remapped = false
    /// False when the forwarded body cannot be replayed (for example a spool-backed edit): an
    /// implicit retry is then never attempted.
    var allowsReplay = true
    /// Runs once after recording the original final head (never interim 100/103). A stage may
    /// retain its continuation while paused; it resumes on the owner loop at most once. A throw
    /// before resume becomes one local failure. Cancellation abandons the retained continuation.
    var finalResponseStage: (HTTPResponseHead, @escaping (HTTPResponseHead) -> Void) throws -> Void = { head, resume in resume(head) }
}

protocol UpstreamResponseSink: AnyObject {
    func receiveResponse(_ part: HTTPClientResponsePart)
    func responseReadStarted()
    func responseReadComplete()
    func upstreamWritabilityChanged(_ writable: Bool)
    func upstreamClosed(error: Error?)
}

extension UpstreamResponseSink {
    func responseReadStarted() {}
    func responseReadComplete() {}
}

protocol UpstreamLease: AnyObject {
    var channel: Channel { get }
    var version: HTTPWireVersion { get }
    var wasReused: Bool { get }
    var isWritable: Bool { get }
    func write(_ part: HTTPClientRequestPart) -> EventLoopFuture<Void>
    func flush()
    func setResponseReading(_ enabled: Bool)
    func release(reusable: Bool)
    func cancel(error: Error?)
}

protocol HTTP1UpstreamLease: UpstreamLease {
    /// Exactly one transfer. TLS and codecs remain until the adapter installs the raw relay.
    func detachForUpgrade() -> Channel?
}

/// The response side of one exchange. It need not be backed by a client socket; every
/// requirement is used only on `eventLoop`, which also owns the exchange.
protocol DownstreamResponseWriter: AnyObject {
    var eventLoop: EventLoop { get }
    var version: HTTPWireVersion { get }
    /// Whether the response side accepts more bytes now (upstream response reading follows it).
    var isWritable: Bool { get }
    /// Whether the response side can still deliver a response (gates an implicit request replay).
    var isActive: Bool { get }
    func write(_ part: HTTPServerResponsePart) -> EventLoopFuture<Void>
    func flush()
    func setRequestReading(_ enabled: Bool)
    func responseFinished()
    func abort(_ error: Error)
    /// A rule closes the response side before anything was written to it (D15): over HTTP/1 the client
    /// connection (graceful = FIN, reset = RST), over HTTP/2 only this stream (RST_STREAM).
    func closeConnection(_ mode: RulesEngine.CloseMode)
}

extension DownstreamResponseWriter {
    /// Without a socket of its own (a virtual client) closing is aborting.
    func closeConnection(_ mode: RulesEngine.CloseMode) { abort(HTTPTransportError.cancelled) }
}

/// What an exchange needs from the connection that owns it, independent of a client socket.
/// Confined to the owning event loop, like the exchange itself.
protocol HTTPOutboundEnvironment: AnyObject {
    var contextID: UUID { get }
    var environment: ProxyEnvironment { get }
    var limits: HTTPTransportLimits { get }
    var upstreamPool: UpstreamSessionPool { get }
    var knownClient: ClientApp? { get }
    /// The client socket's peer address, and the TLS version it negotiated with the proxy (if any).
    var clientIP: String? { get }
    var downstreamTLSVersion: String? { get }
    var forwardingAllowed: Bool { get }
    func onClient(_ callback: @escaping (ClientApp) -> Void)
    func whenForwardingAllowed(_ callback: @escaping () -> Void)
    func register(_ exchange: HTTPExchange, streamID: Int?) -> Bool
    func unregister(_ exchange: HTTPExchange)
    func reservePendingBytes(_ count: Int) -> Bool
    func releasePendingBytes(_ count: Int)
    /// An exchange of this connection holds a breakpoint ticket (true) or no longer does (false).
    /// Called on the owning loop, once per ticket each way.
    func breakpointPauseChanged(_ paused: Bool)
    /// The connection now carries traffic for `host:port`: its upload gate (if any) resolves the
    /// network condition for that host. Called on the owning loop.
    func bindShaping(host: String, port: Int)
}

extension HTTPOutboundEnvironment {
    /// A virtual client (Compose) has no socket, so no address and no downstream TLS.
    var clientIP: String? { nil }
    var downstreamTLSVersion: String? { nil }
    /// Client connections have no deadline of their own that a breakpoint pauses.
    func breakpointPauseChanged(_ paused: Bool) {}
    /// Without a client socket there is no upload gate.
    func bindShaping(host: String, port: Int) {}
}

protocol HTTP1DownstreamResponseWriter: DownstreamResponseWriter {
    /// A removed adapter cannot submit a response head; capture must leave its version unknown.
    var isAttached: Bool { get }
    func finish(keepAlive: Bool, after: EventLoopFuture<Void>?, discardUpload: Bool)
    func upgrade(lease: UpstreamLease, observation: ObservationHandle?)
}

enum HTTPTransportError: Error {
    case cancelled, closed, acquisitionTimedOut, capacityExceeded, pendingBytesExceeded

    func description(localizer: Localizer = L10n.localizer) -> String {
        let key: String
        switch self {
        case .cancelled: key = "proxyTransport.cancelled"
        case .closed: key = "proxyTransport.closed"
        case .acquisitionTimedOut: key = "proxyTransport.acquisitionTimedOut"
        case .capacityExceeded: key = "proxyTransport.capacityExceeded"
        case .pendingBytesExceeded: key = "proxyTransport.pendingBytesExceeded"
        }
        return localizer.format(key, arguments: [])
    }
}
