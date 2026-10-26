import Foundation
import Localization
import RulesEngine

/// One affected pair of the upgrade notice, as a row. `higherID` is the rule with the higher priority and
/// `lowerID` the one below it, whichever of the two changes what the other sees: a Map Remote below a
/// response rule with a status range changes the request that rule reads (spec 5.5.2), so the affected rule
/// can be the higher one. The row therefore names both and says nothing about which one is affected.
public struct UpgradeNoticeItem: Equatable, Sendable, Identifiable {
    public var id: String
    public var changeClass: MigrationChangeClass
    public var higherID: UUID
    public var lowerID: UUID
    public var higherName: String
    public var lowerName: String

    public init(
        id: String, changeClass: MigrationChangeClass, higherID: UUID, lowerID: UUID, higherName: String, lowerName: String
    ) {
        self.id = id
        self.changeClass = changeClass
        self.higherID = higherID
        self.lowerID = lowerID
        self.higherName = higherName
        self.lowerName = lowerName
    }
}

/// The pairs of one change class, with the keys of the explanation shown above them.
public struct UpgradeNoticeSection: Equatable, Sendable {
    public var changeClass: MigrationChangeClass
    public var titleKey: String
    public var bodyKey: String
    public var items: [UpgradeNoticeItem]

    public init(changeClass: MigrationChangeClass, titleKey: String, bodyKey: String, items: [UpgradeNoticeItem]) {
        self.changeClass = changeClass
        self.titleKey = titleKey
        self.bodyKey = bodyKey
        self.items = items
    }
}

/// What the one-time upgrade notice shows (spec 5.6.4): an explanation per change class that has pairs, the
/// pairs under it, and how many more pairs the stored notice does not list. The file holds ids and classes
/// only (D10); every sentence is built here, when it is shown.
public struct UpgradeNoticePresentation: Equatable, Sendable {
    /// Only the classes that have pairs, in class order 1, 2, 3.
    public var sections: [UpgradeNoticeSection]
    /// Affected pairs the stored notice leaves out (`MigrationNotice.omittedPairCount`).
    public var omittedPairCount: Int

    public init(sections: [UpgradeNoticeSection], omittedPairCount: Int = 0) {
        self.sections = sections
        self.omittedPairCount = omittedPairCount
    }

    /// Nil when the notice has nothing to show: none, or one that lists no pair and counts none. A notice
    /// that lists no pair but counts some is shown, so the count is not lost. `ruleName` is nil for a rule
    /// that was deleted since; its row uses the placeholder name.
    public static func make(
        notice: MigrationNotice?, ruleName: (UUID) -> String?, localizer: Localizer = L10n.localizer
    ) -> UpgradeNoticePresentation? {
        guard let notice, notice.listsAffectedRules else { return nil }
        var names: [UUID: String] = [:]
        func name(_ id: UUID) -> String {
            if let known = names[id] { return known }
            let resolved = ruleName(id).map { RulePresentation.displayName($0, localizer: localizer) }
                ?? localizer.string("ruleOutcome.unknownRule")
            names[id] = resolved
            return resolved
        }
        var byClass: [MigrationChangeClass: [UpgradeNoticeItem]] = [:]
        var seen = Set<MigrationPair>()
        for pair in notice.report.pairs where seen.insert(pair).inserted {
            let item = UpgradeNoticeItem(
                id: "\(pair.changeClass.rawValue):\(pair.higherRuleID.uuidString):\(pair.lowerRuleID.uuidString)",
                changeClass: pair.changeClass, higherID: pair.higherRuleID, lowerID: pair.lowerRuleID,
                higherName: name(pair.higherRuleID), lowerName: name(pair.lowerRuleID))
            byClass[pair.changeClass, default: []].append(item)
        }
        let sections = byClass.keys.sorted { $0.rawValue < $1.rawValue }.map { changeClass in
            let keys = Self.keys(for: changeClass)
            return UpgradeNoticeSection(
                changeClass: changeClass, titleKey: keys.title, bodyKey: keys.body, items: byClass[changeClass] ?? [])
        }
        return UpgradeNoticePresentation(sections: sections, omittedPairCount: max(0, notice.omittedPairCount))
    }

    /// "「A」→「B」": the rule with the higher priority first. Arguments are positional, so a translation may
    /// put the rules in either order.
    public func pairText(_ item: UpgradeNoticeItem, localizer: Localizer = L10n.localizer) -> String {
        localizer.format("rules.upgrade.pair", arguments: [item.higherName, item.lowerName])
    }

    /// The sentence that opens the notice. It points at the list below; when no pair is listed (the stored list
    /// was cut down to nothing) there is no list to point at, so it carries the count and says the pairs are not
    /// listed instead.
    public func introText(localizer: Localizer = L10n.localizer) -> String {
        sections.isEmpty
            ? localizer.format("rules.upgrade.introUnlisted", arguments: [omittedPairCount])
            : localizer.string("rules.upgrade.intro")
    }

    /// Whether the advice ("move the affected rule above the other, or change its condition") is shown. It
    /// refers to the listed pairs, so a notice that lists none (only the count of omitted ones) leaves it out.
    public var showsAdvice: Bool { !sections.isEmpty }

    /// "N more affected pairs are not listed here", or nil when every pair is listed. Nil too when no pair is
    /// listed at all: there is no "more" then, and `introText` already gives the count.
    public func omittedText(localizer: Localizer = L10n.localizer) -> String? {
        omittedPairCount > 0 && !sections.isEmpty
            ? localizer.format("rules.upgrade.omitted", arguments: [omittedPairCount]) : nil
    }

    private static func keys(for changeClass: MigrationChangeClass) -> (title: String, body: String) {
        switch changeClass {
        case .finalAction: ("rules.upgrade.class1.title", "rules.upgrade.class1.body")
        case .laterSeesEarlier: ("rules.upgrade.class2.title", "rules.upgrade.class2.body")
        case .sequentialRewrite: ("rules.upgrade.class3.title", "rules.upgrade.class3.body")
        }
    }
}

extension MigrationNotice {
    /// The notice has something to tell: a listed pair, or pairs it counts but does not list. A file with
    /// neither (D13 never writes one) shows nothing and raises no banner.
    var listsAffectedRules: Bool { !report.isEmpty || omittedPairCount > 0 }
}
