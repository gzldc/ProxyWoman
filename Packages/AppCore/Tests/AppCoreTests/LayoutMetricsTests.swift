import Foundation
import RulesEngine
import Testing

@testable import AppCore
@testable import Localization

/// The widths of the controls whose size follows their words, measured with the shipped Chinese and English strings. Chinese must keep every old fixed width; English must leave room for its longest option.
@Suite struct LayoutMetricsTests {
    /// The production Simplified Chinese strings.
    static let chinese = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])

    /// The English strings the app ships, so a reworded label is measured as it will appear.
    static let english = Localizer(bundle: L10n.bundle, preferredLanguages: ["en"])

    static let both: [(name: String, localizer: Localizer)] = [("zh-Hans", chinese), ("en", english)]

    // MARK: corpus

    @Test func shippedEnglishHasNoMissingTitles() {
        let localizer = Self.english
        let titles =
            RuleBuilderMetrics.menuFieldTitles(localizer: localizer) + RuleBuilderMetrics.operatorTitles(localizer: localizer)
            + RuleBuilderMetrics.actionTypeTitles(localizer: localizer) + RuleBuilderMetrics.markColorTitles(localizer: localizer)
            + SettingsMetrics.rowTitleKeys.map { localizer.string($0) } + SettingsMetrics.pageTitleKeys.map { localizer.string($0) }
        #expect(titles.allSatisfy { !$0.contains(".") || $0.contains(" ") })
        #expect(!titles.isEmpty)
    }

    // MARK: Chinese keeps the old widths

    @Test func chineseKeepsEveryOldFixedWidth() {
        let zh = Self.chinese
        #expect(RuleBuilderMetrics.fieldColumnWidth(localizer: zh) == 170)
        #expect(RuleBuilderMetrics.operatorColumnWidth(localizer: zh) == 150)
        #expect(RuleBuilderMetrics.conditionRowExtraWidth(localizer: zh) == 0)
        #expect(RuleBuilderMetrics.actionTypeIdealWidth(localizer: zh) == 190)
        #expect(RuleBuilderMetrics.actionTypePickerWidth(localizer: zh) == 280)
        #expect(RuleBuilderMetrics.fieldListWidth(localizer: zh) == 220)
        #expect(RuleBuilderMetrics.markDropdownWidth(localizer: zh) == 140)
        #expect(RuleBuilderMetrics.markListWidth(localizer: zh) == 210)
        #expect(SettingsMetrics.titleColumnWidth(localizer: zh) == 95)
        #expect(SettingsMetrics.sidebarWidth(localizer: zh) == 180)
        for type in ActionType.allCases {
            let descriptor = ActionEditorDescriptor(draft: ActionDraft(type: type), localizer: zh)
            #expect(RuleBuilderMetrics.modeDropdownWidth(descriptor) == 170, "\(type)")
            #expect(RuleBuilderMetrics.languageDropdownWidth(descriptor) == 190, "\(type)")
            #expect(RuleBuilderMetrics.presetDropdownWidth(descriptor, current: "") == 280, "\(type)")
        }
    }

    // MARK: rule editor columns

    @Test(arguments: ["zh-Hans", "en"])
    func conditionColumnsFitTheirWidestTitle(language: String) {
        let localizer = Self.both.first { $0.name == language }!.localizer
        let fieldWidth = RuleBuilderMetrics.fieldColumnWidth(localizer: localizer)
        let widestField = TextMeasure.widest(RuleBuilderMetrics.menuFieldTitles(localizer: localizer), size: 13)
        // direction icon + gap, the box's padding, chevron and gaps
        #expect(fieldWidth >= widestField + RuleBuilderMetrics.iconWidth + 40, "\(language) field column \(fieldWidth) vs \(widestField)")
        let operatorWidth = RuleBuilderMetrics.operatorColumnWidth(localizer: localizer)
        let widestOperator = TextMeasure.widest(RuleBuilderMetrics.operatorTitles(localizer: localizer), size: 13)
        #expect(operatorWidth >= widestOperator + 40, "\(language) operator column \(operatorWidth) vs \(widestOperator)")
    }

    @Test func englishConditionColumnsGrowButStayBounded() {
        let en = Self.english
        #expect(RuleBuilderMetrics.fieldColumnWidth(localizer: en) > 170)
        #expect(RuleBuilderMetrics.operatorColumnWidth(localizer: en) > 150)
        #expect(RuleBuilderMetrics.fieldColumnWidth(localizer: en) <= 230)
        #expect(RuleBuilderMetrics.operatorColumnWidth(localizer: en) <= 210)
    }

    /// The common one-line row (field, comparison, a value box of at least 80, the delete button, 8 pt gaps, 12 pt
    /// padding) must fit one editor column at the window's smallest width.
    @Test(arguments: ["zh-Hans", "en"])
    func plainConditionRowFitsAtTheSmallestEditorWindow(language: String) {
        let localizer = Self.both.first { $0.name == language }!.localizer
        let rowMinimum =
            RuleBuilderMetrics.fieldColumnWidth(localizer: localizer) + RuleBuilderMetrics.operatorColumnWidth(localizer: localizer)
            + 80 + 28 + 3 * 8 + 2 * 12
        let windowMinimum = 1100 + 2 * RuleBuilderMetrics.conditionRowExtraWidth(localizer: localizer)
        // a column is half the window, less the 12 + 8 pt of padding around the two boxes
        #expect(rowMinimum <= windowMinimum / 2 - 20, "\(language): row \(rowMinimum), column \((windowMinimum / 2) - 20)")
    }

    @Test(arguments: ["zh-Hans", "en"])
    func actionTypeDropdownAndListFitTheirTitles(language: String) {
        let localizer = Self.both.first { $0.name == language }!.localizer
        let widest = TextMeasure.widest(RuleBuilderMetrics.actionTypeTitles(localizer: localizer), size: 13)
        #expect(RuleBuilderMetrics.actionTypeIdealWidth(localizer: localizer) >= widest + RuleBuilderMetrics.iconWidth + 40)
        #expect(RuleBuilderMetrics.actionTypePickerWidth(localizer: localizer) >= widest + 100)
        #expect(RuleBuilderMetrics.actionTypeIdealWidth(localizer: localizer) <= 240)
    }

    /// Every method / language / preset dropdown has room for its longest option.
    @Test(arguments: ["zh-Hans", "en"])
    func actionFormDropdownsFitTheirOptions(language: String) {
        let localizer = Self.both.first { $0.name == language }!.localizer
        for type in ActionType.allCases {
            let descriptor = ActionEditorDescriptor(draft: ActionDraft(type: type), localizer: localizer)
            let modes = descriptor.modes.map(\.title)
            if !modes.isEmpty {
                #expect(RuleBuilderMetrics.modeDropdownWidth(descriptor) >= TextMeasure.widest(modes, size: 13) + 40, "\(language) \(type) modes")
            }
            let languages = descriptor.languages.map(\.title)
            if !languages.isEmpty {
                #expect(RuleBuilderMetrics.languageDropdownWidth(descriptor) >= TextMeasure.widest(languages, size: 13) + 40, "\(language) \(type) languages")
            }
            let presets = descriptor.presetGroups.flatMap { $0.map(\.title) }
            if !presets.isEmpty {
                #expect(
                    RuleBuilderMetrics.presetDropdownWidth(descriptor, current: "") >= TextMeasure.widest(presets, size: 13) + 40,
                    "\(language) presets")
            }
        }
    }

    @Test(arguments: ["zh-Hans", "en"])
    func markColorDropdownsFitTheirNames(language: String) {
        let localizer = Self.both.first { $0.name == language }!.localizer
        let widest = TextMeasure.widest(RuleBuilderMetrics.markColorTitles(localizer: localizer), size: 13)
        #expect(RuleBuilderMetrics.markDropdownWidth(localizer: localizer) >= widest + RuleBuilderMetrics.swatchWidth + 40)
        #expect(RuleBuilderMetrics.markListWidth(localizer: localizer) >= widest + 80)
    }

    @Test func fixedChoiceDropdownsGrowForLongTitles() {
        #expect(RuleBuilderMetrics.fixedChoiceWidth(minimum: 170, titles: ["Short"]) == 170)
        let long = RuleBuilderMetrics.fixedChoiceWidth(minimum: 170, titles: ["Keep Original Path and Query"])
        #expect(long > 170)
        #expect(long >= TextMeasure.width("Keep Original Path and Query", size: 13) + 40)
        // very long titles stop growing; the box cuts them and shows the whole title on hover
        #expect(RuleBuilderMetrics.fixedChoiceWidth(minimum: 170, titles: [String(repeating: "W", count: 80)]) == 320)
    }

    // MARK: settings

    @Test(arguments: ["zh-Hans", "en"])
    func settingsTitleColumnHoldsTheLongestTitleOnOneLine(language: String) {
        let localizer = Self.both.first { $0.name == language }!.localizer
        let width = SettingsMetrics.titleColumnWidth(localizer: localizer)
        for key in SettingsMetrics.rowTitleKeys {
            let title = localizer.string(key)
            #expect(TextMeasure.width(title, size: 13) <= width, "\(language) \(key) \(title)")
        }
        #expect(width >= 95)
    }

    @Test func englishSettingsTitleColumnIsWiderThanTheChineseOne() {
        #expect(SettingsMetrics.titleColumnWidth(localizer: Self.english) > 95)
        // the title column leaves the controls most of the 830 pt window: 180 sidebar, 24 + 24 padding, 16 gap
        let room = 830 - SettingsMetrics.sidebarWidth(localizer: Self.english) - 48 - 16
        #expect(room - SettingsMetrics.titleColumnWidth(localizer: Self.english) >= 420)
    }

    @Test(arguments: ["zh-Hans", "en"])
    func settingsSidebarHoldsEveryPageTitle(language: String) {
        let localizer = Self.both.first { $0.name == language }!.localizer
        let width = SettingsMetrics.sidebarWidth(localizer: localizer)
        for key in SettingsMetrics.pageTitleKeys {
            // icon (about 22) and the list's insets (about 40) around the title
            #expect(TextMeasure.width(localizer.string(key), size: 13) + 62 <= width, "\(language) \(key)")
        }
    }

    // MARK: inspector tab strip

    /// The strip is 320 pt at its narrowest. Only the selected tab spells its title; the others are 34 pt icons; the
    /// rules tab also carries its switch (28 pt + 10 pt) and the strip ends with 6 pt of padding.
    @Test(arguments: ["zh-Hans", "en"])
    func inspectorTabStripFitsTheNarrowestInspector(language: String) {
        let localizer = Self.both.first { $0.name == language }!.localizer
        for selected in InspectorTab.allCases {
            var total: CGFloat = 0
            for tab in InspectorTab.allCases {
                let accessory: CGFloat = tab == .rules ? 28 + 10 : 0
                if tab == selected {
                    let title = TextMeasure.width(localizer.string(tab.titleKey), size: 12, weight: .medium)
                    // 10 leading, icon about 14, 4 gap, title, 10 (or 4 before the accessory) trailing
                    total += 10 + 14 + 4 + title + (accessory == 0 ? 10 : 4) + accessory
                } else {
                    total += CGFloat(InspectorTabStripPolicy.iconTabWidth) + accessory
                }
            }
            #expect(total + 6 <= 320, "\(language) \(selected): \(total)")
        }
    }

    // MARK: tables

    @Test func tableHeaderColumnKeepsItsWidthForShortTitlesAndGrowsForLongOnes() {
        #expect(TableHeaderMetrics.columnWidth(minimum: 52, title: "启用") == 52)
        #expect(TableHeaderMetrics.columnWidth(minimum: 52, title: "") == 52)
        let enabled = TableHeaderMetrics.columnWidth(minimum: 52, title: "Enabled")
        #expect(enabled > 52)
        #expect(enabled >= TextMeasure.width("Enabled", size: 12) + 26)
    }
}
