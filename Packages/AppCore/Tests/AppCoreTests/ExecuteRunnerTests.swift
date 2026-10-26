import FlowStore
import Foundation
import Testing
import os

@testable import AppCore
@testable import RulesEngine

/// Called after every flow the runner handles; a test plugs in what should happen between two flows.
private final class Hook: Sendable {
    typealias Handler = @Sendable @MainActor (Int, ExecuteRunner) async -> Void
    private let runner = OSAllocatedUnfairLock<ExecuteRunner?>(initialState: nil)
    private let handler = OSAllocatedUnfairLock<Handler?>(initialState: nil)
    private let seen = OSAllocatedUnfairLock<[Int]>(initialState: [])
    var ids: [Int] { seen.withLock { $0 } }
    func attach(_ value: ExecuteRunner) { runner.withLock { $0 = value } }
    func on(_ value: @escaping Handler) { handler.withLock { $0 = value } }
    func call(_ id: Int) async {
        seen.withLock { $0.append(id) }
        let handler = handler.withLock { $0 }
        let runner = runner.withLock { $0 }
        if let handler, let runner { await handler(id, runner) }
    }
}

private final class Rules: Sendable {
    private let value: OSAllocatedUnfairLock<RuleSnapshot>
    init(_ snapshot: RuleSnapshot) { value = OSAllocatedUnfairLock(initialState: snapshot) }
    func get() -> RuleSnapshot { value.withLock { $0 } }
    func set(_ snapshot: RuleSnapshot) { value.withLock { $0 = snapshot } }
}

private func snapshot(_ rules: [Rule], groups: [RuleGroup] = []) -> RuleSnapshot {
    var ordered = rules
    for index in ordered.indices { ordered[index].order = index }
    return RuleSnapshot(revision: 1, groups: groups, rules: ordered)
}

private func rule(_ name: String, host: String? = nil, _ actions: ActionKind...) -> Rule {
    let rows = host.map { [ConditionRow(field: .host, name: nil, op: .equals, value: $0)] } ?? []
    return Rule(name: name, conditions: ConditionGroup(mode: .all, rows: rows), actions: actions.map { RuleAction($0) })
}

private func comment(_ text: String) -> ActionKind { .comment(CommentAction(mode: .append, text: text)) }

@MainActor private struct Harness {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pw-runner-\(UUID().uuidString)")
    let store: FlowStore
    let rules: Rules
    let hook = Hook()
    let runner: ExecuteRunner
    let ids: [Int]
    /// Every body the engine asked the store to make.
    let made = OSAllocatedUnfairLock<[BodyRef]>(initialState: [])

    init(
        _ snapshot: RuleSnapshot, flows: Int = 3, batch: Int = 64, provider: RuleSnapshotProvider? = nil,
        responseBody: String? = nil
    ) {
        let directory = directory
        let store = FlowStore(bodyDirectory: directory.appendingPathComponent("bodies"))
        self.store = store
        let rules = Rules(snapshot)
        self.rules = rules
        var ids: [Int] = []
        for _ in 0..<flows {
            ids.append(store.begin { id in
                var flow = Flow(id: id, startedAt: .now, scheme: "https", method: "GET", host: "a.test", port: 443, path: "/p\(id)")
                flow.state = .completed
                flow.statusCode = 200
                flow.completedAt = .now
                if let responseBody {
                    let data = Data(responseBody.utf8)
                    flow.responseBody = .memory(data)
                    let target = HTTPMessageTarget(
                        scheme: "https", host: "a.test", port: 443, method: "GET", pathAndQuery: "/p\(id)")
                    flow.messages[.downstreamRequest] = HTTPMessageSnapshot(
                        boundary: .downstreamRequest, head: .request(target, headers: []), body: nil,
                        bodyState: .complete, observedBytes: 0, transferState: .finished)
                    flow.messages[.upstreamResponse] = HTTPMessageSnapshot(
                        boundary: .upstreamResponse, head: .response(
                            status: 200, reason: nil, headers: [HeaderField(name: "Content-Type", value: "text/plain")]),
                        body: HTTPBodySlice(ref: .memory(data), offset: 0, count: data.count),
                        bodyState: .complete, observedBytes: UInt64(data.count), transferState: .finished)
                }
                return flow
            })
        }
        self.ids = ids
        let limits = RulesLimits()
        let assets = ManagedAssetStore(
            directory: directory.appendingPathComponent("assets"), limits: limits,
            budgets: OwnedFileBudgets(limits: limits))
        let hook = hook
        let made = made
        runner = ExecuteRunner(
            store: store, snapshot: { provider?.current() ?? rules.get() },
            environment: {
                ExecuteEnvironment(
                    assets: assets, limits: limits, cache: PatternCache(), timeZone: TimeZone(identifier: "UTC")!,
                    makeBody: {
                        let body = store.makeManagedBody($0)
                        made.withLock { $0.append(body) }
                        return body
                    })
            },
            batchSize: batch, afterFlow: { await hook.call($0) })
        hook.attach(runner)
    }

