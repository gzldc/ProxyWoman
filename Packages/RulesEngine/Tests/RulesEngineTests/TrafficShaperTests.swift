import Foundation
import Testing

@testable import RulesEngine

private func shaper(bps: Int? = nil, latency: Duration = .zero, loss: Double = 0) -> TrafficShaper {
    TrafficShaper(.init(bytesPerSecond: bps, latency: latency, lossPercent: loss))
}

@Test func unlimitedZeroLatencyIsImmediate() {
    var value = shaper()
    #expect(value.delay(forChunkOf: 10_000, at: .seconds(5), lossDraw: 0.99) == .zero)
}

@Test func bandwidthSerializesChunks() {
    var value = shaper(bps: 100_000)
    #expect(value.delay(forChunkOf: 10_000, at: .zero, lossDraw: 0) == .milliseconds(100))
    #expect(value.delay(forChunkOf: 10_000, at: .zero, lossDraw: 0) == .milliseconds(200))
}

@Test func idleGapResetsTheClock() {
    var value = shaper(bps: 100_000)
    #expect(value.delay(forChunkOf: 10_000, at: .zero, lossDraw: 0) == .milliseconds(100))
    #expect(value.delay(forChunkOf: 10_000, at: .seconds(1), lossDraw: 0) == .milliseconds(100))
}

@Test func latencyAddsToEveryChunk() {
    var value = shaper(latency: .milliseconds(50))
    #expect(value.delay(forChunkOf: 10_000, at: .zero, lossDraw: 0) == .milliseconds(50))
    #expect(value.delay(forChunkOf: 10_000, at: .zero, lossDraw: 0) == .milliseconds(50))
}

@Test func lossDrawBelowProbabilityAddsRetransmitPenalty() {
    var lost = shaper(loss: 50)
    #expect(lost.delay(forChunkOf: 1448, at: .zero, lossDraw: 0.4) == .milliseconds(200))
    var kept = shaper(loss: 50)
    #expect(kept.delay(forChunkOf: 1448, at: .zero, lossDraw: 0.6) == .zero)
}

@Test func penaltyScalesWithLatencyAndCapsAtThreeSeconds() {
    var small = shaper(latency: .milliseconds(100), loss: 50)
    #expect(small.delay(forChunkOf: 1448, at: .zero, lossDraw: 0) == .milliseconds(500))
    var large = shaper(latency: .seconds(2), loss: 50)
    #expect(large.delay(forChunkOf: 1448, at: .zero, lossDraw: 0) == .seconds(5))
}

@Test func lostChunkBlocksFollowingChunks() {
    var value = shaper(loss: 50)
    #expect(value.delay(forChunkOf: 1448, at: .zero, lossDraw: 0) == .milliseconds(200))
    #expect(value.delay(forChunkOf: 100, at: .zero, lossDraw: 0.9) == .milliseconds(200))
}

@Test func reconfigureNeverMovesDeliveryBackwards() {
    var value = shaper(latency: .seconds(1))
    #expect(value.delay(forChunkOf: 100, at: .zero, lossDraw: 0) == .seconds(1))
    let faster = TrafficShaper.Config(bytesPerSecond: nil, latency: .zero, lossPercent: 0)
    value.reconfigure(faster)
    #expect(value.config == faster)
    #expect(value.delay(forChunkOf: 100, at: .zero, lossDraw: 0) == .seconds(1))
}
