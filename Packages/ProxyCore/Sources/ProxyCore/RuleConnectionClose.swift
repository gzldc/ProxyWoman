import NIOCore
import NIOSSL

/// The client-socket side of a rule's forced close (D15).
enum RuleConnectionClose {
    /// Closes `channel` with a TCP reset: SO_LINGER {on, 0} makes the close send RST instead of FIN. Under
    /// TLS the close starts below the TLS handler, so no close_notify goes out first and nothing waits for the
    /// peer's. On the event loop the option is set synchronously; a channel without a socket just closes.
    static func reset(_ channel: Channel) {
        channel.eventLoop.preconditionInEventLoop()
        _ = (channel as? SocketOptionProvider)?.setSoLinger(NIOLinger(l_onoff: 1, l_linger: 0))
        if let tls = try? channel.pipeline.syncOperations.context(handlerType: NIOSSLServerHandler.self) {
            tls.close(promise: nil)
        } else {
            channel.close(promise: nil)
        }
    }
}
