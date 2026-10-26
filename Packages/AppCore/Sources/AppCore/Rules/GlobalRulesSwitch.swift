import Foundation
import Observation
import RulesEngine

/// The toolbar and 工具-menu switch that turns every rule on or off at once (design §10). It sets
/// the provider's flag — the rules themselves are never deleted or rewritten — and always shows
/// the provider's live state. Off: no rule (Header edit, Map, breakpoint) affects new traffic, so
/// no new breakpoint can pause either; messages already paused keep waiting for the user.
@MainActor @Observable public final class GlobalRulesSwitch {
    public static let messageKeys = [
        "rules.globalSwitch.toggle", "rules.globalSwitch.onHelp", "rules.globalSwitch.offHelp", "rules.globalSwitch.offNotice",
    ]

    public private(set) var isOn: Bool
    @ObservationIgnored private let provider: RuleSnapshotProvider
    @ObservationIgnored private let persist: @MainActor (Bool) -> Void

    /// Applies the saved state (`initial`) to the provider before any traffic; default on.
    public init(provider: RuleSnapshotProvider, initial: Bool, persist: @escaping @MainActor (Bool) -> Void) {
        self.provider = provider
        self.persist = persist
        provider.setEnabled(initial)
        isOn = provider.isEnabled
    }

    /// Saves the new state when it changed.
    public func setOn(_ on: Bool) {
        let before = isOn
        provider.setEnabled(on)
        refresh()
        if isOn != before { persist(isOn) }
    }

    public func toggle() { setOn(!isOn) }

    /// Re-reads the live flag.
    public func refresh() { isOn = provider.isEnabled }
}
