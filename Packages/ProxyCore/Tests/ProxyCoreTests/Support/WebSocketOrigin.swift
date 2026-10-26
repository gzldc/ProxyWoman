import CertKit
import CryptoKit
import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import os

/// One scripted origin action after the RFC 6455 handshake.
enum WebSocketOriginStep: Sendable {
    /// Writes these bytes. A `send` that immediately follows the handshake shares the 101 write.
    case send(bytes: Data)
    /// Waits for exactly these bytes from the proxy; a mismatch is recorded and closes the socket.
    case expect(bytes: Data)
    /// Marks `name` reached, then waits for `WebSocketTestBarriers.release(name)`.
    case barrier(name: String)
    case closeTransport
    /// Writes `frame(0)`, `frame(1)`, … (each write awaited, so a blocked socket pauses it)
    /// until `WebSocketTestBarriers.release(until)`; keeps writing regardless of buffer sizes.
    case sendGenerated(until: String, frame: @Sendable (Int) -> Data)
}

/// Named ordering gates between a test and the origin script. Waits are bounded and fail by
/// throwing; success never depends on elapsed time, only on the named transition happening.
final class WebSocketTestBarriers: Sendable {
    private struct State: Sendable { var reached: Set<String> = []; var released: Set<String> = [] }
    private let state = OSAllocatedUnfairLock(initialState: State())
    let timeout: Duration
    init(timeout: Duration = .seconds(30)) { self.timeout = timeout }
    func release(_ name: String) { state.withLock { _ = $0.released.insert(name) } }
    func isReleased(_ name: String) -> Bool { state.withLock { $0.released.contains(name) } }
    /// Waits until the origin script reached `name`.
    func waitFor(_ name: String) async throws {
        try await waitUntil(timeout: timeout, "origin barrier \(name) reached") { state.withLock { $0.reached.contains(name) } }
    }
    func reach(_ name: String) async throws {
        state.withLock { _ = $0.reached.insert(name) }
        try await waitUntil(timeout: timeout, "origin barrier \(name) released") { state.withLock { $0.released.contains(name) } }
    }
}

/// Independent RFC 6455 wire helpers: literal frame layout and SHA-1 accept from CryptoKit,
/// never production handshake/framing/compression code.
enum WSWire {
    static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    static func accept(for key: String) -> String {
        Data(Insecure.SHA1.hash(data: Data((key + guid).utf8))).base64EncodedString()
    }
    static func randomKey() -> String {
        Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
    }
    /// Any payload length; `mask` makes a client frame.
    static func frame(_ opcode: UInt8, _ payload: [UInt8], fin: Bool = true, rsv1: Bool = false, mask: [UInt8]? = nil) -> [UInt8] {
        var bytes: [UInt8] = [(fin ? 0x80 : 0) | (rsv1 ? 0x40 : 0) | opcode]
        let bit: UInt8 = mask == nil ? 0 : 0x80
        switch payload.count {
        case ..<126: bytes.append(bit | UInt8(payload.count))
        case ..<65_536: bytes += [bit | 126, UInt8(payload.count >> 8), UInt8(payload.count & 255)]
        default: bytes.append(bit | 127); bytes += (0..<8).reversed().map { UInt8((UInt64(payload.count) >> (8 * UInt64($0))) & 255) }
        }
        if let mask {
            bytes += mask
            bytes += payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }
        } else { bytes += payload }
        return bytes
    }
    static let clientMask: [UInt8] = [0x37, 0xfa, 0x21, 0x3d]
    static func client(_ opcode: UInt8, _ payload: [UInt8], fin: Bool = true, rsv1: Bool = false) -> [UInt8] {
        frame(opcode, payload, fin: fin, rsv1: rsv1, mask: clientMask)
    }
    static func upgradeRequest(target: String, port: Int, key: String, extensions: String? = nil, body: [UInt8] = []) -> [UInt8] {
        var head = "GET \(target) HTTP/1.1\r\nHost: localhost:\(port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
        head += "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n"
        if let extensions { head += "Sec-WebSocket-Extensions: \(extensions)\r\n" }
        if !body.isEmpty { head += "Content-Length: \(body.count)\r\n" }
        return Array((head + "\r\n").utf8) + body
    }
}

