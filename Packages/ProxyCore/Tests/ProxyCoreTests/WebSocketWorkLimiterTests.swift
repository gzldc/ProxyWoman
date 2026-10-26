import Foundation
import Testing
import FlowStore
import os
@testable import ProxyCore

@Suite(.productionChinese) struct WebSocketWorkLimiterTests {
    @Test func independentBurstsRefillAndMetadataLifetime() {
        var limits = WebSocketLimits()
        limits.observingSessions = 2; limits.sessionFramesPerSecond = 2
        limits.sessionNativePerSecond = 4; limits.storeNativePerSecond = 6
        limits.sessionExpandedPerSecond = 10; limits.storeExpandedPerSecond = 15
        let clock = OSAllocatedUnfairLock(initialState: UInt64(0))
        let budget = WebSocketMemoryBudget(limits: limits)
        let limiter = WebSocketWorkLimiter(limits: limits, budget: budget, now: { clock.withLock { $0 } })
        let a = UUID(), b = UUID()
        #expect(limiter.admit(session: a, frames: 2, expandedBytes: 10, nativeOperations: 4) == .allowed)
        #expect(limiter.admit(session: a, frames: 1, expandedBytes: 0, nativeOperations: 0) == .stopSession)
        #expect(limiter.admit(session: b, frames: 0, expandedBytes: 5, nativeOperations: 2) == .allowed)
        #expect(limiter.admit(session: b, frames: 0, expandedBytes: 1, nativeOperations: 0) == .stopDirection)
        #expect(limiter.admit(session: UUID(), frames: 0, expandedBytes: 0, nativeOperations: 0) == .stopSession)
        #expect(budget.usedBytes(category: .metadata) == 1024)
        clock.withLock { $0 = 1_000_000_000 }
        #expect(limiter.admit(session: a, frames: 2, expandedBytes: 10, nativeOperations: 4) == .allowed)
        limiter.remove(session: a); limiter.remove(session: b)
        #expect(budget.usedBytes(category: .metadata) == 0)
    }
    @Test func concurrentFirstAdmissionChargesOnceAndRefusalReleases() async {
        let budget = WebSocketMemoryBudget()
        let limiter = WebSocketWorkLimiter(limits: .init(), budget: budget, now: { 0 })
        let id = UUID()
        await withTaskGroup(of: WebSocketWorkDecision.self) { group in
            for _ in 0..<128 { group.addTask { limiter.admit(session: id, frames: 0, expandedBytes: 0, nativeOperations: 1) } }
            for await result in group { #expect(result == .allowed) }
        }
        #expect(budget.usedBytes(category: .metadata) == 512)
        limiter.remove(session: id); limiter.remove(session: id)
        #expect(budget.usedBytes(category: .metadata) == 0)
        var limits = WebSocketLimits(); limits.metadataBytes = 511
        let small = WebSocketMemoryBudget(limits: limits)
        let refused = WebSocketWorkLimiter(limits: limits, budget: small, now: { 0 })
        #expect(refused.admit(session: id, frames: 0, expandedBytes: 0, nativeOperations: 0) == .stopSession)
        #expect(small.usedBytes(category: .metadata) == 0)
    }
    @Test func exactDefaultRatesAndStoreBursts() {
        let budget = WebSocketMemoryBudget()
        let limiter = WebSocketWorkLimiter(limits: .init(), budget: budget, now: { 0 })
        var ids = [UUID]()
        for _ in 0..<4 {
            let id = UUID(); ids.append(id)
            #expect(limiter.admit(session: id, frames: 4096, expandedBytes: 16_777_216, nativeOperations: 4096) == .allowed)
            #expect(limiter.admit(session: id, frames: 1, expandedBytes: 0, nativeOperations: 0) == .stopSession)
            #expect(limiter.admit(session: id, frames: 0, expandedBytes: 1, nativeOperations: 0) == .stopDirection)
            #expect(limiter.admit(session: id, frames: 0, expandedBytes: 0, nativeOperations: 1) == .stopDirection)
        }
        let extra = UUID(); ids.append(extra)
        #expect(limiter.admit(session: extra, frames: 0, expandedBytes: 1, nativeOperations: 0) == .stopDirection)
        #expect(limiter.admit(session: extra, frames: 0, expandedBytes: 0, nativeOperations: 1) == .stopDirection)
        for id in ids { limiter.remove(session: id) }
        #expect(budget.usedBytes(category: .metadata) == 0)
    }
    @Test func fractionalRefillBackwardTimeAndHugeLimitsDoNotOverflow() {
        var limits = WebSocketLimits(); limits.sessionNativePerSecond = 3
        let clock = OSAllocatedUnfairLock(initialState: UInt64(0))
        let budget = WebSocketMemoryBudget(limits: limits)
        let limiter = WebSocketWorkLimiter(limits: limits, budget: budget, now: { clock.withLock { $0 } })
        let id = UUID()
        #expect(limiter.admit(session: id, frames: 0, expandedBytes: 0, nativeOperations: 3) == .allowed)
        for step in 1...3 {
            clock.withLock { $0 = UInt64(step) * 100_000_000 }
            #expect(limiter.admit(session: id, frames: 0, expandedBytes: 0, nativeOperations: 1) == .stopDirection)
        }
        clock.withLock { $0 = 400_000_000 }
        #expect(limiter.admit(session: id, frames: 0, expandedBytes: 0, nativeOperations: 1) == .allowed)
        clock.withLock { $0 = 1 }
        #expect(limiter.admit(session: id, frames: 0, expandedBytes: 0, nativeOperations: 1) == .stopDirection)
        clock.withLock { $0 = UInt64.max }
        #expect(limiter.admit(session: id, frames: 0, expandedBytes: 0, nativeOperations: 3) == .allowed)
        limits.sessionNativePerSecond = Int.max; limits.storeNativePerSecond = Int.max
        clock.withLock { $0 = 0 }
        let huge = WebSocketWorkLimiter(limits: limits, budget: budget, now: { clock.withLock { $0 } })
        #expect(huge.admit(session: id, frames: 0, expandedBytes: 0, nativeOperations: Int.max) == .allowed)
        clock.withLock { $0 = 999_999_999 }
        #expect(huge.admit(session: id, frames: 0, expandedBytes: 0, nativeOperations: 1) == .allowed)
        #expect(huge.admit(session: id, frames: -1, expandedBytes: 0, nativeOperations: 0) == .stopSession)
    }
    @Test func concurrentDistinctKeysHaveBoundedMetadataAndNoExpiredHistory() async {
        var limits = WebSocketLimits(); limits.observingSessions = 8
        let budget = WebSocketMemoryBudget(limits: limits)
        let limiter = WebSocketWorkLimiter(limits: limits, budget: budget, now: { 0 })
        let ids = (0..<128).map { _ in UUID() }
        var allowed = 0
        await withTaskGroup(of: WebSocketWorkDecision.self) { group in
            for id in ids { group.addTask { limiter.admit(session: id, frames: 0, expandedBytes: 0, nativeOperations: 0) } }
            for await result in group { if result == .allowed { allowed += 1 } else { #expect(result == .stopSession) } }
        }
        #expect(allowed == 8); #expect(budget.usedBytes(category: .metadata) == 4096)
        for id in ids { limiter.remove(session: id) }
        #expect(budget.usedBytes(category: .metadata) == 0)
        for _ in 0..<200 {
            let id = UUID()
            #expect(limiter.admit(session: id, frames: 0, expandedBytes: 0, nativeOperations: 0) == .allowed)
            limiter.remove(session: id)
        }
        #expect(budget.usedBytes(category: .metadata) == 0)
    }

}
