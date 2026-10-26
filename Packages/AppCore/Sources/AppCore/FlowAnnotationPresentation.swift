import FlowStore
import Foundation
import Localization

/// 标记与注释的文案：详情页、行提示共用。
public enum FlowAnnotationPresentation {
    public static func colourName(forHex hex: String, localizer: Localizer = L10n.localizer) -> String {
        if let preset = MarkPalette.preset(forHex: hex) { return localizer.string(preset.localizationKey) }
        return localizer.string("mark.color.custom")
    }

    /// 有文字用文字，没有用颜色名。
    public static func markLine(_ mark: FlowMark, localizer: Localizer = L10n.localizer) -> String {
        let label = mark.text ?? colourName(forHex: mark.background, localizer: localizer)
        return localizer.format("flowAnnotation.mark.line", arguments: [label])
    }

    public static func markSourceLine(_ mark: FlowMark, localizer: Localizer = L10n.localizer) -> String {
        switch mark.source {
        case .rule(_, let name): localizer.format("flowAnnotation.mark.sourceRule", arguments: [name])
        case .manual: localizer.string("flowAnnotation.mark.sourceManual")
        case .execute(_, _, let name): localizer.format("flowAnnotation.mark.sourceExecute", arguments: [name])
        }
    }

    public static func commentLine(_ comment: String, localizer: Localizer = L10n.localizer) -> String {
        localizer.format("flowAnnotation.comment.line", arguments: [comment])
    }

    public static func tooltip(for flow: Flow, localizer: Localizer = L10n.localizer) -> String? {
        var lines: [String] = []
        if let mark = flow.displayMark {
            lines.append(markLine(mark, localizer: localizer))
            lines.append(markSourceLine(mark, localizer: localizer))
        }
        if let comment = flow.comment { lines.append(commentLine(comment, localizer: localizer)) }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
