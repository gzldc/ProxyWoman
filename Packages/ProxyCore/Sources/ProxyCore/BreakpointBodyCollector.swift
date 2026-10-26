import FlowStore
import Foundation
import NIOCore
import NIOHTTP1
import RulesEngine

/// Event-loop confined adapter. Batched decoder callbacks are copied only after charging the
/// shared I/O budget. Staging plus the spool's one bounded copy never exceeds one MiB.
final class BreakpointBodyCollector {
    private let io: BodyFileIO
    private let spool: ExactBodySpool
    private var queue: [(ByteBuffer, OwnedFileReservation, EventLoopPromise<Void>)] = []
    private var staged = 0
    private var busy = false
    private var stopped = false
    private var finishing = false
    private var end: ([HeaderField], EventLoopPromise<ExactBodySource>)?
    private var received: Int64 = 0
    var canRead: Bool { !stopped && !busy && queue.isEmpty && end == nil }
    init(expectedLength: Int64?, io: BodyFileIO) throws {
        self.io = io
        spool = try ExactBodySpool(category: .breakpoint, expectedLength: expectedLength, limits: io.limits, io: io)
    }
    func append(_ bytes: ByteBuffer) -> EventLoopFuture<Void> {
        io.eventLoop.preconditionInEventLoop()
        guard !stopped, end == nil else { return io.eventLoop.makeFailedFuture(OwnedFileError(.cancelled)) }
        let count = bytes.readableBytes
        guard received + Int64(count) <= Int64(io.limits.breakpointBodyBytes) else {
            return failed(OwnedFileError(.fileTooLarge))
        }
        guard count <= 1_048_576 - min(65_536, max(1, io.limits.ioChunkBytes)) - staged else {
            return failed(OwnedFileError(.capacityExceeded))
        }
        let reservation: OwnedFileReservation
        do { reservation = try io.budgets.reserve(category: .io, bytes: Int64(count)) }
        catch { return failed(error) }
        let promise = io.eventLoop.makePromise(of: Void.self)
        received += Int64(count); staged += count
        queue.append((ByteBuffer(bytes: bytes.readableBytesView), reservation, promise))
        pump()
        return promise.futureResult
    }
    func finish(trailers: [HeaderField]) -> EventLoopFuture<ExactBodySource> {
        io.eventLoop.preconditionInEventLoop()
        guard !stopped, end == nil else { return io.eventLoop.makeFailedFuture(OwnedFileError(.cancelled)) }
        let promise = io.eventLoop.makePromise(of: ExactBodySource.self)
        end = (trailers, promise)
        pump()
        return promise.futureResult
    }
    private func pump() {
        guard !stopped, !busy else { return }
        if queue.isEmpty {
            guard let end else { return }
            busy = true
            finishing = true
            spool.finish(trailers: end.0).assumeIsolated().whenComplete { result in
                self.busy = false
                self.end = nil
                self.stopped = true
                end.1.completeWith(result)
            }
            return
        }
        var entry = queue.removeFirst()
        let slice = entry.0.readSlice(length: min(entry.0.readableBytes, max(1, min(65_536, io.limits.ioChunkBytes))))!
        queue.insert(entry, at: 0)
        busy = true
        spool.append(slice).assumeIsolated().whenComplete { result in
            self.busy = false
            guard !self.stopped else { return }
            switch result {
            case .failure(let error): self.cancel(error: error)
            case .success:
                if self.queue[0].0.readableBytes == 0 {
                    let done = self.queue.removeFirst()
                    self.staged -= Int(done.1.bytes)
                    done.1.release(); done.2.succeed(())
                }
                self.pump()
            }
        }
    }
    private func failed(_ error: Error) -> EventLoopFuture<Void> {
        cancel(error: error)
        return io.eventLoop.makeFailedFuture(error)
    }
    func cancel() { cancel(error: OwnedFileError(.cancelled)) }
    private func cancel(error: Error) {
        guard !stopped else { return }
        stopped = true
        spool.cancel()
        for entry in queue { entry.1.release(); entry.2.fail(error) }
        queue.removeAll(); staged = 0
        // A finish already handed to the spool owns its promise until its file work settles.
        if !finishing { end?.1.fail(error); end = nil }
    }
}

struct BreakpointBodyContinuation {
    let source: ExactBodySource
    let original: HTTPMessageHead
    let descriptor: HTTPBodyDescriptor
    let bytesChanged: Bool
    let version: HTTPWireVersion
    var ignoredBodyEdit = false
}
