import FlowStore
import Foundation
import NIOCore
import NIOHTTP1
import RulesEngine

/// Writes one exchange into the `FlowStore`, converting NIO types (`HTTPHeaders`, `ByteBuffer`)
/// into FlowStore's, so FlowStore itself stays free of NIO.
///
/// Besides the legacy request*/response* projection, every message boundary the exchange really
/// crosses is recorded as an `HTTPMessageSnapshot`. A body entity is captured once per stream;
/// boundaries mirror counted offsets of that stream. A written boundary (`upstreamRequest`,
/// `downstreamResponse`) begins only when its writer accepted the head, and its body range grows
/// only with writes that were accepted, so a head that was merely prepared is never recorded as sent.
/// Events for the write boundaries and late request/response completion are accepted after the
/// flow finished (an early response can finish a flow before the upload, or its last write, settles).
///
/// Confined to the event loop of the connection that owns it (BodyCapture is single-threaded).
/// While bodies stream, byte counts are published at most every `publishInterval`, so a long
/// transfer does not show 0 bytes until it ends.
/// What the recorder knows when the flow finishes, for the rules judged at completion.
struct FlowCompletionInput {
    var state: CompletionFacts.SessionState
    var durationMilliseconds: Int
    /// The response bytes that came over the wire; nil for a local response or no response head.
    var responseWireBytes: Int?
}

/// What those rules did: applied in the same store update as the final state.
struct FlowCompletionOutput {
    var annotations: [FlowAnnotation]
    var provenance: FlowProvenance?
}

final class FlowRecorder {
    static let publishInterval: TimeAmount = .milliseconds(250)

    let id: Int
    /// The entity the client sends (request) and the origin sends (response).
    let requestStream: UUID
    let responseStream: UUID
    /// Where the client side of this flow is recorded: the downstream wire boundaries, or the
    /// Compose virtual client's `composeSubmitted` / `composeDelivered`.
    let clientRequestBoundary: HTTPMessageBoundary
    let clientResponseBoundary: HTTPMessageBoundary
    private let store: FlowStore
    private let eventLoop: EventLoop
    private let scheme: String
    private let host: String
    private let port: Int
    private let transport: HTTPTransportMetadata
    private var streams: [UUID: RecordedBodyStream] = [:]
    private var boundaries: [HTTPMessageBoundary: MessageBoundaryState] = [:]
    private var dirty: Set<HTTPMessageBoundary> = []
    /// Legacy transport mirrors queued by `startBoundary`, applied by the next `commit`.
    private var pendingLegacy: [(inout Flow) -> Void] = []
    private var provenance = FlowProvenance.passive
    private let startedAt: Date
    /// Runs once, on the event loop, as the flow finishes (before its final update).
    var completionHook: ((FlowCompletionInput) -> FlowCompletionOutput)?
    /// Where the upstream request boundary is addressed; a Map Remote rule changes it.
    private var upstreamOrigin: (scheme: String, host: String, port: Int)
    private var bytesSent = 0
    private var bytesReceived = 0
    /// A rule judged at the response answered in place of the origin: the flow's response fields show that answer.
    private var originDiscarded = false
    private var generatedBodyStream: UUID?
    private var publishTask: Scheduled<Void>?
    /// Set once the flow reached `.completed` or `.failed`; later events are ignored.
    private(set) var isFinished = false

    init(
        store: FlowStore, scheme: String, method: String, host: String, port: Int, path: String,
        requestHeaders: HTTPHeaders, client: ClientApp?, eventLoop: EventLoop,
        transport: HTTPTransportMetadata = .init(), virtualClient: Bool = false, holdPublication: Bool = false
    ) {
        let started = Date.now
        self.startedAt = started
        let clientRequest: HTTPMessageBoundary = virtualClient ? .composeSubmitted : .downstreamRequest
        self.clientRequestBoundary = clientRequest
        self.clientResponseBoundary = virtualClient ? .composeDelivered : .downstreamResponse
        let headers = Self.headerFields(requestHeaders)
        let host = Self.flowHost(host)
        let requestStream = UUID()
        let original = MessageBoundaryState(
            head: .request(
                HTTPMessageTarget(scheme: scheme, host: host, port: port, method: method, pathAndQuery: path),
                headers: headers),
            version: transport.downstreamRequest, streamID: transport.downstreamStreamID,
            stream: requestStream, transfer: .observed)
        let snapshot = original.snapshot(clientRequest, streams: [:])
        self.store = store
        self.eventLoop = eventLoop
        self.scheme = scheme
        self.host = host
        self.port = port
        self.transport = transport
        self.upstreamOrigin = (scheme, host, port)
        self.requestStream = requestStream
        self.responseStream = UUID()
        self.id = store.begin(deferringPublication: holdPublication) { id in
            var flow = Flow(
                id: id, scheme: scheme, method: method, host: host, port: port, path: path,
                requestHeaders: headers)
            flow.startedAt = started
            flow.client = client
            flow.transport = transport
            flow.provenance = .passive
            flow.messages[clientRequest] = snapshot
            return flow
        }
        boundaries[clientRequest] = original
        streams[requestStream] = RecordedBodyStream(capture: store.makeBodyCapture())
        streams[responseStream] = RecordedBodyStream(capture: store.makeBodyCapture())
    }

