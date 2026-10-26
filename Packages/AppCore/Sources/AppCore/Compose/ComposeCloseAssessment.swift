import Foundation
import Localization

/// What closing a Compose window would lose (spec C5). The draft counts as changed when it differs
/// from the baseline: the draft the window opened with, reset to the frozen draft at every Send
/// (the sent request is in the flow list, so it is not lost). A send or a body copy still running
/// is cancelled by closing.
public enum ComposeCloseAssessment: Sendable, Equatable {
    /// Nothing would be lost: the window closes without asking.
    case none
    /// The draft has changes that are not in any sent request.
    case confirmDiscard
    /// A send or an import is still running and closing cancels it.
    case confirmCancelSend
    /// Both of the above.
    case confirmBoth

    public static let messageKeys = [
        "compose.close.title", "compose.close.discardMessage", "compose.close.cancelSendMessage", "compose.close.bothMessage",
        "compose.close.confirm", "compose.close.stay",
    ]

    public init(isDirty: Bool, isInFlight: Bool) {
        switch (isDirty, isInFlight) {
        case (false, false): self = .none
        case (true, false): self = .confirmDiscard
        case (false, true): self = .confirmCancelSend
        case (true, true): self = .confirmBoth
        }
    }

    public var needsConfirmation: Bool { self != .none }

    /// The question's explanation; nil when nothing needs confirming.
    public var messageKey: String? {
        switch self {
        case .none: nil
        case .confirmDiscard: "compose.close.discardMessage"
        case .confirmCancelSend: "compose.close.cancelSendMessage"
        case .confirmBoth: "compose.close.bothMessage"
        }
    }

    public var messageText: String? { messageKey.map { L10n.string($0) } }
    public static var titleText: String { L10n.string("compose.close.title") }
    public static var confirmText: String { L10n.string("compose.close.confirm") }
    public static var stayText: String { L10n.string("compose.close.stay") }
}
