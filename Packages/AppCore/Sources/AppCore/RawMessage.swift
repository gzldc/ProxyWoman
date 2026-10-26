import FlowStore
import Foundation
import Localization
import Viewers

/// Reconstructs HTTP messages from the captured fields, preserving header order.
/// May read a spilled body; callers run this work off the main actor.
///
/// Without a `boundary` the legacy projection is used (downstream request, upstream response).
/// With one, the text is that boundary's own start line, version, ordered headers, trailers and
/// body range; a boundary that never happened says so instead of showing another message.
public enum RawMessage {
    private static let textLimit = 2 * 1024 * 1024

    public static func request(
        _ flow: Flow, boundary: HTTPMessageBoundary? = nil, localizer: Localizer = L10n.localizer
    ) -> String {
        if let boundary {
            guard let snapshot = flow.messages[boundary], let target = snapshot.target else {
                return localizer.string("rawMessage.boundaryUnavailable")
            }
            return render(
                snapshot, start: "\(target.method) \(target.pathAndQuery) \(snapshot.wireVersion?.rawValue ?? "HTTP/?")",
                localizer: localizer)
        }
        return annotate(message(
            start: "\(flow.method) \(flow.path) \(flow.transport.downstreamRequest?.rawValue ?? "HTTP/?")", headers: flow.requestHeaders,
            body: flow.requestBody.map(BodySource.ref), captureTruncated: flow.requestBodyTruncated, localizer: localizer),
            version: flow.transport.downstreamRequest, trailers: flow.requestTrailers, localizer: localizer)
    }

    public static func response(
        _ flow: Flow, boundary: HTTPMessageBoundary? = nil, localizer: Localizer = L10n.localizer
    ) -> String {
        if let boundary {
            guard let snapshot = flow.messages[boundary], let status = snapshot.status else {
                return localizer.string("rawMessage.boundaryUnavailable")
            }
            let reason = snapshot.reason.flatMap { $0.isEmpty ? nil : " " + $0 } ?? ""
            return render(
                snapshot, start: "\(snapshot.wireVersion?.rawValue ?? "HTTP/?") \(status)\(reason)", localizer: localizer)
        }
        guard let status = flow.statusCode else { return localizer.string("rawMessage.responsePending") }
        let reason = flow.statusReason.flatMap { $0.isEmpty ? nil : " " + $0 } ?? ""
        return annotate(message(
            start: "\(flow.transport.upstreamResponse?.rawValue ?? "HTTP/?") \(status)\(reason)", headers: flow.responseHeaders,
            body: flow.responseBody.map(BodySource.ref), captureTruncated: flow.responseBodyTruncated, localizer: localizer),
            version: flow.transport.upstreamResponse, trailers: flow.responseTrailers, localizer: localizer)
    }

    private enum BodySource {
        case ref(BodyRef)
        case slice(HTTPBodySlice)

        var size: Int {
            switch self {
            case .ref(let ref): ref.size
            case .slice(let slice): slice.count
            }
        }

        func load(maxBytes: Int) throws -> (data: Data, isTruncated: Bool) {
            switch self {
            case .ref(let ref): try ref.load(maxBytes: maxBytes)
            case .slice(let slice): try slice.load(maxBytes: maxBytes)
            }
        }
    }

    /// One boundary's message. The note after the body says why the body is not the whole entity.
    private static func render(_ snapshot: HTTPMessageSnapshot, start: String, localizer: Localizer) -> String {
        let note: String?
        switch snapshot.bodyState {
        case .complete: note = nil
        case .pending: note = localizer.string("rawMessage.bodyPending")
        case .truncated: note = localizer.string("rawMessage.captureTruncated")
        case .incomplete: note = localizer.string("rawMessage.bodyIncomplete")
        case .unavailable: note = localizer.string("rawMessage.bodyUnavailable")
        }
        return annotate(message(
            start: start, headers: snapshot.headers, body: snapshot.body.map(BodySource.slice), note: note,
            localizer: localizer),
            version: snapshot.wireVersion, trailers: snapshot.trailers, localizer: localizer)
    }

