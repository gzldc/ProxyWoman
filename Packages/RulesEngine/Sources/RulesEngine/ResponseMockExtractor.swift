import FlowStore
import Foundation

/// Why a captured flow cannot become a response mock. Raw values are the stable suffix of the
/// localization keys the UI shows (`rules.mock.blocked.<rawValue>`).
public enum MockBlockReason: String, Error, Sendable, Equatable, CaseIterable {
    /// A CONNECT tunnel: there is no HTTP response to keep.
    case tunnel
    /// The flow never got a final response (still running, or failed before one).
    case noResponse
    /// A protocol switch (101 / Upgrade): not an ordinary response.
    case upgrade
    /// Not a final status a local response can send (1xx other than 101, or outside 200...599).
    case statusNotMockable
    /// The capture kept only a prefix of the body.
    case bodyTruncated
    /// The body is still arriving, ended early, or could not be kept completely.
    case bodyIncomplete
    /// The body is larger than one managed asset may be.
    case bodyTooLarge
}

/// What a response mock keeps of a captured response: status, the usable headers and a bounded
/// view of the body. Nothing is read or copied here.
public struct ResponseMockSource: Sendable, Equatable {
    public var status: Int
    /// Filtered per the mock header rule; order and duplicates are kept.
    public var headers: [HeaderField]
    /// nil = empty body.
    public var body: HTTPBodySlice?
    public var size: Int64
    /// The asset's display name (a file name, not text for the user).
    public var displayName: String

    public init(status: Int, headers: [HeaderField], body: HTTPBodySlice?, size: Int64, displayName: String) {
        self.status = status
        self.headers = headers
        self.body = body
        self.size = size
        self.displayName = displayName
    }
}

/// Takes the response the client actually received out of a captured flow (pure, Foundation only).
public enum ResponseMockExtractor {
    /// Response header names (lower case) a local response never keeps: connection-level and framing
    /// fields. The shared edit validator rejects a few more (for example `Host`); those go too.
    public static let droppedHeaderNames: Set<String> = [
        "connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "proxy-connection",
        "te", "trailer", "transfer-encoding", "upgrade", "content-length",
    ]

    static let assetDisplayName = "response-body.bin"

    private struct Picked {
        var status: Int
        var headers: [HeaderField]
        var body: HTTPBodySlice?
        var bodyState: HTTPBodyState
        var observedBytes: UInt64
        var transferState: HTTPTransferState
    }

    public static func extract(
        from flow: Flow, limits: RulesLimits = RulesLimits()
    ) -> Result<ResponseMockSource, MockBlockReason> {
        if flow.method.uppercased() == "CONNECT" || flow.state == .tunnel { return .failure(.tunnel) }
        guard let picked = pick(from: flow) else { return .failure(.noResponse) }
        if picked.status == 101 { return .failure(.upgrade) }
        guard (200...599).contains(picked.status) else { return .failure(.statusNotMockable) }
        if picked.bodyState == .truncated { return .failure(.bodyTruncated) }
        let kept = Int64(picked.body?.count ?? 0)
        guard picked.bodyState == .complete, picked.transferState == .finished,
              picked.observedBytes <= UInt64(Int64.max), Int64(picked.observedBytes) == kept else {
            return .failure(.bodyIncomplete)
        }
        guard kept <= Int64(limits.assetFileBytes) else { return .failure(.bodyTooLarge) }
        return .success(ResponseMockSource(
            status: picked.status, headers: keptHeaders(picked.headers),
            body: kept > 0 ? picked.body : nil, size: kept, displayName: assetDisplayName))
    }

    /// The client-received boundary, then the proxy's own response, then the legacy fields.
    private static func pick(from flow: Flow) -> Picked? {
        for boundary in [HTTPMessageBoundary.downstreamResponse, .generatedResponse] {
            guard let snapshot = flow.messages[boundary] else { continue }
            guard let status = snapshot.status else { return nil }
            return Picked(
                status: status, headers: snapshot.headers, body: snapshot.body, bodyState: snapshot.bodyState,
                observedBytes: snapshot.observedBytes, transferState: snapshot.transferState)
        }
        // Boundary snapshots exist but none is a response the client got: nothing to keep.
        guard flow.messages.isEmpty, let status = flow.statusCode else { return nil }
        let body = flow.responseBody.map { HTTPBodySlice(ref: $0, offset: 0, count: $0.size) }
        return Picked(
            status: status, headers: flow.responseHeaders, body: body,
            bodyState: flow.responseBodyTruncated ? .truncated : .complete,
            observedBytes: UInt64(max(0, flow.bytesReceived)),
            transferState: flow.state == .completed ? .finished : .failed)
    }

    /// Drops the framing/hop-by-hop names and every field the shared validator would reject on its
    /// own (judged against the full original block, so `Connection`-nominated fields go too).
    private static func keptHeaders(_ headers: [HeaderField]) -> [HeaderField] {
        headers.filter { field in
            guard !droppedHeaderNames.contains(field.name.lowercased()) else { return false }
            return (try? HTTPMutationValidator.validateEdits(
                [.append(name: field.name, value: field.value)], originalHeaders: headers)) != nil
        }
    }
}
