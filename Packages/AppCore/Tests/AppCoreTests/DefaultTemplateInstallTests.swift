import Foundation
import Localization
import RulesEngine
import Testing

@testable import AppCore

/// R8F3 T1: the launch path installs the built-in template tree once per version, through the model's own
/// default arguments and the production client (no test double for the install itself).
@MainActor @Suite(.productionChinese, .timeLimit(.minutes(2))) struct DefaultTemplateInstallTests {
    private func counted(_ fixture: RulesFixture, _ calls: CallCounter) -> RulesRepositoryClient {
        var client = fixture.client()
        let install = client.installTemplates
        client.installTemplates = { set, legacy, revision in
            calls.increment()
            return try await install(set, legacy, revision)
        }
        return client
    }

    @Test func theLaunchPathInstallsTheTreeOnceWithItsDefaultArguments() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let model = try await loadedModel(fixture, rules: [plainRule("mine")])
        await model.installTemplatesIfNeeded()  // exactly the call the app makes at launch

        let presentation = DefaultTemplatePresentation()
        let top = try #require(model.groups.first { $0.id == DefaultTemplateCatalog.groupID(.root) })
        #expect(top.name == presentation.groupName(.root) && !top.name.contains("rules.defaultTemplate"))
        #expect(!top.enabled && top.parentID == nil && top.order == 1, "after the user's root rule")
        #expect(model.groups.count == 9 && model.rules.count == 1 + 28)
        #expect(model.rules.contains { $0.name == "mine" && $0.enabled })
        #expect(model.canMutate && model.error == nil)
        let snapshot = fixture.repository.provider.current()
        #expect(snapshot.templatesVersion == DefaultTemplateCatalog.currentVersion)
        #expect(snapshot.templatesGroupID == top.id)
        // The Return File example works: its managed file exists and the model knows it.
        let fileRule = try #require(model.rules.first { $0.id == DefaultTemplateCatalog.ruleID(.fileReturnResponse) })
        guard case .returnFile(let file) = fileRule.actions[0].kind else { Issue.record("not a file"); return }
        #expect(await fixture.assets.asset(file.assetID) != nil)
    }

    @Test func everyNameIsResolvedAndDistinctWhereTheReferenceHasDistinctOnes() {
        let presentation = DefaultTemplatePresentation()
        for key in DefaultTemplateGroupKey.allCases {
            #expect(!presentation.groupName(key).isEmpty && !presentation.groupName(key).contains("rules.defaultTemplate"), "\(key)")
        }
        for key in DefaultTemplateRuleKey.allCases {
            #expect(!presentation.ruleName(key).isEmpty && !presentation.ruleName(key).contains("rules.defaultTemplate"), "\(key)")
        }
        #expect(presentation.groupName(.root) == "默认模板")
        #expect(presentation.ruleName(.hideConnectTunnels) == "隐藏 CONNECT 隧道")
        let names = DefaultTemplateRuleKey.allCases.map(presentation.ruleName)
        // Two rules appear in both "map local" groups under one name, as in the reference.
        #expect(Set(names).count == names.count - 2)
    }

    @Test func aConflictAtLaunchIsRetriedOnceFromTheCurrentRevision() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let model = try await loadedModel(fixture)
        let calls = CallCounter()
        var client = fixture.client()
        let install = client.installTemplates
        client.installTemplates = { set, legacy, revision in
            calls.increment()
            // Another writer saved between the model's load and its install.
            if calls.value == 1 {
                _ = try await fixture.repository.save(groups: [], rules: [plainRule("other")], expectedRevision: revision)
            }
            return try await install(set, legacy, revision)
        }
        let racing = RulesEditorModel(client: client, limits: RulesLimits())
        await racing.load()
        _ = model
        await racing.installTemplatesIfNeeded()
        #expect(calls.value == 2)
        #expect(racing.groups.count == 9 && racing.rules.contains { $0.name == "other" })
        #expect(racing.error == nil)
    }

    @Test func aSecondConflictGivesUpUntilTheNextLaunch() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        _ = try await loadedModel(fixture)
        let calls = CallCounter()
        var client = fixture.client()
        client.installTemplates = { _, _, _ in
            calls.increment()
            throw RuleRepositoryError.conflict(current: RuleSnapshot(revision: UInt64(calls.value), rules: []))
        }
        let model = RulesEditorModel(client: client, limits: RulesLimits())
        await model.load()
        await model.installTemplatesIfNeeded()
        #expect(calls.value == 2)
        #expect(model.groups.isEmpty && model.error == nil)
    }

    @Test func templatesInstalledInEnglishAreRenamedToChineseButUserNamesStay() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let english = DefaultTemplatePresentation(localizer: Localizer(bundle: L10n.bundle, preferredLanguages: ["en"]))
        let model = try await loadedModel(fixture)
        await model.installTemplatesIfNeeded(presentation: english)
        let hide = DefaultTemplateCatalog.ruleID(.hideConnectTunnels)
        #expect(model.rules.first { $0.id == hide }?.name == english.ruleName(.hideConnectTunnels))
        // The user renamed one rule; it must survive.
        let blockID = DefaultTemplateCatalog.ruleID(.blockProcesses)
        var renamed = model.rules
        if let index = renamed.firstIndex(where: { $0.id == blockID }) { renamed[index].name = "My block list" }
        #expect(await model.commit(renamed, groups: model.groups))

        await model.relocalizeTemplates(others: [english])
        let chinese = DefaultTemplatePresentation()
        #expect(model.rules.first { $0.id == hide }?.name == "隐藏 CONNECT 隧道")
        #expect(model.groups.first { $0.id == DefaultTemplateCatalog.groupID(.root) }?.name == chinese.groupName(.root))
        #expect(model.rules.first { $0.id == blockID }?.name == "My block list")
        let revision = model.revision
        await model.relocalizeTemplates(others: [english])
        #expect(model.revision == revision, "nothing left to rename, so nothing is saved")
    }

    @Test func aSecondLaunchDoesNotInstallAgain() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let calls = CallCounter()
        let model = try await loadedModel(fixture, client: counted(fixture, calls))
        await model.installTemplatesIfNeeded()
        await model.installTemplatesIfNeeded()  // within a run: tried once
        #expect(calls.value == 1)
        let revision = model.revision

        let next = RulesEditorModel(client: counted(fixture, calls), limits: RulesLimits())
        await next.load()
        await next.installTemplatesIfNeeded()
        #expect(calls.value == 1, "the stored version is current, so the install is not even asked for")
        #expect(next.revision == revision && next.groups.count == 9)
    }

    @Test func aDeletedTreeStaysDeletedAfterRelaunch() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let model = try await loadedModel(fixture)
        await model.installTemplatesIfNeeded()
        #expect(model.groups.count == 9)
        _ = try await fixture.repository.save(groups: [], rules: [], expectedRevision: model.revision)

        let relaunched = RulesEditorModel(client: fixture.client(), limits: RulesLimits())
        await relaunched.load()
        await relaunched.installTemplatesIfNeeded()
        #expect(relaunched.groups.isEmpty && relaunched.rules.isEmpty)
        #expect(relaunched.error == nil && relaunched.canMutate)
    }

    @Test func aRoundOneUserWithTheFlagButNoTreeGetsItOnce() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.configDir, withIntermediateDirectories: true)
        try Data(#"{"assets":[],"groups":[],"revision":4,"rules":[],"schemaVersion":4,"templatesInstalled":true}"#.utf8)
            .write(to: fixture.configFile)
        let calls = CallCounter()
        let model = RulesEditorModel(client: counted(fixture, calls), limits: RulesLimits())
        await model.load()
        #expect(model.groups.isEmpty)
        await model.installTemplatesIfNeeded()
        #expect(model.groups.count == 9 && model.rules.count == 28)
        let again = RulesEditorModel(client: counted(fixture, calls), limits: RulesLimits())
        await again.load()
        await again.installTemplatesIfNeeded()
        #expect(calls.value == 1 && again.groups.count == 9)
    }

    @Test func anUntouchedFirstGenerationGroupIsReplacedByTheNewTree() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let old = DefaultTemplatePresentation().legacy
        let (group, rules) = legacyInstall(old)
        let model = try await loadedModel(fixture, groups: [group], rules: rules)
        await model.installTemplatesIfNeeded()
        #expect(!model.groups.contains { $0.id == group.id })
        #expect(model.groups.count == 9 && model.rules.count == 28)
    }

    @Test func anEditedFirstGenerationGroupStaysAndTheNewTreeIsAdded() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let old = DefaultTemplatePresentation().legacy
        let (group, installedRules) = legacyInstall(old)
        var rules = installedRules
        rules[4].enabled = true  // the group is as installed; one rule was switched on
        let model = try await loadedModel(fixture, groups: [group], rules: rules)
        await model.installTemplatesIfNeeded()
        #expect(model.groups.contains { $0.id == group.id } && model.groups.count == 10)
        #expect(model.rules.count == 15 + 28)
        #expect(model.rules.first { $0.id == rules[4].id }?.enabled == true)
    }

    @Test func aFailureIsSilentAndRetriedNextLaunch() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let calls = CallCounter()
        var failing = fixture.client()
        failing.installTemplates = { _, _, _ in
            calls.increment()
            throw RuleRepositoryError.revisionExhausted
        }
        let model = try await loadedModel(fixture, rules: [plainRule("mine")], client: failing)
        await model.installTemplatesIfNeeded()
        await model.installTemplatesIfNeeded()
        #expect(calls.value == 1)
        #expect(model.error == nil && model.canMutate && model.groups.isEmpty && model.rules.count == 1)

        let next = RulesEditorModel(client: fixture.client(), limits: RulesLimits())
        await next.load()
        await next.installTemplatesIfNeeded()
        #expect(next.groups.count == 9)
    }

    @Test func nothingHappensBeforeTheRulesAreLoaded() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let calls = CallCounter()
        let model = RulesEditorModel(client: counted(fixture, calls), limits: RulesLimits())
        await model.installTemplatesIfNeeded()
        #expect(calls.value == 0)
    }

    @Test func aClientWithoutAnInstallClosureIsSilent() async throws {
        let fixture = RulesFixture(); defer { fixture.remove() }
        let base = fixture.client()
        let bare = RulesRepositoryClient(
            load: base.load, save: base.save, reset: base.reset, importFile: base.importFile,
            discardImports: base.discardImports, asset: base.asset, published: base.published,
            importStream: base.importStream, acknowledgeNotice: base.acknowledgeNotice,
            installTemplates: { _, _, _ in throw RuleRepositoryError.notLoaded })
        let model = try await loadedModel(fixture, client: bare)
        await model.installTemplatesIfNeeded()
        #expect(model.error == nil && model.groups.isEmpty)
    }

    @Test func theMarkTemplatesUseCataloguedColours() throws {
        let presentation = DefaultTemplatePresentation()
        let set = presentation.templateSet()
        func background(_ key: DefaultTemplateRuleKey) throws -> String {
            let rule = try #require(set.rules.first { $0.id == DefaultTemplateCatalog.ruleID(key) })
            guard case .mark(let mark) = rule.actions[0].kind else { throw CocoaError(.fileReadUnknown) }
            return mark.background
        }
        #expect(try background(.markLongLivingSessions) == MarkColorCatalog.entry(id: "fuchsia")?.stored)
        #expect(try background(.markScriptsAndJSON) == MarkColorCatalog.entry(id: "aqua")?.stored)
    }

    /// The group and rules a build before this round installed, in the language of `texts`.
    private func legacyInstall(_ texts: LegacyTemplateTexts) -> (RuleGroup, [Rule]) {
        let group = RuleGroup(id: UUID(), name: texts.groupName, enabled: false, parentID: nil, order: 0)
        let rules = RuleTemplate.allCases.enumerated().map { index, template in
            RuleTemplateCatalog.rule(
                template, name: texts.names[template] ?? "", note: texts.notes[template] ?? "", order: index,
                groupID: group.id)
        }
        return (group, rules)
    }
}
