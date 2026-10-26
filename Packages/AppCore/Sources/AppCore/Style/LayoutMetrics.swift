import AppKit
import Foundation
import Localization
import RulesEngine

/// Measures text the way the views draw it, so a fixed-width control can be sized from the words it will show
/// (the widest option in the current language) instead of from the Chinese ones it was first drawn for.
public enum TextMeasure {
    /// The width of one line of `text` in the system font.
    public static func width(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width)
    }

    /// The widest of `texts`; 0 for none.
    public static func widest(_ texts: [String], size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
        texts.map { width($0, size: size, weight: weight) }.max() ?? 0
    }
}

/// Widths of the rule editor's dropdowns. Each is the old fixed width (drawn for Chinese) or, when the widest option of
/// the current language needs more, that option plus the dropdown's own chrome. A Chinese UI therefore keeps every old
/// width; an English one grows only where a label would be cut.
public enum RuleBuilderMetrics {
    /// Left and right padding (8 + 8), the chevron (about 11), the gaps around it and the border.
    public static let dropdownChrome: CGFloat = 44
    /// A direction icon (14) and its gap (6) in front of the title.
    public static let iconWidth: CGFloat = 20
    /// The field column of a condition row, and the operator column; the old fixed widths.
    public static let fieldColumnMinimum: CGFloat = 170
    public static let operatorColumnMinimum: CGFloat = 150

    /// `minimum`, or the widest title with the chrome (and `leading` for an icon) when that is more; never above
    /// `maximum` (a longer title is cut and shows a tooltip).
    public static func dropdownWidth(
        minimum: CGFloat, titles: [String], leading: CGFloat = 0, maximum: CGFloat = .infinity
    ) -> CGFloat {
        let needed = TextMeasure.widest(titles, size: 13) + dropdownChrome + leading
        return max(minimum, min(needed, maximum))
    }

    // MARK: condition row

    /// The titles the field dropdown can show without an "old style" tag: the menu's fields.
    public static func menuFieldTitles(localizer: Localizer = L10n.localizer) -> [String] {
        ConditionFieldCatalog.menuFields.map { ConditionPresentation.fieldTitle($0, localizer: localizer) }
    }

    public static func fieldColumnWidth(localizer: Localizer = L10n.localizer) -> CGFloat {
        dropdownWidth(minimum: fieldColumnMinimum, titles: menuFieldTitles(localizer: localizer), leading: iconWidth, maximum: 230)
    }

    /// Every comparison a new or current-style row can offer, over all fields (and the certificate's items); the "old
    /// style" entries a saved row may add are left out, they are cut with a tooltip.
    public static func operatorTitles(localizer: Localizer = L10n.localizer) -> [String] {
        var rows: [ConditionRowDescriptor] = ConditionFieldCatalog.menuFields.map { ConditionRowDescriptor(field: $0, localizer: localizer) }
        for sub in CertificateField.allCases {
            rows.append(ConditionRowDescriptor(field: .certificate, name: sub.rawValue, localizer: localizer))
        }
        var titles: [String] = []
        for row in rows {
            switch row.operatorControl {
            case .none: break
            case .fixed(let text): titles.append(text)
            case .menu: titles += row.operatorControl.items.filter { !$0.isLegacy }.map(\.title)
            }
        }
        return titles
    }

    public static func operatorColumnWidth(localizer: Localizer = L10n.localizer) -> CGFloat {
        dropdownWidth(minimum: operatorColumnMinimum, titles: operatorTitles(localizer: localizer), maximum: 210)
    }

    /// How much wider than in Chinese the field and operator columns are: the editor window's two columns each
    /// need this much more room.
    public static func conditionRowExtraWidth(localizer: Localizer = L10n.localizer) -> CGFloat {
        (fieldColumnWidth(localizer: localizer) - fieldColumnMinimum) + (operatorColumnWidth(localizer: localizer) - operatorColumnMinimum)
    }

    // MARK: action card

    /// The action type dropdown in a card header: ideal width 190, up to 240.
    public static func actionTypeTitles(localizer: Localizer = L10n.localizer) -> [String] {
        ActionType.allCases.map { localizer.string($0.titleKey) }
    }

    public static func actionTypeIdealWidth(localizer: Localizer = L10n.localizer) -> CGFloat {
        dropdownWidth(minimum: 190, titles: actionTypeTitles(localizer: localizer), leading: iconWidth, maximum: 240)
    }

    /// The popover list of action types: icon, title, the "unavailable" mark and the check mark.
    public static func actionTypePickerWidth(localizer: Localizer = L10n.localizer) -> CGFloat {
        max(280, TextMeasure.widest(actionTypeTitles(localizer: localizer), size: 13) + 112)
    }

