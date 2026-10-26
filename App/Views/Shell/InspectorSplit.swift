import AppCore
import SwiftUI

/// The traffic list and the inspector. Side by side (`.horizontal`) the divider drags the inspector's width,
/// written back to the shell model when the drag ends; stacked (`.vertical`) a split view sizes them and the
/// width does not apply. A collapsed inspector is not rendered.
struct InspectorSplit<Leading: View, Trailing: View>: View {
    let shell: MainShellModel
    let layout: ContentLayout
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    /// How far the divider has moved during the current drag; resets by itself when the drag ends.
    @GestureState private var dragOffset: CGFloat = 0
    /// Whether this view has an `NSCursor` pushed, so push and pop stay balanced however the pointer leaves.
    @State private var cursorPushed = false
    @State private var hovering = false
    @State private var dragging = false

    private static var minLeading: CGFloat { 360 }

    var body: some View {
        if shell.inspector.isCollapsed {
            leading
        } else {
            switch layout {
            case .vertical:
                VSplitView {
                    leading.frame(minHeight: 120)
                    trailing.frame(minHeight: 200)
                }
            case .horizontal:
                GeometryReader { geometry in
                    let width = clampedWidth(total: geometry.size.width, offset: dragOffset)
                    HStack(spacing: 0) {
                        leading.frame(maxWidth: .infinity)
                        divider(total: geometry.size.width)
                        trailing.frame(width: width)
                    }
                }
            }
        }
    }

    /// The inspector's width for `offset` points of drag, keeping the list at least `minLeading` wide.
    private func clampedWidth(total: CGFloat, offset: CGFloat) -> CGFloat {
        let range = ShellStyle.inspectorWidthRange
        let upper = max(range.lowerBound, min(range.upperBound, total - Self.minLeading))
        return min(max(CGFloat(shell.inspector.width) - offset, range.lowerBound), upper)
    }

    private func divider(total: CGFloat) -> some View {
        Rectangle()
            .fill(ShellStyle.color(.separator))
            .frame(width: 1)
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { pushCursor() } else if !dragging { popCursor() }
            }
            .onDisappear {
                dragging = false
                hovering = false
                popCursor()
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .updating($dragOffset) { value, state, _ in state = value.translation.width }
                    .onChanged { _ in
                        dragging = true
                        pushCursor()
                    }
                    .onEnded { value in
                        dragging = false
                        if !hovering { popCursor() }
                        shell.setWidth(Double(clampedWidth(total: total, offset: value.translation.width)))
                    }
            )
            .accessibilityHidden(true)
    }

    private func pushCursor() {
        guard !cursorPushed else { return }
        NSCursor.resizeLeftRight.push()
        cursorPushed = true
    }

    private func popCursor() {
        guard cursorPushed else { return }
        NSCursor.pop()
        cursorPushed = false
    }
}
