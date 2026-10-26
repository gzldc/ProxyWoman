import FlowStore
import Foundation
import Localization
import NIOCore
import NIOHTTP1
import os
import RulesEngine

/// Which HTTP version a Compose send may use upstream.
public enum ComposeHTTPVersion: Sendable, Equatable {
    /// h2 or http/1.1, as the origin's ALPN selects (plain `http` is always HTTP/1.1).
    case automatic
    /// Only http/1.1 is offered, on a connection never shared with automatic sends.
    case http1Only
}

/// The options of one Compose send.
public struct ComposePolicy: Sendable, Equatable {
    /// The accepted `timeout` values, inclusive.
    public static let timeoutRange: ClosedRange<Duration> = .seconds(1) ... .seconds(600)

    /// Whether the published rules (headers, Map Local/Remote, breakpoints) apply to this send.
    /// Off unless the user explicitly switches them on (design RC-09).
    public var applyRules: Bool
    /// The whole send, from the moment it gets a send slot (not while it waits in the queue) until
    /// its response ended; it does not run while the send is paused at a breakpoint, whose ticket
    /// has its own deadline. Outside `timeoutRange` the request is invalid.
    public var timeout: Duration
    public var httpVersion: ComposeHTTPVersion

    public init(applyRules: Bool = false, timeout: Duration = .seconds(60), httpVersion: ComposeHTTPVersion = .automatic) {
        self.applyRules = applyRules
        self.timeout = timeout
        self.httpVersion = httpVersion
    }
}

/// One explicit request the user sends from Compose.
public struct ComposeRequest: Sendable {
    /// Identifies the send: `cancel(_:)`, the flow's provenance and any breakpoint ticket context.
    public var id: UUID
    public var method: String
    /// `http` or `https`; userinfo is refused and a fragment is not sent.
    public var url: URL
    /// Sent in this order, duplicates included. Content-Length/Transfer-Encoding are the
    /// transport's: the exact length of `body` replaces a declared one in place.
    public var headers: [HeaderField]
    public var body: ComposeBody
    /// The captured flow this request was made from, if any (provenance only).
    public var sourceFlowID: Int?
    public var policy: ComposePolicy
    /// Marks the send as one of a repeat run; recorded in the flow's provenance.
    public var repeatTag: RepeatRunTag?

    public init(id: UUID = UUID(), method: String, url: URL, headers: [HeaderField] = [], body: ComposeBody = .none,
                sourceFlowID: Int? = nil, policy: ComposePolicy = ComposePolicy(), repeatTag: RepeatRunTag? = nil) {
        self.id = id
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.sourceFlowID = sourceFlowID
        self.policy = policy
        self.repeatTag = repeatTag
    }
}

public enum ComposeBody: Sendable, Equatable {
    case none
    case bytes(Data)
    /// A managed asset of the server's `ManagedAssetStore`, streamed from its owned copy.
    case asset(UUID)
}

/// The response delivered to the send. The body is held up to the service's in-memory limit and
/// counted beyond it (`truncated`); the recorded flow keeps the capture under its own limits.
/// `headers` describe the de-framed `body`: Transfer-Encoding is never listed (the flow's
/// `upstreamResponse` keeps the origin's exact head).
public struct ComposeResponse: Sendable, Equatable {
    public let status: Int
    public let reason: String
    public let headers: [HeaderField]
    public let body: Data
    /// Every body byte received, kept or not.
    public let bodyBytes: UInt64
    public let truncated: Bool
    public let trailers: [HeaderField]
}

/// Stable machine codes of failures that belong to Compose itself. Transport and rule failures
/// keep the proxy's own local failure codes (`upstream.unreachable`, `rule.selfTarget`, …).
public enum ComposeFailureCode: String, Sendable, CaseIterable {
    /// Every send slot and queue position is taken.
    case busy = "compose.busy"
    /// The server stopped while the send was queued or running.
    case shutdown = "compose.shutdown"
    case cancelled = "compose.cancelled"
    /// Not a sendable request; the localized message carries the validator's machine code.
    case invalidRequest = "compose.invalidRequest"
    /// The asset body could not be opened or read.
    case bodyUnavailable = "compose.bodyUnavailable"
    /// The exchange ended before a complete final response was delivered.
    case responseIncomplete = "compose.responseIncomplete"
    /// The send did not finish within its policy's timeout and was cancelled.
    case timeout = "compose.timeout"
}

