import NIOCore
import NIOHTTP1

/// Owns a bounded copy of one complete, idempotent HTTP/1 request. The initial head is supplied
/// only to the initializer; unexpected sequences permanently discard the copy.
struct RequestReplayBuffer {
    private var head: HTTPRequestHead?
    private var body: ByteBuffer?
    private var trailers: HTTPHeaders?
    private var complete = false
    private var size = 0
    private let limit: Int

    init(head: HTTPRequestHead, limit: Int = 1_048_576) {
        self.limit = max(0, limit)
        guard [.GET, .HEAD, .PUT, .DELETE, .OPTIONS, .TRACE].contains(head.method),
              !head.headers.contains(name: "upgrade"),
              !head.headers[canonicalForm: "connection"].contains(where: { $0.lowercased() == "upgrade" })
        else { return }
        guard account(head.method.rawValue.utf8.count), account(head.uri.utf8.count), account(head.headers) else { return }
        self.head = head
    }

    mutating func append(_ part: HTTPClientRequestPart) {
        guard head != nil else { return }
        guard !complete else { discard(); return }
        switch part {
        case .head:
            discard()
        case .body(.byteBuffer(let bytes)):
            guard account(bytes.readableBytes) else { discard(); return }
            // Copy only readable bytes. Keeping incoming slices would retain their whole backing
            // allocation; keeping individual parts would leave tiny/empty part counts unbounded.
            if !bytes.readableBytesView.isEmpty {
                if body == nil { body = ByteBuffer() }
                body?.writeBytes(bytes.readableBytesView)
            }
        case .body(.fileRegion):
            discard()
        case .end(let trailers):
            if let trailers, !account(trailers) { discard(); return }
            self.trailers = trailers
            complete = true
        }
    }

    var replayParts: [HTTPClientRequestPart]? {
        guard let head, complete else { return nil }
        var parts: [HTTPClientRequestPart] = [.head(head)]
        if let body { parts.append(.body(.byteBuffer(body))) }
        parts.append(.end(trailers))
        return parts
    }

    private mutating func account(_ count: Int) -> Bool {
        guard count <= limit - size else { return false }
        size += count
        return true
    }

    private mutating func account(_ headers: HTTPHeaders) -> Bool {
        for (name, value) in headers {
            guard account(32), account(name.utf8.count), account(value.utf8.count) else { return false }
        }
        return true
    }

    private mutating func discard() {
        head = nil
        body = nil
        trailers = nil
    }
}
