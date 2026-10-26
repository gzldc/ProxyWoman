import Darwin
import NIOCore
import NIOHTTP1
import NIOHTTP2
import NIOHPACK

/// Snapshot emitted BEFORE its payload reaches the semantic codec. No synthesized Host or
/// transfer framing is included. A snapshot is emitted for each initial/interim/trailing block.
struct HTTP2StreamHeaders: Sendable {
    let regularHeaders: HTTPHeaders
    let authority: String?
    var scheme: String? = nil
    var path: String? = nil
    var method: String? = nil
    let endStream: Bool
    let streamID: HTTP2StreamID
    enum Kind: Sendable { case informational, initial, trailers }
    let kind: Kind
    var isTrailers: Bool { kind == .trailers }
}

final class HTTP2StreamMetadataHandler: ChannelInboundHandler, ChannelOutboundHandler {
    typealias InboundIn = HTTP2Frame.FramePayload
    typealias InboundOut = HTTP2Frame.FramePayload
    typealias OutboundIn = HTTP2Frame.FramePayload
    typealias OutboundOut = HTTP2Frame.FramePayload
    enum Role { case request, response }
    private let role: Role
    private let limits: HTTPTransportLimits
    /// Initial request or final response; informational responses live only in currentHeaders/events.
    private(set) var initialHeaders: HTTP2StreamHeaders?
    private(set) var currentHeaders: HTTP2StreamHeaders?
    private(set) var trailingHeaders: HTTP2StreamHeaders?
    private var receivedFinalHead = false

    init(role: Role, limits: HTTPTransportLimits) { self.role = role; self.limits = limits }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        do {
            if case .headers(let headers) = unwrapInboundIn(data) {
                try validateBudget(headers.headers)
                var regular = HTTPHeaders()
                var authority: String?
                var scheme: String?
                var path: String?
                var method: String?
                var status: String?
                for header in headers.headers {
                    if header.name == ":authority" { authority = header.value }
                    if header.name == ":scheme" { scheme = header.value }
                    if header.name == ":path" { path = header.value }
                    if header.name == ":method" { method = header.value }
                    if header.name == ":status" { status = header.value }
                    if !header.name.hasPrefix(":") { regular.add(name: header.name, value: header.value) }
                }
                let trailers = receivedFinalHead
                if role == .request, !trailers {
                    authority = authority ?? regular.first(name: "host")
                    guard let authority, Self.validAuthority(authority),
                          regular["host"].allSatisfy({ Self.sameEndpoint($0, authority, defaultPort: scheme == "http" ? 80 : 443) })
                    else { throw HTTP2TransportError.invalidAuthority }
                }
                guard let options = context.channel.syncOptions else { throw ChannelError.operationUnsupported }
                let streamID = try options.getOption(HTTP2StreamChannelOptions.streamID)
                let kind: HTTP2StreamHeaders.Kind = trailers ? .trailers
                    : (role == .response && status?.hasPrefix("1") == true ? .informational : .initial)
                let snapshot = HTTP2StreamHeaders(regularHeaders: regular, authority: authority, scheme: scheme, path: path, method: method,
                    endStream: headers.endStream, streamID: streamID, kind: kind)
                if kind == .initial { initialHeaders = snapshot }
                currentHeaders = snapshot
                if trailers { trailingHeaders = snapshot }
                if kind == .initial { receivedFinalHead = true }
                context.fireUserInboundEventTriggered(snapshot)
            }
            context.fireChannelRead(data)
        } catch {
            context.fireErrorCaught(error)
            context.close(promise: nil)
        }
    }

    /// Bound the real outbound HPACK list too, including generated pseudo headers. Failure
    /// occurs before child-channel buffering and affects this stream only.
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        do {
            if case .headers(let headers) = unwrapOutboundIn(data) { try validateBudget(headers.headers) }
            context.write(data, promise: promise)
        } catch {
            promise?.fail(error)
            context.fireErrorCaught(error)
            context.close(promise: nil)
        }
    }

    private func validateBudget(_ headers: HPACKHeaders) throws {
        var bytes = 0
        var fields = 0
        for header in headers {
            fields += 1
            bytes += header.name.utf8.count + header.value.utf8.count + 32
            guard fields <= limits.headerFields, bytes <= limits.headerBytes else {
                throw HTTP2TransportError.headerLimitExceeded
            }
        }
    }

    /// DNS case and numeric/default ports compare as endpoints; IPv6 is parsed, never text-matched.
    static func sameEndpoint(_ left: String, _ right: String, defaultPort: Int) -> Bool {
        guard let lhs = endpoint(left, defaultPort: defaultPort),
              let rhs = endpoint(right, defaultPort: defaultPort) else { return false }
        return lhs.host == rhs.host && lhs.port == rhs.port
    }
    private static func endpoint(_ value: String, defaultPort: Int) -> (host: String, port: Int)? {
        guard validAuthority(value) else { return nil }
        let hasPort: Bool
        if value.first == "[", let close = value.firstIndex(of: "]") {
            hasPort = value.index(after: close) != value.endIndex
        } else { hasPort = value.contains(":") }
        guard let target = RequestTarget(authorityForm: hasPort ? value : "\(value):\(defaultPort)") else { return nil }
        var host = target.host.lowercased()
        if host.contains(":") {
            var address = in6_addr()
            guard inet_pton(AF_INET6, host, &address) == 1 else { return nil }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { return nil }
            host = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        return (host, target.port)
    }

    private static func validAuthority(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.allSatisfy({ $0 > 32 && $0 < 127 }),
              !text.contains(where: { "/@?#\\".contains($0) }) else { return false }
        let remainder: Substring
        if text.first == "[" {
            guard let end = text.firstIndex(of: "]") else { return false }
            var address = in6_addr()
            guard inet_pton(AF_INET6, String(text[text.index(after: text.startIndex)..<end]), &address) == 1 else { return false }
            remainder = text[text.index(after: end)...]
        } else {
            let split = text.firstIndex(of: ":") ?? text.endIndex
            let host = text[..<split]
            guard !host.isEmpty, host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }) else { return false }
            remainder = text[split...]
        }
        if remainder.isEmpty { return true }
        guard remainder.first == ":", !remainder.dropFirst().isEmpty,
              remainder.dropFirst().allSatisfy({ $0.isNumber }), let port = UInt16(remainder.dropFirst()), port > 0 else { return false }
        return true
    }
}