/// What the origin can have seen of a send, independent of whether it succeeded.
public enum ComposeDelivery: Sendable, Equatable {
    /// No upstream writer accepted the request head: the origin cannot have received it.
    case notSent
    /// An upstream writer accepted the request head, but no final response head came back:
    /// whether the origin processed the request is unknown.
    case unknown
    /// The origin answered with a final response head (the request reached it).
    case answered
}

public struct ComposeFailure: Error, Sendable, Equatable {
    /// A `ComposeFailureCode` or a proxy local failure code; never free text.
    public let code: String
    /// Localized, complete sentence for display.
    public let message: String
    /// A stable machine code refining `code`, when there is one: for `compose.invalidRequest` the
    /// validator's code (`invalidMethod`, `timeoutOutOfRange`, …), never free text.
    public let detail: String?

    public init(code: String, message: String, detail: String? = nil) {
        self.code = code
        self.message = message
        self.detail = detail
    }

    /// `argument` fills the localized sentence; `detail` is the machine detail.
    init(_ code: ComposeFailureCode, argument: String? = nil, detail: String? = nil) {
        self.init(code: code.rawValue, message: ComposeFailureText.message(code, detail: argument), detail: detail)
    }

    static func invalid(_ detail: String) -> ComposeFailure {
        ComposeFailure(.invalidRequest, argument: detail, detail: detail)
    }
}

/// Exactly one of `response` and `failure` is set. `flowID` is the recorded flow, if the send got
/// that far (requests rejected before execution have none). A failure after a final response
/// head was delivered keeps what had arrived in `partialResponse`; `delivery` says what the
/// origin can have seen.
public struct ComposeResult: Sendable {
    public let flowID: Int?
    public let response: ComposeResponse?
    public let failure: ComposeFailure?
    /// Only with `failure`: the delivered head and the body received before the send ended.
    public let partialResponse: ComposeResponse?
    public let delivery: ComposeDelivery

    init(flowID: Int?, response: ComposeResponse?, failure: ComposeFailure?, partialResponse: ComposeResponse? = nil,
         delivery: ComposeDelivery = .notSent) {
        self.flowID = flowID
        self.response = response
        self.failure = failure
        self.partialResponse = failure == nil ? nil : partialResponse
        self.delivery = delivery
    }
}

/// What the service holds right now. Residual fields sum what ended sends still held when they
/// completed; they stay zero unless a path leaks.
public struct ComposeResources: Sendable, Equatable {
    public var active = 0
    public var queued = 0
    public var bodyLeases = 0
    public var residualPendingBytes = 0
    public var residualUpstreamSockets = 0

    public init() {}
}

enum ComposeFailureText {
    static func message(_ code: ComposeFailureCode, detail: String? = nil, localizer: Localizer = L10n.localizer) -> String {
        switch code {
        case .invalidRequest: localizer.format("compose.failure.invalidRequest", arguments: [detail ?? ""])
        case .busy: localizer.string("compose.failure.busy")
        case .shutdown: localizer.string("compose.failure.shutdown")
        case .cancelled: localizer.string("compose.failure.cancelled")
        case .bodyUnavailable: localizer.string("compose.failure.bodyUnavailable")
        case .responseIncomplete: localizer.string("compose.failure.responseIncomplete")
        case .timeout:
            // The seconds text comes first; the second argument only picks "second" or "seconds" (1 is singular).
            localizer.format("compose.failure.timeout", arguments: [detail ?? "", detail == "1" ? 1 : 2])
        }
    }

