import AppCore
import AppKit
import Localization

/// Everything one card shows; the coordinator builds it, the cell only draws it.
struct RuleCardContent {
    var depth: Int
    var isGroup: Bool
    /// Groups: there is something to fold.
    var hasChildren: Bool
    var title: String
    /// The grey middle text of the single line: a rule's "match → action" (cut off with an ellipsis when too long), a
    /// group's "已启用 1 / 2 条".
    var summary: String
    /// Hover help of the row: the full summary and, for a rule that matched, its hit count. Hits never sit in the row.
    var help: String?
    var isEnabled: Bool
    var canToggle: Bool
    var isExpanded: Bool
    var canRun: Bool
    var canEditTitle: Bool
    var canShowMenu: Bool
    var toggleLabel: String
    var runLabel: String
    var moreLabel: String
    var collapseLabel: String
    var expandLabel: String
    var hitsAccessibility: String?
    /// The pattern-health warning shown in front of a rule's title.
    var warning: String?
}

/// The band behind a row's content (a flat list row, no border): white, the selection grey when selected.
final class RuleCardBackground: NSView {
    var isSelected = false { didSet { if oldValue != isSelected { needsDisplay = true } } }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.cornerRadius = 4
            layer.borderWidth = 0
            layer.backgroundColor = ShellStyle.nsColor(isSelected ? .selection : .content).cgColor
        }
    }
}

/// A row view that draws no highlight of its own: the row band shows the selection.
final class RuleCardRowView: NSTableRowView {
    override var isSelected: Bool { didSet { syncCard() } }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        syncCard()
    }

    override func drawSelection(in dirtyRect: NSRect) {}

    private func syncCard() {
        for case let cell as RuleCardCell in subviews { cell.background.isSelected = isSelected }
    }
}

