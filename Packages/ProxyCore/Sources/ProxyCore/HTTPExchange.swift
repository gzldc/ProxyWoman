import Darwin
import FlowStore
import Foundation
import Localization
import NIOCore
import NIOHTTP1
import RulesEngine

/// A single request/response lifecycle, independent of downstream connection scheduling.
/// Owned by its connection until terminal; attempt sinks weakly reference it.
///
/// Two phases: the initializer admits the request (registration, recording, upgrade
/// classification, the frozen rule snapshot) without touching an upstream; `execute()` runs the
/// request rules and `execute(_:)` then fixes what is forwarded and where, exactly once, and starts
/// acquisition.
final class HTTPExchange {
    /// The original prepared head, used for recording and matching; never the forwarded edit.
    let requestHead: HTTPRequestHead
    let target: RequestTarget
    let downstream: DownstreamResponseWriter
    let connection: HTTPOutboundEnvironment
    /// Classified from the original head: an upgrade always uses a dedicated HTTP/1 route.
    let upgrade: Bool
    /// Both set exactly once by `execute(_:)`, before any acquisition.
    private var effectiveTarget: RequestTarget?
    private(set) var effectiveRequestMethod: HTTPMethod?
    private var route: UpstreamRoute?
    private var finalResponseStage: (HTTPResponseHead, @escaping (HTTPResponseHead) -> Void) throws -> Void = { head, resume in resume(head) }
    private(set) var responseStaging = false
    private var responsePending: [(HTTPClientResponsePart, Int)] = []
    private var responsePendingBytes = 0
    private var responseEndQueued = false
    private var flowRemovalRegistered = false
    private let policy: HTTPExecutionPolicy
    /// The Allow/Block decision frozen at admission; `.unchanged` when no list is active.
    let trafficAdmission: TrafficAdmission
    /// The rules frozen at admission; nil when rules are off for this exchange.
    private(set) var rules: ExchangeRuleSession?
    private let factsState = ExchangeFactsState()
    /// The gate collecting a body (a full-body breakpoint, a body rewrite or a peek), at most one at a time.
    var bodyGate: (any ExchangeBodyGate)?
    var requestPeek = RequestPeek()
    var responsePeek = RequestPeek()
    private(set) var exactRequest: BreakpointBodyContinuation?
    private(set) var exactResponse: BreakpointBodyContinuation?
    private var exactRequestStream: UUID?
    private var exactResponseStream: UUID?
    private var exactRequestOffset: Int64 = 0
    private var exactResponseOffset: Int64 = 0
    private var exactRequestBusy = false
    private var exactResponseBusy = false
    private var exactRequestWrite: EventLoopFuture<Void>?
    private var exactResponseWrite: EventLoopFuture<Void>?
    private var exactRequestTask: Task<Void, Never>?
    private var exactResponseTask: Task<Void, Never>?
    private var exactResponsePlan: FramingPlan?
    private var exactRequestPlan: FramingPlan?
    private var collectedResponseTrailers: HTTPHeaders?
    private var localCollectionEnded = false
    private var localCollectionBodyAllowed = true
    private(set) lazy var bodyIO: BodyFileIO? = {
        guard let runtime = connection.environment.bodyRuntime, let pool = connection.environment.fileIOPool else { return nil }
        return runtime.makeIO(eventLoop: downstream.eventLoop, pool: pool)
    }()
    /// The machine code of the local failure response this exchange produced (or `ruleClosed`), if any.
    private(set) var localFailure: HTTPLocalFailureCode?
    /// The localized message of that local failure (the page without the product name).
    private(set) var localFailureMessage: String?
    /// An upstream writer accepted a request head of this exchange: the origin may have seen it.
    private(set) var upstreamRequestSubmitted = false
    /// The origin answered with a final (non-1xx) response head.
    private(set) var upstreamFinalHeadReceived = false
    private(set) var recorder: FlowRecorder?
    /// The recorded flow, if this exchange is recorded.
    var flowID: Int? { recorder?.id }
    private var lastRecordedRuleProvenance: FlowProvenance?
    private var pendingWebSocket: WebSocketPendingHandshake?
    private var keepAlive: Bool
    private(set) var requestComplete = false
    private var responseComplete = false
    /// Ownership is separate from delivery: an arriving request END cannot finish a prepare.
    private var localResponseClaimed = false
    private var localSource: LocalResponseSource?
    /// A Map Local directory resolution in flight. Nothing is claimed while it runs: the upload
    /// stays pending (within its budget) so a missing file can still go to the network.
    private var directoryResolution: Task<Void, Never>?
    private var localOperation: Task<Void, Never>?
    private var localBusy = false
    private var localHeadWritten = false
    private var localGeneratedStream: UUID?
    private var localRetry: Scheduled<Void>?
    private var localRetryDeadline: NIODeadline?
    private var anyResponseHead = false
    private var localContinueSent = false
    private var upgrading = false
    private var upstreamReusable = true
    private var forwardsRequest = true
    private(set) var terminal = false
    private(set) var attempt = 0
    private(set) var lease: UpstreamLease?
    private var acquisition: UpstreamAcquisition?
    private var replay: RequestReplayBuffer?
    private var pending: [HTTPClientRequestPart] = []
    private var pendingBytes = 0
    private var uploadDisposalTimer: Scheduled<Void>?
    var ruleDelay = RuleDelayState()
    var responseDelay = ResponseDelayState()
    /// A rule judged at the response answered in place of the origin: the proxy's own response goes out next
    /// and the response point does not run on it again.
    private var responseReplaced = false
    private var lastClientWrite: EventLoopFuture<Void>?
    private var pendingDownstreamWrites = 0
    private var responseAwaitingWrites = false
    private var responseTrailers: HTTPHeaders?
    private var upstreamRequestDestination: HTTPWireVersion?
    private var requestIsChunked = false
    private var downstreamResponseDestination: HTTPWireVersion?
    private var responseBodyAllowed = true
    private var responseIsChunked = false
    private let scheme: String
    private var requestReadBatch: Bool
    private var responseReadBatch = false
    let requestInitialEndStream: Bool

    var snapshot: HTTPExchangeSnapshot {
        downstream.eventLoop.preconditionInEventLoop()
        return .init(path: target.originForm, pendingBytes: pendingBytes, uploadDisposalTimers: uploadDisposalTimer == nil ? 0 : 1,
            pendingBodyCapacity: responsePending.reduce(0) { total, entry in
                if case .body(let bytes) = entry.0 { return total + bytes.capacity }
                return total
            } + pending.reduce(0) { total, part in
                if case .body(.byteBuffer(let bytes)) = part { return total + bytes.capacity }
                return total
            }, downstreamQueuedBodyBytes: (downstream as? HTTP2DownstreamHandler)?.queuedBodyBytes,
            upstreamQueuedBodyBytes: (lease as? HTTP2UpstreamLease)?.queuedBodyBytes,
            requestReading: (downstream as? HTTP2DownstreamHandler)?.reading,
            responseReading: (lease as? HTTP2UpstreamLease)?.reading, breakpointTimers: bodyGate?.timerCount ?? 0)
    }

    init(requestHead clientHead: HTTPRequestHead, target: RequestTarget, scheme: String,
         downstream: DownstreamResponseWriter, connection: HTTPOutboundEnvironment, transport: HTTPTransportMetadata,
         requestInitialEndStream: Bool = false, requestReadBatch: Bool = false,
         policy: HTTPExecutionPolicy = .init(), provenance: FlowProvenance = .passive) {
        self.requestReadBatch = requestReadBatch
        self.policy = policy
        self.requestInitialEndStream = requestInitialEndStream
        var head = clientHead
        head.uri = target.originForm
        head.headers.remove(name: "proxy-connection")
        if !head.headers.contains(name: "host") { head.headers.add(name: "Host", value: target.hostHeader) }
        self.requestHead = head
        self.target = target
        // Frozen once per admitted head: a publish affects the next head only. With no active list
        // the policy is not consulted any further and the exchange runs exactly as without it.
        let trafficPolicy = connection.environment.traffic?.current()
        if let trafficPolicy, trafficPolicy.affectsExchanges {
            trafficAdmission = trafficPolicy.admission(
                request: HTTPMessageTarget(scheme: scheme, host: target.host, port: target.port,
                                           method: head.method.rawValue, pathAndQuery: target.originForm),
                explicitSend: policy.virtualClient)
        } else {
            trafficAdmission = .unchanged
        }
        self.downstream = downstream
        self.connection = connection
        self.scheme = scheme
        let upgrade = head.headers.contains(name: "upgrade")
            && head.headers[canonicalForm: "connection"].contains { $0.lowercased() == "upgrade" }
        self.upgrade = upgrade
        keepAlive = (downstream.version == .http2 || clientHead.isKeepAlive) && !upgrade
        guard connection.register(self, streamID: transport.downstreamStreamID) else { cancel(reason: L10n.string("proxyFailure.clientDisconnected")); return }
        // One snapshot read serves both the publication hold and the rule session.
        let ruleProvider = policy.rulesEnabled && trafficAdmission.appliesRules ? connection.environment.rules : nil
        let published = ruleProvider?.active()
        let store = policy.recordsWhilePaused ? connection.environment.recording.store : connection.environment.recording.activeStore
        recorder = trafficAdmission.records ? store.map { store in
            FlowRecorder(store: store, scheme: scheme, method: head.method.rawValue,
                host: target.host, port: target.port, path: target.originForm,
                requestHeaders: clientHead.headers, client: connection.knownClient,
                eventLoop: downstream.eventLoop, transport: transport, virtualClient: policy.virtualClient,
                holdPublication: published?.canHideAtRequestPoint == true)
        } : nil
        if provenance != .passive {
            recorder?.setProvenance(provenance)
            lastRecordedRuleProvenance = provenance
        }
        if case .block(let entryID) = trafficAdmission.action {
            recorder?.mergeTools { $0.blockedByEntry = entryID }
        }
        // Network conditions do not depend on the lists: the client side's gate follows the
        // target, and the flow is tagged with the condition that applies to it.
        connection.bindShaping(host: target.host, port: target.port)
        if let resolved = trafficPolicy?.conditions.resolve(host: target.host, port: target.port) {
            recorder?.mergeTools { $0.networkCondition = resolved.label }
        }
        if let recorder {
            connection.onClient(recorder.setClient)
            recorder.setConnectionInfo(FlowConnectionInfo(clientIP: connection.clientIP, downstreamTLSVersion: connection.downstreamTLSVersion))
            // The WebSocket record keeps the client's original handshake. Rules cannot change what
            // the observer evaluates: an Upgrade skips Map rules and every negotiation field
            // (Host, Connection, Upgrade, Sec-WebSocket-*) is protected from edits.
            pendingWebSocket = WebSocketPendingHandshake(request: clientHead, budget: connection.environment.recording.store.webSocketBudget)
        }
        // Read live for every admitted head, never per socket: a publish or the global switch
        // affects the next head. Switched off, the exchange runs exactly as without rules.
        if let provider = ruleProvider, let published {
            let original = HTTPMessageHead.request(
                HTTPMessageTarget(scheme: scheme, host: target.host, port: target.port, method: head.method.rawValue,
                                  pathAndQuery: target.originForm), headers: head.headers.fields)
            let source = ExchangeRuleSession.FactsSource.exchange(
                connection: connection, clientVersion: downstream.version, state: factsState,
                virtualClient: policy.virtualClient, comment: { [weak recorder] in recorder?.comment })
            rules = ExchangeRuleSession(snapshot: published, hits: provider.hits, originalRequest: original,
                                        provenance: provenance, factsSource: source)
            if published.requirements.completion, let rules { recorder?.completionHook = rules.completion }
        }
        connection.whenForwardingAllowed { [weak self] in self?.sendPending(); self?.updateReading() }
    }

