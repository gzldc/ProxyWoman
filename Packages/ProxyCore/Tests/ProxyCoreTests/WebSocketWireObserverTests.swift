import Foundation
import Testing
import FlowStore
@testable import ProxyCore

@Suite(.productionChinese) struct WebSocketWireObserverTests {
    private let stamp = WebSocketCaptureStamp(epoch: 3, enabled: true, ingressSequence: 7)
    private let date = Date(timeIntervalSince1970: 100)

    private func collect(_ observer: WebSocketWireObserver, _ bytes: Data, into events: inout [WebSocketWireEvent]) {
        var offset = 0
        while offset < bytes.count {
            let result = observer.feed(Data(bytes.dropFirst(offset)), stamp: stamp, observedAt: date, monotonic: 99, baseOffset: UInt32(offset)) { events.append($0) }
            #expect(result.consumed <= 32768)
            #expect(result.frames <= 64)
            if result.disabled { break }
            #expect(result.consumed > 0)
            if result.consumed == 0 { break }
            offset += result.consumed
        }
    }
    private func starts(_ events: [WebSocketWireEvent]) -> [WebSocketFrameStart] {
        events.compactMap { if case .frameStart(let start) = $0 { return start }; return nil }
    }
    private func payload(_ events: [WebSocketWireEvent]) -> Data {
        events.reduce(into: Data()) { result, event in if case .payload(let bytes) = event { result.append(bytes) } }
    }
    private func diagnosticCount(_ events: [WebSocketWireEvent]) -> Int {
        events.filter { if case .diagnostic = $0 { return true }; return false }.count
    }

    @Test func splitEveryHeaderAndMaskBoundaryPreservesInput() {
        let fixtures: [(WebSocketDirection, [UInt8], Data)] = [
            (.clientToServer, [0x81, 0x85, 0x37, 0xFA, 0x21, 0x3D, 0x7F, 0x9F, 0x4D, 0x51, 0x58], Data("Hello".utf8)),
            (.serverToClient, [0x81, 0x05, 0x48, 0x65, 0x6C, 0x6C, 0x6F], Data("Hello".utf8)),
            (.serverToClient, [0x82, 126, 0, 126] + Array(repeating: 42, count: 126), Data(repeating: 42, count: 126)),
            (.serverToClient, [0x82, 127, 0, 0, 0, 0, 0, 1, 0, 0] + Array(repeating: 42, count: 65536), Data(repeating: 42, count: 65536)),
            (.clientToServer, [0x82, 254, 0, 126, 1, 2, 3, 4] + (0..<126).map { 42 ^ UInt8(($0 % 4) + 1) }, Data(repeating: 42, count: 126)),
            (.clientToServer, [0x82, 255, 0, 0, 0, 0, 0, 1, 0, 0, 1, 2, 3, 4] + (0..<65536).map { 42 ^ UInt8(($0 % 4) + 1) }, Data(repeating: 42, count: 65536))
        ]
        for (direction, raw, expected) in fixtures {
            for split in 0...min(raw.count, 15) {
                let input = Data(raw); let originalInput = input
                let observer = WebSocketWireObserver(direction: direction, mode: .messages(nil), limits: .init())
                var events: [WebSocketWireEvent] = []
                collect(observer, Data(input.prefix(split)), into: &events)
                collect(observer, Data(input.dropFirst(split)), into: &events)
                #expect(payload(events) == expected)
                #expect(input == originalInput)
                #expect(starts(events).count == 1)
                #expect(diagnosticCount(events) == 0)
                #expect(events.filter { if case .frameEnd = $0 { return true }; return false }.count == 1)
            }
        }
    }

