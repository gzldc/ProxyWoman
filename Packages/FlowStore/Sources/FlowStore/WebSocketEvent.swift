import Foundation

public enum WebSocketDirection: String, Codable, Sendable { case clientToServer, serverToClient }
public enum WebSocketPayloadKind: String, Codable, Sendable { case application, wirePayload }
public enum WebSocketHandshakeStatus: String, Codable, Sendable { case verified, invalid, negotiationUnverified, opaqueExtension }
public enum WebSocketLifecycle: String, Codable, Sendable { case open, transportClosed, transportEndedWithoutClose }
public enum WebSocketCaptureState: String, Codable, Sendable {
    case observing, metadataOnly, paused, resumePendingBoundary, contentStoppedUntilReconnect, opaquePausedUntilReconnect
    var admitsContent: Bool { self == .observing || self == .resumePendingBoundary }
}
public enum WebSocketEventKind: String, Codable, Sendable { case text, binary, ping, pong, close, opaqueFrame, diagnostic }
public enum WebSocketIntegrity: String, Codable, Sendable { case transportComplete, captureTruncated, incompleteTransport, invalid, opaque, partialPaused, observationStopped }
public enum WebSocketUTF8Status: String, Codable, Sendable { case unverified, valid, invalid }
public enum StoreAcceptance: String, Codable, Sendable { case accepted, revoked, recordingPausedOrEpochChanged, captureBudgetExhausted }

