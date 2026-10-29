import Foundation

public enum ThemeMode: String, Codable, CaseIterable, Sendable { case system, light, dark }
/// `vertical`：列表在上，详情在下。
public enum ContentLayout: String, Codable, CaseIterable, Sendable { case vertical, horizontal }
public enum TruncationStyle: String, Codable, CaseIterable, Sendable { case head, middle, tail }
public enum CopyFormat: String, Codable, CaseIterable, Sendable { case curl }
/// Where ProxyWoman sends traffic onward: through the proxy the system used before (`automatic`), through
/// `Preferences.manualUpstream`, or straight to the server.
public enum UpstreamMode: String, Codable, CaseIterable, Sendable { case automatic, manual, direct }

/// A plain HTTP proxy that ProxyWoman forwards through when `UpstreamMode.manual` is chosen.
public struct ManualUpstream: Codable, Equatable, Sendable {
    public var host = ""
    public var port = 7890
    /// macOS exception-list syntax (`example.com`, `*.example.com`, `192.168.0.0/16`, `<local>`); these go direct.
    public var bypass: [String] = []

    public init(host: String = "", port: Int = 7890, bypass: [String] = []) {
        self.host = host
        self.port = port
        self.bypass = bypass
    }

    /// Host is non-empty and the port in range.
    public var isUsable: Bool { !host.trimmingCharacters(in: .whitespaces).isEmpty && (1...65535).contains(port) }
}

/// 所有界面偏好。解码时缺失的键使用默认值，后续新增字段不会让旧数据失效。
public struct Preferences: Codable, Equatable, Sendable {
    public static let fontSizeRange = 10...18

    public var theme: ThemeMode = .light
    public var contentLayout: ContentLayout = .horizontal
    public var showMenuBarIcon = true
    public var truncation: TruncationStyle = .tail
    public var autoOverrideSystemProxyAtLaunch = false
    public var autoStartRecordingAtLaunch = true
    public var autoSelectAvailablePort = true
    /// Listen on every interface so phones and other devices on the network can use the proxy. Off by default.
    public var allowLANDevices = false
    public var upstreamMode: UpstreamMode = .automatic
    public var manualUpstream = ManualUpstream()
    /// Hosts added to the system proxy's bypass list while ProxyWoman manages it, so they never reach ProxyWoman.
    public var systemBypassDomains: [String] = []
    public var alertOnQuit = true
    /// 始终限制在 `fontSizeRange` 内。
    public var fontSize = 12 {
        didSet {
            let clamped = Self.clampedFontSize(fontSize)
            if clamped != fontSize { fontSize = clamped }
        }
    }
    public var monospaced = true
    public var wordWrap = true
    public var showInvisibles = false
    public var zebraRows = true
    public var showResourceUsage = true
    public var use24HourTime = true
    public var fullTimeFormat = false
    public var autoRemoveOldRequests = true
    public var copyFormat: CopyFormat = .curl
    public var copyAddsProxy = false
    public var copyPreservesOriginalHeaders = false
    public var pinnedApps: [String] = []
    public var pinnedHosts: [String] = []
    /// The global rules switch (phase fix I2d); default on.
    public var rulesEnabled = true
    /// Shows the comment column in the flow list; default off.
    public var showCommentColumn = false
    /// Right-hand inspector of the main window: width, collapsed, tab, source bar.
    public var inspector = InspectorLayout()

    public init() {}

    public func isPinned(app name: String) -> Bool { pinnedApps.contains(name) }
    public func isPinned(host: String) -> Bool { pinnedHosts.contains(host) }

    /// 固定的条目按固定的先后顺序排列，不重复。
    public mutating func setPinned(_ pinned: Bool, app name: String) {
        Self.set(pinned, name, in: &pinnedApps)
    }

    public mutating func setPinned(_ pinned: Bool, host: String) {
        Self.set(pinned, host, in: &pinnedHosts)
    }

    private static func set(_ pinned: Bool, _ name: String, in list: inout [String]) {
        if pinned {
            if !list.contains(name) { list.append(name) }
        } else {
            list.removeAll { $0 == name }
        }
    }

    private static func clampedFontSize(_ value: Int) -> Int {
        min(max(value, fontSizeRange.lowerBound), fontSizeRange.upperBound)
    }

    private enum CodingKeys: String, CodingKey {
        case theme, contentLayout, showMenuBarIcon, truncation, autoOverrideSystemProxyAtLaunch
        case autoStartRecordingAtLaunch, autoSelectAvailablePort, alertOnQuit, fontSize, monospaced
        case wordWrap, showInvisibles, zebraRows, showResourceUsage, use24HourTime, fullTimeFormat
        case autoRemoveOldRequests, copyFormat, copyAddsProxy, copyPreservesOriginalHeaders
        case pinnedApps, pinnedHosts, rulesEnabled, showCommentColumn, inspector
        case allowLANDevices, upstreamMode, manualUpstream, systemBypassDomains
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, into keyPath: WritableKeyPath<Preferences, T>) throws {
            if let value = try c.decodeIfPresent(T.self, forKey: key) { self[keyPath: keyPath] = value }
        }
        try read(.theme, into: \.theme)
        try read(.contentLayout, into: \.contentLayout)
        try read(.showMenuBarIcon, into: \.showMenuBarIcon)
        try read(.truncation, into: \.truncation)
        try read(.autoOverrideSystemProxyAtLaunch, into: \.autoOverrideSystemProxyAtLaunch)
        try read(.autoStartRecordingAtLaunch, into: \.autoStartRecordingAtLaunch)
        try read(.autoSelectAvailablePort, into: \.autoSelectAvailablePort)
        try read(.alertOnQuit, into: \.alertOnQuit)
        try read(.fontSize, into: \.fontSize)
        try read(.monospaced, into: \.monospaced)
        try read(.wordWrap, into: \.wordWrap)
        try read(.showInvisibles, into: \.showInvisibles)
        try read(.zebraRows, into: \.zebraRows)
        try read(.showResourceUsage, into: \.showResourceUsage)
        try read(.use24HourTime, into: \.use24HourTime)
        try read(.fullTimeFormat, into: \.fullTimeFormat)
        try read(.autoRemoveOldRequests, into: \.autoRemoveOldRequests)
        try read(.copyFormat, into: \.copyFormat)
        try read(.copyAddsProxy, into: \.copyAddsProxy)
        try read(.copyPreservesOriginalHeaders, into: \.copyPreservesOriginalHeaders)
        try read(.pinnedApps, into: \.pinnedApps)
        try read(.pinnedHosts, into: \.pinnedHosts)
        try read(.rulesEnabled, into: \.rulesEnabled)
        try read(.showCommentColumn, into: \.showCommentColumn)
        try read(.inspector, into: \.inspector)
        try read(.allowLANDevices, into: \.allowLANDevices)
        try read(.upstreamMode, into: \.upstreamMode)
        try read(.manualUpstream, into: \.manualUpstream)
        try read(.systemBypassDomains, into: \.systemBypassDomains)
    }
}
