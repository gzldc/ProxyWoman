import FlowStore
import Foundation
import RulesEngine

/// What an exchange learns about its origin side, kept for the response point: the lease's
/// address, TLS version and certificate, and the HTTP version it speaks. Confined to the exchange's loop.
final class ExchangeFactsState {
    private(set) var upstream = FlowConnectionInfo()
    private(set) var upstreamVersion: HTTPWireVersion?

    /// Reads the connection under `lease` (once its final head arrived) and returns what it showed.
    func record(_ lease: UpstreamLease) -> FlowConnectionInfo {
        upstream = ConnectionInfoReader.upstream(of: lease)
        upstreamVersion = lease.version
        return upstream
    }
}

extension ExchangeRuleSession.FactsSource {
    /// The live source of a proxy exchange. Everything is read on the exchange's loop when asked;
    /// nothing is captured strongly, so the session never keeps the connection alive.
    static func exchange(
        connection: HTTPOutboundEnvironment, clientVersion: HTTPWireVersion, state: ExchangeFactsState,
        virtualClient: Bool, comment: @escaping () -> String?
    ) -> Self {
        Self(
            clientIP: { [weak connection] in connection?.clientIP },
            remoteIP: { state.upstream.remoteIP },
            clientHTTPVersion: { clientVersion },
            upstreamHTTPVersion: { state.upstreamVersion },
            clientTLSVersion: { [weak connection] in connection?.downstreamTLSVersion },
            upstreamTLSVersion: { state.upstream.upstreamTLSVersion },
            certificate: { state.upstream.upstreamCertificate },
            app: { [weak connection] in
                if virtualClient { return .notApplicable }
                // The exchange waited for the lookup (or its grace) before the rules ran.
                return connection?.knownClient.map(ExchangeFacts.AppLookup.known) ?? .unknown
            },
            comment: comment, requestStartedAt: Date())
    }
}