    /// Seconds as the timeout sentence shows them: whole seconds plainly, otherwise with decimals.
    static func seconds(_ duration: Duration) -> String {
        let (seconds, attoseconds) = duration.components
        guard attoseconds != 0 else { return String(seconds) }
        var text = String(format: "%.3f", Double(seconds) + Double(attoseconds) / 1e18)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// The reason inside the proxy's service-unavailable sentence.
    static func notRunning(localizer: Localizer = L10n.localizer) -> String {
        localizer.string("compose.notRunning")
    }
}

/// Sends explicit requests through this server's own upstream path: the real pool, connector,
/// upstream proxy settings and TLS verification, the published rules (only when a request opts in
/// with `ComposePolicy.applyRules`) and the recorder. Owned by
/// `ProxyServer`, which lends it a run's event loops and stops it after its client connections
/// drained (C6).
///
/// At most `concurrentSends` run at once; up to `queuedSends` more wait in order and anything
/// beyond fails at once with `compose.busy`. A send is never retried and a redirect is returned as
/// is. Its flow is recorded even while recording is paused, with Compose provenance. A target that
/// is one of this proxy's listener endpoints fails with `rule.selfTarget`.
public final class ComposeService: Sendable {
    struct Limits: Sendable, Equatable {
        var concurrentSends: Int
        var queuedSends: Int
        /// The in-memory response body of one send (the editor's 8 MiB).
        var responseBodyBytes: Int
        var requestBodyBytes: Int

        init(concurrentSends: Int = 10, queuedSends: Int = 16, responseBodyBytes: Int = 8_388_608,
             requestBodyBytes: Int = 536_870_912) {
            self.concurrentSends = max(1, concurrentSends)
            self.queuedSends = max(0, queuedSends)
            self.responseBodyBytes = max(0, responseBodyBytes)
            self.requestBodyBytes = max(0, requestBodyBytes)
        }

        init(_ limits: RulesLimits) {
            self.init(concurrentSends: limits.composeSends, responseBodyBytes: limits.editorBodyBytes,
                      requestBodyBytes: limits.composeBodyBytes)
        }
    }

    /// What one server run lends: its loops, and its environment read afresh for each send.
    struct Runtime: Sendable {
        let loops: EventLoopGroup
        let environment: @Sendable () -> ProxyEnvironment
    }

    /// A validated request, before its body length is known.
    private struct Prepared: Sendable {
        let request: ComposeRequest
        let scheme: String
        let target: RequestTarget
        let method: String
        let headers: [HeaderField]
        /// Fresh for every `send` call.
        let admission = UUID()
    }

    private struct Active {
        /// The one `send` call that owns this entry (a reused id from another call never matches).
        let admission: UUID
        let continuation: CheckedContinuation<ComposeResult, Never>
        var stop: ComposeFailureCode?
        var context: NIOLoopBound<OutboundExecutionContext>?
    }

    private struct Queued {
        let prepared: Prepared
        let continuation: CheckedContinuation<ComposeResult, Never>
    }

    private struct State {
        var accepting = false
        var runtime: Runtime?
        var active: [UUID: Active] = [:]
        var queue: [Queued] = []
        var drained: [CheckedContinuation<Void, Never>] = []
        var resources = ComposeResources()
    }

    private let limits: Limits
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let lifetimes: ComposeLifetimeProbe?

    init(limits: Limits, lifetimes: ComposeLifetimeProbe? = nil) {
        self.limits = limits
        self.lifetimes = lifetimes
    }

