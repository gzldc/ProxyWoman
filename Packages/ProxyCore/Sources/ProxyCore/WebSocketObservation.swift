import Foundation
import FlowStore

/// The one lifetime worker owns this actor and all non-Sendable parser/native state.
actor WebSocketObservation {
    private final class Message {
        var metadata: WebSocketEventMetadata
        let stamp: WebSocketCaptureStamp
        var capturing: Bool
        var application: WebSocketPayloadAccumulator?
        var wire: WebSocketPayloadAccumulator?
        let utf8 = WebSocketUTF8Validator()
        let closeUTF8 = WebSocketUTF8Validator()
        var closeCount = 0
        var code: UInt16 = 0
        var final = false
        var isData: Bool
        var compressed = false
        var charge: WebSocketReservation?
        init(metadata: WebSocketEventMetadata, stamp: WebSocketCaptureStamp, capturing: Bool,
             isData: Bool, charge: consuming WebSocketReservation?) {
            self.metadata = metadata; self.stamp = stamp; self.capturing = capturing; self.isData = isData; self.charge = charge
        }
    }
    private final class Direction {
        let value: WebSocketDirection
        let parser: WebSocketWireObserver
        var inflater: WebSocketInflater?
        var data: Message?
        var current: Message?
        var stopped = false
        var ended = false
        init(_ direction: WebSocketDirection, mode: WebSocketObservationMode, limits: WebSocketLimits) {
            value = direction; parser = WebSocketWireObserver(direction: direction, mode: mode, limits: limits)
        }
    }
    private let token: WebSocketSessionToken
    private let store: FlowStore
    private let mode: WebSocketObservationMode
    private let mailbox: ObservationMailbox
    private let limiter: WebSocketWorkLimiter
    private let clock: WebSocketObservationClock
    private let hooks: WebSocketObservationHooks
    private var scratch: WebSocketDictionaryScratch?
    private let client: Direction
    private let server: Direction
    private var nextID: UInt64 = 0
    init(token: WebSocketSessionToken, store: FlowStore, assessment: WebSocketHandshakeAssessment,
         mailbox: ObservationMailbox, limiter: WebSocketWorkLimiter, clock: WebSocketObservationClock,
         hooks: WebSocketObservationHooks = .init()) {
        self.token = token; self.store = store; mode = assessment.mode; self.mailbox = mailbox
        self.limiter = limiter; self.clock = clock; self.hooks = hooks
        var limits = store.webSocketLimits
        limits.quantumBytes = min(limits.quantumBytes, 32_768); limits.quantumFrames = min(limits.quantumFrames, 64)
        client = Direction(.clientToServer, mode: assessment.mode, limits: limits)
        server = Direction(.serverToClient, mode: assessment.mode, limits: limits)
    }
    func drain() async {
        if let reservation = store.takeWebSocketScratchReservation(token: token) {
            scratch = try? WebSocketDictionaryScratch(reservation: reservation)
        }
        if scratch == nil { mailbox.cancel() }
        if case .messages(let compression?) = mode, let scratch {
            for direction in [client, server] {
                do {
                    direction.inflater = try WebSocketInflater(parameters: compression.parameters(for: direction.value),
                        budget: store.webSocketBudget, limiter: limiter, sessionID: token.sessionID, dictionaryScratch: scratch)
                } catch { stop(direction, diagnostic: .init(code: "inflateInitialization")) }
            }
        }
        mailbox.signal()
        for await _ in mailbox.wakes {
            repeat {
                refreshEpoch()
                if mailbox.isCancelled || store.webSocketSummary(token: token) == nil { break }
                while let input = mailbox.take() {
                    switch consume input {
                    case .chunk(let chunk):
                        let sequence = chunk.sequence
                        await hooks.afterTake?()
                        await process(chunk)
                        // process consumes and releases the Data plus both charges before ack.
                        mailbox.finishChunk(sequence: sequence)
                        await hooks.afterChunk?()
                    case .eof(let end): transportEnded(end)
                    }
                    if mailbox.isFinished { break }
                }
                if mailbox.isFinished { break }
            } while mailbox.finishDrain()
            if mailbox.isFinished || store.webSocketSummary(token: token) == nil { break }
        }
        await hooks.beforeCleanup?()
        cancel()
    }
    private func process(_ chunk: consuming ObservationChunk) async {
        let storage = chunk.storage
        let direction = storage.direction == .clientToServer ? client : server
        guard !direction.stopped, !mailbox.isCancelled else { return }
        var cursor = 0
        while cursor < storage.bytes.count && !direction.stopped && !mailbox.isCancelled {
            refreshEpoch()
            // Covers copied feed suffix and parser-owned unmasked payload emissions. Event
            // staging is only this ≤32 KiB/64-frame quantum, consumed before the next feed.
            guard let payloadCharge = store.webSocketBudget.reserve(category: .working, bytes: 65_536),
                  let eventCharge = store.webSocketBudget.reserve(category: .metadata, bytes: 132_096) else {
                stop(direction, diagnostic: .init(code: "observationWorkingMemory")); return
            }
            var events: [WebSocketWireEvent] = []
            var stagedPayload = 0, stagingOverflow = false
            var input = Data(storage.bytes.dropFirst(cursor))
            let progress = direction.parser.feed(input, stamp: storage.stamp, observedAt: storage.observedAt,
                monotonic: storage.monotonic, baseOffset: storage.baseOffset + UInt32(cursor)) { event in
                guard events.count < 258 else { stagingOverflow = true; return }
                if case .payload(let bytes) = event {
                    guard bytes.count <= 32_768 - stagedPayload else { stagingOverflow = true; return }
                    stagedPayload += bytes.count
                }
                events.append(event)
            }
            if stagingOverflow {
                events.removeAll(); input = Data()
                payloadCharge.release(); eventCharge.release()
                stop(direction, diagnostic: .init(code: "parserStagingLimit")); return
            }
            await hooks.afterParserStage?()
            refreshEpoch()
            for event in events {
                if mailbox.isCancelled { break }
                await consume(event, direction: direction, observedAt: storage.observedAt, monotonic: storage.monotonic)
            }
            // A split header may consume bytes without emitting another event yet.
            if progress.consumed > 0, let message = direction.current {
                observed(message, at: storage.observedAt, monotonic: storage.monotonic)
            }
            events.removeAll(); input = Data()
            payloadCharge.release(); eventCharge.release()
            cursor += progress.consumed
            if progress.disabled || progress.consumed == 0 { break }
            await Task.yield()
        }
    }
    private func refreshEpoch() {
        let recording = store.webSocketRecordingState()
        for direction in [client, server] {
            for message in [direction.data, direction.current].compactMap({ $0 }) {
                if !recording.enabled || recording.epoch != message.stamp.epoch {
                    message.capturing = false; message.application?.revoke(); message.wire?.revoke()
                    message.application = nil; message.wire = nil
                }
            }
        }
    }
    private func observed(_ message: Message, at: Date, monotonic: UInt64) {
        message.metadata.lastObservedAt = at
        message.metadata.monotonicEnd = monotonic
    }
    private func consume(_ event: WebSocketWireEvent, direction: Direction, observedAt: Date, monotonic: UInt64) async {
        guard !direction.stopped else { return }
        // Only the current frame owns these bytes; an interleaved control or invalid new
        // header must not advance an earlier fragmented message's last input time.
        if case .headerStart = event {} else if let message = direction.current {
            observed(message, at: observedAt, monotonic: monotonic)
        }
        switch event {
        case .headerStart(let start):
            let opcode = start.firstByte & 15
            if mode != .opaqueFrames && opcode == 0, let active = direction.data {
                direction.current = active; observed(active, at: observedAt, monotonic: monotonic); return
            }
            guard nextID < .max else { stop(direction, diagnostic: .init(code: "eventIDExhausted")); return }
            nextID += 1
            let kind: WebSocketEventKind = mode == .opaqueFrames ? .opaqueFrame
                : [1: .text, 2: .binary, 8: .close, 9: .ping, 10: .pong][Int(opcode)] ?? .diagnostic
            var metadata = WebSocketEventMetadata(id: nextID, order: start.order, direction: direction.value, kind: kind)
            metadata.opcode = opcode; metadata.firstObservedAt = start.observedAt; metadata.lastObservedAt = start.observedAt
            metadata.monotonicStart = start.monotonic; metadata.monotonicEnd = start.monotonic
            if mode == .opaqueFrames { metadata.integrity = .opaque; metadata.lowerBound = true }
            let recording = store.webSocketRecordingState()
            var capturing = start.stamp.enabled && recording.enabled && recording.epoch == start.stamp.epoch
            if store.webSocketSummary(token: token).map({ direction.value == .clientToServer ? $0.clientToServer.capture : $0.serverToClient.capture }) == .opaquePausedUntilReconnect { capturing = false }
            let charge = store.webSocketBudget.reserve(category: .metadata,
                bytes: 512 + 640 + (capturing ? 64 * max(0, min(64, store.webSocketLimits.fragmentDescriptors)) : 0))
            guard charge != nil else { stop(direction, diagnostic: .init(code: "eventMetadataLimit")); return }
            if capturing {
                let result = store.publishWebSocket(.init(metadata: metadata, stamp: start.stamp), token: token, captureEpoch: start.stamp.epoch)
                capturing = result == .accepted
                if result == .captureBudgetExhausted { stop(direction, diagnostic: .init(code: "eventAdmissionLimit")); return }
            } else {
                store.recordWebSocketState(.droppedEvents(direction: direction.value, count: 1), token: token)
            }
            let message = Message(metadata: metadata, stamp: start.stamp, capturing: capturing,
                isData: mode != .opaqueFrames && (opcode == 1 || opcode == 2), charge: charge)
            // headerStart is provisional: validation may reject an overlapping data
            // frame. Keep the existing fragmented owner until a validated start arrives.
            direction.current = message
        case .frameStart(let start):
            switch limiter.admit(session: token.sessionID, frames: 1, expandedBytes: 0, nativeOperations: 0) {
            case .allowed: break
            case .stopSession: mailbox.cancel(); return
            case .stopDirection: stop(direction, diagnostic: .init(code: "frameWorkLimit")); return
            }
            guard let message = direction.current else { stop(direction, diagnostic: .init(code: "missingFrameStart")); return }
            if start.dataMessageStart { direction.data = message }
            message.metadata.fragmentCount += 1
            let descriptorFits = message.metadata.fragments.count < min(64, max(0, store.webSocketLimits.fragmentDescriptors))
            if message.capturing && descriptorFits {
                message.metadata.fragments.append(start.descriptor)
            } else if message.metadata.fragmentCount > UInt64(max(0, min(64, store.webSocketLimits.fragmentDescriptors))) { message.metadata.descriptorTruncated = true }
            message.metadata.compressed = start.compressed; message.compressed = start.compressed
            message.final = mode == .opaqueFrames || start.descriptor.opcode >= 8 || start.dataMessageEnd
        case .payload(let bytes):
            guard let message = direction.current else { return }
            message.metadata.wirePayloadBytes += UInt64(bytes.count)
            append(bytes, to: message, kind: .wirePayload, direction: direction)
            if mode == .opaqueFrames { return }
            if message.compressed {
                await inflate(bytes, final: false, message: message, direction: direction)
            } else {
                if message.isData {
                    guard limiter.admit(session: token.sessionID, frames: 0, expandedBytes: bytes.count, nativeOperations: 0) == .allowed else {
                        stop(direction, diagnostic: .init(code: "expandedWorkLimit")); return
                    }
                    store.recordWebSocketState(.observedBytes(direction: direction.value, wire: 0, application: UInt64(bytes.count), lowerBound: false), token: token)
                }
                decoded(bytes, message: message, direction: direction)
            }
        case .frameEnd:
            guard let message = direction.current else { return }
            if message.final {
                if message.compressed { await inflate(Data(), final: true, message: message, direction: direction) }
                guard !direction.stopped else { return }
                if message.metadata.kind == .text { message.metadata.utf8 = message.utf8.finish() ? .valid : .invalid }
                if message.metadata.utf8 == .invalid {
                    message.metadata.integrity = .invalid; message.metadata.diagnostics = [.init(code: "invalidTextUTF8")]
                    finish(message, completed: true)
                    stop(direction, diagnostic: .init(code: "invalidTextUTF8")); return
                }
                if message.metadata.kind == .close {
                    let validCode = message.closeCount == 0 || Self.validCloseCode(message.code)
                    guard message.closeCount != 1, validCode, message.closeUTF8.finish() else {
                        message.metadata.integrity = .invalid; message.metadata.diagnostics = [.init(code: "invalidClosePayload")]
                        finish(message, completed: true); stop(direction, diagnostic: .init(code: "invalidClosePayload")); return
                    }
                    message.metadata.closeCode = message.closeCount == 0 ? nil : message.code
                    store.recordWebSocketState(.closeFrame(direction: direction.value, code: message.metadata.closeCode), token: token)
                }
                finish(message, completed: true)
                if message.isData { direction.data = nil }
            }
            direction.current = nil
        case .diagnostic(let diagnostic):
            for message in uniqueMessages(direction) { message.metadata.integrity = .invalid }
            stop(direction, diagnostic: diagnostic)
        case .incompleteTransport:
            for message in uniqueMessages(direction) {
                message.metadata.integrity = .incompleteTransport; message.metadata.captureAbandoned = true; finish(message, completed: false)
            }
        }
    }
    private func append(_ bytes: Data, to message: Message, kind: WebSocketPayloadKind, direction: Direction) {
        guard message.capturing else { return }
        if (kind == .application ? message.application : message.wire) == nil {
            let accumulator = store.makeWebSocketAccumulator(token: token, eventID: message.metadata.id, epoch: message.stamp.epoch, kind: kind)
            if kind == .application { message.application = accumulator } else { message.wire = accumulator }
        }
        let accumulator = kind == .application ? message.application : message.wire
        if accumulator?.append(bytes, expectedEpoch: message.stamp.epoch) != true {
            let recording = store.webSocketRecordingState()
            if !recording.enabled || recording.epoch != message.stamp.epoch { message.capturing = false }
            else { stop(direction, diagnostic: .init(code: "prefixWorkingLimit")) }
        }
    }
    private func decoded(_ bytes: Data, message: Message, direction: Direction) {
        message.metadata.decodedBytes += UInt64(bytes.count)
        let expansionExceeded = message.metadata.decodedBytes > UInt64(max(0, store.webSocketLimits.messageExpandedBytes))
        if message.isData && expansionExceeded {
            stop(direction, diagnostic: .init(code: "messageExpandedLimit")); return
        }
        if message.metadata.kind == .text { _ = message.utf8.feed(bytes) }
        if message.metadata.kind == .close {
            var reasonStart = bytes.startIndex
            for byte in bytes {
                if message.closeCount >= 2 { break }
                message.code = (message.code << 8) | UInt16(byte); message.closeCount += 1; reasonStart += 1
            }
            if reasonStart < bytes.endIndex {
                _ = message.closeUTF8.feed(Data(bytes[reasonStart...])); message.closeCount += bytes.endIndex - reasonStart
            }
        }
        append(bytes, to: message, kind: .application, direction: direction)
    }
    private func inflate(_ bytes: Data, final: Bool, message: Message, direction: Direction) async {
        guard let inflater = direction.inflater else { stop(direction, diagnostic: .init(code: "inflateUnavailable")); return }
        var cursor = 0
        repeat {
            guard !mailbox.isCancelled && !direction.stopped else { return }
            refreshEpoch()
            // One fixed output slab and one independent input suffix. Native owns its
            // transient slab separately; callback bytes never outlive that reservation.
            guard let outputCharge = store.webSocketBudget.reserve(category: .working, bytes: 65_536) else {
                stop(direction, diagnostic: .init(code: "inflateOutputWorkingMemory")); return
            }
            var output = Data(count: 32_768), count = 0
            var input = Data(bytes.dropFirst(cursor))
            let progress = inflater.feed(input, final: final) { part in
                precondition(part.count <= 32_768 - count)
                output.withUnsafeMutableBytes { destination in
                    part.withUnsafeBytes { source in
                        destination.baseAddress!.advanced(by: count).copyMemory(from: source.baseAddress!, byteCount: part.count)
                    }
                }
                count += part.count
            }
            output.count = count
            await hooks.afterNativeStage?()
            refreshEpoch()
            if !mailbox.isCancelled && !direction.stopped { decoded(output, message: message, direction: direction) }
            output = Data(); input = Data(); outputCharge.release()
            store.recordWebSocketState(.observedBytes(direction: direction.value, wire: 0,
                application: UInt64(progress.produced), lowerBound: false), token: token)
            cursor += progress.consumed
            switch progress.status {
            case .yield: await Task.yield()
            case .needsInput: return
            case .messageComplete: return
            case .stopped(let diagnostic): stop(direction, diagnostic: diagnostic); return
            case .opaqueCompression: stop(direction, diagnostic: .init(code: "opaqueCompression")); return
            }
        } while true
    }
    private func finish(_ message: Message, completed: Bool) {
        guard message.capturing else { message.application?.revoke(); message.wire?.revoke(); return }
        // Empty content is an available empty payload, not a missing body.
        let direction = message.metadata.direction == .clientToServer ? client : server
        if mode != .opaqueFrames && message.application == nil { append(Data(), to: message, kind: .application, direction: direction) }
        if message.wire == nil { append(Data(), to: message, kind: .wirePayload, direction: direction) }
        guard message.capturing else { return }
        message.metadata.completedAt = completed ? message.metadata.lastObservedAt : nil
        let applicationTruncated = message.metadata.decodedBytes > UInt64(max(0, store.webSocketLimits.decodedPrefixBytes))
        let wireTruncated = message.metadata.wirePayloadBytes > UInt64(max(0, store.webSocketLimits.wirePrefixBytes))
        if (applicationTruncated || wireTruncated) && message.metadata.integrity == .transportComplete { message.metadata.integrity = .captureTruncated }
        let application = message.application?.take(kind: .application, complete: completed, truncated: applicationTruncated)
        let wire = message.wire?.take(kind: .wirePayload, complete: completed, truncated: wireTruncated)
        let result = store.publishWebSocket(.init(metadata: message.metadata, stamp: message.stamp, application: application, wirePayload: wire),
            token: token, captureEpoch: message.stamp.epoch)
        message.capturing = false; message.application = nil; message.wire = nil
        if result == .captureBudgetExhausted { stop(direction, diagnostic: .init(code: "eventPublishLimit")) }
    }
    private func uniqueMessages(_ direction: Direction) -> [Message] {
        if let data = direction.data, let current = direction.current, data === current { return [data] }
        return [direction.data, direction.current].compactMap { $0 }
    }
    private func stop(_ direction: Direction, diagnostic: WebSocketDiagnostic) {
        guard !direction.stopped else { return }
        direction.stopped = true
        for message in uniqueMessages(direction) {
            if message.metadata.integrity == .transportComplete || message.metadata.integrity == .captureTruncated {
                message.metadata.integrity = .observationStopped
            }
            message.metadata.captureAbandoned = true
            if message.metadata.diagnostics.isEmpty { message.metadata.diagnostics = [diagnostic] }
            finish(message, completed: false)
        }
        direction.current = nil; direction.data = nil
        direction.parser.disable(reason: diagnostic); direction.inflater?.close(); direction.inflater = nil
        store.recordWebSocketState(.capture(direction: direction.value, state: .contentStoppedUntilReconnect, diagnostic: diagnostic), token: token)
        store.recordWebSocketState(.observedBytes(direction: direction.value, wire: 0, application: 0, lowerBound: true), token: token)
        if client.stopped && server.stopped { mailbox.cancel() }
    }
    func transportEnded(_ end: WebSocketTransportEnd) {
        let direction = end.direction == .clientToServer ? client : server
        guard !direction.ended else { return }
        direction.ended = true
        var incomplete = false
        direction.parser.end { event in if case .incompleteTransport = event { incomplete = true } }
        if incomplete {
            for message in uniqueMessages(direction) { message.metadata.integrity = .incompleteTransport; message.metadata.captureAbandoned = true; finish(message, completed: false) }
        }
        direction.inflater?.close(); direction.inflater = nil
        direction.current = nil; direction.data = nil
        store.endWebSocket(token: token, transport: end)
    }
    func cancel() {
        if !client.ended { stop(client, diagnostic: .init(code: "observationStopped")) }
        if !server.ended { stop(server, diagnostic: .init(code: "observationStopped")) }
        mailbox.cancel(); scratch = nil
    }
    private static func validCloseCode(_ code: UInt16) -> Bool {
        (1000...1014).contains(code) && ![1004, 1005, 1006].contains(code) || (3000...4999).contains(code)
    }
}
