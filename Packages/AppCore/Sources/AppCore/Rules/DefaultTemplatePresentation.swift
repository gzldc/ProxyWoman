import Foundation
import Localization
import RulesEngine

/// The localized names the built-in template tree is written with: one whole string per group and per rule,
/// resolved when the set is installed (the engine knows no language), plus the texts of the first template
/// generation, which are needed only to recognise an untouched copy of it.
public struct DefaultTemplatePresentation: Sendable {
    private let groupNames: [DefaultTemplateGroupKey: String]
    private let ruleNames: [DefaultTemplateRuleKey: String]
    public let legacy: LegacyTemplateTexts

    public init(localizer: Localizer = L10n.localizer) {
        var groups: [DefaultTemplateGroupKey: String] = [:]
        for key in DefaultTemplateGroupKey.allCases { groups[key] = Self.groupName(key, localizer) }
        var rules: [DefaultTemplateRuleKey: String] = [:]
        for key in DefaultTemplateRuleKey.allCases { rules[key] = Self.ruleName(key, localizer) }
        groupNames = groups
        ruleNames = rules
        legacy = LegacyTemplateTexts(
            groupName: localizer.string("rules.template.group"),
            name: { Self.legacyName($0, localizer) }, note: { Self.legacyNote($0, localizer) })
    }

    public func groupName(_ key: DefaultTemplateGroupKey) -> String { groupNames[key] ?? "" }
    public func ruleName(_ key: DefaultTemplateRuleKey) -> String { ruleNames[key] ?? "" }

    /// The tree to install, named in this language.
    public func templateSet() -> DefaultTemplateSet {
        DefaultTemplateCatalog.build(groupName: { groupName($0) }, ruleName: { ruleName($0) })
    }

    private static func groupName(_ key: DefaultTemplateGroupKey, _ localizer: Localizer) -> String {
        switch key {
        case .root: localizer.string("rules.defaultTemplate.group.root")
        case .allowBlock: localizer.string("rules.defaultTemplate.group.allowBlock")
        case .filters: localizer.string("rules.defaultTemplate.group.filters")
        case .mapTraffic: localizer.string("rules.defaultTemplate.group.mapTraffic")
        case .mapLocalManual: localizer.string("rules.defaultTemplate.group.mapLocalManual")
        case .mapLocalFile: localizer.string("rules.defaultTemplate.group.mapLocalFile")
        case .modifyTraffic: localizer.string("rules.defaultTemplate.group.modifyTraffic")
        case .tooling: localizer.string("rules.defaultTemplate.group.tooling")
        case .uiMarks: localizer.string("rules.defaultTemplate.group.uiMarks")
        }
    }