    func prepare(_ scope: ExecuteRuleScope = .allEnabled, selected: [Int]? = nil, filtered: [Int]? = nil) {
        runner.prepare(ExecuteRequest(rules: scope, selectedIDs: selected ?? ids, filteredIDs: filtered ?? ids))
    }

    func summary() -> ExecuteSummary? {
        if case .finished(let summary) = runner.phase { return summary }
        return nil
    }

    func comments() -> [String?] { ids.map { store.flow($0)?.comment } }
}

@MainActor @Suite(.productionChinese) struct ExecuteRunnerTests {
    @Test func runsEveryFlowOfTheSelectedScope() async {
        let harness = Harness(snapshot([rule("c", comment("x"))]))
        harness.prepare()
        #expect(harness.runner.flowScope == .selected && harness.runner.canStart)
        await harness.runner.run()
        #expect(harness.comments() == ["x", "x", "x"])
        #expect(harness.summary()?.considered == 3 && harness.summary()?.matchedFlows == 3)
        #expect(harness.summary()?.annotatedFlows == 3)
    }

    @Test func selectedScopeRunsOnlyTheClickedFlow() async {
        let harness = Harness(snapshot([rule("c", comment("x"))]))
        harness.prepare(selected: [harness.ids[1]])
        await harness.runner.run()
        #expect(harness.comments() == [nil, "x", nil])
        #expect(harness.summary()?.considered == 1)
    }

    @Test func defaultScopeIsFilteredWhenNothingIsSelected() {
        let harness = Harness(snapshot([rule("c", comment("x"))]))
        harness.prepare(selected: [], filtered: [harness.ids[0], harness.ids[2]])
        #expect(harness.runner.flowScope == .filtered)
        #expect(harness.runner.flowCount(for: .filtered) == 2 && harness.runner.flowCount(for: .all) == 3)
        #expect(harness.runner.flowCount(for: .all) == harness.store.visibleFlowIDs().count)
    }

    @Test func runNowStartsWithScopeAndRequest() async {
        let harness = Harness(snapshot([rule("c", comment("x"))]))
        let request = ExecuteRequest(rules: .allEnabled, selectedIDs: [harness.ids[0]], filteredIDs: harness.ids)
        let task = harness.runner.runNow(request, scope: .filtered)
        #expect(task != nil)
        #expect(harness.runner.flowScope == .filtered && harness.runner.request == request)
        await task?.value
        #expect(harness.summary()?.considered == 3)
        #expect(harness.comments() == ["x", "x", "x"])
    }

    @Test func runNowWithNoFlowsDoesNothing() {
        let harness = Harness(snapshot([rule("c", comment("x"))]))
        let task = harness.runner.runNow(ExecuteRequest(rules: .allEnabled), scope: .filtered)
        #expect(task == nil)
        #expect(harness.runner.phase == .idle)
    }

