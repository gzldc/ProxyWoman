import NIOCore
import NIOEmbedded
import NIOHTTP2
import Testing
@testable import ProxyCore

/// Real NIO multiplexer and production session; only initializer completion is gated.
final class HTTP2LifecycleFixture {
    let loop = EmbeddedEventLoop()
    let parent: EmbeddedChannel
    let session: HTTP2Session
    let gates: NIOLoopBound<Gates>
    final class Gates {
        var pending: [EventLoopPromise<Void>] = []
    }
    init(limits: HTTPTransportLimits = .init()) throws {
        parent = EmbeddedChannel(loop: loop)
        try parent.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 12345)).wait()
        gates = NIOLoopBound(Gates(), eventLoop: loop)
        let gates = gates
        let installed = HTTP2Pipeline.installClient(on: parent,
            route: .init(scheme: "https", host: "localhost", port: 443, policy: .automatic), limits: limits,
            streamCreationGate: { child in
                let promise = child.eventLoop.makePromise(of: Void.self)
                gates.value.pending.append(promise)
                return promise.futureResult
            })
        var result: Result<HTTP2Session, Error>?
        installed.assumeIsolated().whenComplete { result = $0 }
        session = try #require(result).get()
    }
    func complete(_ index: Int, fail: Bool = false) {
        if fail { gates.value.pending[index].fail(HTTPTransportError.cancelled) }
        else { gates.value.pending[index].succeed(()) }
        loop.run()
    }
    func stop() {
        session.close(error: nil)
        _ = try? parent.finish()
        loop.run()
    }
}
