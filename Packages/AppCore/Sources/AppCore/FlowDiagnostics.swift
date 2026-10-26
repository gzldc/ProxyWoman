import FlowStore
import Foundation

/// Recorded diagnostics are independent of the response status, which may precede a failure.
public struct FlowDiagnostics: Sendable, Equatable {
    public let failure: String?
    public let note: String?
    /// Boundaries whose transfer stopped early or whose body is not wholly kept, in a stable order.
    /// Empty for legacy flows (they carry no boundary snapshots) and for flows that went through whole.
    public let incompleteBoundaries: [HTTPMessageBoundary]
    /// False for flows recorded before boundary snapshots existed: nothing is claimed about their provenance.
    public let provenanceKnown: Bool

    public init(flow: Flow) {
        if case .failed(let reason) = flow.state {
            failure = reason
        } else {
            failure = nil
        }
        provenanceKnown = flow.provenance.isKnown
        incompleteBoundaries = HTTPMessageBoundary.allCases.filter { boundary in
            guard let snapshot = flow.messages[boundary] else { return false }
            switch snapshot.transferState {
            case .partiallySent, .failed: return true
            case .observed, .acceptedByWriter, .finished: break
            }
            switch snapshot.bodyState {
            case .truncated, .incomplete, .unavailable: return true
            case .pending, .complete: return false
            }
        }
        let note = flow.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.note =
            note?.isEmpty == false && note != failure?.trimmingCharacters(in: .whitespacesAndNewlines) ? note : nil
    }
}
