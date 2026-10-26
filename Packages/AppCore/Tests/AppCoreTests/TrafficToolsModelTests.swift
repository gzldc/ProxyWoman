import Foundation
import FlowStore
import RulesEngine
import Testing
@testable import AppCore

extension Result {
    fileprivate var failure: Failure? {
        if case .failure(let error) = self { error } else { nil }
    }
}

@MainActor private final class Persisted {
    var saved: [TrafficPolicy] = []
}

@MainActor private func makeModel(
    initial: TrafficPolicy = TrafficPolicy()
) -> (model: TrafficToolsModel, provider: TrafficPolicyProvider, persisted: Persisted) {
    let provider = TrafficPolicyProvider()
    let persisted = Persisted()
    let model = TrafficToolsModel(provider: provider, initial: initial) { persisted.saved.append($0) }
    return (model, provider, persisted)
}

@MainActor @Suite(.productionChinese) struct TrafficToolsModelTests {
    @Test func initResetsSessionOnlyToggles() throws {
        var initial = TrafficPolicy()
        initial.noCaching = true
        initial.allowEnabled = true
        initial.allowEntries = [TrafficFilterEntry(matcher: RuleMatcher(hostPattern: "a.com"))]
        initial.blockEnabled = true
        initial.blockMode = .hide
        initial.conditions.enabled = true
        initial.conditions.global = .preset(.threeG)
        initial.conditions.hostRules = [HostNetworkRule(hostPattern: "b.com", selection: .preset(.edge))]
        let (model, provider, persisted) = makeModel(initial: initial)

        for policy in [model.policy, provider.current()] {
            #expect(!policy.noCaching)
            #expect(!policy.conditions.enabled)
            #expect(policy.allowEnabled && policy.blockEnabled && policy.blockMode == .hide)
            #expect(policy.allowEntries == initial.allowEntries)
            #expect(policy.conditions.global == .preset(.threeG))
            #expect(policy.conditions.hostRules == initial.conditions.hostRules)
        }
        #expect(persisted.saved.isEmpty)
    }

    @Test func mutationsValidatePublishAndPersist() throws {
        let (model, provider, persisted) = makeModel()
        let start = provider.revision

        model.setAllowEnabled(true)
        #expect(provider.revision == start + 1 && provider.current().allowEnabled)
        model.setBlockEnabled(true)
        model.setBlockMode(.hide)
        model.setNoCaching(true)
        model.setConditionsEnabled(true)
        #expect(provider.revision == start + 5)
        let after = provider.current()
        #expect(after.blockEnabled && after.blockMode == .hide && after.noCaching && after.conditions.enabled)
        #expect(model.policy == after)
        #expect(persisted.saved.count == 5)
        #expect(persisted.saved.last == after)

        let entry = try model.addAllow(host: "a.com", port: 443).get()
        #expect(provider.revision == start + 6)
        #expect(persisted.saved.last?.allowEntries == [entry])
        #expect(model.policy.allowEntries == [entry])
    }

    @Test func invalidEntryLeavesEverythingUntouched() throws {
        let (model, provider, persisted) = makeModel()
        model.setAllowEnabled(true)
        let before = model.policy
        let revision = provider.revision
        let saves = persisted.saved.count

        for result in [
            model.addAllow(host: "bad host!", port: nil),
            model.addAllow(host: "a.com", port: 70_000),
            model.addAllow(host: "   ", port: nil),
            model.addBlock(host: "a.com", port: nil, scheme: "ftp", method: nil, pathPrefix: nil),
            model.addBlock(host: "a.com", port: nil, scheme: nil, method: "BAD METHOD", pathPrefix: nil),
            model.addBlock(host: "a.com", port: nil, scheme: nil, method: nil, pathPrefix: "/a b"),
            model.addBlock(host: "", port: nil, scheme: nil, method: nil, pathPrefix: nil),
        ] {
            guard case .failure = result else {
                Issue.record("expected failure")
                continue
            }
        }
        let hostError = model.addAllow(host: "bad host!", port: nil)
        guard case .failure(let error) = hostError else { Issue.record("expected failure"); return }
        #expect(error.code == .invalidHostPattern && error.list == .allow)
        guard case .failure(let portError) = model.addAllow(host: "a.com", port: 0) else {
            Issue.record("expected failure"); return
        }
        #expect(portError.code == .invalidPort)
        guard case .failure(let schemeError) = model.addBlock(
            host: "a.com", port: nil, scheme: "ftp", method: nil, pathPrefix: nil) else {
            Issue.record("expected failure"); return
        }
        #expect(schemeError.code == .invalidScheme && schemeError.list == .block)
        #expect(model.policy == before)
        #expect(provider.current() == before)
        #expect(provider.revision == revision)
        #expect(persisted.saved.count == saves)
    }