    /// Writes what rules did to the record, in the order they ran, in one update: a mark replaces the
    /// rule mark, a comment action edits the current comment, hide hides the flow. The user's own mark
    /// and comment fields are only read (the comment) or left alone (the manual mark).
    func apply(_ annotations: [FlowAnnotation]) {
        guard !annotations.isEmpty else { return }
        store.update(id) { Self.apply(annotations, to: &$0) }
    }

    fileprivate static func apply(_ annotations: [FlowAnnotation], to flow: inout Flow) {
        for annotation in annotations {
            switch annotation {
            case .mark(let mark): flow.ruleMark = mark
            case .resetMark(let background, let foreground):
                flow.ruleMark = FlowMark.reset(flow.ruleMark, background: background, foreground: foreground)
            case .comment(let action): flow.comment = action.applying(to: flow.comment)
            case .hide: flow.isHidden = true
            }
        }
    }

    /// Applies request-side actions of a rule judged at the response to the recorded request: the legacy
    /// projection the session list and inspector show. The `downstreamRequest` boundary keeps what the client
    /// sent and `upstreamRequest` what was written upstream, so the origin's request is never touched and
    /// Execute still reads the original.
    func applyRecordedRequestActions(
        _ actions: [RecordedRequestAction], allowance: RegexAllowance, cache: PatternCache, limits: RulesLimits
    ) {
        guard !actions.isEmpty else { return }
        store.update(id) { flow in
            let target = HTTPMessageTarget(
                scheme: flow.scheme, host: flow.host, port: flow.port, method: flow.method, pathAndQuery: flow.path)
            let edited = RecordedRequestEditing.apply(
                actions, to: .request(target, headers: flow.requestHeaders), allowance: allowance, cache: cache,
                limits: limits)
            guard case .request(let target, let headers) = edited else { return }
            flow.scheme = target.scheme
            flow.host = target.host
            flow.port = target.port
            flow.method = target.method
            flow.path = target.pathAndQuery
            flow.requestHeaders = headers
        }
    }

    /// Lets a flow created with `holdPublication` reach subscribers. Idempotent.
    func releasePublication() {
        store.publish(id)
    }

    func setClient(_ client: ClientApp) {
        commit { $0.client = client }
    }

    /// Marks the flow as held at (or released from) a breakpoint; the store publishes the change so a live
    /// count refreshes. Only called by exchanges that use a breakpoint, so other flows never see it.
    func setPausedAtBreakpoint(_ paused: Bool) {
        commit { $0.isPausedAtBreakpoint = paused }
    }

    /// The flow's comment right now (the user's, or one a rule already wrote).
    var comment: String? { store.flow(id)?.comment }

    /// Records addresses, TLS versions and the origin's certificate in one update; fields that are nil
    /// are left as they were.
    func setConnectionInfo(_ info: FlowConnectionInfo) {
        guard !info.isEmpty else { return }
        commit { flow in
            if let clientIP = info.clientIP { flow.clientIP = clientIP }
            if let remoteIP = info.remoteIP { flow.remoteIP = remoteIP }
            if let version = info.downstreamTLSVersion { flow.transport.downstreamTLSVersion = version }
            if let version = info.upstreamTLSVersion { flow.transport.upstreamTLSVersion = version }
            if let certificate = info.upstreamCertificate { flow.upstreamCertificate = certificate }
        }
    }

    // MARK: Message boundaries

