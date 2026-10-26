import Foundation

public enum HARExporter {
    /// 导出 HAR 1.2。CONNECT（隧道和握手失败的记录）不导出，它们没有 HAR 能表示的 URL；读取不到的 body 按空内容导出。
    /// 被规则隐藏的记录默认不导出，`includeHidden` 为 true 时才包含。
    /// 存储的 body 是线上原始字节。`decodeBody` 用来解压：响应带 Content-Encoding 头时才调用，
    /// 返回 nil 就按原始字节导出。
    /// Each entry's custom `_proxywoman` object contains optional `upstreamRequestVersion`,
    /// `upstreamResponseVersion`, `downstreamStreamID`, `upstreamStreamID`, and ordered
    /// `requestTrailers` / `responseTrailers` name/value arrays, separate from initial headers.
    /// Flows recorded with boundary snapshots export the client-visible request/response
    /// (downstream, or the Compose submitted/delivered virtual endpoints, whose `httpVersion` is
    /// empty); the origin-side message is described, never merged in, under `_proxywoman.boundaries`
    /// together with `_proxywoman.provenance`. Legacy flows keep the old field projection.
    public static func export(
        _ flows: [Flow],
        creatorName: String,
        creatorVersion: String,
        includeHidden: Bool = false,
        decodeBody: (_ data: Data, _ contentEncoding: String?) -> Data? = { _, _ in nil }
    ) throws -> Data {
        try export(flows, creatorName: creatorName, creatorVersion: creatorVersion,
                   webSocketSummaryForFlow: { _ in nil }, includeHidden: includeHidden, decodeBody: decodeBody)
    }

