import Foundation
import Localization
import Testing

/// Runs a suite with Chinese as the app language, whatever language the machine uses.
/// Production has two languages now, so a test that asserts Chinese text through the app's default
/// language must say so instead of relying on the fallback for an unsupported system language.
/// The language stays pinned for the rest of the test process (the code under test also runs on other threads);
/// tests that need another language use an explicit `Localizer`.
struct ProductionChineseTrait: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        L10n.pinLanguageForTesting("zh-Hans")
        try await function()
    }
}

extension Trait where Self == ProductionChineseTrait {
    static var productionChinese: Self { Self() }
}
