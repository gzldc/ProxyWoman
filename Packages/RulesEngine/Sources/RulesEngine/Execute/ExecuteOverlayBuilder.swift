import FlowStore
import Foundation

/// Turns one flow's evaluation into its overlay (D10, D11): the request the wire would carry and the response
/// the client would receive, each only when it differs from the original record, with the body rewrites run
/// and their provisional outcomes settled.
enum ExecuteOverlayBuilder {
    struct Built: Sendable {
        var overlay: ExecuteOverlay?
        /// The evaluation's records with every body action's real outcome, relabelled again (D12).
        var matches: RuleMatchSummary?
        /// A header edit, a route or a status rewrite applied, or a body really changed.
        var rulesModified: Bool
    }

    /// Applies the request and response decisions to the originals: routing, sanitised headers, body rewrites
    /// (`BodyRewriter`, off the main actor, cancellable), the local response, and settles the provisional body
    /// outcomes. Throws only `CancellationError`; no body is created once cancelled.
    static func build(_ evaluation: ExecuteEvaluation, snapshot: RuleSnapshot, environment: ExecuteEnvironment)
        async throws -> Built
    {
        try Task.checkCancellation()
        guard let originals = evaluation.originals, let request = evaluation.request else {
            return Built(overlay: nil, matches: evaluation.matches, rulesModified: false)
        }
        var settled: [RuleOutcome] = []
        var bodyChanged = false

        // Request side (D10).
        var plannedRequest: Planned?
        let original = originals.request
        do {
            // `FlowOriginals` always holds a request head; nothing to send otherwise.
            guard let originalTarget = original.target else {
                throw HTTPMutationError(code: .invalidPath, field: .path)
            }
            var target = originalTarget
            var headers = request.effectiveHead.headers
            switch request.route {
            case .original, .remote:
                // Only a request that goes upstream is moved and stripped, as the proxy sends it.
                target = try RequestRouting.target(original: originalTarget, decision: request)
                var preserveCredentials = false
                if case .remote(let remote) = request.route { preserveCredentials = remote.preserveCredentials }
                headers = RequestRouting.sanitizedHeaders(
                    headers, from: originalTarget, to: target, preserveCredentials: preserveCredentials)
            case .local, .localDirectory, .generated, .close:
                break
            }
            var plan = Planned(head: .request(target, headers: headers), body: .captured(original.body))
            let rewrite = try await rewrite(
                request.bodyRewrites, head: plan.head, source: .captured(original.body), environment: environment)
            settled += rewrite.outcomes
            if let rewritten = rewrite.result {
                plan = rewritten
                bodyChanged = true
            }
            plannedRequest = plan.head == original.head && plan.body.isOriginal ? nil : plan
        } catch is HTTPMutationError {
            // A target the proxy would refuse to send (never for a saved rule): no request goes out.
            settled += request.bodyRewrites.map {
                RuleOutcome(ruleID: $0.ruleID, code: .rejected, actionIndex: $0.actionIndex)
            }
            plannedRequest = nil
        }
        // Request-side actions of rules judged at the response change only the record of the request (spec
        // R8F2-6), shown in place of it; the overlay's request then is the record, as `viewingExecuteOverlay` shows it.
        if let recorded = evaluation.response?.recordedRequestActions, !recorded.isEmpty {
            var plan = plannedRequest ?? Planned(head: original.head, body: .captured(original.body))
            let edited = RecordedRequestEditing.apply(
                recorded, to: plan.head, allowance: environment.makeAllowance(), cache: environment.cache,
                limits: environment.limits)
            if edited != plan.head {
                plan.head = edited
                plannedRequest = plan
            }
        }
        try Task.checkCancellation()

        // Response side (D11): only when the response point ran on a response.
        var plannedResponse: Planned?
        if let response = evaluation.response {
            let source: BodySource
            if let local = evaluation.local {
                source = .bytes(local.body)
            } else if let original = originals.response {
                source = .captured(original.body)
            } else {
                source = .bytes(Data())
            }
            // A rewritten status (and a local response without one) gets its conventional reason, else none.
            var head = response.effectiveHead
            if case .response(let status, nil, let headers) = head,
                response.statusRewrite != nil || evaluation.local != nil
            {
                let reason = GeneratedResponse.standardReason(for: status)
                head = .response(status: status, reason: reason, headers: headers)
            }
            var plan = Planned(head: head, body: source)
            let rewrite = try await rewrite(response.bodyRewrites, head: head, source: source, environment: environment)
            settled += rewrite.outcomes
            if let rewritten = rewrite.result {
                plan = rewritten
                bodyChanged = true
            }
            // Live writes a local response through `HTTPMessageTranslation.response` with the real body length: it
            // drops `Content-Length` and `Transfer-Encoding`, then adds the length last (never for 1xx or 204).
            if evaluation.local != nil, case .bytes(let bytes) = plan.body {
                plan.head = liveFramed(plan.head, length: bytes.count)
            }
            if evaluation.local != nil || plan.head != originals.response?.head || !plan.body.isOriginal {
                plannedResponse = plan
            }
        }

        // Nothing is created for a run that was cancelled meanwhile.
        try Task.checkCancellation()
        let overlay = ExecuteOverlay(
            request: plannedRequest.map { snapshotOf($0, boundary: .upstreamRequest, environment: environment) },
            response: plannedResponse.map { snapshotOf($0, boundary: .downstreamResponse, environment: environment) },
            responseIsLocal: plannedResponse != nil && evaluation.local != nil)

        let steps = request.bodyRewrites + (evaluation.response?.bodyRewrites ?? [])
        var matches = evaluation.matches.map { settle($0, with: settled, steps: steps) }
        if let summary = matches { matches = ExecuteOutcomes.relabelOffline(summary, rules: snapshot.rules).summary }
        let modified = request.rulesModified || (evaluation.response?.rulesModified ?? false) || bodyChanged
        return Built(overlay: overlay.isEmpty ? nil : overlay, matches: matches, rulesModified: modified)
    }