    public static func export(
        _ flows: [Flow], creatorName: String, creatorVersion: String,
        webSocketSummaryForFlow: (Flow) -> WebSocketHARSummary?,
        includeHidden: Bool = false,
        decodeBody: (_ data: Data, _ contentEncoding: String?) -> Data? = { _, _ in nil }
    ) throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let entries = flows
            .filter { includeHidden || !$0.isHidden }
            .filter { $0.method != "CONNECT" && $0.state != .tunnel }
            .map { entry(for: $0, formatter: formatter, webSocket: webSocketSummaryForFlow($0), decodeBody: decodeBody) }
        let har = HAR(log: .init(
            version: "1.2",
            creator: .init(name: creatorName, version: creatorVersion),
            entries: entries
        ))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return try encoder.encode(har)
    }

    private static func entry(
        for flow: Flow,
        formatter: ISO8601DateFormatter,
        webSocket: WebSocketHARSummary?,
        decodeBody: (Data, String?) -> Data?
    ) -> HAR.Entry {
        let time = (flow.duration ?? 0) * 1000
        let snapshots = !flow.messages.isEmpty
        var unreadable: Set<HTTPMessageBoundary> = []
        let requestSnapshot = flow.clientVisibleMessage(.request)
        let responseSnapshot = flow.clientVisibleMessage(.response)
        let requestEntry = snapshots ? request(for: flow, snapshot: requestSnapshot, unreadable: &unreadable) : request(for: flow)
        let responseEntry = snapshots
            ? response(snapshot: responseSnapshot, decodeBody: decodeBody, unreadable: &unreadable)
            : response(for: flow, decodeBody: decodeBody)
        return HAR.Entry(
            startedDateTime: formatter.string(from: flow.startedAt),
            time: time,
            request: requestEntry,
            response: responseEntry,
            cache: .init(),
            timings: .init(send: 0, wait: time, receive: 0),
            _proxywoman: .init(
                upstreamRequestVersion: flow.transport.upstreamRequest,
                upstreamResponseVersion: flow.transport.upstreamResponse,
                downstreamStreamID: flow.transport.downstreamStreamID,
                upstreamStreamID: flow.transport.upstreamStreamID,
                requestTrailers: flow.requestTrailers,
                responseTrailers: flow.responseTrailers,
                provenance: provenance(of: flow.provenance, execute: flow),
                boundaries: snapshots ? boundaries(of: flow, unreadable: unreadable) : nil,
                mark: flow.displayMark.map(HAR.Mark.init)),
            _proxywomanWebSocket: webSocket,
            comment: flow.comment)
    }

    private static func provenance(of value: FlowProvenance, execute flow: Flow) -> HAR.Provenance {
        var result = HAR.Provenance(known: value.isKnown)
        if let record = flow.execute {
            result.execute = .init(
                runID: record.runID.uuidString, ruleIDs: record.matches.ruleIDs.map(\.uuidString),
                modified: flow.executeOverlay != nil)
        }
        guard value.isKnown else { return result }
        if value.rulesModified { result.rulesModified = true }
        switch value.source {
        case .passive: result.source = "passive"
        case .compose(let sendID, let sourceFlowID, let sourceBoundary):
            result.source = "compose"
            result.virtualClient = true
            result.composeSendID = sendID.uuidString
            result.composeSourceFlowID = sourceFlowID
            result.composeSourceBoundary = sourceBoundary
        }
        if let matches = value.ruleMatches {
            result.ruleRevision = matches.revision
            result.ruleIDs = matches.ruleIDs.map(\.uuidString)
            result.ruleMatchTotal = matches.total
            result.ruleMatchOmitted = matches.omitted
            result.ruleOutcomes = matches.outcomes.map { .init(ruleID: $0.ruleID.uuidString, code: $0.code.rawValue) }
        }
        if let generated = value.generatedResponse {
            result.generatedResponse = .init(assetID: generated.assetID?.uuidString, size: generated.size)
        }
        if value.rulesDisabled { result.rulesDisabled = true }
        if !value.tools.isEmpty { result.trafficTools = .init(value.tools) }
        return result
    }

    /// One compact record per boundary that really happened; absent boundaries are simply absent.
    private static func boundaries(of flow: Flow, unreadable: Set<HTTPMessageBoundary>) -> [String: HAR.Boundary] {
        var result: [String: HAR.Boundary] = [:]
        for (boundary, snapshot) in flow.messages {
            result[boundary.rawValue] = HAR.Boundary(
                wireVersion: snapshot.wireVersion, streamID: snapshot.streamID,
                transferState: snapshot.transferState, bodyState: snapshot.bodyState,
                observedBytes: snapshot.observedBytes, bodyBytes: snapshot.body?.count,
                method: snapshot.target?.method, url: snapshot.target?.url, status: snapshot.status,
                trailers: snapshot.trailers.isEmpty ? nil : snapshot.trailers,
                bodyReadFailed: unreadable.contains(boundary) ? true : nil)
        }
        return result
    }

    private static func request(
        for flow: Flow, snapshot: HTTPMessageSnapshot?, unreadable: inout Set<HTTPMessageBoundary>
    ) -> HAR.Request {
        guard let snapshot, let target = snapshot.target else { return request(for: flow) }
        let (body, failed) = loadBody(snapshot.body)
        if failed { unreadable.insert(snapshot.boundary) }
        let postData = body.isEmpty && !failed ? nil : HAR.PostData(
            mimeType: snapshot.headers.value(for: "content-type") ?? "",
            text: String(data: body, encoding: .utf8) ?? body.base64EncodedString(),
            comment: failed ? "body unreadable" : nil
        )
        return HAR.Request(
            method: target.method,
            url: target.url,
            httpVersion: snapshot.wireVersion?.rawValue ?? "",
            cookies: MessageParsing.requestCookies(snapshot.headers).map { .init(name: $0.name, value: $0.value) },
            headers: snapshot.headers.map { .init(name: $0.name, value: $0.value) },
            queryString: MessageParsing.queryItems(path: target.pathAndQuery).map { .init(name: $0.name, value: $0.value) },
            postData: postData,
            headersSize: -1,
            bodySize: Int(clamping: snapshot.observedBytes)
        )
    }

    /// A missing client-visible response (never delivered, or not yet) is exported as empty; the
    /// origin's response is never put in its place.
    private static func response(
        snapshot: HTTPMessageSnapshot?, decodeBody: (Data, String?) -> Data?, unreadable: inout Set<HTTPMessageBoundary>
    ) -> HAR.Response {
        let headers = snapshot?.headers ?? []
        let (raw, failed) = loadBody(snapshot?.body)
        if failed, let snapshot { unreadable.insert(snapshot.boundary) }
        var body = raw
        var compression: Int?
        if let encoding = headers.value(for: "content-encoding"), let decoded = decodeBody(raw, encoding) {
            body = decoded
            compression = raw.count - decoded.count
        }
        let text = String(data: body, encoding: .utf8)
        return HAR.Response(
            status: snapshot?.status ?? 0,
            statusText: snapshot?.reason ?? "",
            httpVersion: snapshot?.wireVersion?.rawValue ?? "",
            cookies: MessageParsing.responseCookies(headers).map { .init(name: $0.name, value: $0.value) },
            headers: headers.map { .init(name: $0.name, value: $0.value) },
            content: .init(
                size: body.count,
                mimeType: headers.value(for: "content-type") ?? "",
                text: text ?? body.base64EncodedString(),
                compression: compression,
                encoding: text == nil ? "base64" : nil,
                comment: failed ? "body unreadable" : nil
            ),
            redirectURL: headers.value(for: "location") ?? "",
            headersSize: -1,
            bodySize: Int(clamping: snapshot?.observedBytes ?? 0)
        )
    }

    private static func request(for flow: Flow) -> HAR.Request {
        let (body, failed) = loadBody(flow.requestBody)
        let postData = body.isEmpty && !failed ? nil : HAR.PostData(
            mimeType: flow.requestHeaders.value(for: "content-type") ?? "",
            text: String(data: body, encoding: .utf8) ?? body.base64EncodedString(),
            comment: failed ? "body unreadable" : nil
        )
        return HAR.Request(
            method: flow.method,
            url: flow.url,
            httpVersion: flow.transport.downstreamRequest?.rawValue ?? "",
            cookies: MessageParsing.requestCookies(flow.requestHeaders).map { .init(name: $0.name, value: $0.value) },
            headers: flow.requestHeaders.map { .init(name: $0.name, value: $0.value) },
            queryString: MessageParsing.queryItems(path: flow.path).map { .init(name: $0.name, value: $0.value) },
            postData: postData,
            headersSize: -1,
            bodySize: body.count
        )
    }

    private static func response(for flow: Flow, decodeBody: (Data, String?) -> Data?) -> HAR.Response {
        let (raw, failed) = loadBody(flow.responseBody)
        var body = raw
        var compression: Int?
        if let encoding = flow.responseHeaders.value(for: "content-encoding"),
           let decoded = decodeBody(raw, encoding) {
            body = decoded
            compression = raw.count - decoded.count
        }
        let text = String(data: body, encoding: .utf8)
        return HAR.Response(
            status: flow.statusCode ?? 0,
            statusText: flow.statusReason ?? "",
            httpVersion: flow.transport.downstreamResponse?.rawValue ?? "",
            cookies: MessageParsing.responseCookies(flow.responseHeaders).map { .init(name: $0.name, value: $0.value) },
            headers: flow.responseHeaders.map { .init(name: $0.name, value: $0.value) },
            content: .init(
                size: body.count,
                mimeType: flow.responseHeaders.value(for: "content-type") ?? "",
                text: text ?? body.base64EncodedString(),
                compression: compression,
                encoding: text == nil ? "base64" : nil,
                comment: failed ? "body unreadable" : nil
            ),
            redirectURL: flow.responseHeaders.value(for: "location") ?? "",
            headersSize: -1,
            bodySize: raw.count
        )
    }

    /// A read error is reported, never exported as an empty body.
    private static func loadBody(_ ref: BodyRef?) -> (data: Data, failed: Bool) {
        guard let ref else { return (Data(), false) }
        do { return (try ref.load(), false) } catch { return (Data(), true) }
    }

    /// A read error is reported, never exported as an empty body.
    private static func loadBody(_ slice: HTTPBodySlice?) -> (data: Data, failed: Bool) {
        guard let slice, slice.count > 0 else { return (Data(), false) }
        do { return (try slice.load(), false) } catch { return (Data(), true) }
    }
}

