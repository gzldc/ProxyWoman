import AppCore
import Localization
import RulesEngine
import SwiftUI

extension AppModel {
    /// Pair with SwiftUI's openSettings(): Settings opens on the Traffic Control page at `tab`.
    func prepareTrafficControl(_ tab: TrafficToolsTab) {
        trafficToolsNavigation.tab = tab
        settingsPage = .trafficControl
    }

    /// Pair with SwiftUI's openSettings(): Settings opens on the HTTPS page.
    func prepareHTTPSSettings() {
        settingsPage = .https
    }
}

// MARK: shared pieces

/// An empty field means "any port"; text that is not a number is reported as an invalid port.
enum PortInput {
    case any, port(Int), invalid

    init(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            self = .any
        } else if let port = Int(trimmed) {
            self = .port(port)
        } else {
            self = .invalid
        }
    }

    var value: Int? {
        if case .port(let port) = self { port } else { nil }
    }
}

struct ErrorLine: View {
    let text: String?

    var body: some View {
        if let text {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Palette.failureColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A regular expression of this entry was switched off after repeated timeouts.
struct DisabledPatternBadge: View {
    var body: some View {
        Label(L10n.string("pattern.disabled.badge"), systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(Palette.pendingColor)
            .help(L10n.string("pattern.disabled.help.entry"))
    }
}

struct HintLine: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Valid input that probably does not do what the user means: methods are case-sensitive, so a
/// lowercase `get` never matches a `GET` request (the same warning the rules editor shows).
func methodWarning(_ text: String) -> String? {
    let method = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return method.contains(where: \.isLowercase) ? RuleDraftWarning.methodCase(method).message() : nil
}

struct WarningLine: View {
    let text: String?

    var body: some View {
        if let text {
            Label(text, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(Palette.pendingColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A menu to change how an entry's host text is read (literal, wildcard, regular expression).
struct SyntaxMenu: View {
    let current: PatternSyntax
    let choose: (PatternSyntax) -> Void

    var body: some View {
        Menu {
            ForEach(PatternSyntax.allCases, id: \.self) { syntax in
                Button {
                    choose(syntax)
                } label: {
                    if syntax == current {
                        Label(syntax.title(), systemImage: "checkmark")
                    } else {
                        Text(syntax.title())
                    }
                }
            }
        } label: {
            Image(systemName: "chevron.up.chevron.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.string("traffic.field.syntax"))
        // The symbol alone is announced by its description; name the pop-up and say what it is set to.
        .accessibilityLabel(L10n.string("traffic.field.syntax"))
        .accessibilityValue(current.title())
    }
}

/// The syntax chosen for the entry about to be added, next to its host field.
struct NewEntrySyntaxPicker: View {
    @Binding var syntax: PatternSyntax

    var body: some View {
        Picker(L10n.string("traffic.field.syntax"), selection: $syntax) {
            ForEach(PatternSyntax.allCases, id: \.self) { choice in
                Text(choice.title()).tag(choice)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help(L10n.string("traffic.field.syntax"))
    }
}

struct EntryToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle(L10n.string("traffic.field.enabled"), isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.checkbox)
    }
}

// MARK: shared tab pieces

/// The texts a traffic entry shows, for the filter field.
enum TrafficRowText {
    static func port(_ port: Int?) -> String { port.map(String.init) ?? L10n.string("traffic.field.any") }

    static func fields(of entry: TrafficFilterEntry) -> [String] {
        [
            TrafficPresentation.hostTitle(of: entry.matcher), port(entry.matcher.port), entry.matcher.method ?? "",
            TrafficPresentation.pathTitle(of: entry.matcher.path),
        ]
    }

    static func fields(of rule: HostNetworkRule) -> [String] {
        [rule.hostPattern, port(rule.port), TrafficPresentation.label(of: rule.selection)]
    }
}

/// "Clear list…" in the More menu; the owner asks for confirmation before anything is deleted.
struct ClearListMenuItem: View {
    let isEmpty: Bool
    let ask: () -> Void

    var body: some View {
        Button(L10n.string("toolWindow.bar.clearAll"), role: .destructive, action: ask)
            .disabled(isEmpty)
    }
}

extension View {
    func clearListConfirmation(isPresented: Binding<Bool>, clear: @escaping () -> Void) -> some View {
        confirmationDialog(L10n.string("toolWindow.bar.clearAllTitle"), isPresented: isPresented) {
            Button(L10n.string("toolWindow.bar.clearAllConfirm"), role: .destructive, action: clear)
            Button(L10n.string("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string("toolWindow.bar.clearAllMessage"))
        }
    }
}

// MARK: Allow list

struct AllowListTab: View {
    let model: TrafficToolsModel
    let health: PatternHealthMonitor
    @State private var selection: Set<UUID> = []
    @State private var host = ""
    @State private var port = ""
    @State private var syntax = PatternSyntax.literal
    @State private var error: String?
    @State private var filter = ToolListFilter()
    @State private var confirmsClear = false
    @FocusState private var hostFocused: Bool

    var body: some View {
        let entries = model.policy.allowEntries
        let visible = entries.filter { filter.includes(enabled: $0.enabled, fields: TrafficRowText.fields(of: $0)) }
        // A row the filter hides is no longer part of the selection the keys and buttons act on.
        let chosen = selection.intersection(visible.map(\.id))
        ToolWindowSkeleton(
            enableTitle: L10n.string("traffic.allow.title"),
            isEnabled: Binding(get: { model.policy.allowEnabled }, set: { model.setAllowEnabled($0) }),
            description: L10n.string("traffic.allow.hint"), order: L10n.string("traffic.allow.order"),
            legend: [.new, .delete, .toggleEnabled],
            actions: actions(entries: entries, chosen: chosen),
            top: {
                if model.allowListIsInertHint {
                    HintLine(text: L10n.string("traffic.allow.inertHint"), tint: Palette.pendingColor)
                }
            },
            content: { table(entries: entries, visible: visible, chosen: chosen) },
            bottom: { bottom(entries: entries, chosen: chosen) })
    }

    @ViewBuilder private func table(entries: [TrafficFilterEntry], visible: [TrafficFilterEntry], chosen: Set<UUID>) -> some View {
        Table(visible, selection: $selection) {
            TableColumn(L10n.string("traffic.field.enabled")) { entry in
                EntryToggle(isOn: Binding(
                    get: { entry.enabled }, set: { model.setEntryEnabled(entry.id, enabled: $0) }))
            }
            .width(TableHeaderMetrics.columnWidth(minimum: 52, title: L10n.string("traffic.field.enabled")))
            TableColumn(L10n.string("traffic.field.host")) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(TrafficPresentation.hostTitle(of: entry.matcher)).font(.body.monospaced())
                        SyntaxMenu(current: entry.matcher.hostSyntax) { setSyntax(entry.id, $0) }
                    }
                    if entry.enabled && health.isDisabled(entry.matcher) { DisabledPatternBadge() }
                }
            }
            TableColumn(L10n.string("traffic.field.port")) { entry in
                Text(TrafficRowText.port(entry.matcher.port))
            }
            .width(TableHeaderMetrics.columnWidth(minimum: 80, title: L10n.string("traffic.field.port")))
        }
        .alternatingRowBackgrounds(.enabled)
        .onDeleteCommand { if !chosen.isEmpty { remove(chosen) } }
        .overlay {
            if entries.isEmpty {
                ToolEmptyState(message: L10n.string("traffic.allow.empty"))
            } else if visible.isEmpty {
                ToolEmptyState(message: L10n.string("toolWindow.noMatches"), showsNewHint: false)
            }
        }
    }

    @ViewBuilder private func bottom(entries: [TrafficFilterEntry], chosen: Set<UUID>) -> some View {
        ToolWindowBottomBar(
            removeLabel: L10n.string("traffic.action.remove"), canRemove: !chosen.isEmpty,
            remove: { remove(chosen) },
            helpParagraphs: [L10n.string("traffic.allow.hint"), L10n.string("traffic.allow.order")],
            filter: $filter,
            add: { ToolBarAddButton(label: L10n.string("traffic.action.add")) { hostFocused = true } },
            more: { ClearListMenuItem(isEmpty: entries.isEmpty) { confirmsClear = true } })
            .clearListConfirmation(isPresented: $confirmsClear) {
                model.clearEntries(in: .allow)
                selection = []
            }
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            TextField(
                L10n.string("traffic.field.host"), text: $host,
                prompt: Text(syntax.hint() ?? L10n.string("traffic.field.hostPrompt"))
            )
            .focused($hostFocused)
            .onSubmit(addEntry)
            NewEntrySyntaxPicker(syntax: $syntax)
            TextField(L10n.string("traffic.field.port"), text: $port, prompt: Text(L10n.string("traffic.field.any")))
                .frame(width: 90)
                .onSubmit(addEntry)
            Button(L10n.string("traffic.action.add"), action: addEntry)
        }
        ErrorLine(text: error)
    }

    private func actions(entries: [TrafficFilterEntry], chosen: Set<UUID>) -> ToolTableActions {
        var actions = ToolTableActions(new: { hostFocused = true })
        if !chosen.isEmpty {
            actions.delete = { remove(chosen) }
            actions.toggleEnabled = { toggle(chosen, among: entries) }
        }
        return actions
    }

    private func remove(_ ids: Set<UUID>) {
        model.removeEntries(ids)
        selection = []
    }

    private func toggle(_ ids: Set<UUID>, among entries: [TrafficFilterEntry]) {
        let states = entries.filter { ids.contains($0.id) }.map(\.enabled)
        if let target = ToolSelectionToggle.targetEnabled(for: states) { model.setEntriesEnabled(ids, enabled: target) }
    }

    private func setSyntax(_ id: UUID, _ syntax: PatternSyntax) {
        // A refusal is a list-level message under the table: a table cell is too narrow for a sentence.
        error = model.setEntrySyntax(id, list: .allow, to: syntax).map(TrafficPresentation.message)
    }

    private func addEntry() {
        switch PortInput(port) {
        case .invalid:
            error = TrafficPresentation.message(for: TrafficPolicyError(list: .allow, index: nil, code: .invalidPort))
        case .any, .port:
            switch model.addAllow(host: host, port: PortInput(port).value, syntax: syntax) {
            case .success:
                host = ""
                port = ""
                error = nil
            case .failure(let failure):
                error = TrafficPresentation.message(for: failure)
            }
        }
    }
}

// MARK: Block list

struct BlockListTab: View {
    let model: TrafficToolsModel
    let health: PatternHealthMonitor
    @State private var selection: Set<UUID> = []
    @State private var host = ""
    @State private var port = ""
    @State private var method = ""
    @State private var pathPrefix = ""
    @State private var syntax = PatternSyntax.literal
    @State private var error: String?
    @State private var filter = ToolListFilter()
    @State private var confirmsClear = false
    @FocusState private var hostFocused: Bool

    var body: some View {
        let entries = model.policy.blockEntries
        let visible = entries.filter { filter.includes(enabled: $0.enabled, fields: TrafficRowText.fields(of: $0)) }
        let chosen = selection.intersection(visible.map(\.id))
        ToolWindowSkeleton(
            enableTitle: L10n.string("traffic.block.title"),
            isEnabled: Binding(get: { model.policy.blockEnabled }, set: { model.setBlockEnabled($0) }),
            description: L10n.string("traffic.block.hint"), order: L10n.string("traffic.block.order"),
            legend: [.new, .delete, .toggleEnabled],
            actions: actions(entries: entries, chosen: chosen),
            top: {
                Picker(
                    L10n.string("traffic.block.mode"),
                    selection: Binding(get: { model.policy.blockMode }, set: { model.setBlockMode($0) })
                ) {
                    Text(L10n.string("traffic.block.modeShow")).tag(BlockDisplayMode.show)
                    Text(L10n.string("traffic.block.modeHide")).tag(BlockDisplayMode.hide)
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
            },
            content: { table(entries: entries, visible: visible, chosen: chosen) },
            bottom: { bottom(entries: entries, chosen: chosen) })
    }

    @ViewBuilder private func table(entries: [TrafficFilterEntry], visible: [TrafficFilterEntry], chosen: Set<UUID>) -> some View {
        Table(visible, selection: $selection) {
            TableColumn(L10n.string("traffic.field.enabled")) { entry in
                EntryToggle(isOn: Binding(
                    get: { entry.enabled }, set: { model.setEntryEnabled(entry.id, enabled: $0) }))
            }
            .width(TableHeaderMetrics.columnWidth(minimum: 52, title: L10n.string("traffic.field.enabled")))
            TableColumn(L10n.string("traffic.field.host")) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(TrafficPresentation.hostTitle(of: entry.matcher)).font(.body.monospaced())
                        SyntaxMenu(current: entry.matcher.hostSyntax) { setSyntax(entry.id, $0) }
                    }
                    if entry.enabled && health.isDisabled(entry.matcher) { DisabledPatternBadge() }
                }
            }
            TableColumn(L10n.string("traffic.field.port")) { entry in
                Text(TrafficRowText.port(entry.matcher.port))
            }
            .width(TableHeaderMetrics.columnWidth(minimum: 70, title: L10n.string("traffic.field.port")))
            TableColumn(L10n.string("traffic.field.method")) { entry in
                let warning = entry.matcher.method.flatMap(methodWarning)
                Text(entry.matcher.method ?? L10n.string("traffic.field.any"))
                    .foregroundStyle(warning == nil ? Color.primary : Palette.pendingColor)
                    .help(warning ?? "")
            }
            .width(TableHeaderMetrics.columnWidth(minimum: 80, title: L10n.string("traffic.field.method")))
            TableColumn(L10n.string("traffic.field.pathPrefix")) { entry in
                Text(TrafficPresentation.pathTitle(of: entry.matcher.path)).font(.body.monospaced())
            }
        }
        .alternatingRowBackgrounds(.enabled)
        .onDeleteCommand { if !chosen.isEmpty { remove(chosen) } }
        .overlay {
            if entries.isEmpty {
                ToolEmptyState(message: L10n.string("traffic.block.empty"))
            } else if visible.isEmpty {
                ToolEmptyState(message: L10n.string("toolWindow.noMatches"), showsNewHint: false)
            }
        }
    }

    @ViewBuilder private func bottom(entries: [TrafficFilterEntry], chosen: Set<UUID>) -> some View {
        ToolWindowBottomBar(
            removeLabel: L10n.string("traffic.action.remove"), canRemove: !chosen.isEmpty,
            remove: { remove(chosen) },
            helpParagraphs: [L10n.string("traffic.block.hint"), L10n.string("traffic.block.order")],
            filter: $filter,
            add: { ToolBarAddButton(label: L10n.string("traffic.action.add")) { hostFocused = true } },
            more: { ClearListMenuItem(isEmpty: entries.isEmpty) { confirmsClear = true } })
            .clearListConfirmation(isPresented: $confirmsClear) {
                model.clearEntries(in: .block)
                selection = []
            }
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            TextField(
                L10n.string("traffic.field.host"), text: $host,
                prompt: Text(syntax.hint() ?? L10n.string("traffic.field.hostPrompt"))
            )
            .focused($hostFocused)
            .onSubmit(addEntry)
            NewEntrySyntaxPicker(syntax: $syntax)
            TextField(L10n.string("traffic.field.port"), text: $port, prompt: Text(L10n.string("traffic.field.any")))
                .frame(width: 70)
                .onSubmit(addEntry)
            TextField(L10n.string("traffic.field.method"), text: $method, prompt: Text(L10n.string("traffic.field.any")))
                .frame(width: 90)
                .onSubmit(addEntry)
            TextField(L10n.string("traffic.field.pathPrefix"), text: $pathPrefix, prompt: Text(verbatim: "/api"))
                .onSubmit(addEntry)
            Button(L10n.string("traffic.action.add"), action: addEntry)
        }
        WarningLine(text: methodWarning(method))
        ErrorLine(text: error)
        HintLine(text: L10n.string("traffic.block.pathHint"))
    }

    private func actions(entries: [TrafficFilterEntry], chosen: Set<UUID>) -> ToolTableActions {
        var actions = ToolTableActions(new: { hostFocused = true })
        if !chosen.isEmpty {
            actions.delete = { remove(chosen) }
            actions.toggleEnabled = { toggle(chosen, among: entries) }
        }
        return actions
    }

    private func remove(_ ids: Set<UUID>) {
        model.removeEntries(ids)
        selection = []
    }

    private func toggle(_ ids: Set<UUID>, among entries: [TrafficFilterEntry]) {
        let states = entries.filter { ids.contains($0.id) }.map(\.enabled)
        if let target = ToolSelectionToggle.targetEnabled(for: states) { model.setEntriesEnabled(ids, enabled: target) }
    }

    private func setSyntax(_ id: UUID, _ syntax: PatternSyntax) {
        // A refusal is a list-level message under the table: a table cell is too narrow for a sentence.
        error = model.setEntrySyntax(id, list: .block, to: syntax).map(TrafficPresentation.message)
    }

    private func addEntry() {
        switch PortInput(port) {
        case .invalid:
            error = TrafficPresentation.message(for: TrafficPolicyError(list: .block, index: nil, code: .invalidPort))
        case .any, .port:
            switch model.addBlock(
                host: host, port: PortInput(port).value, scheme: nil, method: method, pathPrefix: pathPrefix, syntax: syntax) {
            case .success:
                host = ""
                port = ""
                method = ""
                pathPrefix = ""
                error = nil
            case .failure(let failure):
                error = TrafficPresentation.message(for: failure)
            }
        }
    }
}

// MARK: Network conditions

/// What the global pop-up offers; the case, not the text, is the identity.
enum GlobalChoice: Hashable {
    case none
    case preset(NetworkPreset)
    case custom

    init(_ selection: NetworkSelection?) {
        switch selection {
        case nil: self = .none
        case .preset(let preset): self = .preset(preset)
        case .custom: self = .custom
        }
    }
}

struct ConditionsTab: View {
    let model: TrafficToolsModel
    @State private var customDraft = NetworkProfileDraft(NetworkPreset.medium.profile)
    @State private var selection: Set<UUID> = []
    @State private var host = ""
    @State private var port = ""
    @State private var preset: NetworkPreset = .threeG
    @State private var error: String?
    @State private var filter = ToolListFilter()
    @State private var confirmsClear = false
    @FocusState private var hostFocused: Bool

    var body: some View {
        let conditions = model.policy.conditions
        let visible = conditions.hostRules.filter { filter.includes(enabled: $0.enabled, fields: TrafficRowText.fields(of: $0)) }
        let chosen = selection.intersection(visible.map(\.id))
        ToolWindowSkeleton(
            enableTitle: L10n.string("traffic.conditions.enable"),
            isEnabled: Binding(get: { conditions.enabled }, set: { model.setConditionsEnabled($0) }),
            description: L10n.string("traffic.conditions.hint"), order: L10n.string("traffic.conditions.order"),
            legend: [.new, .delete, .toggleEnabled],
            actions: actions(rules: conditions.hostRules, chosen: chosen),
            top: {
                // The global preset stays right under the header; the host rules below it win over it.
                globalSection(conditions)
                Divider()
                Text(L10n.string("traffic.conditions.hostRules")).font(.headline)
            },
            content: { table(conditions: conditions, visible: visible, chosen: chosen) },
            bottom: { bottom(conditions: conditions, chosen: chosen) })
        .onAppear {
            if case .custom(let profile) = conditions.global { customDraft = NetworkProfileDraft(profile) }
        }
    }

    @ViewBuilder private func table(conditions: NetworkConditions, visible: [HostNetworkRule], chosen: Set<UUID>) -> some View {
        Table(visible, selection: $selection) {
            TableColumn(L10n.string("traffic.field.enabled")) { rule in
                EntryToggle(isOn: Binding(
                    get: { rule.enabled }, set: { model.setHostCondition(rule.id, enabled: $0) }))
            }
            .width(TableHeaderMetrics.columnWidth(minimum: 52, title: L10n.string("traffic.field.enabled")))
            TableColumn(L10n.string("traffic.field.host")) { rule in
                Text(rule.hostPattern).font(.body.monospaced())
            }
            TableColumn(L10n.string("traffic.field.port")) { rule in
                Text(TrafficRowText.port(rule.port))
            }
            .width(TableHeaderMetrics.columnWidth(minimum: 70, title: L10n.string("traffic.field.port")))
            TableColumn(L10n.string("traffic.field.selection")) { rule in
                Text(TrafficPresentation.label(of: rule.selection)).lineLimit(1)
            }
        }
        .alternatingRowBackgrounds(.enabled)
        .frame(minHeight: 90)
        .onDeleteCommand { if !chosen.isEmpty { remove(chosen) } }
        .overlay {
            if conditions.hostRules.isEmpty {
                ToolEmptyState(message: L10n.string("traffic.conditions.hostRulesEmpty"))
            } else if visible.isEmpty {
                ToolEmptyState(message: L10n.string("toolWindow.noMatches"), showsNewHint: false)
            }
        }
    }

    @ViewBuilder private func bottom(conditions: NetworkConditions, chosen: Set<UUID>) -> some View {
        ToolWindowBottomBar(
            removeLabel: L10n.string("traffic.action.remove"), canRemove: !chosen.isEmpty,
            remove: { remove(chosen) },
            helpParagraphs: [L10n.string("traffic.conditions.hint"), L10n.string("traffic.conditions.order")],
            filter: $filter,
            add: { ToolBarAddButton(label: L10n.string("traffic.action.add")) { hostFocused = true } },
            more: { ClearListMenuItem(isEmpty: conditions.hostRules.isEmpty) { confirmsClear = true } })
            .clearListConfirmation(isPresented: $confirmsClear) {
                model.clearHostConditions()
                selection = []
            }
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            TextField(
                L10n.string("traffic.field.host"), text: $host, prompt: Text(L10n.string("traffic.field.hostPrompt"))
            )
            .focused($hostFocused)
            .onSubmit(addRule)
            TextField(L10n.string("traffic.field.port"), text: $port, prompt: Text(L10n.string("traffic.field.any")))
                .frame(width: 70)
                .onSubmit(addRule)
            Picker(L10n.string("traffic.field.selection"), selection: $preset) {
                ForEach(NetworkPreset.allCases, id: \.self) { Text(TrafficPresentation.title(of: $0)).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Button(L10n.string("traffic.action.add"), action: addRule)
        }
        ErrorLine(text: error)
    }

    private func actions(rules: [HostNetworkRule], chosen: Set<UUID>) -> ToolTableActions {
        var actions = ToolTableActions(new: { hostFocused = true })
        if !chosen.isEmpty {
            actions.delete = { remove(chosen) }
            actions.toggleEnabled = { toggle(chosen, among: rules) }
        }
        return actions
    }

    private func remove(_ ids: Set<UUID>) {
        model.removeHostConditions(ids)
        selection = []
    }

    private func toggle(_ ids: Set<UUID>, among rules: [HostNetworkRule]) {
        let states = rules.filter { ids.contains($0.id) }.map(\.enabled)
        if let target = ToolSelectionToggle.targetEnabled(for: states) { model.setHostConditions(ids, enabled: target) }
    }

    @ViewBuilder private func globalSection(_ conditions: NetworkConditions) -> some View {
        let choice = GlobalChoice(conditions.global)
        Picker(
            L10n.string("traffic.conditions.global"),
            selection: Binding(get: { choice }, set: { select($0) })
        ) {
            Text(L10n.string("traffic.conditions.globalNone")).tag(GlobalChoice.none)
            ForEach(NetworkPreset.allCases, id: \.self) { preset in
                Text(TrafficPresentation.title(of: preset)).tag(GlobalChoice.preset(preset))
            }
            Divider()
            Text(L10n.string("traffic.conditions.custom")).tag(GlobalChoice.custom)
        }
        .frame(maxWidth: 420)
        if let global = conditions.global {
            Text(TrafficPresentation.summary(of: global.profile))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        if choice == .custom {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                profileField("traffic.field.download", text: $customDraft.downloadText, unlimited: true)
                profileField("traffic.field.upload", text: $customDraft.uploadText, unlimited: true)
                profileField("traffic.field.latency", text: $customDraft.latencyText, unlimited: false)
                profileField("traffic.field.loss", text: $customDraft.lossText, unlimited: false)
                Button(L10n.string("traffic.action.apply"), action: applyCustom)
                    .disabled(!canApplyCustom(conditions.global))
            }
        }
    }

    private func canApplyCustom(_ current: NetworkSelection?) -> Bool {
        guard let profile = customDraft.profile else { return false }
        return NetworkSelection.custom(profile) != current
    }

    private func profileField(_ key: String, text: Binding<String>, unlimited: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.string(key)).font(.caption).foregroundStyle(.secondary)
            TextField(
                L10n.string(key), text: text, prompt: unlimited ? Text(L10n.string("traffic.conditions.unlimited")) : nil
            )
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 100)
            .onSubmit(applyCustom)
        }
    }

    private func select(_ choice: GlobalChoice) {
        switch choice {
        case .none: model.setGlobalCondition(nil)
        case .preset(let preset): model.setGlobalCondition(.preset(preset))
        case .custom:
            if case .custom(let profile) = model.policy.conditions.global { customDraft = NetworkProfileDraft(profile) }
            if let profile = customDraft.profile { model.setGlobalCondition(.custom(profile)) }
        }
    }

    /// The fields are brought into the allowed ranges first, so what is saved is what they show.
    private func applyCustom() {
        guard let profile = customDraft.profile else { return }
        customDraft = customDraft.clamped
        model.setGlobalCondition(.custom(profile))
    }

    private func addRule() {
        switch PortInput(port) {
        case .invalid:
            error = TrafficPresentation.message(for: TrafficPolicyError(list: .hostRules, index: nil, code: .invalidPort))
        case .any, .port:
            switch model.addHostCondition(host: host, port: PortInput(port).value, selection: .preset(preset)) {
            case .success:
                host = ""
                port = ""
                error = nil
            case .failure(let failure):
                error = TrafficPresentation.message(for: failure)
            }
        }
    }
}