/// Real loopback WebSocket origin for one upgraded connection. It validates the actual request
/// key/version/upgrade fields, answers with an independently computed accept and runs `script`.
final class WebSocketOrigin: Sendable {
    struct Transcript: Sendable {
        var requestHead = ""
        var requestBody: [UInt8] = []
        var inbox: [UInt8] = []
        var handshakeLength: Int?
        var cursor = 0
        /// Post-101-head bytes whose write completed.
        var sent: [UInt8] = []
        var failures: [String] = []
        var finished = false
        var closed = false
        var connections = 0
        var channel: Channel?
        var received: [UInt8] { handshakeLength.map { Array(inbox[$0...]) } ?? [] }
    }
    let port: Int
    /// The temporary origin CA (TLS only); its DER root is also written to `directory`.
    let ca: CertificateAuthority?
    let barriers: WebSocketTestBarriers
    private let group: MultiThreadedEventLoopGroup
    private let listener: Channel
    private let state: OSAllocatedUnfairLock<Transcript>
    private let tasks: OSAllocatedUnfairLock<[Task<Void, Never>]>

    private init(port: Int, ca: CertificateAuthority?, barriers: WebSocketTestBarriers, group: MultiThreadedEventLoopGroup,
                 listener: Channel, state: OSAllocatedUnfairLock<Transcript>, tasks: OSAllocatedUnfairLock<[Task<Void, Never>]>) {
        self.port = port; self.ca = ca; self.barriers = barriers; self.group = group
        self.listener = listener; self.state = state; self.tasks = tasks
    }

    var transcript: Transcript { state.withLock { $0 } }
    var received: [UInt8] { state.withLock { $0.received } }
    var sent: [UInt8] { state.withLock { $0.sent } }
    var channel: Channel? { state.withLock { $0.channel } }

