import FlowStore
import Foundation
import NIOCore
import NIOHTTP1
import RulesEngine

/// The request body a virtual client submits: nothing, bytes already in memory, or an owned file
/// lease streamed in chunks of at most 64 KiB (never loaded whole).
enum OutboundRequestBody {
    case none
    case bytes(Data)
    case file(OwnedFileLease)
}

/// How one virtual client ended, plus what it still held at that moment (always zero unless a
/// path leaked; the service keeps the sum for its resource checks).
struct OutboundCompletion: Sendable {
    let result: ComposeResult
    let residualPendingBytes: Int
    let residualUpstreamSockets: Int
}

/// A channel-free client for exactly one `HTTPExchange` (a Compose send). It is both the outbound
/// environment (its own upstream pool and pending-byte quota, forwarding allowed at once, no client
/// identity) and the response writer, which collects the delivered response instead of encoding
/// it onto a socket.
///
/// Declared writer semantics (T4b): `version` is `.http1_1` and this is not an
/// `HTTP1DownstreamResponseWriter`, so the exchange treats it as always attached. A local failure
/// is therefore delivered here as a generated response (reported as that failure, never as a
/// response); a 101 upgrade, an upstream that closes after a final head or an exchange cancellation
/// ends in `abort`, reported as a failure. Every write completes at once: the response is held in
/// memory up to `responseBodyLimit` bytes and only counted beyond it, so collecting never slows the
/// upstream read. `responseFinished`/`abort` end the client exactly once.
///
/// The send's total timeout is one absolute deadline on `eventLoop`; while the exchange holds a
/// breakpoint ticket it is suspended (the ticket's own deadline governs) and the remaining time
/// resumes afterwards. Once a complete response arrived the request body is not read any further.
///
/// Confined to `eventLoop`, like the exchange it owns.
final class OutboundExecutionContext: HTTPOutboundEnvironment, DownstreamResponseWriter {
    let contextID: UUID
    let environment: ProxyEnvironment
    let limits: HTTPTransportLimits
    let upstreamPool: UpstreamSessionPool
    let eventLoop: EventLoop
    let version: HTTPWireVersion = .http1_1
    var knownClient: ClientApp? { nil }
    let forwardingAllowed = true
    /// Accepts bytes until the client ended; it never needs the upstream to slow down.
    var isWritable: Bool { terminal == nil }
    var isActive: Bool { terminal == nil }
    var completion: EventLoopFuture<OutboundCompletion> { promise.futureResult }

    private enum Terminal { case finished, aborted }

    private let responseBodyLimit: Int
    private let promise: EventLoopPromise<OutboundCompletion>
    private let bodyReleased: () -> Void
    private var body: OutboundRequestBody
    private var bodyOffset: Int64 = 0
    private var bodyEnded = false
    private var bodyReleaseReported = false
    private var reading = false
    private var feeding = false
    private var readInFlight = false
    private var capacityDeadline: NIODeadline?
    private var retry: Scheduled<Void>?
    /// The registered exchange; `started` keeps it for its flow and local failure after it settled.
    private var exchange: HTTPExchange?
    private var started: HTTPExchange?
    private var didStart = false
    /// Test observation only: told the exchange once it exists (`ComposeLifetimeProbe`).
    var exchangeCreated: ((HTTPExchange) -> Void)?
    /// Test observation only: told the size of every chunk read from a file body.
    var bodyRead: ((Int) -> Void)?
    private(set) var pendingBytes = 0
    private var terminal: Terminal?
    private var failure: ComposeFailure?
    private var poolClosed = false
    private var completed = false
    private var timeoutFailure: ComposeFailure?
    private var timeoutDeadline: NIODeadline?
    /// What was left of the timeout when a breakpoint paused it.
    private var timeoutRemaining: TimeAmount?
    private var timeoutTask: Scheduled<Void>?
    /// Bumped whenever the armed timer is cancelled or replaced. NIO runs every task due at one
    /// instant in a single batch, so a timer callback already in that batch still runs after
    /// another task of the batch cancelled it; it must then see it is stale.
    private var timeoutGeneration: UInt64 = 0
    private var breakpointPauses = 0
    private var head: HTTPResponseHead?
    private var collected = ByteBuffer()
    private var receivedBytes: UInt64 = 0
    private var truncated = false
    private var trailers: HTTPHeaders?
    private var ended = false