    /// A new message boundary begins. For written boundaries call this only after the writer
    /// accepted the head (or pass `transfer: .partiallySent` when the head write failed). A
    /// second call for the same boundary starts it over (a replayed request attempt).
    func beginMessage(
        _ head: HTTPMessageHead, boundary: HTTPMessageBoundary, version: HTTPWireVersion?, streamID: Int?,
        transfer: HTTPTransferState? = nil
    ) {
        startBoundary(head, boundary: boundary, version: version, streamID: streamID, transfer: transfer)
        commit()
    }

    func makeBodyStream() -> UUID {
        let id = UUID()
        streams[id] = RecordedBodyStream(capture: store.makeBodyCapture())
        return id
    }

    /// Captures source bytes once. Which boundaries carried them is told by `observeBody`.
    func captureBody(stream: UUID, bytes: ByteBuffer) {
        streams[stream]?.capture?.append(bytes.readableBytesView)
    }

    /// `byteCount` more bytes of `stream`, counted from the start, passed `boundary`.
    func observeBody(boundary: HTTPMessageBoundary, stream: UUID, byteCount: Int) {
        guard byteCount > 0, var state = boundaries[boundary], !state.finished else { return }
        if state.stream != stream {
            state.stream = stream
            state.accepted = 0
        }
        state.accepted += UInt64(byteCount)
        boundaries[boundary] = state
        dirty.insert(boundary)
        schedulePublish()
    }

    /// The boundary's message ended: `complete` is false when the transfer stopped early.
    func finishMessage(boundary: HTTPMessageBoundary, trailers: [HeaderField], complete: Bool) {
        guard endBoundary(boundary, trailers: trailers, complete: complete) else { return }
        commit()
    }

    /// The request is sent to another origin than the client addressed (the flow keeps the original).
    func setUpstreamOrigin(scheme: String, host: String, port: Int) {
        upstreamOrigin = (scheme, Self.flowHost(host), port)
    }

    /// The generated-response source belongs to this recorder (`beginGeneratedResponse`); callers
    /// describing rules or the send never know it, so it survives their update.
    func setProvenance(_ value: FlowProvenance) {
        var value = value
        if value.generatedResponse == nil { value.generatedResponse = provenance.generatedResponse }
        // Marks of the traffic tools accumulate: a rule session's report never erases them.
        value.tools = provenance.tools.merging(value.tools)
        provenance = value
        commit { $0.provenance = value }
    }

    /// Updates the traffic-tool marks in place; marks nobody changed are kept.
    func mergeTools(_ change: (inout TrafficToolsProvenance) -> Void) {
        change(&provenance.tools)
        let value = provenance
        commit { $0.provenance = value }
    }

    /// Records a locally generated response (failure page, rejection) as its own entity with no
    /// origin involved, and returns the body stream the downstream boundary should mirror.
    @discardableResult
    func recordGeneratedResponse(
        status: HTTPResponseStatus, headers: HTTPHeaders, body: ByteBuffer?, assetID: UUID? = nil
    ) -> UUID {
        let stream = beginGeneratedResponse(status: status, headers: headers, assetID: assetID,
                                            representationLength: UInt64(body?.readableBytes ?? 0))
        if let body { recordGeneratedBody(body, stream: stream) }
        finishGeneratedResponse(stream: stream, complete: true)
        return stream
    }

    /// Starts one bounded capture shared by the generated and accepted downstream views.
    /// `headers` are the original generated head, before response rules and transport framing.
    /// `projectsBody` gives a response without an asset (a rule's handwritten or preset one) the same
    /// list projection (status, headers, body) as an asset response.
    func beginGeneratedResponse(status: HTTPResponseStatus, headers: HTTPHeaders,
                                assetID: UUID?, representationLength: UInt64, projectsBody: Bool = false) -> UUID {
        let stream = makeBodyStream()
        // Preserve the legacy one-shot failure projection; asset responses get a useful fallback.
        if assetID != nil || projectsBody { generatedBodyStream = stream }
        startBoundary(
            .response(status: Int(status.code), reason: status.reasonPhrase, headers: Self.headerFields(headers)),
            boundary: .generatedResponse, version: nil, streamID: nil, transfer: .observed)
        boundaries[.generatedResponse]?.stream = stream
        provenance.generatedResponse = GeneratedResponseSource(assetID: assetID, size: representationLength)
        let value = provenance
        commit { $0.provenance = value }
        return stream
    }

