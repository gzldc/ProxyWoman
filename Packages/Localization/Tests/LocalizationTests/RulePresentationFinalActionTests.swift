import AppCore
import FlowStore
import Foundation
import Localization
import RulesEngine
import Testing

// Rules 2.0 R1, Task 10: the list and the detail pane describe rules 2.0 in the three fixture languages.
// This suite lives beside the translations it reads (the fixture bundle is a resource of this test target).

private func fixtureBundle() throws -> Bundle {
    let url = try #require(Bundle.module.url(forResource: "Translations", withExtension: "bundle", subdirectory: "Fixtures"))
    return try #require(Bundle(url: url))
}

/// zh-Hans, en and fr, each from the fixture bundle.
private func localizers() throws -> [(language: String, localizer: Localizer)] {
    let bundle = try fixtureBundle()
    return ["zh-Hans", "en", "fr"].map { ($0, Localizer(bundle: bundle, preferredLanguages: [$0])) }
}

private let ruleA = UUID(), ruleB = UUID(), gone = UUID()

private func names(_ id: UUID) -> String? {
    if id == ruleA { return "Fix price" }
    if id == ruleB { return "Force 404" }
    return nil
}

private func matches(_ outcomes: [RuleOutcome]) -> RuleMatchSummary {
    RuleMatchSummary(revision: 1, ruleIDs: [], total: outcomes.count, outcomes: outcomes)
}

private func simpleRule(
    matcher: RuleMatcher = RuleMatcher(hostPattern: "a.test"), mode: ConditionGroup.Mode = .all,
    action: LegacyRuleAction = .rewriteStatus(RewriteStatusAction(status: 404))
) -> Rule {
    var rule = Rule(id: UUID(), name: "r", enabled: true, order: 0, matcher: matcher, action: action)
    rule.conditions.mode = mode
    return rule
}

private func multiActionRule(actions: Int) -> Rule {
    Rule(
        id: UUID(), name: "multi",
        conditions: ConditionGroup(rows: [
            ConditionRow(field: .host, op: .hostPattern, value: "a.test"),
            ConditionRow(field: .method, op: .equals, value: "GET", caseSensitive: true),
        ]),
        actions: (0..<actions).map { RuleAction(.rewriteStatus(RewriteStatusAction(status: 400 + $0))) })
}

@Suite(.productionChinese) struct RulePresentationFinalActionTests {
    // MARK: outcomes

    @Test func finalStopLineNamesTheRuleAndActionNumber() throws {
        for (language, localizer) in try localizers() {
            let lines = RulePresentation.outcomeLines(
                matches([RuleOutcome(ruleID: ruleA, code: .finalStop, actionIndex: 1)]), ruleName: names, localizer: localizer)
            #expect(lines == [localizer.format("ruleOutcome.finalStop", arguments: ["Fix price", 2])], "\(language)")
            let line = try #require(lines.first)
            #expect(line.contains("Fix price") && line.contains("2") && !line.contains("1"), "\(language): \(line)")
            #expect(!line.hasPrefix("ruleOutcome."), "\(language) is translated")
        }
        // Another action of the same rule is another sentence.
        let zh = try #require(try localizers().first).localizer
        let lines = RulePresentation.outcomeLines(
            matches([
                RuleOutcome(ruleID: ruleA, code: .finalStop, actionIndex: 0),
                RuleOutcome(ruleID: ruleA, code: .finalStop, actionIndex: 2),
                RuleOutcome(ruleID: ruleA, code: .finalStop, actionIndex: 0),
            ]),
            ruleName: names, localizer: zh)
        #expect(lines.count == 2 && lines[0].contains("1") && lines[1].contains("3"))
    }

    @Test func skippedAfterFinalLine() throws {
        for (language, localizer) in try localizers() {
            let lines = RulePresentation.outcomeLines(
                matches([RuleOutcome(ruleID: ruleB, code: .skippedAfterFinal, actionIndex: 2)]), ruleName: names,
                localizer: localizer)
            #expect(lines == [localizer.format("ruleOutcome.skippedAfterFinal", arguments: ["Force 404", 3])], "\(language)")
            let line = try #require(lines.first)
            #expect(line.contains("Force 404") && line.contains("3"), "\(language): \(line)")
        }
    }

    @Test func occurrenceSkippedLine() throws {
        for (language, localizer) in try localizers() {
            let lines = RulePresentation.outcomeLines(
                matches([RuleOutcome(ruleID: ruleA, code: .occurrenceSkipped)]), ruleName: names, localizer: localizer)
            #expect(lines == [localizer.format("ruleOutcome.occurrenceSkipped", arguments: ["Fix price"])], "\(language)")
            #expect(lines.first?.contains("Fix price") == true, "\(language)")
        }
        // A deleted rule gets the placeholder, like every other outcome.
        let zh = try #require(try localizers().first).localizer
        let lines = RulePresentation.outcomeLines(
            matches([RuleOutcome(ruleID: gone, code: .finalStop, actionIndex: 0)]), ruleName: names, localizer: zh)
        #expect(lines == [zh.format("ruleOutcome.finalStop", arguments: [zh.string("ruleOutcome.unknownRule"), 1])])
        // Those three are not pattern problems.
        let summary = matches([
            RuleOutcome(ruleID: ruleA, code: .finalStop, actionIndex: 0), RuleOutcome(ruleID: ruleA, code: .occurrenceSkipped),
            RuleOutcome(ruleID: ruleA, code: .skippedAfterFinal, actionIndex: 1),
        ])
        #expect(RulePresentation.patternProblemLines(summary, ruleName: names, localizer: zh).isEmpty)
        #expect(RulePresentation.outcomeLines(summary, ruleName: names, localizer: zh).count == 3)
    }

