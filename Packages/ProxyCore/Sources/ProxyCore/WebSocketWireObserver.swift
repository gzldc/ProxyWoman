import Foundation
import FlowStore

public struct WebSocketHeaderStart: Sendable, Equatable {
    public let firstByte: UInt8
    public let stamp: WebSocketCaptureStamp
    public let order: WebSocketOrder
    public let observedAt: Date
    public let monotonic: UInt64
}

public struct WebSocketFrameStart: Sendable, Equatable {
    public let descriptor: WebSocketFragmentDescriptor
    public let stamp: WebSocketCaptureStamp
    public let order: WebSocketOrder
    public let observedAt: Date
    public let monotonic: UInt64
    public let dataMessageStart: Bool
    public let dataMessageEnd: Bool
    public let compressed: Bool
}

public enum WebSocketWireEvent: Sendable, Equatable {
    case headerStart(WebSocketHeaderStart)
    case frameStart(WebSocketFrameStart)
    case payload(Data)
    case frameEnd
    case diagnostic(WebSocketDiagnostic)
    case incompleteTransport
}

public struct WebSocketParseProgress: Sendable, Equatable {
    public let consumed: Int
    /// Complete frames emitted during this feed, including empty frames.
    public let frames: Int
    public let disabled: Bool
}

/// Pure, non-Sendable parser for a single direction. The future observer actor owns it.
/// Payload emissions are private transient copies (at most 32 KiB); caller owns their
/// working reservation and must consume/release them before resuming input processing.
public final class WebSocketWireObserver {
    private let direction: WebSocketDirection
    private let mode: WebSocketObservationMode
    private let limits: WebSocketLimits
    private var header: [UInt8] = []
    private var first: WebSocketHeaderStart?
    private var remaining: UInt64 = 0
    private var inPayload = false
    private var mask: [UInt8] = []
    private var maskOffset = 0
    private var activeMessage = false
    private var messageCompressed = false
    private var messageBytes: UInt64 = 0
    private var messageFrames = 0
    private var stopped = false
    private var deferredDiagnostic: WebSocketDiagnostic?

    public init(direction: WebSocketDirection, mode: WebSocketObservationMode, limits: WebSocketLimits) {
        self.direction = direction; self.mode = mode; self.limits = limits
        stopped = mode == .disabled
        header.reserveCapacity(14)
        if !stopped && (limits.quantumBytes <= 0 || limits.quantumFrames <= 0) {
            stopped = true
            deferredDiagnostic = .init(code: "invalidParserQuantum")
        }
    }

    /// Terminal external stop. Since no callback is provided, the bounded diagnostic is
    /// emitted once before an active feed returns, or at the next feed/end otherwise.
    /// Repeated disables never replace the first reason. Emit callbacks may call disable;
    /// they must not recursively feed input into this same parser.
    public func disable(reason: WebSocketDiagnostic) {
        guard !stopped else { return }
        stopped = true
        deferredDiagnostic = .init(code: Self.bounded(reason.code), detail: reason.detail.map(Self.bounded))
        clear()
    }

    public func feed(_ bytes: Data, stamp: WebSocketCaptureStamp, observedAt: Date,
                     monotonic: UInt64, baseOffset: UInt32 = 0,
                     emit: (WebSocketWireEvent) -> Void) -> WebSocketParseProgress {
        flushDiagnostic(emit)
        var consumed = 0
        var frames = 0
        let byteBudget = min(bytes.count, max(0, limits.quantumBytes))
        let frameBudget = max(0, limits.quantumFrames)
        while !stopped && consumed < byteBudget && frames < frameBudget {
            if inPayload {
                let count = Int(min(remaining, UInt64(min(32_768, byteBudget - consumed))))
                let start = bytes.index(bytes.startIndex, offsetBy: consumed)
                var privateBytes = Data(bytes[start..<bytes.index(start, offsetBy: count)])
                if !mask.isEmpty {
                    for index in privateBytes.indices {
                        privateBytes[index] ^= mask[maskOffset]
                        maskOffset = (maskOffset + 1) % 4
                    }
                }
                consumed += count; remaining -= UInt64(count)
                emit(.payload(privateBytes))
                guard !stopped else { break }
                if remaining == 0 {
                    inPayload = false; frames += 1
                    emit(.frameEnd)
                    header.removeAll(keepingCapacity: true); first = nil; mask.removeAll(keepingCapacity: true)
                }
                continue
            }
            if header.isEmpty {
                guard let relative = UInt32(exactly: consumed) else { fail("orderOffsetOverflow", emit); break }
                let (offset, overflow) = baseOffset.addingReportingOverflow(relative)
                guard !overflow else { fail("orderOffsetOverflow", emit); break }
                let start = WebSocketHeaderStart(firstByte: bytes[bytes.index(bytes.startIndex, offsetBy: consumed)],
                    stamp: stamp, order: .init(ingressSequence: stamp.ingressSequence, offset: offset),
                    observedAt: observedAt, monotonic: monotonic)
                first = start
                header.append(start.firstByte); consumed += 1
                // Admission ordering must happen before any full-header validation.
                emit(.headerStart(start))
                continue
            }
            header.append(bytes[bytes.index(bytes.startIndex, offsetBy: consumed)])
            consumed += 1
            guard header.count >= 2 else { continue }
            let lengthCode = header[1] & 0x7F
            let extended = lengthCode == 126 ? 2 : (lengthCode == 127 ? 8 : 0)
            let masked = header[1] & 0x80 != 0
            let expected = 2 + extended + (masked ? 4 : 0)
            guard header.count == expected else { continue }
            guard let frame = validateHeader(extended: extended, masked: masked, emit: emit) else { break }
            remaining = frame.descriptor.length
            mask = masked ? Array(header.suffix(4)) : []
            maskOffset = 0
            emit(.frameStart(frame))
            guard !stopped else { break }
            if remaining == 0 {
                frames += 1; emit(.frameEnd)
                header.removeAll(keepingCapacity: true); first = nil; mask.removeAll(keepingCapacity: true)
            } else { inPayload = true }
        }
        flushDiagnostic(emit)
        return .init(consumed: consumed, frames: frames, disabled: stopped)
    }