    /// Forwards the prepared request unchanged.
    var forwardUnchanged: HTTPRequestDecision { HTTPRequestDecision(head: requestHead, target: target) }

    /// Runs the request rules (if any) and executes their decision; `decided` is a request point that was
    /// already evaluated off the event loop (`startRequestPeek`).
    func execute(decided: Result<RequestRuleDecision, Error>? = nil) {
        // A rule on the client app waits for the lookup (or its grace); nothing else ever does.
        if let rules, !terminal, rules.snapshot.requirements.clientApp, !policy.virtualClient, !connection.forwardingAllowed {
            connection.whenForwardingAllowed { [weak self] in self?.execute() }
            return
        }
        if decided == nil, startRequestPeek() { return }
        defer { recorder?.releasePublication() }
        if case .block = trafficAdmission.action, !terminal {
            fail(status: .forbidden, code: .blockedByList, message: HTTPLocalFailureText.blocked(authority: target.authority))
            return
        }
        guard let rules, !terminal else { execute(forwardUnchanged); return }
        downstream.eventLoop.preconditionInEventLoop()
        let continuation: ExchangeRuleContinuation
        do {
            defer { recordRuleProvenanceIfChanged(rules.provenance) }
            let decision = try decided?.get() ?? rules.prepareRequest(limits: rewriteLimits)
            if scheduleRuleDelay(decision) { return }
            if decision.breakpoint != nil, connection.environment.breakpoints == nil {
                throw ExchangeRuleFailure.unsupported("requestBreakpoint")
            }
            if let mode = decision.breakpoint { try connection.environment.breakpoints?.validatePauseMode(mode, bodySupported: bodyIO != nil) }
            continuation = try rules.continuation(for: decision)
            if let mode = decision.breakpoint, let coordinator = connection.environment.breakpoints {
                let head: HTTPMessageHead
                let routeKind: BreakpointRouteKind
                switch continuation {
                case .network(let effective, _): head = effective; routeKind = .network
                case .local, .localDirectory, .generated, .close: head = decision.effectiveHead; routeKind = .local
                }
                let now = coordinator.clock.now
                let ticket = BreakpointTicket(
                    token: .init(ticketID: .init(), generation: 0, revision: rules.snapshot.revision),
                    contextID: connection.contextID, flowID: recorder?.id, direction: .request,
                    originalHead: rules.originalRequest, effectiveHead: head, routeKind: routeKind,
                    source: rules.provenance.source, mode: mode, state: .pausedHeaders,
                    matchedAt: now, deadline: now + .seconds(Int64(coordinator.limits.ticketSeconds)), matches: decision.matches)
                let gate = ExchangeBreakpointGate(loop: downstream.eventLoop, coordinator: coordinator,
                    io: bodyIO, sourceVersion: HTTPWireVersion(requestHead.version) ?? .http1_1, requestMethod: requestHead.method.rawValue,
                    changed: { [weak self] in self?.collectionChanged() },
                    bodyFailure: { [weak self] in self?.failBody($0, direction: .request) },
                    continueBody: { [weak self] in self?.acceptBody($0, direction: .request) },
                    sendContinue: { [weak self] in self?.sendLocalContinue() },
                    pauseChanged: { [weak self, weak connection = self.connection] in
                        connection?.breakpointPauseChanged($0)
                        self?.recorder?.setPausedAtBreakpoint($0)
                    },
                    resume: { [weak self] in self?.executeContinuation($0) },
                    fail: { [weak self] reason in
                        let code: HTTPLocalFailureCode = reason == .expired ? .breakpointTimeout : .breakpointCancelled
                        self?.fail(status: reason == .expired ? .gatewayTimeout : .badGateway, code: code,
                                   message: HTTPLocalFailureText.breakpoint(code))
                    })
                bodyGate = gate
                do {
                    if try gate.pause(ticket: ticket, continuation: continuation) {
                        bindFlowRemoval(coordinator)
                    } else {
                        bodyGate = nil
                        executeContinuation(continuation)
                    }
                }
                catch let mutation as HTTPMutationError {
                    gate.abandon()
                    throw ExchangeRuleFailure.rejected(mutation)
                } catch let failure as ExchangeRuleFailure {
                    gate.abandon()
                    throw failure
                } catch let error as OwnedFileError {
                    gate.abandon()
                    failBody(error, direction: .request)
                } catch {
                    gate.abandon()
                    fail(status: .serviceUnavailable, code: .breakpointCapacity,
                         message: HTTPLocalFailureText.breakpoint(.breakpointCapacity))
                }
                updateReading()
                return
            }
            // The evaluator hands out body steps only without a breakpoint, an upgrade or a local route.
            if decision.breakpoint == nil, !decision.bodyRewrites.isEmpty, case .network(let effective, _) = continuation,
               startRequestRewrite(decision, effective: effective, continuation: continuation) {
                return
            }
        } catch {
            failRule(error)
            return
        }
        executeContinuation(continuation)
    }

    /// Collects the request body for the rule steps through the same staging route as a full-body
    /// breakpoint, then continues on the exact-body path with the rewritten (or original) bytes.
    /// Returns true when a gate now owns the request. False: nothing is collected (the request has
    /// no body, or it cannot be held) and the caller continues with the untouched request; the
    /// rules say why.
    private func startRequestRewrite(_ decision: RequestRuleDecision, effective: HTTPMessageHead,
                                     continuation: ExchangeRuleContinuation) -> Bool {
        guard let rules else { return false }
        func skip(_ code: RuleOutcomeCode) -> Bool {
            rules.recordBodyRewriteOutcomes(decision.bodyRewrites.map { RuleOutcome(ruleID: $0.ruleID, code: code, actionIndex: $0.actionIndex) },
                                           direction: .request)
            return false
        }
        let wire = requestHead.headers
        let sourceVersion = HTTPWireVersion(requestHead.version) ?? .http1_1
        let hasLength = wire.first(name: "content-length").flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
        let framed = sourceVersion == .http2 ? !requestInitialEndStream : (wire.contains(name: "transfer-encoding") || (hasLength ?? 0) > 0)
        guard framed else { return skip(.bodySkippedNoBody) }
        // Only a plain `Expect: 100-continue` is understood; the local 100 follows the collection start.
        let expectations = wire["expect"]
        guard expectations.allSatisfy({ value in
            value.split(separator: ",", omittingEmptySubsequences: false).allSatisfy {
                $0.trimmingCharacters(in: .whitespaces).lowercased() == "100-continue"
            }
        }) else { return skip(.bodySkippedUnavailable) }
        guard let io = bodyIO else { return skip(.bodySkippedUnavailable) }
        let expected: Int64? = sourceVersion != .http2 && wire.contains(name: "transfer-encoding") ? nil : hasLength
        let generation = attempt
        let rewriter: ExchangeBodyRewriter
        do {
            rewriter = try ExchangeBodyRewriter(
                loop: downstream.eventLoop, io: io, limits: io.limits, cache: connection.environment.rules?.patternCache ?? .shared,
                direction: .request, steps: decision.bodyRewrites, effectiveHead: effective,
                expectedLength: expected, sourceVersion: sourceVersion, collected: requestPeek.source,
                changed: { [weak self] in self?.collectionChanged() },
                completed: { [weak self] completion in
                    guard let self, !self.terminal, self.attempt == generation, let rules = self.rules else {
                        completion.continuation.source.cancel(); return
                    }
                    // Resolved: it holds nothing any more, and the response side may take the slot.
                    if (self.bodyGate as? ExchangeBodyRewriter)?.direction == .request { self.bodyGate = nil }
                    self.acceptBody(completion.continuation, direction: .request)
                    rules.recordBodyRewriteOutcomes(completion.outcomes, direction: .request)
                    self.recordRuleProvenanceIfChanged(rules.provenance)
                    self.executeContinuation(continuation)
                },
                failed: { [weak self] failure, outcomes in
                    guard let self, !self.terminal, self.attempt == generation else { return }
                    self.failRewrite(failure, outcomes: outcomes, direction: .request)
                })
        } catch BodyRewriteFailure.tooLarge {
            return skip(.bodySkippedTooLarge)
        } catch {
            return skip(.bodySkippedUnavailable)
        }
        bodyGate = rewriter; requestPeek.source = nil
        rewriter.start()
        // The client must not upload until the collection exists.
        if !expectations.isEmpty { sendLocalContinue() }
        updateReading()
        return true
    }

    /// Continues a rule-decided request. Nothing was acquired before; a request breakpoint (T7)
    /// resumes here with its possibly edited continuation.
    func executeContinuation(_ continuation: ExchangeRuleContinuation) {
        downstream.eventLoop.preconditionInEventLoop()
        guard let rules, !terminal else { return }
        switch continuation {
        case .local(let action):
            startLocalResponse(action)
        case .localDirectory(let route):
            startDirectoryResponse(route)
        case .generated(let response):
            startGeneratedResponse(response)
        case .close(let mode, let ruleName):
            closeByRule(mode, ruleName: ruleName)
        case .network(.response, _):
            preconditionFailure("a request continues with a request head")
        case .network(.request(let effective, let fields), _):
            let remapped = effective != rules.originalTarget
            var head = requestHead
            head.method = HTTPMethod(rawValue: effective.method)
            head.uri = effective.pathAndQuery
            head.headers = HTTPHeaders(fields: fields)
            var decision = HTTPRequestDecision(head: head, target: remapped ? EffectiveRequestRoute.requestTarget(effective) : target)
            adoptPeekedRequest(.request(effective, headers: fields))
            decision.allowsReplay = exactRequest == nil
            decision.scheme = effective.scheme
            decision.remapped = remapped
            decision.finalResponseStage = { [weak self] head, resume in
                try self?.applyResponseRules(head, isLocal: false, resume: resume)
            }
            execute(decision)
        }
    }

    /// The same frozen response stage for network and generated original heads.
    /// `isLocal` marks a response the proxy produced itself (Map Local); status rewrite rules only
    /// touch those when they opted in; `decided` is a response point evaluated off the event loop.
    func applyResponseRules(_ original: HTTPResponseHead, isLocal: Bool, decided: Result<ResponseRuleDecision, Error>? = nil,
                            resume: @escaping (HTTPResponseHead) -> Void) throws {
        guard let rules else { resume(original); return }
        if responseReplaced {
            // The rules already ran on the origin's response; this is the proxy's own answer in its place.
            localCollectionBodyAllowed = HTTPMessageTranslation.responseBodyAllowed(requestMethod: requestHead.method, status: original.status)
            resume(original)
            return
        }
        if decided == nil, startResponseOffLoop(original, isLocal: isLocal, resume: resume) { return }
        defer { recordRuleProvenanceIfChanged(rules.provenance) }
        let head = HTTPMessageHead.response(status: Int(original.status.code), reason: original.status.reasonPhrase,
                                            headers: original.headers.fields)
        let response = try decided?.get() ?? rules.prepareResponse(head, isLocalResponse: isLocal, limits: rewriteLimits)
        if bodyGate is ExchangeBodyPeeker { bodyGate = nil }
        if !response.recordedRequestActions.isEmpty {
            // The request is on its way or done: these edit only what the session list shows (spec R8F2-6).
            recorder?.applyRecordedRequestActions(
                response.recordedRequestActions, allowance: rules.allowance,
                cache: connection.environment.rules?.patternCache ?? .shared, limits: rewriteLimits)
        }
        // A delay action of a rule judged here holds the response head back (the response stays staged).
        let generation = attempt
        if scheduleResponseDelay(response.delayMilliseconds, then: { [weak self] in
            guard let self, !self.terminal, self.attempt == generation, self.responseStaging, let rules = self.rules else { return }
            defer { self.recordRuleProvenanceIfChanged(rules.provenance) }
            do { try self.continueResponseRules(response, original: original, head: head, isLocal: isLocal, resume: resume) }
            catch { self.failResponseStage(error) }
        }) { return }
        try continueResponseRules(response, original: original, head: head, isLocal: isLocal, resume: resume)
    }