    func recordGeneratedBody(_ bytes: ByteBuffer, stream: UUID) {
        captureBody(stream: stream, bytes: bytes)
        observeBody(boundary: .generatedResponse, stream: stream, byteCount: bytes.readableBytes)
        if generatedBodyStream == stream { bytesReceived += bytes.readableBytes }
    }

    /// Streaming callers finish only after the final write was accepted; failures close this
    /// stream through fail(). Bodyless replies retain the representation length in provenance.
    func finishGeneratedResponse(stream: UUID, complete: Bool) {
        closeStream(stream)
        _ = endBoundary(.generatedResponse, trailers: [], complete: complete)
        commit()
    }

    /// The upstream writer settled one request part. `succeeded` is the write future's outcome,
    /// which proves the writer accepted the bytes, not that the origin application received them.
    func recordUpstreamWrite(_ part: HTTPClientRequestPart, version: HTTPWireVersion?, streamID: Int?, succeeded: Bool, bodyStream: UUID? = nil) {
        switch part {
        case .head(let head):
            let target = HTTPMessageTarget(
                scheme: upstreamOrigin.scheme, host: upstreamOrigin.host, port: upstreamOrigin.port,
                method: head.method.rawValue, pathAndQuery: head.uri)
            beginMessage(
                .request(target, headers: Self.headerFields(head.headers)), boundary: .upstreamRequest,
                version: version, streamID: streamID, transfer: succeeded ? nil : .partiallySent)
        case .body(let body):
            let count: Int
            switch body {
            case .byteBuffer(let bytes): count = bytes.readableBytes
            case .fileRegion(let region): count = region.readableBytes
            }
            if succeeded { observeBody(boundary: .upstreamRequest, stream: bodyStream ?? requestStream, byteCount: count) }
            else { finishMessage(boundary: .upstreamRequest, trailers: [], complete: false) }
        case .end(let trailers):
            finishMessage(
                boundary: .upstreamRequest, trailers: trailers.map(Self.headerFields) ?? [], complete: succeeded)
        }
    }

    /// The downstream writer settled one response part (see `recordUpstreamWrite`). `bodyStream`
    /// is the entity the response body bytes belong to.
    func recordDownstreamWrite(_ part: HTTPServerResponsePart, bodyStream: UUID?, succeeded: Bool) {
        switch part {
        case .head(let head):
            beginMessage(
                .response(
                    status: Int(head.status.code), reason: head.status.reasonPhrase,
                    headers: Self.headerFields(head.headers)),
                // A virtual client has no wire version: only real hops record one.
                boundary: clientResponseBoundary, version: clientResponseBoundary == .composeDelivered ? nil : HTTPWireVersion(head.version),
                streamID: transport.downstreamStreamID, transfer: succeeded ? nil : .partiallySent)
            // 101 carries no body and no END: the raw relay takes over after the head.
            if succeeded, head.status == .switchingProtocols {
                finishMessage(boundary: clientResponseBoundary, trailers: [], complete: true)
            }
        case .body(let body):
            let count: Int
            switch body {
            case .byteBuffer(let bytes): count = bytes.readableBytes
            case .fileRegion(let region): count = region.readableBytes
            }
            if succeeded, let bodyStream { observeBody(boundary: clientResponseBoundary, stream: bodyStream, byteCount: count) }
            else if !succeeded { finishMessage(boundary: clientResponseBoundary, trailers: [], complete: false) }
        case .end(let trailers):
            finishMessage(
                boundary: clientResponseBoundary, trailers: trailers.map(Self.headerFields) ?? [], complete: succeeded)
        }
    }

    func finishExactStream(_ stream: UUID) { closeStream(stream); commit() }
    func finishOriginalResponse(trailers: [HeaderField]) {
        closeStream(responseStream)
        _ = endBoundary(.upstreamResponse, trailers: trailers, complete: true)
        commit()
    }

    /// A rule judged at the response answers in place of the origin's response, which is dropped unread: its body stream
    /// closes and its boundary ends incomplete (kept as the record of what the origin sent). The flow's response fields
    /// (status, headers, body, byte count) then show what the client receives, as for a Return at the request point.
    func discardOriginResponse() {
        guard !isFinished, !originDiscarded else { return }
        originDiscarded = true
        closeStream(responseStream)
        _ = endBoundary(.upstreamResponse, trailers: [], complete: false)
        bytesReceived = 0
        commit {
            $0.statusCode = nil
            $0.statusReason = nil
            $0.responseHeaders = []
            $0.responseBody = nil
            $0.responseBodyTruncated = false
            $0.bytesReceived = 0
        }
    }