    /// The popover list of condition fields: icon, title, check mark, scroller.
    public static func fieldListWidth(localizer: Localizer = L10n.localizer) -> CGFloat {
        max(220, TextMeasure.widest(menuFieldTitles(localizer: localizer), size: 13) + 84)
    }

    /// The method dropdown of a card (find and replace, regex, ...): 170 wide at least.
    public static func modeDropdownWidth(_ descriptor: ActionEditorDescriptor) -> CGFloat {
        dropdownWidth(minimum: 170, titles: descriptor.modes.map(\.title), maximum: 260)
    }

    /// The language dropdown of a body editor: 190 wide at least.
    public static func languageDropdownWidth(_ descriptor: ActionEditorDescriptor) -> CGFloat {
        dropdownWidth(minimum: 190, titles: descriptor.languages.map(\.title), maximum: 260)
    }

    /// The predefined response dropdown: 280 wide at least.
    public static func presetDropdownWidth(_ descriptor: ActionEditorDescriptor, current: String) -> CGFloat {
        dropdownWidth(minimum: 280, titles: descriptor.presetGroups.flatMap { $0.map(\.title) } + [current], maximum: 380)
    }

    /// A dropdown over a few fixed titles (scope, path, missing file): the old width or the room for the longest.
    public static func fixedChoiceWidth(minimum: CGFloat, titles: [String]) -> CGFloat {
        dropdownWidth(minimum: minimum, titles: titles, maximum: 320)
    }

    /// The mark color dropdowns (140 wide at least) and their popover list (210).
    public static func markColorTitles(localizer: Localizer = L10n.localizer) -> [String] {
        MarkColorCatalog.choices().map { MarkColorCatalog.title(of: $0, localizer: localizer) }
    }

    /// The swatch in front of a mark color title.
    public static let swatchWidth: CGFloat = 16

    public static func markDropdownWidth(localizer: Localizer = L10n.localizer) -> CGFloat {
        dropdownWidth(minimum: 140, titles: markColorTitles(localizer: localizer), leading: swatchWidth + 6, maximum: 240)
    }

    public static func markListWidth(localizer: Localizer = L10n.localizer) -> CGFloat {
        max(210, TextMeasure.widest(markColorTitles(localizer: localizer), size: 13) + 84)
    }
}

/// The title column of the settings panes (the right-aligned "Port:", "Language:" ...).
public enum SettingsMetrics {
    /// The old fixed width of the column.
    public static let titleColumnMinimum: CGFloat = 95

    /// Every title a `SettingsRow` is given.
    public static let rowTitleKeys = [
        "advancedProxySheet.runningStatus", "advancedProxySheet.portLabel", "advancedProxySheet.advancedLabel",
        "appearancePane.fontSizeLabel", "appearancePane.bodyTabsLabel", "appearancePane.otherLabel",
        "generalPane.contentLayoutLabel", "generalPane.menuBarLabel", "generalPane.truncationLabel",
        "generalPane.behaviorLabel", "generalPane.languageLabel", "privacyPane.dataCollectionLabel",
        "advancedPane.setupLabel", "advancedPane.recordingLabel", "advancedPane.terminalLabel", "toolsPane.copyFormatLabel",
    ]

    /// Wide enough for the longest title on one line, so a title never wraps under its own row.
    public static func titleColumnWidth(localizer: Localizer = L10n.localizer) -> CGFloat {
        let widest = TextMeasure.widest(rowTitleKeys.map { localizer.string($0) }, size: 13)
        return max(titleColumnMinimum, widest + 2)
    }
}

extension SettingsMetrics {
    public static let sidebarMinimum: CGFloat = 180

    public static let pageTitleKeys = [
        "settings.page.general.title", "settings.page.appearance.title", "settings.page.privacy.title",
        "settings.page.trafficControl.title", "settings.page.https.title", "settings.page.tools.title",
        "settings.page.mcp.title", "settings.page.advanced.title",
    ]

    /// The page list on the left: the icon, the title and the list's own insets around the longest page title.
    public static func sidebarWidth(localizer: Localizer = L10n.localizer) -> CGFloat {
        let widest = TextMeasure.widest(pageTitleKeys.map { localizer.string($0) }, size: 13)
        return max(sidebarMinimum, ceil(widest + 70))
    }
}

/// Header cells of the AppKit tables.
public enum TableHeaderMetrics {
    /// The room a header title needs in a column: text, cell margins and the sort arrow.
    public static func columnWidth(minimum: CGFloat, title: String) -> CGFloat {
        guard !title.isEmpty else { return minimum }
        return max(minimum, TextMeasure.width(title, size: 12) + 26)
    }
}
