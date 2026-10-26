import FlowStore
import Foundation
import NIOCore
import NIOHTTP1
import RulesEngine

/// Confined to the exchange loop. One reservation and absolute timer cover headers, collection,
/// editing and replacement I/O; no late callback can republish an abandoned ticket.
final class ExchangeBreakpointGate: ExchangeBodyGate {
    enum BodyCallback: Sendable { case collectionAppend, collectionFinish, replacementWrite, replacementFinish, comparison }
    private let beforeBodyCallback: ((BodyCallback) -> Void)?
    private let loop: EventLoop
    private let coordinator: BreakpointCoordinator
    private let resume: (ExchangeRuleContinuation) -> Void
    private let fail: (BreakpointEndReason) -> Void
    private let io: BodyFileIO?
    private let sourceVersion: HTTPWireVersion
    private let requestMethod: String
    private let changed: () -> Void
    private let bodyFailure: (Error) -> Void
    private let continueBody: (BreakpointBodyContinuation) -> Void
    private let sendContinue: () -> Void
    /// True once a ticket was reserved, false once that ticket resolved, exactly once each.
    private let pauseChanged: (Bool) -> Void
    private var paused = false
    private var ticket: BreakpointTicket?
    private enum Continuation {
        case request(ExchangeRuleContinuation)
        case response(HTTPResponseHead, (HTTPResponseHead) -> Void)
    }
    private var continuation: Continuation?
    private var timer: Scheduled<Void>?
    private var resolved = false
    private var collector: BreakpointBodyCollector?
    private var replacement: ExactBodySpool?
    private var body: ExactBodySource?
    private var checkingSource: ExactBodySource?
    private var comparison: Task<Void, Never>?
    private var collecting = false
    private(set) var receivedEnd = false
    var direction: HTTPMessageDirection? { ticket?.direction }
    var isCollecting: Bool { collecting && !resolved }
    var canRead: Bool { isCollecting && collector?.canRead == true }
    var timerCount: Int { loop.preconditionInEventLoop(); return timer == nil ? 0 : 1 }

