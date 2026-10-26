import Foundation
import RulesEngine
import Testing

@testable import AppCore

@MainActor @Suite(.productionChinese) struct RuleOutlineCacheTests {
    @Test func outlineIsRebuiltOnlyWhenTheKeyChanges() {
        let cache = RuleOutlineCache()
        let tree = RuleTree(groups: [], rules: [Rule(name: "a", order: 0, actions: [RuleAction(.hide)])])
        var builds = 0
        func get(_ key: RuleOutlineCache.Key) -> RuleOutline {
            cache.outline(for: key) {
                builds += 1
                return RuleOutline(tree: tree, expanded: key.expanded, onlyEnabled: key.onlyEnabled, query: key.query) { [$0.name] }
            }
        }
        let base = RuleOutlineCache.Key(revision: 1, expanded: [], onlyEnabled: false, query: "")
        let first = get(base)
        _ = get(base)
        _ = get(base)
        #expect(builds == 1)
        #expect(get(base) == first)

        var key = base
        key.revision = 2
        _ = get(key)
        #expect(builds == 2)
        key.query = "a"
        _ = get(key)
        #expect(builds == 3)
        key.expanded = [UUID()]
        _ = get(key)
        #expect(builds == 4)
        key.onlyEnabled = true
        _ = get(key)
        #expect(builds == 5)
        _ = get(key)
        #expect(builds == 5)
    }
}
