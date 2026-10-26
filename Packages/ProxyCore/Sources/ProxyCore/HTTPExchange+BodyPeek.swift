import FlowStore
import Foundation
import NIOCore
import NIOHTTP1
import RulesEngine

/// The body peek (D12, D13): collecting the request or the response body for conditions, evaluating the
/// rule point off the event loop, and handing the collected body on to whatever continues the message,
/// so its bytes are read from the wire exactly once.
extension HTTPExchange {
    /// The peeked request body, from its collection until a continuation takes it or it is given up.
    struct RequestPeek {
        /// The request point of this exchange took the peek path (evaluated off the event loop).
        var started = false
        /// The complete collected body; owned here until a continuation takes it.
        var source: ExactBodySource?
        var version: HTTPWireVersion = .http1_1
        /// How much of `source` was fed to a gate that collects the body again (a full-body breakpoint).
        var fed: Int64 = 0
        var feeding: Task<Void, Never>?
    }

    /// The provider's pattern cache: its breakers and body budget.
    private var patternCache: PatternCache { connection.environment.rules?.patternCache ?? .shared }

    /// Called by `execute()` before the request point. When a rule that reads the request body could
    /// match this request (`RuleEvaluator.requestMayNeedBody`, judged on the head; never for an
    /// upgrade), the request point runs off the event loop: with the body when it can be peeked
    /// (collected first), otherwise with what its head already says (no body, or why it is not read).
    /// Returns false when the ordinary synchronous path runs; nothing changed then, and the request
    /// streams (and may be replayed) exactly as without such rules.
    func startRequestPeek() -> Bool {
        guard let rules, !terminal, !upgrade, !requestPeek.started, rules.snapshot.requirements.requestBody else { return false }
        if case .block = trafficAdmission.action { return false }
        downstream.eventLoop.preconditionInEventLoop()
        guard RuleEvaluator.requestMayNeedBody(rules.originalRequest, snapshot: rules.snapshot, facts: rules.facts(),
                                               cache: patternCache) else { return false }
        requestPeek.started = true
        let wire = requestHead.headers
        requestPeek.version = HTTPWireVersion(requestHead.version) ?? .http1_1
        let noBody = requestPeek.version == .http2
            ? requestInitialEndStream : !(wire.contains(name: "transfer-encoding") || wire.contains(name: "content-length"))
        switch BodyPeekRules.classify(headers: wire.fields, knownLength: nil, isHeadOrNoBody: noBody, limits: rewriteLimits) {
        case .empty: evaluatePeekedRequest(.empty)
        case .skip(let code): evaluatePeekedRequest(.skipped(code))
        case .collect: if !collectRequestPeek() { evaluatePeekedRequest(.skipped(.bodySkippedUnavailable)) }
        }
        return true
    }