    init(loop: EventLoop, coordinator: BreakpointCoordinator,
         io: BodyFileIO? = nil, sourceVersion: HTTPWireVersion = .http1_1, requestMethod: String = "GET",
         beforeBodyCallback: ((BodyCallback) -> Void)? = nil, changed: @escaping () -> Void = {}, bodyFailure: @escaping (Error) -> Void = { _ in },
         continueBody: @escaping (BreakpointBodyContinuation) -> Void = { _ in },
         sendContinue: @escaping () -> Void = {}, pauseChanged: @escaping (Bool) -> Void = { _ in },
         resume: @escaping (ExchangeRuleContinuation) -> Void, fail: @escaping (BreakpointEndReason) -> Void) {
        self.loop = loop; self.coordinator = coordinator; self.resume = resume; self.fail = fail
        self.io = io; self.sourceVersion = sourceVersion; self.requestMethod = requestMethod
        self.beforeBodyCallback = beforeBodyCallback
        self.changed = changed; self.bodyFailure = bodyFailure; self.continueBody = continueBody
        self.sendContinue = sendContinue
        self.pauseChanged = pauseChanged
    }
    @discardableResult
    func pause(ticket: BreakpointTicket, continuation: ExchangeRuleContinuation) throws -> Bool {
        try pause(ticket: ticket, continuation: .request(continuation))
    }
    func pauseResponse(ticket: BreakpointTicket, head: HTTPResponseHead,
                       resume: @escaping (HTTPResponseHead) -> Void) throws -> Bool {
        try pause(ticket: ticket, continuation: .response(head, resume))
    }
    private func pause(ticket: BreakpointTicket, continuation: Continuation) throws -> Bool {
        loop.preconditionInEventLoop()
        let owner = NIOLoopBound(self, eventLoop: loop)
        guard try coordinator.reserve(ticket, deliver: { [loop] delivery in
            loop.execute { owner.value.receive(delivery) }
        }) != nil else { return false }
        self.ticket = ticket; self.continuation = continuation
        timer = loop.assumeIsolated().scheduleTask(deadline: ticket.deadline) { [weak self] in self?.requestExpiry() }
        paused = true
        pauseChanged(true)
        if ticket.mode == .fullBody { _ = try startCollection() }
        return true
    }
    private func startCollection() throws -> BreakpointCommandResult {
        guard let ticket, let io else { throw ExchangeRuleFailure.unsupported("fullBodyBreakpoint") }
        let fields = HTTPHeaders(fields: ticket.originalHead.headers)
        let expectations = ticket.direction == .request ? fields["expect"] : []
        guard expectations.allSatisfy({ value in
            value.split(separator: ",", omittingEmptySubsequences: false).allSatisfy {
                $0.trimmingCharacters(in: .whitespaces).lowercased() == "100-continue"
            }
        }) else { throw ExchangeRuleFailure.unsupported("fullBodyExpect") }
        var expected = fields.first(name: "content-length").flatMap(Int64.init)
        if case .response(let status, _, _) = ticket.originalHead,
           !HTTPMessageTranslation.responseBodyAllowed(requestMethod: .init(rawValue: requestMethod), status: .init(statusCode: status)) { expected = 0 }
        if ticket.direction == .request, sourceVersion != .http2, expected == nil, !fields.contains(name: "transfer-encoding") { expected = 0 }
        if let expected, expected > Int64(coordinator.limits.breakpointBodyBytes) {
            coordinator.bodyUnavailable(token: ticket.token, reason: .knownLengthTooLarge)
            return .unsupported
        }
        let collector = try BreakpointBodyCollector(expectedLength: expected, io: io)
        guard coordinator.collecting(ticket.token, io: io) else { collector.cancel(); return .invalid }
        self.collector = collector; collecting = true
        // The client must not upload until its reservation and collection admission succeeded.
        if !expectations.isEmpty { sendContinue() }
        changed()
        return .accepted
    }
    @discardableResult
    func append(_ bytes: ByteBuffer) -> EventLoopFuture<Void> {
        guard isCollecting, let collector, !receivedEnd else { return loop.makeFailedFuture(OwnedFileError(.cancelled)) }
        let future = collector.append(bytes)
        future.assumeIsolated().whenComplete { [weak self] result in
            self?.beforeBodyCallback?(.collectionAppend)
            guard let self, !self.resolved else { return }
            if case .failure(let error) = result { self.failBodyCallback(error) }
            else { self.changed() }
        }
        changed()
        return future
    }
    func finishBody(trailers: [HeaderField]) {
        guard isCollecting, !receivedEnd, let collector else { return }
        receivedEnd = true
        collector.finish(trailers: trailers).assumeIsolated().whenComplete { [weak self] result in
            self?.beforeBodyCallback?(.collectionFinish)
            guard let self, !self.resolved, let ticket = self.ticket else {
                if case .success(let source) = result { source.cancel() }; return
            }
            switch result {
            case .failure(let error): self.failBodyCallback(error)
            case .success(let source):
                guard self.coordinator.clock.now < ticket.deadline else { source.cancel(); self.requestExpiry(); return }
                guard self.coordinator.bodyReady(token: ticket.token, source: source, originalTrailers: trailers) else {
                    if self.coordinator.clock.now >= ticket.deadline { self.requestExpiry() }; return
                }
                self.body = source; self.collecting = false; self.collector = nil
                self.changed()
            }
        }
        changed()
    }
    private func receive(_ delivery: BreakpointCoordinator.Delivery) {
        loop.preconditionInEventLoop()
        guard !resolved, let ticket, continuation != nil else { return }
        switch delivery {
        case .end(let reason): applyEnd(reason)
        case .command(let command, let operation):
            guard command.token == ticket.token, coordinator.isPending(ticket.token, operation: operation) else { return }
            guard coordinator.clock.now < ticket.deadline else { requestExpiry(); return }
            switch command {
            case .continue(_, let edit):
                do {
                    try HTTPMutationValidator.validateBreakpointHeadBudget(edit.head, limits: coordinator.limits)
                    guard !collecting else { throw InvalidEdit() }
                    if let body {
                        let changed: Bool
                        switch edit.body { case .replace, .replaceSource: changed = true; default: changed = false }
                        if ticket.direction == .request, ticket.routeKind == .local, changed { throw InvalidEdit() }
                        var length = body.size
                        switch edit.body {
                        case .replace(let data):
                            guard data.count <= coordinator.limits.editorBodyBytes else { throw InvalidEdit() }
                            length = Int64(data.count)
                        case .replaceSource(let source):
                            guard coordinator.ownsReplacement(source, token: ticket.token), source.size <= Int64(coordinator.limits.breakpointBodyBytes) else { throw InvalidEdit() }
                            length = source.size
                        default: break
                        }
                        let descriptor = HTTPBodyDescriptor(length: length, complete: true, changed: changed,
                            encodingChoice: edit.bodyEncodingChoice, trailers: body.trailers)
                        let plan = try BreakpointFraming.plan(original: ticket.effectiveHead, edited: edit.head,
                            body: descriptor, source: sourceVersion, target: sourceVersion, requestMethod: requestMethod, limits: coordinator.limits)
                        if case .replace(let data) = edit.body, plan.bodyAllowed {
                            try replace(data, edit: edit, descriptor: descriptor, operation: operation)
                        } else {
                            let source: ExactBodySource
                            if case .replaceSource(let replacement) = edit.body, plan.bodyAllowed { source = replacement }
                            else { source = body }
                            var selected = descriptor
                            if !plan.bodyAllowed { selected.length = source.size; selected.changed = false }
                            accept(edit: edit, source: source, descriptor: selected, operation: operation,
                                   ignoredBodyEdit: changed && !plan.bodyAllowed)
                        }
                    } else {
                        switch edit.body { case nil, .unchanged: break; default: throw InvalidEdit() }
                        try HTTPMutationValidator.validateEdit(original: ticket.effectiveHead, edited: edit.head,
                            body: .init(length: nil, complete: false, changed: false),
                            upgradeCandidate: HTTPMutationValidator.isUpgradeCandidate(ticket.originalHead.headers), limits: coordinator.limits)
                        accept(edit: edit, source: nil, descriptor: nil, operation: operation)
                    }
                } catch { _ = coordinator.complete(ticket.token, operation: operation, result: .invalid) }
            case .cancel:
                coordinator.releaseImported(ticket.token)
                guard coordinator.complete(ticket.token, operation: operation, result: .accepted) else { return }
                applyEnd(.cancelled)
            case .collectBody:
                do {
                    let result = try startCollection()
                    _ = coordinator.complete(ticket.token, operation: operation, result: result, retaining: true)
                } catch let error as ExchangeRuleFailure {
                    _ = error
                    _ = coordinator.complete(ticket.token, operation: operation, result: .unsupported, retaining: true)
                } catch {
                    failBodyCallback(error, operation: operation)
                }
            }
        }
    }
    private func replace(_ data: Data, edit: BreakpointEdit, descriptor: HTTPBodyDescriptor, operation: UUID) throws {
        guard let io else { throw InvalidEdit() }
        let spool = try ExactBodySpool(category: .breakpoint, expectedLength: Int64(data.count), limits: coordinator.limits, io: io)
        replacement = spool
        writeReplacement(data, offset: 0, spool: spool, edit: edit, descriptor: descriptor, operation: operation)
    }
    private func writeReplacement(_ data: Data, offset: Int, spool: ExactBodySpool, edit: BreakpointEdit,
                                  descriptor: HTTPBodyDescriptor, operation: UUID) {
        guard !resolved, let ticket, coordinator.isPending(ticket.token, operation: operation) else { spool.cancel(); return }
        if offset == data.count {
            spool.finish(trailers: []).assumeIsolated().whenComplete { [weak self] result in
                self?.beforeBodyCallback?(.replacementFinish)
                guard let self, !self.resolved else { if case .success(let source) = result { source.cancel() }; return }
                self.replacement = nil
                switch result {
                case .failure(let error): self.failBodyCallback(error, operation: operation)
                case .success(let source): self.accept(edit: edit, source: source, descriptor: descriptor, operation: operation)
                }
            }
        } else {
            let count = min(data.count - offset, max(1, min(65_536, coordinator.limits.ioChunkBytes)))
            spool.append(ByteBuffer(bytes: data[offset..<(offset + count)])).assumeIsolated().whenComplete { [weak self] result in
                self?.beforeBodyCallback?(.replacementWrite)
                guard let self, !self.resolved else { spool.cancel(); return }
                switch result {
                case .failure(let error): self.failBodyCallback(error, operation: operation)
                case .success: self.writeReplacement(data, offset: offset + count, spool: spool, edit: edit, descriptor: descriptor, operation: operation)
                }
            }
        }
    }
    private func accept(edit: BreakpointEdit, source: ExactBodySource?, descriptor: HTTPBodyDescriptor?, operation: UUID, bytesChanged: Bool? = nil, ignoredBodyEdit: Bool = false) {
        guard let ticket, let continuation, !resolved, coordinator.isPending(ticket.token, operation: operation) else { source?.cancel(); return }
        guard coordinator.clock.now < ticket.deadline else { source?.cancel(); requestExpiry(); return }
        if bytesChanged == nil, descriptor?.changed == true, let source, let original = body,
           source.size == original.size, source.lease.id != original.lease.id, let io {
            checkingSource = source
            let promise = loop.makePromise(of: Bool.self)
            comparison = promise.completeWithTask {
                var offset: Int64 = 0
                while offset < source.size {
                    try Task.checkCancellation()
                    let count = min(65_536, max(1, io.limits.ioChunkBytes), Int(source.size - offset))
                    let retained = try io.budgets.reserve(category: .io, bytes: Int64(count) * 2)
                    defer { retained.release() }
                    let a = try await original.read(offset: offset, maxBytes: count)
                    let b = try await source.read(offset: offset, maxBytes: count)
                    if a != b { return true }
                    guard !a.isEmpty else { throw OwnedFileError(.shortRead) }
                    offset += Int64(a.count)
                }
                return false
            }
            promise.futureResult.assumeIsolated().whenComplete { [weak self] result in
                self?.beforeBodyCallback?(.comparison)
                guard let self, !self.resolved else { source.cancel(); return }
                self.checkingSource = nil; self.comparison = nil
                switch result {
                case .failure(let error as OwnedFileError) where error.code == .operationInFlight || error.code == .capacityExceeded:
                    if !self.coordinator.ownsReplacement(source, token: ticket.token) { source.cancel() }
                    _ = self.coordinator.complete(ticket.token, operation: operation, result: .invalid)
                case .failure(let error): source.cancel(); self.failBodyCallback(error, operation: operation)
                case .success(let changed): self.accept(edit: edit, source: source, descriptor: descriptor, operation: operation, bytesChanged: changed, ignoredBodyEdit: ignoredBodyEdit)
                }
            }
            return
        }
        let release: () -> Void
        do {
            switch continuation {
            case .response(var head, let resumeResponse):
                guard case .response(let status, let reason, let fields) = edit.head else { throw InvalidEdit() }
                head.status = HTTPResponseStatus(statusCode: status, reasonPhrase: reason ?? "")
                head.headers = HTTPHeaders(fields: fields)
                release = { resumeResponse(head) }
            case .request(let request):
                let next: ExchangeRuleContinuation
                guard case .request(let edited, let fields) = edit.head,
                      case .request(let paused, _) = ticket.effectiveHead else { throw InvalidEdit() }
                switch request {
                case .local, .localDirectory, .generated, .close:
                    guard edited == paused else { throw InvalidEdit() }
                    next = request
                case .network:
                    let sensitive: Set<String> = ["authorization", "cookie", "origin", "referer"]
                    let explicit = fields.filter { field in sensitive.contains(field.name.lowercased()) && !ticket.effectiveHead.headers.contains {
                        $0.name.lowercased() == field.name.lowercased() && $0.value == field.value
                    } }
                    let headers = EffectiveRequestRoute.sanitizedHeaders(fields, from: paused, to: edited,
                        preserveCredentials: false, explicitCredentialFields: explicit)
                    next = .network(head: .request(edited, headers: headers), body: source)
                }
                release = { self.resume(next) }
            }
        } catch { _ = coordinator.complete(ticket.token, operation: operation, result: .invalid); return }
        guard coordinator.clock.now < ticket.deadline else { source?.cancel(); requestExpiry(); return }
        guard coordinator.isPending(ticket.token, operation: operation) else { source?.cancel(); return }
        coordinator.releaseImported(ticket.token, preserving: source?.lease.id)
        guard coordinator.complete(ticket.token, operation: operation, result: .accepted) else { source?.cancel(); return }
        if let source, let descriptor {
            continueBody(.init(source: source, original: ticket.effectiveHead, descriptor: descriptor, bytesChanged: descriptor.changed && bytesChanged != false, version: sourceVersion, ignoredBodyEdit: ignoredBodyEdit))
        }
        finish(transferring: source)
        release()
    }
    /// A registered cancel owns the result even while its delivery waits behind this callback.
    func failBodyCallback(_ error: Error, operation: UUID? = nil) {
        guard !resolved, let ticket,
              let result = coordinator.claimBodyFailure(ticket.token, operation: operation) else { return }
        if result == .expired { applyEnd(.expired) }
        else { finish(); bodyFailure(error) }
    }
    private struct InvalidEdit: Error {}
    private func requestExpiry() {
        guard !resolved, let ticket, coordinator.claimExpiry(ticket.token) else { return }
        applyEnd(.expired)
    }
    /// Applies a decision already won in the registry, including a delivery after removal.
    private func applyEnd(_ reason: BreakpointEndReason) {
        guard !resolved, ticket != nil else { return }
        finish(); fail(reason)
    }
    private func finish(transferring source: ExactBodySource? = nil) {
        resolved = true
        collector?.cancel(); collector = nil
        replacement?.cancel(); replacement = nil
        comparison?.cancel(); comparison = nil
        checkingSource?.cancel(); checkingSource = nil
        if body?.lease.id != source?.lease.id { body?.cancel() }
        body = nil
        timer?.cancel(); timer = nil
        continuation = nil; ticket = nil
        if paused {
            paused = false
            pauseChanged(false)
        }
    }
    func abandon() {
        loop.preconditionInEventLoop()
        guard !resolved else { return }
        if let ticket { coordinator.remove(ticket.token) }
        finish()
    }
}