// MARK: - HAR 1.2 结构

private struct HAR: Encodable {
    var log: Log

    struct Log: Encodable {
        var version: String
        var creator: Creator
        var entries: [Entry]
    }

    struct Creator: Encodable {
        var name: String
        var version: String
    }

    struct Entry: Encodable {
        var startedDateTime: String
        var time: Double
        var request: Request
        var response: Response
        var cache: Cache
        var timings: Timings
        var _proxywoman: Transport
        var _proxywomanWebSocket: WebSocketHARSummary?
        var comment: String?
    }

    /// Custom HAR entry fields: optional origin-side request/response versions and stream IDs,
    /// plus ordered trailing fields kept separate from the standard initial-header arrays.
    /// Nil versions/IDs are omitted, never inferred from another message boundary.
    struct Transport: Encodable {
        var upstreamRequestVersion: HTTPWireVersion?
        var upstreamResponseVersion: HTTPWireVersion?
        var downstreamStreamID: Int?
        var upstreamStreamID: Int?
        var requestTrailers: [HeaderField]
        var responseTrailers: [HeaderField]
        var provenance: Provenance
        /// Present only for flows recorded with boundary snapshots.
        var boundaries: [String: Boundary]?
        /// The display mark (manual wins over rule); absent when the flow has none.
        var mark: Mark?
    }

