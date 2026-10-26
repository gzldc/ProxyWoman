import Foundation

extension LanguageChoice {
    /// The language the interface uses after a restart with this choice, by the same rule `Localizer` applies (ruling
    /// L1-4: only the first preferred language counts, anything but Chinese or English gives Simplified Chinese).
    /// An explicit choice resolves from its own value; "system" from the system's language list, which is
    /// `systemLanguages` (not this app's override, which "system" removes).
    public func resolvedLanguageCode(systemLanguages: [String], bundle: Bundle) -> String {
        Localizer(bundle: bundle, preferredLanguages: overrideValue ?? systemLanguages).languageCode
    }

    /// Whether choosing this changes the language in effect (`currentLanguageCode`, normally
    /// `L10n.localizer.languageCode`) after a restart. Choosing the language already shown needs no restart.
    /// When the system's list is unknown (`nil`), "system" counts as a change: an extra prompt is harmless, a missing
    /// one is not.
    public func changesLanguage(
        from currentLanguageCode: String, systemLanguages: [String]?, bundle: Bundle
    ) -> Bool {
        guard overrideValue != nil || systemLanguages != nil else { return true }
        return resolvedLanguageCode(systemLanguages: systemLanguages ?? [], bundle: bundle) != currentLanguageCode
    }
}

extension LanguagePreference {
    /// The language list the system itself has (Language & Region), not this app's `AppleLanguages` override: the
    /// global domain's list, or `nil` when the system does not publish one (for example under an isolated
    /// `CFFIXED_USER_HOME`). The process's own list is no substitute: it already contains this app's override.
    public static var systemLanguages: [String]? {
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        return global?[key] as? [String]
    }
}
