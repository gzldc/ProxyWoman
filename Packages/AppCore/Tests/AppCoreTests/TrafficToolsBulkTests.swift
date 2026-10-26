import FlowStore
import Foundation
import RulesEngine
import Testing
@testable import AppCore

@MainActor private final class Saved {
    var policies: [TrafficPolicy] = []
}

@MainActor private func makeModel(_ initial: TrafficPolicy) -> (TrafficToolsModel, TrafficPolicyProvider, Saved) {
    let provider = TrafficPolicyProvider()
    let saved = Saved()
    return (TrafficToolsModel(provider: provider, initial: initial) { saved.policies.append($0) }, provider, saved)
}

private func entry(_ host: String, enabled: Bool = true) -> TrafficFilterEntry {
    var entry = TrafficFilterEntry(matcher: RuleMatcher(hostPattern: host))
    entry.enabled = enabled
    return entry
}

private func policy() -> TrafficPolicy {
    var policy = TrafficPolicy()
    policy.allowEntries = [entry("a.test"), entry("b.test", enabled: false), entry("c.test")]
    policy.blockEntries = [entry("x.test"), entry("y.test")]
    policy.conditions.hostRules = [
        HostNetworkRule(hostPattern: "h1.test", selection: .preset(.edge)),
        HostNetworkRule(hostPattern: "h2.test", selection: .preset(.edge)),
    ]
    return policy
}

/// The tool windows act on every selected row at once: one validated change, one publish, one save.
@MainActor @Suite(.productionChinese) struct TrafficToolsBulkTests {
    @Test func switchingSeveralEntriesIsOneChange() {
        let (model, provider, saved) = makeModel(policy())
        let start = provider.revision
        let ids = Set(model.policy.allowEntries.map(\.id) + model.policy.blockEntries.prefix(1).map(\.id))
        model.setEntriesEnabled(ids, enabled: false)
        #expect(model.policy.allowEntries.map(\.enabled) == [false, false, false])
        #expect(model.policy.blockEntries.map(\.enabled) == [false, true])
        #expect(provider.revision == start + 1 && saved.policies.count == 1)
        model.setEntriesEnabled(ids, enabled: false)
        #expect(provider.revision == start + 1, "no change, nothing published")
    }

    @Test func removingSeveralEntriesIsOneChange() {
        let (model, provider, saved) = makeModel(policy())
        let start = provider.revision
        let keep = model.policy.allowEntries[1]
        let ids = Set([model.policy.allowEntries[0].id, model.policy.allowEntries[2].id, model.policy.blockEntries[1].id])
        model.removeEntries(ids)
        #expect(model.policy.allowEntries == [keep])
        #expect(model.policy.blockEntries.map { $0.matcher.hostPattern } == ["x.test"])
        #expect(provider.revision == start + 1 && saved.policies.count == 1)
        model.removeEntries([UUID()])
        #expect(provider.revision == start + 1)
    }

    @Test func clearingAListLeavesTheOtherAlone() {
        let (model, provider, saved) = makeModel(policy())
        let start = provider.revision
        model.clearEntries(in: .allow)
        #expect(model.policy.allowEntries.isEmpty && model.policy.blockEntries.count == 2)
        model.clearEntries(in: .block)
        #expect(model.policy.blockEntries.isEmpty)
        #expect(provider.revision == start + 2 && saved.policies.count == 2)
        model.clearEntries(in: .block)
        #expect(provider.revision == start + 2)
        // Host rules and the global selection are not entry lists.
        model.clearEntries(in: .hostRules)
        #expect(model.policy.conditions.hostRules.count == 2)
    }

    @Test func hostRulesFollowTheSameBulkRules() {
        let (model, provider, saved) = makeModel(policy())
        let start = provider.revision
        let ids = Set(model.policy.conditions.hostRules.map(\.id))
        model.setHostConditions(ids, enabled: false)
        #expect(model.policy.conditions.hostRules.map(\.enabled) == [false, false])
        model.removeHostConditions([model.policy.conditions.hostRules[0].id])
        #expect(model.policy.conditions.hostRules.map(\.hostPattern) == ["h2.test"])
        model.clearHostConditions()
        #expect(model.policy.conditions.hostRules.isEmpty)
        #expect(provider.revision == start + 3 && saved.policies.count == 3)
        model.clearHostConditions()
        #expect(provider.revision == start + 3)
    }
}
