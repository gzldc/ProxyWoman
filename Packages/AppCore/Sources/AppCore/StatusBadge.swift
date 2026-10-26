import FlowStore
import Localization

public enum BadgeTone: Sendable { case neutral, success, pending, failure }

public struct StatusBadge: Equatable, Sendable {
    public var text: String
    public var tone: BadgeTone

    public init(text: String, tone: BadgeTone) {
        self.text = text
        self.tone = tone
    }

    /// 有状态码时显示数字（2xx/3xx 成功，4xx/5xx 失败，其余中性），否则按流状态显示。
    public static func of(_ flow: Flow) -> StatusBadge {
        if let code = flow.statusCode {
            let tone: BadgeTone =
                switch code {
                case 200..<400: .success
                case 400..<600: .failure
                default: .neutral
                }
            return StatusBadge(text: String(code), tone: tone)
        }
        switch flow.state {
        case .inProgress: return StatusBadge(text: L10n.string("statusBadge.inProgress"), tone: .pending)
        case .failed: return StatusBadge(text: L10n.string("statusBadge.failed"), tone: .failure)
        case .tunnel: return StatusBadge(text: L10n.string("common.tunnel"), tone: .neutral)
        case .completed: return StatusBadge(text: "–", tone: .neutral)
        }
    }
}

extension StatusClass {
    /// The label of this class in filter menus. Numeric classes are protocol notation; only
    /// `.failed` is a word, so only it is localized.
    public func title(localizer: Localizer = L10n.localizer) -> String {
        switch self {
        case .informational: "1xx"
        case .success: "2xx"
        case .redirect: "3xx"
        case .clientError: "4xx"
        case .serverError: "5xx"
        case .failed: localizer.string("statusBadge.failed")
        }
    }
}