/// One rule or group row of the rules tab: a single line with ▶, the switch and ⋮ in a fixed column at the right edge.
/// Controls send their actions to `target` (the outline coordinator), which finds the row from the sender.
final class RuleCardCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("rule-card")
    // Pitch 27 pt (26 + 1), as tight as the reference list.
    static let groupHeight: CGFloat = 26
    static let ruleHeight: CGFloat = 26
    static let gap: CGFloat = 1
    private static let indent: CGFloat = 16
    /// The right column: every row has the same widths here, so the controls line up whatever the text says.
    static let controlWidth: CGFloat = 24
    static let switchWidth: CGFloat = 34
    static let controlSpacing: CGFloat = 4

    let background = RuleCardBackground()
    let chevron = NSButton()
    private let folder = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let summary = NSTextField(labelWithString: "")
    let runButton = NSButton()
    let toggle = NSSwitch()
    let moreButton = NSButton()
    private var leading: NSLayoutConstraint?
    /// A group's title is editable in place, and an editable field has no intrinsic width, so the stack could squeeze
    /// it to nothing; this asks for its text’s width, above the summary (which gives way first) and below the controls.
    private lazy var titleWidth: NSLayoutConstraint = {
        let constraint = title.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
        constraint.priority = NSLayoutConstraint.Priority(260)
        constraint.isActive = true
        return constraint
    }()
    private var chevronLabels = (collapse: "", expand: "")

    var titleField: NSTextField { title }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        background.wantsLayer = true
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)

        configure(chevron, symbol: "chevron.down")
        folder.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        folder.contentTintColor = ShellStyle.nsColor(.accent)
        folder.setContentHuggingPriority(.required, for: .horizontal)
        configure(runButton, symbol: "play")
        runButton.contentTintColor = ShellStyle.nsColor(.accent)
        configure(moreButton, symbol: "ellipsis")
        toggle.controlSize = .mini
        toggle.setContentHuggingPriority(.required, for: .horizontal)

        title.lineBreakMode = .byTruncatingTail
        title.cell?.usesSingleLineMode = true
        title.isBezeled = false
        title.drawsBackground = false
        title.font = .systemFont(ofSize: 13)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summary.lineBreakMode = .byTruncatingTail
        summary.cell?.usesSingleLineMode = true
        summary.font = .systemFont(ofSize: 12)
        summary.textColor = ShellStyle.nsColor(.textSecondary)
        // The summary gives way first, then the title; the right column never does.
        summary.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(250), for: .horizontal)
        summary.setContentHuggingPriority(NSLayoutConstraint.Priority(200), for: .horizontal)
        title.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(500), for: .horizontal)
        title.setContentHuggingPriority(NSLayoutConstraint.Priority(300), for: .horizontal)

        let left = NSStackView(views: [chevron, folder, title, summary])
        left.orientation = .horizontal
        left.alignment = .centerY
        left.spacing = 6
        left.translatesAutoresizingMaskIntoConstraints = false
        left.setCustomSpacing(10, after: title)
        left.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        background.addSubview(left)

        let controls = NSStackView(views: [runButton, toggle, moreButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = Self.controlSpacing
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.setContentCompressionResistancePriority(.required, for: .horizontal)
        controls.setContentHuggingPriority(.required, for: .horizontal)
        background.addSubview(controls)

        let leading = background.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4)
        self.leading = leading
        NSLayoutConstraint.activate([
            leading,
            background.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            background.topAnchor.constraint(equalTo: topAnchor, constant: Self.gap / 2),
            background.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.gap / 2),
            left.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 6),
            left.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            left.trailingAnchor.constraint(lessThanOrEqualTo: controls.leadingAnchor, constant: -8),
            controls.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -6),
            controls.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 16),
            runButton.widthAnchor.constraint(equalToConstant: Self.controlWidth),
            moreButton.widthAnchor.constraint(equalToConstant: Self.controlWidth),
            toggle.widthAnchor.constraint(equalToConstant: Self.switchWidth),
        ])
        textField = title
    }

    private func configure(_ button: NSButton, symbol: String) {
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.contentTintColor = ShellStyle.nsColor(.textSecondary)
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    func show(_ content: RuleCardContent, target: AnyObject, delegate: NSTextFieldDelegate, actions: (chevron: Selector, run: Selector, toggle: Selector, more: Selector)) {
        leading?.constant = 4 + CGFloat(content.depth) * Self.indent
        // A group without children keeps the chevron's space (invisible, inert), so its folder does not shift left.
        chevron.isHidden = !content.isGroup
        let showsChevron = content.isGroup && content.hasChildren
        chevron.alphaValue = showsChevron ? 1 : 0
        chevron.isEnabled = showsChevron
        chevron.setAccessibilityElement(showsChevron)
        folder.isHidden = !content.isGroup
        summary.isHidden = content.summary.isEmpty
        chevron.image = NSImage(
            systemSymbolName: content.isExpanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        chevronLabels = (content.collapseLabel, content.expandLabel)
        chevron.setAccessibilityLabel(content.isExpanded ? content.collapseLabel : content.expandLabel)
        chevron.target = target
        chevron.action = actions.chevron

        title.stringValue = content.title
        title.font = .systemFont(ofSize: 13, weight: content.isGroup ? .medium : .regular)
        title.textColor = content.isEnabled ? ShellStyle.nsColor(.textPrimary) : ShellStyle.nsColor(.textSecondary)
        title.isEditable = content.canEditTitle
        title.delegate = delegate
        showWarning(content.warning)
        titleWidth.constant = ceil(title.attributedStringValue.size().width) + 4
        summary.stringValue = content.summary
        summary.textColor = ShellStyle.nsColor(.textSecondary)
        // Hover help for the whole line; the hit count (rules) is read out as help of the summary.
        toolTip = content.help
        summary.setAccessibilityHelp(content.hitsAccessibility)

        runButton.target = target
        runButton.action = actions.run
        runButton.isEnabled = content.canRun
        runButton.toolTip = content.runLabel
        runButton.setAccessibilityLabel(content.runLabel)

        toggle.target = target
        toggle.action = actions.toggle
        toggle.state = content.isEnabled ? .on : .off
        toggle.isEnabled = content.canToggle
        toggle.toolTip = content.toggleLabel
        toggle.setAccessibilityLabel(content.toggleLabel)

        moreButton.target = target
        moreButton.action = actions.more
        moreButton.isEnabled = content.canShowMenu
        moreButton.toolTip = content.moreLabel
        moreButton.setAccessibilityLabel(content.moreLabel)
    }

    /// A warning symbol before the title of a rule whose pattern the health monitor switched off.
    private func showWarning(_ help: String?) {
        guard let help else {
            title.toolTip = nil
            title.setAccessibilityHelp(nil)
            return
        }
        let attachment = NSTextAttachment()
        attachment.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: L10n.string("pattern.disabled.badge"))?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [NSColor(Palette.pendingColor)]))
        let text = NSMutableAttributedString(attachment: attachment)
        text.append(NSAttributedString(string: " " + title.stringValue))
        text.addAttributes(
            [.font: title.font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: title.textColor ?? NSColor.labelColor],
            range: NSRange(location: 1, length: text.length - 1))
        title.attributedStringValue = text
        title.toolTip = help
        title.setAccessibilityHelp(help)
    }

    func setExpanded(_ expanded: Bool) {
        chevron.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        chevron.setAccessibilityLabel(expanded ? chevronLabels.collapse : chevronLabels.expand)
    }
}