    /// `handshakeBarrier` holds the validated request before the 101 is written (a pending Upgrade).
    static func start(tls: Bool, script: [WebSocketOriginStep], directory: URL, responseExtensions: String? = nil,
                      handshakeBarrier: String? = nil, barriers: WebSocketTestBarriers = .init()) async throws -> WebSocketOrigin {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var ca: CertificateAuthority?
        var context: NIOSSLContext?
        if tls {
            let authority = try CertificateAuthority.generate(commonName: "WS synthetic origin CA")
            let leaf = try authority.leaf(for: "localhost")
            var config = TLSConfiguration.makeServerConfiguration(
                certificateChain: [.certificate(try NIOSSLCertificate(bytes: leaf.certificateDER, format: .der))],
                privateKey: .privateKey(try NIOSSLPrivateKey(bytes: leaf.privateKeyDER, format: .der)))
            config.applicationProtocols = ["http/1.1"]
            context = try NIOSSLContext(configuration: config)
            try Data(authority.rootCertificateDER).write(to: directory.appendingPathComponent("origin-ca.der"))
            ca = authority
        }
        let state = OSAllocatedUnfairLock(initialState: Transcript())
        let tasks = OSAllocatedUnfairLock(initialState: [Task<Void, Never>]())
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let tlsContext = context
        do {
            let listener = try await ServerBootstrap(group: group).childChannelInitializer { channel in
                let first = state.withLock { state -> Bool in
                    state.connections += 1
                    guard state.channel == nil else { return false }
                    state.channel = channel; return true
                }
                guard first else { return channel.close() }
                return channel.eventLoop.makeCompletedFuture {
                    if let tlsContext { try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tlsContext)) }
                    try channel.pipeline.syncOperations.addHandler(Collector(state: state))
                    let runner = Task { await run(channel: channel, script: script, extensions: responseExtensions, handshakeBarrier: handshakeBarrier,
                                                  state: state, barriers: barriers) }
                    tasks.withLock { $0.append(runner) }
                }
            }.bind(host: "127.0.0.1", port: 0).get()
            return .init(port: listener.localAddress!.port!, ca: ca, barriers: barriers, group: group,
                         listener: listener, state: state, tasks: tasks)
        } catch { try? await group.shutdownGracefully(); throw error }
    }

    func stop() async throws {
        let runners = tasks.withLock { $0 }
        runners.forEach { $0.cancel() }
        for runner in runners { await runner.value }
        try? await listener.close().get()
        if let channel { try? await channel.close().get() }
        try await group.shutdownGracefully()
    }

    /// Waits until the script finished every step (or throws with recorded failures).
    func waitUntilFinished(timeout: Duration = .seconds(30)) async throws {
        try await waitUntil(timeout: timeout, "origin script; failures: \(state.withLock { $0.failures })") {
            state.withLock { $0.finished || !$0.failures.isEmpty }
        }
    }
    func waitUntilClosed(timeout: Duration = .seconds(10)) async throws {
        try await waitUntil(timeout: timeout, "origin peer socket closed") { state.withLock { $0.closed } }
    }

    private static func run(channel: Channel, script: [WebSocketOriginStep], extensions: String?, handshakeBarrier: String?,
                            state: OSAllocatedUnfairLock<Transcript>, barriers: WebSocketTestBarriers) async {
        do {
            let marker = Array("\r\n\r\n".utf8)
            var found: Int?
            try await waitUntil(timeout: .seconds(10), "WebSocket request head") {
                let bytes = state.withLock { $0.inbox }
                if bytes.count >= 4 { found = (0...(bytes.count - 4)).first { bytes[$0..<($0 + 4)].elementsEqual(marker) }.map { $0 + 4 } }
                return found != nil
            }
            let headEnd = found!
            let head = state.withLock { String(decoding: $0.inbox[..<headEnd], as: UTF8.self) }
            var lines = head.components(separatedBy: "\r\n").filter { !$0.isEmpty }
            let requestLine = lines.removeFirst().split(separator: " ")
            var fields: [(String, String)] = []
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { throw OriginFailure("malformed header \(line)") }
                fields.append((line[..<colon].lowercased(), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
            }
            func values(_ name: String) -> [String] { fields.filter { $0.0 == name }.map(\.1) }
            let length = Int(values("content-length").first ?? "0") ?? -1
            try await waitUntil(timeout: .seconds(10), "request body") { state.withLock { $0.inbox.count >= headEnd + length } }
            guard requestLine.count == 3, requestLine[0] == "GET", requestLine[2] == "HTTP/1.1", length >= 0,
                  values("host").count == 1,
                  values("upgrade").contains(where: { $0.lowercased() == "websocket" }),
                  values("connection").flatMap({ $0.split(separator: ",") }).contains(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == "upgrade" }),
                  values("sec-websocket-version") == ["13"],
                  let key = values("sec-websocket-key").first, values("sec-websocket-key").count == 1,
                  Data(base64Encoded: key)?.count == 16 else {
                _ = try? await channel.writeAndFlush(ByteBuffer(string: "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")).get()
                throw OriginFailure("invalid WebSocket request: \(head)")
            }
            if extensions != nil, !values("sec-websocket-extensions").joined(separator: ",").contains("permessage-deflate") {
                throw OriginFailure("response extension was not offered")
            }
            state.withLock { state in
                state.requestHead = head
                state.requestBody = Array(state.inbox[headEnd..<(headEnd + length)])
                state.handshakeLength = headEnd + length; state.cursor = headEnd + length
            }
            if let handshakeBarrier { try await barriers.reach(handshakeBarrier) }
            var response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(WSWire.accept(for: key))\r\n"
            if let extensions { response += "Sec-WebSocket-Extensions: \(extensions)\r\n" }
            var steps = script[...]
            var first: [UInt8] = []
            if case .send(let bytes) = steps.first { first = Array(bytes); steps = steps.dropFirst() }
            let greeting = first
            try await channel.writeAndFlush(ByteBuffer(bytes: Array((response + "\r\n").utf8) + greeting)).get()
            state.withLock { $0.sent += greeting }
            for step in steps {
                switch step {
                case .send(let bytes):
                    try await channel.writeAndFlush(ByteBuffer(bytes: Array(bytes))).get()
                    state.withLock { $0.sent += bytes }
                case .expect(let bytes):
                    try await waitUntil(timeout: .seconds(30), "\(bytes.count) expected bytes at the origin") {
                        state.withLock { $0.inbox.count - $0.cursor >= bytes.count }
                    }
                    let actual = state.withLock { state in
                        defer { state.cursor += bytes.count }
                        return Array(state.inbox[state.cursor..<(state.cursor + bytes.count)])
                    }
                    guard actual == Array(bytes) else { throw OriginFailure("origin received unexpected bytes") }
                case .barrier(let name): try await barriers.reach(name)
                case .closeTransport: try await channel.close().get()
                case .sendGenerated(let until, let frame):
                    var index = 0
                    while !barriers.isReleased(until) {
                        try Task.checkCancellation()
                        let bytes = frame(index); index += 1
                        try await channel.writeAndFlush(ByteBuffer(bytes: Array(bytes))).get()
                        state.withLock { $0.sent += bytes }
                    }
                }
            }
            state.withLock { $0.finished = true }
        } catch is CancellationError {
        } catch {
            if Task.isCancelled { return }
            state.withLock { $0.failures.append(String(describing: error)) }
            channel.close(promise: nil)
        }
    }
    private struct OriginFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
    private final class Collector: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        let state: OSAllocatedUnfairLock<Transcript>
        init(state: OSAllocatedUnfairLock<Transcript>) { self.state = state }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let bytes = unwrapInboundIn(data)
            state.withLock { $0.inbox.append(contentsOf: bytes.readableBytesView) }
        }
        func channelInactive(context: ChannelHandlerContext) {
            state.withLock { $0.closed = true }
            context.fireChannelInactive()
        }
        func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
    }
}

