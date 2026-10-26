import FlowStore
import Foundation
import Localization
import RulesEngine

/// Opens a read lease on a captured body (the flow store's `acquireBody`); same shape as Compose's.
public typealias BodyLeaseAcquirer = @Sendable (BodyRef) throws -> HTTPBodyReadLease

extension MockBlockReason {
    public var localizationKey: String {
        switch self {
        case .tunnel: "rules.mock.blocked.tunnel"
        case .noResponse: "rules.mock.blocked.noResponse"
        case .upgrade: "rules.mock.blocked.upgrade"
        case .statusNotMockable: "rules.mock.blocked.statusNotMockable"
        case .bodyTruncated: "rules.mock.blocked.bodyTruncated"
        case .bodyIncomplete: "rules.mock.blocked.bodyIncomplete"
        case .bodyTooLarge: "rules.mock.blocked.bodyTooLarge"
        }
    }

    public var localizedDescription: String { L10n.string(localizationKey) }
}

/// Pure pieces of "save the response as a mock rule": the draft itself and the bounded body reader.
enum ResponseMockDraft {
    /// A Map Local draft whose matcher is the client's original request (R32) and whose response
    /// is the captured one. Nothing is saved.
    static func make(from flow: Flow, source: ResponseMockSource, asset: ManagedAsset) -> RuleEditorDraft {
        var draft = RuleEditorDraft.fromFlow(flow, kind: .mapLocal)
        draft.name = L10n.format("rules.mock.draftName", draft.match.host)
        draft.mapLocal.asset = asset
        draft.mapLocal.status = String(source.status)
        draft.mapLocal.headers = source.headers.map { HeaderFieldRow(name: $0.name, value: $0.value) }
        return draft
    }

    /// The `read` closure for a managed-asset stream import: offsets count from the start of the
    /// slice, every answer is at most 64 KiB and never reaches past the slice, however much is asked.
    static func reader(
        lease: HTTPBodyReadLease, slice: HTTPBodySlice, progress: @escaping @Sendable (Int64) async -> Void
    ) -> @Sendable (Int64, Int) async throws -> Data {
        { offset, maxBytes in
            await progress(offset)
            let remaining = Int64(slice.count) - offset
            guard offset >= 0, remaining > 0 else { return Data() }
            let wanted = Int(min(Int64(min(maxBytes, HTTPBodyReadLease.maxReadBytes)), remaining))
            guard wanted > 0 else { return Data() }
            return try await lease.read(offset: slice.offset + Int(offset), maxBytes: wanted)
        }
    }
}
