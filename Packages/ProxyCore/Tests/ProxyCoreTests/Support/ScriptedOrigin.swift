import Foundation
import NIOCore
import NIOPosix
import os

/// Runs `body` with a scripted origin and always stops it.
func withScriptedOrigin(_ body: (ScriptedOrigin) async throws -> Void) async throws {
    let origin = try await ScriptedOrigin.start()
    do { try await body(origin) } catch { try? await origin.stop(); throw error }
    try await origin.stop()
}

/// A plain-HTTP origin that answers each request head with a scripted byte sequence: literal
/// writes, waits on test barriers, or a close. Request bodies are not supported (GET/HEAD only).
final class ScriptedOrigin: Sendable {
    enum Step: Sendable {
        case send([UInt8])
        case wait(EventLoopFuture<Void>)
        case close
    }
    struct State: Sendable {
        var routes: [String: [Step]] = [:]
        /// Every raw request head received, in arrival order.
        var requests: [String] = []
        var closed = 0
        /// Answers every request head when set (instead of the routes and the 404).
        var everything: [Step]?
    }
    let state = OSAllocatedUnfairLock(initialState: State())
    let port: Int
    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel

    private init(port: Int, group: MultiThreadedEventLoopGroup, channel: Channel) {
        self.port = port; self.group = group; self.channel = channel
    }

    var requests: [String] { state.withLock { $0.requests } }
    var closedConnections: Int { state.withLock { $0.closed } }
    func route(_ path: String, _ steps: [Step]) { state.withLock { $0.routes[path] = steps } }
    func makePromise() -> EventLoopPromise<Void> { group.next().makePromise(of: Void.self) }

    /// An origin that answers every request head with `reply` (possibly nothing) and then closes.
    static func start(reply: [UInt8]) async throws -> ScriptedOrigin {
        let origin = try await start()
        origin.state.withLock { $0.everything = (reply.isEmpty ? [] : [.send(reply)]) + [.close] }
        return origin
    }

    static func start() async throws -> ScriptedOrigin {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let box = OSAllocatedUnfairLock<ScriptedOrigin?>(initialState: nil)
        do {
            let channel = try await ServerBootstrap(group: group).childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(Handler(origin: box))
                }
            }.bind(host: "127.0.0.1", port: 0).get()
            let origin = ScriptedOrigin(port: channel.localAddress!.port!, group: group, channel: channel)
            box.withLock { $0 = origin }
            return origin
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    func stop() async throws {
        try? await channel.close().get()
        try await group.shutdownGracefully()
    }

    private final class Handler: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer
        let origin: OSAllocatedUnfairLock<ScriptedOrigin?>
        var buffer: [UInt8] = []
        init(origin: OSAllocatedUnfairLock<ScriptedOrigin?>) { self.origin = origin }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            buffer += Array(unwrapInboundIn(data).readableBytesView)
            while let end = firstHeadEnd() {
                let head = String(decoding: buffer[..<end], as: UTF8.self)
                buffer.removeFirst(end)
                let target = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let steps = origin.withLock { owner -> [Step] in
                    owner?.state.withLock { state in
                        state.requests.append(head)
                        return state.everything ?? state.routes[target]
                            ?? [.send(Array("HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: 8\r\n\r\nno route".utf8))]
                    } ?? []
                }
                run(steps[...], context: context)
            }
        }

        private func firstHeadEnd() -> Int? {
            guard buffer.count >= 4 else { return nil }
            for index in 0...(buffer.count - 4) where buffer[index] == 13 && buffer[index + 1] == 10
                && buffer[index + 2] == 13 && buffer[index + 3] == 10 { return index + 4 }
            return nil
        }

        private func run(_ steps: ArraySlice<Step>, context: ChannelHandlerContext) {
            guard let step = steps.first, context.channel.isActive else { return }
            let rest = steps.dropFirst()
            switch step {
            case .send(let bytes):
                context.writeAndFlush(wrapOutboundOut(ByteBuffer(bytes: bytes))).assumeIsolated().whenComplete { _ in
                    self.run(rest, context: context)
                }
            case .wait(let barrier):
                barrier.hop(to: context.eventLoop).assumeIsolated().whenComplete { _ in self.run(rest, context: context) }
            case .close:
                context.close(promise: nil)
            }
        }

        func channelInactive(context: ChannelHandlerContext) {
            origin.withLock { owner in owner?.state.withLock { $0.closed += 1 } }
            context.fireChannelInactive()
        }

        func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
    }
}