    // MARK: bodies

    /// Where a message's body comes from: the captured record (shared when unchanged) or bytes a rule produced.
    enum BodySource {
        case captured(FlowOriginals.Body)
        case bytes(Data)

        /// The captured record itself, which the overlay shares instead of copying.
        var isOriginal: Bool {
            if case .captured = self { return true }
            return false
        }
    }

    /// One side of the overlay before any body is created.
    struct Planned {
        var head: HTTPMessageHead
        var body: BodySource
    }

    /// Runs `steps` over the body (D10 / D11). `result` is the new head and bytes when the bytes changed;
    /// `outcomes` are the steps' real outcomes (empty without steps).
    private static func rewrite(
        _ steps: [BodyRewriteStep], head: HTTPMessageHead, source: BodySource, environment: ExecuteEnvironment
    ) async throws -> (result: Planned?, outcomes: [RuleOutcome]) {
        guard !steps.isEmpty else { return (nil, []) }
        func skipped(_ code: RuleOutcomeCode) -> (result: Planned?, outcomes: [RuleOutcome]) {
            (nil, steps.map { RuleOutcome(ruleID: $0.ruleID, code: code, actionIndex: $0.actionIndex) })
        }
        let limits = environment.limits
        let data: Data
        switch source {
        case .bytes(let bytes):
            data = bytes
        case .captured(let body):
            // A cut-short or unfinished record is never rewritten, nor one over the cap (not even read).
            guard body.state == .complete, !body.legacyTruncated else { return skipped(.bodySkippedTooLarge) }
            guard body.size <= limits.rewriteBodyBytes else { return skipped(.bodySkippedTooLarge) }
            do {
                data = try read(body, chunkBytes: limits.ioChunkBytes)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return skipped(.bodySkippedUnavailable)
            }
        }
        let headers = head.headers
        let contentType = headers.values(for: "content-type").first
        let encodings = headers.values(for: "content-encoding")
        let result = try await BodyRewriter.apply(
            steps: steps, to: data, contentType: contentType,
            contentEncoding: encodings.isEmpty ? nil : encodings.joined(separator: ", "), limits: limits,
            cache: environment.cache)
        switch result {
        case .unchanged(let outcomes):
            return (nil, outcomes)
        case .rewritten(let bytes, let outcomes):
            let encoded = headers.contains {
                $0.name.lowercased() == "content-encoding" && BodyContentCodec.hasRealEncoding($0.value)
            }
            let normalized: HTTPMessageHead
            do {
                normalized = try HTTPMutationValidator.normalize(
                    head: head,
                    body: HTTPBodyDescriptor(
                        length: Int64(bytes.count), complete: true, changed: true,
                        encodingChoice: encoded ? .removeEncoding : .unchanged),
                    limits: limits
                ).head
            } catch {
                return skipped(.rejected)
            }
            return (Planned(head: withContentLength(normalized, bytes.count), body: .bytes(bytes)), outcomes)
        }
    }

