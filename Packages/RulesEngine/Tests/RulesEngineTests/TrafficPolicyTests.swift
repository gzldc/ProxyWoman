import FlowStore
import Foundation
import Testing

@testable import RulesEngine

private func target(
    _ host: String = "api.example.com", scheme: String = "https", port: Int = 443,
    method: String = "GET", path: String = "/v1/items"
) -> HTTPMessageTarget {
    HTTPMessageTarget(scheme: scheme, host: host, port: port, method: method, pathAndQuery: path)
}

private func entry(
    _ host: String?, port: Int? = nil, scheme: String? = nil, method: String? = nil,
    path: PathMatch = .any, enabled: Bool = true, id: UUID = UUID(), hostSyntax: PatternSyntax = .literal
) -> TrafficFilterEntry {
    TrafficFilterEntry(
        id: id, enabled: enabled,
        matcher: RuleMatcher(
            scheme: scheme, hostPattern: host, port: port, method: method, path: path, hostSyntax: hostSyntax))
}

private func allowing(_ entries: TrafficFilterEntry...) -> TrafficPolicy {
    var policy = TrafficPolicy()
    policy.allowEnabled = true
    policy.allowEntries = entries
    return policy
}

private func blocking(_ mode: BlockDisplayMode = .show, _ entries: TrafficFilterEntry...) -> TrafficPolicy {
    var policy = TrafficPolicy()
    policy.blockEnabled = true
    policy.blockMode = mode
    policy.blockEntries = entries
    return policy
}

private func failure(_ policy: TrafficPolicy) -> TrafficPolicyError? {
    do { try policy.validate(); return nil } catch let error as TrafficPolicyError { return error } catch { return nil }
}

