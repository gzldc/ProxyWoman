import FlowStore
import Foundation

/// The original records of one captured session as a rule would have seen them (D7): the client's request,
/// the origin's response (else the one the proxy generated), and the facts around them. Live counts and
/// Execute both read a flow through this type, so they cannot disagree on what "original" means.
public struct FlowOriginals: Sendable {
    public struct Body: Sendable {
        public var slice: HTTPBodySlice?
        public var legacy: BodyRef?
        public var state: HTTPBodyState
        public var legacyTruncated: Bool

        public init(
            slice: HTTPBodySlice? = nil, legacy: BodyRef? = nil, state: HTTPBodyState = .complete,
            legacyTruncated: Bool = false
        ) {
            self.slice = slice
            self.legacy = legacy
            self.state = state
            self.legacyTruncated = legacyTruncated
        }

        /// The captured byte count (0 when nothing was kept).
        public var size: Int { slice?.count ?? legacy?.size ?? 0 }

        /// Reads at most `maxBytes`; may read a spilled body from disk (call off the main actor).
        public func load(maxBytes: Int) throws -> Data {
            if let slice { return try slice.load(maxBytes: maxBytes).data }
            if let legacy { return try legacy.load(maxBytes: maxBytes).data }
            return Data()
        }

        /// The body as a condition reads it. With `allowDisk: false` only what is in memory is read: a
        /// spilled body is `bodySkippedOnDisk`. Either way a body bigger than the condition cap is
        /// `bodyTooLarge`, a cut-short one `bodyTooLarge`, an unfinished one `bodySkippedStreaming`.
        public func peek(headers: [HeaderField], allowDisk: Bool, limits: RulesLimits) -> BodyPeek {
            let reference: BodyRef
            let count: Int
            if let slice {
                switch state {
                case .complete: break
                case .truncated: return .skipped(.bodyTooLarge)
                case .pending, .incomplete, .unavailable: return .skipped(.bodySkippedStreaming)
                }
                reference = slice.ref
                count = slice.count
            } else if let legacy {
                if legacyTruncated { return .skipped(.bodyTooLarge) }
                reference = legacy
                count = legacy.size
            } else {
                return state == .complete ? .empty : .skipped(.bodySkippedStreaming)
            }
            guard count > 0 else { return .empty }
            if !allowDisk {
                switch reference {
                case .file: return .skipped(.bodySkippedOnDisk)
                case .managed(let handle) where handle.isOnDisk: return .skipped(.bodySkippedOnDisk)
                case .memory, .managed: break
                }
            }
            guard count <= limits.conditionBodyBytes else { return .skipped(.bodyTooLarge) }
            let data: Data
            do {
                data = try load(maxBytes: limits.conditionBodyBytes)
            } catch {
                return .skipped(.bodySkippedUnavailable)
            }
            return BodyPeek.decode(data, headers: headers, limits: limits)
        }
    }

    public struct Message: Sendable {
        public var head: HTTPMessageHead
        public var body: Body

        public init(head: HTTPMessageHead, body: Body) {
            self.head = head
            self.body = body
        }

        public var headers: [HeaderField] { head.headers }

        /// The request target; nil for a response.
        public var target: HTTPMessageTarget? {
            if case .request(let target, _) = head { return target }
            return nil
        }

        /// The status code; nil for a request.
        public var status: Int? {
            if case .response(let status, _, _) = head { return status }
            return nil
        }
    }

    public var request: Message
    /// Nil: no response was captured.
    public var response: Message?
    /// `comment` = the flow's comment, `rulesModified` = the flow's live-rules flag.
    public var facts: ExchangeFacts
    public var completion: CompletionFacts
    /// False for a session still in flight (see `inFlight(_:timeZone:)`): `completion` is then a placeholder
    /// that must not be read.
    public var isFinished: Bool = true
    public var isTunnel: Bool
    /// Bytes that really came from the origin (`false` for a generated response).
    public var hadOriginResponse: Bool

    /// Nil while the flow is in progress. The client's original request and the origin's original response
    /// (the proxy's own when there was none; Compose: submitted and delivered), the legacy projection for
    /// flows recorded without boundaries.
    public static func of(_ flow: Flow, timeZone: TimeZone = .current) -> FlowOriginals? {
        if flow.state == .inProgress { return nil }
        return build(flow, timeZone: timeZone)
    }