    @Test func listsAreCappedAtTheEntryLimit() throws {
        let (model, provider, persisted) = makeModel()
        for index in 0..<TrafficPolicy.maxEntries {
            _ = try model.addAllow(host: "h\(index).example.com", port: nil).get()
        }
        let revision = provider.revision
        let saves = persisted.saved.count
        guard case .failure(let error) = model.addAllow(host: "over.example.com", port: nil) else {
            Issue.record("expected failure"); return
        }
        #expect(error.code == .tooManyEntries && error.list == .allow)
        #expect(provider.revision == revision && persisted.saved.count == saves)
        #expect(model.policy.allowEntries.count == TrafficPolicy.maxEntries)
    }

    @Test func addAllowNormalizesHost() throws {
        let (model, provider, _) = makeModel()
        let entry = try model.addAllow(host: " API.Example.COM. ", port: nil).get()
        #expect(entry.matcher.hostPattern == "api.example.com")
        #expect(entry.matcher.port == nil && entry.enabled)
        #expect(provider.current().allowEntries == [entry])
        let wildcard = try model.addAllow(host: "*.Example.com", port: 8443).get()
        #expect(wildcard.matcher.hostPattern == "*.example.com" && wildcard.matcher.port == 8443)
    }

    @Test func addBlockBuildsTheMatcherAndTreatsEmptyFieldsAsAbsent() throws {
        let (model, provider, _) = makeModel()
        let plain = try model.addBlock(host: "Ads.Example.com", port: nil, scheme: "", method: " ", pathPrefix: "").get()
        #expect(plain.matcher == RuleMatcher(hostPattern: "ads.example.com"))
        let full = try model.addBlock(host: "x.com", port: 80, scheme: "http", method: "POST", pathPrefix: "/api").get()
        #expect(full.matcher == RuleMatcher(scheme: "http", hostPattern: "x.com", port: 80, method: "POST", path: .prefix("/api")))
        #expect(provider.current().blockEntries == [plain, full])
        #expect(model.policy.allowEntries.isEmpty)
    }

