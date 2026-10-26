import FlowStore
import Foundation
import NIOCore
import RulesEngine

/// What the CONNECT point's rules did, for the CONNECT's own row: their outcomes and annotations (D14).
struct ConnectRuleRecord {
    let provenance: FlowProvenance
    let annotations: [FlowAnnotation]

    /// Nil when the rules left nothing to write, so the row is recorded exactly as without rules.
    init?(_ decision: ConnectRuleDecision) {
        guard decision.matches.hasRecords || !decision.annotations.isEmpty else { return nil }
        provenance = FlowProvenance(ruleMatches: decision.matches.hasRecords ? decision.matches : nil)
        annotations = decision.annotations
    }
}

extension ProxyHandler {
    /// The CONNECT point (P0, spec 5.5.2, D11–D14), after the Block and Allow lists and before the CONNECT is
    /// answered. It runs only when an active rule runs there (`activeAtConnect`), on the event loop, and waits for
    /// the client app only when such a rule reads it (D13), at most the lookup grace.
    ///
    /// The rules can close the client connection before the 200 (FIN or RST), keep a host the tools decrypt
    /// out of decryption, or go on as the tools decided. Their annotations and outcomes are written on the
    /// tunnel row or on the failed row of a closed CONNECT; a decrypted CONNECT has no row, so they are dropped
    /// there, and the requests inside it are evaluated from the start.
    func evaluateConnectRules(
        _ exchange: LocalExchange, target: RequestTarget, rules: RuleSnapshotProvider, snapshot: RuleSnapshot,
        toolDecrypts: Bool, records: Bool
    ) {
        guard let connection else { return }
        let evaluate = { [self] in
            // The client may have gone while the lookup was awaited.
            guard localExchange === exchange, let context else { return }
            let facts = ExchangeFacts(
                clientIP: connection.clientIP, app: connection.knownClient.map(ExchangeFacts.AppLookup.known) ?? .unknown,
                requestStartedAt: Date())
            let decision = RuleEvaluator.connect(
                target: HTTPMessageTarget(scheme: "https", host: target.host, port: target.port, method: "CONNECT",
                                          pathAndQuery: ""),
                snapshot: snapshot, tool: toolDecrypts ? .decrypt : .tunnel, hits: rules.hits, facts: facts,
                cache: rules.patternCache)
            switch decision.disposition {
            case .proceed where toolDecrypts:
                intercept(exchange, host: target.host.lowercased(), port: target.port, context: context)
            case .proceed, .noDecrypt:
                openTunnel(exchange, target: target, context: context, records: records, rules: ConnectRuleRecord(decision))
            case .close(let mode, let ruleID):
                closeConnect(exchange, target: target, mode: mode, ruleID: ruleID, snapshot: snapshot, decision: decision,
                             records: records)
            }
        }
        if snapshot.requirements.connectClientApp { connection.whenForwardingAllowed(evaluate) } else { evaluate() }
    }

    /// A rule closed the CONNECT: nothing is answered. The failed row (when the CONNECT is recorded) names the
    /// rule and carries the annotations, as a blocked CONNECT's does.
    private func closeConnect(
        _ exchange: LocalExchange, target: RequestTarget, mode: RulesEngine.CloseMode, ruleID: UUID, snapshot: RuleSnapshot,
        decision: ConnectRuleDecision, records: Bool
    ) {
        if records, let store = environment.recording.activeStore {
            let name = snapshot.rules.first { $0.id == ruleID }?.name ?? ruleID.uuidString
            let record = ConnectRuleRecord(decision)
            let id = TunnelRecorder.recordFailure(
                store: store, host: target.host, port: target.port, client: connection?.knownClient,
                reason: HTTPLocalFailureText.ruleClosed(ruleName: name), note: nil,
                provenance: record?.provenance ?? FlowProvenance(), annotations: decision.annotations)
            connection?.onClient { app in store.update(id) { $0.client = app } }
        }
        localExchange = nil
        connection?.finishLocalOperation()
        // As a rule close of an exchange (T9): graceful half-closes and drains for a bounded time, so bytes the
        // client sent early never turn the FIN into a reset; reset sends RST.
        if mode == .reset { closeClient(reset: true) } else { closeAfterDiscardingUpload(after: nil) }
    }
}