    /// A rule judged at the response answers in place of the origin: what was staged or peeked of its response is given up
    /// and the response point will not run again on the proxy's own answer. False when the exchange already ended.
    private func discardOriginResponse() -> Bool {
        guard !terminal else { return false }
        responseReplaced = true
        recorder?.discardOriginResponse()
        responsePeek.source?.cancel(); responsePeek.source = nil
        // The lease that delivered the origin's read batch is released next, so its read-complete never arrives: writes
        // of the replacement must not wait for it to flush.
        responseReadBatch = false
        return true
    }

    /// The part of the response point after the delay: a replacement or a close, else the staged head (status, headers),
    /// body rewrites and the response breakpoint.
    private func continueResponseRules(_ response: ResponseRuleDecision, original: HTTPResponseHead, head: HTTPMessageHead,
                                       isLocal: Bool, resume: @escaping (HTTPResponseHead) -> Void) throws {
        guard let rules else { resume(original); return }
        if let replacement = response.replacement {
            switch replacement.kind {
            case .close(let mode):
                // Before any head reached the client: the same close as the request point's, the origin's answer is dropped.
                cancel(reason: HTTPLocalFailureText.ruleClosed(ruleName: rules.ruleName(of: replacement.ruleID)), closing: mode)
            case .generated(let generated):
                guard discardOriginResponse() else { return }
                startGeneratedResponse(generated)
            case .file(let file):
                guard discardOriginResponse() else { return }
                startLocalResponse(file)
            }
            return
        }
        let resume = adoptingPeekedResponse(resume, effective: response.effectiveHead)
        var staged = original
        staged.headers = HTTPHeaders(fields: response.effectiveHead.headers)
        // The standard reason phrase of the new code; framing follows `writeResponseHead`, which
        // compares this status with the upstream one.
        if let code = response.statusRewrite {
            // A reason phrase the rule wrote goes on an HTTP/1.1 status line; HTTP/2 sends the code only.
            // `.custom` keeps the phrase for well-known codes too (`init(statusCode:reasonPhrase:)` would not);
            // it compares equal to the well-known status of the same code.
            staged.status = response.statusReason.map { HTTPResponseStatus.custom(code: UInt(code), reasonPhrase: $0) }
                ?? HTTPResponseStatus(statusCode: code)
        }
        if isLocal {
            localCollectionBodyAllowed = HTTPMessageTranslation.responseBodyAllowed(requestMethod: requestHead.method, status: staged.status)
        }
        guard let mode = response.breakpoint else {
            // The evaluator hands out body steps only without a breakpoint in this direction.
            if response.bodyRewrites.isEmpty { resume(staged) }
            else { startResponseRewrite(response, original: original, staged: staged, resume: resume) }
            return
        }
        guard let coordinator = connection.environment.breakpoints else {
            throw ExchangeRuleFailure.unsupported("responseBreakpoint")
        }
        let now = coordinator.clock.now
        let ticket = BreakpointTicket(
            token: .init(ticketID: .init(), generation: 0, revision: rules.snapshot.revision),
            contextID: connection.contextID, flowID: recorder?.id, direction: .response,
            originalHead: head, effectiveHead: response.effectiveHead,
            routeKind: isLocal ? .local : .network, source: rules.provenance.source,
            mode: mode, state: .pausedHeaders, matchedAt: now,
            deadline: now + .seconds(Int64(coordinator.limits.ticketSeconds)), matches: response.matches)
        let gate = ExchangeBreakpointGate(loop: downstream.eventLoop, coordinator: coordinator,
            io: bodyIO, sourceVersion: HTTPWireVersion(original.version) ?? .http1_1, requestMethod: (effectiveRequestMethod ?? requestHead.method).rawValue,
            changed: { [weak self] in self?.collectionChanged() },
            bodyFailure: { [weak self] in self?.failBody($0, direction: .response) },
            continueBody: { [weak self] in self?.acceptBody($0, direction: .response) },
            pauseChanged: { [weak self, weak connection = self.connection] in
                connection?.breakpointPauseChanged($0)
                self?.recorder?.setPausedAtBreakpoint($0)
            },
            resume: { _ in preconditionFailure("response gate cannot release a request") },
            fail: { [weak self] reason in
                let code: HTTPLocalFailureCode = reason == .expired ? .breakpointTimeout : .breakpointCancelled
                self?.fail(status: reason == .expired ? .gatewayTimeout : .badGateway, code: code,
                           message: HTTPLocalFailureText.breakpoint(code))
            })
        bodyGate = gate
        do {
            if try gate.pauseResponse(ticket: ticket, head: staged, resume: resume) {
                lease?.setResponseReading(gate.canRead)
                bindFlowRemoval(coordinator)
            } else {
                bodyGate = nil
                resume(staged)
            }
        } catch let mutation as HTTPMutationError {
            gate.abandon()
            throw ExchangeRuleFailure.rejected(mutation)
        } catch let failure as ExchangeRuleFailure {
            gate.abandon()
            throw failure
        } catch let error as OwnedFileError {
            gate.abandon()
            failBody(error, direction: .response)
        } catch {
            gate.abandon()
            fail(status: .serviceUnavailable, code: .breakpointCapacity,
                 message: HTTPLocalFailureText.breakpoint(.breakpointCapacity))
        }
    }

    /// The engineering limits of this run's exact bodies (the body rewrite cap and deadline).
    var rewriteLimits: RulesLimits { connection.environment.bodyRuntime?.limits ?? RulesLimits() }

    /// Collects the response body for the rule steps through the same staging route as a
    /// full-body breakpoint, then continues on the exact-body path with the rewritten (or original)
    /// bytes. Nothing is collected when the body cannot be held: the response streams untouched
    /// and the rules say why.
    private func startResponseRewrite(_ decision: ResponseRuleDecision, original: HTTPResponseHead, staged: HTTPResponseHead,
                                      resume: @escaping (HTTPResponseHead) -> Void) {
        guard let rules else { resume(staged); return }
        func skip(_ code: RuleOutcomeCode) {
            rules.recordBodyRewriteOutcomes(decision.bodyRewrites.map { RuleOutcome(ruleID: $0.ruleID, code: code, actionIndex: $0.actionIndex) },
                                           direction: .response)
            recordRuleProvenanceIfChanged(rules.provenance)
            resume(staged)
        }
        guard let io = bodyIO else { skip(.bodySkippedUnavailable); return }
        // The wire length of what arrives, as a full-body breakpoint counts it.
        var expected = original.headers.first(name: "content-length").flatMap(Int64.init)
        if !HTTPMessageTranslation.responseBodyAllowed(requestMethod: effectiveRequestMethod ?? requestHead.method, status: original.status) {
            expected = 0
        }
        let generation = attempt
        let rewriter: ExchangeBodyRewriter
        do {
            rewriter = try ExchangeBodyRewriter(
                loop: downstream.eventLoop, io: io, limits: io.limits, cache: connection.environment.rules?.patternCache ?? .shared,
                direction: .response, steps: decision.bodyRewrites, effectiveHead: decision.effectiveHead,
                expectedLength: expected, sourceVersion: HTTPWireVersion(original.version) ?? .http1_1,
                collected: responsePeek.source,
                changed: { [weak self] in self?.collectionChanged() },
                completed: { [weak self] completion in
                    guard let self, !self.terminal, self.attempt == generation, let rules = self.rules else {
                        completion.continuation.source.cancel(); return
                    }
                    self.acceptBody(completion.continuation, direction: .response)
                    rules.recordBodyRewriteOutcomes(completion.outcomes, direction: .response)
                    self.recordRuleProvenanceIfChanged(rules.provenance)
                    resume(staged)
                },
                failed: { [weak self] failure, outcomes in
                    guard let self, !self.terminal, self.attempt == generation else { return }
                    self.failRewrite(failure, outcomes: outcomes, direction: .response)
                })
        } catch BodyRewriteFailure.tooLarge {
            skip(.bodySkippedTooLarge); return
        } catch {
            skip(.bodySkippedUnavailable); return
        }
        bodyGate = rewriter; responsePeek.source = nil
        rewriter.start()
        lease?.setResponseReading(rewriter.canRead)
    }

    /// Abandons the body gate. A rewrite that has not settled its rules yet leaves
    /// `bodySkippedAborted` for each of them instead of the provisional `applied`; a rule
    /// already settled (completed, or `rejected` by its own failure page) keeps its outcome.
    private func dropBodyGate() {
        if let rewriter = bodyGate as? ExchangeBodyRewriter, let direction = rewriter.direction, let rules {
            rules.recordBodyRewriteOutcomes(
                rewriter.steps.map { RuleOutcome(ruleID: $0.ruleID, code: .bodySkippedAborted, actionIndex: $0.actionIndex) },
                direction: direction)
            recordRuleProvenanceIfChanged(rules.provenance)
        }
        bodyGate?.abandon(); bodyGate = nil
    }

    /// A collection that cannot finish ends the exchange locally: the bytes already taken can
    /// neither be forwarded as they were nor be rewritten.
    private func failRewrite(_ failure: BodyRewriteFailure, outcomes: [RuleOutcome], direction: HTTPMessageDirection) {
        if let rules {
            rules.recordBodyRewriteOutcomes(outcomes, direction: direction)
            recordRuleProvenanceIfChanged(rules.provenance)
        }
        let code: HTTPLocalFailureCode
        let status: HTTPResponseStatus
        switch failure {
        case .tooLarge:
            code = .rewriteBodyTooLarge
            status = direction == .request ? .payloadTooLarge : .badGateway
        case .timedOut:
            code = .rewriteBodyTimeout
            status = .gatewayTimeout
        case .unavailable, .cancelled:
            code = .rewriteBodyUnavailable
            status = .badGateway
        }
        fail(status: status, code: code,
             message: HTTPLocalFailureText.rewrite(code, limitMiB: rewriteLimits.rewriteBodyBytes / 1_048_576))
    }

    private func bindFlowRemoval(_ coordinator: BreakpointCoordinator) {
        guard let id = recorder?.id else { return }
        let store = connection.environment.recording.store
        if !flowRemovalRegistered {
            flowRemovalRegistered = true
            if store.registerFlowRemoval(flowID: id, action: { [weak coordinator] in
                coordinator?.revoke(flowIDs: [id], reason: .cancelled)
            }) { return }
        } else if store.flow(id) != nil { return }
        // The flow may have vanished before this response pause. Revoke synchronously;
        // network cleanup remains a generation-checked owner-loop delivery.
        coordinator.revoke(flowIDs: [id], reason: .cancelled)
    }

