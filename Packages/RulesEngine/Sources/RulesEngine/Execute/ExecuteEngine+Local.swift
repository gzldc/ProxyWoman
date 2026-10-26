import FlowStore
import Foundation

/// What a local route of a captured flow comes to offline (D9).
enum LocalResolution: Sendable, Equatable {
    /// The response the rule produced; the response point runs on it with `isLocalResponse`.
    case response(LocalResponse)
    /// A directory without the file whose policy is `network`: the request goes on, the original response stays.
    case fallBackToNetwork
    /// The file could not be read (missing, unavailable, over `rewriteBodyBytes`): that action is `rejected`,
    /// there is no response point, completion still runs.
    case rejected(ruleID: UUID, actionIndex: Int?)
}

/// A leased file read whole, or why it was not.
enum LeaseRead: Sendable, Equatable {
    case data(Data)
    /// Over the cap, or a read failed.
    case unreadable
}

extension ExecuteEngine {
    /// The response the request decision's local route produces, read in the background like live Return File
    /// (D9). Every lease is released before this returns, however it ends. Throws only `CancellationError`.
    static func resolveLocal(
        route: RuleRoute, decision: RequestRuleDecision, snapshot: RuleSnapshot, environment: ExecuteEnvironment
    ) async throws -> LocalResolution {
        let limits = environment.limits
        switch route {
        case .generated(let generated):
            return .response(
                LocalResponse(
                    status: generated.status, reason: generated.reason,
                    headers: withLength(generated.headers, status: generated.status, length: generated.body.count),
                    body: generated.body))

        case .local(let action):
            let lease: OwnedFileLease
            do {
                lease = try await environment.assets.lease(action.assetID)
            } catch {
                try Task.checkCancellation()
                return rejection(of: decision, snapshot: snapshot)
            }
            let read = try await readLease(lease, cap: limits.rewriteBodyBytes, chunkBytes: limits.ioChunkBytes)
            guard case .data(let body) = read,
                let response = validated(status: action.status, headers: action.headers, body: body, limits: limits)
            else { return rejection(of: decision, snapshot: snapshot) }
            return .response(response)

        case .localDirectory(let directory):
            let resolution = await environment.assets.directoryResolver().resolve(directory)
            switch resolution {
            case .file(let lease, let contentType):
                var headers: [HeaderField] = []
                if !directory.action.headers.contains(where: { $0.name.lowercased() == "content-type" }) {
                    headers.append(HeaderField(name: "Content-Type", value: contentType))
                }
                headers += directory.action.headers
                let read = try await readLease(lease, cap: limits.rewriteBodyBytes, chunkBytes: limits.ioChunkBytes)
                guard case .data(let body) = read,
                    let response = validated(status: 200, headers: headers, body: body, limits: limits)
                else { return rejection(of: decision, snapshot: snapshot) }
                return .response(response)
            case .notFound where directory.action.missing == .network,
                .methodNotAllowed where directory.action.missing == .network:
                try Task.checkCancellation()
                return .fallBackToNetwork
            case .notFound, .unsafe:
                // An unsafe path is always this 404 and never reaches the network (spec F8).
                try Task.checkCancellation()
                return .response(
                    empty(status: 404, headers: [HeaderField(name: "X-ProxyWoman-Map-Local", value: "not-found")]))
            case .methodNotAllowed:
                try Task.checkCancellation()
                return .response(
                    empty(
                        status: 405,
                        headers: [
                            HeaderField(name: "Allow", value: "GET, HEAD"),
                            HeaderField(name: "X-ProxyWoman-Map-Local", value: "method-not-allowed"),
                        ]))
            case .unavailable:
                try Task.checkCancellation()
                return rejection(of: decision, snapshot: snapshot)
            }

        case .original, .remote, .close:
            assertionFailure("only a local route produces a response")
            return .fallBackToNetwork
        }
    }

    /// Reads the whole leased file in chunks of at most `chunkBytes` (≤ 64 KiB), checking for cancellation
    /// before each one. A file over `cap` is not read. The lease is cancelled however this ends.
    static func readLease(_ lease: OwnedFileLease, cap: Int, chunkBytes: Int = 65_536) async throws -> LeaseRead {
        defer { lease.cancel() }
        guard lease.size <= Int64(cap) else { return .unreadable }
        let chunk = max(1, min(chunkBytes, 65_536))
        var data = Data()
        data.reserveCapacity(Int(lease.size))
        while true {
            try Task.checkCancellation()
            let next: Data
            do {
                next = try await lease.read(offset: Int64(data.count), maxBytes: chunk)
            } catch {
                try Task.checkCancellation()
                return .unreadable
            }
            if next.isEmpty { return .data(data) }
            data.append(next)
            if data.count > cap { return .unreadable }
        }
    }

    /// The response a file makes, checked as live checks it before sending (`LocalResponseSource.prepare`).
    private static func validated(status: Int, headers: [HeaderField], body: Data, limits: RulesLimits)
        -> LocalResponse?
    {
        let head = HTTPMessageHead.response(status: status, reason: nil, headers: headers)
        let descriptor = HTTPBodyDescriptor(length: Int64(body.count), complete: true, changed: false)
        do {
            try HTTPMutationValidator.validate(head: head, body: descriptor, limits: limits)
        } catch {
            return nil
        }
        return LocalResponse(
            status: status, reason: nil, headers: withLength(headers, status: status, length: body.count), body: body)
    }

    private static func empty(status: Int, headers: [HeaderField]) -> LocalResponse {
        LocalResponse(
            status: status, reason: nil, headers: withLength(headers, status: status, length: 0), body: Data())
    }

    /// The real `Content-Length`, set as live sets it on a local response (replacing any the rule wrote, last).
    private static func withLength(_ headers: [HeaderField], status: Int, length: Int) -> [HeaderField] {
        guard !(100..<200).contains(status), status != 204 else { return headers }
        return headers.filter { $0.name.lowercased() != "content-length" }
            + [HeaderField(name: "Content-Length", value: String(length))]
    }

    /// The local route's action, named as its outcome names it: the request point's final stop (a Return File
    /// is always final, so a local route always has one).
    private static func rejection(of decision: RequestRuleDecision, snapshot: RuleSnapshot) -> LocalResolution {
        let rules = snapshot.evaluationOrder
        guard let stop = decision.carry?.finalStop, rules.indices.contains(stop.position) else {
            assertionFailure("a local route comes from a final action")
            return .rejected(ruleID: UUID(), actionIndex: nil)
        }
        let rule = rules[stop.position]
        return .rejected(ruleID: rule.id, actionIndex: rule.actions.count > 1 ? stop.actionIndex : nil)
    }
}
