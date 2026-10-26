import Foundation
import Localization
import Observation
import RulesEngine

/// The tabs of the traffic tools window. The case is the tab's identity; the title is only text.
public enum TrafficToolsTab: String, CaseIterable, Identifiable, Sendable {
    case allow, block, conditions

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .allow: L10n.string("traffic.tab.allow")
        case .block: L10n.string("traffic.tab.block")
        case .conditions: L10n.string("traffic.tab.conditions")
        }
    }
}

extension TrafficBadge {
    /// The tab a click on this badge opens. No Caching has no tab of its own.
    public var tab: TrafficToolsTab? {
        switch self {
        case .noCaching: nil
        case .allowList: .allow
        case .blockList: .block
        case .conditions: .conditions
        }
    }
}

/// Which tab the traffic tools window shows. Menus, badges and the flow menu set it before they
/// open the window, so an already open window switches too.
@MainActor @Observable public final class TrafficToolsNavigation {
    public var tab: TrafficToolsTab = .allow

    public init() {}
}

/// The four text fields of a custom network profile. Empty bandwidth means unlimited; numbers
/// outside the allowed range are brought into it, text that is not a number gives no profile.
public struct NetworkProfileDraft: Equatable, Sendable {
    public static let bandwidthRange = 1...1_000_000
    public static let latencyRange = 0...10_000
    public static let lossRange = 0.0...100.0

    public var downloadText: String
    public var uploadText: String
    public var latencyText: String
    public var lossText: String

    public init(downloadText: String = "", uploadText: String = "", latencyText: String = "0", lossText: String = "0") {
        self.downloadText = downloadText
        self.uploadText = uploadText
        self.latencyText = latencyText
        self.lossText = lossText
    }

    public init(_ profile: NetworkProfile) {
        downloadText = profile.downloadKbps.map(String.init) ?? ""
        uploadText = profile.uploadKbps.map(String.init) ?? ""
        latencyText = String(profile.latencyMs)
        lossText = Self.format(profile.lossPercent)
    }

    /// nil when a field holds text that is not a number.
    public var profile: NetworkProfile? {
        guard let download = Self.bandwidth(downloadText).kbps, let upload = Self.bandwidth(uploadText).kbps,
            let latency = Self.integer(latencyText), let loss = Self.decimal(lossText)
        else { return nil }
        return NetworkProfile(
            downloadKbps: download, uploadKbps: upload,
            latencyMs: min(max(latency, Self.latencyRange.lowerBound), Self.latencyRange.upperBound),
            lossPercent: min(max(loss, Self.lossRange.lowerBound), Self.lossRange.upperBound))
    }

    /// The fields rewritten as the profile that would be applied.
    public var clamped: NetworkProfileDraft { profile.map(NetworkProfileDraft.init) ?? self }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    private static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private static func integer(_ text: String) -> Int? { Int(trimmed(text)) }

    private static func decimal(_ text: String) -> Double? {
        let value = trimmed(text).replacingOccurrences(of: ",", with: ".")
        guard let number = Double(value), number.isFinite else { return nil }
        return number
    }

    private enum Bandwidth {
        case unlimited, limited(Int), invalid

        var kbps: Int?? {
            switch self {
            case .unlimited: .some(nil)
            case .limited(let value): .some(value)
            case .invalid: nil
            }
        }
    }

    private static func bandwidth(_ text: String) -> Bandwidth {
        if trimmed(text).isEmpty { return .unlimited }
        guard let number = integer(text) else { return .invalid }
        return .limited(min(max(number, bandwidthRange.lowerBound), bandwidthRange.upperBound))
    }
}