    private func recordRuleProvenanceIfChanged(_ provenance: FlowProvenance) {
        if let rules { recorder?.apply(rules.drainAnnotations()) }
        guard let matches = provenance.ruleMatches, matches.total > 0 || !matches.outcomes.isEmpty,
              provenance != lastRecordedRuleProvenance, let recorder else { return }
        recorder.setProvenance(provenance)
        lastRecordedRuleProvenance = provenance
    }

    /// Fixes the forwarded head, target and route, builds the replay copy from them, and starts
    /// upstream acquisition. Request parts received since admission stay pending behind the head.
    func execute(_ original: HTTPRequestDecision) {
        downstream.eventLoop.preconditionInEventLoop()
        precondition(route == nil && effectiveTarget == nil, "an exchange executes exactly once")
        var decision = original
        effectiveTarget = decision.target
        effectiveRequestMethod = decision.head.method
        if trafficAdmission.appliesNoCaching {
            do { try applyNoCaching(to: &decision) } catch {
                failRule(error)
                return
            }
        }
        let scheme = decision.scheme ?? self.scheme
        do {
            route = try EffectiveRequestRoute.resolve(decision.target, scheme: scheme, upgrade: upgrade,
                                                      remapped: decision.remapped || policy.rejectsListener,
                                                      listeners: connection.environment.listeners, http1Only: policy.http1Only)
        } catch {
            failRule(error)
            return
        }
        finalResponseStage = decision.finalResponseStage
        guard !terminal, forwardsRequest else { return }
        if decision.remapped {
            recorder?.setUpstreamOrigin(scheme: scheme, host: decision.target.host, port: decision.target.port)
        }
        if decision.allowsReplay, !localContinueSent, policy.retry == .existingProxyPolicy {
            var replay = RequestReplayBuffer(head: decision.head)
            for part in pending { replay.append(part) }
            self.replay = replay
        }
        appendPending(.head(decision.head))
        guard !terminal, forwardsRequest else { return }
        pending.insert(pending.removeLast(), at: 0)
        acquire(forceFresh: false)
    }

    /// The No Caching tool (spec D7/D8). The request side is the last edit before anything is sent
    /// (after rules and breakpoints), so no validator leaves; the response side runs first in the
    /// final response stage, so response rules and breakpoints may still override it. An Upgrade
    /// candidate and its answer are never touched. A header block the edits cannot be applied to
    /// fails the exchange locally (both sides) rather than forwarding validators the tool exists to
    /// remove. The recorded boundary snapshots keep the original headers.
    private func applyNoCaching(to decision: inout HTTPRequestDecision) throws {
        let upgradeCandidate = HTTPMutationValidator.isUpgradeCandidate(decision.head.headers.fields)
        guard !upgradeCandidate else { return }
        // The same code and text as any rejected rule edit (`rule.rejected`).
        func apply(_ fields: [HeaderField], _ direction: HTTPMessageDirection, status: Int? = nil) throws -> HTTPHeaders {
            do {
                return HTTPHeaders(fields: try NoCaching.apply(fields, direction: direction, status: status,
                                                               upgradeCandidate: upgradeCandidate))
            } catch let error as HTTPMutationError { throw ExchangeRuleFailure.rejected(error) }
        }
        decision.head.headers = try apply(decision.head.headers.fields, .request)
        let inner = decision.finalResponseStage
        decision.finalResponseStage = { head, resume in
            var edited = head
            edited.headers = try apply(head.headers.fields, .response, status: Int(head.status.code))
            try inner(edited, resume)
        }
        recorder?.mergeTools { $0.noCaching = true }
    }

    func receiveRequest(_ part: HTTPServerRequestPart) {
        guard !terminal else { return }
        switch part {
        case .head: assertionFailure("request head already supplied at exchange creation")
        case .body(let buffer):
            recorder?.recordRequestBody(buffer)
            if bodyGate?.direction == .request, bodyGate?.isCollecting == true { bodyGate?.append(buffer) }
            else if forwardsRequest { send(.body(.byteBuffer(buffer))) }
        case .end(let trailers):
            guard !requestComplete else { return }
            requestComplete = true
            recorder?.finishRequest(trailers: trailers)
            if bodyGate?.direction == .request, bodyGate?.isCollecting == true { bodyGate?.finishBody(trailers: trailers?.fields ?? []) }
            else if forwardsRequest { send(.end(trailers)) }
            finishIfDone()
        }
        updateReading()
    }

    func requestReadStarted() { requestReadBatch = true }
    func requestReadComplete() {
        requestReadBatch = false
        lease?.flush()
    }
    func responseReadStarted() { responseReadBatch = true }
    func responseReadComplete() {
        responseReadBatch = false
        downstream.flush()
    }

    private func acquire(forceFresh: Bool) {
        guard !terminal, forwardsRequest else { return }
        guard let route else { preconditionFailure("acquisition before execute") }
        let generation = attempt
        let sink = AttemptSink(exchange: self, attempt: generation)
        let acquisition = connection.upstreamPool.acquire(route: route, forceFresh: forceFresh, responseSink: sink)
        self.acquisition = acquisition
        acquisition.futureResult.assumeIsolated().whenComplete { [weak self] result in
            guard let self, !self.terminal, self.attempt == generation else {
                if case .success(let lease) = result { lease.release(reusable: false) }
                return
            }
            self.acquisition = nil
            switch result {
            case .success(let lease):
                self.lease = lease
                lease.setResponseReading(self.downstream.isWritable)
                self.sendPending()
                self.updateReading()
            case .failure(let error): self.upstreamClosed(error: error, attempt: generation)
            }
        }
    }

    private func send(_ part: HTTPClientRequestPart) {
        replay?.append(part)
        if let lease, connection.forwardingAllowed {
            write(part, lease: lease)
            if !requestReadBatch || part.isEnd { lease.flush() }
        } else { appendPending(part) }
    }
    private func appendPending(_ part: HTTPClientRequestPart) {
        let count: Int
        var owned = part
        switch part {
        case .head(let head): count = head.uri.utf8.count + head.method.rawValue.utf8.count + Self.headerBytes(head.headers)
        case .body(.byteBuffer(let buffer)):
            count = buffer.readableBytes
            if count == 0 { return }
            owned = .body(.byteBuffer(ByteBuffer(bytes: buffer.readableBytesView)))
        case .body(.fileRegion(let region)): count = region.readableBytes
        case .end(let trailers): count = trailers.map(Self.headerBytes) ?? 0
        }
        guard count <= connection.limits.pendingBytesPerExchange - pendingBytes,
              connection.reservePendingBytes(count) else {
            unavailable(reason: UpstreamConnector.describe(HTTPTransportError.pendingBytesExceeded), code: .pendingBytesExceeded)
            return
        }
        pendingBytes += count
        pending.append(owned)
    }
    private static func headerBytes(_ headers: HTTPHeaders) -> Int {
        var total = 0
        for field in headers {
            for value in [32, field.name.utf8.count, field.value.utf8.count] {
                let sum = total.addingReportingOverflow(value)
                guard !sum.overflow else { return Int.max }
                total = sum.partialValue
            }
        }
        return total
    }
    private func clearPending() {
        pending.removeAll()
        connection.releasePendingBytes(pendingBytes - responsePendingBytes)
        pendingBytes = responsePendingBytes
    }
    private func sendPending() {
        guard !terminal, connection.forwardingAllowed, let lease else { return }
        if pending.isEmpty { pumpExact(direction: .request); return }
        let parts = pending
        clearPending()
        for part in parts {
            guard !terminal, self.lease === lease else { return }
            write(part, lease: lease)
        }
        if !requestReadBatch || parts.contains(where: { $0.isEnd }) { lease.flush() }
        pumpExact(direction: .request)
    }
    @discardableResult
    private func write(_ part: HTTPClientRequestPart, lease: UpstreamLease) -> EventLoopFuture<Void> {
        let translated: HTTPClientRequestPart
        do {
            switch part {
            case .head(let head):
                guard let source = HTTPWireVersion(head.version) else { throw HTTPTranslationError.invalidFraming }
                let destination = lease.version == .http2 ? .http2 : (source == .http2 ? lease.version : source)
                guard let effectiveTarget else { preconditionFailure("request written before execute") }
                var plan: FramingPlan?
                if let exactRequest {
                    let effective = HTTPMessageHead.request(HTTPMessageTarget(scheme: route?.scheme ?? scheme, host: effectiveTarget.host,
                        port: effectiveTarget.port, method: head.method.rawValue, pathAndQuery: head.uri), headers: head.headers.fields)
                    plan = try BreakpointFraming.plan(original: exactRequest.original, edited: effective, body: exactRequest.descriptor,
                        source: exactRequest.version, target: destination, requestMethod: head.method.rawValue)
                    exactRequestPlan = plan
                    recordBodyOutcomes(plan!, direction: .request)
                }
                var head = try HTTPMessageTranslation.request(head, target: effectiveTarget, source: source, destination: destination,
                    endStream: requestInitialEndStream, framingPlan: plan)
                // Protocol handling follows edit validation: Expect is protected from user edits,
                // but our completed local handshake must never be sent upstream a second time.
                if localContinueSent { head.headers.remove(name: "expect") }
                upstreamRequestDestination = destination
                requestIsChunked = try HTTPMessageTranslation.transferCodings(head.headers).last == "chunked"
                translated = .head(head)
            case .body: translated = part
            case .end(let fields):
                let destination = upstreamRequestDestination ?? lease.version
                let trailers = try fields.flatMap {
                    try HTTPMessageTranslation.trailers($0, destination: destination, bodyAllowed: destination == .http2 || requestIsChunked)
                }
                translated = .end(trailers)
            }
        } catch {
            fail(status: .badGateway, code: .requestUntranslatable, message: UpstreamConnector.describe(error))
            return downstream.eventLoop.makeFailedFuture(error)
        }
        let generation = attempt
        let version = upstreamRequestDestination
        let recorder = recorder
        let stream = exactRequestStream
        let result = lease.write(translated)
        result.assumeIsolated().whenComplete { [weak self, weak lease] result in
            // The write future is the only proof the writer accepted these bytes (not that the
            // origin application received them); a head the writer never accepted is not recorded as
            // sent. The recorder outlives a settled exchange, so late settlements are still recorded.
            if (self?.attempt ?? generation) == generation {
                var failed = false
                if case .failure = result { failed = true }
                let streamID = (lease as? HTTP2UpstreamLease)?.streamID.map { Int($0) }
                recorder?.recordUpstreamWrite(translated, version: version, streamID: streamID, succeeded: !failed, bodyStream: stream)
                if !failed, case .head = translated { self?.upstreamRequestSubmitted = true }
            }
            guard let self, case .failure(let error) = result, let lease, !self.terminal, !self.responseComplete,
                  self.attempt == generation, self.lease === lease else { return }
            lease.cancel(error: error)
        }
        return result
    }