    /// Sends `request` and returns once it ended and everything it held was returned. Cancelling
    /// the calling task cancels the send.
    public func send(_ request: ComposeRequest) async -> ComposeResult {
        let prepared: Prepared
        do { prepared = try prepare(request) } catch {
            return ComposeResult(flowID: nil, response: nil, failure: .invalid(Self.detail(error)))
        }
        // The caller's task cancels only what this call admitted, never a send another call owns.
        let admission = prepared.admission
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in admit(prepared, continuation) }
        } onCancel: {
            cancel(request.id, admission: admission)
        }
    }

    /// A queued send is removed without any connection; a running one is cancelled at whatever
    /// stage it is (connecting, awaiting or receiving the response, paused at a breakpoint) and
    /// reports `compose.cancelled`, keeping a response head it already delivered. True when a
    /// queued or running send with `id` was found; a send that already ended keeps its result and
    /// this is a no-op (false). A send whose complete response already arrived is not undone.
    @discardableResult
    public func cancel(_ id: UUID) -> Bool {
        cancel(id, admission: nil)
    }

    /// `admission` nil matches whichever call owns `id`.
    @discardableResult
    private func cancel(_ id: UUID, admission: UUID?) -> Bool {
        let action = state.withLock { state -> (Bool, CheckedContinuation<ComposeResult, Never>?, NIOLoopBound<OutboundExecutionContext>?) in
            if let index = state.queue.firstIndex(where: {
                $0.prepared.request.id == id && (admission == nil || $0.prepared.admission == admission)
            }) {
                let queued = state.queue.remove(at: index)
                state.resources.queued = state.queue.count
                return (true, queued.continuation, nil)
            }
            guard let entry = state.active[id], admission == nil || entry.admission == admission else { return (false, nil, nil) }
            if state.active[id]?.stop == nil { state.active[id]?.stop = .cancelled }
            return (true, nil, state.active[id]?.context)
        }
        action.1?.resume(returning: Self.failed(.cancelled))
        if let context = action.2 { stop(context, .cancelled) }
        return action.0
    }

    public var resources: ComposeResources {
        state.withLock { $0.resources }
    }

    // MARK: Server lifecycle

    func beginRun(_ runtime: Runtime) {
        state.withLock { state in
            state.runtime = runtime
            state.accepting = true
        }
    }

    /// The server is stopping: new sends are refused; queued ones wait for `shutdown()`.
    func stopAdmission() {
        state.withLock { $0.accepting = false }
    }

    /// Fails every queued send and cancels every running one with `compose.shutdown`, then waits
    /// until each of them ended and returned its pool sockets, pending bytes and file leases.
    func shutdown() async {
        let (queued, running) = state.withLock { state in
            state.accepting = false
            state.runtime = nil
            let queued = state.queue
            state.queue.removeAll()
            state.resources.queued = 0
            for id in state.active.keys where state.active[id]?.stop == nil { state.active[id]?.stop = .shutdown }
            return (queued, state.active.values.compactMap { entry in entry.stop == .shutdown ? entry.context : nil })
        }
        for entry in queued { entry.continuation.resume(returning: Self.failed(.shutdown)) }
        for context in running { stop(context, .shutdown) }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let idle = state.withLock { state in
                if state.active.isEmpty { return true }
                state.drained.append(continuation)
                return false
            }
            if idle { continuation.resume() }
        }
    }

    // MARK: Admission

    private func admit(_ prepared: Prepared, _ continuation: CheckedContinuation<ComposeResult, Never>) {
        let id = prepared.request.id
        enum Decision { case start(Runtime), wait, reject(ComposeResult) }
        // Under the lock, so a cancellation of the calling task either is seen here or finds the entry.
        let decision = state.withLock { state -> Decision in
            if Task.isCancelled { return .reject(Self.failed(.cancelled)) }
            guard state.accepting, let runtime = state.runtime else { return .reject(Self.notRunning()) }
            guard state.active[id] == nil, !state.queue.contains(where: { $0.prepared.request.id == id }) else {
                return .reject(ComposeResult(flowID: nil, response: nil, failure: .invalid("duplicateSend")))
            }
            if state.active.count < limits.concurrentSends {
                state.active[id] = Active(admission: prepared.admission, continuation: continuation)
                state.resources.active = state.active.count
                return .start(runtime)
            }
            guard state.queue.count < limits.queuedSends else { return .reject(Self.failed(.busy)) }
            state.queue.append(Queued(prepared: prepared, continuation: continuation))
            state.resources.queued = state.queue.count
            return .wait
        }
        switch decision {
        case .start(let runtime): start(prepared, runtime)
        case .wait: break
        case .reject(let result): continuation.resume(returning: result)
        }
    }

    /// The send got its slot: its timeout starts now (never while it waited in the queue).
    private func start(_ prepared: Prepared, _ runtime: Runtime) {
        let loop = runtime.loops.next()
        let environment = runtime.environment()
        let deadline = NIODeadline.now() + Self.timeAmount(prepared.request.policy.timeout)
        guard case .asset(let assetID) = prepared.request.body else {
            loop.execute { self.launch(prepared, lease: nil, loop: loop, environment: environment, deadline: deadline) }
            return
        }
        Task {
            guard let assets = environment.assets, let lease = try? await assets.lease(assetID) else {
                self.complete(prepared.request.id, OutboundCompletion(result: Self.failed(.bodyUnavailable),
                                                                      residualPendingBytes: 0, residualUpstreamSockets: 0))
                return
            }
            self.state.withLock { $0.resources.bodyLeases += 1 }
            guard lease.size <= Int64(self.limits.requestBodyBytes) else {
                lease.cancel()
                self.bodyLeaseReleased()
                self.complete(prepared.request.id, OutboundCompletion(
                    result: ComposeResult(flowID: nil, response: nil, failure: .invalid("bodyTooLarge")),
                    residualPendingBytes: 0, residualUpstreamSockets: 0))
                return
            }
            loop.execute { self.launch(prepared, lease: lease, loop: loop, environment: environment, deadline: deadline) }
        }
    }

    /// On `loop`: creates the virtual client, then either starts its exchange or, if the send was
    /// stopped meanwhile, ends it without any request.
    private func launch(_ prepared: Prepared, lease: OwnedFileLease?, loop: EventLoop, environment: ProxyEnvironment,
                        deadline: NIODeadline) {
        let id = prepared.request.id
        let body: OutboundRequestBody
        let length: Int64
        switch prepared.request.body {
        case .none: body = .none; length = 0
        case .bytes(let data): body = .bytes(data); length = Int64(data.count)
        case .asset:
            guard let lease else { preconditionFailure("asset body without lease") }
            body = .file(lease); length = lease.size
        }
        let context = OutboundExecutionContext(contextID: id, eventLoop: loop, environment: environment,
            responseBodyLimit: limits.responseBodyBytes, body: body,
            bodyReleased: { [weak self] in self?.bodyLeaseReleased() })
        context.completion.assumeIsolated().whenSuccess { completion in self.complete(id, completion) }
        if let lifetimes {
            lifetimes.track(id, context: context)
            context.exchangeCreated = { lifetimes.track(id, exchange: $0) }
            context.bodyRead = { lifetimes.track(id, bodyBytesRead: $0) }
        }
        let bound = NIOLoopBound(context, eventLoop: loop)
        let stopped = state.withLock { state -> ComposeFailureCode? in
            guard state.active[id] != nil else { return .cancelled }
            if let stop = state.active[id]?.stop { return stop }
            state.active[id]?.context = bound
            return nil
        }
        if let stopped {
            context.cancel(ComposeFailure(stopped))
            return
        }
        let head = HTTPRequestHead(version: .http1_1, method: HTTPMethod(rawValue: prepared.method),
                                   uri: prepared.target.originForm, headers: HTTPHeaders(fields: Self.framed(prepared.headers, length: length)))
        let request = prepared.request
        let policy = request.policy
        context.start(head: head, target: prepared.target, scheme: prepared.scheme,
            policy: HTTPExecutionPolicy(rulesEnabled: policy.applyRules, retry: .never, rejectsListener: true,
                                        recordsWhilePaused: true, virtualClient: true, http1Only: policy.httpVersion == .http1Only),
            provenance: FlowProvenance(source: .compose(sendID: request.id, sourceFlowID: request.sourceFlowID, sourceBoundary: nil),
                                       rulesDisabled: !policy.applyRules, tools: TrafficToolsProvenance(repeatRun: request.repeatTag)),
            deadline: deadline, timeoutFailure: ComposeFailure(.timeout, argument: ComposeFailureText.seconds(policy.timeout)))
    }

    static func timeAmount(_ duration: Duration) -> TimeAmount {
        let (seconds, attoseconds) = duration.components
        return .nanoseconds(seconds * 1_000_000_000 + attoseconds / 1_000_000_000)
    }

    private func stop(_ context: NIOLoopBound<OutboundExecutionContext>, _ code: ComposeFailureCode) {
        context.eventLoop.execute { context.value.cancel(ComposeFailure(code)) }
    }

    private func bodyLeaseReleased() {
        state.withLock { $0.resources.bodyLeases -= 1 }
    }

    /// Ends an active send, then starts queued sends into the freed slots (never while stopping).
    private func complete(_ id: UUID, _ completion: OutboundCompletion) {
        let (continuation, next, runtime, drained, stopping) = state.withLock { state in
            let entry = state.active.removeValue(forKey: id)
            let stopping = entry != nil && !state.accepting
            state.resources.residualPendingBytes += completion.residualPendingBytes
            state.resources.residualUpstreamSockets += completion.residualUpstreamSockets
            var next: [Prepared] = []
            if state.accepting, state.runtime != nil {
                while state.active.count < limits.concurrentSends, !state.queue.isEmpty {
                    let queued = state.queue.removeFirst()
                    state.active[queued.prepared.request.id] = Active(admission: queued.prepared.admission, continuation: queued.continuation)
                    next.append(queued.prepared)
                }
            }
            state.resources.active = state.active.count
            state.resources.queued = state.queue.count
            var drained: [CheckedContinuation<Void, Never>] = []
            if state.active.isEmpty { swap(&drained, &state.drained) }
            return (entry?.continuation, next, state.runtime, drained, stopping)
        }
        continuation?.resume(returning: stopping ? Self.attributedToStop(completion.result) : completion.result)
        if let runtime { for prepared in next { start(prepared, runtime) } }
        drained.forEach { $0.resume() }
    }

    // MARK: Validation

    private func prepare(_ request: ComposeRequest) throws -> Prepared {
        guard let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw HTTPMutationError(code: .invalidScheme, field: .scheme)
        }
        if components.user != nil || components.password != nil {
            throw HTTPMutationError(code: .userinfoNotAllowed, field: .host)
        }
        var host = Substring(components.percentEncodedHost ?? "")
        if host.hasPrefix("["), host.hasSuffix("]") { host = host.dropFirst().dropLast() }
        let defaultPort = scheme == "https" ? 443 : 80
        let port = components.port ?? defaultPort
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        let pathAndQuery = path + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
        // Framing belongs to the transport; everything else is validated as written.
        let headers = request.headers.filter { !Self.framingNames.contains($0.name.lowercased()) }
        let length: Int64?
        switch request.body {
        case .none: length = 0
        case .bytes(let data): length = Int64(data.count)
        case .asset: length = nil
        }
        try HTTPMutationValidator.validate(
            head: .request(HTTPMessageTarget(scheme: scheme, host: String(host), port: port, method: request.method,
                                             pathAndQuery: pathAndQuery), headers: headers),
            body: HTTPBodyDescriptor(length: length, complete: true, changed: false))
        if HTTPMutationValidator.isUpgradeCandidate(request.headers) { throw ComposeValidationError("upgradeNotSupported") }
        if !ComposePolicy.timeoutRange.contains(request.policy.timeout) { throw ComposeValidationError("timeoutOutOfRange") }
        if let length, length > Int64(limits.requestBodyBytes) { throw ComposeValidationError("bodyTooLarge") }
        return Prepared(request: request, scheme: scheme,
                        target: RequestTarget(host: String(host), port: port, originForm: pathAndQuery, defaultPort: defaultPort),
                        method: request.method, headers: request.headers)
    }

    private static let framingNames: Set<String> = ["content-length", "transfer-encoding"]

    /// The exact body length replaces the first declared Content-Length in place (later ones and
    /// Transfer-Encoding are dropped); a body nobody declared gets one appended.
    static func framed(_ headers: [HeaderField], length: Int64) -> [HeaderField] {
        var result: [HeaderField] = []
        var declared = false
        for field in headers {
            switch field.name.lowercased() {
            case "transfer-encoding": continue
            case "content-length":
                if !declared { result.append(HeaderField(name: field.name, value: String(length))) }
                declared = true
            default: result.append(field)
            }
        }
        if !declared, length > 0 { result.append(HeaderField(name: "Content-Length", value: String(length))) }
        return result
    }

    private static func detail(_ error: Error) -> String {
        if let mutation = error as? HTTPMutationError { return mutation.code.rawValue }
        if let validation = error as? ComposeValidationError { return validation.code }
        return "invalidRequest"
    }

    /// A stopping server revokes paused breakpoint tickets before its bounded drain (design §11),
    /// ahead of cancelling Compose sends (C6). A send paused at its breakpoint then ended because
    /// of the stop, so it reports `compose.shutdown` like every other send the stop ended.
    private static func attributedToStop(_ result: ComposeResult) -> ComposeResult {
        guard result.failure?.code == HTTPLocalFailureCode.breakpointCancelled.rawValue else { return result }
        return ComposeResult(flowID: result.flowID, response: nil, failure: ComposeFailure(.shutdown),
                             partialResponse: result.partialResponse, delivery: result.delivery)
    }

    private static func failed(_ code: ComposeFailureCode) -> ComposeResult {
        ComposeResult(flowID: nil, response: nil, failure: ComposeFailure(code))
    }

    private static func notRunning() -> ComposeResult {
        ComposeResult(flowID: nil, response: nil, failure: ComposeFailure(
            code: HTTPLocalFailureCode.serviceUnavailable.rawValue,
            message: HTTPLocalFailureText.serviceUnavailable(reason: ComposeFailureText.notRunning())))
    }
}

