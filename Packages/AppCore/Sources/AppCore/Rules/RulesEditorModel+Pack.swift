import Foundation
import os
import RulesEngine

private let packLog = Logger(subsystem: "ProxyWoman", category: "RulesPack")

/// Rule pack export, import commit, and templates (R7). Importing only ever adds: the plan already holds the
/// existing groups and rules unchanged plus one disabled wrapper group with everything the pack brought.
extension RulesEditorModel {
    /// Builds a pack of the selected rules and groups (`nil` = everything) from the committed state. Writing it
    /// is the caller's job (`RulePackClient.write`). Reading rules never needs the editor to be idle.
    public func exportPack(ids: Set<UUID>?, client packClient: RulePackClient) async throws -> RulePackExport {
        guard loadState == .loaded else { throw RulePackError.nothingToExport }
        return try await packClient.export(ids, groups, rules)
    }

    /// Saves `plan` (its groups and rules, built by `RulePackTransform.plan` against the committed state) in a
    /// single save. The caller has already copied the plan's assets into the managed store and rewritten the
    /// rules to their ids, and releases them if this returns false. The importer holds `isBusy` while it
    /// copies, so only the load state and an open conflict are checked here.
    func commitImport(_ plan: RulePackImportPlan) async -> Bool {
        guard loadState == .loaded, conflict == nil else {
            error = loadState == .loaded ? .conflict : .notLoaded
            return false
        }
        let snapshot = RuleSnapshot(revision: revision, groups: plan.groups, rules: plan.rules)
        do {
            try snapshot.validateStructure(
                limits: limits, enforcingRuleCount: plan.rules.count > max(limits.ruleCount, rules.count))
        } catch let failure as RuleValidationError {
            error = failure.code == .tooManyRules ? .configurationTooLarge : .invalidRule
            return false
        } catch {
            self.error = .invalidRule
            return false
        }
        guard await commit(plan.rules, groups: plan.groups) else { return false }
        await refreshAssets()
        return true
    }
}

// MARK: built-in templates

extension RulesEditorModel {
    /// Installs the built-in template tree when this version of it was never installed (R8F3): at launch, once the
    /// rules are loaded. Once the stored version is current nothing is added again, so a user who deleted the tree
    /// does not get it back, and there is no command to restore it. Nothing here is the user's doing, so a failure
    /// shows no banner: it is logged, and the next launch tries again. Within one run it is tried once; a conflict (another writer saved first) is retried once from the revision it reports.
    public func installTemplatesIfNeeded(presentation: DefaultTemplatePresentation = DefaultTemplatePresentation()) async {
        guard loadState == .loaded, canMutate, !templateInstallAttempted else { return }
        templateInstallAttempted = true
        let set = presentation.templateSet()
        guard (client.published().templatesVersion ?? 0) < set.version else { return }
        isBusy = true
        defer { endBusy() }
        do {
            let installed: RuleSnapshot
            do {
                installed = try await client.installTemplates(set, presentation.legacy, revision)
            } catch RuleRepositoryError.conflict(let current) {
                // Another writer saved first (for example a rules tool at launch): read what is saved now and try once more.
                if (current.templatesVersion ?? 0) >= set.version {
                    apply(current)
                    return
                }
                installed = try await client.installTemplates(set, presentation.legacy, current.revision)
            }
            apply(installed)
            await refreshAssets()
        } catch {
            packLog.error("Template install skipped this launch: \(String(describing: type(of: error)), privacy: .public)")
        }
    }
}

extension RulesEditorModel {
    /// Built-in template groups and rules are named in the language in effect when they were installed. After a
    /// language change, each one whose name is still exactly a built-in name in another language is renamed to
    /// this language; anything the user renamed keeps its name. One save, or none when nothing matches.
    public func relocalizeTemplates(
        current: DefaultTemplatePresentation = DefaultTemplatePresentation(),
        others: [DefaultTemplatePresentation]
    ) async {
        guard canMutate else { return }
        var groupNames: [UUID: (current: String, others: Set<String>)] = [:]
        for key in DefaultTemplateGroupKey.allCases {
            groupNames[DefaultTemplateCatalog.groupID(key)] = (current.groupName(key), Set(others.map { $0.groupName(key) }))
        }
        var ruleNames: [UUID: (current: String, others: Set<String>)] = [:]
        for key in DefaultTemplateRuleKey.allCases {
            ruleNames[DefaultTemplateCatalog.ruleID(key)] = (current.ruleName(key), Set(others.map { $0.ruleName(key) }))
        }
        var changed = false
        let newGroups = groups.map { group -> RuleGroup in
            guard let names = groupNames[group.id], group.name != names.current, names.others.contains(group.name)
            else { return group }
            changed = true
            var renamed = group
            renamed.name = names.current
            return renamed
        }
        let newRules = rules.map { rule -> Rule in
            guard let names = ruleNames[rule.id], rule.name != names.current, names.others.contains(rule.name)
            else { return rule }
            changed = true
            var renamed = rule
            renamed.name = names.current
            return renamed
        }
        guard changed else { return }
        if !(await commit(newRules, groups: newGroups)) {
            packLog.error("Template names were not relocalized this launch")
        }
    }
}