    /// Annotations are visibly outside the reconstructed start/header/body representation.
    /// The body is loaded once by message(); trailers never trigger another read.
    private static func annotate(_ message: String, version: HTTPWireVersion?, trailers: [HeaderField],
                                 localizer: Localizer) -> String {
        var result = version == .http2
            ? "<" + localizer.string("httpTransport.reconstructed") + ">\r\n\r\n" + message : message
        if !trailers.isEmpty {
            result += "\r\n\r\n<" + localizer.string("httpTransport.capturedTrailers") + ">\r\n"
            result += trailers.map { "\($0.name): \($0.value)" }.joined(separator: "\r\n")
        }
        return result
    }

    private static func message(
        start: String, headers: [HeaderField], body: BodySource?, captureTruncated: Bool, localizer: Localizer
    ) -> String {
        message(
            start: start, headers: headers, body: body,
            note: captureTruncated ? localizer.string("rawMessage.captureTruncated") : nil, localizer: localizer)
    }

    private static func message(
        start: String, headers: [HeaderField], body: BodySource?, note: String?, localizer: Localizer
    ) -> String {
        let header = ([start] + headers.map { "\($0.name): \($0.value)" }).joined(separator: "\r\n")
        var result = header + "\r\n\r\n"
        if let body {
            do {
                let loaded = try body.load(maxBytes: textLimit + 4)
                let capped = loaded.isTruncated || loaded.data.count > textLimit
                let data = Data(loaded.data.prefix(textLimit))
                var text: String?
                // Judge decoded characters: UTF-16 text legitimately contains zero bytes.
                for backoff in 0...(capped ? min(3, data.count) : 0) {
                    if let decoded = TextDecoding.string(
                        from: Data(data.dropLast(backoff)), contentType: headers.value(for: "content-type")),
                        !decoded.unicodeScalars.contains(where: { $0.value < 32 && ![9, 10, 13].contains($0.value) })
                    {
                        text = decoded
                        break
                    }
                }
                if let text {
                    result += text
                    if capped { result += localizer.string("rawMessage.displayTruncated") }
                } else {
                    result += localizer.format("rawMessage.binaryBody", arguments: [body.size])
                }
            } catch {
                result += localizer.format("rawMessage.bodyReadFailed", arguments: [error.localizedDescription])
            }
        }
        if let note { result += note }
        return result
    }
}

/// Metadata-only identity for the Raw panel's asynchronous text task. Creating it never reads a body.
public struct RawMessagePresentationKey: Equatable, Sendable {
    private let id: Int
    private let isRequest: Bool
    private let boundary: HTTPMessageBoundary?
    private let method: String?
    private let path: String?
    private let version: HTTPWireVersion?
    private let headers: [HeaderField]
    private let trailers: [HeaderField]
    private let size: Int?
    private let truncated: Bool
    private let status: Int?
    private let reason: String?
    private let bodyState: HTTPBodyState?
    private let observedBytes: UInt64?
    private let transferState: HTTPTransferState?
    private let present: Bool

    public init(flow: Flow, isRequest: Bool, boundary: HTTPMessageBoundary? = nil) {
        id = flow.id
        self.isRequest = isRequest
        self.boundary = boundary
        if let boundary {
            let snapshot = flow.messages[boundary]
            present = snapshot != nil
            method = snapshot?.target?.method
            path = snapshot?.target?.pathAndQuery
            version = snapshot?.wireVersion
            headers = snapshot?.headers ?? []
            trailers = snapshot?.trailers ?? []
            size = snapshot?.body?.count
            truncated = snapshot.map { $0.bodyState != .complete } ?? false
            status = snapshot?.status
            reason = snapshot?.reason
            bodyState = snapshot?.bodyState
            observedBytes = snapshot?.observedBytes
            transferState = snapshot?.transferState
            return
        }
        present = true
        bodyState = nil
        observedBytes = nil
        transferState = nil
        method = isRequest ? flow.method : nil
        path = isRequest ? flow.path : nil
        version = isRequest ? flow.transport.downstreamRequest : flow.transport.upstreamResponse
        headers = isRequest ? flow.requestHeaders : flow.responseHeaders
        trailers = isRequest ? flow.requestTrailers : flow.responseTrailers
        size = isRequest ? flow.requestBody?.size : flow.responseBody?.size
        truncated = isRequest ? flow.requestBodyTruncated : flow.responseBodyTruncated
        status = isRequest ? nil : flow.statusCode
        reason = isRequest ? nil : flow.statusReason
    }
}
