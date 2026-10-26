import FlowStore
import Localization

/// 请求列表 SSL 列的图标。
public enum SSLIndicator: Sendable {
    /// 明文 HTTP：不显示。
    case none
    /// 已解密的 HTTPS 请求。
    case decrypted
    /// 未解密的隧道（CONNECT）。
    case tunnel

    /// SF Symbols 名称。
    public var symbolName: String? {
        switch self {
        case .none: nil
        case .decrypted: "lock.open"
        case .tunnel: "lock"
        }
    }
}

/// 请求列表每行的状态圆点和 SSL 图标。
public enum FlowIndicators {
    /// 按流的状态而不是状态码：完成为绿色，进行中为橙色，失败为红色，隧道为灰色。
    public static func dotTone(of flow: Flow) -> BadgeTone {
        switch flow.state {
        case .completed: .success
        case .inProgress: .pending
        case .failed: .failure
        case .tunnel: .neutral
        }
    }

    /// 应用列的名称：发起请求的进程；Compose 手动发送没有客户端进程，显示本地化的“Compose”，
    /// 重复发送显示“重复发送 #序号”。
    public static func appName(of flow: Flow) -> String {
        if let client = flow.client { return client.name }
        if let run = flow.provenance.tools.repeatRun { return L10n.format("repeat.flow.appName", run.index) }
        return flow.provenance.isCompose ? L10n.string("compose.flow.appName") : ""
    }

    /// Compose 手动发送用自己的 SF Symbol 代替通用可执行文件图标，重复发送用 "repeat"；其他流为 nil（用进程图标）。
    public static func appSymbolName(of flow: Flow) -> String? {
        guard flow.client == nil else { return nil }
        if flow.provenance.isRepeat { return "repeat" }
        return flow.provenance.isCompose ? "paperplane" : nil
    }

    public static func ssl(of flow: Flow) -> SSLIndicator {
        if flow.method == "CONNECT" { return .tunnel }
        return flow.scheme == "https" ? .decrypted : .none
    }
}
