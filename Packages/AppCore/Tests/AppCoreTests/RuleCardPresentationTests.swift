import Foundation
import Localization
import RulesEngine
import Testing

@testable import AppCore

@Suite(.productionChinese) struct RuleCardPresentationTests {
    private let rule = Rule(name: "r", actions: [RuleAction(.hide)])

    private func card(_ hits: Int) -> RuleCard {
        RuleCardPresentation.card(for: rule, hits: hits, isReadOnly: false, assetName: { _ in nil })
    }

    @Test func summaryJoinsMatchAndAction() {
        let match = RulePresentation.matchSummary(of: rule)
        let action = RuleOutlinePresentation.actionText(of: rule, assetName: { _ in nil })
        #expect(card(0).summary == L10n.format("rules.card.summary", match, action))
    }

    @Test func zeroHitsHasNoBadge() { #expect(card(0).hitBadge == nil) }

    @Test func hitsBadgeUsesPositionalCount() { #expect(card(12).hitBadge == L10n.format("rules.card.hits", 12)) }

    @Test func helpTextIsSummaryAloneWithoutHits() { #expect(card(0).helpText == card(0).summary) }

    @Test func helpTextAppendsHitsAfterTheFullSummary() {
        #expect(card(3).helpText == card(3).summary + "\n" + L10n.format("rules.card.hits", 3))
    }

    @Test func groupCountTextShowsEnabledOfTotal() {
        let group = RuleGroup(name: "G", order: 0)
        let card = RuleCardPresentation.group(group, counts: (3, 5))
        #expect(card.countText == L10n.format("rules.card.groupCount", 3, 5))
        #expect(card.title == "G" && card.isEnabled)
    }

    @Test func emptyGroupNameFallsBackToUnnamed() {
        let card = RuleCardPresentation.group(RuleGroup(name: "  ", order: 0), counts: (0, 0))
        #expect(card.title == L10n.string("rules.list.unnamed"))
    }

    @Test func flagsAreCarriedThrough() {
        var disabled = rule
        disabled.enabled = false
        let card = RuleCardPresentation.card(for: disabled, hits: 0, isReadOnly: true, assetName: { _ in nil })
        #expect(!card.isEnabled && card.isReadOnly)
    }
}
