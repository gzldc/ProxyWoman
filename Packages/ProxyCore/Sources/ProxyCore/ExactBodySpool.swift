import Darwin
import FlowStore
import Foundation
import NIOCore
import RulesEngine
import os

/// Collects one complete body into a private file, byte-exact, for a breakpoint or Compose. Distinct
/// from the truncatable `BodyCapture`: a spool either proves the whole body (exact expected length
/// and an end) or fails; it never yields a prefix.
///
/// The caller gates transport reads while an append future is pending: at most one append is in
/// flight, each at most `ioChunkBytes`. Every append is charged to the shared I/O buffer budget
/// before its bytes are copied, and an unknown-length body grows its spool reservation before
/// writing. Reservations are returned only after the file work they cover has settled, even after
/// `cancel()`.
///
/// `@unchecked Sendable`: every mutable property is confined to `io.eventLoop` (asserted); blocking
/// work runs on the file pool and only captures immutable values.
public final class ExactBodySpool: @unchecked Sendable {
    private enum Phase { case open, finishing, finished, failed(OwnedFileError), cancelled }

    public let category: ExactBodyCategory
    public let expectedLength: Int64?
    private let io: BodyFileIO
    private let limit: Int64
    private let chunkBytes: Int
    private let id = UUID()
    private let reservation: OwnedFileReservation
    private let pin: BreakpointBodyRuntime.Pin?
    private var phase = Phase.open
    private var written: Int64 = 0
    private var inFlight = false
    private var cleanupScheduled = false
    /// Write descriptor of the temp file, once the first write created it.
    private var descriptor: Int32?

    /// Throws `fileTooLarge` for a known length over the single-body limit and `capacityExceeded`
    /// when the service-wide spool budget cannot hold it; nothing is reserved or created then.
    public init(category: ExactBodyCategory, expectedLength: Int64?, limits: RulesLimits, io: BodyFileIO) throws {
        self.category = category
        self.expectedLength = expectedLength
        self.io = io
        self.limit = category.bodyLimit(limits)
        self.chunkBytes = max(1, limits.ioChunkBytes)
        if let expectedLength {
            guard expectedLength >= 0 else { throw OwnedFileError(.lengthMismatch) }
            guard expectedLength <= limit else { throw OwnedFileError(.fileTooLarge) }
        }
        let pin = try io.runtime?.pin()
        do { reservation = try io.budgets.reserve(category: category.budget, bytes: expectedLength ?? 0) }
        catch { pin?.release(); throw error }
        self.pin = pin
    }

    deinit {
        // Never runs while file work is in flight: its callback retains the spool.
        if case .finished = phase { return }
        discardFile()
    }

    public var bytesWritten: Int64 {
        io.eventLoop.preconditionInEventLoop()
        return written
    }

    /// Appends at most `ioChunkBytes`. Fails the whole spool (and cleans up) on overflow, length
    /// mismatch, budget exhaustion or I/O error; never accepts part of a chunk.
    public func append(_ bytes: ByteBuffer) -> EventLoopFuture<Void> {
        io.eventLoop.preconditionInEventLoop()
        guard case .open = phase else { return io.eventLoop.makeFailedFuture(currentError) }
        guard !inFlight else { return io.eventLoop.makeFailedFuture(OwnedFileError(.operationInFlight)) }
        let count = bytes.readableBytes
        guard count <= chunkBytes else { return fail(OwnedFileError(.chunkTooLarge)) }
        let next = written + Int64(count)
        if let expectedLength, next > expectedLength { return fail(OwnedFileError(.lengthMismatch)) }
        guard next <= limit else { return fail(OwnedFileError(.fileTooLarge)) }
        guard count > 0 else { return io.eventLoop.makeSucceededVoidFuture() }
        let buffer: OwnedFileReservation
        do {
            buffer = try io.budgets.reserve(category: .io, bytes: Int64(count))
            if expectedLength == nil { try reservation.extend(by: Int64(count)) }
        } catch let error as OwnedFileError {
            return fail(error)
        } catch {
            return fail(OwnedFileError(.ioFailure))
        }
        // Owned copy of only the readable bytes: never retain the caller's backing allocation.
        let chunk = Array(bytes.readableBytesView)
        let existing = descriptor, id = self.id, directory = io.directory, budgets = io.budgets, hook = io.hooks.beforeWrite
        inFlight = true
        return io.run { () throws -> Int32 in
            let target: Int32
            if let existing {
                target = existing
            } else {
                try OwnedFiles.preparePrivateDirectory(directory)
                target = try OwnedFiles.createExclusive(BodyFileIO.tempName(id), in: directory)
            }
            do {
                try budgets.ensureFreeDisk(in: directory, adding: Int64(count))
                hook?()
                try chunk.withUnsafeBytes { try OwnedFiles.writeAll(target, $0) }
            } catch {
                // Keep the descriptor reachable for cleanup even when the first write failed.
                if existing == nil { throw CreatedButFailed(descriptor: target, error: error) }
                throw error
            }
            return target
        }.settle { result -> Result<Void, Error> in
            buffer.release()
            self.inFlight = false
            switch result {
            case .success(let target):
                self.descriptor = target
                if case .open = self.phase {
                    self.written = next
                    return .success(())
                }
            case .failure(let error as CreatedButFailed):
                self.descriptor = error.descriptor
                if case .open = self.phase { return .failure(self.failNow(Self.ownedError(error.error))) }
            case .failure(let error):
                if case .open = self.phase { return .failure(self.failNow(Self.ownedError(error))) }
            }
            // Cancelled or failed while the write was pending: clean up now that it has settled.
            self.discardFile()
            return .failure(self.currentError)
        }
    }