    @Test func refusedRunNowKeepsThePreviousResult() async {
        let harness = Harness(snapshot([rule("c", comment("x"))]))
        harness.prepare()
        await harness.runner.run()
        let before = harness.runner.phase
        #expect(harness.runner.runNow(ExecuteRequest(rules: .allEnabled), scope: .filtered) == nil)
        #expect(harness.runner.phase == before && harness.summary() != nil)
        #expect(harness.runner.canUndoLastRun)
    }

    @Test func runNowWhileRunningReturnsNilAndKeepsPhase() async {
        let harness = Harness(snapshot([rule("c", comment("x"))]), flows: 2)
        harness.prepare()
        let started = harness.runner.start()
        let phase = harness.runner.phase
        let request = harness.runner.request
        #expect(harness.runner.runNow(ExecuteRequest(rules: .allEnabled, selectedIDs: [1], filteredIDs: [1]), scope: .selected) == nil)
        #expect(harness.runner.phase == phase && harness.runner.request == request)
        await started?.value
    }

    @Test func runNowSelectedScopeRunsOnlyThoseFlows() async {
        let harness = Harness(snapshot([rule("c", comment("x"))]))
        let task = harness.runner.runNow(
            ExecuteRequest(rules: .allEnabled, selectedIDs: [harness.ids[1]], filteredIDs: harness.ids), scope: .selected)
        await task?.value
        #expect(harness.comments() == [nil, "x", nil])
    }

    @Test func cancelWhileRunNowRunningEndsAsCancelled() async {
        let harness = Harness(snapshot([rule("c", comment("x"))]), flows: 4)
        harness.hook.on { id, runner in if id == 1 { runner.cancel() } }
        let task = harness.runner.runNow(
            ExecuteRequest(rules: .allEnabled, selectedIDs: [], filteredIDs: harness.ids), scope: .filtered)
        await task?.value
        #expect(harness.summary()?.wasCancelled == true)
        let banner = ExecuteRunBanner.of(phase: harness.runner.phase, canUndo: harness.runner.canUndoLastRun, dismissedRunID: nil)
        if case .cancelled = banner?.state {} else { Issue.record("expected cancelled banner") }
    }

    @Test func allScopeSkipsHiddenFlows() async {
        let harness = Harness(snapshot([rule("c", comment("x"))]))
        harness.store.update(harness.ids[1]) { $0.isHidden = true }
        harness.prepare()
        harness.runner.flowScope = .all
        await harness.runner.run()
        #expect(harness.comments() == ["x", nil, "x"])
        #expect(harness.summary()?.considered == 2)
    }

    @Test func hiddenFlowsPickedByTheSelectionAreSkippedAndCounted() async {
        let harness = Harness(snapshot([rule("c", comment("x"))]))
        harness.store.update(harness.ids[1]) { $0.isHidden = true }
        harness.prepare()
        await harness.runner.run()
        #expect(harness.summary()?.skippedHidden == 1 && harness.comments() == ["x", nil, "x"])
    }

    @Test func inProgressFlowsAreSkippedAndCounted() async {
        let harness = Harness(snapshot([rule("c", comment("x"))]))
        harness.store.update(harness.ids[0]) { $0.state = .inProgress }
        harness.prepare()
        await harness.runner.run()
        #expect(harness.summary()?.skippedInProgress == 1)
        #expect(harness.comments() == [nil, "x", "x"])
    }

    @Test func ignoresTheGlobalRulesSwitch() async {
        let provider = RuleSnapshotProvider(snapshot([rule("c", comment("x"))]))
        provider.setEnabled(false)
        let harness = Harness(snapshot([]), provider: provider)
        harness.prepare()
        #expect(harness.runner.ruleCount == 1)
        await harness.runner.run()
        #expect(harness.comments() == ["x", "x", "x"])
        #expect(provider.isEnabled == false)
    }