    /// `bodyStream` is the entity the response body bytes belong to; `records` is false for
    /// interim 1xx heads, which are written as-is and are not a message boundary.
    private func writeDownstream(
        _ part: HTTPServerResponsePart, bodyStream: UUID? = nil, records: Bool = true
    ) -> EventLoopFuture<Void> {
        guard !terminal else { return downstream.eventLoop.makeFailedFuture(HTTPTransportError.closed) }
        pendingDownstreamWrites += 1
        let generation = attempt
        let result = downstream.write(part)
        let recorder = records ? recorder : nil
        result.assumeIsolated().whenComplete { [weak self] result in
            // Recorded even when the exchange already settled (a failure page is written after it).
            if let recorder {
                var failed = false
                if case .failure = result { failed = true }
                recorder.recordDownstreamWrite(part, bodyStream: bodyStream, succeeded: !failed)
            }
            guard let self else { return }
            self.pendingDownstreamWrites -= 1
            guard !self.terminal, self.attempt == generation else { return }
            switch result {
            case .failure(let error): self.cancel(reason: UpstreamConnector.describe(error))
            case .success: self.completeDeliveredResponse()
            }
        }
        // END/local/out-of-batch and early responses must never depend on another read event.
        if !responseReadBatch || part.isEnd || !requestComplete { downstream.flush() }
        return result
    }

    /// A local informational response has the normal writer's settlement/flush guarantees, but
    /// neither an origin response nor a final capture. HEAD alone keeps an h2 stream open.
    func sendLocalContinue() {
        downstream.eventLoop.preconditionInEventLoop()
        guard !terminal, !localContinueSent else { return }
        localContinueSent = true
        anyResponseHead = true
        replay = nil
        let version: HTTPVersion = downstream.version == .http2 ? .http2 : requestHead.version
        lastClientWrite = writeDownstream(.head(.init(version: version, status: .continue)), records: false)
        downstream.flush()
    }

    func receiveResponse(_ part: HTTPClientResponsePart, attempt: Int) {
        guard !terminal, self.attempt == attempt, !responseComplete, let lease else { return }
        if case .body(let buffer) = part { recorder?.recordResponseBody(buffer) }
        if responseStaging, bodyGate?.direction == .response, bodyGate?.isCollecting == true {
            switch part {
            case .body(let bytes): bodyGate?.append(bytes)
            case .end(let trailers):
                collectedResponseTrailers = trailers
                recorder?.finishOriginalResponse(trailers: trailers?.fields ?? [])
                bodyGate?.finishBody(trailers: trailers?.fields ?? [])
            case .head: failBody(OwnedFileError(.lengthMismatch), direction: .response)
            }
            return
        }
        if responseStaging {
            appendResponsePending(part)
            return
        }
        deliverResponse(part, lease: lease)
    }

    private func deliverResponse(_ part: HTTPClientResponsePart, lease: UpstreamLease) {
        switch part {
        case .head(let upstreamHead):
            anyResponseHead = true
            replay = nil
            let interim = (100..<200).contains(upstreamHead.status.code) && upstreamHead.status != .switchingProtocols
            // Trailers replace the lease's current HTTP/2 metadata while a final head is
            // paused. Capture this head's framing fact before entering the response stage.
            let endStream = (lease as? HTTP2UpstreamLease)?.responseHeaders?.endStream ?? false
            if interim {
                if localContinueSent, upstreamHead.status == .continue { return }
                writeResponseHead(upstreamHead, original: upstreamHead, interim: true, endStream: endStream, lease: lease)
                return
            }
            recorder?.recordResponseHead(upstreamHead, streamID: (lease as? HTTP2UpstreamLease)?.streamID.map { Int($0) })
            recorder?.setConnectionInfo(factsState.record(lease))
            upstreamFinalHeadReceived = true
            responseStaging = true
            let generation = self.attempt
            do {
                try finalResponseStage(upstreamHead) { [weak self] staged in
                    guard let self, !self.terminal, self.attempt == generation, self.responseStaging else { return }
                    self.responseStaging = false
                    self.writeResponseHead(staged, original: upstreamHead, interim: false, endStream: endStream, lease: lease)
                    if self.exactResponse != nil { self.pumpExact(direction: .response) }
                    else { self.drainResponsePending() }
                    if !self.terminal { self.lease?.setResponseReading(self.exactResponse == nil && self.downstream.isWritable) }
                }
            } catch { failResponseStage(error) }
        case .body(let buffer):
            if responseBodyAllowed {
                lastClientWrite = writeDownstream(.body(.byteBuffer(buffer)), bodyStream: recorder?.responseStream)
            }
            if !downstream.isWritable { lease.setResponseReading(false) }
        case .end(let trailers):
            if upgrading {
                downstream.flush()
                guard !terminal else { return }
                let pending = pendingWebSocket.take()
                let observation: ObservationHandle?
                if let pending, let recorder, let coordinator = connection.environment.webSockets,
                   downstream is HTTP1DownstreamResponseWriter {
                    observation = pending.begin(flowID: recorder.id, coordinator: coordinator, eventLoop: downstream.eventLoop)
                } else { observation = nil }
                recorder?.complete(trailers: trailers, note: ProxyHandler.upgradeNote)
                self.lease = nil
                settle()
                if let writer = downstream as? HTTP1DownstreamResponseWriter { writer.upgrade(lease: lease, observation: observation) }
                else { lease.cancel(error: nil); downstream.abort(HTTPTransportError.closed) }
                return
            }
            do {
                let destination = downstreamResponseDestination ?? downstream.version
                let fields = try trailers.flatMap {
                    try HTTPMessageTranslation.trailers($0, destination: destination,
                        bodyAllowed: responseBodyAllowed && (destination == .http2 || responseIsChunked))
                }
                lastClientWrite = writeDownstream(.end(fields))
            } catch {
                lease.cancel(error: error)
                return
            }
            guard !terminal else { return }
            responseComplete = true
            if requestComplete {
                // Retain ordinary completion and the lease until every submitted write
                // settles, including an earlier body still pending when END succeeds.
                responseAwaitingWrites = true
                responseTrailers = trailers
                completeDeliveredResponse()
            } else {
                recorder?.complete(trailers: trailers)
                self.lease = nil
                lease.release(reusable: false)
                replay = nil
                forwardsRequest = false
                clearPending()
                if keepAlive { scheduleUploadDisposal(); updateReading() }
                else {
                    recorder?.finishRequest(complete: false)
                    settle()
                    finishDownstream(discardUpload: true)
                }
            }
        }
    }

    private func writeResponseHead(_ head: HTTPResponseHead, original upstreamHead: HTTPResponseHead,
                                   interim: Bool, endStream: Bool, lease: UpstreamLease) {
        guard !terminal else { return }
        if !interim {
            if upstreamHead.status == .switchingProtocols { pendingWebSocket?.captureResponse(head) }
            else { pendingWebSocket = nil }
        }
        let translated: HTTPResponseHead
        do {
            guard let source = HTTPWireVersion(upstreamHead.version) else { throw HTTPTranslationError.invalidFraming }
            let destination: HTTPWireVersion = downstream.version == .http2 ? .http2
                : (requestHead.version == .http1_0 ? .http1_0 : (source == .http2 ? downstream.version : source))
            var plan: FramingPlan?
            if let exactResponse, !interim {
                plan = try BreakpointFraming.plan(original: exactResponse.original,
                    edited: .response(status: Int(head.status.code), reason: head.status.reasonPhrase, headers: head.headers.fields),
                    body: exactResponse.descriptor, source: exactResponse.version, target: destination, requestMethod: requestHead.method.rawValue)
                exactResponsePlan = plan
                recordBodyOutcomes(plan!, direction: .response)
            }
            translated = try HTTPMessageTranslation.response(head, requestMethod: requestHead.method, source: source,
                destination: destination, endStream: endStream,
                bodyLength: !interim
                    && !HTTPMessageTranslation.responseBodyAllowed(requestMethod: effectiveRequestMethod ?? requestHead.method, status: upstreamHead.status)
                    && HTTPMessageTranslation.responseBodyAllowed(requestMethod: requestHead.method, status: head.status) ? 0 : nil, framingPlan: plan)
            if !interim {
                downstreamResponseDestination = destination
                responseBodyAllowed = HTTPMessageTranslation.responseBodyAllowed(requestMethod: requestHead.method, status: head.status)
                    && HTTPMessageTranslation.responseBodyAllowed(requestMethod: effectiveRequestMethod ?? requestHead.method, status: upstreamHead.status)
                responseIsChunked = try HTTPMessageTranslation.transferCodings(translated.headers).last == "chunked"
            }
        } catch {
            fail(status: .badGateway, code: .responseUntranslatable, message: UpstreamConnector.describe(error))
            return
        }
        if interim {
            lastClientWrite = writeDownstream(.head(translated), records: false)
            return
        }
        if upstreamHead.status == .switchingProtocols { upgrading = true }
        else {
            keepAlive = keepAlive && (downstream.version == .http2 || translated.isKeepAlive)
            upstreamReusable = lease.channel.isActive && HTTPMessageTranslation.responseIsPersistent(upstreamHead, requestMethod: effectiveRequestMethod ?? requestHead.method)
        }
        // A detached HTTP/1 adapter cannot submit the head: nothing is recorded as sent.
        lastClientWrite = writeDownstream(.head(translated), records: attached)
    }

    private func appendResponsePending(_ part: HTTPClientResponsePart) {
        guard !responseEndQueued else { return } // END owns the last queue slot.
        let owned: HTTPClientResponsePart
        let count: Int
        switch part {
        case .head:
            fail(status: .badGateway, code: .responseUntranslatable, message: UpstreamConnector.describe(HTTPTranslationError.invalidFraming))
            return
        case .body(let buffer):
            guard buffer.readableBytes > 0 else { return }
            count = buffer.readableBytes
            owned = part
        case .end(let fields):
            count = max(1, fields.map(Self.headerBytes) ?? 0)
            owned = part
        }
        guard count <= connection.limits.pendingBytesPerExchange - pendingBytes,
              connection.reservePendingBytes(count) else {
            unavailable(reason: UpstreamConnector.describe(HTTPTransportError.pendingBytesExceeded), code: .pendingBytesExceeded)
            return
        }
        pendingBytes += count
        responsePendingBytes += count
        if case .body(let buffer) = owned {
            responsePending.append((.body(ByteBuffer(bytes: buffer.readableBytesView)), count))
        } else { responsePending.append((owned, count)) }
        if case .end = part { responseEndQueued = true }
    }

    private func drainResponsePending() {
        let parts = responsePending
        clearResponsePending()
        for (part, _) in parts {
            guard !terminal, let lease else { return }
            deliverResponse(part, lease: lease)
        }
    }

    private func clearResponsePending() {
        responsePending.removeAll()
        connection.releasePendingBytes(responsePendingBytes)
        pendingBytes -= responsePendingBytes
        responsePendingBytes = 0
        responseEndQueued = false
    }