    // MARK: Legacy projection (downstream request, upstream response)

    func recordRequestBody(_ buffer: ByteBuffer) {
        guard streams[requestStream]?.capture != nil else { return }
        bytesSent += buffer.readableBytes
        captureBody(stream: requestStream, bytes: buffer)
        observeBody(boundary: clientRequestBoundary, stream: requestStream, byteCount: buffer.readableBytes)
    }

    /// The client finished sending the request (`complete`), or the request was abandoned. May
    /// come after the response completed.
    func finishRequest(trailers: HTTPHeaders? = nil, complete: Bool = true) {
        guard streams[requestStream]?.capture != nil else { return }
        let (body, truncated) = closeStream(requestStream)
        let fields = trailers.map(Self.headerFields) ?? []
        _ = endBoundary(clientRequestBoundary, trailers: fields, complete: complete)
        let sent = bytesSent
        commit {
            $0.requestTrailers = fields
            $0.requestBody = body
            $0.requestBodyTruncated = truncated
            $0.bytesSent = sent
        }
    }

    func recordResponseHead(_ head: HTTPResponseHead, upstreamVersion: HTTPWireVersion? = nil, streamID: Int? = nil) {
        guard !isFinished else { return }
        let headers = Self.headerFields(head.headers)
        let version = upstreamVersion ?? HTTPWireVersion(head.version)
        startBoundary(
            .response(status: Int(head.status.code), reason: head.status.reasonPhrase, headers: headers),
            boundary: .upstreamResponse, version: version, streamID: streamID, transfer: .observed)
        boundaries[.upstreamResponse]?.stream = responseStream
        commit {
            $0.transport.upstreamResponse = version
            $0.statusCode = Int(head.status.code)
            $0.statusReason = head.status.reasonPhrase
            $0.responseHeaders = headers
        }
    }

    func recordResponseBody(_ buffer: ByteBuffer) {
        guard !isFinished, streams[responseStream]?.capture != nil else { return }
        bytesReceived += buffer.readableBytes
        captureBody(stream: responseStream, bytes: buffer)
        observeBody(boundary: .upstreamResponse, stream: responseStream, byteCount: buffer.readableBytes)
    }

    func complete(trailers: HTTPHeaders? = nil, note: String? = nil) {
        finish(.completed, trailers: trailers, note: note)
    }

    /// Also closes the request side: a failed exchange receives no more request bytes.
    func fail(_ reason: String) {
        finishRequest(complete: false)
        finish(.failed(reason), trailers: nil, note: nil)
    }

    // MARK: Internals

    private func startBoundary(
        _ head: HTTPMessageHead, boundary: HTTPMessageBoundary, version: HTTPWireVersion?, streamID: Int?,
        transfer: HTTPTransferState?
    ) {
        let state = transfer ?? (boundary.isReceived ? .observed : .acceptedByWriter)
        boundaries[boundary] = MessageBoundaryState(head: head, version: version, streamID: streamID, transfer: state)
        dirty.insert(boundary)
        // The legacy per-boundary versions mirror only what a writer accepted or the proxy read.
        guard state != .partiallySent, state != .failed else { return }
        switch boundary {
        case .upstreamRequest: pendingLegacy.append { $0.transport.upstreamRequest = version; $0.transport.upstreamStreamID = streamID }
        case .downstreamResponse: pendingLegacy.append { $0.transport.downstreamResponse = version }
        default: break
        }
    }

    @discardableResult
    private func endBoundary(_ boundary: HTTPMessageBoundary, trailers: [HeaderField], complete: Bool) -> Bool {
        guard var state = boundaries[boundary], !state.finished else { return false }
        state.trailers = trailers
        state.finished = true
        state.complete = complete
        state.transfer = complete ? .finished : (boundary.isReceived ? .failed : .partiallySent)
        boundaries[boundary] = state
        dirty.insert(boundary)
        return true
    }

    /// Ends a body entity once; every boundary mirroring it is republished with the final reference.
    @discardableResult
    private func closeStream(_ id: UUID) -> (body: BodyRef?, truncated: Bool) {
        guard var stream = streams[id] else { return (nil, false) }
        if let final = stream.final { return (final.ref, final.truncated) }
        let (body, truncated) = stream.capture?.finish() ?? (nil, false)
        stream.capture = nil
        stream.final = (body, truncated)
        streams[id] = stream
        for (boundary, state) in boundaries where state.stream == id { dirty.insert(boundary) }
        return (body, truncated)
    }