@Suite("TrafficPolicy")
struct TrafficPolicyTests {
    @Test func emptyPolicyIsInertAndAdmitsUnchanged() {
        let policy = TrafficPolicy()
        #expect(policy.admission(request: target(), explicitSend: false) == .unchanged)
        #expect(policy.admission(request: target(), explicitSend: true) == .unchanged)
        #expect(policy.admission(connectHost: "api.example.com", port: 443) == .unchanged)
        #expect(!policy.affectsExchanges)
        #expect(TrafficAdmission.unchanged
            == TrafficAdmission(action: .forward, records: true, appliesRules: true, appliesNoCaching: false))
    }

    @Test func allowListOnlyRecordsMatchingHosts() {
        let policy = allowing(entry("*.example.com"))
        #expect(policy.affectsExchanges)
        let hit = policy.admission(request: target("api.example.com"), explicitSend: false)
        #expect(hit.action == .forward)
        #expect(hit.records && hit.appliesRules)
        let miss = policy.admission(request: target("other.test"), explicitSend: false)
        #expect(miss == TrafficAdmission(action: .forward, records: false, appliesRules: false, appliesNoCaching: false))
        let connectMiss = policy.admission(connectHost: "other.test", port: 443)
        #expect(connectMiss.action == .forward && !connectMiss.records && !connectMiss.appliesRules)
        #expect(policy.admission(connectHost: "api.example.com", port: 443).records)
    }

    @Test func allowEnabledWithoutEnabledEntriesIsInactive() {
        var policy = allowing(entry("a.test", enabled: false))
        #expect(!policy.allowActive)
        #expect(!policy.affectsExchanges)
        #expect(policy.admission(request: target("other.test"), explicitSend: false) == .unchanged)
        policy.allowEntries = []
        #expect(!policy.allowActive)
        policy.allowEntries = [entry("a.test")]
        policy.allowEnabled = false
        #expect(!policy.allowActive)
    }

    @Test func blockWinsOverAllowMiss() {
        var policy = blocking(.show, entry("blocked.test"))
        policy.allowEnabled = true
        policy.allowEntries = [entry("allowed.test")]
        let id = policy.blockEntries[0].id
        let result = policy.admission(request: target("blocked.test"), explicitSend: false)
        #expect(result.action == .block(entryID: id))
        #expect(!result.records && !result.appliesRules && !result.appliesNoCaching)
        // Allowed and blocked: show mode records it.
        policy.allowEntries = [entry("blocked.test")]
        let shown = policy.admission(request: target("blocked.test"), explicitSend: false)
        #expect(shown.action == .block(entryID: id) && shown.records && !shown.appliesRules)
    }

    @Test func blockShowRecordsAndHideDoesNot() {
        let blocked = entry("blocked.test")
        var policy = blocking(.show, blocked)
        policy.noCaching = true
        let shown = policy.admission(request: target("blocked.test"), explicitSend: false)
        #expect(shown == TrafficAdmission(action: .block(entryID: blocked.id), records: true, appliesRules: false, appliesNoCaching: false))
        policy.blockMode = .hide
        let hidden = policy.admission(request: target("blocked.test"), explicitSend: false)
        #expect(hidden == TrafficAdmission(action: .block(entryID: blocked.id), records: false, appliesRules: false, appliesNoCaching: false))
        // A request that is not blocked keeps the normal row and picks up NoCaching.
        let other = policy.admission(request: target("fine.test"), explicitSend: false)
        #expect(other == TrafficAdmission(action: .forward, records: true, appliesRules: true, appliesNoCaching: true))
    }

    @Test func explicitSendIgnoresAllowMissAndHide() {
        var policy = allowing(entry("allowed.test"))
        let miss = policy.admission(request: target("other.test"), explicitSend: true)
        #expect(miss == TrafficAdmission(action: .forward, records: true, appliesRules: true, appliesNoCaching: false))
        let blocked = entry("blocked.test")
        policy.blockEnabled = true
        policy.blockMode = .hide
        policy.blockEntries = [blocked]
        let result = policy.admission(request: target("blocked.test"), explicitSend: true)
        #expect(result.action == .block(entryID: blocked.id))
        #expect(result.records)
        #expect(!result.appliesRules)
        let implicit = policy.admission(request: target("blocked.test"), explicitSend: false)
        #expect(!implicit.records)
    }

    @Test func connectLevelUsesOnlyHostLevelBlockEntries() {
        let hostOnly = entry("*.example.com")
        let portOnly = entry("port.test", port: 8443)
        let httpsScheme = entry("https.test", scheme: "HTTPS")
        let pathy = entry("path.test", path: .prefix("/a"))
        let withMethod = entry("method.test", method: "GET")
        let httpScheme = entry("http.test", scheme: "http")
        let disabled = entry("off.test", enabled: false)
        let policy = blocking(.show, hostOnly, portOnly, httpsScheme, pathy, withMethod, httpScheme, disabled)
        #expect(policy.admission(connectHost: "api.example.com", port: 443).action == .block(entryID: hostOnly.id))
        #expect(policy.admission(connectHost: "port.test", port: 8443).action == .block(entryID: portOnly.id))
        #expect(policy.admission(connectHost: "port.test", port: 443).action == .forward)
        #expect(policy.admission(connectHost: "https.test", port: 443).action == .block(entryID: httpsScheme.id))
        for host in ["path.test", "method.test", "http.test", "off.test"] {
            #expect(policy.admission(connectHost: host, port: 443) == .unchanged, "\(host)")
        }
        // A blocked CONNECT still reports show-mode recording and no rules.
        let blocked = policy.admission(connectHost: "api.example.com", port: 443)
        #expect(blocked.records && !blocked.appliesRules)
    }

    @Test func ipv6AndCaseSpellingsMatch() {
        let bracketed = entry("[::1]")
        let policy = blocking(.show, bracketed, entry("EXAMPLE.com."))
        #expect(policy.admission(request: target("::1"), explicitSend: false).action == .block(entryID: bracketed.id))
        #expect(policy.admission(connectHost: "[0:0:0:0:0:0:0:1]", port: 443).action == .block(entryID: bracketed.id))
        #expect(policy.admission(request: target("example.com"), explicitSend: false).action
            == .block(entryID: policy.blockEntries[1].id))
        let reverse = blocking(.show, entry("::1"), entry("example.com"))
        #expect(reverse.admission(request: target("[::1]"), explicitSend: false).action != .forward)
        #expect(reverse.admission(request: target("EXAMPLE.com."), explicitSend: false).action != .forward)
        let allow = allowing(entry("EXAMPLE.com."))
        #expect(allow.admission(request: target("example.com"), explicitSend: false).records)
    }

    @Test func validationAcceptsDefaultsAndWellFormedEntries() throws {
        try TrafficPolicy().validate()
        var policy = allowing(entry("*.example.com", port: 443))
        policy.blockEnabled = true
        policy.blockEntries = [entry("x.test", scheme: "https", method: "POST", path: .prefix("/p"))]
        policy.conditions.enabled = true
        policy.conditions.global = .custom(NetworkProfile(downloadKbps: 100, uploadKbps: nil, latencyMs: 0, lossPercent: 0))
        policy.conditions.hostRules = [HostNetworkRule(hostPattern: "*.a.test", port: 443, selection: .preset(.edge))]
        try policy.validate()
    }

    @Test func validationRejectsBadEntries() {
        var policy = allowing(entry("a.test", method: "GET"))
        #expect(failure(policy) == TrafficPolicyError(list: .allow, index: 0, code: .unsupportedField))
        policy = allowing(entry("a.test"), entry("a.test", scheme: "https"))
        #expect(failure(policy) == TrafficPolicyError(list: .allow, index: 1, code: .unsupportedField))
        policy = allowing(entry("a.test", path: .prefix("/x")))
        #expect(failure(policy) == TrafficPolicyError(list: .allow, index: 0, code: .unsupportedField))
        var withStatus = entry("a.test")
        withStatus.matcher.statusRange = 200...299
        #expect(failure(allowing(withStatus)) == TrafficPolicyError(list: .allow, index: 0, code: .unsupportedField))
        #expect(failure(blocking(.show, entry("b.test"), withStatus))
            == TrafficPolicyError(list: .block, index: 1, code: .unsupportedField))
        #expect(failure(allowing(entry("a b"))) == TrafficPolicyError(list: .allow, index: 0, code: .invalidHostPattern))
        #expect(failure(blocking(.show, entry("ok.test"), entry("a b")))
            == TrafficPolicyError(list: .block, index: 1, code: .invalidHostPattern))
        #expect(failure(blocking(.show, entry("a.test", port: 0))) == TrafficPolicyError(list: .block, index: 0, code: .invalidPort))
        #expect(failure(blocking(.show, entry("a.test", scheme: "ftp")))
            == TrafficPolicyError(list: .block, index: 0, code: .invalidScheme))
        #expect(failure(blocking(.show, entry("a.test", method: "G T")))
            == TrafficPolicyError(list: .block, index: 0, code: .invalidMethod))
        #expect(failure(blocking(.show, entry("a.test", path: .exact("/a b"))))
            == TrafficPolicyError(list: .block, index: 0, code: .invalidPath))
    }

    @Test func validationRejectsTooManyEntriesAndDuplicateIDs() {
        let many = (0...TrafficPolicy.maxEntries).map { entry("h\($0).test") }
        var policy = TrafficPolicy()
        policy.allowEntries = many
        #expect(many.count == 257)
        #expect(failure(policy) == TrafficPolicyError(list: .allow, index: nil, code: .tooManyEntries))
        policy.allowEntries = Array(many.dropLast())
        #expect(failure(policy) == nil)
        policy.allowEntries = []
        policy.blockEntries = many
        #expect(failure(policy) == TrafficPolicyError(list: .block, index: nil, code: .tooManyEntries))
        policy.blockEntries = []
        policy.conditions.hostRules = many.map { HostNetworkRule(hostPattern: $0.matcher.hostPattern ?? "", selection: .preset(.edge)) }
        #expect(failure(policy) == TrafficPolicyError(list: .hostRules, index: nil, code: .tooManyEntries))

        let id = UUID()
        #expect(failure(allowing(entry("a.test", id: id), entry("b.test", id: id)))
            == TrafficPolicyError(list: .allow, index: 1, code: .duplicateID))
        var cross = allowing(entry("a.test", id: id))
        cross.blockEntries = [entry("b.test", id: id)]
        #expect(failure(cross) == TrafficPolicyError(list: .block, index: 0, code: .duplicateID))
        var rules = TrafficPolicy()
        let ruleID = UUID()
        rules.conditions.hostRules = [
            HostNetworkRule(id: ruleID, hostPattern: "a.test", selection: .preset(.edge)),
            HostNetworkRule(id: ruleID, hostPattern: "b.test", selection: .preset(.edge)),
        ]
        #expect(failure(rules) == TrafficPolicyError(list: .hostRules, index: 1, code: .duplicateID))
    }

    @Test func validationChecksNetworkConditions() {
        let bad = NetworkProfile(downloadKbps: 0, uploadKbps: nil, latencyMs: 0, lossPercent: 0)
        var policy = TrafficPolicy()
        policy.conditions.global = .custom(bad)
        #expect(failure(policy) == TrafficPolicyError(list: .global, index: nil, code: .invalidProfile))
        policy.conditions.global = nil
        policy.conditions.hostRules = [
            HostNetworkRule(hostPattern: "a.test", selection: .preset(.edge)),
            HostNetworkRule(hostPattern: "b.test", selection: .custom(bad)),
        ]
        #expect(failure(policy) == TrafficPolicyError(list: .hostRules, index: 1, code: .invalidProfile))
        policy.conditions.hostRules = [HostNetworkRule(hostPattern: "a b", selection: .preset(.edge))]
        #expect(failure(policy) == TrafficPolicyError(list: .hostRules, index: 0, code: .invalidHostPattern))
        policy.conditions.hostRules = [HostNetworkRule(hostPattern: "a.test", port: 70_000, selection: .preset(.edge))]
        #expect(failure(policy) == TrafficPolicyError(list: .hostRules, index: 0, code: .invalidPort))
    }

    @Test func missingKeysDecodeToDefaults() throws {
        let decoded = try JSONDecoder().decode(TrafficPolicy.self, from: Data("{}".utf8))
        #expect(decoded == TrafficPolicy())
        var policy = allowing(entry("a.test"))
        policy.blockMode = .hide
        policy.noCaching = true
        policy.conditions.enabled = true
        let round = try JSONDecoder().decode(TrafficPolicy.self, from: JSONEncoder().encode(policy))
        #expect(round == policy)
    }

    @Test func affectsExchangesFollowsActiveFeatures() {
        var policy = TrafficPolicy()
        policy.noCaching = true
        #expect(policy.affectsExchanges)
        #expect(policy.admission(request: target(), explicitSend: false).appliesNoCaching)
        #expect(blocking(.show, entry("a.test")).blockActive)
        #expect(blocking(.show, entry("a.test")).affectsExchanges)
        #expect(!blocking(.show, entry("a.test", enabled: false)).blockActive)
    }

    @Test func providerPublishesAndCountsRevisions() {
        let provider = TrafficPolicyProvider()
        #expect(provider.revision == 1)
        #expect(provider.current() == TrafficPolicy())
        var next = TrafficPolicy()
        next.noCaching = true
        #expect(provider.publish(next) == 2)
        #expect(provider.revision == 2)
        #expect(provider.current() == next)
        #expect(provider.publish(TrafficPolicy()) == 3)
        #expect(TrafficPolicyProvider(next).current() == next)
        #expect(TrafficPolicyProvider(next).revision == 1)
    }
}

