import AppCore
import AppKit
import Localization
import SwiftUI

/// The structure every tool window shares: an enable checkbox, a line saying what the tool does, a
/// line saying in which order entries are checked, the table, a shortcut legend and a bottom bar.
/// The window supplies the table and its rows; this view supplies everything around it.
struct ToolWindowSkeleton<Top: View, Content: View, Bottom: View>: View {
    let enableTitle: String
    @Binding var isEnabled: Bool
    let description: String
    let order: String
    let legend: [ToolTableCommand]
    var legendStatus: String?
    var isBusy = false
    let actions: ToolTableActions
    let top: Top
    let content: Content
    let bottom: Bottom

    init(
        enableTitle: String, isEnabled: Binding<Bool>, description: String, order: String, legend: [ToolTableCommand],
        legendStatus: String? = nil, isBusy: Bool = false, actions: ToolTableActions,
        @ViewBuilder top: () -> Top, @ViewBuilder content: () -> Content, @ViewBuilder bottom: () -> Bottom
    ) {
        self.enableTitle = enableTitle
        _isEnabled = isEnabled
        self.description = description
        self.order = order
        self.legend = legend
        self.legendStatus = legendStatus
        self.isBusy = isBusy
        self.actions = actions
        self.top = top()
        self.content = content()
        self.bottom = bottom()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ToolWindowHeader(enableTitle: enableTitle, isOn: $isEnabled, description: description, order: order)
            top
            content
                .background(ToolTableKeyMonitor(actions: actions))
            ToolShortcutLegendView(commands: legend, status: legendStatus, isBusy: isBusy)
            bottom
        }
        .padding(12)
    }
}

// MARK: header