    @Test func neverCountsHits() async {
        let ruleToRun = rule("c", comment("x"))
        let provider = RuleSnapshotProvider(snapshot([ruleToRun]))
        let harness = Harness(snapshot([]), provider: provider)
        harness.prepare()
        await harness.runner.run()
        #expect(provider.hits.snapshot().values.allSatisfy { $0 == 0 })
        #expect(provider.hits.count(ruleToRun.id) == 0)
        for id in harness.ids {
            let provenance = harness.store.flow(id)?.provenance
            #expect(provenance?.ruleMatches == nil && provenance?.rulesModified == false)
        }
    }

    @Test func allEnabledSkipsDisabledRules() async {
        var off = rule("off", comment("off"))
        off.enabled = false
        let harness = Harness(snapshot([rule("on", comment("on")), off]))
        harness.prepare(.allEnabled)
        #expect(harness.runner.ruleCount == 1)
        await harness.runner.run()
        #expect(harness.comments() == ["on", "on", "on"])
    }

    @Test func selectedRulesRunWhenDisabled() async {
        var off = rule("off", comment("off"))
        off.enabled = false
        var inGroup = rule("grouped", comment("g"))
        let group = RuleGroup(name: "G", enabled: false)
        inGroup.groupID = group.id
        let harness = Harness(snapshot([off, inGroup], groups: [group]))
        harness.prepare(.items([off.id]))
        await harness.runner.run()
        #expect(harness.comments() == ["off", "off", "off"])
        harness.prepare(.items([group.id]))
        #expect(harness.runner.ruleCount == 1)
        await harness.runner.run()
        #expect(harness.comments() == ["g", "g", "g"])
    }

    @Test func summaryListsEveryRuleWithItsFlowCount() async {
        let first = rule("a", comment("a"))
        let second = rule("b", host: "nowhere.test", comment("b"))
        let third = rule("c", host: "a.test", comment("c"))
        let harness = Harness(snapshot([first, second, third]))
        harness.prepare()
        await harness.runner.run()
        let lines = harness.summary()?.rules
        #expect(lines?.map(\.ruleID) == [first.id, second.id, third.id])
        #expect(lines?.map(\.flows) == [3, 0, 3])
    }

    @Test func summaryCountsModifiedHiddenAnnotatedAndNotApplicable() async {
        let edit = rule(
            "edit", ActionKind.editHeaders(direction: .request, operations: [.set(name: "X-Run", value: "1")]))
        let mark = rule("mark", ActionKind.mark(MarkAction(background: "#FF3B30")))
        let hide = rule("hide", host: "a.test", ActionKind.hide)
        let delay = rule("delay", ActionKind.delay(milliseconds: 5))
        let harness = Harness(snapshot([edit, mark, delay, hide]), flows: 2)
        harness.prepare()
        await harness.runner.run()
        let summary = harness.summary()
        #expect(summary?.modifiedFlows == 2 && summary?.annotatedFlows == 2 && summary?.hiddenFlows == 2)
        #expect(summary?.notApplicableActions == 2 && summary?.matchedFlows == 2)
        #expect(harness.store.flow(harness.ids[0])?.executeOverlay != nil)
        #expect(harness.store.flow(harness.ids[0])?.isHidden == true)
    }

    @Test func cancelStopsAtTheNextFlowAndKeepsWrittenOnes() async {
        let harness = Harness(snapshot([rule("c", comment("x"))]), flows: 4)
        harness.hook.on { id, runner in
            if id == 2 { runner.cancel() }
        }
        harness.prepare()
        await harness.runner.run()
        #expect(harness.hook.ids == [1, 2])
        #expect(harness.summary()?.wasCancelled == true && harness.summary()?.considered == 2)
        #expect(harness.comments() == ["x", "x", nil, nil])
        #expect(harness.runner.canUndoLastRun)
        #expect(harness.runner.undoLastRun() == 2)
        #expect(harness.comments() == [nil, nil, nil, nil])
    }

