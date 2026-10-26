import Foundation
import RulesEngine

/// The two ways the rule editor offers "how often the rule runs": every matching exchange, or only the first N
/// matches (ruling R8F-1). "First N" is stored as the engine's `.times(1...N)`; the model is unchanged.
public enum OccurrenceChoice: Equatable, Sendable {
    case any
    case specific(Int)

    /// The largest N the editor accepts.
    public static let maxCount = 9999

    /// `.times(a...b)` reads as "specific, b" (the upper bound is what the number field shows).
    public init(_ occurrence: Occurrence) {
        switch occurrence {
        case .any: self = .any
        case .times(let range): self = .specific(range.upperBound)
        }
    }

    /// The stored occurrence: nil when N is outside 1...maxCount.
    public var occurrence: Occurrence? {
        switch self {
        case .any: return Occurrence.any
        case .specific(let count):
            guard (1...Self.maxCount).contains(count) else { return nil }
            return .times(1...count)
        }
    }
}

/// The occurrence as the editor holds it: the choice, the count as typed and, for a rule loaded with an older range
/// (such as 3...5), that range, which is saved unchanged until the count is edited.
public struct OccurrenceDraft: Equatable, Sendable {
    public private(set) var isSpecific: Bool
    public private(set) var countText: String
    /// The loaded range that the count field has not been touched against.
    public private(set) var preserved: ClosedRange<Int>?

    public static let any = OccurrenceDraft(isSpecific: false, countText: "1", preserved: nil)

    public init(isSpecific: Bool, countText: String, preserved: ClosedRange<Int>? = nil) {
        self.isSpecific = isSpecific
        self.countText = countText
        self.preserved = preserved
    }

    public init(_ occurrence: Occurrence) {
        switch occurrence {
        case .any: self = .any
        case .times(let range): self.init(isSpecific: true, countText: String(range.upperBound), preserved: range)
        }
    }

    private var trimmedCount: String { countText.trimmingCharacters(in: .whitespaces) }

    /// The range a legacy rule was loaded with, when its lower bound is above 1 (the count box then shows only the upper bound).
    public var preservedLegacyRange: ClosedRange<Int>? {
        guard let preserved, preserved.lowerBound > 1 else { return nil }
        return preserved
    }

    public var choice: OccurrenceChoice? {
        guard isSpecific else { return OccurrenceChoice.any }
        return Int(trimmedCount).map { OccurrenceChoice.specific($0) }
    }

    /// Switching to "any" keeps the typed count, so switching back restores it.
    public mutating func setSpecific(_ specific: Bool) {
        isSpecific = specific
    }

    /// Typing the count drops a preserved range, unless the text still equals what the range shows.
    public mutating func setCountText(_ text: String) {
        countText = text
        if let preserved, trimmedCount != String(preserved.upperBound) { self.preserved = nil }
    }

    /// The occurrence to save; nil when the count is not a whole number from 1 to 9999.
    public var occurrence: Occurrence? {
        guard isSpecific else { return Occurrence.any }
        if let preserved, trimmedCount == String(preserved.upperBound) { return .times(preserved) }
        return choice?.occurrence
    }

    /// A problem with the count: not a number, or outside 1...9999.
    public var issue: RuleDraftIssue? {
        guard isSpecific, occurrence == nil else { return nil }
        return Int(trimmedCount) == nil ? .notANumber : .invalidConditionValue
    }
}