    /// The captured body in chunks, checking for cancellation before each (it may be on disk).
    private static func read(_ body: FlowOriginals.Body, chunkBytes: Int) throws -> Data {
        let reference: BodyRef
        let start: Int
        let count: Int
        if let slice = body.slice {
            (reference, start, count) = (slice.ref, slice.offset, slice.count)
        } else if let legacy = body.legacy {
            (reference, start, count) = (legacy, 0, legacy.size)
        } else {
            return Data()
        }
        let chunk = max(1, min(65_536, chunkBytes))
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            try Task.checkCancellation()
            let next = try reference.load(offset: start + data.count, maxBytes: min(chunk, count - data.count))
            guard !next.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            data.append(next)
        }
        return data
    }

    private static func liveFramed(_ head: HTTPMessageHead, length: Int) -> HTTPMessageHead {
        guard case .response(let status, let reason, let headers) = head else { return head }
        var kept = headers.filter { !["content-length", "transfer-encoding"].contains($0.name.lowercased()) }
        if !(100..<200).contains(status) && status != 204 { kept.append(HeaderField(name: "Content-Length", value: String(length))) }
        return .response(status: status, reason: reason, headers: kept)
    }

    private static func withContentLength(_ head: HTTPMessageHead, _ length: Int) -> HTTPMessageHead {
        let field = HeaderField(name: "Content-Length", value: String(length))
        switch head {
        case .request(let target, let headers): return .request(target, headers: headers + [field])
        case .response(let status, let reason, let headers):
            return .response(status: status, reason: reason, headers: headers + [field])
        }
    }

    /// The overlay snapshot of one side. New bytes become a store body (`makeBody`); a captured body is shared.
    private static func snapshotOf(_ planned: Planned, boundary: HTTPMessageBoundary, environment: ExecuteEnvironment)
        -> HTTPMessageSnapshot
    {
        let slice: HTTPBodySlice?
        let state: HTTPBodyState
        switch planned.body {
        case .bytes(let bytes):
            slice = bytes.isEmpty ? nil : HTTPBodySlice(ref: environment.makeBody(bytes), offset: 0, count: bytes.count)
            state = .complete
        case .captured(let body):
            if let original = body.slice {
                slice = original
            } else if let legacy = body.legacy {
                slice = HTTPBodySlice(ref: legacy, offset: 0, count: legacy.size)
            } else {
                slice = nil
            }
            state = body.legacyTruncated ? .truncated : body.state
        }
        return HTTPMessageSnapshot(
            boundary: boundary, head: planned.head, wireVersion: nil, body: slice, bodyState: state,
            observedBytes: UInt64(slice?.count ?? 0), transferState: .finished)
    }

    // MARK: outcomes

    /// Replaces each body action's provisional `applied` with its real outcome, once per action (as
    /// `ExchangeRuleSession.recordBodyRewriteOutcomes`). Only the actions the decisions handed out are accepted.
    private static func settle(_ summary: RuleMatchSummary, with outcomes: [RuleOutcome], steps: [BodyRewriteStep])
        -> RuleMatchSummary
    {
        struct Key: Hashable {
            var ruleID: UUID
            var actionIndex: Int?
        }
        let expected = Set(steps.map { Key(ruleID: $0.ruleID, actionIndex: $0.actionIndex) })
        var done: Set<Key> = []
        var recorded = summary.outcomes
        for outcome in outcomes {
            let key = Key(ruleID: outcome.ruleID, actionIndex: outcome.actionIndex)
            guard expected.contains(key), done.insert(key).inserted else { continue }
            // Not found when the cap on recorded outcomes cut the action's entry.
            guard let index = recorded.firstIndex(where: {
                $0.code == .applied && $0.ruleID == key.ruleID && $0.actionIndex == key.actionIndex
            }) else { continue }
            recorded[index] = outcome
        }
        var result = summary
        result.outcomes = recorded
        return result
    }
}
