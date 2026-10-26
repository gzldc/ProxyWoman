import AppCore
import FlowStore
import Localization
import SwiftUI

/// The quick filter chips (protocol group | content group; multi-select within a group, groups combined with
/// AND) and the "⋯" menu for methods and status classes. It lives in the traffic toolbar's filter popover.
struct QuickFilterChips: View {
    @Bindable var flowList: FlowListModel

    private static let chipGroups: [[QuickFilterChip]] = [
        [.all, .http, .https, .websocket],
        [.json, .form, .xml, .javascript, .css, .graphql, .document, .media, .other],
    ]
    private static let methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]
    private static let statusClasses: [StatusClass] = [.success, .redirect, .clientError, .serverError, .failed]

    var body: some View {
        let selection = flowList.quickFilterSelection
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Self.chipGroups.indices, id: \.self) { index in
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 60), spacing: 2, alignment: .leading)], spacing: 2) {
                        ForEach(Self.chipGroups[index], id: \.self) { chip in
                            QuickFilterChipButton(title: chip.title, isOn: selection.contains(chip)) {
                                flowList.toggleQuickFilter(chip)
                            }
                        }
                    }
                }
            }
            moreMenu
        }
        .font(.callout)
    }

    @State private var isEditingComment = false

    private var activeMoreFilters: Int { QuickFilter.moreFilterCount(flowList.filter) }

    private var moreMenu: some View {
        Menu {
            Section(L10n.string("quickFilterBar.method")) {
                ForEach(Self.methods, id: \.self) { method in
                    Toggle(method, isOn: member(method, of: $flowList.filter.methods))
                }
            }
            Section(L10n.string("quickFilterBar.status")) {
                ForEach(Self.statusClasses, id: \.self) { statusClass in
                    Toggle(statusClass.title(), isOn: member(statusClass, of: $flowList.filter.statusClasses))
                }
            }
            Section(L10n.string("quickFilterBar.annotations")) {
                Toggle(L10n.string("quickFilterBar.hasMark"), isOn: $flowList.filter.hasMark)
                Toggle(L10n.string("quickFilterBar.rulesModified"), isOn: $flowList.filter.rulesModified)
                Button(L10n.string("quickFilterBar.commentContains")) { isEditingComment = true }
            }
            if activeMoreFilters > 0 {
                Divider()
                if !flowList.filter.methods.isEmpty || !flowList.filter.statusClasses.isEmpty {
                    Button(L10n.string("quickFilterBar.clearMethodStatus")) {
                        flowList.filter.methods = []
                        flowList.filter.statusClasses = []
                    }
                }
                if flowList.filter.hasMark || flowList.filter.rulesModified || !flowList.filter.commentContains.isEmpty {
                    Button(L10n.string("quickFilterBar.clearAnnotations")) {
                        QuickFilter.clearAnnotationFilters(&flowList.filter)
                    }
                }
            }
        } label: {
            if activeMoreFilters > 0 {
                Label(
                    Formatting.moreFilters(activeMoreFilters),
                    systemImage: "line.3.horizontal.decrease.circle.fill")
            } else {
                Label(L10n.string("quickFilterBar.moreFilters"), systemImage: "ellipsis")
            }
        }
        .labelStyle(.iconOnly)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.string("quickFilterBar.moreFiltersHelp"))
        .popover(isPresented: $isEditingComment) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.string("quickFilterBar.commentPopoverTitle"))
                TextField("", text: $flowList.filter.commentContains)
                    .accessibilityLabel(L10n.string("quickFilterBar.commentPopoverTitle"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit { isEditingComment = false }
            }
            .padding(12)
        }
    }

    private func member<Option: Hashable>(_ option: Option, of set: Binding<Set<Option>>) -> Binding<Bool> {
        Binding(
            get: { set.wrappedValue.contains(option) },
            set: { isOn in
                if isOn {
                    set.wrappedValue.insert(option)
                } else {
                    set.wrappedValue.remove(option)
                }
            })
    }
}

/// "规则命中 N 条 ×": the filter the rule editor's "查看" set; the button clears it.
struct RuleMatchesChip: View {
    let title: String
    let clear: () -> Void

    var body: some View {
        Button(action: clear) {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "xmark.circle.fill")
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.string("quickFilterBar.clearRuleMatches"))
        .help(L10n.string("quickFilterBar.clearRuleMatches"))
    }
}

/// A selected chip is a dark capsule (primary fill, window-background text) in both appearances.
private struct QuickFilterChipButton: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .foregroundStyle(isOn ? Color(nsColor: .windowBackgroundColor) : Color.primary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(isOn ? Color.primary : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
