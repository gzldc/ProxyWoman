import FlowStore
import Foundation
import Localization
import RulesEngine

public enum ReplayBlockReason: String, Error, Sendable, CaseIterable {
    case bodyOnDisk
    case bodyTooLarge
    case bodyTruncated
    case bodyIncomplete

    public var localizationKey: String {
        switch self {
        case .bodyOnDisk: "replay.blocked.bodyOnDisk"
        case .bodyTooLarge: "replay.blocked.bodyTooLarge"
        case .bodyTruncated: "replay.blocked.bodyTruncated"
        case .bodyIncomplete: "replay.blocked.bodyIncomplete"
        }
    }
    public var localizedDescription: String { L10n.string(localizationKey) }
}

/// Eligibility for an explicit replay of the captured original request. This never loads a body,
/// stats a path, or evaluates implicit transport retry policy. T11 must use the same boundary.
public enum ReplayEligibility {
    public static func evaluate(flow: Flow) -> Result<Void, ReplayBlockReason> {
        let limit = 1_048_576
        if let request = flow.messages[.downstreamRequest] {
            if isOnDisk(request.body?.ref) { return .failure(.bodyOnDisk) }
            if request.bodyState == .truncated { return .failure(.bodyTruncated) }
            if request.observedBytes > UInt64(limit) || (request.body?.count ?? 0) > limit { return .failure(.bodyTooLarge) }
            guard request.bodyState == .complete, request.transferState == .finished else { return .failure(.bodyIncomplete) }
            if let body = request.body {
                guard body.offset <= body.ref.size, body.count <= body.ref.size - body.offset,
                      UInt64(body.count) == request.observedBytes else { return .failure(.bodyIncomplete) }
            } else if request.observedBytes != 0 { return .failure(.bodyIncomplete) }
            return .success(())
        }
        if isOnDisk(flow.requestBody) { return .failure(.bodyOnDisk) }
        if flow.requestBodyTruncated { return .failure(.bodyTruncated) }
        if flow.bytesSent > limit || (flow.requestBody?.size ?? 0) > limit { return .failure(.bodyTooLarge) }
        guard flow.state == .completed, flow.bytesSent >= 0,
              (flow.requestBody?.size ?? 0) == flow.bytesSent else { return .failure(.bodyIncomplete) }
        return .success(())
    }

    private static func isOnDisk(_ body: BodyRef?) -> Bool {
        switch body {
        case .file: true
        case .managed(let handle): handle.isOnDisk
        case .memory, nil: false
        }
    }
}

/// What Compose does with the original request body of a captured flow (spec C3, C7). Unlike
/// `ReplayEligibility`, which gates one-click Replay and Repeat and stays strict, a complete body
/// that is on disk or larger than 1 MiB can still be brought in by streaming it through a read
/// lease into a managed asset, up to the asset size limit. Nothing here loads a body, stats a path
/// or opens a lease.
public enum ComposeImportEligibility: Sendable, Equatable {
    /// Complete, in memory and at most 1 MiB: the draft reads it directly (same as Replay).
    case inline
    /// Complete but on disk or larger than 1 MiB, within the asset size limit.
    case importable(HTTPBodySlice)
    /// Truncated, incomplete, or over the asset size limit.
    case blocked(ReplayBlockReason)

    /// The in-memory ceiling shared with `ReplayEligibility`.
    static let inlineLimit = 1_048_576

    /// Judges the body of `boundary`, which must be a request boundary. Only `.downstreamRequest`
    /// falls back to the legacy flow fields when it has no snapshot.
    public static func evaluate(flow: Flow, boundary: HTTPMessageBoundary) -> ComposeImportEligibility {
        let maximum = RulesLimits().assetFileBytes
        guard let message = flow.messages[boundary] else {
            return boundary == .downstreamRequest ? legacy(flow, maximum: maximum) : .blocked(.bodyIncomplete)
        }
        if message.bodyState == .truncated { return .blocked(.bodyTruncated) }
        if message.observedBytes > UInt64(maximum) || (message.body?.count ?? 0) > maximum { return .blocked(.bodyTooLarge) }
        guard message.bodyState == .complete, message.transferState == .finished else { return .blocked(.bodyIncomplete) }
        guard let body = message.body else {
            return message.observedBytes == 0 ? .inline : .blocked(.bodyIncomplete)
        }
        guard body.offset <= body.ref.size, body.count <= body.ref.size - body.offset,
              UInt64(body.count) == message.observedBytes else { return .blocked(.bodyIncomplete) }
        return isInline(body.ref, count: body.count) ? .inline : .importable(body)
    }

    private static func legacy(_ flow: Flow, maximum: Int) -> ComposeImportEligibility {
        if flow.requestBodyTruncated { return .blocked(.bodyTruncated) }
        if flow.bytesSent > maximum || (flow.requestBody?.size ?? 0) > maximum { return .blocked(.bodyTooLarge) }
        guard flow.state == .completed, flow.bytesSent >= 0,
              (flow.requestBody?.size ?? 0) == flow.bytesSent else { return .blocked(.bodyIncomplete) }
        guard let body = flow.requestBody else { return .inline }
        return isInline(body, count: body.size) ? .inline : .importable(HTTPBodySlice(ref: body, offset: 0, count: body.size))
    }

    private static func isInline(_ ref: BodyRef, count: Int) -> Bool {
        let onDisk: Bool
        switch ref {
        case .file: onDisk = true
        case .managed(let handle): onDisk = handle.isOnDisk
        case .memory: onDisk = false
        }
        return !onDisk && count <= inlineLimit
    }
}
