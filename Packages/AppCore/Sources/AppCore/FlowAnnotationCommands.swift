import FlowStore
import Foundation

/// 手动标记与注释的写入口；界面（右键菜单、详情页）都经这里。
public struct FlowAnnotationCommands {
    private let store: FlowStore

    public init(store: FlowStore) { self.store = store }

    /// 存预设的浅色值。
    public func mark(_ preset: MarkPreset, flowID: Int) {
        guard let mark = FlowMark(background: preset.lightHex, source: .manual) else { return }
        store.setManualMark(mark, for: flowID)
    }

    /// 颜色规范化失败返回 false，什么都不改。
    @discardableResult
    public func markCustom(hex: String, flowID: Int) -> Bool {
        guard let mark = FlowMark(background: hex, source: .manual) else { return false }
        store.setManualMark(mark, for: flowID)
        return true
    }

    /// 只清手动标记；规则标记回到显示。
    public func clearMark(flowID: Int) {
        store.setManualMark(nil, for: flowID)
    }

    public func setComment(_ text: String?, flowID: Int) {
        store.setComment(text, for: flowID)
    }
}
