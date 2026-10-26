import Foundation
import os

public enum L10n {
    public static let bundle: Bundle = resolveBundle(appBundle: .main) { .module }
    private static let systemLocalizer = Localizer(bundle: bundle, preferredLanguages: Locale.preferredLanguages)
    /// A test seam, process-wide because the code under test also runs on other threads (event loops, queues).
    /// Nothing in the app sets it, so the app always uses the system (or in-app chosen) language.
    private static let testOverride = OSAllocatedUnfairLock<Localizer?>(initialState: nil)
    public static var localizer: Localizer { testOverride.withLock { $0 } ?? systemLocalizer }

    /// Pins the app language for the rest of a test process, so tests that assert one language's text do not depend on
    /// the language of the machine running them.
    package static func pinLanguageForTesting(_ languageCode: String) {
        let localizer = Localizer(bundle: bundle, preferredLanguages: [languageCode])
        testOverride.withLock { $0 = localizer }
    }
    public static var locale: Locale { localizer.locale }

    public static func string(_ key: String) -> String {
        localizer.string(key)
    }

    public static func format(_ key: String, _ arguments: CVarArg...) -> String {
        localizer.format(key, arguments: arguments)
    }

    static func resolveBundle(appBundle: Bundle, developmentBundle: () -> Bundle) -> Bundle {
        if let resources = appBundle.resourceURL,
            let packaged = Bundle(url: resources.appendingPathComponent("Localization.bundle"))
        {
            return packaged
        }
        // Keep this lazy: SwiftPM's accessor can terminate when its build directory is absent.
        return developmentBundle()
    }
}
