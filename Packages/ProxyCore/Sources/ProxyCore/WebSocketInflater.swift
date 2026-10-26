import Foundation
import Darwin
import FlowStore
import CWebSocketZlib

public enum WebSocketInflateStatus: Sendable, Equatable {
    case needsInput, yield, messageComplete
    case stopped(WebSocketDiagnostic)
    case opaqueCompression
}
public struct WebSocketInflateProgress: Sendable, Equatable {
    public let consumed: Int
    public let produced: Int
    public let nativeOperations: Int
    public let status: WebSocketInflateStatus
}

/// Actor-confined streaming raw inflater. Input/output pointers are borrowed only inside each C call.
/// A yielded caller must resubmit only unread input; the FIN tail is owned by this instance.
public final class WebSocketInflater {
    public enum InitializationError: Error { case nativeMemory, workLimit, nativeFailure }
    struct NativeAccounting: Sendable {
        var liveBytes = 0
        var peakBytes = 0
        var allocations = 0
        var frees = 0
        var refusals = 0
        var lowerBound = false
    }
    private final class Allocation {
        let reservation: WebSocketReservation
        init(_ reservation: consuming WebSocketReservation) { self.reservation = reservation }
    }
    private final class Allocator {
        let budget: WebSocketMemoryBudget
        var blocks: [UnsafeMutableRawPointer: Allocation] = [:]
        var accounting = NativeAccounting()
        init(_ budget: WebSocketMemoryBudget) { self.budget = budget }
        func increment(_ key: WritableKeyPath<NativeAccounting, Int>) {
            if accounting[keyPath: key] == Int.max { accounting.lowerBound = true }
            else { accounting[keyPath: key] += 1 }
        }
        func allocate(_ count: Int) -> UnsafeMutableRawPointer? {
            guard let reservation = budget.reserve(category: .native, bytes: count) else {
                increment(\.refusals); return nil
            }
            guard let pointer = malloc(count) else { increment(\.refusals); return nil }
            blocks[pointer] = Allocation(reservation)
            accounting.liveBytes += count // The budget has already checked this addition against an Int capacity.
            accounting.peakBytes = max(accounting.peakBytes, accounting.liveBytes)
            increment(\.allocations)
            return pointer
        }
        func release(_ pointer: UnsafeMutableRawPointer, _ count: Int) {
            let allocation = blocks.removeValue(forKey: pointer)
            precondition(allocation != nil && allocation!.reservation.bytes == count)
            free(pointer)
            accounting.liveBytes -= count; increment(\.frees)
            withExtendedLifetime(allocation) {}
        }
    }
    private let parameters: WebSocketCompressionParameters
    private let budget: WebSocketMemoryBudget
    private let limiter: WebSocketWorkLimiter
    private let sessionID: UUID
    private let allocator: Allocator
    private var scratch: WebSocketDictionaryScratch?
    private var native: OpaquePointer?
    private var terminal: WebSocketInflateStatus?
    private var recovery = false
    private var finishing = false
    private var tailOffset = 0
    private var messageExpanded = 0
    private var feeding = false
    private static let tail = Data([0,0,255,255])
    let nativeInitializationStatus: Int32
    var nativeAccounting: NativeAccounting { allocator.accounting }

    public init(parameters: WebSocketCompressionParameters, budget: WebSocketMemoryBudget,
                limiter: WebSocketWorkLimiter, sessionID: UUID,
                dictionaryScratch: WebSocketDictionaryScratch) throws {
        self.parameters = parameters; self.budget = budget; self.limiter = limiter; self.sessionID = sessionID
        self.scratch = dictionaryScratch
        allocator = Allocator(budget)
        guard (8...15).contains(parameters.windowBits) else {
            nativeInitializationStatus = Z_STREAM_ERROR; terminal = .opaqueCompression; return
        }
        guard limiter.admit(session: sessionID, frames: 0, expandedBytes: 0, nativeOperations: 1) == .allowed else {
            throw InitializationError.workLimit
        }
        var result: Int32 = Z_OK
        native = pwws_create(Int32(parameters.windowBits), Unmanaged.passUnretained(allocator).toOpaque(), { context, count in
            guard let context, count >= 0 else { return nil }
            return Unmanaged<Allocator>.fromOpaque(context).takeUnretainedValue().allocate(count)
        }, { context, pointer, count in
            guard let context, let pointer else { return }
            Unmanaged<Allocator>.fromOpaque(context).takeUnretainedValue().release(pointer, count)
        }, &result)
        nativeInitializationStatus = result
        if native == nil {
            if result == Z_MEM_ERROR { throw InitializationError.nativeMemory }
            if result == Z_STREAM_ERROR || result == Z_VERSION_ERROR { terminal = .opaqueCompression }
            else { throw InitializationError.nativeFailure }
        }
    }