    /// Like `of`, but also for a session still in flight: what has arrived so far, `isFinished == false`.
    /// Only the live count uses it; Execute and rules keep `of`.
    public static func inFlight(_ flow: Flow, timeZone: TimeZone = .current) -> FlowOriginals {
        build(flow, timeZone: timeZone)
    }

    private static func build(_ flow: Flow, timeZone: TimeZone) -> FlowOriginals {
        let state: CompletionFacts.SessionState
        switch flow.state {
        case .inProgress: state = .completed
        case .completed: state = .completed
        case .failed: state = .failed
        case .tunnel: state = .tunnel
        }
        let isLegacy = flow.messages.isEmpty
        let requestSnapshot = flow.provenance.isCompose ? flow.messages[.composeSubmitted] : flow.messages[.downstreamRequest]
        let responseSnapshot: HTTPMessageSnapshot?
        if flow.provenance.isCompose {
            responseSnapshot = flow.messages[.composeDelivered]
        } else {
            responseSnapshot = flow.messages[.upstreamResponse] ?? flow.messages[.generatedResponse]
        }

        let target = requestSnapshot?.target
            ?? HTTPMessageTarget(
                scheme: flow.scheme, host: flow.host, port: flow.port, method: flow.method, pathAndQuery: flow.path)
        // Before the first snapshot of a session in flight nothing is known about its request body: pending, not empty.
        let unknownRequestBody = requestSnapshot == nil && flow.state == .inProgress && flow.requestBody == nil
        let request = Message(
            head: .request(target, headers: requestSnapshot?.headers ?? flow.requestHeaders),
            body: Body(
                slice: requestSnapshot?.body, legacy: requestSnapshot == nil ? flow.requestBody : nil,
                state: requestSnapshot?.bodyState ?? (unknownRequestBody ? .pending : .complete),
                legacyTruncated: flow.requestBodyTruncated))

        var response: Message?
        if flow.state != .tunnel {
            if let responseSnapshot, responseSnapshot.status != nil {
                response = Message(
                    head: responseSnapshot.head,
                    body: Body(
                        slice: responseSnapshot.body, legacy: nil, state: responseSnapshot.bodyState,
                        legacyTruncated: flow.responseBodyTruncated))
            } else if isLegacy, let status = flow.statusCode {
                response = Message(
                    head: .response(status: status, reason: nil, headers: flow.responseHeaders),
                    body: Body(
                        slice: nil, legacy: flow.responseBody, state: .complete,
                        legacyTruncated: flow.responseBodyTruncated))
            }
        }

        let hadOriginResponse = isLegacy ? flow.statusCode != nil : flow.messages[.upstreamResponse] != nil
        let facts = ExchangeFacts(
            clientIP: flow.clientIP, remoteIP: flow.remoteIP, clientHTTPVersion: flow.transport.downstreamRequest,
            upstreamHTTPVersion: flow.transport.upstreamRequest ?? flow.transport.upstreamResponse,
            clientTLSVersion: flow.transport.downstreamTLSVersion, upstreamTLSVersion: flow.transport.upstreamTLSVersion,
            certificate: flow.upstreamCertificate,
            app: flow.client.map(ExchangeFacts.AppLookup.known) ?? (flow.provenance.isCompose ? .notApplicable : .unknown),
            requestStartedAt: flow.startedAt, timeZone: timeZone, comment: flow.comment,
            rulesModified: flow.provenance.rulesModified, isPausedAtBreakpoint: flow.isPausedAtBreakpoint)
        let duration = flow.completedAt.map { Int(($0.timeIntervalSince(flow.startedAt) * 1000).rounded()) } ?? 0
        return FlowOriginals(
            request: request, response: response, facts: facts,
            completion: CompletionFacts(
                state: state, durationMilliseconds: duration,
                responseWireBytes: hadOriginResponse ? flow.bytesReceived : nil),
            isFinished: flow.state != .inProgress, isTunnel: flow.state == .tunnel, hadOriginResponse: hadOriginResponse)
    }
}
