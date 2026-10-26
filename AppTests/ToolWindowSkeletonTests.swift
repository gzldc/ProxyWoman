import AppCore
import AppKit
import SwiftUI
import Testing
@testable import ProxyWoman

/// The skeleton's wiring, read from an in-process hosting view that is never shown: the header's enable
/// checkbox is the tool's master switch, and the bar's "show enabled only" checkbox drives the filter.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)), .productionChinese) struct ToolWindowSkeletonTests {
    private static func buttons(in view: NSView) -> [NSButton] {
        ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap { buttons(in: $0) }
    }

    private static func host<V: View>(_ view: V) -> NSHostingView<some View> {
        let host = NSHostingView(rootView: view.frame(width: 700, height: 360))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 360), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return host
    }

    private struct Harness: View {
        @State var enabled: Bool
        @State var filter: ToolListFilter

        init(enabled: Bool, onlyEnabled: Bool) {
            _enabled = State(initialValue: enabled)
            _filter = State(initialValue: ToolListFilter(onlyEnabled: onlyEnabled))
        }

        var body: some View {
            ToolWindowSkeleton(
                enableTitle: "Enable Thing", isEnabled: $enabled,
                description: "What it does", order: "In which order", legend: [.new, .delete, .toggleEnabled],
                actions: ToolTableActions(new: {}),
                top: { EmptyView() }, content: { List { Text("row") } },
                bottom: {
                    ToolWindowBottomBar(
                        removeLabel: "Remove", canRemove: false, remove: {}, helpParagraphs: ["x"], filter: $filter,
                        add: { ToolBarAddButton(label: "Add", action: {}) }, more: { EmptyView() })
                })
        }
    }

    /// The header's enable checkbox, then the bar's "show enabled only" one. (A hosted SwiftUI checkbox has
    /// no AppKit target to click, so what is checked is the state each one shows from its binding.)
    private static func checkboxes(in host: NSView) -> (header: NSButton, bar: NSButton)? {
        let boxes = buttons(in: host).filter { $0.frame.width <= 20 && $0.frame.height <= 20 && abs($0.frame.width - ToolBarSymbol.target) > 1 }
        // A hosting view is flipped: the header is above the bar, so it has the smaller y.
        let ordered = boxes.sorted { $0.convert($0.bounds, to: host).minY < $1.convert($1.bounds, to: host).minY }
        guard ordered.count == 2 else { return nil }
        return (ordered[0], ordered[1])
    }

    @Test(arguments: [(false, false), (true, false), (false, true), (true, true)])
    func eachCheckboxShowsItsOwnBinding(enabled: Bool, onlyEnabled: Bool) throws {
        let host = Self.host(Harness(enabled: enabled, onlyEnabled: onlyEnabled))
        let boxes = try #require(Self.checkboxes(in: host))
        #expect(boxes.header.state == (enabled ? .on : .off), "master switch")
        #expect(boxes.bar.state == (onlyEnabled ? .on : .off), "show enabled only")
    }
}