public struct WebSocketSessionToken: Sendable, Hashable, Codable {
    public let flowID: Int
    public let sessionID: UUID
    public let generation: UInt64
    public init(flowID: Int, sessionID: UUID, generation: UInt64) { self.flowID = flowID; self.sessionID = sessionID; self.generation = generation }
}
public struct WebSocketDiagnostic: Sendable, Equatable, Codable {
    public var code: String
    /// Protocol/limit explanation only. Payload and close reason belong to owned payloads.
    public var detail: String?
    public init(code: String, detail: String? = nil) { self.code = code; self.detail = detail }
    var bounded: Bool { code.utf8.count <= 128 && (detail?.utf8.count ?? 0) <= 128 }
}
public struct WebSocketHandshake: Sendable, Equatable, Codable {
    public var requestMethod: String
    public var requestURI: String?
    public var version: String
    public var requestHeaders: [HeaderField]
    public var responseHeaders: [HeaderField]
    public var responseStatus: Int
    public var offeredProtocols: [String]
    public var selectedProtocol: String?
    public var offeredExtensions: [String]
    public var selectedExtensions: [String]
    public var assessment: WebSocketHandshakeStatus
    public var diagnostics: [WebSocketDiagnostic]
    public init(requestMethod: String = "GET", version: String = "HTTP/1.1", requestHeaders: [HeaderField] = [],
                responseHeaders: [HeaderField] = [], responseStatus: Int = 101, offeredProtocols: [String] = [],
                selectedProtocol: String? = nil, offeredExtensions: [String] = [], selectedExtensions: [String] = [],
                assessment: WebSocketHandshakeStatus = .verified, diagnostics: [WebSocketDiagnostic] = [], requestURI: String? = nil) {
        self.requestURI = requestURI; self.requestMethod = requestMethod; self.version = version; self.requestHeaders = requestHeaders
        self.responseHeaders = responseHeaders; self.responseStatus = responseStatus; self.offeredProtocols = offeredProtocols
        self.selectedProtocol = selectedProtocol; self.offeredExtensions = offeredExtensions; self.selectedExtensions = selectedExtensions
        self.assessment = assessment; self.diagnostics = diagnostics
    }
}
public struct WebSocketDirectionSummary: Sendable, Equatable, Codable {
    public var capture: WebSocketCaptureState = .observing
    public var wireBytes: UInt64 = 0
    public var applicationBytes: UInt64 = 0
    public var droppedEvents: UInt64 = 0
    public var closeCode: UInt16?
    public var completedClose = false
    public var diagnostic: WebSocketDiagnostic?
    public init() {}
}
/// Coalesced interval extent and total count, without an unbounded interval history.
public struct WebSocketPausedIntervals: Sendable, Equatable, Codable {
    public var firstStartedAt: Date?
    public var lastEndedAt: Date?
    public var currentStartedAt: Date?
    public var totalCount: UInt64 = 0
    public init() {}
}
public struct WebSocketSummary: Sendable, Equatable, Codable {
    public var handshake: WebSocketHandshake
    public var openedAt: Date?
    public var closedAt: Date?
    public var lifecycle: WebSocketLifecycle = .open
    public var clientToServer = WebSocketDirectionSummary()
    public var serverToClient = WebSocketDirectionSummary()
    public var lowerBound = false
    public var firstAvailableEventID: UInt64?
    public var pausedIntervals = WebSocketPausedIntervals()
    public var revision: UInt64 = 0
    public init(handshake: WebSocketHandshake, openedAt: Date? = Date()) { self.handshake = handshake; self.openedAt = openedAt }
    subscript(_ direction: WebSocketDirection) -> WebSocketDirectionSummary {
        get { direction == .clientToServer ? clientToServer : serverToClient }
        set { if direction == .clientToServer { clientToServer = newValue } else { serverToClient = newValue } }
    }
}
public struct WebSocketOrder: Sendable, Equatable, Codable, Comparable {
    public var ingressSequence: UInt64
    public var offset: UInt32
    public init(ingressSequence: UInt64, offset: UInt32) { self.ingressSequence = ingressSequence; self.offset = offset }
    public static func < (lhs: Self, rhs: Self) -> Bool { (lhs.ingressSequence, lhs.offset) < (rhs.ingressSequence, rhs.offset) }
}
public struct WebSocketFragmentDescriptor: Sendable, Equatable, Codable {
    public var opcode: UInt8
    public var fin: Bool
    public var rsv: UInt8
    public var masked: Bool
    public var length: UInt64
    public var observedAt: Date
    public init(opcode: UInt8, fin: Bool, rsv: UInt8, masked: Bool, length: UInt64, observedAt: Date) {
        self.opcode = opcode; self.fin = fin; self.rsv = rsv; self.masked = masked; self.length = length; self.observedAt = observedAt
    }
}
public struct WebSocketEventMetadata: Sendable, Equatable, Codable {
    public var id: UInt64
    public var order: WebSocketOrder
    public var direction: WebSocketDirection
    public var kind: WebSocketEventKind
    public var opcode: UInt8 = 1
    public var firstObservedAt = Date()
    public var lastObservedAt = Date()
    public var completedAt: Date?
    public var monotonicStart: UInt64 = 0
    public var monotonicEnd: UInt64 = 0
    public var wirePayloadBytes: UInt64 = 0
    public var decodedBytes: UInt64 = 0
    public var retainedBytes: UInt64 = 0
    public var lowerBound = false
    public var fragmentCount: UInt64 = 0
    public var fragments: [WebSocketFragmentDescriptor] = []
    public var descriptorTruncated = false
    public var compressed = false
    public var integrity: WebSocketIntegrity = .transportComplete
    public var utf8: WebSocketUTF8Status = .unverified
    public var closeCode: UInt16?
    public var diagnostics: [WebSocketDiagnostic] = []
    public var revision: UInt64 = 0
    /// Capture abandonment is terminal without claiming an on-wire FIN or transport end.
    public var captureAbandoned = false
    public var isCaptureTerminal: Bool { completedAt != nil || integrity == .partialPaused || captureAbandoned }
    public init(id: UInt64, order: WebSocketOrder, direction: WebSocketDirection, kind: WebSocketEventKind) {
        self.id = id; self.order = order; self.direction = direction; self.kind = kind
    }
}
public struct WebSocketCaptureStamp: Sendable, Equatable, Codable {
    public let epoch: UInt64
    public let enabled: Bool
    public let ingressSequence: UInt64
    public init(epoch: UInt64, enabled: Bool, ingressSequence: UInt64) { self.epoch = epoch; self.enabled = enabled; self.ingressSequence = ingressSequence }
}
public struct WebSocketRecordingState: Sendable, Equatable, Codable {
    public let enabled: Bool
    public let epoch: UInt64
    public let revision: UInt64
    public init(enabled: Bool, epoch: UInt64, revision: UInt64) { self.enabled = enabled; self.epoch = epoch; self.revision = revision }
}
public struct WebSocketTransportEnd: Sendable, Equatable, Codable {
    public let direction: WebSocketDirection
    public let at: Date
    public let monotonic: UInt64
    public init(direction: WebSocketDirection, at: Date, monotonic: UInt64) { self.direction = direction; self.at = at; self.monotonic = monotonic }
}
public enum WebSocketMetadataOnlyUpdate: Sendable {
    case capture(direction: WebSocketDirection, state: WebSocketCaptureState, diagnostic: WebSocketDiagnostic?)
    case observedBytes(direction: WebSocketDirection, wire: UInt64, application: UInt64, lowerBound: Bool)
    case pausedInterval(start: Date, end: Date?)
    case droppedEvents(direction: WebSocketDirection, count: UInt64)
    case closeCode(direction: WebSocketDirection, code: UInt16)
    case closeFrame(direction: WebSocketDirection, code: UInt16?)
}

func wsSaturatingAdd(_ value: inout UInt64, _ addition: UInt64, lowerBound: inout Bool) {
    let (sum, overflow) = value.addingReportingOverflow(addition)
    value = overflow ? .max : sum
    lowerBound = lowerBound || overflow
}

extension WebSocketSummary {
    mutating func addPausedIntervalCount() {
        wsSaturatingAdd(&pausedIntervals.totalCount, 1, lowerBound: &lowerBound)
    }
    mutating func addDroppedEvents(_ count: UInt64, direction: WebSocketDirection) {
        switch direction {
        case .clientToServer: wsSaturatingAdd(&clientToServer.droppedEvents, count, lowerBound: &lowerBound)
        case .serverToClient: wsSaturatingAdd(&serverToClient.droppedEvents, count, lowerBound: &lowerBound)
        }
    }
}
