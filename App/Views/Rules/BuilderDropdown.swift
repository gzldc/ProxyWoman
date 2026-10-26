import AppCore
import Localization
import SwiftUI

/// The look of every dropdown of the rule builder: 28 pt high, thin border, rounded, the current choice on the left
/// and a chevron on the right (not the small system pop-up button with its up/down arrows). The popover based pickers
/// (condition field, action type) use this label too, so all of them look the same.
struct BuilderDropdownLabel<Leading: View>: View {
    static var height: CGFloat { 28 }

    let title: String
    /// A small grey tag after the title (the "old style" mark of a saved field the menu no longer offers).
    let tag: String?
    let leading: Leading

    init(title: String, tag: String? = nil, @ViewBuilder leading: () -> Leading) {
        self.title = title
        self.tag = tag
        self.leading = leading()
    }

    var body: some View {
        HStack(spacing: 6) {
            leading
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(ShellStyle.color(.textPrimary))
                .lineLimit(1)
                .truncationMode(.tail)
                // A title the box cuts is still readable on hover.
                .help(title)
            if let tag {
                Text(tag)
                    .font(.system(size: 10))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Palette.neutralBadgeFillColor))
                    .foregroundStyle(ShellStyle.color(.textSecondary))
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ShellStyle.color(.textSecondary))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: ShellStyle.cornerRadius).fill(ShellStyle.color(.content)))
        .overlay(RoundedRectangle(cornerRadius: ShellStyle.cornerRadius).strokeBorder(ShellStyle.color(.separator), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: ShellStyle.cornerRadius))
    }
}

extension BuilderDropdownLabel where Leading == EmptyView {
    init(title: String) { self.init(title: title) { EmptyView() } }
}

/// A dropdown that picks one of a few values; the list opens as a menu with a check mark on the current one.
/// It fills the width it is given; the caller sets the width (a frame) where it should not.
struct BuilderDropdown<Value: Hashable>: View {
    struct Option: Identifiable {
        var value: Value
        var title: String
        var id: Value { value }
    }

    /// What VoiceOver says for the dropdown (the current choice is its value).
    let label: String
    let options: [Option]
    @Binding var selection: Value

    private var currentTitle: String {
        options.first { $0.value == selection }?.title ?? ""
    }

    var body: some View {
        Menu {
            Picker(label, selection: $selection) {
                ForEach(options) { Text($0.title).tag($0.value) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            BuilderDropdownLabel(title: currentTitle)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel(label)
        .accessibilityValue(currentTitle)
    }
}

/// One entry of a `BuilderMenuDropdown`.
struct BuilderMenuItem: Identifiable {
    var id: String
    var title: String
    var isSelected: Bool
    /// An old entry a saved row still carries: listed with an "old style" mark.
    var isLegacy = false
}

/// A dropdown over groups of entries, a line between two groups and a check mark on the current one. It looks like
/// `BuilderDropdown`; the caller says which entry is current (several entries may share a value) and gets the id picked.
struct BuilderMenuDropdown<Leading: View>: View {
    let label: String
    let title: String
    var tag: String?
    let groups: [[BuilderMenuItem]]
    let leading: Leading
    let onSelect: (String) -> Void

    init(
        label: String, title: String, tag: String? = nil, groups: [[BuilderMenuItem]], onSelect: @escaping (String) -> Void,
        @ViewBuilder leading: () -> Leading
    ) {
        self.label = label
        self.title = title
        self.tag = tag
        self.groups = groups
        self.onSelect = onSelect
        self.leading = leading()
    }

    var body: some View {
        Menu {
            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                if index > 0 { Divider() }
                ForEach(group) { item in
                    Toggle(
                        isOn: Binding(get: { item.isSelected }, set: { _ in onSelect(item.id) })
                    ) {
                        Text(item.isLegacy ? L10n.format("rules.editor3.legacyOption", item.title) : item.title)
                    }
                }
            }
        } label: {
            BuilderDropdownLabel(title: title, tag: tag) { leading }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel(label)
        .accessibilityValue(title)
    }
}

extension BuilderMenuDropdown where Leading == EmptyView {
    init(label: String, title: String, tag: String? = nil, groups: [[BuilderMenuItem]], onSelect: @escaping (String) -> Void) {
        self.init(label: label, title: title, tag: tag, groups: groups, onSelect: onSelect) { EmptyView() }
    }
}
