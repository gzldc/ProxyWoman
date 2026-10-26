import FlowStore
import Foundation

/// One captured body entity. The capture is made once; every boundary that carried (a prefix of)
/// the same bytes mirrors a counted range of the final reference instead of capturing again.
struct RecordedBodyStream {
    var capture: BodyCapture?
    /// Set once when the producer ended or was cancelled.
    var final: (ref: BodyRef?, truncated: Bool)?
}

/// Live accounting of one message boundary, turned into an `HTTPMessageSnapshot` on publication.
struct MessageBoundaryState {
    var head: HTTPMessageHead
    var version: HTTPWireVersion?
    var streamID: Int?
    var trailers: [HeaderField] = []
    var stream: UUID?
    /// Body bytes this boundary has carried so far (accepted by the writer or read from the peer).
    var accepted: UInt64 = 0
    var transfer: HTTPTransferState
    var finished = false
    var complete = false

    /// `streams` resolves the shared body; `isStreamClosed` is false while the capture is running.
    func snapshot(_ boundary: HTTPMessageBoundary, streams: [UUID: RecordedBodyStream]) -> HTTPMessageSnapshot {
        let closed: Bool
        let kept: (ref: BodyRef, size: Int)?
        if let stream {
            let final = streams[stream]?.final
            closed = final != nil
            kept = final?.ref.map { ($0, $0.size) }
        } else {
            closed = true
            kept = nil
        }
        var slice: HTTPBodySlice?
        var state = HTTPBodyState.pending
        if closed, let kept {
            let count = min(Int(clamping: accepted), kept.size)
            if count > 0 { slice = HTTPBodySlice(ref: kept.ref, offset: 0, count: count) }
        }
        if finished {
            if complete && accepted == 0 {
                state = .complete
            } else if closed {
                let count = slice?.count ?? 0
                if !complete { state = .incomplete }
                else if UInt64(count) == accepted { state = .complete }
                else if count > 0 { state = .truncated }
                else { state = .unavailable }
            }
        }
        return HTTPMessageSnapshot(
            boundary: boundary, head: head, trailers: trailers, wireVersion: version, streamID: streamID,
            body: slice, bodyState: state, observedBytes: accepted, transferState: transfer)
    }
}
