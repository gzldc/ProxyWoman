import Testing

@testable import AppCore

@Suite(.productionChinese) struct ThroughputMeterTests {
    @Test func firstSampleHasNoRate() {
        var meter = ThroughputMeter()
        #expect(meter.sample(up: 1000, down: 5000, at: 10) == .zero)
    }

    @Test func rateIsTheDeltaPerSecond() {
        var meter = ThroughputMeter()
        _ = meter.sample(up: 1000, down: 5000, at: 10)
        #expect(meter.sample(up: 3000, down: 5000, at: 12) == ThroughputMeter.Rate(up: 1000, down: 0))
        #expect(meter.sample(up: 3000, down: 6024, at: 12.5) == ThroughputMeter.Rate(up: 0, down: 2048))
    }

    @Test func nonAdvancingClockOrShrinkingTotalsGiveZero() {
        var meter = ThroughputMeter()
        _ = meter.sample(up: 1000, down: 5000, at: 10)
        #expect(meter.sample(up: 2000, down: 6000, at: 10) == .zero)
        // A new server starts counting from zero again.
        #expect(meter.sample(up: 10, down: 20, at: 11) == .zero)
        #expect(meter.sample(up: 110, down: 20, at: 12) == ThroughputMeter.Rate(up: 100, down: 0))
    }
}