/// A Compose-only rejection; `code` is a stable machine code shown inside the localized message.
private struct ComposeValidationError: Error {
    let code: String
    init(_ code: String) { self.code = code }
}

/// Test observation of Compose object lifetimes. It holds weak references only, so it never keeps
/// a context or exchange alive. `@unchecked Sendable`: every access goes through `lock`, and the
/// weak references are only compared with nil, never dereferenced off their event loop.
final class ComposeLifetimeProbe: @unchecked Sendable {
    private final class Weak {
        weak var context: AnyObject?
        weak var exchange: AnyObject?
        var sawExchange = false
        var bodyBytesRead = 0
    }

    private let lock = NSLock()
    private var entries: [UUID: Weak] = [:]

    func track(_ id: UUID, context: AnyObject) {
        lock.withLock { entry(id).context = context }
    }

    func track(_ id: UUID, exchange: AnyObject) {
        lock.withLock {
            entry(id).exchange = exchange
            entry(id).sawExchange = true
        }
    }

    func track(_ id: UUID, bodyBytesRead count: Int) {
        lock.withLock { entry(id).bodyBytesRead += count }
    }

    /// The request body bytes the send read from its asset file.
    func bodyBytesRead(_ id: UUID) -> Int {
        lock.withLock { entries[id]?.bodyBytesRead ?? 0 }
    }

    /// Whether the send's context, and its exchange if one was created, are still allocated.
    func alive(_ id: UUID) -> (tracked: Bool, context: Bool, exchangeCreated: Bool, exchange: Bool) {
        lock.withLock {
            guard let entry = entries[id] else { return (false, false, false, false) }
            return (true, entry.context != nil, entry.sawExchange, entry.exchange != nil)
        }
    }

    private func entry(_ id: UUID) -> Weak {
        if let entry = entries[id] { return entry }
        let entry = Weak()
        entries[id] = entry
        return entry
    }
}