    /// Completes the body. A known length must match exactly; a short or missing body fails.
    /// `trailers` is the end proof carried with the source.
    public func finish(trailers: [HeaderField]) -> EventLoopFuture<ExactBodySource> {
        io.eventLoop.preconditionInEventLoop()
        guard case .open = phase else { return io.eventLoop.makeFailedFuture(currentError) }
        guard !inFlight else { return io.eventLoop.makeFailedFuture(OwnedFileError(.operationInFlight)) }
        if let expectedLength, written != expectedLength { return fail(OwnedFileError(.lengthMismatch)) }
        phase = .finishing
        inFlight = true
        let existing = descriptor, id = self.id, directory = io.directory, size = written, beforeFinish = io.hooks.beforeFinish
        // Set once the job starts: from then on the job owns (closes/unlinks) the temp file.
        let started = OSAllocatedUnfairLock(initialState: false)
        return io.run { () throws -> Int32 in
            beforeFinish?()
            started.withLock { $0 = true }
            let target: Int32
            if let existing {
                target = existing
            } else {
                try OwnedFiles.preparePrivateDirectory(directory)
                target = try OwnedFiles.createExclusive(BodyFileIO.tempName(id), in: directory)
            }
            var published = false
            defer {
                close(target)
                if !published { OwnedFiles.unlinkOwned(BodyFileIO.tempName(id), in: directory) }
            }
            try OwnedFiles.sync(target)
            try OwnedFiles.rename(BodyFileIO.tempName(id), to: BodyFileIO.finalName(id), in: directory)
            published = true
            do {
                let opened = try OwnedFiles.openOwned(BodyFileIO.finalName(id), in: directory)
                guard opened.identity.size == size else {
                    close(opened.descriptor)
                    throw OwnedFileError(.lengthMismatch)
                }
                return opened.descriptor
            } catch {
                OwnedFiles.unlinkOwned(BodyFileIO.finalName(id), in: directory)
                throw error
            }
        }.settle { result -> Result<ExactBodySource, Error> in
            self.inFlight = false
            if case .failure = result, !started.withLock({ $0 }) {
                // The pool was shut down before the job ran: close, unlink, then release.
                if case .finishing = self.phase { self.phase = .failed(OwnedFileError(.cancelled)) }
                self.discardFile()
                return .failure(self.currentError)
            }
            self.descriptor = nil
            switch (result, self.phase) {
            case (.success(let reader), .finishing):
                self.phase = .finished
                return .success(self.io.makeSource(
                    id: id, size: size, trailers: trailers, descriptor: reader, reservation: self.reservation, pin: self.pin))
            case (.success(let reader), _):
                // Cancelled while finishing: the published file is still ours to remove.
                close(reader)
                self.unlinkFinal()
                return .failure(OwnedFileError(.cancelled))
            case (.failure(let error), .finishing):
                self.phase = .failed(Self.ownedError(error))
                self.cleanupScheduled = true
                self.reservation.release(); self.pin?.release()
                return .failure(self.currentError)
            case (.failure, _):
                self.cleanupScheduled = true
                self.reservation.release(); self.pin?.release()
                return .failure(self.currentError)
            }
        }
    }

    /// Idempotent; callable from any thread. Pending file work keeps its reservations until it has
    /// settled; then the temp file is unlinked and the budgets returned. A finished source is not
    /// affected (it is cancelled through `ExactBodySource.cancel()`).
    public func cancel() {
        guard io.eventLoop.inEventLoop else {
            io.eventLoop.execute { self.cancel() }
            return
        }
        switch phase {
        case .open:
            phase = .cancelled
            if !inFlight { discardFile() }
        case .failed:
            break  // Keep the original failure.
        case .finishing:
            phase = .cancelled
        case .finished, .cancelled:
            break
        }
    }

    // MARK: helpers

    private var currentError: OwnedFileError {
        if case .failed(let error) = phase { return error }
        return OwnedFileError(.cancelled)
    }

    private func fail<T>(_ error: OwnedFileError) -> EventLoopFuture<T> {
        io.eventLoop.makeFailedFuture(failNow(error))
    }

    private func failNow(_ error: OwnedFileError) -> OwnedFileError {
        phase = .failed(error)
        if !inFlight { discardFile() }
        return error
    }

    /// Closes and unlinks the temp file off-loop, then returns the spool reservation.
    private func discardFile() {
        guard !cleanupScheduled else { return }
        cleanupScheduled = true
        let existing = descriptor, id = self.id, directory = io.directory, reservation = self.reservation, pin = self.pin
        descriptor = nil
        io.runner { _ in
            if let existing { close(existing) }
            OwnedFiles.unlinkOwned(BodyFileIO.tempName(id), in: directory)
            reservation.release(); pin?.release()
        }
    }

    private func unlinkFinal() {
        guard !cleanupScheduled else { return }
        cleanupScheduled = true
        let id = self.id, directory = io.directory, reservation = self.reservation, pin = self.pin
        io.runner { _ in
            OwnedFiles.unlinkOwned(BodyFileIO.finalName(id), in: directory)
            reservation.release(); pin?.release()
        }
    }

    private static func ownedError(_ error: Error) -> OwnedFileError {
        (error as? OwnedFileError) ?? OwnedFileError(.ioFailure)
    }

    private struct CreatedButFailed: Error {
        var descriptor: Int32
        var error: Error
    }
}

extension EventLoopFuture {
    /// Transforms the settled result on the future's own loop.
    fileprivate func settle<NewValue: Sendable>(
        _ body: @escaping @Sendable (Result<Value, Error>) -> Result<NewValue, Error>
    ) -> EventLoopFuture<NewValue> {
        let promise = eventLoop.makePromise(of: NewValue.self)
        whenComplete { promise.completeWith(body($0)) }
        return promise.futureResult
    }
}
