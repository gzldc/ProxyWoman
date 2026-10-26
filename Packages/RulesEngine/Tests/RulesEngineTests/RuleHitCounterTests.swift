import Foundation
import Testing

@testable import RulesEngine

@Suite("RuleHitCounter")
struct RuleHitCounterTests {
    @Test func recordHitCountsFromOne() {
        let counter = RuleHitCounter()
        let id = UUID()
        #expect(counter.count(id) == 0)
        #expect(counter.recordHit(id) == 1)
        #expect(counter.recordHit(id) == 2)
        #expect(counter.recordHit(id) == 3)
        #expect(counter.count(id) == 3)
        #expect(counter.snapshot() == [id: 3])
    }

    @Test func resetOnlyAffectsOneRule() {
        let counter = RuleHitCounter()
        let kept = UUID()
        let cleared = UUID()
        counter.recordHit(kept)
        counter.recordHit(kept)
        counter.recordHit(cleared)
        counter.reset(cleared)
        #expect(counter.count(cleared) == 0)
        #expect(counter.count(kept) == 2)
        #expect(counter.snapshot() == [kept: 2])
        // Counting starts again from one after a reset.
        #expect(counter.recordHit(cleared) == 1)
        counter.reset(UUID())
        #expect(counter.snapshot() == [kept: 2, cleared: 1])
    }

    @Test func resetAllClears() {
        let counter = RuleHitCounter()
        let ids = (0..<4).map { _ in UUID() }
        for id in ids { counter.recordHit(id) }
        counter.resetAll()
        #expect(counter.snapshot().isEmpty)
        for id in ids { #expect(counter.count(id) == 0) }
        #expect(counter.recordHit(ids[0]) == 1)
    }

    @Test func concurrentRecordsAreNotLost() async {
        let counter = RuleHitCounter()
        let id = UUID()
        let returned = await withTaskGroup(of: [Int].self) { group in
            for _ in 0..<8 {
                group.addTask {
                    var seen: [Int] = []
                    seen.reserveCapacity(1000)
                    for _ in 0..<1000 { seen.append(counter.recordHit(id)) }
                    return seen
                }
            }
            var all: [Int] = []
            for await seen in group { all += seen }
            return all
        }
        #expect(counter.count(id) == 8000)
        // Every hit got its own number: 1 through 8000, each exactly once.
        #expect(returned.sorted() == Array(1...8000))
    }
}
