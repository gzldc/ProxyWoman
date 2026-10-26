import AppCore
import AppKit
import Localization

/// Fonts and metrics of the flow table, derived from the preferences.
@MainActor struct FlowTableMetrics {
    let textFont: NSFont
    /// For the numeric columns: digits keep their width even with the proportional font.
    let numberFont: NSFont
    let badgeFont: NSFont
    let rowHeight: CGFloat
    let iconSize: CGFloat
    /// Bumped by the table whenever the metrics change, so reused cells know to restyle.
    let generation: Int

    init(fontSize: Int, monospaced: Bool, generation: Int) {
        let size = CGFloat(fontSize)
        textFont = monospaced ? .monospacedSystemFont(ofSize: size, weight: .regular) : .systemFont(ofSize: size)
        numberFont = monospaced ? textFont : .monospacedDigitSystemFont(ofSize: size, weight: .regular)
        badgeFont = .monospacedSystemFont(ofSize: max(size - 1, 9), weight: .medium)
        let lineHeight = ceil(textFont.ascender - textFont.descender + textFont.leading)
        rowHeight = lineHeight + 7
        iconSize = min(lineHeight + 2, rowHeight - 4)
        self.generation = generation
    }
}

/// One line of text, optionally after an image (the app column).
final class FlowTextCell: NSTableCellView {
    private var generation = -1
    private var iconWidth: NSLayoutConstraint?
    /// A mark's text colour; not applied while the row is drawn with the selection highlight.
    var markForeground: NSColor? {
        didSet { applyTextColor() }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if backgroundStyle != oldValue { applyTextColor() } }
    }

    private func applyTextColor() {
        textField?.textColor = backgroundStyle == .emphasized ? .labelColor : markForeground ?? .labelColor
    }

    init(identifier: NSUserInterfaceItemIdentifier, hasImage: Bool) {
        super.init(frame: .zero)
        self.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.usesSingleLineMode = true
        field.maximumNumberOfLines = 1
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(field)
        textField = field
        var constraints = [
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        if hasImage {
            let image = NSImageView()
            image.imageScaling = .scaleProportionallyUpOrDown
            image.translatesAutoresizingMaskIntoConstraints = false
            addSubview(image)
            imageView = image
            let size = image.widthAnchor.constraint(equalToConstant: 16)
            constraints += [
                image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: centerYAnchor),
                size,
                image.heightAnchor.constraint(equalTo: image.widthAnchor),
                field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
            ]
            iconWidth = size
        } else {
            constraints.append(field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2))
        }
        NSLayoutConstraint.activate(constraints)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func style(font: NSFont, lineBreakMode: NSLineBreakMode, metrics: FlowTableMetrics) {
        guard generation != metrics.generation || textField?.lineBreakMode != lineBreakMode else { return }
        generation = metrics.generation
        textField?.font = font
        textField?.lineBreakMode = lineBreakMode
        iconWidth?.constant = metrics.iconSize
    }
}

/// The state dot.
final class FlowDotCell: NSTableCellView {
    var color: NSColor = .clear {
        didSet { if color != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        let diameter: CGFloat = 8
        let rect = NSRect(
            x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2, width: diameter, height: diameter)
        color.setFill()
        NSBezierPath(ovalIn: rect).fill()
    }
}

/// A small rounded label (method, status). On an emphasized (accent) selection it switches to
/// the selection's text color, so it stays readable on any accent color.
final class FlowBadgeCell: NSTableCellView {
    private var text = ""
    private var textColor: NSColor = .labelColor
    private var fillColor: NSColor = .clear
    private var font: NSFont = .systemFont(ofSize: NSFont.smallSystemFontSize)

    func configure(text: String, tone: BadgeTone, font: NSFont) {
        let textColor = Palette.text(for: tone)
        let fillColor = Palette.badgeFill(for: tone)
        guard text != self.text || textColor != self.textColor || fillColor != self.fillColor || font != self.font
        else { return }
        self.text = text
        self.textColor = textColor
        self.fillColor = fillColor
        self.font = font
        needsDisplay = true
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if backgroundStyle != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        let isEmphasized = backgroundStyle == .emphasized
        let foreground = isEmphasized ? NSColor.alternateSelectedControlTextColor : textColor
        let label = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: foreground])
        let textSize = label.size()
        let height = ceil(textSize.height) + 2
        let width = min(ceil(textSize.width) + 12, bounds.width - 4)
        let badge = NSRect(x: 2, y: floor(bounds.midY - height / 2), width: width, height: height)
        (isEmphasized ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.2) : fillColor).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4).fill()
        label.draw(
            with: NSRect(x: badge.minX + 6, y: badge.minY + 1, width: badge.width - 12, height: ceil(textSize.height)),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// The SSL column: a template symbol, which the table tints for the selection by itself.
final class FlowSymbolCell: NSTableCellView {
    private static var images: [String: NSImage] = [:]

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let image = NSImageView()
        image.translatesAutoresizingMaskIntoConstraints = false
        image.symbolConfiguration = .init(scale: .small)
        addSubview(image)
        imageView = image
        NSLayoutConstraint.activate([
            image.centerXAnchor.constraint(equalTo: centerXAnchor),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ indicator: SSLIndicator) {
        let image = Self.image(for: indicator)
        if imageView?.image !== image { imageView?.image = image }
    }

    private static func image(for indicator: SSLIndicator) -> NSImage? {
        guard let name = indicator.symbolName else { return nil }
        if let image = images[name] { return image }
        let image = NSImage(
            systemSymbolName: name,
            accessibilityDescription: indicator == .tunnel
                ? L10n.string("common.tunnel") : L10n.string("flowTableCells.decrypted"))
        images[name] = image
        return image
    }
}
