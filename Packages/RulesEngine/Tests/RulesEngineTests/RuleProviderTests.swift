import FlowStore
import Foundation
import Testing

@testable import RulesEngine

// The provider publishes the repository's snapshot: patterns are prepared and hit counts reset on publish,
// the global switch only hides the snapshot, and the evaluation order is worked out once per snapshot.

private func uuid(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", number))!
}

private func legacyRule(_ number: Int, order: Int = 0, host: String = "a.test", enabled: Bool = true) -> LegacyRule {
    LegacyRule(
        id: uuid(number), name: "rule \(number)", enabled: enabled, order: order, matcher: RuleMatcher(hostPattern: host),
        action: .editHeaders(direction: .request, operations: [.set(name: "X-Rule", value: "\(number)")]))
}

private func makeRepository(_ root: URL) -> (RuleRepository, ManagedAssetStore) {
    let limits = RulesLimits()
    let assets = ManagedAssetStore(
        directory: root.appendingPathComponent("assets"), limits: limits,
        budgets: OwnedFileBudgets(limits: limits, freeDiskBytes: ample))
    return (RuleRepository(directory: root.appendingPathComponent("config"), assets: assets, limits: limits), assets)
}

@Suite struct RuleProviderTests {
    @Test func providerPublishPreparesPatternsOfEveryEnabledRow() throws {
        let clock = BodyTestClock()
        let cache = PatternCache(budget: StepClock().budget, bodyBudget: clock.budget(maxDuration: .milliseconds(5)))
        let provider = RuleSnapshotProvider(RuleSnapshot(revision: 0, rules: []), patternCache: cache)
        let body = BodyRewriteAction(find: catastrophicFind, replacement: "x", syntax: .regex)
        let rows = Rule(
            id: uuid(1), name: "rows",
            conditions: ConditionGroup(mode: .any, rows: [
                ConditionRow(field: .host, op: .regexWhole, value: #"(a|b)\.test"#),
                ConditionRow(field: .host, op: .wildcard, value: "*.example.*"),
                ConditionRow(field: .pathAndQuery, op: .regexWhole, value: "/v[0-9]+/.*", caseSensitive: true),
                ConditionRow(field: .pathAndQuery, op: .wildcard, value: "/api/*", caseSensitive: true),
            ]),
            actions: [RuleAction(.rewriteBody(direction: .response, body))])
        let off = Rule(
            id: uuid(2), name: "off", enabled: false,
            conditions: ConditionGroup(rows: [
                ConditionRow(field: .pathAndQuery, op: .regexWhole, value: "/never/(x)+", caseSensitive: true)
            ]),
            actions: [RuleAction(.breakpoint(direction: .request, mode: .headers))])
        provider.publish(RuleSnapshot(revision: 1, rules: [rows, off]))
        #expect(cache.count == 4, "every row pattern of the enabled rule, none of the disabled one")

        // A body search that timed out stays off while its rule is unchanged, whether the snapshot is
        // republished as it is (an acknowledgement) or saved again with other rules edited; the
        // test below covers what switches it back on.
        let compiled = try cache.bodyPattern(body)
        for _ in 0..<3 { _ = compiled.replace(in: catastrophicInput, with: "x", scope: .all) }
        #expect(cache.isBodyPatternDisabled(body))
        provider.publish(RuleSnapshot(revision: 1, rules: [rows, off], migrationNotice: nil))
        #expect(cache.isBodyPatternDisabled(body))
        provider.publish(RuleSnapshot(revision: 2, rules: [rows, off]))
        #expect(cache.isBodyPatternDisabled(body))
    }

    // MARK: Position-only changes (order, group) are not edits

    /// A cache whose regex and body budgets run out after a few reads, so a few matches trip them.
    private static func quickTripCache() -> PatternCache {
        PatternCache(
            budget: BodyTestClock().budget(maxDuration: .milliseconds(2)),
            bodyBudget: BodyTestClock().budget(maxDuration: .milliseconds(5)))
    }

    private static let slowTarget = HTTPMessageTarget(
        scheme: "https", host: catastrophicInput, port: 443, method: "GET", pathAndQuery: "/api/x")

    /// A rule whose only condition is the catastrophic host regex.
    private static func regexRule(_ number: Int, order: Int = 0, groupID: UUID? = nil) -> Rule {
        Rule(
            id: uuid(number), name: "rule \(number)", groupID: groupID, order: order,
            conditions: ConditionGroup(rows: [ConditionRow(field: .host, op: .regexWhole, value: catastrophicFind)]),
            actions: [RuleAction(.editHeaders(direction: .request, operations: [.set(name: "X", value: "\(number)")]))])
    }

    private static func plainRule(_ number: Int, order: Int = 0, groupID: UUID? = nil, host: String = "a.test") -> Rule {
        Rule(
            id: uuid(number), name: "rule \(number)", groupID: groupID, order: order,
            conditions: ConditionGroup(rows: [ConditionRow(field: .host, op: .hostPattern, value: host)]),
            actions: [RuleAction(.editHeaders(direction: .request, operations: [.set(name: "X", value: "\(number)")]))])
    }

    /// Runs the rule's catastrophic regex until its circuit breaker opens.
    private static func trip(_ rule: Rule, in cache: PatternCache) {
        for _ in 0..<3 { _ = rule.conditions.evaluate(slowTarget, status: nil, cache: cache) }
    }

    private static func recordHits(_ provider: RuleSnapshotProvider, _ rules: [Rule], times: Int = 2) {
        for rule in rules { for _ in 0..<times { provider.hits.recordHit(rule.id) } }
    }

    /// The old editor renumbers every rule below an insert, a delete or a move. That is not an edit of
    /// those rules: their hit counts stay and a regex that timed out stays switched off.
    @Test func positionOnlyChangesKeepHitCountsAndTimedOutRegexes() {
        let cache = Self.quickTripCache()
        let provider = RuleSnapshotProvider(RuleSnapshot(revision: 0, rules: []), patternCache: cache)
        let slow = Self.regexRule(1, order: 0), b = Self.plainRule(2, order: 1), c = Self.plainRule(3, order: 2)
        provider.publish(RuleSnapshot(revision: 1, rules: [slow, b, c]))
        Self.recordHits(provider, [slow, b, c])
        Self.trip(slow, in: cache)
        #expect(cache.isRegexDisabled(catastrophicFind, caseInsensitive: true))

        // Insert a rule on top: everything below moves down one place.
        let inserted = Self.plainRule(9, order: 0)
        var moved = [slow, b, c]
        for index in moved.indices { moved[index].order += 1 }
        provider.publish(RuleSnapshot(revision: 2, rules: [inserted] + moved))
        #expect([slow, b, c].map { provider.hits.count($0.id) } == [2, 2, 2])
        #expect(cache.isRegexDisabled(catastrophicFind, caseInsensitive: true))

        // Move one into a new group and renumber the rest.
        let group = RuleGroup(id: uuid(100), name: "g", order: 0)
        var grouped = moved
        grouped[1].groupID = group.id
        grouped[1].order = 0
        grouped[0].order = 5
        grouped[2].order = 6
        provider.publish(RuleSnapshot(revision: 3, groups: [group], rules: [inserted] + grouped))
        #expect([slow, b, c].map { provider.hits.count($0.id) } == [2, 2, 2])
        #expect(cache.isRegexDisabled(catastrophicFind, caseInsensitive: true))

        // Delete another rule and renumber what is left.
        var rest = [grouped[0], grouped[1]]
        rest[0].order = 0
        provider.publish(RuleSnapshot(revision: 4, groups: [group], rules: rest))
        #expect(provider.hits.count(c.id) == 0, "the removed rule starts over")
        #expect([slow, b].map { provider.hits.count($0.id) } == [2, 2])
        #expect(cache.isRegexDisabled(catastrophicFind, caseInsensitive: true))
    }

    /// Spec 5.5.8/6.5: saving a rule starts its count over. Its patterns are prepared again only when
    /// its conditions or body searches changed, or it was switched on (the help text says: change the
    /// conditions, or switch the rule off and on).
    @Test func savingARuleResetsItsCountAndRearmsPatternsOnlyForPatternEdits() {
        let cache = Self.quickTripCache()
        let provider = RuleSnapshotProvider(RuleSnapshot(revision: 0, rules: []), patternCache: cache)
        let slow = Self.regexRule(1), other = Self.plainRule(2, order: 1)
        var revision: UInt64 = 1
        func publish(_ rules: [Rule]) {
            provider.publish(RuleSnapshot(revision: revision, rules: rules))
            revision += 1
        }
        func setUp() {
            publish([slow, other])
            Self.recordHits(provider, [slow, other])
            Self.trip(slow, in: cache)
            #expect(cache.isRegexDisabled(catastrophicFind, caseInsensitive: true))
        }

        // A rename (or any edit that leaves the conditions alone) resets the count, nothing else.
        setUp()
        var renamed = slow
        renamed.name = "renamed"
        publish([renamed, other])
        #expect(provider.hits.count(slow.id) == 0)
        #expect(provider.hits.count(other.id) == 2)
        #expect(cache.isRegexDisabled(catastrophicFind, caseInsensitive: true))

        // Changing the conditions prepares the patterns again.
        var edited = renamed
        edited.conditions.rows.append(ConditionRow(field: .method, op: .equals, value: "GET", caseSensitive: true))
        publish([edited, other])
        #expect(provider.hits.count(slow.id) == 0)
        #expect(!cache.isRegexDisabled(catastrophicFind, caseInsensitive: true))

        // Switching a rule off and on prepares them again; off alone does not.
        Self.recordHits(provider, [edited])
        Self.trip(edited, in: cache)
        #expect(cache.isRegexDisabled(catastrophicFind, caseInsensitive: true))
        var off = edited
        off.enabled = false
        publish([off, other])
        #expect(provider.hits.count(edited.id) == 0)
        #expect(cache.isRegexDisabled(catastrophicFind, caseInsensitive: true))
        publish([edited, other])
        #expect(!cache.isRegexDisabled(catastrophicFind, caseInsensitive: true))
        #expect(provider.hits.count(other.id) == 2, "the other rule was never touched")
    }

    private static func headerRegexRule(_ pattern: String) -> Rule {
        Rule(
            id: uuid(1), name: "header", order: 0,
            actions: [RuleAction(.editHeaders(direction: .request, operations: [
                .regex(name: "X", pattern: pattern, replacement: "y", caseSensitive: true)]))])
    }

    private static func tripHeaderRegex(in cache: PatternCache) throws {
        let compiled = try cache.regex(catastrophicFind, mode: .find, caseInsensitive: false)
        for _ in 0..<3 { _ = compiled.matches(catastrophicInput) }
        #expect(cache.isRegexDisabled(catastrophicFind, mode: .find, caseInsensitive: false))
    }

    @Test func patternsDifferSeesAChangedHeaderRegex() throws {
        let cache = Self.quickTripCache()
        let provider = RuleSnapshotProvider(RuleSnapshot(revision: 0, rules: []), patternCache: cache)
        provider.publish(RuleSnapshot(revision: 1, rules: [Self.headerRegexRule("harmless")]))
        try Self.tripHeaderRegex(in: cache)
        // Same id, same conditions: only the header regex differs. It is prepared again (strikes forgotten).
        provider.publish(RuleSnapshot(revision: 2, rules: [Self.headerRegexRule(catastrophicFind)]))
        #expect(!cache.isRegexDisabled(catastrophicFind, mode: .find, caseInsensitive: false))
    }

    @Test func patternsDifferIgnoresUnrelatedEdits() throws {
        let cache = Self.quickTripCache()
        let provider = RuleSnapshotProvider(RuleSnapshot(revision: 0, rules: []), patternCache: cache)
        let rule = Self.headerRegexRule(catastrophicFind)
        provider.publish(RuleSnapshot(revision: 1, rules: [rule]))
        try Self.tripHeaderRegex(in: cache)
        var renamed = rule
        renamed.name = "renamed"
        renamed.note = "a note"
        provider.publish(RuleSnapshot(revision: 2, rules: [renamed]))
        #expect(cache.isRegexDisabled(catastrophicFind, mode: .find, caseInsensitive: false))
    }

    @Test func aTimedOutBodySearchComesBackOnlyWhenItsRuleEditsBodySearchesOrIsSwitchedOn() throws {
        let cache = Self.quickTripCache()
        let provider = RuleSnapshotProvider(RuleSnapshot(revision: 0, rules: []), patternCache: cache)
        let body = BodyRewriteAction(find: catastrophicFind, replacement: "x", syntax: .regex)
        let rewrite = Rule(
            id: uuid(1), name: "body", order: 0,
            actions: [RuleAction(.rewriteBody(direction: .response, body))])
        let neighbour = Self.plainRule(2, order: 1)
        provider.publish(RuleSnapshot(revision: 1, rules: [rewrite, neighbour]))
        func tripBody() throws {
            let compiled = try cache.bodyPattern(body)
            for _ in 0..<3 { _ = compiled.replace(in: catastrophicInput, with: "x", scope: .all) }
            #expect(cache.isBodyPatternDisabled(body))
        }
        try tripBody()

        // Another rule goes away and this one is renumbered or renamed: still switched off.
        var renumbered = rewrite
        renumbered.order = 0
        renumbered.name = "renamed"
        provider.publish(RuleSnapshot(revision: 2, rules: [renumbered]))
        #expect(cache.isBodyPatternDisabled(body))

        // Editing the search switches the (same text) pattern back on.
        var edited = renumbered
        edited.actions = [RuleAction(.rewriteBody(direction: .response, BodyRewriteAction(
            find: catastrophicFind, replacement: "y", syntax: .regex)))]
        provider.publish(RuleSnapshot(revision: 3, rules: [edited]))
        #expect(!cache.isBodyPatternDisabled(body))

        // So does switching the rule off and on.
        try tripBody()
        var off = edited
        off.enabled = false
        provider.publish(RuleSnapshot(revision: 4, rules: [off]))
        #expect(cache.isBodyPatternDisabled(body))
        provider.publish(RuleSnapshot(revision: 5, rules: [edited]))
        #expect(!cache.isBodyPatternDisabled(body))
    }

    @Test func hitCountersResetForChangedRulesOnly() {
        let provider = RuleSnapshotProvider(RuleSnapshot(revision: 0, rules: []))
        let changed = Rule(migrating: legacyRule(1))
        let removed = Rule(migrating: legacyRule(2))
        let unchanged = Rule(migrating: legacyRule(3))
        let switchedOff = Rule(migrating: legacyRule(4))
        provider.publish(RuleSnapshot(revision: 1, rules: [changed, removed, unchanged, switchedOff]))
        for rule in [changed, removed, unchanged, switchedOff] {
            provider.hits.recordHit(rule.id)
            provider.hits.recordHit(rule.id)
        }
        var edited = changed
        edited.conditions.rows = [ConditionRow(field: .host, op: .hostPattern, value: "b.test")]
        var disabled = switchedOff
        disabled.enabled = false
        provider.publish(RuleSnapshot(revision: 2, rules: [edited, unchanged, disabled]))
        #expect(provider.hits.count(changed.id) == 0)
        #expect(provider.hits.count(removed.id) == 0)
        #expect(provider.hits.count(unchanged.id) == 2)
        #expect(provider.hits.count(switchedOff.id) == 0)
    }

    @Test func hitCountSurvivesRepublishOfUnchangedRule() async throws {
        let rule = Rule(migrating: legacyRule(1))
        let provider = RuleSnapshotProvider(RuleSnapshot(revision: 1, rules: [rule]))
        provider.hits.recordHit(rule.id)
        provider.publish(RuleSnapshot(revision: 2, groups: [RuleGroup(name: "new")], rules: [rule]))
        #expect(provider.hits.count(rule.id) == 1)

        // Through the repository: saving the rule unchanged keeps its count, editing it starts over.
        let root = makeTempDirectory(); defer { removeTree(root) }
        let (repository, _) = makeRepository(root)
        _ = try await repository.load()
        let first = try await repository.save(groups: [], rules: [rule], expectedRevision: 0)
        repository.provider.hits.recordHit(rule.id)
        let again = try await repository.save(groups: [], rules: [rule], expectedRevision: first.revision)
        #expect(repository.provider.hits.count(rule.id) == 1)
        var renamed = rule
        renamed.name = "renamed"
        _ = try await repository.save(groups: [], rules: [renamed], expectedRevision: again.revision)
        #expect(repository.provider.hits.count(rule.id) == 0)
    }

    /// The evaluation order is worked out once per snapshot value and shared by its
    /// copies; changing the rules or groups of a copy gives that copy its own order. The cache is not
    /// part of the snapshot's value or its stored form.
    @Test func evaluationOrderIsCachedPerSnapshotAndFollowsEdits() throws {
        let a = Rule(migrating: legacyRule(1, order: 0)), b = Rule(migrating: legacyRule(2, order: 1))
        var snapshot = RuleSnapshot(revision: 1, rules: [b, a])
        #expect(snapshot.evaluationOrder.map(\.id) == [a.id, b.id])
        let copy = snapshot
        snapshot.rules[0].order = -1
        #expect(snapshot.evaluationOrder.map(\.id) == [b.id, a.id])
        #expect(copy.evaluationOrder.map(\.id) == [a.id, b.id])
        let group = RuleGroup(id: uuid(100), name: "g", enabled: false, order: -2)
        snapshot.rules[1].groupID = group.id
        snapshot.groups = [group]
        #expect(snapshot.evaluationOrder.map(\.id) == [b.id])

        #expect(copy == RuleSnapshot(revision: 1, rules: [b, a]))
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(copy)) as? [String: Any]
        #expect(Set(json?.keys.map { $0 } ?? []) == ["schemaVersion", "revision", "groups", "rules", "templatesInstalled"])
        #expect(try JSONDecoder().decode(RuleSnapshot.self, from: JSONEncoder().encode(copy)) == copy)
    }
}