struct ToolWindowHeader: View {
    let enableTitle: String
    @Binding var isOn: Bool
    let description: String
    var order: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(enableTitle, isOn: $isOn)
                .toggleStyle(.checkbox)
            Text(description)
                .fontWeight(.medium)
                .fixedSize(horizontal: false, vertical: true)
            if let order {
                Text(order)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: legend

struct ToolShortcutLegendView: View {
    let commands: [ToolTableCommand]
    var status: String?
    var isBusy = false

    var body: some View {
        HStack(spacing: 8) {
            Text(ToolShortcutLegend.text(for: commands))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(ToolShortcutLegend.text(for: commands))
            Spacer(minLength: 8)
            if isBusy { ProgressView().controlSize(.small) }
            if let status { Text(status).monospacedDigit() }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

// MARK: empty state

/// Centred over an empty table: what the list is for, and how to add to it. It never takes clicks.
struct ToolEmptyState: View {
    let message: String
    var showsNewHint = true

    var body: some View {
        VStack(spacing: 6) {
            Text(message)
            if showsNewHint { Text(L10n.string("toolWindow.empty.hint")) }
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
        .padding(24)
        .allowsHitTesting(false)
    }
}

// MARK: bottom bar

/// A square hit target for a symbol: a borderless button is only as big as its label, so the label is
/// the 24-point square (sizing the button from outside does not resize the AppKit button under it).
enum ToolBarSymbol {
    static let target: CGFloat = 24

    static func image(_ name: String) -> some View {
        Image(systemName: name)
            .frame(width: target, height: target)
            .contentShape(Rectangle())
    }
}

/// "+" for a plain add: the owner decides what adding means (usually focusing the add row).
struct ToolBarAddButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { ToolBarSymbol.image("plus") }
            .help(label)
            .accessibilityLabel(label)
    }
}

/// One entry of the "+" menu.
struct ToolBarMenuItem: Identifiable {
    let id = UUID()
    let title: String
    var systemImage: String?
    var isEnabled = true
    /// A non-empty list makes this entry a submenu (its own action is not used).
    var children: [ToolBarMenuItem] = []
    let action: () -> Void
}

/// Builds the native menu behind a "+" button. Each item keeps its own target in `representedObject`
/// (a menu item holds its target weakly).
@MainActor enum ToolBarMenu {
    private final class Target: NSObject {
        let action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
    }

    static func make(_ items: [ToolBarMenuItem]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            if !item.children.isEmpty {
                let entry = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                entry.image = item.systemImage.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
                entry.isEnabled = item.isEnabled
                entry.submenu = make(item.children)
                menu.addItem(entry)
                continue
            }
            let target = Target(action: item.action)
            let entry = NSMenuItem(title: item.title, action: #selector(Target.fire), keyEquivalent: "")
            entry.isEnabled = item.isEnabled
            entry.target = target
            entry.representedObject = target
            entry.image = item.systemImage.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
            menu.addItem(entry)
        }
        return menu
    }
}

/// Where a "+" button's menu opens: at the button's bottom-left corner, whatever started it. The
/// menu used to open at the last mouse location, which is nowhere near the button after a keyboard
/// or VoiceOver activation.
enum ToolBarMenuAnchor {
    /// The point, in the button view's own coordinates, that sits on its bottom edge at the left.
    static func popUpLocation(in bounds: NSRect, isFlipped: Bool) -> NSPoint {
        NSPoint(x: bounds.minX, y: isFlipped ? bounds.maxY : bounds.minY)
    }
}

/// Holds the AppKit view behind a SwiftUI button, so a menu can be anchored to that button's frame.
@MainActor final class ToolBarAnchorBox {
    weak var view: NSView?
}

struct ToolBarAnchorView: NSViewRepresentable {
    let box: ToolBarAnchorBox

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { box.view = view }
}

/// "+" that opens a menu of what to create (the rules window's kinds). A real 24-point button that
/// pops up a native menu: a SwiftUI `Menu` is only as tall as its pop-up control (14 points), too
/// small a target for a bar of square buttons.
struct ToolBarPlusMenu: View {
    let label: String
    let items: [ToolBarMenuItem]
    @State private var anchor = ToolBarAnchorBox()

    var body: some View {
        Button(action: popUp) { ToolBarSymbol.image("plus") }
            .background(ToolBarAnchorView(box: anchor))
            .help(label)
            .accessibilityLabel(label)
    }

    private func popUp() {
        guard let view = anchor.view, view.window != nil else { return }
        let spot = ToolBarMenuAnchor.popUpLocation(in: view.bounds, isFlipped: view.isFlipped)
        ToolBarMenu.make(items).popUp(positioning: nil, at: spot, in: view)
    }
}

/// +/− on the left (labelled, 24 × 24), "?" help; "show enabled only", the filter toggle and a More
/// menu on the right. The filter field appears above the bar while the filter toggle is on.
struct ToolWindowBottomBar<Add: View, More: View, Trailing: View>: View {
    let removeLabel: String
    let canRemove: Bool
    let remove: () -> Void
    let helpParagraphs: [String]
    @Binding var filter: ToolListFilter
    let showsMore: Bool
    let add: Add
    let more: More
    /// Extra buttons just left of the More menu (the rules window's run button).
    let trailing: Trailing
    @State private var showsFilter = false
    @State private var showsHelp = false
    @FocusState private var filterFocused: Bool

    init(
        removeLabel: String, canRemove: Bool, remove: @escaping () -> Void, helpParagraphs: [String],
        filter: Binding<ToolListFilter>, showsMore: Bool = true, @ViewBuilder add: () -> Add, @ViewBuilder more: () -> More,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.trailing = trailing()
        self.removeLabel = removeLabel
        self.canRemove = canRemove
        self.remove = remove
        self.helpParagraphs = helpParagraphs
        _filter = filter
        self.showsMore = showsMore
        self.add = add()
        self.more = more()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsFilter {
                TextField(
                    L10n.string("toolWindow.bar.filter"), text: $filter.query,
                    prompt: Text(L10n.string("toolWindow.bar.filterPrompt"))
                )
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .focused($filterFocused)
                .accessibilityLabel(L10n.string("toolWindow.bar.filter"))
            }
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    add
                    Button(action: remove) { ToolBarSymbol.image("minus") }
                        .help(removeLabel)
                        .accessibilityLabel(removeLabel)
                        .disabled(!canRemove)
                    Button { showsHelp.toggle() } label: { ToolBarSymbol.image("questionmark.circle") }
                        .help(L10n.string("toolWindow.bar.help"))
                        .accessibilityLabel(L10n.string("toolWindow.bar.help"))
                        .popover(isPresented: $showsHelp, arrowEdge: .top) {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(helpParagraphs, id: \.self) { paragraph in
                                    Text(paragraph).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .frame(width: 320, alignment: .leading)
                            .padding(14)
                        }
                }
                .buttonStyle(.borderless)
                Spacer(minLength: 8)
                Toggle(L10n.string("toolWindow.bar.onlyEnabled"), isOn: $filter.onlyEnabled)
                    .toggleStyle(.checkbox)
                Toggle(isOn: $showsFilter) {
                    Label(L10n.string("toolWindow.bar.filter"), systemImage: "line.3.horizontal.decrease.circle")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .accessibilityLabel(L10n.string("toolWindow.bar.filter"))
                trailing
                if showsMore {
                    Menu {
                        more
                    } label: {
                        Text(L10n.string("toolWindow.bar.more"))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel(L10n.string("toolWindow.bar.more"))
                }
            }
        }
        // Always laid out at its natural size: a tab whose upper part is tall must shrink the table, not push this bar out.
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
        .onChange(of: showsFilter) { _, shown in
            if shown {
                filterFocused = true
            } else {
                filter.query = ""
            }
        }
    }
}

extension ToolWindowBottomBar where Trailing == EmptyView {
    init(
        removeLabel: String, canRemove: Bool, remove: @escaping () -> Void, helpParagraphs: [String],
        filter: Binding<ToolListFilter>, showsMore: Bool = true, @ViewBuilder add: () -> Add, @ViewBuilder more: () -> More
    ) {
        self.init(
            removeLabel: removeLabel, canRemove: canRemove, remove: remove, helpParagraphs: helpParagraphs, filter: filter,
            showsMore: showsMore, add: add, more: more, trailing: { EmptyView() })
    }
}