    /// Starts the peek gate. False when the body cannot be held (no body runtime, an `Expect` other than
    /// `100-continue`, no spool budget): nothing was taken from the client then.
    private func collectRequestPeek() -> Bool {
        let wire = requestHead.headers
        let expectations = wire["expect"]
        guard expectations.allSatisfy({ value in
            value.split(separator: ",", omittingEmptySubsequences: false).allSatisfy {
                $0.trimmingCharacters(in: .whitespaces).lowercased() == "100-continue"
            }
        }), let io = bodyIO,
            let length = wire.first(name: "content-length").flatMap({ Int64($0.trimmingCharacters(in: .whitespaces)) })
        else { return false }
        let generation = attempt
        let peeker: ExchangeBodyPeeker
        do {
            peeker = try ExchangeBodyPeeker(
                loop: downstream.eventLoop, io: io, limits: io.limits, expectedLength: length, headers: wire.fields,
                changed: { [weak self] in self?.collectionChanged() },
                completed: { [weak self] source, peek in
                    guard let self, !self.terminal, self.attempt == generation else {
                        source.cancel(); self?.recorder?.releasePublication(); return
                    }
                    if self.bodyGate is ExchangeBodyPeeker { self.bodyGate = nil }
                    self.requestPeek.source = source
                    self.evaluatePeekedRequest(peek)
                },
                failed: { [weak self] failure in
                    guard let self, !self.terminal, self.attempt == generation else { return }
                    let taken = (self.bodyGate as? ExchangeBodyPeeker)?.received ?? 0
                    if self.bodyGate is ExchangeBodyPeeker { self.bodyGate = nil }
                    guard taken == 0 else {
                        // Bytes already taken from the client can no longer be forwarded as they arrived.
                        let code: HTTPLocalFailureCode = failure == .timedOut ? .peekBodyTimeout : .peekBodyUnavailable
                        self.fail(status: failure == .timedOut ? .gatewayTimeout : .badGateway, code: code,
                                  message: HTTPLocalFailureText.peek(code))
                        self.recorder?.releasePublication()
                        return
                    }
                    // Nothing was taken: the request goes on with its body unknown and streams as usual.
                    self.updateReading()
                    self.evaluatePeekedRequest(.skipped(.bodySkippedUnavailable))
                })
        } catch {
            return false
        }
        bodyGate = peeker
        peeker.start()
        // The client must not upload until the collection exists.
        if !expectations.isEmpty { sendLocalContinue() }
        updateReading()
        return true
    }

    /// Evaluates the request point in a task and continues `execute` with its decision on the loop. The
    /// publication hold (R2) is released there, or here when the exchange ended meanwhile.
    private func evaluatePeekedRequest(_ peek: BodyPeek) {
        guard let rules else { return }
        let recorder = self.recorder
        rules.prepareRequestOffLoop(
            peek: peek, limits: rewriteLimits, cache: patternCache, on: downstream.eventLoop
        ).assumeIsolated().whenComplete { [weak self] result in
            guard let self, !self.terminal else { recorder?.releasePublication(); return }
            self.execute(decided: result)
        }
    }

    /// Called by the response stage before the response point. The response point runs off the event
    /// loop when the request body was peeked (its rules may read that body, ruling M2) or when a rule
    /// that reads the response body could match this response, judged on its head
    /// (`RuleEvaluator.responseMayNeedBody`; never for an upgrade). In the second case the body is
    /// collected first when `classify` says so, and then handed on: the response bytes reach the client
    /// as they were, or as the body rewrites made them. The response stays staged and unread meanwhile.
    /// Returns false when the response point runs synchronously.
    func startResponseOffLoop(_ original: HTTPResponseHead, isLocal: Bool, resume: @escaping (HTTPResponseHead) -> Void) -> Bool {
        guard let rules, !terminal else { return false }
        let head = HTTPMessageHead.response(status: Int(original.status.code), reason: original.status.reasonPhrase,
                                            headers: original.headers.fields)
        let wantsBody = rules.snapshot.requirements.responseBody && !upgrade && original.status != .switchingProtocols
            && rules.responseMayNeedBody(head, cache: patternCache)
        guard requestPeek.started || wantsBody else { return false }
        responsePeek.started = wantsBody
        guard wantsBody else { evaluateResponse(head, original: original, isLocal: isLocal, peek: .notCollected, resume: resume); return true }
        let noBody = !HTTPMessageTranslation.responseBodyAllowed(requestMethod: effectiveRequestMethod ?? requestHead.method, status: original.status)
        switch BodyPeekRules.classify(headers: original.headers.fields, knownLength: nil, isHeadOrNoBody: noBody, limits: rewriteLimits) {
        case .empty: evaluateResponse(head, original: original, isLocal: isLocal, peek: .empty, resume: resume)
        case .skip(let code): evaluateResponse(head, original: original, isLocal: isLocal, peek: .skipped(code), resume: resume)
        case .collect:
            if !collectResponsePeek(head, original: original, isLocal: isLocal, resume: resume) {
                evaluateResponse(head, original: original, isLocal: isLocal, peek: .skipped(.bodySkippedUnavailable), resume: resume)
            }
        }
        return true
    }