    /// A colour mark as shown in the list. `source` is "manual", "rule" or "execute"; rule and Execute marks name the rule.
    struct Mark: Encodable {
        var background: String
        var foreground: String?
        var text: String?
        var source: String
        var ruleID: String?
        var ruleName: String?
        var runID: String?

        init(_ mark: FlowMark) {
            background = mark.background
            foreground = mark.foreground
            text = mark.text
            switch mark.source {
            case .manual:
                source = "manual"
            case .rule(let id, let name):
                source = "rule"
                ruleID = id.uuidString
                ruleName = name
            case .execute(let runID, let id, let name):
                source = "execute"
                self.runID = runID.uuidString
                ruleID = id.uuidString
                ruleName = name
            }
        }
    }

    /// Where the message came from. No local file paths: a generated response names its managed
    /// asset by id and size only.
    struct Provenance: Encodable {
        var known: Bool
        var source: String?
        var virtualClient: Bool?
        var composeSendID: String?
        var composeSourceFlowID: Int?
        var composeSourceBoundary: HTTPMessageBoundary?
        var ruleRevision: UInt64?
        var ruleIDs: [String]?
        var ruleMatchTotal: Int?
        var ruleMatchOmitted: Int?
        var ruleOutcomes: [Outcome]?
        var generatedResponse: Generated?
        /// Present (true) only when the rules were switched off for the flow.
        var rulesDisabled: Bool?
        /// Present (true) only when a rule changed the exchange.
        var rulesModified: Bool?
        /// Present only when a traffic tool marked the flow.
        var trafficTools: TrafficTools?
        /// Present only when an Execute run touched the flow.
        var execute: ExecuteSummary?

        init(known: Bool) { self.known = known }
    }

    /// Traffic-tool marks. Each field is omitted when it does not apply; `noCaching` appears only when true.
    struct TrafficTools: Encodable {
        var blockedByEntry: String?
        var noCaching: Bool?
        var networkCondition: String?
        var repeatRunID: String?
        var repeatIndex: Int?
        var repeatTotal: Int?

        init(_ value: TrafficToolsProvenance) {
            blockedByEntry = value.blockedByEntry?.uuidString
            noCaching = value.noCaching ? true : nil
            networkCondition = value.networkCondition
            repeatRunID = value.repeatRun?.runID.uuidString
            repeatIndex = value.repeatRun?.index
            repeatTotal = value.repeatRun?.total
        }
    }

    struct ExecuteSummary: Encodable {
        var runID: String
        var ruleIDs: [String]
        var modified: Bool
    }

    struct Outcome: Encodable {
        var ruleID: String
        var code: String
    }

    struct Generated: Encodable {
        var assetID: String?
        var size: UInt64?
    }

    /// Integrity of one boundary: how far the transfer got and how much of the body is kept.
    struct Boundary: Encodable {
        var wireVersion: HTTPWireVersion?
        var streamID: Int?
        var transferState: HTTPTransferState
        var bodyState: HTTPBodyState
        var observedBytes: UInt64
        var bodyBytes: Int?
        var method: String?
        var url: String?
        var status: Int?
        var trailers: [HeaderField]?
        /// The kept body could not be read at export time (for example the record was cleared).
        var bodyReadFailed: Bool?
    }

