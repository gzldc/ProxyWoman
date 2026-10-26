import Foundation

/// Resolves one language from the bundle's resources, falling back per missing key.
public struct Localizer: Sendable {
    private let languageBundle: Bundle?
    private let fallbackBundle: Bundle?
    public let languageCode: String
    public let locale: Locale
    public let supportedLanguageCodes: [String]

    public init(bundle: Bundle, preferredLanguages: [String], fallbackLanguage: String = "zh-Hans") {
        let resourceLanguages = bundle.localizations.filter { $0 != "Base" }
        let languages = resourceLanguages.map { Locale.canonicalLanguageIdentifier(from: $0) }
        supportedLanguageCodes = Array(Set(languages)).sorted()
        let fallback = Locale.canonicalLanguageIdentifier(from: fallbackLanguage)
        // Only the first preferred language counts: a list such as ["fr", "en"] must not skip an
        // unsupported first language and land on the second. Anything else gets the fallback.
        languageCode =
            Bundle.preferredLocalizations(
                from: supportedLanguageCodes,
                forPreferences: Array(preferredLanguages.prefix(1)) + [fallback]
            ).first ?? fallback
        locale = Locale(identifier: languageCode)

        func localizedBundle(for code: String) -> Bundle? {
            guard
                let resourceLanguage = resourceLanguages.first(where: {
                    Locale.canonicalLanguageIdentifier(from: $0) == code
                }), let url = bundle.url(forResource: resourceLanguage, withExtension: "lproj")
            else {
                return nil
            }
            return Bundle(url: url)
        }
        languageBundle = localizedBundle(for: languageCode)
        fallbackBundle = localizedBundle(for: fallback)
    }

    public func string(_ key: String) -> String {
        // An explicit value distinguishes a missing entry from a translation equal to its key.
        let missing = "\u{0}missing-localization\u{0}"
        if let value = languageBundle?.localizedString(forKey: key, value: missing, table: "Localizable"),
            value != missing
        {
            return value
        }
        return fallbackBundle?.localizedString(forKey: key, value: key, table: "Localizable") ?? key
    }

    public func format(_ key: String, arguments: [CVarArg]) -> String {
        String(format: string(key), locale: locale, arguments: arguments)
    }
}
