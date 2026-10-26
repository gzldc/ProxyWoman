import FlowStore
import Foundation
import NIOCore

/// The common face of a body collection gate: `HTTPExchange` depends only on this to route a body
/// that is being collected. The breakpoint gate and the body rewriter both implement it. An
/// exchange holds at most one gate at a time, for one direction. Confined to the exchange loop.
protocol ExchangeBodyGate: AnyObject {
    /// The message direction being collected, or nil before the gate took one.
    var direction: HTTPMessageDirection? { get }
    /// True while body parts of `direction` must go to the gate instead of the wire.
    var isCollecting: Bool { get }
    /// The gate can take another body part now (transport reads follow this).
    var canRead: Bool { get }
    var timerCount: Int { get }
    /// The END of the collected message arrived: a clean upstream close afterwards is not a
    /// truncation. (Not in the original task interface; the upstream-close path needs it.)
    var receivedEnd: Bool { get }
    @discardableResult func append(_ bytes: ByteBuffer) -> EventLoopFuture<Void>
    func finishBody(trailers: [HeaderField])
    /// The transport failed the body being collected (truncation, a second head, an I/O error).
    func failBodyCallback(_ error: Error, operation: UUID?)
    /// Gives up everything the gate holds; no callback fires afterwards.
    func abandon()
}