    @Test(arguments: [
        [UInt8]([0x81, 0x80, 0, 0, 0, 0]), // server mask
        [0x83, 0], [0xC1, 0], [0xA1, 0], [0x80, 0],
        [0x09, 0], [0x89, 126, 0, 126],
        [0x82, 126, 0, 125], [0x82, 127, 0, 0, 0, 0, 0, 0, 0, 126],
        [0x82, 127, 0x80, 0, 0, 0, 0, 0, 0, 0],
        [0x82, 127, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
        [0x01, 0, 0x81, 0]
    ]) func semanticErrorsDisableOnce(_ raw: [UInt8]) {
        let observer = WebSocketWireObserver(direction: .serverToClient, mode: .messages(nil), limits: .init())
        var events: [WebSocketWireEvent] = []
        collect(observer, Data(raw), into: &events)
        let after = observer.feed(Data([0x81, 0]), stamp: stamp, observedAt: date, monotonic: 100) { events.append($0) }
        #expect(after.disabled)
        #expect(diagnosticCount(events) == 1)
        let count = events.count
        observer.end { events.append($0) }
        #expect(events.count == count)
    }

    @Test func wrongClientMaskAndWireLimit() {
        for (direction, data) in [(WebSocketDirection.clientToServer, Data([0x81, 0])), (.serverToClient, Data([0x01, 2, 1, 2, 0x80, 2, 3, 4]))] {
            var limits = WebSocketLimits(); limits.messageWireBytes = 3
            let observer = WebSocketWireObserver(direction: direction, mode: .messages(nil), limits: limits)
            var events: [WebSocketWireEvent] = []
            collect(observer, data, into: &events)
            #expect(diagnosticCount(events) == 1)
        }
    }

    @Test func fragmentationControlAndEmptyMessage() {
        let observer = WebSocketWireObserver(direction: .serverToClient, mode: .messages(nil), limits: .init())
        var events: [WebSocketWireEvent] = []
        collect(observer, Data([0x01, 1, 65, 0x89, 1, 88, 0x8A, 0, 0x88, 0, 0x80, 1, 66, 0x81, 0]), into: &events)
        let frames = starts(events)
        #expect(frames.map(\.descriptor.opcode) == [1, 9, 10, 8, 0, 1])
        #expect(frames.map(\.dataMessageStart) == [true, false, false, false, false, true])
        #expect(frames.map(\.dataMessageEnd) == [false, false, false, false, true, true])
        #expect(frames.map(\.order.offset) == [0, 3, 6, 8, 10, 13])
        #expect(frames.allSatisfy { $0.stamp == stamp && $0.observedAt == date && $0.monotonic == 99 })
        #expect(diagnosticCount(events) == 0)
    }

    @Test func frameLimitAndQuantumYield() {
        let observer = WebSocketWireObserver(direction: .serverToClient, mode: .messages(nil), limits: .init())
        var raw = Data([0x01, 0]); for _ in 0..<4096 { raw.append(contentsOf: [0, 0]) }
        var events: [WebSocketWireEvent] = []
        collect(observer, raw, into: &events)
        #expect(starts(events).count == 4096)
        #expect(diagnosticCount(events) == 1)
        var limits = WebSocketLimits(); limits.quantumBytes = 3; limits.quantumFrames = 1
        let bounded = WebSocketWireObserver(direction: .serverToClient, mode: .messages(nil), limits: limits)
        let progress = bounded.feed(Data([0x81, 0, 0x81, 0]), stamp: stamp, observedAt: date, monotonic: 99) { _ in }
        #expect(progress.consumed == 2 && progress.frames == 1 && !progress.disabled)
    }

    @Test func firstByteOrderSurvivesReverseCompletionAndEpoch() {
        let a = WebSocketWireObserver(direction: .serverToClient, mode: .messages(nil), limits: .init())
        let b = WebSocketWireObserver(direction: .clientToServer, mode: .messages(nil), limits: .init())
        let s1 = WebSocketCaptureStamp(epoch: 1, enabled: true, ingressSequence: 1)
        let s2 = WebSocketCaptureStamp(epoch: 2, enabled: false, ingressSequence: 2)
        let s3 = WebSocketCaptureStamp(epoch: 3, enabled: true, ingressSequence: 3)
        var events: [WebSocketWireEvent] = []
        _ = a.feed(Data([0x81]), stamp: s1, observedAt: date, monotonic: 1, baseOffset: 4) { events.append($0) }
        #expect(events.count == 1)
        #expect(starts(events).isEmpty)
        _ = b.feed(Data([0x81, 0x80, 0, 0, 0, 0]), stamp: s2, observedAt: date.addingTimeInterval(1), monotonic: 2) { events.append($0) }
        _ = a.feed(Data([0]), stamp: s3, observedAt: date.addingTimeInterval(2), monotonic: 3) { events.append($0) }
        let headers = events.compactMap { if case .headerStart(let h) = $0 { return h }; return nil }
        #expect(headers.map(\.stamp) == [s1, s2])
        #expect(headers.map(\.firstByte) == [0x81, 0x81])
        #expect(starts(events).map(\.stamp) == [s2, s1])
        #expect(starts(events).map(\.order) == [.init(ingressSequence: 2, offset: 0), .init(ingressSequence: 1, offset: 4)])
        #expect(starts(events).last?.monotonic == 1)
        #expect(starts(events).last?.observedAt == date)
    }

    @Test func eofAndInvalidPendingDoNotHoldOtherDirection() {
        for tail in [Data(), Data([126, 0, 0])] {
            let a = WebSocketWireObserver(direction: .serverToClient, mode: .messages(nil), limits: .init())
            let b = WebSocketWireObserver(direction: .serverToClient, mode: .messages(nil), limits: .init())
            var events: [WebSocketWireEvent] = []
            collect(a, Data([0x81]), into: &events)
            collect(b, Data([0x81, 0]), into: &events)
            collect(a, tail, into: &events)
            a.end { events.append($0) }
            #expect(starts(events).count == 1)
            #expect(events.filter { if case .headerStart = $0 { return true }; return false }.count == 2)
            #expect(events.filter { if case .incompleteTransport = $0 { return true }; return false }.count == (tail.isEmpty ? 1 : 0))
        }
        for raw in [[UInt8]([0x81, 2, 65]), [0x01, 0]] {
            let observer = WebSocketWireObserver(direction: .serverToClient, mode: .messages(nil), limits: .init())
            var events: [WebSocketWireEvent] = []
            collect(observer, Data(raw), into: &events)
            observer.end { events.append($0) }
            observer.end { events.append($0) }
            #expect(events.filter { if case .incompleteTransport = $0 { return true }; return false }.count == 1)
        }
    }

    @Test func opaqueFramesNeverInferMessageOrControlSemantics() {
        let observer = WebSocketWireObserver(direction: .serverToClient, mode: .opaqueFrames, limits: .init())
        var events: [WebSocketWireEvent] = []
        collect(observer, Data([0x79, 126, 0, 126] + Array(repeating: 1, count: 126) + [0x80, 0]), into: &events)
        #expect(starts(events).count == 2)
        #expect(starts(events).allSatisfy { !$0.dataMessageStart && !$0.dataMessageEnd && !$0.compressed })
        #expect(diagnosticCount(events) == 0)
    }

    @Test func quantumResumesMaskAndHonorsSlicedDataIndices() {
        var limits = WebSocketLimits(); limits.quantumBytes = 1
        let observer = WebSocketWireObserver(direction: .clientToServer, mode: .messages(nil), limits: limits)
        let input = Data([99, 0x81, 0x85, 0x37, 0xFA, 0x21, 0x3D, 0x7F, 0x9F, 0x4D, 0x51, 0x58]).dropFirst()
        var cursor = input.startIndex
        var events: [WebSocketWireEvent] = []
        while cursor < input.endIndex {
            let progress = observer.feed(input[cursor...], stamp: stamp, observedAt: date, monotonic: 99, baseOffset: UInt32(cursor)) { events.append($0) }
            #expect(progress.consumed == 1 && !progress.disabled)
            cursor += progress.consumed
        }
        #expect(payload(events) == Data("Hello".utf8))
        #expect(starts(events).count == 1)
        #expect(starts(events).first?.order.offset == 1)
        #expect(events.filter { if case .headerStart = $0 { return true }; return false }.count == 1)
    }

    @Test func externalDisableIsTerminalAndDiagnosticBounded() {
        let observer = WebSocketWireObserver(direction: .serverToClient, mode: .messages(nil), limits: .init())
        var events: [WebSocketWireEvent] = []
        collect(observer, Data([0x81]), into: &events)
        observer.disable(reason: .init(code: String(repeating: "💥", count: 100), detail: String(repeating: "界", count: 100)))
        observer.disable(reason: .init(code: "second"))
        let result = observer.feed(Data([0]), stamp: stamp, observedAt: date, monotonic: 99) { events.append($0) }
        observer.end { events.append($0) }
        #expect(result.disabled && result.consumed == 0)
        #expect(starts(events).isEmpty)
        #expect(diagnosticCount(events) == 1)
        let diagnostics = events.compactMap { if case .diagnostic(let d) = $0 { return d }; return nil }
        #expect(diagnostics[0].code.utf8.count == 128)
        #expect(diagnostics[0].detail?.utf8.count == 126)
    }

    @Test func synchronousAdmissionStopCannotPublishCompletion() {
        for stopAt in ["header", "frame", "payload"] {
            let observer = WebSocketWireObserver(direction: .serverToClient, mode: .messages(nil), limits: .init())
            var events: [WebSocketWireEvent] = []
            let result = observer.feed(Data([0x81, 1, 65, 0x81, 0]), stamp: stamp, observedAt: date, monotonic: 99) { event in
                events.append(event)
                switch event {
                case .headerStart where stopAt == "header", .frameStart where stopAt == "frame", .payload where stopAt == "payload":
                    observer.disable(reason: .init(code: "captureBudgetExhausted"))
                default: break
                }
            }
            #expect(result.disabled)
            #expect(events.filter { if case .frameEnd = $0 { return true }; return false }.isEmpty)
            #expect(events.filter { if case .headerStart = $0 { return true }; return false }.count == 1)
            #expect(diagnosticCount(events) == 1)
        }
    }

    @Test func invalidQuantumCannotExceedConfiguredBudget() {
        for (bytes, frames) in [(0, 64), (-1, 64), (32768, 0), (32768, -1)] {
            var limits = WebSocketLimits(); limits.quantumBytes = bytes; limits.quantumFrames = frames
            let observer = WebSocketWireObserver(direction: .serverToClient, mode: .messages(nil), limits: limits)
            var events: [WebSocketWireEvent] = []
            let result = observer.feed(Data([0x81, 0]), stamp: stamp, observedAt: date, monotonic: 99) { events.append($0) }
            #expect(result.disabled && result.consumed == 0 && result.frames == 0)
            #expect(starts(events).isEmpty)
            #expect(diagnosticCount(events) == 1)
        }
    }

    @Test func offsetOverflowStopsWithoutWrappingOrder() {
        let observer = WebSocketWireObserver(direction: .serverToClient, mode: .messages(nil), limits: .init())
        var events: [WebSocketWireEvent] = []
        let result = observer.feed(Data([0x81, 0, 0x81, 0]), stamp: stamp, observedAt: date, monotonic: 99, baseOffset: UInt32.max) { events.append($0) }
        #expect(result.disabled && result.consumed == 2)
        #expect(starts(events).count == 1)
        #expect(starts(events)[0].order.offset == UInt32.max)
        #expect(diagnosticCount(events) == 1)
    }

    @Test func compressionBitOnlyOnInitialDataFrame() {
        let compression = WebSocketCompression(client: .init(windowBits: 15, noContextTakeover: false), server: .init(windowBits: 15, noContextTakeover: false))
        let observer = WebSocketWireObserver(direction: .serverToClient, mode: .messages(compression), limits: .init())
        var events: [WebSocketWireEvent] = []
        collect(observer, Data([0x41, 0, 0x89, 0, 0x80, 0, 0xC9, 0]), into: &events)
        #expect(starts(events).map(\.compressed) == [true, false, true])
        #expect(diagnosticCount(events) == 1)
    }
}