    func upstreamClosed(error: Error?, attempt: Int) {
        guard !terminal, self.attempt == attempt, !responseComplete else { return }
        if responseStaging, (responseEndQueued || bodyGate?.receivedEnd == true), error == nil {
            // An ordinary FIN after a fully decoded END cannot discard the paused response.
            // Retain the lease object for ordered delivery, but never return its socket to the pool.
            upstreamReusable = false
            return
        }
        if responseStaging, bodyGate?.isCollecting == true {
            failBody(error ?? OwnedFileError(.lengthMismatch), direction: .response)
            return
        }
        if let selfTarget = error as? ProxySelfTargetError {
            failRule(ExchangeRuleFailure.selfTarget(selfTarget.authority))
            return
        }
        let oldLease = lease
        lease = nil
        let reason: String
        let tlsFailure: Bool
        if error is TLSHandshakeTimeout {
            reason = ProxyHandler.upstreamHandshakeTimeout
            tlsFailure = true
        } else if let certificateReason = error.flatMap(TLSInterception.certificateFailureReason) {
            reason = L10n.format("proxyFailure.upstreamCertificateFailed", certificateReason)
            tlsFailure = true
        } else {
            reason = error.map { UpstreamConnector.describe($0) } ?? L10n.string("proxyFailure.upstreamClosedEarly")
            tlsFailure = false
        }
        if anyResponseHead {
            recorder?.fail(reason)
            closeDownstreamBoundaryAfterLastWrite()
            settle()
            keepAlive = false
            if let writer = downstream as? HTTP1DownstreamResponseWriter {
                // A decoder failure may close the upstream before readComplete. Flush
                // the already submitted response writes before waiting for their delivery.
                downstream.flush()
                writer.finish(keepAlive: false, after: lastClientWrite, discardUpload: false)
            } else { downstream.abort(error ?? HTTPTransportError.closed) }
        } else if (oldLease?.version == .http1_0 || oldLease?.version == .http1_1), oldLease?.wasReused == true, self.attempt == 0, requestComplete,
                  downstream.isActive, Self.isRetryableTransportFailure(error), let parts = replay?.replayParts {
            self.attempt = 1
            replay = nil
            clearPending()
            // Replay has its independently bounded consuming buffer (1 MiB); forwarding it
            // after acquisition avoids copying it into the smaller pending-upload budget.
            pending = parts
            oldLease?.cancel(error: nil)
            acquire(forceFresh: true)
        } else if tlsFailure { fail(status: .badGateway, code: .upstreamTLSFailed, message: reason) }
        else { unavailable(reason: reason, code: .upstreamUnreachable) }
    }

    static func isRetryableTransportFailure(_ error: Error?) -> Bool {
        guard let error else { return true }
        if let channelError = error as? ChannelError {
            switch channelError {
            case .eof, .ioOnClosedChannel, .outputClosed: return true
            default: return false
            }
        }
        if let error = error as? IOError { return error.errnoCode == ECONNRESET || error.errnoCode == EPIPE }
        return false
    }
    func upstreamWritabilityChanged(_ writable: Bool, attempt: Int) {
        guard !terminal, self.attempt == attempt else { return }
        pumpExact(direction: .request)
        updateReading()
    }
    func downstreamWritabilityChanged(_ writable: Bool) {
        guard !terminal else { return }
        // A rewrite collecting the response reads on its own pace, independent of the client's
        // writability (nothing is written downstream until it completes). A breakpoint keeps the
        // reviewed behavior.
        if responseStaging, let gate = bodyGate as? ExchangeBodyRewriter, gate.direction == .response, gate.isCollecting {
            lease?.setResponseReading(gate.canRead)
        } else {
            lease?.setResponseReading(writable && !responseStaging)
        }
        if writable { readLocalResponse(); pumpExact(direction: .response) }
    }
    func updateReading() {
        guard !terminal else { return }
        if let gate = bodyGate, gate.direction == .request, gate.isCollecting {
            downstream.setRequestReading(gate.canRead); return
        }
        downstream.setRequestReading(!forwardsRequest || requestComplete || (connection.forwardingAllowed && lease?.isWritable == true))
    }
    func collectionChanged() {
        guard !terminal, let gate = bodyGate else { return }
        feedPeeked(to: gate)
        if gate.isCollecting {
            if gate.direction == .request, !pending.isEmpty {
                let parts = pending; clearPending()
                for part in parts {
                    switch part {
                    case .body(.byteBuffer(let bytes)): gate.append(bytes)
                    case .end(let fields): gate.finishBody(trailers: fields?.fields ?? [])
                    default: break
                    }
                }
            } else if gate.direction == .response, !responsePending.isEmpty {
                let parts = responsePending; clearResponsePending()
                for (part, _) in parts {
                    switch part {
                    case .body(let bytes): gate.append(bytes)
                    case .end(let fields):
                        collectedResponseTrailers = fields
                        recorder?.finishOriginalResponse(trailers: fields?.fields ?? [])
                        gate.finishBody(trailers: fields?.fields ?? [])
                    default: break
                    }
                }
            }
        }
        updateReading()
        if gate.direction == .response {
            lease?.setResponseReading(gate.canRead)
            if gate.canRead { readLocalResponse() }
        }
    }
    func failBody(_ error: Error, direction: HTTPMessageDirection) {
        if let gate = bodyGate, gate.direction == direction, gate.isCollecting {
            gate.failBodyCallback(error, operation: nil)
            return
        }
        let large = (error as? OwnedFileError)?.code == .fileTooLarge
        let code: HTTPLocalFailureCode = large ? .breakpointBodyTooLarge : .breakpointBodyUnavailable
        fail(status: large && direction == .request ? .payloadTooLarge : .badGateway, code: code,
             message: HTTPLocalFailureText.breakpoint(code))
    }
    func acceptBody(_ body: BreakpointBodyContinuation, direction: HTTPMessageDirection) {
        if direction == .request {
            exactRequest = body
            exactRequestStream = body.bytesChanged ? recorder?.makeBodyStream() : recorder?.requestStream
            clearPending()
        } else {
            exactResponse = body
            exactResponseStream = body.bytesChanged ? recorder?.makeBodyStream() : (localGeneratedStream ?? recorder?.responseStream)
            clearResponsePending()
        }
    }
    private func recordBodyOutcomes(_ plan: FramingPlan, direction: HTTPMessageDirection) {
        guard let rules else { return }
        var outcomes = plan.outcomes
        if direction == .response, exactResponse?.ignoredBodyEdit == true, !outcomes.contains(.breakpointBodyIgnored) {
            outcomes.append(.breakpointBodyIgnored)
        }
        rules.recordBodyOutcomes(outcomes, direction: direction)
        recordRuleProvenanceIfChanged(rules.provenance)
    }
    /// A single bounded read followed by a settled write. The source and staging charge stay
    /// alive across the writer future; cancellation only releases after that future settles.
    private func pumpExact(direction: HTTPMessageDirection) {
        guard !terminal else { return }
        let request = direction == .request
        guard let body = request ? exactRequest : exactResponse else { return }
        if request {
            guard !exactRequestBusy, connection.forwardingAllowed, let lease, lease.isWritable, upstreamRequestDestination != nil else { return }
        } else {
            guard !exactResponseBusy, !responseStaging, downstream.isWritable, downstreamResponseDestination != nil else { return }
        }
        let offset = request ? exactRequestOffset : exactResponseOffset
        let plan = request ? exactRequestPlan : exactResponsePlan
        if offset == body.source.size || plan?.bodyAllowed == false {
            if request {
                exactRequestBusy = true
                guard let lease else { return }
                let write = write(.end(plan.map { HTTPHeaders(fields: $0.trailers) }), lease: lease)
                lease.flush()
                exactRequestWrite = write
                let stream = exactRequestStream
                write.assumeIsolated().whenComplete { [weak self] _ in
                    if let stream { self?.recorder?.finishExactStream(stream) }
                    body.source.cancel(); self?.exactRequest = nil
                }
            } else {
                exactResponseBusy = true
                if let stream = exactResponseStream { recorder?.finishExactStream(stream) }
                if let lease { deliverResponse(.end(plan.map { HTTPHeaders(fields: $0.trailers) }), lease: lease) }
                else { endLocalResponse() }
                exactResponseWrite = lastClientWrite
            }
            return
        }
        guard let io = bodyIO else { failBody(OwnedFileError(.cancelled), direction: direction); return }
        let charge: OwnedFileReservation
        do { charge = try io.budgets.reserve(category: .io, bytes: 2 * min(65_536, body.source.size - offset)) }
        catch { failBody(error, direction: direction); return }
        if request { exactRequestBusy = true } else { exactResponseBusy = true }
        let promise = downstream.eventLoop.makePromise(of: Data.self)
        let task = promise.completeWithTask { try await body.source.read(offset: offset, maxBytes: 65_536) }
        if request { exactRequestTask = task } else { exactResponseTask = task }
        promise.futureResult.assumeIsolated().whenComplete { [weak self] result in
            guard let self, !self.terminal else { charge.release(); body.source.cancel(); return }
            switch result {
            case .failure(let error): charge.release(); self.failBody(error, direction: direction)
            case .success(let data):
                guard !data.isEmpty else { charge.release(); self.failBody(OwnedFileError(.shortRead), direction: direction); return }
                let bytes = ByteBuffer(bytes: data)
                let stream = request ? self.exactRequestStream : self.exactResponseStream
                if body.bytesChanged, let stream { self.recorder?.captureBody(stream: stream, bytes: bytes) }
                let write: EventLoopFuture<Void>
                if request {
                    guard let lease = self.lease else { charge.release(); body.source.cancel(); return }
                    write = self.write(.body(.byteBuffer(bytes)), lease: lease); lease.flush()
                    self.exactRequestOffset += Int64(data.count)
                } else {
                    write = self.writeDownstream(.body(.byteBuffer(bytes)), bodyStream: stream)
                    self.lastClientWrite = write
                    self.exactResponseOffset += Int64(data.count)
                    self.downstream.flush()
                }
                if request { self.exactRequestWrite = write } else { self.exactResponseWrite = write }
                write.assumeIsolated().whenComplete { [weak self] result in
                    charge.release()
                    guard let self, !self.terminal else { body.source.cancel(); return }
                    if request { self.exactRequestBusy = false; self.exactRequestWrite = nil }
                    else { self.exactResponseBusy = false; self.exactResponseWrite = nil }
                    if case .success = result { self.pumpExact(direction: direction) }
                }
            }
        }
    }
    private func releaseExactBodies() {
        releaseRequestPeek()
        exactRequestTask?.cancel(); exactResponseTask?.cancel()
        if let source = exactRequest?.source {
            if let write = exactRequestWrite { write.whenComplete { _ in source.cancel() } } else { source.cancel() }
        }
        if let source = exactResponse?.source {
            if let write = exactResponseWrite { write.whenComplete { _ in source.cancel() } } else { source.cancel() }
        }
        exactRequest = nil; exactResponse = nil
    }
    private var attached: Bool { (downstream as? HTTP1DownstreamResponseWriter)?.isAttached ?? true }
    /// The upstream cannot be used: always a 502 naming the effective upstream authority.
    private func unavailable(reason: String, code: HTTPLocalFailureCode) {
        let authority = (effectiveTarget ?? target).authority
        fail(status: .badGateway, code: code, message: HTTPLocalFailureText.unreachable(authority: authority, reason: reason),
             reason: reason)
    }
    /// A failure of the response stage, at once or after a delay: rule failures keep their own code, anything else is an
    /// untranslatable response.
    func failResponseStage(_ error: Error) {
        if let failure = error as? ExchangeRuleFailure { failRule(failure) }
        else { fail(status: .badGateway, code: .responseUntranslatable, message: UpstreamConnector.describe(error)) }
    }
    /// A rule could not be carried out: one local 502 with the rule's code.
    private func failRule(_ error: Error) {
        if let failure = error as? ExchangeRuleFailure {
            fail(status: .badGateway, code: failure.code, message: failure.message)
        } else if let selfTarget = error as? ProxySelfTargetError {
            failRule(ExchangeRuleFailure.selfTarget(selfTarget.authority))
        } else {
            fail(status: .badGateway, code: .requestUntranslatable, message: UpstreamConnector.describe(error))
        }
    }
    /// Ends the exchange with a local final response when no final head was written yet:
    /// abandons the upload, the lease and any acquisition, then writes `status` with `message`.
    /// `reason` is the recorded failure (default `message`).
    func fail(status: HTTPResponseStatus, code: HTTPLocalFailureCode, message: String, reason: String? = nil) {
        downstream.eventLoop.preconditionInEventLoop()
        if localResponseClaimed, localSource != nil, !localHeadWritten, !terminal {
            dropBodyGate()
            responseStaging = false
            clearResponsePending()
            releaseLocalSource()
        } else {
            guard claimLocalResponse() else { return }
        }
        writeLocalFailure(status: status, code: code, message: message, reason: reason)
    }
    private func writeLocalFailure(status: HTTPResponseStatus, code: HTTPLocalFailureCode, message: String, reason: String? = nil) {
        localFailure = code
        localFailureMessage = message
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        let page = HTTPLocalFailureText.page(productName: connection.environment.configuration.productName, message: message)
        writeLocalResponse(status: status, headers: headers, body: ByteBuffer(string: page), failure: reason ?? message)
    }
    /// Takes the response side for a final response the proxy produces itself: abandons the
    /// upload, the replay copy, the lease and any acquisition. False (and nothing changes) when the
    /// exchange ended or a final response was already chosen.
    func claimLocalResponse() -> Bool {
        guard !terminal, !responseComplete, !localResponseClaimed else { return false }
        cancelDirectoryResolution()
        dropBodyGate()
        releaseExactBodies()
        responseStaging = false
        clearResponsePending()
        replay = nil
        forwardsRequest = false
        clearPending()
        let old = lease
        lease = nil
        old?.release(reusable: false)
        let pendingAcquisition = acquisition
        acquisition = nil
        // Invalidate before cancellation callbacks, which may synchronously attempt failure again.
        localResponseClaimed = true
        pendingAcquisition?.cancel()
        return true
    }
    /// Writes a final response the proxy produced itself, with no upstream lease; call it only
    /// after `claimLocalResponse()` succeeded. The head is framed for the downstream version
    /// (HTTP/1.0 clients get an HTTP/1.0 head), HEAD/1xx/204/304 carry no payload, and afterwards
    /// the exchange finishes or disposes of an unfinished upload exactly as after an early upstream
    /// response. `headers` must not contain framing fields. The generated response is recorded
    /// before anything is written; `failure` also fails the flow. A detached HTTP/1 adapter cannot
    /// take a head: the exchange then only records the failure and settles.
    private func writeLocalResponse(status: HTTPResponseStatus, headers fields: HTTPHeaders, body: ByteBuffer?,
                                    failure: String?) {
        precondition(localResponseClaimed && !forwardsRequest && lease == nil && pending.isEmpty,
                     "a local response needs claimLocalResponse()")
        responseComplete = true
        guard attached else {
            if let failure { recorder?.fail(failure) }
            settle()
            return
        }
        let bytes = body ?? ByteBuffer()
        var headers = fields
        if !(100..<200).contains(status.code), status != .noContent {
            headers.add(name: "Content-Length", value: String(bytes.readableBytes))
        }
        if downstream.version != .http2 {
            if !keepAlive { headers.add(name: "Connection", value: "close") }
            else if requestHead.version == .http1_0 { headers.add(name: "Connection", value: "keep-alive") }
        }
        let destination: HTTPWireVersion = downstream.version == .http2 ? .http2 : (requestHead.version == .http1_0 ? .http1_0 : .http1_1)
        let version: HTTPVersion = destination == .http2 ? .http2 : (destination == .http1_0 ? .http1_0 : .http1_1)
        downstreamResponseDestination = destination
        responseBodyAllowed = HTTPMessageTranslation.responseBodyAllowed(requestMethod: requestHead.method, status: status)
        responseIsChunked = false
        let head = HTTPResponseHead(version: version, status: status, headers: headers)
        let generated = recorder?.recordGeneratedResponse(status: status, headers: headers, body: body)
        if let failure { recorder?.fail(failure) }
        _ = writeDownstream(.head(head))
        if responseBodyAllowed, bytes.readableBytes > 0 { _ = writeDownstream(.body(.byteBuffer(bytes)), bodyStream: generated) }
        lastClientWrite = writeDownstream(.end(nil))
        finishIfDone()
        if !requestComplete { scheduleUploadDisposal() }
        updateReading()
    }
    // MARK: Owned local representations

