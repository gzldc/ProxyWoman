/// Immutable diagnostics sampled only on the production owner's event loop.
struct HTTP2SessionSnapshot: Sendable {
    let reservedStreams: Int
    let creatingStreams: Int
    let activeStreams: Int
    let streamCreations: Int
    let idleTimers: Int
    let drainTimers: Int
}

struct UpstreamPoolSnapshot: Sendable {
    let waiting: Int
    let connecting: Int
    let opening: Int
    let pending: Int
    let acquisitionTimers: Int
    let socketReservations: Int
    let physicalSockets: Int
    let sessions: [HTTP2SessionSnapshot]
}

struct HTTPExchangeSnapshot: Sendable {
    let path: String
    let pendingBytes: Int
    let uploadDisposalTimers: Int
    let pendingBodyCapacity: Int
    // nil when the corresponding adapter is not HTTP/2; do not invent H1 measurements.
    let downstreamQueuedBodyBytes: Int?
    let upstreamQueuedBodyBytes: Int?
    let requestReading: Bool?
    let responseReading: Bool?
    var breakpointTimers: Int = 0
}

struct ClientConnectionSnapshot: Sendable {
    let pendingBytes: Int
    let lookupTimers: Int
    let exchanges: [HTTPExchangeSnapshot]
}
