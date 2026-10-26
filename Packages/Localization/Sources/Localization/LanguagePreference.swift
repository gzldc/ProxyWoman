import Foundation

/// The interface language the user picked in the app.
public enum LanguageChoice: String, CaseIterable, Sendable {
    /// No override: the system language list applies.
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    /// The `AppleLanguages` value that selects this choice; nil removes the override.
    var overrideValue: [String]? {
        switch self {
        case .system: nil
        case .simplifiedChinese: ["zh-Hans"]
        case .english: ["en"]
        }
    }

    /// A language name in that language itself, as macOS lists languages; nil for `.system`
    /// (its label is a localized string).
    public var nativeName: String? {
        switch self {
        case .system: nil
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        }
    }
}

/// The language override in the standard macOS place: the app domain's `AppleLanguages`.
/// "System" removes the key so the global language list applies again. Reading looks at the app
/// domain only, never at the global list, so a system language is never mistaken for a choice.
///
/// The domain is a parameter so a test can use an isolated suite; the app uses `standard`.
public struct LanguagePreference {
    public static let key = "AppleLanguages"

    private let defaults: UserDefaults
    private let domainName: String

    /// `domainName` is the persistent domain `defaults` writes to: the bundle identifier for
    /// `UserDefaults.standard`, the suite name for `UserDefaults(suiteName:)`.
    public init(defaults: UserDefaults, domainName: String) {
        self.defaults = defaults
        self.domainName = domainName
    }

    /// The preference of this process: the standard defaults and the main bundle's identifier.
    public static var standard: LanguagePreference {
        LanguagePreference(
            defaults: .standard, domainName: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName)
    }

    public var choice: LanguageChoice {
        get {
            let stored = defaults.persistentDomain(forName: domainName)?[Self.key] as? [String]
            switch stored?.first.map(Self.family) {
            case "zh": return .simplifiedChinese
            case "en": return .english
            default: return .system
            }
        }
        nonmutating set {
            // Always replaced as a whole, so no earlier value survives next to the new one.
            if let value = newValue.overrideValue {
                defaults.set(value, forKey: Self.key)
            } else {
                defaults.removeObject(forKey: Self.key)
            }
        }
    }

    private static func family(_ identifier: String) -> String {
        Locale(identifier: identifier).language.languageCode?.identifier ?? identifier
    }
}
