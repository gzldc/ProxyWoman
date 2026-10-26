import AppCore
import FlowStore
import Foundation
import Localization
import ProxyCore

/// The AppCore Compose facade over the server's `ComposeService` (the real upstream path, pool,
/// TLS verification and recorder). It keeps no state: each call converts Foundation values to the
/// service's request and its `ComposeResult` back.
final class ProxyComposeClient: ComposeClient {
    private let service: ComposeService

    init(service: ComposeService) {
        self.service = service
    }

    func send(_ request: ComposeOutgoingRequest) async -> ComposeOutcome {
        // The draft already encoded the URL for the wire; nothing may be encoded or normalized again.
        guard let url = URL(string: request.url, encodingInvalidCharacters: false) else {
            return ComposeOutcome(flowID: nil, failure: ComposeOutcomeFailure(
                code: ComposeFailureCode.invalidRequest.rawValue,
                message: L10n.string("compose.issue.invalidURL")), delivery: .notSent)
        }
        let result = await service.send(ComposeRequest(
            id: request.id, method: request.method, url: url, headers: request.headers,
            body: Self.body(of: request), sourceFlowID: request.sourceFlowID,
            policy: ComposePolicy(applyRules: request.applyRules, timeout: .seconds(request.timeoutSeconds),
                                  httpVersion: request.http1Only ? .http1Only : .automatic),
            repeatTag: request.repeatTag))
        return ComposeOutcome(
            flowID: result.flowID, response: result.response.map(Self.snapshot),
            failure: result.failure.map {
                ComposeOutcomeFailure(code: $0.code, message: $0.message,
                                      isCancellation: $0.code == ComposeFailureCode.cancelled.rawValue)
            },
            partialResponse: result.partialResponse.map(Self.snapshot), delivery: Self.delivery(result.delivery))
    }

    /// A managed file streams from the store; otherwise the bytes (or no body).
    static func body(of request: ComposeOutgoingRequest) -> ComposeBody {
        if let asset = request.bodyAsset { return .asset(asset.assetID) }
        return request.body.isEmpty ? .none : .bytes(request.body)
    }

    func cancel(_ id: UUID) {
        service.cancel(id)
    }

    private static func snapshot(_ response: ComposeResponse) -> ComposeResponseSnapshot {
        ComposeResponseSnapshot(status: response.status, reason: response.reason, headers: response.headers,
                                body: response.body, bodyBytes: response.bodyBytes, truncated: response.truncated,
                                trailers: response.trailers)
    }

    private static func delivery(_ delivery: ComposeDelivery) -> ComposeDeliveryState {
        switch delivery {
        case .notSent: .notSent
        case .unknown: .unknown
        case .answered: .answered
        }
    }
}