    @Test func entriesCanBeToggledAndRemoved() throws {
        let (model, provider, persisted) = makeModel()
        let allow = try model.addAllow(host: "a.com", port: nil).get()
        let block = try model.addBlock(host: "b.com", port: nil, scheme: nil, method: nil, pathPrefix: nil).get()

        model.setEntryEnabled(block.id, enabled: false)
        #expect(provider.current().blockEntries.first?.enabled == false)
        #expect(provider.current().allowEntries.first?.enabled == true)
        model.setEntryEnabled(allow.id, enabled: false)
        #expect(provider.current().allowEntries.first?.enabled == false)

        let revision = provider.revision
        let saves = persisted.saved.count
        model.setEntryEnabled(UUID(), enabled: true)
        model.removeEntry(UUID())
        #expect(provider.revision == revision && persisted.saved.count == saves)

        model.removeEntry(allow.id)
        #expect(provider.current().allowEntries.isEmpty && provider.current().blockEntries == [
            TrafficFilterEntry(id: block.id, enabled: false, matcher: block.matcher)
        ])
        model.removeEntry(block.id)
        #expect(model.policy.blockEntries.isEmpty && provider.current() == model.policy)
        #expect(persisted.saved.last == model.policy)
    }

    @Test func globalAndHostConditionsResolveThroughTheProvider() throws {
        let (model, provider, persisted) = makeModel()
        model.setConditionsEnabled(true)
        model.setGlobalCondition(.preset(.threeG))
        let rule = try model.addHostCondition(host: "Slow.Example.com", port: 443, selection: .preset(.edge)).get()
        #expect(rule.hostPattern == "slow.example.com" && rule.port == 443 && rule.enabled)

        let conditions = provider.current().conditions
        #expect(conditions.resolve(host: "slow.example.com", port: 443)?.selection == .preset(.edge))
        #expect(conditions.resolve(host: "slow.example.com", port: 443)?.ruleID == rule.id)
        #expect(conditions.resolve(host: "slow.example.com", port: 80)?.selection == .preset(.threeG))
        #expect(conditions.resolve(host: "other.com", port: 443)?.ruleID == nil)

        model.setHostCondition(rule.id, enabled: false)
        #expect(provider.current().conditions.resolve(host: "slow.example.com", port: 443)?.selection == .preset(.threeG))
        model.setHostCondition(rule.id, enabled: true)
        model.removeHostCondition(rule.id)
        #expect(provider.current().conditions.hostRules.isEmpty)
        model.setGlobalCondition(nil)
        #expect(provider.current().conditions.resolve(host: "other.com", port: 443) == nil)
        #expect(persisted.saved.last == model.policy)
    }

    @Test func invalidHostConditionIsRejectedWithoutChange() throws {
        let (model, provider, persisted) = makeModel()
        let revision = provider.revision
        guard case .failure(let hostError) = model.addHostCondition(host: "no good", port: nil, selection: .preset(.lte)) else {
            Issue.record("expected failure"); return
        }
        #expect(hostError.code == .invalidHostPattern && hostError.list == .hostRules)
        let bad = NetworkProfile(downloadKbps: 0, uploadKbps: nil, latencyMs: 0, lossPercent: 0)
        guard case .failure(let profileError) = model.addHostCondition(host: "a.com", port: nil, selection: .custom(bad)) else {
            Issue.record("expected failure"); return
        }
        #expect(profileError.code == .invalidProfile)
        model.setGlobalCondition(.custom(bad))
        #expect(model.policy.conditions.global == nil)
        #expect(provider.revision == revision && persisted.saved.isEmpty)
    }

    @Test func badgesReflectActiveToolsInFixedOrder() throws {
        let (model, _, _) = makeModel()
        #expect(model.badges.isEmpty)

        model.setConditionsEnabled(true)
        #expect(model.badges.isEmpty)  // enabled but nothing selected
        model.setGlobalCondition(.preset(.threeG))
        model.setBlockEnabled(true)
        _ = model.addBlock(host: "a.com", port: nil, scheme: nil, method: nil, pathPrefix: nil)
        let disabledBlock = try model.addBlock(host: "b.com", port: nil, scheme: nil, method: nil, pathPrefix: nil).get()
        model.setEntryEnabled(disabledBlock.id, enabled: false)
        model.setAllowEnabled(true)
        _ = model.addAllow(host: "c.com", port: nil)
        _ = model.addAllow(host: "d.com", port: nil)
        model.setNoCaching(true)

        #expect(model.badges.map(\.id) == ["noCaching", "allowList", "blockList", "conditions"])
        #expect(model.badges[1] == .allowList(2))
        #expect(model.badges[2] == .blockList(1))
        #expect(model.badges[3] == .conditions(TrafficPresentation.title(of: .threeG)))
        for badge in model.badges {
            #expect(!badge.title.isEmpty && !badge.title.hasPrefix("traffic."))
            #expect(!badge.help.isEmpty && !badge.help.hasPrefix("traffic."))
        }
        #expect(TrafficBadge.allowList(2).title.contains("2"))

        model.setNoCaching(false)
        model.setAllowEnabled(false)
        #expect(model.badges.map(\.id) == ["blockList", "conditions"])
    }

    @Test func conditionBadgeLabelCoversCustomAndHostOnlySelections() throws {
        let (model, _, _) = makeModel()
        model.setConditionsEnabled(true)
        _ = model.addHostCondition(host: "a.com", port: nil, selection: .preset(.edge))
        #expect(model.badges == [.conditions(TrafficPresentation.hostRulesLabel)])
        let custom = NetworkProfile(downloadKbps: 100, uploadKbps: 50, latencyMs: 20, lossPercent: 1)
        model.setGlobalCondition(.custom(custom))
        #expect(model.badges == [.conditions(TrafficPresentation.summary(of: custom))])
    }

    @Test func allowListIsInertHint() throws {
        let (model, _, _) = makeModel()
        #expect(!model.allowListIsInertHint)
        model.setAllowEnabled(true)
        #expect(model.allowListIsInertHint)
        let entry = try model.addAllow(host: "a.com", port: nil).get()
        #expect(!model.allowListIsInertHint)
        model.setEntryEnabled(entry.id, enabled: false)
        #expect(model.allowListIsInertHint)
        model.setAllowEnabled(false)
        #expect(!model.allowListIsInertHint)
    }

    @Test func presentationFormatsProfilesAndErrors() throws {
        #expect(TrafficPresentation.summary(of: NetworkPreset.threeG.profile) == "下行 780 kbps · 上行 300 kbps · 延迟 100 ms · 丢包 0%")
        let downloadUnlimited = NetworkProfile(downloadKbps: nil, uploadKbps: 300, latencyMs: 100, lossPercent: 0)
        let uploadUnlimited = NetworkProfile(downloadKbps: 780, uploadKbps: nil, latencyMs: 100, lossPercent: 1.5)
        #expect(TrafficPresentation.summary(of: downloadUnlimited) == "下行不限速 · 上行 300 kbps · 延迟 100 ms · 丢包 0%")
        #expect(TrafficPresentation.summary(of: uploadUnlimited) == "下行 780 kbps · 上行不限速 · 延迟 100 ms · 丢包 1.5%")
        #expect(TrafficPresentation.summary(of: NetworkPreset.offline.profile) == "带宽不限速 · 延迟 0 ms · 丢包 100%")
        #expect(TrafficPresentation.title(of: .offline) != TrafficPresentation.title(of: .wifi))
        let codes: [TrafficPolicyError.Code] = [
            .invalidHostPattern, .invalidPort, .invalidMethod, .invalidPath, .invalidScheme,
            .unsupportedField, .tooManyEntries, .invalidProfile, .duplicateID, .invalidPattern,
        ]
        let messages = Set(codes.map { TrafficPresentation.message(for: TrafficPolicyError(list: .allow, index: nil, code: $0)) })
        #expect(messages.count == codes.count && !messages.contains { $0.isEmpty || $0.hasPrefix("traffic.") })
    }

    // MARK: match syntax (P2 task 4)

    @Test func setEntrySyntaxToWildcardPersistsAndValidates() throws {
        let (model, provider, persisted) = makeModel()
        let allow = try model.addAllow(host: "*.Example.com", port: 443).get()
        let block = try model.addBlock(host: "ads.example.com", port: nil, scheme: nil, method: "GET", pathPrefix: "/x").get()
        let saves = persisted.saved.count
        let revision = provider.revision

        #expect(model.setEntrySyntax(allow.id, list: .allow, to: .wildcard) == nil)
        #expect(model.policy.allowEntries.first?.matcher.hostSyntax == .wildcard)
        #expect(model.policy.allowEntries.first?.matcher.hostPattern == "*.example.com")
        #expect(provider.revision == revision + 1 && persisted.saved.count == saves + 1)
        #expect(provider.current() == model.policy && persisted.saved.last == model.policy)

        #expect(model.setEntrySyntax(block.id, list: .block, to: .wildcard) == nil)
        let changed = try #require(model.policy.blockEntries.first)
        #expect(changed.matcher.hostSyntax == .wildcard && changed.matcher.method == "GET" && changed.matcher.path == .prefix("/x"))
        #expect(persisted.saved.count == saves + 2)

        // The same syntax again changes nothing and saves nothing.
        #expect(model.setEntrySyntax(block.id, list: .block, to: .wildcard) == nil)
        #expect(persisted.saved.count == saves + 2)

        // Back to literal: the host is normalized again.
        #expect(model.setEntrySyntax(allow.id, list: .allow, to: .literal) == nil)
        #expect(model.policy.allowEntries.first?.matcher.hostSyntax == .literal)
        #expect(model.policy.allowEntries.first?.matcher.hostPattern == "*.example.com")
        #expect(persisted.saved.last == model.policy)

        // An entry that is not in that list is reported, not ignored.
        let missing = model.setEntrySyntax(allow.id, list: .block, to: .regex)
        #expect(missing != nil)
        #expect(persisted.saved.count == saves + 3)
    }

    @Test func regexEntryWithRiskyPatternIsRejectedAndNotPersisted() throws {
        var initial = TrafficPolicy()
        initial.allowEntries = [TrafficFilterEntry(matcher: RuleMatcher(hostPattern: "*.example.com"))]
        initial.blockEntries = [TrafficFilterEntry(matcher: RuleMatcher(hostPattern: "*.example.com"))]
        let (model, provider, persisted) = makeModel(initial: initial)
        let before = model.policy
        let revision = provider.revision

        // "*.example.com" is a host but not a regular expression (a leading repeat).
        let broken = model.setEntrySyntax(initial.allowEntries[0].id, list: .allow, to: .regex)
        #expect(broken == TrafficPolicyError(list: .allow, index: 0, code: .invalidPattern))
        let brokenBlock = model.setEntrySyntax(initial.blockEntries[0].id, list: .block, to: .regex)
        #expect(brokenBlock == TrafficPolicyError(list: .block, index: 0, code: .invalidPattern))
        let added = model.addAllow(host: "(a+)+", port: nil, syntax: .regex)
        #expect(added.failure?.code == .invalidPattern)
        let addedBlock = model.addBlock(host: "(", port: nil, scheme: nil, method: nil, pathPrefix: nil, syntax: .regex)
        #expect(addedBlock.failure?.code == .invalidPattern)
        let wildcard = model.addBlock(host: "a\\", port: nil, scheme: nil, method: nil, pathPrefix: nil, syntax: .wildcard)
        #expect(wildcard.failure?.code == .invalidPattern)
        #expect(model.addAllow(host: "  ", port: nil, syntax: .regex).failure?.code == .invalidHostPattern)

        #expect(model.policy == before && provider.current() == before && provider.revision == revision)
        #expect(persisted.saved.isEmpty)
    }

    @Test func presentationMessageForInvalidPatternIsLocalized() {
        let message = TrafficPresentation.message(for: TrafficPolicyError(list: .allow, index: 0, code: .invalidPattern))
        #expect(message == "模式无效，没有保存。")
        #expect(!message.hasPrefix("traffic."))
        #expect(TrafficPresentation.messageKeys.contains("traffic.error.invalidPattern"))
    }

    @Test func allowEntryRegexHostAdmitsMatchingHostOnly() throws {
        let (model, _, _) = makeModel()
        model.setAllowEnabled(true)
        let entry = try model.addAllow(host: #"(a|b)\.example\.com"#, port: nil, syntax: .regex).get()
        #expect(entry.matcher.hostSyntax == .regex)
        func admission(_ host: String) -> TrafficAdmission {
            model.policy.admission(
                request: HTTPMessageTarget(scheme: "https", host: host, port: 443, method: "GET", pathAndQuery: "/"),
                explicitSend: false)
        }
        #expect(admission("a.example.com").records)
        #expect(admission("B.EXAMPLE.COM").records)
        #expect(!admission("c.example.com").records)
        #expect(!admission("xa.example.com").records)
    }

    @Test func wildcardBlockEntryBlocksMatchingHostsOnly() throws {
        let (model, _, _) = makeModel()
        model.setBlockEnabled(true)
        let entry = try model.addBlock(host: "ad?.example.*", port: nil, scheme: nil, method: nil, pathPrefix: nil, syntax: .wildcard).get()
        func admission(_ host: String) -> TrafficAdmission {
            model.policy.admission(
                request: HTTPMessageTarget(scheme: "https", host: host, port: 443, method: "GET", pathAndQuery: "/"),
                explicitSend: false)
        }
        #expect(admission("ad1.example.com").action == .block(entryID: entry.id))
        #expect(admission("ad.example.com").action == .forward)
    }

    @Test func entryTitlesCarryTheSyntaxTag() {
        let literal = RuleMatcher(hostPattern: "a.test")
        let wildcard = RuleMatcher(hostPattern: "a.*", hostSyntax: .wildcard)
        let regex = RuleMatcher(hostPattern: "(a|b)\\.test", hostSyntax: .regex)
        #expect(TrafficPresentation.hostTitle(of: literal) == "a.test")
        #expect(TrafficPresentation.hostTitle(of: RuleMatcher()) == "*")
        #expect(TrafficPresentation.hostTitle(of: wildcard) == "a.*（通配符）")
        #expect(TrafficPresentation.hostTitle(of: regex) == "(a|b)\\.test（正则）")
        #expect(TrafficPresentation.pathTitle(of: .prefix("/x")) == "/x")
        #expect(TrafficPresentation.pathTitle(of: .any) == "任意")
        #expect(TrafficPresentation.pathTitle(of: .wildcard("/a*")) == "/a*（通配符）")
        #expect(TrafficPresentation.pathTitle(of: .regex("/a.*")) == "/a.*（正则）")
    }
}