    @Test func undoLastRunRestoresEverythingTheRunWrote() async {
        let hide = rule("hide", ActionKind.hide)
        let harness = Harness(snapshot([rule("c", comment("x")), hide]))
        harness.store.update(harness.ids[0]) { $0.comment = "mine" }
        harness.prepare()
        await harness.runner.run()
        #expect(harness.store.visibleFlowIDs().isEmpty)
        #expect(harness.runner.undoLastRun() == 3)
        #expect(harness.comments() == ["mine", nil, nil])
        #expect(harness.store.visibleFlowIDs() == harness.ids)
        #expect(harness.ids.allSatisfy { harness.store.flow($0)?.execute == nil })
        #expect(!harness.runner.canUndoLastRun)
    }

    @Test func undoLastRunKeepsUserEditsMadeAfterwards() async {
        let harness = Harness(snapshot([rule("c", comment("x"))]), flows: 2)
        harness.prepare()
        await harness.runner.run()
        harness.store.update(harness.ids[0]) { $0.comment = "edited" }
        #expect(harness.runner.undoLastRun() == 2)
        #expect(harness.comments() == ["edited", nil])
    }

    @Test func secondRunReplacesTheFirstRunsResultsAndLastRun() async {
        let first = rule("first", comment("one"))
        let harness = Harness(snapshot([first]), flows: 2)
        harness.prepare()
        await harness.runner.run()
        let firstRun = harness.runner.lastRun?.runID
        harness.rules.set(snapshot([rule("second", comment("two"))]))
        harness.prepare()
        await harness.runner.run()
        #expect(harness.comments() == ["two", "two"])
        #expect(harness.runner.lastRun?.runID != nil && harness.runner.lastRun?.runID != firstRun)
        #expect(harness.runner.lastRun?.flowIDs == harness.ids)
        // A rule that no longer matches puts the baseline back; a run that wrote nothing has nothing to undo.
        harness.rules.set(snapshot([rule("none", host: "nowhere.test", comment("three"))]))
        harness.prepare()
        await harness.runner.run()
        #expect(harness.comments() == [nil, nil])
        #expect(harness.runner.lastRun == nil)
        #expect(!harness.runner.canUndoLastRun)
    }

    @Test func onlyOneRunAtATime() async {
        let harness = Harness(snapshot([rule("c", comment("x"))]), flows: 2)
        harness.prepare()
        let started = harness.runner.start()
        #expect(started != nil)
        #expect(harness.runner.phase == .running(done: 0, total: 2))
        #expect(harness.runner.start() == nil)
        #expect(!harness.runner.canStart)
        await started?.value
        #expect(harness.hook.ids == [1, 2])
        #expect(harness.summary()?.considered == 2)
    }

    @Test func rulesEditedDuringARunDoNotChangeIt() async {
        let harness = Harness(snapshot([rule("old", comment("old"))]))
        harness.hook.on { id, _ in
            if id == 1 { harness.rules.set(snapshot([rule("new", comment("new"))])) }
        }
        harness.prepare()
        await harness.runner.run()
        #expect(harness.comments() == ["old", "old", "old"])
    }

    @Test func rulesEditedAfterStartDoNotChangeIt() async {
        let harness = Harness(snapshot([rule("old", comment("old"))]), flows: 2)
        harness.prepare()
        let task = harness.runner.start()
        harness.rules.set(snapshot([rule("new", comment("new"))]))
        await task?.value
        #expect(harness.comments() == ["old", "old"])
    }

    @Test func flowsClearedDuringTheRunAreCountedAsVanished() async {
        let harness = Harness(snapshot([rule("c", comment("x"))]), flows: 3)
        let store = harness.store
        harness.hook.on { id, _ in
            if id == 1 { store.clear() }
        }
        harness.prepare()
        await harness.runner.run()
        #expect(harness.summary()?.vanished == 2 && harness.summary()?.considered == 1)
    }