    /// Starts the response peek gate; the body then arrives through `receiveResponse` or the local
    /// source like any collected response body. False when it cannot be held (no body runtime, no spool
    /// budget): nothing was taken then.
    private func collectResponsePeek(_ head: HTTPMessageHead, original: HTTPResponseHead, isLocal: Bool,
                                     resume: @escaping (HTTPResponseHead) -> Void) -> Bool {
        guard let io = bodyIO,
              let length = original.headers.first(name: "content-length").flatMap({ Int64($0.trimmingCharacters(in: .whitespaces)) })
        else { return false }
        let generation = attempt
        responsePeek.version = HTTPWireVersion(original.version) ?? .http1_1
        let peeker: ExchangeBodyPeeker
        do {
            peeker = try ExchangeBodyPeeker(
                loop: downstream.eventLoop, io: io, limits: io.limits, expectedLength: length, headers: original.headers.fields,
                direction: .response,
                changed: { [weak self] in self?.collectionChanged() },
                completed: { [weak self] source, peek in
                    guard let self, !self.terminal, self.attempt == generation else { source.cancel(); return }
                    // The resolved gate stays as `bodyGate` (it has seen the END) until the decision is applied.
                    self.responsePeek.source = source
                    self.evaluateResponse(head, original: original, isLocal: isLocal, peek: peek, resume: resume)
                },
                failed: { [weak self] failure in
                    guard let self, !self.terminal, self.attempt == generation else { return }
                    let taken = (self.bodyGate as? ExchangeBodyPeeker)?.received ?? 0
                    guard taken == 0 else {
                        // Bytes already taken from the origin can no longer be forwarded as they arrived.
                        let code: HTTPLocalFailureCode = failure == .timedOut ? .peekResponseBodyTimeout : .peekResponseBodyUnavailable
                        self.fail(status: failure == .timedOut ? .gatewayTimeout : .badGateway, code: code,
                                  message: HTTPLocalFailureText.peek(code))
                        return
                    }
                    // Nothing was taken: the response goes on with its body unknown and streams as usual.
                    if self.bodyGate is ExchangeBodyPeeker { self.bodyGate = nil }
                    self.evaluateResponse(head, original: original, isLocal: isLocal, peek: .skipped(.bodySkippedUnavailable), resume: resume)
                })
        } catch {
            return false
        }
        bodyGate = peeker
        peeker.start()
        lease?.setResponseReading(peeker.canRead)
        return true
    }

    /// Evaluates the response point in a task and continues the stage with its decision on the loop.
    private func evaluateResponse(_ head: HTTPMessageHead, original: HTTPResponseHead, isLocal: Bool, peek: BodyPeek,
                                  resume: @escaping (HTTPResponseHead) -> Void) {
        guard let rules else { return }
        let generation = attempt
        lease?.setResponseReading(false)
        rules.prepareResponseOffLoop(head, isLocalResponse: isLocal, limits: rewriteLimits, cache: patternCache, responseBody: peek,
                                     on: downstream.eventLoop).assumeIsolated().whenComplete { [weak self] result in
            guard let self, !self.terminal, self.attempt == generation, self.responseStaging else { return }
            do { try self.applyResponseRules(original, isLocal: isLocal, decided: result, resume: resume) }
            catch { self.failResponseStage(error) }
        }
    }

    /// `resume` for a response whose body was peeked: whatever continues the response first takes the
    /// peeked body as its exact body (unless a gate already made a new one), as for a request.
    func adoptingPeekedResponse(_ resume: @escaping (HTTPResponseHead) -> Void, effective: HTTPMessageHead)
        -> (HTTPResponseHead) -> Void {
        guard responsePeek.source != nil else { return resume }
        return { [weak self] staged in
            self?.adoptPeekedResponse(effective)
            resume(staged)
        }
    }

