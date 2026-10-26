import AppCore
import FlowStore
import Foundation
import RulesEngine
import Testing
@testable import ProxyWoman

/// Rules 2.0 R1, Task 11: the main window's one-time banner for the upgrade notice. Whether the user closed
/// it is a preference (`rulesUpgradeBannerDismissed`): kept in the user defaults, or in memory only in an
/// isolated launch. Whether the notice was read is the rules file's business (`acknowledged`); the banner
/// shows only while the notice is unread and was not closed. No server is started; the models are isolated.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)), .productionChinese) struct RulesUpgradeBannerSettingTests {
    private static let key = "rulesUpgradeBannerDismissed"

    private struct StoredFile: Encodable {
        var schemaVersion = 4
        var revision: UInt64 = 3
        var groups: [RuleGroup] = []
        var rules: [Rule]
        var assets: [ManagedAsset] = []
        var templatesInstalled = false
        var migrationNotice: MigrationNotice?
    }

    private func isolatedRuntime(in base: URL) throws -> AppRuntime {
        let root = base.appendingPathComponent("root", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        return try AppRuntime.resolve(
            arguments: ["/app", IsolatedLaunch.rootArgument, root.path], environment: ["CFFIXED_USER_HOME": home.path],
            bundleIdentifier: "dev.pwapp.mac.t12a-copy", temporaryDirectories: [base], home: home,
            commandRunner: RecordingCommandRunner(), trust: TrustRecorder().operations)
    }

    private func rule(_ name: String, order: Int) -> Rule {
        Rule(
            id: UUID(), name: name, enabled: true, order: order, matcher: RuleMatcher(hostPattern: "a.test"),
            action: .rewriteStatus(RewriteStatusAction(status: 500)))
    }

    /// Runs `body` with an isolated model whose rules file already holds `notice` (none: no file at all),
    /// after the editor has read it. The model is shut down afterwards.
    private func withModel(
        notice: MigrationNotice?, writesFile: Bool = true,
        _ body: (AppModel, AppRuntime) async throws -> Void
    ) async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("rules-banner-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let runtime = try isolatedRuntime(in: base)
        if writesFile {
            let first = rule("A", order: 0), second = rule("B", order: 1)
            try FileManager.default.createDirectory(at: runtime.layout.rules, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(StoredFile(rules: [first, second], migrationNotice: notice))
                .write(to: runtime.layout.rules.appendingPathComponent("rules.json"))
        }
        let model = AppModel(runtime: runtime)
        do {
            await model.rulesEditor.load()
            #expect(model.rulesEditor.loadState == .loaded)
            try await body(model, runtime)
        } catch {
            model.shutdown()
            throw error
        }
        model.shutdown()
    }

    private func unreadNotice(acknowledged: Bool = false) -> MigrationNotice {
        MigrationNotice(
            report: MigrationReport(pairs: [MigrationPair(changeClass: .finalAction, higherRuleID: UUID(), lowerRuleID: UUID())]),
            migratedFromSchema: 3, acknowledged: acknowledged)
    }

    // MARK: the setting

    @Test func dismissalPersistsOutsideIsolatedMode() throws {
        let suite = "pw-banner-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = AppSettings(defaults: defaults)
        #expect(!first.rulesUpgradeBannerDismissed, "nothing stored: the banner has not been closed")
        first.rulesUpgradeBannerDismissed = true
        #expect(defaults.object(forKey: Self.key) as? Bool == true, "written under its own key")

        let relaunched = AppSettings(defaults: defaults)
        #expect(relaunched.rulesUpgradeBannerDismissed)
    }

    @Test func dismissalIsInMemoryInIsolatedMode() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("rules-banner-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let runtime = try isolatedRuntime(in: base)
        #expect(runtime.settingsStorage is InMemorySettingsStorage)
        let standardBefore = UserDefaults.standard.object(forKey: Self.key) as? Bool

        let settings = AppSettings(defaults: runtime.settingsStorage)
        #expect(!settings.rulesUpgradeBannerDismissed)
        settings.rulesUpgradeBannerDismissed = true
        #expect(runtime.settingsStorage.bool(forKey: Self.key), "kept for this run")
        #expect(AppSettings(defaults: runtime.settingsStorage).rulesUpgradeBannerDismissed)

        // It never reaches the standard preferences, and the next isolated launch starts without it.
        #expect(UserDefaults.standard.object(forKey: Self.key) as? Bool == standardBefore)
        #expect(!AppSettings(defaults: InMemorySettingsStorage()).rulesUpgradeBannerDismissed)
    }

    // MARK: the banner

    @Test func bannerShowsOnlyWhileNoticeUnacknowledgedAndNotDismissed() async throws {
        // No notice: no banner.
        try await withModel(notice: nil) { model, _ in
            #expect(model.rulesEditor.migrationNotice == nil)
            #expect(!model.showsRulesUpgradeBanner)
        }
        try await withModel(notice: nil, writesFile: false) { model, _ in
            #expect(!model.showsRulesUpgradeBanner)
        }
        // A notice that lists nothing: none either.
        try await withModel(notice: MigrationNotice(report: MigrationReport(pairs: []), migratedFromSchema: 3)) { model, _ in
            #expect(!model.showsRulesUpgradeBanner)
        }
        // Already read: none.
        try await withModel(notice: unreadNotice(acknowledged: true)) { model, _ in
            #expect(!model.showsRulesUpgradeBanner)
        }

        // Unread and not closed: shown. Closing it keeps the notice unread, and the banner stays closed.
        try await withModel(notice: unreadNotice()) { model, runtime in
            #expect(model.showsRulesUpgradeBanner)
            model.dismissRulesUpgradeBanner()
            #expect(!model.showsRulesUpgradeBanner)
            #expect(model.settings.rulesUpgradeBannerDismissed && runtime.settingsStorage.bool(forKey: Self.key))
            #expect(model.rulesEditor.hasUnreadUpgradeNotice && model.rulesEditor.showsUpgradeNotice, "the window still has the notice")
        }

        // Unread and not closed, then read in the rules window: the banner goes without being closed.
        try await withModel(notice: unreadNotice()) { model, runtime in
            #expect(model.showsRulesUpgradeBanner)
            await model.rulesEditor.acknowledgeUpgradeNotice()
            #expect(!model.showsRulesUpgradeBanner)
            #expect(!model.settings.rulesUpgradeBannerDismissed && !runtime.settingsStorage.bool(forKey: Self.key))
            // Viewing the notes again from the window does not bring the banner back.
            model.rulesEditor.reopenUpgradeNotice()
            #expect(model.rulesEditor.showsUpgradeNotice && !model.showsRulesUpgradeBanner)
        }
    }
}
