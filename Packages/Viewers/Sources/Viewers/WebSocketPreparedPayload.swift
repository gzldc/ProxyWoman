import Foundation
import FlowStore

public enum WebSocketPreparedStatus: String, Sendable { case available, invalid, incomplete, truncated, opaque }
public struct WebSocketPreparedPayload: Sendable, Equatable {
    public let bytes: Data
    public let text: String?
    public let json: JSONNode?
    public let status: WebSocketPreparedStatus
    public let displayTruncated: Bool

    public static func prepare(snapshot: WebSocketPayloadSnapshot, event: WebSocketEventMetadata,
                               attemptBinaryUTF8: Bool) async -> Self {
        await prepare(snapshot: snapshot, event: event, kind: .application, attemptBinaryUTF8: attemptBinaryUTF8)
    }

    public static func prepare(snapshot: WebSocketPayloadSnapshot, event: WebSocketEventMetadata,
                               kind: WebSocketPayloadKind, attemptBinaryUTF8: Bool) async -> Self {
        let work = Task.detached(priority: .userInitiated) {
            let bytes = Data(snapshot.bytes.prefix(262_144))
            let displayTruncated = snapshot.offset != 0 || snapshot.totalRetainedBytes > bytes.count
            let truncated = snapshot.truncated || event.integrity == .captureTruncated || displayTruncated
            let incomplete = event.completedAt == nil || event.captureAbandoned || !snapshot.complete
                || [.incompleteTransport, .partialPaused, .observationStopped].contains(event.integrity)
            let opaque = event.kind == .opaqueFrame || event.integrity == .opaque
            var status: WebSocketPreparedStatus = opaque ? .opaque : event.integrity == .invalid || (kind == .application && event.utf8 == .invalid) ? .invalid : incomplete ? .incomplete : truncated ? .truncated : .available
            var text: String?
            if (kind == .wirePayload && attemptBinaryUTF8) || (!opaque && kind == .application && (event.kind == .text || attemptBinaryUTF8)) {
                text = String(data: bytes, encoding: .utf8)
                // Only the trailing incomplete scalar may be omitted from a prefix preview.
                if text == nil && (truncated || incomplete) {
                    for dropped in 1...min(3, bytes.count) {
                        let prefix = bytes.dropLast(dropped)
                        let tail = bytes.suffix(dropped)
                        guard let first = tail.first, (0xC2...0xF4).contains(first),
                              tail.dropFirst().allSatisfy({ (0x80...0xBF).contains($0) }) else { continue }
                        let expected = first < 0xE0 ? 2 : first < 0xF0 ? 3 : 4
                        if dropped < expected, let valid = String(data: prefix, encoding: .utf8) { text = valid; break }
                    }
                }
                if text == nil && !truncated && !incomplete { status = .invalid }
            }
            let eligible = kind == .application && event.kind == .text && event.utf8 == .valid && event.integrity == .transportComplete
                && !incomplete && !truncated && !event.lowerBound && snapshot.offset == 0
                && event.decodedBytes == UInt64(bytes.count) && text != nil && !Task.isCancelled
            return Self(bytes: bytes, text: text, json: eligible ? try? JSONParser.parse(bytes) : nil,
                        status: status, displayTruncated: displayTruncated)
        }
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }
}