    private func startLocalResponse(_ action: MapLocalAction) {
        guard let assets = connection.environment.assets else {
            failRule(ExchangeRuleFailure.unsupported("mapLocal"))
            return
        }
        guard claimLocalResponse() else { return }
        let source = LocalResponseSource(action: action, assets: assets, hooks: connection.environment.localResponseHooks)
        localSource = source
        prepareLocalResponse(source, generatedID: action.assetID)
        updateReading()
    }

    /// Resolves a directory route off the loop before claiming anything (spec section 4). Only the
    /// result decides: a file or a local 404/405 claims the response, a missing file with the
    /// `network` policy continues as if no Map rule matched, an unusable directory is the 502.
    private func startDirectoryResponse(_ route: DirectoryRoute) {
        guard let resolver = connection.environment.directories else {
            failRule(ExchangeRuleFailure.unsupported("mapLocalDirectory"))
            return
        }
        precondition(directoryResolution == nil, "a request continues exactly once")
        let generation = attempt
        let hooks = connection.environment.localResponseHooks
        let promise = downstream.eventLoop.makePromise(of: DirectoryResolution.self)
        // The resolver never observes cancellation: whatever it returns comes back here.
        let task = promise.completeWithTask {
            let resolution = await resolver.resolve(route)
            await hooks?.afterDirectoryResolve?(resolution)
            return resolution
        }
        directoryResolution = task
        promise.futureResult.assumeIsolated().whenComplete { [weak self] result in
            guard case .success(let resolution) = result else { return }
            guard let self, !self.terminal, !self.localResponseClaimed, self.attempt == generation,
                  self.directoryResolution == task else {
                Self.discard(resolution)
                return
            }
            self.directoryResolution = nil
            self.finishDirectoryResolution(resolution, route: route)
        }
        updateReading()
    }

    private func finishDirectoryResolution(_ resolution: DirectoryResolution, route: DirectoryRoute) {
        downstream.eventLoop.preconditionInEventLoop()
        switch resolution {
        case .file(let lease, let contentType):
            guard claimLocalResponse() else { lease.cancel(); return }
            var headers: [HeaderField] = []
            if !route.action.headers.contains(where: { $0.name.lowercased() == "content-type" }) {
                headers.append(HeaderField(name: "Content-Type", value: contentType))
            }
            headers += route.action.headers
            startOwnedLocalResponse(LocalResponseSource(preResolved: lease, status: 200, headers: headers,
                                                        hooks: connection.environment.localResponseHooks))
        case .notFound where route.action.missing == .network, .methodNotAllowed where route.action.missing == .network:
            guard let rules else { return }
            let next: ExchangeRuleContinuation
            do { next = try rules.networkFallback() } catch { failRule(error); return }
            executeContinuation(next)
        case .notFound, .unsafe:
            // An unsafe path is always this 404 and never reaches the network (spec F8).
            startEmptyLocalResponse(status: 404, headers: [HeaderField(name: "X-ProxyWoman-Map-Local", value: "not-found")])
        case .methodNotAllowed:
            startEmptyLocalResponse(status: 405, headers: [HeaderField(name: "Allow", value: "GET, HEAD"),
                                                          HeaderField(name: "X-ProxyWoman-Map-Local", value: "method-not-allowed")])
        case .unavailable:
            fail(status: .badGateway, code: .ruleLocalAssetUnavailable, message: HTTPLocalFailureText.localAssetUnavailable())
        }
    }

    private func startEmptyLocalResponse(status: Int, headers: [HeaderField]) {
        guard claimLocalResponse() else { return }
        startOwnedLocalResponse(LocalResponseSource(emptyStatus: status, headers: headers,
                                                    hooks: connection.environment.localResponseHooks))
    }

    /// After `claimLocalResponse()`: the directory source goes through the same prepare/response
    /// rules/read path as an asset, recorded under the directory rule's ID.
    func startOwnedLocalResponse(_ source: LocalResponseSource) {
        localSource = source
        prepareLocalResponse(source, generatedID: rules?.directoryRuleID)
        updateReading()
    }

    private func cancelDirectoryResolution() {
        directoryResolution?.cancel()
        directoryResolution = nil
    }

    /// A resolution nobody serves: its lease (if any) is released now, not at deinit.
    private static func discard(_ resolution: DirectoryResolution) {
        if case .file(let lease, _) = resolution { lease.cancel() }
    }

    private func ownsLocal(_ source: LocalResponseSource, generation: Int) -> Bool {
        downstream.eventLoop.preconditionInEventLoop()
        return !terminal && attempt == generation && localSource === source
    }

    /// `generatedID` is recorded as the generated response's source: the asset or the directory rule.
    private func prepareLocalResponse(_ source: LocalResponseSource, generatedID: UUID?) {
        guard !terminal, localSource === source, !localBusy else { return }
        localBusy = true
        let generation = attempt
        let promise = downstream.eventLoop.makePromise(of: LocalResponseSource.Prepared.self)
        localOperation = promise.completeWithTask { try await source.prepare() }
        promise.futureResult.assumeIsolated().whenComplete { [weak self] result in
            guard let self, self.ownsLocal(source, generation: generation) else { source.cancel(); return }
            self.localOperation = nil
            self.localBusy = false
            switch result {
            case .failure(let error): self.localSourceFailed(error, source: source, step: .prepare(generatedID))
            case .success(let prepared):
                self.localRetryDeadline = nil
                do {
                    guard case .response(let status, let reason, let fields) = prepared.head else { preconditionFailure("local response head") }
                    var original = HTTPResponseHead(version: .http1_1, status: .init(statusCode: status, reasonPhrase: reason ?? ""),
                                                    headers: HTTPHeaders(fields: fields))
                    if status != 204, !(100..<200).contains(status) {
                        original.headers.replaceOrAdd(name: "Content-Length", value: String(prepared.length))
                    }
                    self.localCollectionBodyAllowed = HTTPMessageTranslation.responseBodyAllowed(requestMethod: self.requestHead.method, status: original.status)
                    self.localGeneratedStream = self.recorder?.beginGeneratedResponse(status: original.status, headers: original.headers,
                        assetID: generatedID, representationLength: UInt64(prepared.length), projectsBody: source.isGenerated)
                    self.responseStaging = true
                    try self.applyResponseRules(original, isLocal: true) { [weak self] staged in
                        guard let self, self.ownsLocal(source, generation: generation), self.responseStaging else { return }
                        self.responseStaging = false
                        do {
                            let destination: HTTPWireVersion = self.downstream.version == .http2 ? .http2
                                : (self.requestHead.version == .http1_0 ? .http1_0 : .http1_1)
                            var plan: FramingPlan?
                            if let exact = self.exactResponse {
                                plan = try BreakpointFraming.plan(original: exact.original,
                                    edited: .response(status: Int(staged.status.code), reason: staged.status.reasonPhrase, headers: staged.headers.fields),
                                    body: exact.descriptor, source: exact.version, target: destination, requestMethod: self.requestHead.method.rawValue)
                                self.exactResponsePlan = plan
                                self.recordBodyOutcomes(plan!, direction: .response)
                            }
                            var head = try HTTPMessageTranslation.response(staged, requestMethod: self.requestHead.method, source: .http1_1,
                                destination: destination, endStream: false, bodyLength: UInt64(prepared.length), framingPlan: plan)
                            if destination != .http2 {
                                if !self.keepAlive { head.headers.replaceOrAdd(name: "Connection", value: "close") }
                                else if destination == .http1_0 { head.headers.replaceOrAdd(name: "Connection", value: "keep-alive") }
                            }
                            guard self.attached else { self.cancel(reason: HTTPLocalFailureText.localAssetUnavailable()); return }
                            self.downstreamResponseDestination = destination
                            self.responseBodyAllowed = HTTPMessageTranslation.responseBodyAllowed(requestMethod: self.requestHead.method, status: head.status)
                            self.responseIsChunked = false
                            self.anyResponseHead = true
                            self.localHeadWritten = true
                            self.localBusy = true
                            let write = self.writeDownstream(.head(head))
                            self.lastClientWrite = write
                            write.assumeIsolated().whenSuccess { [weak self] in
                                guard let self, self.ownsLocal(source, generation: generation) else { return }
                                self.localBusy = false
                                if self.exactResponse != nil { self.pumpExact(direction: .response) }
                                else if self.responseBodyAllowed { self.readLocalResponse() }
                                else { self.endLocalResponse() }
                            }
                        } catch { self.localSourceFailed(error, source: source, step: .prepare(generatedID)) }
                    }
                } catch { self.localSourceFailed(error, source: source, step: .prepare(generatedID)) }
            }
        }
    }