@Suite("TrafficPolicySyntax")
struct TrafficPolicySyntaxTests {
    @Test func invalidRegexEntryReportsInvalidPattern() {
        var policy = blocking(.show, entry("example.com", path: .regex("(")))
        #expect(failure(policy) == TrafficPolicyError(list: .block, index: 0, code: .invalidPattern))
        policy = blocking(.show, entry("example.com"), entry("(a+)+", hostSyntax: .regex))
        #expect(failure(policy) == TrafficPolicyError(list: .block, index: 1, code: .invalidPattern))
        policy = blocking(.show, entry("a b", hostSyntax: .wildcard))
        #expect(failure(policy) == TrafficPolicyError(list: .block, index: 0, code: .invalidPattern))
        #expect(failure(blocking(.show, entry("example.com", path: .wildcard(#"/a\x"#))))
            == TrafficPolicyError(list: .block, index: 0, code: .invalidPattern))
    }

    @Test func allowEntryWithWildcardHostIsValid() {
        let policy = allowing(entry("*.example.com", hostSyntax: .wildcard))
        #expect(failure(policy) == nil)
        #expect(policy.admission(request: target("a.b.example.com"), explicitSend: false).records)
        #expect(!policy.admission(request: target("other.test"), explicitSend: false).records)
    }

    @Test func allowEntryWithRegexPathStaysUnsupported() {
        let policy = allowing(entry("example.com", path: .regex("/a.*")))
        #expect(failure(policy) == TrafficPolicyError(list: .allow, index: 0, code: .unsupportedField))
    }
}
