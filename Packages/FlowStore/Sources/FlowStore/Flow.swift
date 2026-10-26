import Foundation

public struct HeaderField: Sendable, Hashable, Codable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

extension Array where Element == HeaderField {
    /// 大小写不敏感，取第一个匹配项。
    public func value(for name: String) -> String? {
        first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public func values(for name: String) -> [String] {
        filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }
}

public struct ClientApp: Sendable, Hashable {
    public var pid: Int32
    public var name: String
    public var executablePath: String?

    public init(pid: Int32, name: String, executablePath: String? = nil) {
        self.pid = pid
        self.name = name
        self.executablePath = executablePath
    }
}

public enum FlowState: Sendable, Equatable {
    case inProgress
    case completed
    case failed(String)
    case tunnel
}

public enum BodyRef: Sendable, Equatable {
    /// Borrowed compatibility input: counted by size, never deleted by the store.
    case memory(Data)
    /// Borrowed compatibility input: the store never deletes this file, wherever it lives.
    case file(URL, size: Int)
    /// A body the store created and registered; only these may be reclaimed by the store.
    case managed(HTTPBodyHandle)

    public var size: Int {
        switch self {
        case .memory(let data): data.count
        case .file(_, let size): size
        case .managed(let handle): handle.size
        }
    }

    public func load() throws -> Data {
        switch self {
        case .memory(let data): data
        case .file(let url, _): try Data(contentsOf: url)
        case .managed(let handle): try handle.load(maxBytes: handle.size).data
        }
    }

    /// Reads `[offset, offset + maxBytes)` clamped to the body; never reads the whole body into memory.
    public func load(offset: Int, maxBytes: Int) throws -> Data {
        let start = max(0, offset)
        let wanted = max(0, min(maxBytes, size - start))
        guard wanted > 0 else { return Data() }
        switch self {
        case .memory(let data):
            let from = data.startIndex + start
            return Data(data[from..<from + wanted])
        case .file(let url, _):
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(start))
            return try handle.read(upToCount: wanted) ?? Data()
        case .managed(let handle):
            return try handle.load(offset: start, maxBytes: wanted)
        }
    }

    /// 最多读取 `maxBytes` 字节；落盘的 body 只读文件开头，不会整个读进内存。
    public func load(maxBytes: Int) throws -> (data: Data, isTruncated: Bool) {
        let limit = max(0, maxBytes)
        switch self {
        case .memory(let data):
            return (data.prefix(limit), data.count > limit)
        case .file(let url, _):
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: limit) ?? Data()
            guard data.count == limit else { return (data, false) }
            let next = try handle.read(upToCount: 1) ?? Data()
            return (data, !next.isEmpty)
        case .managed(let handle):
            return try handle.load(maxBytes: limit)
        }
    }
}

public struct Flow: Identifiable, Sendable, Equatable {
    public let id: Int
    public var startedAt: Date
    public var completedAt: Date?
    /// "http" | "https"
    public var scheme: String
    public var method: String
    public var host: String
    public var port: Int
    /// origin-form，包含 query。
    public var path: String
    /// Independent message-boundary versions; unknown values stay nil.
    public var transport: HTTPTransportMetadata
    /// Trailing fields in arrival order, separate from the initial headers.
    public var requestTrailers: [HeaderField]
    public var responseTrailers: [HeaderField]
    public var requestHeaders: [HeaderField]
    public var requestBody: BodyRef?
    /// 正文超过记录上限（或无法落盘），`requestBody` 只是前缀。
    public var requestBodyTruncated: Bool
    public var statusCode: Int?
    public var statusReason: String?
    public var responseHeaders: [HeaderField]
    public var responseBody: BodyRef?
    /// 正文超过记录上限（或无法落盘），`responseBody` 只是前缀。
    public var responseBodyTruncated: Bool
    public var state: FlowState
    public var client: ClientApp?
    public var note: String?
    /// 隧道和普通请求都统计 body 字节。
    public var bytesSent: Int
    public var bytesReceived: Int
    /// What each message boundary actually carried. Empty for legacy flows, which keep the old
    /// request*/response* projection (downstream request, upstream response) and claim nothing more.
    public var messages: [HTTPMessageBoundary: HTTPMessageSnapshot]
    public var provenance: FlowProvenance
    public var ruleMark: FlowMark?
    public var manualMark: FlowMark?
    public var comment: String?
    public var isHidden: Bool
    /// Client peer address of the downstream connection; nil when unknown.
    public var clientIP: String? = nil
    /// Address the upstream connection actually reached; nil when unknown.
    public var remoteIP: String? = nil
    /// Leaf certificate the upstream server presented; nil for plain HTTP or when unknown.
    public var upstreamCertificate: CertificateSummary? = nil
    /// Session-only message versions from an Execute run; nil when none was produced.
    public var executeOverlay: ExecuteOverlay? = nil
    /// The last Execute run's record (baseline, written values, matches); nil when never executed.
    public var execute: ExecuteRecord? = nil
    /// True while the proxy holds this exchange at a request or response breakpoint. Transient: never
    /// exported or archived; the live count reads it as the session state "paused".
    public var isPausedAtBreakpoint: Bool = false

    public init(
        id: Int,
        startedAt: Date = .now,
        scheme: String,
        method: String,
        host: String,
        port: Int,
        path: String,
        requestHeaders: [HeaderField] = []
    ) {
        self.id = id
        self.startedAt = startedAt
        self.completedAt = nil
        self.scheme = scheme
        self.method = method
        self.host = host
        self.port = port
        self.path = path
        self.transport = .init()
        self.requestTrailers = []
        self.responseTrailers = []
        self.requestHeaders = requestHeaders
        self.requestBody = nil
        self.requestBodyTruncated = false
        self.statusCode = nil
        self.statusReason = nil
        self.responseHeaders = []
        self.responseBody = nil
        self.responseBodyTruncated = false
        self.state = .inProgress
        self.client = nil
        self.note = nil
        self.bytesSent = 0
        self.bytesReceived = 0
        self.messages = [:]
        self.provenance = .unknown
        self.ruleMark = nil
        self.manualMark = nil
        self.comment = nil
        self.isHidden = false
    }

    /// The message the client (or the Compose virtual client) actually saw: downstream for passive
    /// flows, the submitted/delivered pair for Compose. Nil when that boundary never happened.
    public func clientVisibleMessage(_ direction: HTTPMessageDirection) -> HTTPMessageSnapshot? {
        let boundary: HTTPMessageBoundary
        switch (provenance.isCompose, direction) {
        case (true, .request): boundary = .composeSubmitted
        case (true, .response): boundary = .composeDelivered
        case (false, .request): boundary = .downstreamRequest
        case (false, .response): boundary = .downstreamResponse
        }
        return messages[boundary]
    }

    /// 默认端口（http 80、https 443）不写进 URL；CONNECT 返回 "host:port"。
    public var url: String {
        if method == "CONNECT" { return "\(host):\(port)" }
        let isDefaultPort = (scheme == "http" && port == 80) || (scheme == "https" && port == 443)
        return "\(scheme)://\(host)\(isDefaultPort ? "" : ":\(port)")\(path)"
    }

    public var duration: TimeInterval? {
        completedAt.map { $0.timeIntervalSince(startedAt) }
    }
}