    private func readLocalResponse() {
        let collecting = bodyGate?.direction == .response && bodyGate?.isCollecting == true
        guard !terminal, !responseComplete, (collecting || (!responseStaging && localHeadWritten)), let source = localSource,
              !localCollectionEnded, exactResponse == nil, responsePeek.source == nil,
              !localBusy, localRetry == nil, downstream.isWritable else { return }
        if collecting && !localCollectionBodyAllowed {
            localCollectionEnded = true
            bodyGate?.finishBody(trailers: [])
            return
        }
        localBusy = true
        let generation = attempt
        let promise = downstream.eventLoop.makePromise(of: Data?.self)
        localOperation = promise.completeWithTask { try await source.readNext() }
        promise.futureResult.assumeIsolated().whenComplete { [weak self] result in
            guard let self, self.ownsLocal(source, generation: generation) else { source.cancel(); return }
            self.localOperation = nil
            self.localBusy = false
            switch result {
            case .failure(let error): self.localSourceFailed(error, source: source)
            case .success(let data):
                self.localRetryDeadline = nil
                guard let data else {
                    if collecting {
                        self.localCollectionEnded = true
                        self.bodyGate?.finishBody(trailers: [])
                    } else { self.endLocalResponse() }
                    return
                }
                let bytes = ByteBuffer(bytes: data)
                if let stream = self.localGeneratedStream { self.recorder?.recordGeneratedBody(bytes, stream: stream) }
                if collecting { self.bodyGate?.append(bytes); return }
                self.localBusy = true
                let write = self.writeDownstream(.body(.byteBuffer(bytes)), bodyStream: self.localGeneratedStream)
                self.lastClientWrite = write
                write.assumeIsolated().whenSuccess { [weak self] in
                    guard let self, self.ownsLocal(source, generation: generation) else { return }
                    self.localBusy = false
                    self.readLocalResponse()
                }
            }
        }
    }

    private func endLocalResponse() {
        guard !terminal, !responseComplete else { return }
        // Arm completion after submission: a synchronous writer may settle before assignment.
        lastClientWrite = writeDownstream(.end(nil))
        guard !terminal else { return }
        responseComplete = true
        responseAwaitingWrites = true
        completeDeliveredResponse()
    }

    /// Which local operation failed, and so which one a capacity retry repeats.
    private enum LocalStep {
        case prepare(UUID?)
        case read
    }

    /// Capacity is transient. One deadline belongs to this blocked operation, never each retry.
    private func localSourceFailed(_ error: Error, source: LocalResponseSource, step: LocalStep = .read) {
        guard !terminal, localSource === source else { return }
        if let owned = error as? OwnedFileError, owned.code == .capacityExceeded {
            let deadline = localRetryDeadline ?? (NIODeadline.now() + .seconds(2))
            localRetryDeadline = deadline
            if NIODeadline.now() < deadline {
                let generation = attempt
                localRetry = downstream.eventLoop.assumeIsolated().scheduleTask(in: .milliseconds(10)) { [weak self] in
                    guard let self, self.ownsLocal(source, generation: generation) else { return }
                    self.localRetry = nil
                    switch step {
                    case .prepare(let generatedID): self.prepareLocalResponse(source, generatedID: generatedID)
                    case .read: self.readLocalResponse()
                    }
                }
                return
            }
        }
        if !localHeadWritten {
            releaseLocalSource()
            if let failure = error as? ExchangeRuleFailure {
                writeLocalFailure(status: .badGateway, code: failure.code, message: failure.message)
            } else {
                writeLocalFailure(status: .badGateway, code: .ruleLocalAssetUnavailable,
                                  message: HTTPLocalFailureText.localAssetUnavailable())
            }
        } else {
            recorder?.fail(HTTPLocalFailureText.localAssetUnavailable())
            closeDownstreamBoundaryAfterLastWrite()
            settle()
            keepAlive = false
            if let writer = downstream as? HTTP1DownstreamResponseWriter {
                downstream.flush()
                writer.finish(keepAlive: false, after: lastClientWrite, discardUpload: !requestComplete)
            } else { downstream.abort(error) }
        }
    }

    private func releaseLocalSource() {
        localRetry?.cancel(); localRetry = nil
        localRetryDeadline = nil
        localOperation?.cancel(); localOperation = nil
        localSource?.cancel(); localSource = nil
        localBusy = false
    }

    private func scheduleUploadDisposal() {
        guard downstream.version == .http2, uploadDisposalTimer == nil, !terminal else { return }
        uploadDisposalTimer = downstream.eventLoop.assumeIsolated().scheduleTask(in: connection.limits.drainTimeout) { [weak self] in
            guard let self, !self.terminal else { return }
            self.recorder?.finishRequest(complete: false)
            self.settle()
            self.downstream.abort(HTTPTransportError.cancelled)
        }
    }
    private func completeDeliveredResponse() {
        guard !terminal, responseAwaitingWrites, pendingDownstreamWrites == 0 else { return }
        if localSource != nil {
            responseAwaitingWrites = false
            if let stream = localGeneratedStream { recorder?.finishGeneratedResponse(stream: stream, complete: true) }
            recorder?.complete()
            releaseLocalSource()
            exactResponse?.source.cancel(); exactResponse = nil
            if requestComplete { finishIfDone() }
            else if downstream.version == .http2 { scheduleUploadDisposal(); updateReading() }
            else {
                recorder?.finishRequest(complete: false)
                settle()
                finishDownstream(discardUpload: true)
            }
            return
        }
        guard let lease else { return }
        responseAwaitingWrites = false
        recorder?.complete(trailers: collectedResponseTrailers ?? responseTrailers)
        exactResponse?.source.cancel(); exactResponse = nil
        responseTrailers = nil
        self.lease = nil
        lease.release(reusable: upstreamReusable)
        finishIfDone()
    }
    /// A virtual client stops submitting a request body that no longer goes anywhere: a final
    /// response was completely delivered and the upload is not forwarded any more, so the unsent
    /// rest is disposed of now (the HTTP/2 upload-disposal timer's job, without its grace) and the
    /// exchange finishes. False when that is not the case; nothing changes then.
    @discardableResult
    func disposeUnneededUpload() -> Bool {
        downstream.eventLoop.preconditionInEventLoop()
        guard !terminal, responseComplete, !requestComplete, !forwardsRequest, !upgrading,
              !responseAwaitingWrites, pendingDownstreamWrites == 0 else { return false }
        recorder?.finishRequest(complete: false)
        settle()
        finishDownstream(discardUpload: true)
        return true
    }
    private func finishIfDone() {
        guard !terminal, requestComplete, responseComplete, !responseAwaitingWrites else { return }
        settle()
        finishDownstream(discardUpload: false)
    }
    private func finishDownstream(discardUpload: Bool) {
        if let writer = downstream as? HTTP1DownstreamResponseWriter {
            writer.finish(keepAlive: keepAlive, after: lastClientWrite, discardUpload: discardUpload)
        } else { downstream.responseFinished() }
    }
    /// A terminal path while response writes may still be queued: once the last one settles, the
    /// downstream boundary can receive nothing more, so it ends (a no-op if its END already did).
    private func closeDownstreamBoundaryAfterLastWrite() {
        guard let recorder else { return }
        lastClientWrite?.assumeIsolated().whenComplete { _ in
            recorder.finishMessage(boundary: recorder.clientResponseBoundary, trailers: [], complete: false)
        }
    }
    private func settle() {
        dropBodyGate()
        releaseExactBodies()
        responseStaging = false
        clearResponsePending()
        // Whatever of the request was not accepted by now never will be: an early response, a
        // failure or a cancel ends the exchange. A boundary that already finished keeps its outcome.
        // This is deliberately biased to partiallySent: an END write still queued when the response
        // completes is reported as not fully sent even if it settles successfully a moment later.
        recorder?.finishMessage(boundary: .upstreamRequest, trailers: [], complete: false)
        pendingWebSocket = nil
        terminal = true
        cancelDirectoryResolution()
        releaseLocalSource()
        responseAwaitingWrites = false
        responseTrailers = nil
        uploadDisposalTimer?.cancel(); uploadDisposalTimer = nil
        ruleDelay.cancel()
        responseDelay.cancel()
        replay = nil
        clearPending()
        connection.unregister(self)
    }
    /// `closing` replaces the abort with a rule's close of the response side (D15).
    func cancel(reason: String, closing: RulesEngine.CloseMode? = nil) {
        guard !terminal else { return }
        if closing != nil { localFailure = .ruleClosed; localFailureMessage = reason }
        recorder?.fail(reason)
        closeDownstreamBoundaryAfterLastWrite()
        settle()
        acquisition?.cancel()
        acquisition = nil
        let old = lease
        lease = nil
        old?.release(reusable: false)
        if let closing { downstream.closeConnection(closing) } else { downstream.abort(HTTPTransportError.cancelled) }
    }
}

private final class AttemptSink: UpstreamResponseSink {
    private weak var exchange: HTTPExchange?
    private let attempt: Int
    init(exchange: HTTPExchange, attempt: Int) { self.exchange = exchange; self.attempt = attempt }
    func receiveResponse(_ part: HTTPClientResponsePart) { exchange?.receiveResponse(part, attempt: attempt) }
    func responseReadStarted() { exchange?.responseReadStarted() }
    func responseReadComplete() { exchange?.responseReadComplete() }
    func upstreamWritabilityChanged(_ writable: Bool) { exchange?.upstreamWritabilityChanged(writable, attempt: attempt) }
    func upstreamClosed(error: Error?) { exchange?.upstreamClosed(error: error, attempt: attempt) }
}

private extension HTTPPart {
    var isEnd: Bool { if case .end = self { return true }; return false }
}