    /// `bodyReleased` runs once, when a file body's lease was given back.
    init(contextID: UUID, eventLoop: EventLoop, environment: ProxyEnvironment, limits: HTTPTransportLimits = .init(),
         responseBodyLimit: Int, body: OutboundRequestBody, bodyReleased: @escaping () -> Void = {}) {
        self.contextID = contextID
        self.eventLoop = eventLoop
        self.environment = environment
        self.limits = limits
        self.responseBodyLimit = max(0, responseBodyLimit)
        self.body = body
        self.bodyReleased = bodyReleased
        self.promise = eventLoop.makePromise()
        self.upstreamPool = UpstreamSessionPool(eventLoop: eventLoop, environment: environment, limits: limits)
    }

    /// Admits and executes the one exchange of this client, then submits its body. At `deadline`
    /// (not counting breakpoint pauses) the client ends with `timeoutFailure`.
    func start(head: HTTPRequestHead, target: RequestTarget, scheme: String, policy: HTTPExecutionPolicy,
               provenance: FlowProvenance, deadline: NIODeadline? = nil, timeoutFailure: ComposeFailure? = nil) {
        eventLoop.preconditionInEventLoop()
        precondition(!didStart, "one exchange per virtual client")
        // A client that already ended never creates an exchange (nothing could release it again).
        guard terminal == nil else { return }
        if let deadline, let timeoutFailure {
            self.timeoutFailure = timeoutFailure
            armTimeout(deadline)
        }
        // `register` runs inside the initializer; it accepts only while nothing has started.
        let exchange = HTTPExchange(requestHead: head, target: target, scheme: scheme, downstream: self, connection: self,
                                    transport: HTTPTransportMetadata(), policy: policy, provenance: provenance)
        didStart = true
        started = exchange
        exchangeCreated?(exchange)
        exchangeCreated = nil
        guard terminal == nil else { return }
        exchange.execute()
        pumpBody()
    }

    /// Ends this client with `failure` (cancel, shutdown, unreadable body). A started exchange is
    /// cancelled and reports back through `abort`; otherwise the client ends at once.
    func cancel(_ failure: ComposeFailure) {
        eventLoop.preconditionInEventLoop()
        guard terminal == nil else { return }
        // A complete response already arrived: only the unneeded upload remains, and the send
        // keeps its response.
        if ended, exchange?.disposeUnneededUpload() == true, terminal != nil { return }
        if self.failure == nil { self.failure = failure }
        if let exchange { exchange.cancel(reason: failure.message) }
        if terminal == nil { end(.aborted) }
    }

    // MARK: Timeout

    private func armTimeout(_ deadline: NIODeadline) {
        timeoutDeadline = deadline
        timeoutGeneration &+= 1
        let generation = timeoutGeneration
        timeoutTask = eventLoop.assumeIsolated().scheduleTask(deadline: deadline) { [weak self] in
            guard let self, self.timeoutGeneration == generation, let failure = self.timeoutFailure else { return }
            self.timeoutTask = nil
            self.cancel(failure)
        }
    }

    // MARK: HTTPOutboundEnvironment

    /// Suspends the timeout while any breakpoint ticket of the exchange is held, keeping the time
    /// that was left; resumes it with that time once no ticket is held any more.
    func breakpointPauseChanged(_ paused: Bool) {
        eventLoop.preconditionInEventLoop()
        guard terminal == nil else { return }
        if paused {
            breakpointPauses += 1
            guard breakpointPauses == 1, let deadline = timeoutDeadline else { return }
            timeoutTask?.cancel()
            timeoutTask = nil
            timeoutGeneration &+= 1
            timeoutDeadline = nil
            timeoutRemaining = max(.zero, deadline - .now())
        } else {
            guard breakpointPauses > 0 else { return }
            breakpointPauses -= 1
            guard breakpointPauses == 0, let remaining = timeoutRemaining else { return }
            timeoutRemaining = nil
            armTimeout(.now() + remaining)
        }
    }

    func onClient(_ callback: @escaping (ClientApp) -> Void) {}
    func whenForwardingAllowed(_ callback: @escaping () -> Void) { callback() }

    func register(_ exchange: HTTPExchange, streamID: Int?) -> Bool {
        guard terminal == nil, self.exchange == nil, !didStart else { return false }
        self.exchange = exchange
        return true
    }