/// Client-side steps through a real proxy listener: optional CONNECT + MITM TLS, then a real
/// Upgrade whose 101 accept is checked against the independent RFC computation.
enum WSProxyPeer {
    static func connect(proxyPort: Int, originPort: Int, tls: NIOSSLTrustRoots?, receiveBufferSize: Int? = nil) async throws -> RawClient {
        let client = try await RawClient.connect(port: proxyPort, receiveBufferSize: receiveBufferSize)
        guard let tls else { return client }
        do {
            try await client.send("CONNECT localhost:\(originPort) HTTP/1.1\r\nHost: localhost:\(originPort)\r\n\r\n")
            let established = try await client.receive(until: "\r\n\r\n")
            guard established.hasPrefix("HTTP/1.1 200 ") else { throw WaitTimeout(description: "CONNECT refused: \(established)") }
            try await client.startTLS(trustRoots: tls, serverName: "localhost")
            return client
        } catch { try? await client.close(); throw error }
    }
    /// Returns the 101 head; every later byte belongs to the WebSocket stream.
    @discardableResult
    static func upgrade(_ client: RawClient, originPort: Int, absolute: Bool, extensions: String? = nil, body: [UInt8] = []) async throws -> String {
        let key = WSWire.randomKey()
        let target = absolute ? "http://localhost:\(originPort)/chat" : "/chat"
        try await client.send(bytes: WSWire.upgradeRequest(target: target, port: originPort, key: key, extensions: extensions, body: body))
        let head = try await client.receive(until: "\r\n\r\n")
        guard head.hasPrefix("HTTP/1.1 101 "), head.contains("Sec-WebSocket-Accept: \(WSWire.accept(for: key))\r\n") else {
            throw WaitTimeout(description: "unexpected Upgrade response: \(head)")
        }
        return head
    }
    static func roots(_ ca: CertificateAuthority) throws -> NIOSSLTrustRoots {
        .certificates([try NIOSSLCertificate(bytes: ca.rootCertificateDER, format: .der)])
    }
}