    /// One store update: the caller's legacy fields plus every boundary changed since the last one.
    private func commit(_ legacy: ((inout Flow) -> Void)? = nil) {
        let changed = dirty.map { ($0, boundaries[$0]?.snapshot($0, streams: streams)) }
        dirty.removeAll()
        let extra = pendingLegacy
        pendingLegacy.removeAll()
        guard legacy != nil || !changed.isEmpty || !extra.isEmpty else { return }
        store.update(id) { flow in
            for modify in extra { modify(&flow) }
            legacy?(&flow)
            for case (let boundary, let snapshot?) in changed { flow.messages[boundary] = snapshot }
        }
    }

    private func schedulePublish() {
        guard publishTask == nil else { return }
        publishTask = eventLoop.assumeIsolated().scheduleTask(in: Self.publishInterval) {
            self.publishTask = nil
            let sent = self.bytesSent
            let received = self.bytesReceived
            self.commit {
                $0.bytesSent = sent
                $0.bytesReceived = received
            }
        }
    }

    private func finish(_ state: FlowState, trailers: HTTPHeaders?, note: String?) {
        guard !isFinished else { return }
        isFinished = true
        publishTask?.cancel()
        publishTask = nil
        let answeredLocally = boundaries[.upstreamResponse] == nil || originDiscarded
        // A discarded origin's partial body is not what the client received: with no replacement body (a replacement that
        // failed, such as a missing file) nothing is recorded.
        let responseBody: UUID? = originDiscarded ? generatedBodyStream : (answeredLocally ? (generatedBodyStream ?? responseStream) : responseStream)
        let (body, truncated) = responseBody.map { closeStream($0) } ?? (nil, false)
        let generated = answeredLocally && generatedBodyStream != nil ? boundaries[.generatedResponse]?.head : nil
        let fields = trailers.map(Self.headerFields) ?? []
        _ = endBoundary(.upstreamResponse, trailers: fields, complete: !isFailure(state))
        if isFailure(state) {
            // The exchange is over: whatever has not finished will not, so it is no longer pending.
            for id in streams.keys { closeStream(id) }
            for boundary in boundaries.keys { _ = endBoundary(boundary, trailers: [], complete: false) }
        }
        let received = bytesReceived
        let now = Date.now
        var completion = FlowCompletionOutput(annotations: [], provenance: nil)
        if let hook = completionHook {
            completionHook = nil
            completion = hook(FlowCompletionInput(
                state: isFailure(state) ? .failed : .completed,
                durationMilliseconds: Int((now.timeIntervalSince(startedAt) * 1000).rounded()),
                responseWireBytes: answeredLocally ? nil : received))
        }
        if var merged = completion.provenance {
            if merged.generatedResponse == nil { merged.generatedResponse = provenance.generatedResponse }
            merged.tools = provenance.tools.merging(merged.tools)
            provenance = merged
            completion.provenance = merged
        }
        commit {
            if case .response(let status, let reason, let headers) = generated {
                $0.statusCode = status
                $0.statusReason = reason
                $0.responseHeaders = headers
            }
            $0.responseTrailers = fields
            $0.responseBody = body
            $0.responseBodyTruncated = truncated
            $0.bytesReceived = received
            $0.state = state
            $0.completedAt = now
            // A session that ends while held at a breakpoint is no longer held.
            $0.isPausedAtBreakpoint = false
            if let note { $0.note = note }
            Self.apply(completion.annotations, to: &$0)
            if let value = completion.provenance { $0.provenance = value }
        }
    }

    private func isFailure(_ state: FlowState) -> Bool {
        if case .failed = state { true } else { false }
    }

    static func headerFields(_ headers: HTTPHeaders) -> [HeaderField] {
        headers.map { HeaderField(name: $0.name, value: $0.value) }
    }

    /// How a host is stored in `Flow.host`: lowercased, IPv6 literals in brackets (so `Flow.url`
    /// is a valid URL and host filters match regardless of how the client spelled it).
    static func flowHost(_ host: String) -> String {
        let lowered = host.lowercased()
        if lowered.contains(":"), !lowered.hasPrefix("[") { return "[\(lowered)]" }
        return lowered
    }
}