    func unregister(_ exchange: HTTPExchange) {
        guard self.exchange === exchange else { return }
        self.exchange = nil
        // A settled exchange always reports finished or abort in the same stack; this only
        // guarantees the client ends even if a future path forgets to.
        eventLoop.assumeIsolated().execute { if self.terminal == nil { self.end(.aborted) } }
    }

    /// The same per-connection quota a client socket has, owned by this send alone.
    func reservePendingBytes(_ count: Int) -> Bool {
        guard count <= limits.pendingBytesPerContext - pendingBytes else { return false }
        pendingBytes += count
        return true
    }

    func releasePendingBytes(_ count: Int) {
        pendingBytes -= count
        assert(pendingBytes >= 0)
    }

    // MARK: DownstreamResponseWriter

    func write(_ part: HTTPServerResponsePart) -> EventLoopFuture<Void> {
        guard terminal == nil else { return eventLoop.makeFailedFuture(HTTPTransportError.closed) }
        switch part {
        case .head(let response):
            // Interim 1xx heads are not the result; 101 is kept so the abort that follows is explained.
            let interim = (100..<200).contains(response.status.code) && response.status != .switchingProtocols
            if !interim, head == nil { head = response }
        case .body(.byteBuffer(let bytes)):
            collect(bytes)
        case .body(.fileRegion(let region)):
            receivedBytes += UInt64(region.readableBytes)
            truncated = true
        case .end(let fields):
            trailers = fields
            ended = true
            // The response is complete: a request body still being submitted goes nowhere now.
            if !bodyEnded {
                eventLoop.assumeIsolated().execute {
                    guard self.terminal == nil else { return }
                    self.exchange?.disposeUnneededUpload()
                }
            }
        }
        return eventLoop.makeSucceededVoidFuture()
    }

    func flush() {}

    func setRequestReading(_ enabled: Bool) {
        let resumed = enabled && !reading
        reading = enabled
        // Never feed the exchange from inside its own call stack.
        if resumed { eventLoop.assumeIsolated().execute { self.pumpBody() } }
    }

    func responseFinished() { end(.finished) }

    func abort(_ error: Error) { end(.aborted) }

    // MARK: Response collection

    private func collect(_ bytes: ByteBuffer) {
        let count = bytes.readableBytes
        receivedBytes += UInt64(count)
        let room = max(0, responseBodyLimit - collected.readableBytes)
        if room > 0, var slice = bytes.getSlice(at: bytes.readerIndex, length: min(room, count)) {
            collected.writeBuffer(&slice)
        }
        if count > room { truncated = true }
    }

    // MARK: Request body

    private func pumpBody() {
        guard !feeding else { return }
        feeding = true
        defer { feeding = false }
        // After a complete response nothing more is read or submitted (the exchange disposes of it).
        while terminal == nil, !ended, let exchange, !bodyEnded, !readInFlight, retry == nil {
            switch body {
            case .none:
                bodyEnded = true
                exchange.receiveRequest(.end(nil))
            case .bytes(let data):
                guard bodyOffset < Int64(data.count) else {
                    bodyEnded = true
                    exchange.receiveRequest(.end(nil))
                    continue
                }
                guard reading else { return }
                let start = data.startIndex + Int(bodyOffset)
                let count = min(65_536, data.endIndex - start)
                bodyOffset += Int64(count)
                exchange.receiveRequest(.body(ByteBuffer(bytes: data[start..<(start + count)])))
            case .file(let lease):
                guard bodyOffset < lease.size else {
                    bodyEnded = true
                    releaseBody()
                    exchange.receiveRequest(.end(nil))
                    continue
                }
                guard reading else { return }
                read(lease)
            }
        }
    }

    /// One bounded read on the lease's own file executor; the result returns to this loop.
    private func read(_ lease: OwnedFileLease) {
        readInFlight = true
        let offset = bodyOffset
        let read = eventLoop.makePromise(of: Data.self)
        read.completeWithTask { try await lease.read(offset: offset, maxBytes: 65_536) }
        read.futureResult.assumeIsolated().whenComplete { result in
            self.readInFlight = false
            guard self.terminal == nil, let exchange = self.exchange else {
                self.releaseBody()
                self.finishIfSettled()
                return
            }
            switch result {
            case .success(let data):
                guard !data.isEmpty, Int64(data.count) <= lease.size - offset else { self.bodyFailed(); return }
                self.capacityDeadline = nil
                self.bodyRead?(data.count)
                self.bodyOffset += Int64(data.count)
                exchange.receiveRequest(.body(ByteBuffer(bytes: data)))
                self.pumpBody()
            case .failure(let error):
                // The shared I/O budget is back-pressure, not a broken asset: retry for a bounded time.
                if (error as? OwnedFileError)?.code == .capacityExceeded {
                    let deadline = self.capacityDeadline ?? (NIODeadline.now() + .seconds(2))
                    self.capacityDeadline = deadline
                    if NIODeadline.now() < deadline {
                        self.retry = self.eventLoop.assumeIsolated().scheduleTask(in: .milliseconds(10)) {
                            self.retry = nil
                            self.pumpBody()
                        }
                        return
                    }
                }
                self.bodyFailed()
            }
        }
    }

