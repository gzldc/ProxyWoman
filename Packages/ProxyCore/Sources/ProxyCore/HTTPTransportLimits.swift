import NIOCore

/// Per accepted client socket. Later protocol adapters use the same injectable budgets.
struct HTTPTransportLimits {
    var downstreamStreams = 100
    var upstreamStreams = 100
    // NIOHTTP2 1.46 increments signed Int32 by two while allocating an ID. Retire
    // before its final legal ID would overflow that increment; failed creations also count.
    static let safeStreamCreationsPerSession = Int(Int32.max) / 2
    private var streamCreationLimit = safeStreamCreationsPerSession
    var upstreamStreamCreationsPerSession: Int {
        get { streamCreationLimit }
        set { streamCreationLimit = min(Self.safeStreamCreationsPerSession, max(1, newValue)) }
    }
    var http1SocketsPerRoute = 6
    var totalUpstreamSockets = 8
    var pendingAcquisitions = 100
    var pendingBytesPerExchange = 65_536
    var pendingBytesPerContext = 4_194_304
    var headerBytes = 65_536
    var headerFields = 256
    var highWatermark = 65_536
    var lowWatermark = 32_768
    var receiveWindow = 65_535
    var idleTimeout: TimeAmount = .seconds(30)
    var drainTimeout: TimeAmount = .seconds(30)
}