/// Records a CONNECT as one flow (method "CONNECT", empty path): a tunnel relayed without
/// decryption, or a client TLS handshake that failed.
///
/// Confined to the event loop of the client connection. Byte counts are published to the store
/// at most every `publishInterval` while the tunnel is open, and once more when it closes.
final class TunnelRecorder {
    static let publishInterval: TimeAmount = .milliseconds(250)

    private let id: Int
    private let store: FlowStore
    private let eventLoop: EventLoop
    private var bytesSent = 0
    private var bytesReceived = 0
    private var publishTask: Scheduled<Void>?
    private var isFinished = false

    /// Begins a `.tunnel` flow. `holdPublication` keeps it from subscribers until the first update (`apply`),
    /// so what the CONNECT point's rules did to it (a hide) is there from the first time it shows.
    init(store: FlowStore, host: String, port: Int, client: ClientApp?, eventLoop: EventLoop, holdPublication: Bool = false) {
        self.store = store
        self.eventLoop = eventLoop
        self.id = Self.begin(store: store, host: host, port: port, client: client, state: .tunnel,
                             deferringPublication: holdPublication)
    }

    /// Records a finished, failed CONNECT flow in one go, with what the CONNECT point's rules did to it.
    @discardableResult
    static func recordFailure(
        store: FlowStore, host: String, port: Int, client: ClientApp?, reason: String, note: String?,
        provenance: FlowProvenance = .unknown, annotations: [FlowAnnotation] = []
    ) -> Int {
        begin(store: store, host: host, port: port, client: client, state: .failed(reason)) {
            $0.completedAt = $0.startedAt
            $0.note = note
            $0.provenance = provenance
            FlowRecorder.apply(annotations, to: &$0)
        }
    }

    private static func begin(
        store: FlowStore, host: String, port: Int, client: ClientApp?, state: FlowState, deferringPublication: Bool = false,
        customize: (inout Flow) -> Void = { _ in }
    ) -> Int {
        let host = FlowRecorder.flowHost(host)
        return store.begin(deferringPublication: deferringPublication) { id in
            var flow = Flow(id: id, scheme: "https", method: "CONNECT", host: host, port: port, path: "")
            flow.state = state
            flow.client = client
            customize(&flow)
            return flow
        }
    }

    func setClient(_ client: ClientApp) {
        store.update(id) { $0.client = client }
    }

    /// Writes what the CONNECT point's rules did (in the order they ran) and their outcomes in one update, which
    /// also publishes a held row. It touches neither the state nor the counts, so it is harmless at any time.
    func apply(annotations: [FlowAnnotation], provenance: FlowProvenance) {
        store.update(id) {
            $0.provenance = provenance
            FlowRecorder.apply(annotations, to: &$0)
        }
    }

    /// Bytes relayed from the client to the origin.
    func addSent(_ count: Int) {
        bytesSent += count
        schedulePublish()
    }

    /// Bytes relayed from the origin to the client.
    func addReceived(_ count: Int) {
        bytesReceived += count
        schedulePublish()
    }

    /// The tunnel closed: publish the final counts and the completion time.
    func close() {
        finish(failure: nil)
    }

    /// The tunnel could not be opened.
    func fail(_ reason: String) {
        finish(failure: reason)
    }

    private func schedulePublish() {
        guard !isFinished, publishTask == nil else { return }
        publishTask = eventLoop.assumeIsolated().scheduleTask(in: Self.publishInterval) {
            self.publishTask = nil
            self.publish()
        }
    }

    private func publish(completing: Bool = false, failure: String? = nil) {
        let sent = bytesSent
        let received = bytesReceived
        store.update(id) {
            $0.bytesSent = sent
            $0.bytesReceived = received
            if completing { $0.completedAt = .now }
            if let failure { $0.state = .failed(failure) }
        }
    }

    private func finish(failure: String?) {
        guard !isFinished else { return }
        isFinished = true
        publishTask?.cancel()
        publishTask = nil
        publish(completing: true, failure: failure)
    }
}

/// NIO stays at the proxy boundary; unsupported versions remain unknown.
extension HTTPWireVersion {
    init?(_ version: HTTPVersion) {
        switch (version.major, version.minor) {
        case (1, 0): self = .http1_0
        case (1, 1): self = .http1_1
        case (2, 0): self = .http2
        default: return nil
        }
    }
}
