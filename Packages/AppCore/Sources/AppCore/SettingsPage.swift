import Foundation
import Localization

/// Shared with AppModel so menu actions can prepare a destination before openSettings().
public enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    case appearance
    case privacy
    case trafficControl
    case https
    case tools
    case mcp
    case advanced
    public var id: Self { self }
    public var icon: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .privacy: "hand.raised"
        case .trafficControl: "network"
        case .https: "lock.shield"
        case .tools: "hammer"
        case .mcp: "sparkles"
        case .advanced: "slider.horizontal.3"
        }
    }
    public var title: String { title(using: L10n.localizer) }
    public func title(using localizer: Localizer) -> String { localizer.string(titleKey) }
    public func keywords(using localizer: Localizer) -> String { localizer.string(keywordsKey) }
    var titleKey: String {
        switch self {
        case .general: "settings.page.general.title"
        case .appearance: "settings.page.appearance.title"
        case .privacy: "settings.page.privacy.title"
        case .trafficControl: "settings.page.trafficControl.title"
        case .https: "settings.page.https.title"
        case .tools: "settings.page.tools.title"
        case .mcp: "settings.page.mcp.title"
        case .advanced: "settings.page.advanced.title"
        }
    }
    var keywordsKey: String {
        switch self {
        case .general: "settings.page.general.keywords"
        case .appearance: "settings.page.appearance.keywords"
        case .privacy: "settings.page.privacy.keywords"
        case .trafficControl: "settings.page.trafficControl.keywords"
        case .https: "settings.page.https.keywords"
        case .tools: "settings.page.tools.keywords"
        case .mcp: "settings.page.mcp.keywords"
        case .advanced: "settings.page.advanced.keywords"
        }
    }
    public func matches(_ query: String, using localizer: Localizer = L10n.localizer) -> Bool {
        query.isEmpty
            || (title(using: localizer) + " " + keywords(using: localizer))
                .range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: localizer.locale) != nil
    }
}