    @Test func aFlowClearedBetweenReadAndWriteIsVanishedAndItsNewBodiesAreReleased() async {
        let rewrite = rule(
            "rewrite", ActionKind.rewriteBody(direction: .response, BodyRewriteAction(find: "hello", replacement: "bye")))
        let kept = Harness(snapshot([rewrite]), flows: 1, responseBody: "hello")
        kept.prepare()
        await kept.runner.run()
        let keptBodies = kept.made.withLock { $0 }
        #expect(keptBodies.count == 1 && kept.summary()?.modifiedFlows == 1)
        #expect((try? kept.store.acquireBody(keptBodies[0])) != nil)

        let harness = Harness(snapshot([rewrite]), flows: 1, responseBody: "hello")
        let store = harness.store
        harness.runner.beforeWrite = { _ in store.clear() }
        harness.prepare()
        await harness.runner.run()
        let bodies = harness.made.withLock { $0 }
        #expect(bodies.count == 1)
        #expect(harness.summary()?.vanished == 1 && harness.summary()?.modifiedFlows == 0)
        #expect((try? store.acquireBody(bodies[0])) == nil)
        #expect(!harness.runner.canUndoLastRun)
    }

    @Test func canUndoLastRunIsFalseOnceNoFlowCarriesTheRunsRecord() async {
        let harness = Harness(snapshot([rule("c", comment("x"))]), flows: 2)
        harness.prepare()
        await harness.runner.run()
        #expect(harness.runner.canUndoLastRun)
        #expect(harness.runner.undoFlow(harness.ids[0]))
        #expect(harness.runner.canUndoLastRun)
        harness.store.clear()
        #expect(!harness.runner.canUndoLastRun)
        #expect(harness.runner.undoLastRun() == 0)
    }

    @Test func emptyRuleSetCannotStart() async {
        let harness = Harness(snapshot([]))
        harness.prepare()
        #expect(harness.runner.ruleCount == 0 && !harness.runner.canStart)
        #expect(harness.runner.start() == nil)
        await harness.runner.run()
        #expect(harness.runner.phase == .idle)
    }

    @Test func emptyScopeCannotStart() {
        let harness = Harness(snapshot([rule("c", comment("x"))]))
        harness.prepare(selected: [], filtered: [])
        #expect(!harness.runner.canStart)
    }

    @Test func progressReportsDoneAndTotal() async {
        let harness = Harness(snapshot([rule("c", comment("x"))]), flows: 3, batch: 1)
        let seen = OSAllocatedUnfairLock<[ExecuteRunner.Phase]>(initialState: [])
        harness.hook.on { _, runner in
            let phase = await MainActor.run { runner.phase }
            seen.withLock { $0.append(phase) }
        }
        harness.prepare()
        await harness.runner.run()
        #expect(seen.withLock { $0 } == [.running(done: 1, total: 3), .running(done: 2, total: 3), .running(done: 3, total: 3)])
        #expect(harness.summary()?.wasCancelled == false)
    }

    @Test func progressIsReportedPerBatch() async {
        let harness = Harness(snapshot([rule("c", comment("x"))]), flows: 5, batch: 2)
        let seen = OSAllocatedUnfairLock<[ExecuteRunner.Phase]>(initialState: [])
        harness.hook.on { _, runner in
            let phase = await MainActor.run { runner.phase }
            seen.withLock { $0.append(phase) }
        }
        harness.prepare()
        await harness.runner.run()
        let total = 5
        #expect(
            seen.withLock { $0 } == [
                .running(done: 0, total: total), .running(done: 2, total: total), .running(done: 2, total: total),
                .running(done: 4, total: total), .running(done: 5, total: total),
            ])
    }

    @Test func undoFlowOnlyTouchesThatFlow() async {
        let harness = Harness(snapshot([rule("c", comment("x"))]), flows: 3)
        harness.prepare()
        await harness.runner.run()
        #expect(harness.runner.undoFlow(harness.ids[1]))
        #expect(!harness.runner.undoFlow(harness.ids[1]))
        #expect(harness.comments() == ["x", nil, "x"])
        #expect(harness.runner.lastRun?.flowIDs == [harness.ids[0], harness.ids[2]])
    }
}