    // MARK: the list

    @Test func multiActionSummaryShowsActionCount() throws {
        for (language, localizer) in try localizers() {
            for count in [2, 3, 16] {
                let rule = multiActionRule(actions: count)
                let action = RulePresentation.actionSummary(of: rule, assetName: { _ in nil }, localizer: localizer)
                #expect(action == localizer.format("rules.summary.multiAction", arguments: [count]), "\(language) \(count)")
                #expect(action.contains(String(count)), "\(language): \(action)")
            }
            // And the conditions column counts the rows.
            let match = RulePresentation.matchSummary(of: multiActionRule(actions: 2), localizer: localizer)
            #expect(match == localizer.format("rules.summary.conditionsCount", arguments: [2]), "\(language)")
        }
    }

    @Test func nonSimpleRuleUsesMultipleKind() throws {
        let rule = multiActionRule(actions: 2)
        #expect(RuleKind(rule) == nil)
        for (language, localizer) in try localizers() {
            #expect(RulePresentation.kindTitle(of: rule, localizer: localizer) == localizer.string("rules.kind.multiple"), "\(language)")
            let fields = RulePresentation.searchFields(of: rule, assetName: { _ in nil }, localizer: localizer)
            #expect(fields.count == 4 && fields[1] == localizer.string("rules.kind.multiple"), "\(language)")
            #expect(fields[2] == localizer.format("rules.summary.conditionsCount", arguments: [2]), "\(language)")
            #expect(fields[3] == localizer.format("rules.summary.multiAction", arguments: [2]), "\(language)")
            #expect(localizer.string("rules.kind.multiple") != "rules.kind.multiple", "\(language) is translated")
        }
        // A rule the old editor can state keeps its action's name.
        let simple = simpleRule(action: .breakpoint(direction: .request, mode: .headers))
        let zh = try #require(try localizers().first).localizer
        #expect(RulePresentation.kindTitle(of: simple, localizer: zh) == zh.string("rules.kind.breakpoint"))
    }

    @Test func modeTagsAppearForAnyAndNone() throws {
        let matcher = RuleMatcher(scheme: "https", hostPattern: "a.test")
        for (language, localizer) in try localizers() {
            let base = RulePresentation.matchSummary(matcher, localizer: localizer)
            #expect(RulePresentation.matchSummary(of: simpleRule(matcher: matcher, mode: .all), localizer: localizer) == base, "\(language)")
            #expect(
                RulePresentation.matchSummary(of: simpleRule(matcher: matcher, mode: .any), localizer: localizer)
                    == localizer.format("rules.summary.modeAny", arguments: [base]), "\(language)")
            #expect(
                RulePresentation.matchSummary(of: simpleRule(matcher: matcher, mode: .none), localizer: localizer)
                    == localizer.format("rules.summary.modeNone", arguments: [base]), "\(language)")
            #expect(base != localizer.format("rules.summary.modeAny", arguments: [base]), "\(language)")
            // No condition rows: every mode matches every session, so there is nothing to tag.
            let everything = RulePresentation.matchSummary(RuleMatcher(), localizer: localizer)
            #expect(RulePresentation.matchSummary(of: simpleRule(matcher: RuleMatcher(), mode: .none), localizer: localizer) == everything)
        }
    }

    @Test func existingSingleActionSummariesAreUnchanged() throws {
        let rules: [Rule] = [
            simpleRule(),
            simpleRule(matcher: RuleMatcher(scheme: "https", hostPattern: "*.a.test", port: 8443, method: "GET", path: .prefix("/api/"))),
            simpleRule(matcher: RuleMatcher(hostPattern: "a.test", statusRange: 500...599), action: .editHeaders(direction: .response, operations: [.remove(name: "X")])),
            simpleRule(action: .mapRemote(MapRemoteAction(targetScheme: "https", targetHost: "b.test", targetPort: 443, path: .replace("/v2")))),
            simpleRule(action: .rewriteBody(direction: .response, BodyRewriteAction(find: "foo", replacement: "bar"))),
        ]
        for (language, localizer) in try localizers() {
            for rule in rules {
                let legacy = try #require(rule.simple)
                #expect(
                    RulePresentation.matchSummary(of: rule, localizer: localizer)
                        == RulePresentation.matchSummary(legacy.matcher, localizer: localizer), "\(language)")
                #expect(RulePresentation.kindTitle(of: rule, localizer: localizer) == localizer.string(RuleKind(legacy.action).localizationKey))
            }
            #expect(
                RulePresentation.actionSummary(of: rules[4], assetName: { _ in nil }, localizer: localizer)
                    == localizer.format("rules.actionSummary.rewriteBody.response", arguments: ["foo", "bar"]), "\(language)")
            #expect(
                RulePresentation.actionSummary(of: rules[0], assetName: { _ in nil }, localizer: localizer)
                    == localizer.format("rules.actionSummary.rewriteStatus", arguments: [404]), "\(language)")
            #expect(
                RulePresentation.summary(of: rules[0], localizer: localizer)
                    == localizer.format(
                        "rules.summary.rewriteStatus", arguments: [RulePresentation.matchSummary(rules[0].simple!.matcher, localizer: localizer), 404]),
                "\(language)")
        }
    }
}
