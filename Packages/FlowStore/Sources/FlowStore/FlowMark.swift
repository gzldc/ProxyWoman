import Foundation

/// 流量列表里的一条颜色标记。规则求值或用户手动设置。
public struct FlowMark: Sendable, Equatable, Hashable {
    public enum Source: Sendable, Equatable, Hashable {
        /// 求值那一刻的规则名。
        case rule(id: UUID, name: String)
        case manual
        /// Written by an Execute run: the run, the rule that marked it, and that rule's name at that time.
        case execute(runID: UUID, ruleID: UUID, ruleName: String)
    }

    public static let maxTextBytes = 256

    /// "#RRGGBB" or "#RRGGBBAA" (the last two digits are the opacity), upper case.
    public var background: String
    /// 同上；nil 表示保持系统文字色。
    public var foreground: String?
    /// 不超过 `maxTextBytes` 字节，在字符边界截断；空串变 nil。
    public var text: String?
    public var source: Source

    /// 背景或文字色不是 6 位（或带不透明度的 8 位）十六进制时返回 nil。
    public init?(background: String, foreground: String? = nil, text: String? = nil, source: Source) {
        guard let background = Self.normalizedHex(background) else { return nil }
        var normalizedForeground: String?
        if let foreground {
            guard let value = Self.normalizedHex(foreground) else { return nil }
            normalizedForeground = value
        }
        self.background = background
        self.foreground = normalizedForeground
        self.text = Self.truncated(text, maxBytes: Self.maxTextBytes).flatMap { $0.isEmpty ? nil : $0 }
        self.source = source
    }

    /// "#ff3b30" / "ff3b30" → "#FF3B30"; "#ff3b3080" → "#FF3B3080" (the last pair is the opacity, additive: every
    /// 6-digit colour is as valid and as rendered as before); anything else (3 digits, non-hex, white space) nil.
    public static func normalizedHex(_ raw: String) -> String? {
        let digits = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        guard digits.utf8.count == 6 || digits.utf8.count == 8, digits.utf8.allSatisfy(\.isASCIIHexDigit) else { return nil }
        return "#" + digits.uppercased()
    }

    /// Clears the colours an earlier rule set: the background (a mark is its background, so the whole mark goes) and/or
    /// the text colour (the mark stays on its background). Nothing to clear stays nothing.
    public static func reset(_ mark: FlowMark?, background: Bool, foreground: Bool) -> FlowMark? {
        guard var mark else { return nil }
        if background { return nil }
        if foreground { mark.foreground = nil }
        return mark
    }

    /// 在 Character 边界按 UTF-8 字节数截断。
    static func truncated(_ text: String?, maxBytes: Int) -> String? {
        guard let text else { return nil }
        guard text.utf8.count > maxBytes else { return text }
        var result = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            if used + size > maxBytes { break }
            result.append(character)
            used += size
        }
        return result
    }
}

private extension UInt8 {
    var isASCIIHexDigit: Bool {
        (0x30...0x39).contains(self) || (0x41...0x46).contains(self) || (0x61...0x66).contains(self)
    }
}

extension Flow {
    public static let maxCommentBytes = 4096

    public var displayMark: FlowMark? { manualMark ?? ruleMark }

    /// 空串或全空白 → nil；超过上限在字符边界截断。内容不 trim。
    public static func limitedComment(_ text: String?) -> String? {
        guard let text, !text.allSatisfy(\.isWhitespace) else { return nil }
        return FlowMark.truncated(text, maxBytes: maxCommentBytes)
    }
}

extension FlowStore {
    public func visibleFlow(_ id: Int) -> Flow? {
        state.withLock { state in
            guard let flow = state.flows[id], !flow.isHidden else { return nil }
            return flow
        }
    }

    /// id 升序，不含隐藏。
    public func visibleFlows() -> [Flow] {
        let flows = state.withLock { $0.flows.values.filter { !$0.isHidden } }
        return flows.sorted { $0.id < $1.id }
    }

    /// 可见记录数；O(1)。
    public var visibleFlowCount: Int {
        state.withLock { $0.flows.count - $0.hiddenCount }
    }

    /// 以 source = .manual 存入；nil 清除。未知 id 不记录。
    public func setManualMark(_ mark: FlowMark?, for id: Int) {
        var stored = mark
        stored?.source = .manual
        update(id) { $0.manualMark = stored }
    }

    public func setComment(_ text: String?, for id: Int) {
        let limited = Flow.limitedComment(text)
        update(id) { $0.comment = limited }
    }
}