    struct Cache: Encodable {}

    struct Timings: Encodable {
        var send: Double
        var wait: Double
        var receive: Double
    }

    struct Pair: Encodable {
        var name: String
        var value: String
    }

    struct Request: Encodable {
        var method: String
        var url: String
        var httpVersion: String
        var cookies: [Pair]
        var headers: [Pair]
        var queryString: [Pair]
        var postData: PostData?
        var headersSize: Int
        var bodySize: Int
    }

    struct PostData: Encodable {
        var mimeType: String
        var text: String
        var comment: String?
    }

    struct Response: Encodable {
        var status: Int
        var statusText: String
        var httpVersion: String
        var cookies: [Pair]
        var headers: [Pair]
        var content: Content
        var redirectURL: String
        var headersSize: Int
        var bodySize: Int
    }

    struct Content: Encodable {
        var size: Int
        var mimeType: String
        var text: String
        var compression: Int?
        var encoding: String?
        var comment: String?
    }
}

/// Fixed-size projection: byte domains deliberately differ from event wirePayload.
public struct WebSocketHARSummary: Sendable, Encodable {
    public let schemaVersion = 1
    public let messagesIncluded = false
    public let token: WebSocketSessionToken
    public let lifecycle: WebSocketLifecycle
    public let clientCapture: WebSocketCaptureState
    public let serverCapture: WebSocketCaptureState
    public let clientWireBytes: UInt64
    public let serverWireBytes: UInt64
    public let clientApplicationBytes: UInt64
    public let serverApplicationBytes: UInt64
    public let clientDroppedEvents: UInt64
    public let serverDroppedEvents: UInt64
    public let lowerBound: Bool
    public let openedAt: Date?
    public let closedAt: Date?
    public let clientCompletedClose: Bool
    public let serverCompletedClose: Bool
    public let clientCloseCode: UInt16?
    public let serverCloseCode: UInt16?
    public let pausedIntervals: WebSocketPausedIntervals
    public let limits: WebSocketLimits
    public let wireByteDomain = "observedDecryptedPostHTTPIncludingFrameAndMask"
    public let applicationByteDomain = "decodedTextBinaryExcludingControl"
    private enum CodingKeys: String, CodingKey { case schemaVersion, messagesIncluded, token, lifecycle, clientCapture, serverCapture, clientWireBytes, serverWireBytes, clientApplicationBytes, serverApplicationBytes, clientDroppedEvents, serverDroppedEvents, lowerBound, openedAt, closedAt, clientCompletedClose, serverCompletedClose, clientCloseCode, serverCloseCode, pausedIntervals, limits, wireByteDomain, applicationByteDomain }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(messagesIncluded, forKey: .messagesIncluded)
        try container.encode(token, forKey: .token)
        try container.encode(lifecycle, forKey: .lifecycle)
        try container.encode(clientCapture, forKey: .clientCapture)
        try container.encode(serverCapture, forKey: .serverCapture)
        try container.encode(clientWireBytes, forKey: .clientWireBytes)
        try container.encode(serverWireBytes, forKey: .serverWireBytes)
        try container.encode(clientApplicationBytes, forKey: .clientApplicationBytes)
        try container.encode(serverApplicationBytes, forKey: .serverApplicationBytes)
        try container.encode(clientDroppedEvents, forKey: .clientDroppedEvents)
        try container.encode(serverDroppedEvents, forKey: .serverDroppedEvents)
        try container.encode(lowerBound, forKey: .lowerBound)
        try container.encodeIfPresent(openedAt, forKey: .openedAt)
        try container.encodeIfPresent(closedAt, forKey: .closedAt)
        try container.encode(clientCompletedClose, forKey: .clientCompletedClose)
        try container.encode(serverCompletedClose, forKey: .serverCompletedClose)
        try container.encodeIfPresent(clientCloseCode, forKey: .clientCloseCode)
        try container.encodeIfPresent(serverCloseCode, forKey: .serverCloseCode)
        try container.encode(pausedIntervals, forKey: .pausedIntervals)
        try container.encode(WebSocketHARLimits(value: limits), forKey: .limits)
        try container.encode(wireByteDomain, forKey: .wireByteDomain)
        try container.encode(applicationByteDomain, forKey: .applicationByteDomain)
    }

}
extension FlowStore {
    public func webSocketHARSummary(token: WebSocketSessionToken) -> WebSocketHARSummary? {
        state.withLock { state in
            guard let summary = state.webSockets.session(token)?.summary else { return nil }
            return .init(token: token, lifecycle: summary.lifecycle,
                clientCapture: summary.clientToServer.capture, serverCapture: summary.serverToClient.capture,
                clientWireBytes: summary.clientToServer.wireBytes, serverWireBytes: summary.serverToClient.wireBytes,
                clientApplicationBytes: summary.clientToServer.applicationBytes, serverApplicationBytes: summary.serverToClient.applicationBytes,
                clientDroppedEvents: summary.clientToServer.droppedEvents, serverDroppedEvents: summary.serverToClient.droppedEvents,
                lowerBound: summary.lowerBound, openedAt: summary.openedAt, closedAt: summary.closedAt,
                clientCompletedClose: summary.clientToServer.completedClose, serverCompletedClose: summary.serverToClient.completedClose,
                clientCloseCode: summary.clientToServer.closeCode, serverCloseCode: summary.serverToClient.closeCode,
                pausedIntervals: summary.pausedIntervals, limits: webSocketLimits)
        }
    }
}