    private static func ruleName(_ key: DefaultTemplateRuleKey, _ localizer: Localizer) -> String {
        switch key {
        case .allowOnlyProcesses: localizer.string("rules.defaultTemplate.rule.allowOnlyProcesses")
        case .allowOnlyHosts: localizer.string("rules.defaultTemplate.rule.allowOnlyHosts")
        case .blockProcesses: localizer.string("rules.defaultTemplate.rule.blockProcesses")
        case .blockHosts: localizer.string("rules.defaultTemplate.rule.blockHosts")
        case .hideConnectTunnels: localizer.string("rules.defaultTemplate.rule.hideConnectTunnels")
        case .hideProcesses: localizer.string("rules.defaultTemplate.rule.hideProcesses")
        case .hideHosts: localizer.string("rules.defaultTemplate.rule.hideHosts")
        case .showOnlyProcesses: localizer.string("rules.defaultTemplate.rule.showOnlyProcesses")
        case .showOnlyHosts: localizer.string("rules.defaultTemplate.rule.showOnlyHosts")
        case .showOnlyLocalhost: localizer.string("rules.defaultTemplate.rule.showOnlyLocalhost")
        case .hideConnectsOfBlockedProcesses: localizer.string("rules.defaultTemplate.rule.hideConnectsOfBlockedProcesses")
        case .mapRemoteLocalhost: localizer.string("rules.defaultTemplate.rule.mapRemoteLocalhost")
        case .mapRemoteURL: localizer.string("rules.defaultTemplate.rule.mapRemoteURL")
        case .redirect307: localizer.string("rules.defaultTemplate.rule.redirect307")
        case .manualReturnConnect: localizer.string("rules.defaultTemplate.rule.manualReturnConnect")
        case .manualReturnResponse: localizer.string("rules.defaultTemplate.rule.manualReturnResponse")
        case .fileReturnConnect: localizer.string("rules.defaultTemplate.rule.fileReturnConnect")
        case .fileReturnResponse: localizer.string("rules.defaultTemplate.rule.fileReturnResponse")
        case .insertHTMLRegex: localizer.string("rules.defaultTemplate.rule.insertHTMLRegex")
        case .insertHTML: localizer.string("rules.defaultTemplate.rule.insertHTML")
        case .modifyImageEndpoint: localizer.string("rules.defaultTemplate.rule.modifyImageEndpoint")
        case .userAgentChromeMac: localizer.string("rules.defaultTemplate.rule.userAgentChromeMac")
        case .userAgentChromeWindows: localizer.string("rules.defaultTemplate.rule.userAgentChromeWindows")
        case .bypassCORS: localizer.string("rules.defaultTemplate.rule.bypassCORS")
        case .noCaching: localizer.string("rules.defaultTemplate.rule.noCaching")
        case .blockCookies: localizer.string("rules.defaultTemplate.rule.blockCookies")
        case .markLongLivingSessions: localizer.string("rules.defaultTemplate.rule.markLongLivingSessions")
        case .markScriptsAndJSON: localizer.string("rules.defaultTemplate.rule.markScriptsAndJSON")
        }
    }

    private static func legacyName(_ template: RuleTemplate, _ localizer: Localizer) -> String {
        switch template {
        case .simulate404: localizer.string("rules.template.simulate404.name")
        case .simulate500: localizer.string("rules.template.simulate500.name")
        case .simulate429: localizer.string("rules.template.simulate429.name")
        case .addCORSHeaders: localizer.string("rules.template.addCORSHeaders.name")
        case .disableCaching: localizer.string("rules.template.disableCaching.name")
        case .delay2Seconds: localizer.string("rules.template.delay2Seconds.name")
        case .markDomain: localizer.string("rules.template.markDomain.name")
        case .httpToHttps: localizer.string("rules.template.httpToHttps.name")
        case .recordAllPOST: localizer.string("rules.template.recordAllPOST.name")
        case .blockAnalytics: localizer.string("rules.template.blockAnalytics.name")
        case .breakpointPUT: localizer.string("rules.template.breakpointPUT.name")
        case .stripAuthorization: localizer.string("rules.template.stripAuthorization.name")
        case .forceStatus200: localizer.string("rules.template.forceStatus200.name")
        case .hideNoise: localizer.string("rules.template.hideNoise.name")
        case .closeConnection: localizer.string("rules.template.closeConnection.name")
        }
    }

    private static func legacyNote(_ template: RuleTemplate, _ localizer: Localizer) -> String {
        switch template {
        case .simulate404: localizer.string("rules.template.simulate404.note")
        case .simulate500: localizer.string("rules.template.simulate500.note")
        case .simulate429: localizer.string("rules.template.simulate429.note")
        case .addCORSHeaders: localizer.string("rules.template.addCORSHeaders.note")
        case .disableCaching: localizer.string("rules.template.disableCaching.note")
        case .delay2Seconds: localizer.string("rules.template.delay2Seconds.note")
        case .markDomain: localizer.string("rules.template.markDomain.note")
        case .httpToHttps: localizer.string("rules.template.httpToHttps.note")
        case .recordAllPOST: localizer.string("rules.template.recordAllPOST.note")
        case .blockAnalytics: localizer.string("rules.template.blockAnalytics.note")
        case .breakpointPUT: localizer.string("rules.template.breakpointPUT.note")
        case .stripAuthorization: localizer.string("rules.template.stripAuthorization.note")
        case .forceStatus200: localizer.string("rules.template.forceStatus200.note")
        case .hideNoise: localizer.string("rules.template.hideNoise.note")
        case .closeConnection: localizer.string("rules.template.closeConnection.note")
        }
    }
}
