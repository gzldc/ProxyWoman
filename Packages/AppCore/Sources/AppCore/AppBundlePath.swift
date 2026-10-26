import Foundation

public enum AppBundlePath {
    /// 可执行文件所在的最外层 `.app`（辅助程序也归到主 App），不在任何 `.app` 里时为 nil。
    /// 只做字符串处理，不访问磁盘。
    public static func outermostApp(ofExecutable path: String) -> String? {
        var prefix: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            prefix.append(component)
            if component.hasSuffix(".app"), component.count > 4 {
                return prefix.joined(separator: "/")
            }
        }
        return nil
    }
}