    private func adoptPeekedResponse(_ head: HTTPMessageHead) {
        guard let source = responsePeek.source else { return }
        responsePeek.source = nil
        guard !terminal, exactResponse == nil else { source.cancel(); return }
        let descriptor = HTTPBodyDescriptor(length: source.size, complete: true, changed: false, trailers: source.trailers)
        acceptBody(BreakpointBodyContinuation(source: source, original: head, descriptor: descriptor, bytesChanged: false,
                                              version: responsePeek.version), direction: .response)
    }

    /// The request continues on the network: the peeked body becomes its exact body, unless a gate
    /// already handed it a new one (a full-body breakpoint's copy), when the peeked one is given up.
    func adoptPeekedRequest(_ head: HTTPMessageHead) {
        guard let source = requestPeek.source else { return }
        requestPeek.source = nil
        guard exactRequest == nil else { source.cancel(); return }
        let descriptor = HTTPBodyDescriptor(length: source.size, complete: true, changed: false, trailers: source.trailers)
        acceptBody(BreakpointBodyContinuation(source: source, original: head, descriptor: descriptor, bytesChanged: false,
                                              version: requestPeek.version), direction: .request)
    }

    /// A gate that collects the body again after a peek (a full-body breakpoint) is fed from the
    /// peeked body, one bounded read at a time, never from the wire: the client sent it once. Called
    /// whenever a gate changes; a no-op unless such a gate can take the next part.
    func feedPeeked(to gate: any ExchangeBodyGate) {
        guard let direction = gate.direction else { return }
        let slot = direction == .request ? \HTTPExchange.requestPeek : \HTTPExchange.responsePeek
        guard gate.isCollecting, !gate.receivedEnd, gate.canRead, self[keyPath: slot].feeding == nil,
              let source = self[keyPath: slot].source, let io = bodyIO else { return }
        let offset = self[keyPath: slot].fed
        guard offset < source.size else {
            self[keyPath: slot].source = nil
            gate.finishBody(trailers: source.trailers)
            source.cancel()
            return
        }
        let count = min(65_536, max(1, io.limits.ioChunkBytes), Int(source.size - offset))
        let charge: OwnedFileReservation
        do { charge = try io.budgets.reserve(category: .io, bytes: Int64(count)) }
        catch { failBody(error, direction: direction); return }
        let promise = downstream.eventLoop.makePromise(of: Data.self)
        self[keyPath: slot].feeding = promise.completeWithTask { try await source.read(offset: offset, maxBytes: count) }
        promise.futureResult.assumeIsolated().whenComplete { [weak self] result in
            defer { charge.release() }
            // Given up meanwhile (`releaseRequestPeek`): nothing more is fed.
            guard let self, self[keyPath: slot].feeding != nil, self[keyPath: slot].source != nil else { return }
            self[keyPath: slot].feeding = nil
            guard let gate = self.bodyGate, gate.direction == direction, gate.isCollecting else { return }
            switch result {
            case .failure(let error): self.failBody(error, direction: direction)
            case .success(let data) where data.isEmpty: self.failBody(OwnedFileError(.shortRead), direction: direction)
            case .success(let data):
                self[keyPath: slot].fed += Int64(data.count)
                gate.append(ByteBuffer(bytes: data))
            }
        }
    }

    /// Gives up the peeked body and an evaluation not started yet (a local route, a failure, the end of the exchange).
    func releaseRequestPeek() {
        rules?.cancelOffLoop()
        requestPeek.feeding?.cancel(); requestPeek.feeding = nil
        requestPeek.source?.cancel(); requestPeek.source = nil
        responsePeek.feeding?.cancel(); responsePeek.feeding = nil
        responsePeek.source?.cancel(); responsePeek.source = nil
    }
}
