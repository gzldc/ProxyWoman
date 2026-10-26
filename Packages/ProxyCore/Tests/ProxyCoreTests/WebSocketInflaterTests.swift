import Foundation
import Testing
import FlowStore
import CWebSocketZlib
@testable import ProxyCore

@Suite(.productionChinese) struct WebSocketInflaterTests {
    func make(_ limits: WebSocketLimits = .init(), parameters: WebSocketCompressionParameters = .init()) throws
        -> (WebSocketInflater, WebSocketMemoryBudget, WebSocketWorkLimiter, UUID) {
        let budget = WebSocketMemoryBudget(limits: limits)
        let scratch = try WebSocketDictionaryScratch(reservation: budget.reserve(category: .working, bytes: 32768)!)
        let limiter = WebSocketWorkLimiter(limits: limits, budget: budget, now: { 0 })
        let id = UUID()
        return (try WebSocketInflater(parameters: parameters, budget: budget, limiter: limiter,
                                      sessionID: id, dictionaryScratch: scratch), budget, limiter, id)
    }
    @discardableResult
    func drain(_ inflater: WebSocketInflater, _ bytes: Data, final: Bool, decoded: inout Data,
               quantum: Int = 32768, operations: Int = 64) -> WebSocketInflateProgress {
        var offset = 0
        for _ in 0..<20000 {
            let progress = inflater.feed(Data(bytes.dropFirst(offset)), final: final) {
                #expect($0.count <= 32768); decoded.append($0)
            }
            #expect(progress.consumed <= quantum)
            #expect(progress.produced <= quantum)
            #expect(progress.nativeOperations <= operations)
            offset += progress.consumed
            if progress.status != .yield {
                switch progress.status {
                case .needsInput, .messageComplete: #expect(offset == bytes.count)
                case .stopped, .opaqueCompression: #expect(offset <= bytes.count)
                case .yield: break
                }
                return progress
            }
        }
        Issue.record("Inflater failed to make bounded progress")
        return inflater.feed(Data(), final: false) { _ in }
    }
    @Test func fixedRFCVectorsAllSplits() throws {
        for vector in WebSocketCompressionVectors.hello + [WebSocketCompressionVectors.empty] {
            for split in 0...vector.count {
                let (inflater,budget,_,_) = try make()
                var decoded = Data()
                let first = drain(inflater, Data(vector.prefix(split)), final: false, decoded: &decoded)
                #expect(first.status == .needsInput)
                let last = drain(inflater, Data(vector.dropFirst(split)), final: true, decoded: &decoded)
                #expect(last.status == .messageComplete)
                #expect(decoded == (vector == WebSocketCompressionVectors.empty ? Data() : Data("Hello".utf8)))
                if split == 0 {
                    print("WS_VECTOR hex=\(vector.map { String(format: "%02x", $0) }.joined()) actualHex=\(decoded.map { String(format: "%02x", $0) }.joined()) consumed=\(last.consumed) nativeOps=\(last.nativeOperations) status=\(last.status)")
                }
                inflater.close()
                let nativeLiveBytes = budget.usedBytes(category: .native)
                #expect(nativeLiveBytes == 0)
            }
        }
    }
    @Test func bfinalPreservesHistoryAndNoContextClearsAtBoundary() throws {
        for noContext in [false,true] {
            let (inflater,budget,_,_) = try make(parameters: .init(noContextTakeover: noContext))
            var decoded = Data()
            #expect(drain(inflater, WebSocketCompressionVectors.bfinal, final: true, decoded: &decoded).status == .messageComplete)
            #expect(decoded == Data("Hello".utf8))
            decoded.removeAll()
            let next = drain(inflater, WebSocketCompressionVectors.takeover, final: true, decoded: &decoded)
            if noContext {
                #expect(next.status == .stopped(.init(code: "inflateInvalidData")))
                #expect(next.consumed >= 0 && next.consumed <= WebSocketCompressionVectors.takeover.count)
                print("WS_REJECT historyOnly consumed=\(next.consumed) status=\(next.status)")
                #expect(decoded.isEmpty)
                #expect(inflater.feed(WebSocketCompressionVectors.sync, final: true) { _ in }.status == next.status)
            }
            else { #expect(next.status == .messageComplete); #expect(decoded == Data("Hello".utf8)) }
            inflater.close(); #expect(budget.usedBytes(category: .native) == 0)
        }
    }
    @Test func truncatedFinalCannotPretendComplete() throws {
        let (inflater,budget,_,_) = try make()
        // Claims a 16-byte stored block, but only five literal bytes exist. Appended tail
        // is swallowed as content and must not turn an incomplete block into a FIN.
        let truncated = Data([0,16,0,239,255,72,101,108,108,111])
        let progress = inflater.feed(truncated, final: true) { _ in }
        #expect(progress.status == .stopped(.init(code: "inflateIncompleteFinal")))
        #expect(budget.usedBytes(category: .native) == 0)
    }
    @Test func invalidQuantumAndNativeFailureArePermanent() throws {
        for value in [0,-1] {
            var limits = WebSocketLimits(); limits.quantumBytes = value
            let (inflater,budget,_,_) = try make(limits)
            let result = inflater.feed(WebSocketCompressionVectors.sync, final: true) { _ in Issue.record("No output") }
            if case .stopped = result.status {} else { Issue.record("Invalid quantum must stop") }
            #expect(inflater.feed(Data(), final: true) { _ in }.status == result.status)
            inflater.close(); #expect(budget.usedBytes(category: .native) == 0)
        }
        var limits = WebSocketLimits(); limits.nativeBytes = 1
        let budget = WebSocketMemoryBudget(limits: limits)
        let scratch = try WebSocketDictionaryScratch(reservation: budget.reserve(category: .working, bytes: 32768)!)
        let limiter = WebSocketWorkLimiter(limits: limits, budget: budget, now: { 0 })
        #expect(throws: (any Error).self) {
            _ = try WebSocketInflater(parameters: .init(), budget: budget, limiter: limiter, sessionID: UUID(), dictionaryScratch: scratch)
        }
        #expect(budget.usedBytes(category: .native) == 0)
    }
    @Test func supportedWindowsHaveIndependentLiteralProof() throws {
        print("WS_RUNTIME zlib=\(String(cString: zlibVersion())) header=\(ZLIB_VERSION)")
        for window in 8...15 {
            let (inflater,budget,_,_) = try make(parameters: .init(windowBits: window))
            var decoded = Data()
            let progress = drain(inflater, WebSocketCompressionVectors.stored, final: true, decoded: &decoded)
            print("WS_WINDOW bits=\(window) nativeInit=\(inflater.nativeInitializationStatus) status=\(progress.status)")
            #expect(inflater.nativeInitializationStatus == Z_OK)
            #expect(progress.status == .messageComplete)
            #expect(decoded == Data("Hello".utf8))
            inflater.close(); #expect(budget.usedBytes(category: .native) == 0)
        }
        // Raw deflate -8 is a separate runtime capability, never labeled an 8-bit oracle.
        do {
            let fixture = try WebSocketDeflater(windowBits: 8)
            _ = try fixture.message(Data("Hello".utf8))
            print("WS_DEFLATER requestedBits=8 nativeStatus=0; no assertion about effective compressor window")
        } catch let error as WebSocketDeflater.Failure {
            #expect(error.status == Z_STREAM_ERROR)
            print("WS_DEFLATER requestedBits=8 nativeStatus=\(error.status)")
        }
        for window in [7,16,Int.max,Int.min] {
            let (inflater,budget,_,_) = try make(parameters: .init(windowBits: window))
            #expect(inflater.feed(Data(), final: true) { _ in }.status == .opaqueCompression)
            #expect(budget.usedBytes(category: .native) == 0)
            inflater.close()
        }
    }
    @Test func independentDeflaterLongHistoryAndDiscardPreserveContext() throws {
        for window in 9...15 {
            let fixture = try WebSocketDeflater(windowBits: window)
            let source = Data((0..<100000).map { UInt8(truncatingIfNeeded: $0 * 31 + $0 / 257) })
            let first = try fixture.message(source)
            let nextSource = Data(source.suffix(min(1 << window, 16000)))
            let next = try fixture.message(nextSource)
            let (inflater,budget,_,_) = try make(parameters: .init(windowBits: window))
            var offset = 0, expanded = 0, prefix = Data(), yields = 0
            while true {
                let progress = inflater.feed(Data(first.dropFirst(offset)), final: true) { chunk in
                    #expect(budget.usedBytes(category: .working) >= 32768 + chunk.count)
                    prefix.append(chunk.prefix(max(0, 17 - prefix.count)))
                }
                #expect(progress.consumed <= 32768); #expect(progress.produced <= 32768)
                #expect(progress.nativeOperations <= 64)
                offset += progress.consumed; expanded += progress.produced
                if progress.status != .yield { #expect(progress.status == .messageComplete); break }
                yields += 1; #expect(yields < 200)
                if yields >= 200 { break }
            }
            #expect(offset == first.count); #expect(expanded == source.count)
            #expect(prefix == source.prefix(17)); #expect(yields >= 3)
            var decoded = Data()
            #expect(drain(inflater, next, final: true, decoded: &decoded).status == .messageComplete)
            #expect(decoded == nextSource)
            let peak = inflater.nativeAccounting.peakBytes
            #expect(peak > 0); #expect(peak <= 16_777_216)
            inflater.close()
            let accounting = inflater.nativeAccounting
            #expect(accounting.liveBytes == 0); #expect(accounting.allocations == accounting.frees)
            #expect(budget.usedBytes(category: .native) == 0)
            print("WS_ALLOC window=\(window) peak=\(peak) allocations=\(accounting.allocations) frees=\(accounting.frees) live=\(accounting.liveBytes)")
        }
    }
    @Test func emptyBlocksConsumeNativeQuantumAndRate() throws {
        let (inflater,budget,_,_) = try make()
        let block = Data([0,0,0,255,255])
        var flood = Data()
        for _ in 0..<5000 { flood.append(block) }
        var cursor = 0, totalOps = 0, calls = 0
        while true {
            let progress = inflater.feed(Data(flood.dropFirst(cursor)), final: false) { _ in Issue.record("Empty blocks emitted data") }
            #expect(progress.nativeOperations <= 64); #expect(progress.produced == 0)
            cursor += progress.consumed; totalOps += progress.nativeOperations; calls += 1
            if calls == 1 { #expect(progress.status == .yield); #expect(progress.nativeOperations == 64); #expect(progress.consumed == 320) }
            if case .stopped = progress.status {
                #expect(progress.status == .stopped(.init(code: "inflateWorkLimit"))); break
            }
            #expect(calls < 100); if calls >= 100 { break }
        }
        #expect(totalOps == 4095) // The actual create call consumed the first native token.
        #expect(cursor == 4095 * 5)
        #expect(budget.usedBytes(category: .native) == 0)
        #expect(inflater.feed(block, final: false) { _ in }.status == .stopped(.init(code: "inflateWorkLimit")))
        print("WS_EMPTY_BLOCKS calls=\(calls) nativeOps=\(totalOps) cursor=\(cursor)")
    }
    @Test func twoDirectionsShareOneScratchWithoutHistorySharing() throws {
        var limits = WebSocketLimits(); limits.quantumNativeOperations = 4
        let budget = WebSocketMemoryBudget(limits: limits)
        let limiter = WebSocketWorkLimiter(limits: limits, budget: budget, now: { 0 })
        let id = UUID()
        var scratch: WebSocketDictionaryScratch? = try WebSocketDictionaryScratch(reservation: budget.reserve(category: .working, bytes: 32768)!)
        let a = try WebSocketInflater(parameters: .init(), budget: budget, limiter: limiter, sessionID: id, dictionaryScratch: scratch!)
        let b = try WebSocketInflater(parameters: .init(), budget: budget, limiter: limiter, sessionID: id, dictionaryScratch: scratch!)
        scratch = nil
        #expect(budget.usedBytes(category: .working) == 32768)
        var aOffset = 0, bOffset = 0, aDone = false, bDone = false
        var aDecoded = Data(), bDecoded = Data()
        for _ in 0..<20 {
            if !aDone {
                let progress = a.feed(Data(WebSocketCompressionVectors.bfinal.dropFirst(aOffset)), final: true) { aDecoded.append($0) }
                aOffset += progress.consumed; #expect(progress.nativeOperations <= 4)
                aDone = progress.status == .messageComplete
                #expect(progress.status == .yield || aDone)
            }
            if !bDone {
                let progress = b.feed(Data(WebSocketCompressionVectors.bfinal.dropFirst(bOffset)), final: true) { bDecoded.append($0) }
                bOffset += progress.consumed; #expect(progress.nativeOperations <= 4)
                bDone = progress.status == .messageComplete
                #expect(progress.status == .yield || bDone)
            }
            #expect(budget.usedBytes(category: .working) == 32768)
            if aDone && bDone { break }
        }
        #expect(aDone && bDone); #expect(aOffset == 8 && bOffset == 8)
        #expect(aDecoded == Data("Hello".utf8)); #expect(bDecoded == Data("Hello".utf8))
        #expect(budget.usedBytes(category: .native) == a.nativeAccounting.liveBytes + b.nativeAccounting.liveBytes)
        print("WS_SHARED scratchWorking=\(budget.usedBytes(category: .working)) nativeLive=\(budget.usedBytes(category: .native)) aPeak=\(a.nativeAccounting.peakBytes) bPeak=\(b.nativeAccounting.peakBytes)")
        a.close(); #expect(budget.usedBytes(category: .working) == 32768)
        #expect(budget.usedBytes(category: .metadata) == 512)
        bDecoded.removeAll()
        #expect(drain(b, WebSocketCompressionVectors.takeover, final: true, decoded: &bDecoded, operations: 4).status == .messageComplete)
        #expect(bDecoded == Data("Hello".utf8))
        b.close(); #expect(budget.usedBytes(category: .working) == 0)
        #expect(budget.usedBytes(category: .native) == 0)
        #expect(budget.usedBytes(category: .metadata) == 512)
        limiter.remove(session: id); #expect(budget.usedBytes(category: .metadata) == 0)
        // A fresh opposite direction cannot use a different direction's dictionary.
        let (fresh,_,_,_) = try make()
        var decoded = Data()
        #expect(drain(fresh, WebSocketCompressionVectors.takeover, final: true, decoded: &decoded).status == .stopped(.init(code: "inflateInvalidData")))
    }
    @Test func scratchFailureAndNativeAllocationFailuresReleaseExactlyOnce() throws {
        let budget = WebSocketMemoryBudget()
        #expect(throws: WebSocketDictionaryScratch.AllocationError.allocationFailed) {
            _ = try WebSocketDictionaryScratch(reservation: budget.reserve(category: .working, bytes: 32768)!, allocate: { nil })
        }
        #expect(budget.usedBytes(category: .working) == 0)
        #expect(throws: WebSocketDictionaryScratch.AllocationError.invalidReservation) {
            _ = try WebSocketDictionaryScratch(reservation: budget.reserve(category: .native, bytes: 32768)!, allocate: { nil })
        }
        #expect(budget.usedBytes(category: .native) == 0)
        for cap in [0,1,200,8000] {
            var limits = WebSocketLimits(); limits.nativeBytes = cap
            let budget = WebSocketMemoryBudget(limits: limits)
            let limiter = WebSocketWorkLimiter(limits: limits, budget: budget, now: { 0 })
            let scratch = try WebSocketDictionaryScratch(reservation: budget.reserve(category: .working, bytes: 32768)!)
            do {
                let inflater = try WebSocketInflater(parameters: .init(), budget: budget, limiter: limiter, sessionID: UUID(), dictionaryScratch: scratch)
                let result = inflater.feed(WebSocketCompressionVectors.sync, final: true) { _ in }
                #expect(result.status == .stopped(.init(code: "inflateNativeMemory")))
                #expect(inflater.nativeAccounting.refusals == 1)
                inflater.close(); inflater.close()
                #expect(inflater.nativeAccounting.allocations == inflater.nativeAccounting.frees)
                print("WS_FAIL cap=\(cap) allocations=\(inflater.nativeAccounting.allocations) frees=\(inflater.nativeAccounting.frees) refusals=\(inflater.nativeAccounting.refusals)")
            } catch { #expect(error is WebSocketInflater.InitializationError); print("WS_FAIL cap=\(cap) init=\(error)") }
            #expect(budget.usedBytes(category: .native) == 0)
            #expect(budget.usedBytes(category: .working) == 32768)
        }
    }
    @Test func expandedLimitStopsPermanentlyAtFourMiB() throws {
        let fixture = try WebSocketDeflater()
        let compressed = try fixture.message(Data(repeating: 65, count: 4_194_305))
        let (inflater,budget,_,_) = try make()
        var offset = 0, received = 0, calls = 0, expandedWork = 0
        while true {
            let progress = inflater.feed(Data(compressed.dropFirst(offset)), final: true) { received += $0.count }
            offset += progress.consumed; expandedWork += progress.produced; calls += 1
            #expect(progress.produced <= 32768); #expect(progress.nativeOperations <= 64)
            if case .stopped = progress.status { #expect(progress.status == .stopped(.init(code: "inflateExpandedLimit"))); break }
            #expect(progress.status == .yield); #expect(calls < 200)
            if calls >= 200 { break }
        }
        print("WS_EXPANDED work=\(expandedWork) emitted=\(received) calls=\(calls) cursor=\(offset)")
        #expect(expandedWork == 4_194_305) // Include the decoded over-limit byte even though it is not emitted.
        #expect(received == 4_194_304); #expect(budget.usedBytes(category: .native) == 0)
        #expect(inflater.feed(WebSocketCompressionVectors.sync, final: true) { _ in Issue.record("Must remain stopped") }.status == .stopped(.init(code: "inflateExpandedLimit")))
    }
    @Test func byteQuantumBoundsInputOutputAndTailAcrossEverySplit() throws {
        for quantum in [1,2,3,7] {
            var limits = WebSocketLimits(); limits.quantumBytes = quantum
            let (inflater,budget,_,_) = try make(limits)
            var decoded = Data()
            #expect(drain(inflater, WebSocketCompressionVectors.bfinal, final: true, decoded: &decoded, quantum: quantum).status == .messageComplete)
            #expect(decoded == Data("Hello".utf8))
            decoded.removeAll()
            #expect(drain(inflater, WebSocketCompressionVectors.takeover, final: true, decoded: &decoded, quantum: quantum).status == .messageComplete)
            #expect(decoded == Data("Hello".utf8))
            inflater.close(); #expect(budget.usedBytes(category: .native) == 0)
        }
        for nativeQuantum in [0,-1,1,2,3] {
            var limits = WebSocketLimits(); limits.quantumNativeOperations = nativeQuantum
            let (inflater,budget,_,_) = try make(limits)
            var decoded = Data()
            let progress = drain(inflater, WebSocketCompressionVectors.bfinal, final: true, decoded: &decoded, operations: max(0,nativeQuantum))
            if case .stopped = progress.status {} else { Issue.record("Nonprogressing recovery must stop") }
            #expect(budget.usedBytes(category: .native) == 0)
        }
    }

    @Test func noContextPreservesBfinalSubstreamHistoryUntilActualFinal() throws {
        let combined = WebSocketCompressionVectors.bfinal + Data([0,0,255,255]) + WebSocketCompressionVectors.takeover
        for split in 0...combined.count {
            let (inflater,budget,_,_) = try make(parameters: .init(noContextTakeover: true))
            var decoded = Data()
            #expect(drain(inflater, Data(combined.prefix(split)), final: false, decoded: &decoded).status == .needsInput)
            #expect(drain(inflater, Data(combined.dropFirst(split)), final: true, decoded: &decoded).status == .messageComplete)
            #expect(decoded == Data("HelloHello".utf8))
            inflater.close(); #expect(budget.usedBytes(category: .native) == 0)
        }
    }
    @Test func rawWindowEightWrapsHistoryUsingOnlyRFCOracles() throws {
        let (inflater,budget,_,_) = try make(parameters: .init(windowBits: 8))
        for index in 0..<100 {
            var decoded = Data()
            let bytes = index == 0 ? WebSocketCompressionVectors.sync : WebSocketCompressionVectors.takeover
            #expect(drain(inflater, bytes, final: true, decoded: &decoded).status == .messageComplete)
            #expect(decoded == Data("Hello".utf8))
        }
        print("WS_WINDOW8 historyBytes=500 peak=\(inflater.nativeAccounting.peakBytes) nativeInit=\(inflater.nativeInitializationStatus)")
        inflater.close(); #expect(budget.usedBytes(category: .native) == 0)
    }
    @Test func noProgressTruncatedBfinalAndWorkingFailureStopWithoutSpin() throws {
        let (empty,budget,_,_) = try make()
        let waiting = empty.feed(Data(), final: false) { _ in Issue.record("No output") }
        #expect(waiting.status == .needsInput); #expect(waiting.nativeOperations == 1)
        #expect(waiting.consumed == 0 && waiting.produced == 0)
        empty.close(); #expect(budget.usedBytes(category: .native) == 0)
        for malformed in [Data(), Data(WebSocketCompressionVectors.bfinal.dropLast())] {
            let (inflater,budget,_,_) = try make()
            let progress = inflater.feed(malformed, final: true) { _ in }
            #expect(progress.status == .stopped(.init(code: "inflateIncompleteFinal")))
            #expect(budget.usedBytes(category: .native) == 0)
            #expect(inflater.feed(WebSocketCompressionVectors.sync, final: true) { _ in Issue.record("Permanent stop") }.consumed == 0)
        }
        var limits = WebSocketLimits(); limits.workingBytes = 32768
        let (inflater,limited,_,_) = try make(limits)
        #expect(inflater.feed(WebSocketCompressionVectors.sync, final: true) { _ in }.status == .stopped(.init(code: "inflateWorkingMemory")))
        #expect(limited.usedBytes(category: .working) == 0); #expect(limited.usedBytes(category: .native) == 0)
    }
    @Test func closePreservesSharedRateHistoryAndRecoveryCannotWaitForRefill() throws {
        var limits = WebSocketLimits(); limits.sessionNativePerSecond = 2
        let budget = WebSocketMemoryBudget(limits: limits)
        let scratch = try WebSocketDictionaryScratch(reservation: budget.reserve(category: .working, bytes: 32768)!)
        let limiter = WebSocketWorkLimiter(limits: limits, budget: budget, now: { 0 })
        let id = UUID()
        let a = try WebSocketInflater(parameters: .init(), budget: budget, limiter: limiter, sessionID: id, dictionaryScratch: scratch)
        let b = try WebSocketInflater(parameters: .init(), budget: budget, limiter: limiter, sessionID: id, dictionaryScratch: scratch)
        a.close()
        #expect(b.feed(WebSocketCompressionVectors.sync, final: true) { _ in }.status == .stopped(.init(code: "inflateWorkLimit")))
        #expect(budget.usedBytes(category: .native) == 0)
        limits.sessionNativePerSecond = 5
        let (recovering,recoveryBudget,_,_) = try make(limits)
        let result = recovering.feed(WebSocketCompressionVectors.bfinal, final: true) { _ in }
        #expect(result.status == .stopped(.init(code: "inflateWorkLimit")))
        #expect(result.consumed == 7); #expect(result.produced == 5)
        #expect(result.nativeOperations == 2) // Z_BLOCK ends block first; next inflate reports STREAM_END.
        #expect(recoveryBudget.usedBytes(category: .native) == 0)
    }

    @Test func recoveryAllocationFailureAndInitRateRefusalReleaseNative() throws {
        var limits = WebSocketLimits(); limits.nativeBytes = 8000
        let (inflater,budget,_,_) = try make(limits)
        // DEFLATE BFINAL=1, BTYPE=fixed, literal end-of-block (03 00), followed
        // by a stored-block header (00). No output precedes dictionary restoration.
        let progress = inflater.feed(Data([3,0,0]), final: true) { _ in Issue.record("Empty stream") }
        #expect(progress.status == .stopped(.init(code: "inflateRecoveryFailed")))
        #expect(progress.nativeOperations == 6)
        #expect(inflater.nativeAccounting.refusals == 1)
        #expect(inflater.nativeAccounting.allocations == inflater.nativeAccounting.frees)
        #expect(budget.usedBytes(category: .native) == 0)
        print("WS_RECOVERY_FAIL ops=\(progress.nativeOperations) consumed=\(progress.consumed) allocations=\(inflater.nativeAccounting.allocations) frees=\(inflater.nativeAccounting.frees) refusals=\(inflater.nativeAccounting.refusals)")
        limits.sessionNativePerSecond = 0
        let noWork = WebSocketMemoryBudget(limits: limits)
        let scratch = try WebSocketDictionaryScratch(reservation: noWork.reserve(category: .working, bytes: 32768)!)
        let limiter = WebSocketWorkLimiter(limits: limits, budget: noWork, now: { 0 })
        #expect(throws: WebSocketInflater.InitializationError.workLimit) {
            _ = try WebSocketInflater(parameters: .init(), budget: noWork, limiter: limiter, sessionID: UUID(), dictionaryScratch: scratch)
        }
        #expect(noWork.usedBytes(category: .native) == 0)
        #expect(noWork.usedBytes(category: .working) == 32768)
    }
    @Test func callbackCloseAndReentryCannotUseFreedNativePointers() throws {
        let (closing,budget,_,_) = try make()
        let closed = closing.feed(WebSocketCompressionVectors.sync, final: true) { _ in closing.close() }
        #expect(closed.status == .stopped(.init(code: "inflateClosed")))
        #expect(budget.usedBytes(category: .native) == 0)
        let (reentering,other,_,_) = try make()
        var nested: WebSocketInflateProgress?
        let result = reentering.feed(WebSocketCompressionVectors.sync, final: true) { _ in
            nested = reentering.feed(Data(), final: false) { _ in Issue.record("Reentry output") }
        }
        #expect(result.status == .stopped(.init(code: "inflateReentered")))
        #expect(nested?.consumed == 0 && nested?.nativeOperations == 0)
        #expect(other.usedBytes(category: .native) == 0)
    }

}