    public func feed(_ input: Data, final: Bool, emit: (Data) -> Void) -> WebSocketInflateProgress {
        var consumed = 0, produced = 0, operations = 0, inputWork = 0
        func result(_ status: WebSocketInflateStatus) -> WebSocketInflateProgress {
            .init(consumed: consumed, produced: produced, nativeOperations: operations, status: status)
        }
        if let terminal { return result(terminal) }
        guard !feeding else { return result(stop("inflateReentered")) }
        feeding = true
        defer { feeding = false }
        let limits = limiter.limits
        guard limits.quantumBytes > 0, limits.quantumNativeOperations > 0, limits.messageExpandedBytes >= 0 else {
            return result(stop("invalidInflateLimits"))
        }
        // Once FIN input is consumed, only empty drain calls may follow a yield.
        guard !finishing || input.isEmpty else { return result(stop("inflateInputAfterFinal")) }
        while true {
            if let terminal { return result(terminal) }
            guard let native else { return result(stop("inflateClosed")) }
            if recovery {
                guard limits.quantumNativeOperations >= 4 else { return result(stop("invalidRecoveryQuantum")) }
                guard operations <= limits.quantumNativeOperations - 4 else { return result(.yield) }
                guard charge(4) else { return result(stop("inflateWorkLimit")) }
                operations += 4 // get + the bounded dictionary copy it performs + reset + set.
                guard let scratch else { return result(stop("inflateClosed")) }
                let status: Int32 = scratch.withBuffer { buffer in
                    var count = 0
                    let pointer = buffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    let got = pwws_get_dictionary(native, pointer, buffer.count, &count)
                    guard got == Z_OK else { return got }
                    let reset = pwws_reset(native)
                    guard reset == Z_OK else { return reset }
                    return pwws_set_dictionary(native, pointer, count)
                }
                guard status == Z_OK else { return result(stop("inflateRecoveryFailed")) }
                recovery = false
            }
            if consumed == input.count, final, !finishing { finishing = true; tailOffset = 0 }
            if finishing && tailOffset == Self.tail.count {
                guard pwws_at_block_boundary(native) != 0 else { return result(stop("inflateIncompleteFinal")) }
                if parameters.noContextTakeover {
                    guard operations < limits.quantumNativeOperations else { return result(.yield) }
                    guard charge(1) else { return result(stop("inflateWorkLimit")) }
                    operations += 1
                    guard pwws_reset(native) == Z_OK else { return result(stop("inflateResetFailed")) }
                }
                finishing = false; tailOffset = 0; messageExpanded = 0
                return result(.messageComplete)
            }
            guard inputWork < limits.quantumBytes, produced < limits.quantumBytes,
                  operations < limits.quantumNativeOperations else { return result(.yield) }
            let useTail = finishing
            let source = useTail ? Self.tail : input
            let offset = useTail ? tailOffset : consumed
            let count = min(source.count - offset, limits.quantumBytes - inputWork)
            let capacity = min(32768, limits.quantumBytes - produced,
                               messageExpanded < limits.messageExpandedBytes ? limits.messageExpandedBytes - messageExpanded : 1)
            guard let reservation = budget.reserve(category: .working, bytes: capacity), let pointer = malloc(capacity) else {
                return result(stop("inflateWorkingMemory"))
            }
            var output = Data(bytesNoCopy: pointer, count: capacity, deallocator: .free)
            var read = 0, written = 0
            guard charge(1) else { return result(stop("inflateWorkLimit")) }
            operations += 1
            let status = source.withUnsafeBytes { sourceBytes in
                output.withUnsafeMutableBytes { outputBytes in
                    pwws_inflate(native, sourceBytes.baseAddress?.advanced(by: offset).assumingMemoryBound(to: UInt8.self), count,
                        &read, outputBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), capacity, &written)
                }
            }
            inputWork += read
            if useTail { tailOffset += read } else { consumed += read }
            // Progress reports actual native expansion, including output discarded on failure.
            produced += written
            let expansionDecision = limiter.admit(session: sessionID, frames: 0, expandedBytes: written, nativeOperations: 0)
            guard written <= limits.messageExpandedBytes - messageExpanded else {
                return result(stop("inflateExpandedLimit"))
            }
            guard expansionDecision == .allowed else {
                return result(stop("inflateWorkLimit"))
            }
            messageExpanded += written
            guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
                return result(stop(status == Z_MEM_ERROR ? "inflateNativeMemory" : "inflateInvalidData"))
            }
            output.count = written
            if written > 0 { emit(output) }
            withExtendedLifetime(reservation) {}
            if let terminal { return result(terminal) }
            if status == Z_STREAM_END { recovery = true; continue }
            if read == 0 && written == 0 {
                // Z_BUF_ERROR is a request for more input, never a spin/retry loop.
                if finishing { return result(stop("inflateIncompleteFinal")) }
                return result(.needsInput)
            }
            // Drain buffered output with empty input until zlib says there is no progress.
        }
    }
    private func charge(_ count: Int) -> Bool {
        limiter.admit(session: sessionID, frames: 0, expandedBytes: 0, nativeOperations: count) == .allowed
    }
    @discardableResult private func stop(_ code: String) -> WebSocketInflateStatus {
        let status = WebSocketInflateStatus.stopped(WebSocketDiagnostic(code: code))
        terminal = status
        releaseNative()
        return status
    }
    private func releaseNative() {
        if let native { pwws_destroy(native); self.native = nil }
        scratch = nil
    }
    public func close() {
        if terminal == nil { terminal = .stopped(WebSocketDiagnostic(code: "inflateClosed")) }
        releaseNative()
    }
    deinit { if let native { pwws_destroy(native) } }
}