    /// Emits incompleteTransport once for a partial header, payload, or fragmented message.
    /// A terminal semantic error already has its diagnostic and is not relabeled as EOF.
    public func end(emit: (WebSocketWireEvent) -> Void) {
        flushDiagnostic(emit)
        guard !stopped else { return }
        if !header.isEmpty || inPayload || activeMessage { emit(.incompleteTransport) }
        stopped = true; clear()
    }

    private func validateHeader(extended: Int, masked: Bool,
                                emit: (WebSocketWireEvent) -> Void) -> WebSocketFrameStart? {
        guard let first else { return nil }
        guard masked == (direction == .clientToServer) else { fail("invalidMask", emit); return nil }
        var length = UInt64(header[1] & 0x7F)
        if extended > 0 {
            if extended == 8 && header[2] & 0x80 != 0 { fail("invalidLengthHighBit", emit); return nil }
            length = 0
            for byte in header[2..<(2 + extended)] { length = (length << 8) | UInt64(byte) }
            if extended == 2 && length < 126 || extended == 8 && length < 65_536 {
                fail("nonMinimalLength", emit); return nil
            }
        }
        let opcode = header[0] & 0x0F
        let fin = header[0] & 0x80 != 0
        let rsv = (header[0] >> 4) & 7
        var messageStart = false
        var messageEnd = false
        var compressed = false
        let wireLimit = UInt64(max(0, limits.messageWireBytes))
        guard length <= wireLimit else { fail("messageWireLimit", emit); return nil }
        if case .messages(let compression) = mode {
            guard [UInt8(0), 1, 2, 8, 9, 10].contains(opcode) else { fail("invalidOpcode", emit); return nil }
            guard rsv & 3 == 0, rsv & 4 == 0 || (compression != nil && (opcode == 1 || opcode == 2)) else {
                fail("invalidRSV", emit); return nil
            }
            if opcode >= 8 {
                guard fin, length <= 125 else { fail("invalidControlFrame", emit); return nil }
            } else {
                if opcode == 0 {
                    guard activeMessage else { fail("unexpectedContinuation", emit); return nil }
                } else {
                    guard !activeMessage else { fail("overlappingDataMessage", emit); return nil }
                    messageStart = true; messageBytes = 0; messageFrames = 0
                    messageCompressed = rsv & 4 != 0
                }
                guard messageFrames < max(0, limits.messageFrames), length <= wireLimit - messageBytes else {
                    fail("messageLimit", emit); return nil
                }
                messageFrames += 1; messageBytes += length
                compressed = messageCompressed
                messageEnd = fin; activeMessage = !fin
            }
        }
        return .init(descriptor: .init(opcode: opcode, fin: fin, rsv: rsv, masked: masked, length: length, observedAt: first.observedAt),
                     stamp: first.stamp, order: first.order, observedAt: first.observedAt, monotonic: first.monotonic,
                     dataMessageStart: messageStart, dataMessageEnd: messageEnd, compressed: compressed)
    }

    private func fail(_ code: String, _ emit: (WebSocketWireEvent) -> Void) {
        disable(reason: .init(code: code)); flushDiagnostic(emit)
    }
    private func flushDiagnostic(_ emit: (WebSocketWireEvent) -> Void) {
        if let diagnostic = deferredDiagnostic { deferredDiagnostic = nil; emit(.diagnostic(diagnostic)) }
    }
    private func clear() {
        header.removeAll(keepingCapacity: true); first = nil
        mask.removeAll(keepingCapacity: true); remaining = 0; inPayload = false; activeMessage = false
    }
    private static func bounded(_ string: String) -> String {
        // Walk Unicode scalars so truncation cannot manufacture replacement characters.
        var result = ""
        var count = 0
        for scalar in string.unicodeScalars {
            let bytes = scalar.utf8.count
            if count + bytes > 128 { break }
            result.unicodeScalars.append(scalar); count += bytes
        }
        return result
    }
}
