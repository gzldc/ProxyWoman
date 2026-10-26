import Foundation
import Observation
import RulesEngine

/// The one place the traffic tools are changed. Each change is made on a copy, validated, then
/// published to the proxy's provider and saved; a change that does not validate leaves everything
/// as it was and reports why. "No Caching" and the Network Conditions master switch only last for
/// one run (spec D12), so they start off whatever was saved.
@MainActor @Observable public final class TrafficToolsModel {
    public private(set) var policy: TrafficPolicy
    @ObservationIgnored private let provider: TrafficPolicyProvider
    @ObservationIgnored private let persist: @MainActor (TrafficPolicy) -> Void

    public init(
        provider: TrafficPolicyProvider, initial: TrafficPolicy, persist: @escaping @MainActor (TrafficPolicy) -> Void
    ) {
        var start = initial
        start.noCaching = false
        start.conditions.enabled = false
        self.provider = provider
        self.persist = persist
        policy = start
        provider.publish(start)
    }

    // MARK: Switches

    public func setAllowEnabled(_ on: Bool) { apply { $0.allowEnabled = on } }
    public func setBlockEnabled(_ on: Bool) { apply { $0.blockEnabled = on } }
    public func setBlockMode(_ mode: BlockDisplayMode) { apply { $0.blockMode = mode } }
    public func setNoCaching(_ on: Bool) { apply { $0.noCaching = on } }
    public func setConditionsEnabled(_ on: Bool) { apply { $0.conditions.enabled = on } }

    // MARK: Allow and Block lists

    /// An allow entry is a host pattern and an optional port. A literal host is stored normalized;
    /// a wildcard or regular-expression host is stored as typed (trimmed) and validated as such.
    @discardableResult
    public func addAllow(
        host: String, port: Int?, syntax: PatternSyntax = .literal
    ) -> Result<TrafficFilterEntry, TrafficPolicyError> {
        addEntry(to: .allow, host: host, matcher: RuleMatcher(port: port), syntax: syntax)
    }

    /// A block entry needs a host (`*` blocks every host, so nothing is blocked by accident); empty
    /// scheme, method or path text means "any". Method and path are kept exactly as typed. `syntax`
    /// is how the host is read; the path stays a prefix.
    @discardableResult
    public func addBlock(
        host: String, port: Int?, scheme: String?, method: String?, pathPrefix: String?,
        syntax: PatternSyntax = .literal
    ) -> Result<TrafficFilterEntry, TrafficPolicyError> {
        let path = Self.present(pathPrefix).map(PathMatch.prefix) ?? .any
        let matcher = RuleMatcher(
            scheme: Self.present(scheme), port: port, method: Self.present(method), path: path)
        return addEntry(to: .block, host: host, matcher: matcher, syntax: syntax)
    }