private struct WebSocketHARLimits: Encodable {
    let value: WebSocketLimits
    private enum CodingKeys: String, CodingKey { case decodedPrefixBytes, wirePrefixBytes, messageWireBytes, messageExpandedBytes, messageFrames, fragmentDescriptors, sessionEvents, sessionPayloadBytes, storeEvents, retainedBytes, observingSessions, sessionMailboxBytes, mailboxBytes, workingBytes, nativeBytes, metadataBytes, quantumBytes, quantumFrames, quantumNativeOperations, sessionFramesPerSecond, sessionExpandedPerSecond, storeExpandedPerSecond, sessionNativePerSecond, storeNativePerSecond, pageRows, readerPayloadBytes }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value.decodedPrefixBytes, forKey: .decodedPrefixBytes)
        try container.encode(value.wirePrefixBytes, forKey: .wirePrefixBytes)
        try container.encode(value.messageWireBytes, forKey: .messageWireBytes)
        try container.encode(value.messageExpandedBytes, forKey: .messageExpandedBytes)
        try container.encode(value.messageFrames, forKey: .messageFrames)
        try container.encode(value.fragmentDescriptors, forKey: .fragmentDescriptors)
        try container.encode(value.sessionEvents, forKey: .sessionEvents)
        try container.encode(value.sessionPayloadBytes, forKey: .sessionPayloadBytes)
        try container.encode(value.storeEvents, forKey: .storeEvents)
        try container.encode(value.retainedBytes, forKey: .retainedBytes)
        try container.encode(value.observingSessions, forKey: .observingSessions)
        try container.encode(value.sessionMailboxBytes, forKey: .sessionMailboxBytes)
        try container.encode(value.mailboxBytes, forKey: .mailboxBytes)
        try container.encode(value.workingBytes, forKey: .workingBytes)
        try container.encode(value.nativeBytes, forKey: .nativeBytes)
        try container.encode(value.metadataBytes, forKey: .metadataBytes)
        try container.encode(value.quantumBytes, forKey: .quantumBytes)
        try container.encode(value.quantumFrames, forKey: .quantumFrames)
        try container.encode(value.quantumNativeOperations, forKey: .quantumNativeOperations)
        try container.encode(value.sessionFramesPerSecond, forKey: .sessionFramesPerSecond)
        try container.encode(value.sessionExpandedPerSecond, forKey: .sessionExpandedPerSecond)
        try container.encode(value.storeExpandedPerSecond, forKey: .storeExpandedPerSecond)
        try container.encode(value.sessionNativePerSecond, forKey: .sessionNativePerSecond)
        try container.encode(value.storeNativePerSecond, forKey: .storeNativePerSecond)
        try container.encode(value.pageRows, forKey: .pageRows)
        try container.encode(value.readerPayloadBytes, forKey: .readerPayloadBytes)
    }
}
