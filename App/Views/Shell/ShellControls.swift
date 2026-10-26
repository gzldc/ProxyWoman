import AppCore
import SwiftUI

/// Outlined rounded button, 12 pt, for icon + text actions.
struct OutlineButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    /// 24 pt in the toolbars, 28 pt in the rule builder (pass 28).
    var minHeight: CGFloat = ShellStyle.iconButtonSide

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(ShellStyle.color(.textPrimary))
            .padding(.horizontal, 8)
            .frame(minHeight: minHeight)
            .background(
                RoundedRectangle(cornerRadius: ShellStyle.cornerRadius)
                    .fill(configuration.isPressed ? ShellStyle.color(.selection) : ShellStyle.color(.content))
            )
            .overlay(
                RoundedRectangle(cornerRadius: ShellStyle.cornerRadius)
                    .strokeBorder(ShellStyle.color(.separator), lineWidth: 1)
            )
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: ShellStyle.cornerRadius))
    }
}

/// Solid accent button with white text.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    /// 24 pt in the toolbars, 28 pt in the rule builder (pass 28).
    var minHeight: CGFloat = ShellStyle.iconButtonSide

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 10)
            .frame(minHeight: minHeight)
            .background(
                RoundedRectangle(cornerRadius: ShellStyle.cornerRadius)
                    .fill(ShellStyle.color(.accent).opacity(configuration.isPressed ? 0.8 : 1))
            )
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: ShellStyle.cornerRadius))
    }
}

/// 24 x 24 outlined square for icon-only buttons (callers add the accessibility label).
struct IconSquareButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    /// 24 pt in the toolbars, 28 pt in the rule builder (pass 28).
    var side: CGFloat = ShellStyle.iconButtonSide

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(ShellStyle.color(.textPrimary))
            .frame(width: side, height: side)
            .background(
                RoundedRectangle(cornerRadius: ShellStyle.cornerRadius)
                    .fill(configuration.isPressed ? ShellStyle.color(.selection) : ShellStyle.color(.content))
            )
            .overlay(
                RoundedRectangle(cornerRadius: ShellStyle.cornerRadius)
                    .strokeBorder(ShellStyle.color(.separator), lineWidth: 1)
            )
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: ShellStyle.cornerRadius))
    }
}

/// 28 x 16 capsule switch; on = accent. The Toggle's label stays in the accessibility tree.
struct CapsuleSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? ShellStyle.color(.accent) : ShellStyle.color(.separator))
                Circle()
                    .fill(Color.white)
                    .padding(2)
            }
            .frame(width: 28, height: 16)
            .animation(.easeOut(duration: 0.12), value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

/// Horizontal tab strip: selected = content background with a 2 pt accent underline, others in secondary text.
struct ShellTabStrip<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let title: (Tab) -> String
    let icon: (Tab) -> String?
    let accessory: (Tab) -> AnyView?
    /// Tabs with an icon show only the icon (fixed width) until selected.
    let iconOnlyWhenUnselected: Bool
    let trailing: AnyView?

    init(
        tabs: [Tab],
        selection: Binding<Tab>,
        title: @escaping (Tab) -> String,
        icon: @escaping (Tab) -> String?,
        accessory: @escaping (Tab) -> AnyView? = { _ in nil },
        iconOnlyWhenUnselected: Bool = false,
        trailing: AnyView? = nil
    ) {
        self.iconOnlyWhenUnselected = iconOnlyWhenUnselected
        self.trailing = trailing
        self.tabs = tabs
        self._selection = selection
        self.title = title
        self.icon = icon
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                let selected = tab == selection
                let extra = accessory(tab)
                HStack(spacing: 0) {
                    Button {
                        selection = tab
                    } label: {
                        let symbol = icon(tab)
                        let iconOnly = iconOnlyWhenUnselected && symbol != nil
                            && !InspectorTabStripPolicy.showsTitle(selected: selected)
                        HStack(spacing: 4) {
                            if let symbol {
                                Image(systemName: symbol).imageScale(.small).accessibilityHidden(true)
                            }
                            if !iconOnly { Text(title(tab)) }
                        }
                        // The padding is part of the label so the whole tab is the hit target.
                        .padding(.leading, iconOnly ? 0 : 10)
                        .padding(.trailing, iconOnly ? 0 : (extra == nil ? 10 : 4))
                        .frame(width: iconOnly ? CGFloat(InspectorTabStripPolicy.iconTabWidth) : nil, height: 30)
                        .contentShape(Rectangle())
                        .accessibilityLabel(title(tab))
                    }
                    .help(title(tab))
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    if let extra { extra.padding(.trailing, 10) }
                }
                .font(.system(size: 12, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? ShellStyle.color(.textPrimary) : ShellStyle.color(.textSecondary))
                .background(selected ? ShellStyle.color(.content) : Color.clear)
                .overlay(alignment: .bottom) {
                    if selected {
                        Rectangle().fill(ShellStyle.color(.accent)).frame(height: ShellStyle.tabUnderline)
                    }
                }
            }
            Spacer(minLength: 0)
            if let trailing { trailing.padding(.trailing, 6) }
        }
        .background(ShellStyle.color(.toolbar))
        .overlay(alignment: .bottom) {
            Rectangle().fill(ShellStyle.color(.separator)).frame(height: 1)
        }
    }
}