    private func bodyFailed() {
        cancel(ComposeFailure(.bodyUnavailable))
    }

    /// Gives a file lease back once no read is in flight (a read in flight releases it when it settles).
    private func releaseBody() {
        guard !readInFlight else { return }
        if case .file(let lease) = body {
            body = .none
            lease.cancel()
            if !bodyReleaseReported {
                bodyReleaseReported = true
                bodyReleased()
            }
        }
    }

    // MARK: Completion

    private func end(_ how: Terminal) {
        guard terminal == nil else { return }
        terminal = how
        reading = false
        retry?.cancel()
        retry = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        timeoutGeneration &+= 1
        timeoutDeadline = nil
        timeoutRemaining = nil
        releaseBody()
        upstreamPool.shutdown(error: nil).assumeIsolated().whenComplete { _ in
            self.poolClosed = true
            self.finishIfSettled()
        }
        finishIfSettled()
    }

    /// Completes once the exchange ended, the private pool closed every socket and no body read
    /// is in flight, so the result is only delivered after every resource was returned.
    private func finishIfSettled() {
        guard let terminal, poolClosed, !readInFlight, !completed else { return }
        completed = true
        let pool = upstreamPool.snapshot
        let completion = OutboundCompletion(result: result(terminal), residualPendingBytes: pendingBytes,
            residualUpstreamSockets: pool.physicalSockets + pool.socketReservations + pool.pending)
        releaseReferences()
        promise.succeed(completion)
    }

    /// The exchange holds this client strongly (as its writer and environment): drop every
    /// reference back to it and every buffer once the result is built, so neither outlives the send.
    private func releaseReferences() {
        started = nil
        exchange = nil
        exchangeCreated = nil
        bodyRead = nil
        // A file lease was given back by `releaseBody()` before completion; never drop one silently.
        if case .file = body { assertionFailure("file body lease still held at completion") }
        body = .none
        head = nil
        trailers = nil
        collected = ByteBuffer()
    }

    private func result(_ terminal: Terminal) -> ComposeResult {
        let flowID = started?.flowID
        let delivery: ComposeDelivery = started?.upstreamFinalHeadReceived == true ? .answered
            : (started?.upstreamRequestSubmitted == true ? .unknown : .notSent)
        // A generated failure page is the proxy's, never a partial response of the origin.
        let localFailure = started?.localFailure
        let partial = localFailure == nil ? delivered(complete: false) : nil
        if let failure { return ComposeResult(flowID: flowID, response: nil, failure: failure, partialResponse: partial, delivery: delivery) }
        if let code = localFailure {
            return ComposeResult(flowID: flowID, response: nil,
                                 failure: ComposeFailure(code: code.rawValue, message: started?.localFailureMessage ?? ""), delivery: delivery)
        }
        guard terminal == .finished, ended, let response = delivered(complete: true) else {
            return ComposeResult(flowID: flowID, response: nil, failure: ComposeFailure(.responseIncomplete),
                                 partialResponse: partial, delivery: delivery)
        }
        return ComposeResult(flowID: flowID, response: response, failure: nil, delivery: delivery)
    }

    /// The delivered final head and the body collected so far; nil without one (or for a 101).
    /// The body is de-framed, so Transfer-Encoding is not listed.
    private func delivered(complete: Bool) -> ComposeResponse? {
        guard let head, head.status != .switchingProtocols else { return nil }
        return ComposeResponse(
            status: Int(head.status.code), reason: head.status.reasonPhrase,
            headers: head.headers.fields.filter { $0.name.lowercased() != "transfer-encoding" },
            body: Data(collected.readableBytesView), bodyBytes: receivedBytes, truncated: truncated,
            trailers: complete ? trailers?.fields ?? [] : [])
    }
}