    /// Changes how an entry's host text is read. The text is kept, so a pattern that is not valid
    /// in the new syntax is refused: the result is the typed error and nothing is published or
    /// saved. nil means the entry now has that syntax (or already had it) and it is saved.
    public func setEntrySyntax(
        _ id: UUID, list: TrafficPolicyError.List, to syntax: PatternSyntax
    ) -> TrafficPolicyError? {
        let entries: [TrafficFilterEntry] =
            switch list {
            case .allow: policy.allowEntries
            case .block: policy.blockEntries
            case .hostRules, .global: []
            }
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            return TrafficPolicyError(list: list, index: nil, code: .unsupportedField)
        }
        let result = apply { policy in
            func change(_ entry: inout TrafficFilterEntry) {
                entry.matcher.hostSyntax = syntax
                if syntax == .literal, let host = entry.matcher.hostPattern,
                    let normalized = HostPattern.normalizedUserPattern(host)
                {
                    entry.matcher.hostPattern = normalized
                }
            }
            if list == .allow { change(&policy.allowEntries[index]) } else { change(&policy.blockEntries[index]) }
        }
        if case .failure(let error) = result { return error }
        return nil
    }

    public func setEntryEnabled(_ id: UUID, enabled: Bool) {
        apply { policy in
            if let index = policy.allowEntries.firstIndex(where: { $0.id == id }) {
                policy.allowEntries[index].enabled = enabled
            } else if let index = policy.blockEntries.firstIndex(where: { $0.id == id }) {
                policy.blockEntries[index].enabled = enabled
            }
        }
    }

    public func removeEntry(_ id: UUID) {
        apply { policy in
            policy.allowEntries.removeAll { $0.id == id }
            policy.blockEntries.removeAll { $0.id == id }
        }
    }

    // MARK: Bulk changes

    /// Switches every listed Allow or Block entry as one change (one publish, one save).
    public func setEntriesEnabled(_ ids: Set<UUID>, enabled: Bool) {
        apply { policy in
            for index in policy.allowEntries.indices where ids.contains(policy.allowEntries[index].id) {
                policy.allowEntries[index].enabled = enabled
            }
            for index in policy.blockEntries.indices where ids.contains(policy.blockEntries[index].id) {
                policy.blockEntries[index].enabled = enabled
            }
        }
    }

    public func removeEntries(_ ids: Set<UUID>) {
        apply { policy in
            policy.allowEntries.removeAll { ids.contains($0.id) }
            policy.blockEntries.removeAll { ids.contains($0.id) }
        }
    }

    /// Empties the Allow or the Block list; any other list is not an entry list and stays as it is.
    public func clearEntries(in list: TrafficPolicyError.List) {
        apply { policy in
            switch list {
            case .allow: policy.allowEntries = []
            case .block: policy.blockEntries = []
            case .hostRules, .global: break
            }
        }
    }

    public func setHostConditions(_ ids: Set<UUID>, enabled: Bool) {
        apply { policy in
            for index in policy.conditions.hostRules.indices where ids.contains(policy.conditions.hostRules[index].id) {
                policy.conditions.hostRules[index].enabled = enabled
            }
        }
    }

    public func removeHostConditions(_ ids: Set<UUID>) {
        apply { $0.conditions.hostRules.removeAll { ids.contains($0.id) } }
    }

    public func clearHostConditions() { apply { $0.conditions.hostRules = [] } }

    // MARK: Network conditions

    /// nil clears the global selection.
    public func setGlobalCondition(_ selection: NetworkSelection?) { apply { $0.conditions.global = selection } }

    @discardableResult
    public func addHostCondition(
        host: String, port: Int?, selection: NetworkSelection
    ) -> Result<HostNetworkRule, TrafficPolicyError> {
        let index = policy.conditions.hostRules.count
        guard let pattern = HostPattern.normalizedUserPattern(host) else {
            return .failure(TrafficPolicyError(list: .hostRules, index: index, code: .invalidHostPattern))
        }
        let rule = HostNetworkRule(hostPattern: pattern, port: port, selection: selection)
        return apply { $0.conditions.hostRules.append(rule) }.map { rule }
    }

    public func removeHostCondition(_ id: UUID) { apply { $0.conditions.hostRules.removeAll { $0.id == id } } }

    public func setHostCondition(_ id: UUID, enabled: Bool) {
        apply { policy in
            if let index = policy.conditions.hostRules.firstIndex(where: { $0.id == id }) {
                policy.conditions.hostRules[index].enabled = enabled
            }
        }
    }

    // MARK: Status

    /// Active tools for the status bar, always in this order: No Caching, Allow, Block, Conditions.
    public var badges: [TrafficBadge] {
        var result: [TrafficBadge] = []
        if policy.noCaching { result.append(.noCaching) }
        if policy.allowActive { result.append(.allowList(policy.allowEntries.filter(\.enabled).count)) }
        if policy.blockActive { result.append(.blockList(policy.blockEntries.filter(\.enabled).count)) }
        if policy.conditions.isActive {
            let label = policy.conditions.global.map(TrafficPresentation.label(of:)) ?? TrafficPresentation.hostRulesLabel
            result.append(.conditions(label))
        }
        return result
    }

    /// The Allow list is switched on but has no enabled entry, so it filters nothing (spec D1).
    public var allowListIsInertHint: Bool { policy.allowEnabled && !policy.allowActive }

    // MARK: Internals

    private static func present(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func addEntry(
        to list: TrafficPolicyError.List, host: String, matcher: RuleMatcher, syntax: PatternSyntax
    ) -> Result<TrafficFilterEntry, TrafficPolicyError> {
        let index = list == .allow ? policy.allowEntries.count : policy.blockEntries.count
        let typed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = syntax == .literal ? HostPattern.normalizedUserPattern(host) : (typed.isEmpty ? nil : typed)
        guard let pattern else {
            return .failure(TrafficPolicyError(list: list, index: index, code: .invalidHostPattern))
        }
        var matcher = matcher
        matcher.hostPattern = pattern
        matcher.hostSyntax = syntax
        let entry = TrafficFilterEntry(matcher: matcher)
        return apply { policy in
            if list == .allow { policy.allowEntries.append(entry) } else { policy.blockEntries.append(entry) }
        }.map { entry }
    }

    /// Changes a copy, validates it, then publishes and saves it. A change that alters nothing is
    /// not published or saved. A failure leaves the policy, the provider and the saved copy alone.
    @discardableResult
    private func apply(_ change: (inout TrafficPolicy) -> Void) -> Result<Void, TrafficPolicyError> {
        var next = policy
        change(&next)
        guard next != policy else { return .success(()) }
        do {
            try next.validate()
        } catch let error as TrafficPolicyError {
            return .failure(error)
        } catch {
            return .failure(TrafficPolicyError(list: .global, index: nil, code: .unsupportedField))
        }
        policy = next
        provider.publish(next)
        persist(next)
        return .success(())
    }
}
