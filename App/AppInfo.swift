import Foundation

enum AppInfo {
    static let name = "ProxyWoman"
    static let repositoryURL = URL(string: "https://github.com/gzldc/ProxyWoman")
    /// From Info.plist (set by scripts/build-app.sh), so HAR exports and MCP never report a stale version.
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    static let bundleID = "dev.pwapp.mac"
    static let defaultPort = 9090
}
