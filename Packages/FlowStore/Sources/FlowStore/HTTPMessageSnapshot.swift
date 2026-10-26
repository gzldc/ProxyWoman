import Foundation

/// The seven places an HTTP message can be observed or produced. The first four are the real
/// wire boundaries of a proxied exchange; the others are explicit generated/virtual sources.
public enum HTTPMessageBoundary: String, Sendable, Codable, CaseIterable, Hashable {
    /// The client's original input, as read by the proxy.
    case downstreamRequest
    /// What the origin side actually accepted from the proxy writer.
    case upstreamRequest
    /// The origin's original final response, as read by the proxy.
    case upstreamResponse
    /// What the client side actually accepted from the proxy writer.
    case downstreamResponse
    /// A response the proxy produced itself (local failure, Map Local); never an origin response.
    case generatedResponse
    /// The frozen request a Compose send was submitted with (virtual client endpoint).
    case composeSubmitted
    /// The result delivered to a Compose send (virtual client endpoint).
    case composeDelivered

    /// True when the proxy reads this message from a peer; false when the proxy writes it.
    public var isReceived: Bool {
        switch self {
        case .downstreamRequest, .upstreamResponse: true
        case .upstreamRequest, .downstreamResponse, .generatedResponse, .composeSubmitted, .composeDelivered: false
        }
    }
}

public enum HTTPMessageDirection: String, Sendable, Equatable, Hashable, Codable {
    case request
    case response
}

/// Where a request message was addressed. `pathAndQuery` is origin-form, query included.
public struct HTTPMessageTarget: Sendable, Equatable, Hashable, Codable {
    public var scheme: String
    public var host: String
    public var port: Int
    public var method: String
    public var pathAndQuery: String

    public init(scheme: String, host: String, port: Int, method: String, pathAndQuery: String) {
        self.scheme = scheme
        self.host = host
        self.port = port
        self.method = method
        self.pathAndQuery = pathAndQuery
    }

    /// Default ports are omitted, like `Flow.url`.
    public var url: String {
        let isDefaultPort = (scheme == "http" && port == 80) || (scheme == "https" && port == 443)
        return "\(scheme)://\(host)\(isDefaultPort ? "" : ":\(port)")\(pathAndQuery)"
    }
}

/// Start line and ordered initial header fields of one message.
public enum HTTPMessageHead: Sendable, Equatable {
    case request(HTTPMessageTarget, headers: [HeaderField])
    case response(status: Int, reason: String?, headers: [HeaderField])

    public var headers: [HeaderField] {
        switch self {
        case .request(_, let headers), .response(_, _, let headers): headers
        }
    }
}

/// How much of the body this boundary can show.
public enum HTTPBodyState: String, Sendable, Codable, Equatable {
    /// The transfer or the capture is still running.
    case pending
    /// Every byte of the message at this boundary is readable (an empty body is complete with no slice).
    case complete
    /// The boundary saw more bytes than the capture kept: the slice is a prefix.
    case truncated
    /// The transfer ended before the whole entity passed this boundary.
    case incomplete
    /// Bytes passed this boundary but none could be kept.
    case unavailable
}

public enum HTTPTransferState: String, Sendable, Codable, Equatable {
    /// The proxy read this message from a peer and is still reading it.
    case observed
    /// The writer accepted the head; the rest of the message has not all been accepted yet.
    case acceptedByWriter
    /// The writer stopped (failed or the exchange ended) after accepting only part of the message.
    /// This is not proof that the remote application received anything.
    case partiallySent
    case finished
    /// A received message ended abnormally.
    case failed
}

/// A bounded view of the captured bytes `[offset, offset + count)` of one shared body.
/// `count` is what actually passed the boundary; reads clamp to what the capture really kept.
public struct HTTPBodySlice: Sendable, Equatable {
    public let ref: BodyRef
    public let offset: Int
    public let count: Int

    public init(ref: BodyRef, offset: Int, count: Int) {
        self.ref = ref
        self.offset = max(0, offset)
        self.count = max(0, count)
    }

    /// Reads at most `maxBytes` of the slice, never past the kept body.
    public func load(maxBytes: Int) throws -> (data: Data, isTruncated: Bool) {
        let available = max(0, min(count, ref.size - offset))
        let limit = max(0, min(maxBytes, available))
        let loaded = try ref.load(offset: offset, maxBytes: limit)
        return (loaded, available > limit)
    }

    public func load() throws -> Data { try load(maxBytes: count).data }
}

/// What one boundary actually carried, kept next to the other boundaries instead of overwriting them.
public struct HTTPMessageSnapshot: Sendable, Equatable {
    public var boundary: HTTPMessageBoundary
    public var head: HTTPMessageHead
    public var trailers: [HeaderField]
    /// Wire version of this boundary; nil when unknown or when the endpoint is virtual.
    public var wireVersion: HTTPWireVersion?
    public var streamID: Int?
    public var body: HTTPBodySlice?
    public var bodyState: HTTPBodyState
    /// Body bytes that passed this boundary (independent of how many the capture kept).
    public var observedBytes: UInt64
    public var transferState: HTTPTransferState

    public init(
        boundary: HTTPMessageBoundary, head: HTTPMessageHead, trailers: [HeaderField] = [],
        wireVersion: HTTPWireVersion? = nil, streamID: Int? = nil, body: HTTPBodySlice? = nil,
        bodyState: HTTPBodyState = .pending, observedBytes: UInt64 = 0,
        transferState: HTTPTransferState = .observed
    ) {
        self.boundary = boundary
        self.head = head
        self.trailers = trailers
        self.wireVersion = wireVersion
        self.streamID = streamID
        self.body = body
        self.bodyState = bodyState
        self.observedBytes = observedBytes
        self.transferState = transferState
    }

    public var headers: [HeaderField] { head.headers }

    public var target: HTTPMessageTarget? {
        if case .request(let target, _) = head { target } else { nil }
    }

    public var status: Int? {
        if case .response(let status, _, _) = head { status } else { nil }
    }

    public var reason: String? {
        if case .response(_, let reason, _) = head { reason } else { nil }
    }
}
