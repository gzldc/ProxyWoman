import AppCore
import FlowStore
import Localization
import RulesEngine
import SwiftUI
import UniformTypeIdentifiers

// MARK: the grouped menu

/// The list of action types, in a popover (a `Menu` drops the direction icons): the menu's groups separated by lines,
/// one direction icon per type. A type the judgment point or the other cards rule out stays in the list, grey; choosing
/// it explains why.
struct ActionTypePicker: View {
    private static let width = RuleBuilderMetrics.actionTypePickerWidth()
    let availability: (ActionType) -> ActionType.Availability
    let selected: ActionType?
    let choose: (ActionType) -> Void

    @State private var explained: ActionType.Reason?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(ActionMenuPresentation.sections(availability: availability)) { section in
                        if section.index > 0 { Divider().padding(.vertical, 4) }
                        ForEach(section.items) { item in row(item) }
                    }
                }
                .padding(6)
            }
            if let explained {
                Divider()
                Text(L10n.string(ActionType.explanationKey(explained)))
                    .font(.callout)
                    .foregroundStyle(Palette.pendingColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
            }
        }
        .frame(width: Self.width, height: 440)
    }

    private func row(_ item: ActionMenuItem) -> some View {
        let type = item.type
        let title = L10n.string(type.titleKey)
        return Button {
            if let reason = item.reason {
                explained = reason
            } else {
                choose(type)
            }
        } label: {
            HStack(spacing: 8) {
                ConditionDirectionIcon(direction: item.direction, dimmed: !item.isAvailable)
                Text(title).font(.system(size: 13))
                Spacer(minLength: 12)
                if !item.isAvailable { Image(systemName: "nosign").font(.caption).foregroundStyle(.secondary) }
                if type == selected { Image(systemName: "checkmark").font(.system(size: 11)) }
            }
            .foregroundStyle(item.isAvailable ? ShellStyle.color(.textPrimary) : ShellStyle.color(.textSecondary))
            .padding(.horizontal, 6)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: ShellStyle.cornerRadius)
                    .fill(type == selected ? ShellStyle.color(.selection) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.isAvailable ? title : L10n.format("rules.card.menuItem.unavailable", title))
        .accessibilityValue(item.direction.title())
    }
}

// MARK: banner

/// The strip above the cards when any card has a notice: errors name actions that never run, warnings only actions that
/// may not do what they say.
private struct ActionBannerView: View {
    let banner: ActionBanner

    var body: some View {
        let isError = banner == .errors
        let tint = isError ? Palette.failureColor : Palette.pendingColor
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill").foregroundStyle(tint)
            Text(L10n.string(banner.textKey))
                .font(.system(size: 13))
                .foregroundStyle(ShellStyle.color(.textPrimary))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: ShellStyle.cornerRadius).fill(tint.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: ShellStyle.cornerRadius).strokeBorder(tint.opacity(0.5), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

// MARK: column

/// The right column: a bordered box with "+ Add action" on top, then the cards in order.
struct RuleActionsColumn: View {
    let session: RuleEditorSession
    let store: FlowStore

    private static let dragType = UTType(exportedAs: "com.proxywoman.rules.action-card", conformingTo: .data)

    /// The card being dragged and the card the pointer is over.
    @State private var dragging: UUID?
    @State private var dropTarget: UUID?
    @State private var endTargeted = false

    var body: some View {
        if let document = session.document {
            let report = document.liveCardReport(limits: session.limits)
            let analysis = report.analysis
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.string("rules.builder.actions")).font(.headline)
                if let banner = analysis.banner { ActionBannerView(banner: banner) }
                GeometryReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                Spacer()
                                addButton
                            }
                            .padding(10)
                            // The strip under the header, as in the reference, whether or not there are cards yet.
                            Divider()
                            ForEach(Array(document.actions.enumerated()), id: \.element.id) { index, card in
                                cardCell(
                                    card, index: index, count: document.actions.count,
                                    state: analysis.states.indices.contains(index) ? analysis.states[index] : .active,
                                    notices: analysis.notices.indices.contains(index) ? analysis.notices[index] : [],
                                    buildWarnings: report.buildWarnings.indices.contains(index) ? report.buildWarnings[index] : [])
                                    // An earlier card's suggestion list draws over the cards under it.
                                    .zIndex(Double(document.actions.count - index))
                            }
                            endDropZone(count: document.actions.count)
                            let problem = session.validation?.issues[.actions]
                            if problem != nil {
                                Divider()
                                RuleDocumentIssueText(session: session, field: .actions).padding(10)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: ShellStyle.cornerRadius).fill(ShellStyle.color(.content)))
                        .overlay(RoundedRectangle(cornerRadius: ShellStyle.cornerRadius).strokeBorder(ShellStyle.color(.separator), lineWidth: 1))
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .topLeading)
                    }
                    // A suggestion list opens upward when the viewport has no room for it below the box.
                    .coordinateSpace(name: SuggestionViewport.space)
                    .environment(\.suggestionViewportHeight, proxy.size.height)
                }
            }
            .padding(EdgeInsets(top: 12, leading: 8, bottom: 12, trailing: 12))
            // A card dropped on the column outside every card and the end strip (the header, a gap, the padding) ends the
            // drag too; a drag that ends outside the column cannot leave a stale card behind because no drop reads it.
            .onDrop(of: [Self.dragType], isTargeted: nil) { _ in
                endDrag()
                return false
            }
        }
    }

    /// A new action is a Mark Session card with both colours unchanged, as in the reference.
    private var addButton: some View {
        Button {
            session.update { $0.addAction(ActionMenuPresentation.defaultNewType) }
        } label: {
            Label(L10n.string("rules.builder.addAction"), systemImage: "plus")
        }
        .buttonStyle(OutlineButtonStyle(minHeight: 28))
        .keyboardShortcut("a", modifiers: [.command, .shift])
        .accessibilityLabel(L10n.string("rules.builder.addAction"))
    }

    private func cardCell(
        _ card: ActionDraft, index: Int, count: Int, state: ActionCardState, notices: [ActionCardNotice], buildWarnings: [ActionWarning]
    ) -> some View {
        let id = card.id
        let isTarget = dropTarget == id && dragging != nil && dragging != id
        return ActionCardView(
            session: session, store: store, action: binding(card), index: index, count: count, state: state, notices: notices,
            warnings: warnings(of: card, built: buildWarnings), issues: issues(of: id),
            beginDrag: {
                dragging = id
                // A type of its own, so a text box under the pointer does not take the drop as text.
                let provider = NSItemProvider()
                provider.registerDataRepresentation(forTypeIdentifier: Self.dragType.identifier, visibility: .ownProcess) { done in
                    done(Data(id.uuidString.utf8), nil)
                    return nil
                }
                return provider
            }
        )
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: ShellStyle.cornerRadius)
                .strokeBorder(isTarget ? ShellStyle.color(.accent) : ShellStyle.color(.separator), lineWidth: isTarget ? 2 : 1)
        )
        .padding(10)
        .onDrop(
            of: [Self.dragType],
            isTargeted: Binding(
                get: { dropTarget == id },
                set: { inside in
                    if inside { dropTarget = id } else if dropTarget == id { dropTarget = nil }
                })
        ) { providers in
            takeDrop(providers) { source in
                guard source != id,
                    let from = session.document?.actions.firstIndex(where: { $0.id == source }),
                    let to = session.document?.actions.firstIndex(where: { $0.id == id })
                else { return }
                session.update { $0.moveAction(source, by: to - from) }
            }
        }
    }

    /// Clears what a drag leaves behind, however it ended.
    private func endDrag() {
        dragging = nil
        dropTarget = nil
        endTargeted = false
    }

    /// Takes the dropped card from the drop's own payload (the id `beginDrag` wrote), never from `dragging`: a drag that
    /// ended outside every zone cannot leave state that a later drop would act on. The drag state is cleared first.
    private func takeDrop(_ providers: [NSItemProvider], move: @escaping @MainActor (UUID) -> Void) -> Bool {
        endDrag()
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(Self.dragType.identifier) }) else {
            return false
        }
        provider.loadDataRepresentation(forTypeIdentifier: Self.dragType.identifier) { data, _ in
            guard let data, let text = String(data: data, encoding: .utf8), let id = UUID(uuidString: text) else { return }
            Task { @MainActor in move(id) }
        }
        return true
    }

    /// The strip after the last card: dropping a card here moves it to the end.
    private func endDropZone(count: Int) -> some View {
        let isTarget = endTargeted && dragging != nil
        return Rectangle()
            .fill(Color.clear)
            .frame(height: 28)
            .overlay(alignment: .top) {
                if isTarget { Rectangle().fill(ShellStyle.color(.accent)).frame(height: 2).padding(.horizontal, 10) }
            }
            .contentShape(Rectangle())
            .onDrop(of: [Self.dragType], isTargeted: $endTargeted) { providers in
                takeDrop(providers) { source in
                    guard let from = session.document?.actions.firstIndex(where: { $0.id == source }) else { return }
                    session.update { $0.moveAction(source, by: count - 1 - from) }
                }
            }
            .accessibilityHidden(true)
    }

    private func binding(_ card: ActionDraft) -> Binding<ActionDraft> {
        let id = card.id
        return Binding(
            get: { session.document?.actions.first { $0.id == id } ?? card },
            set: { new in
                session.update { document in
                    if let index = document.actions.firstIndex(where: { $0.id == id }) { document.actions[index] = new }
                }
            })
    }

    /// The warnings of the last check; before any check the two that cost nothing to see live.
    private func warnings(of card: ActionDraft, built: [ActionWarning]) -> [ActionWarning] {
        if let known = session.validation?.warnings[card.id] { return known }
        guard session.validation == nil, card.type == .hide || card.type == .returnHandwritten else { return [] }
        return built
    }

    private func issues(of id: UUID) -> [ActionField: RuleDraftIssue] {
        var result: [ActionField: RuleDraftIssue] = [:]
        for (key, issue) in session.validation?.issues ?? [:] {
            if case .action(id, let field) = key { result[field] = issue }
        }
        return result
    }
}

// MARK: notices

/// The warning or error icon of a card with the number of its notices; hovering shows them as a tooltip, a click opens the list.
private struct ActionNoticeBadge: View {
    let index: Int
    let notices: [ActionCardNotice]

    @State private var isOpen = false

    private var hasError: Bool { notices.contains { $0.isError } }

    var body: some View {
        let tint = hasError ? Palette.failureColor : Palette.pendingColor
        let summary = L10n.format(hasError ? "rules.card.errorCount" : "rules.card.noticeCount", index + 1, notices.count)
        Button { isOpen = true } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: hasError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(tint)
                    .frame(width: 26, height: BuilderDropdownLabel<EmptyView>.height)
                Text(verbatim: String(notices.count))
                    .font(.system(size: 9, weight: .bold).monospacedDigit())
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 4)
                    .background(Capsule().fill(tint))
                    .offset(x: 2, y: 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(notices.map { L10n.string($0.textKey) }.joined(separator: "\n"))
        .accessibilityLabel(summary)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(notices.enumerated()), id: \.offset) { _, notice in
                    let kind = L10n.string(notice.isError ? "rules.card.noticeKind.error" : "rules.card.noticeKind.warning")
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: notice.isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(notice.isError ? Palette.failureColor : Palette.pendingColor)
                        Text(L10n.string(notice.textKey))
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(L10n.format("rules.card.noticeItem", kind, L10n.string(notice.textKey)))
                }
            }
            .padding(12)
            .frame(width: 340, alignment: .leading)
        }
    }
}

// MARK: card

/// One action: number, type, key, notices, order, copy and delete; the type's editor; the one-line explanation, the
/// "stop processing" checkbox and the state.
struct ActionCardView: View {
    let session: RuleEditorSession
    let store: FlowStore
    @Binding var action: ActionDraft
    let index: Int
    let count: Int
    let state: ActionCardState
    let notices: [ActionCardNotice]
    let warnings: [ActionWarning]
    let issues: [ActionField: RuleDraftIssue]
    /// Starts a drag of this card; the column keeps which card it is.
    let beginDrag: () -> NSItemProvider

    @State private var showsTypes = false
    @State private var showsHint = false
    @State private var showsStopHint = false

    private var isBlocked: Bool { if case .blocked = state { true } else { false } }
    private var isUnreachable: Bool { state == .unreachable }
    private static var indent: CGFloat { 30 }
    private static let typeDropdownIdealWidth = RuleBuilderMetrics.actionTypeIdealWidth()

    var body: some View {
        let problems = ActionIssues(issues: issues, limits: session.limits)
        let descriptor = ActionEditorDescriptor(draft: action)
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 8) {
                header(descriptor)
                VStack(alignment: .leading, spacing: 8) {
                    // The badge and the banner carry every reason except a blocked type, which has no notice: its
                    // sentence shows here, unless the last check already put the same reason under the type.
                    if case .blocked = state, issues[.type] == nil, let key = state.explanationKey {
                        Text(L10n.string(key))
                            .font(.caption)
                            .foregroundStyle(Palette.failureColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    problems.line(.type)
                    if action.isOpaque {
                        RuleHelpText(text: L10n.string("rules.card.opaque"))
                    } else {
                        parameters(problems, descriptor)
                    }
                    hint
                    stopRow
                    problems.line(.final)
                }
                .padding(.leading, Self.indent)
            }
            .overlay {
                if isBlocked { RoundedRectangle(cornerRadius: 8).stroke(Palette.failureColor, lineWidth: 1.5).padding(-6) }
            }
            .opacity(isUnreachable ? 0.5 : 1)
            ForEach(warnings, id: \.self) { warning in
                Label(L10n.string(warning.localizationKey), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Palette.pendingColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Self.indent)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.format("rules.card.number", index + 1))
        .accessibilityAction(named: Text(L10n.string("rules.list.moveUp"))) { move(-1) }
        .accessibilityAction(named: Text(L10n.string("rules.list.moveDown"))) { move(1) }
        .contextMenu { moveButtons }
    }

    // MARK: header

    private func header(_ descriptor: ActionEditorDescriptor) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                numberCircle
                typeDropdown
                keyField(descriptor).frame(minWidth: 100, idealWidth: 140, maxWidth: 170)
                Spacer(minLength: 0)
                controls
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    numberCircle
                    typeDropdown
                    Spacer(minLength: 0)
                    controls
                }
                keyField(descriptor).padding(.leading, Self.indent)
            }
        }
        // The key's suggestion list hangs over what is below.
        .zIndex(1)
    }

    private var numberCircle: some View {
        Text(verbatim: String(index + 1))
            .font(.caption.weight(.semibold).monospacedDigit())
            .frame(width: 22, height: 22)
            .overlay(Circle().strokeBorder(ShellStyle.color(.separator), lineWidth: 1))
            .accessibilityLabel(L10n.format("rules.card.number", index + 1))
    }

    private var typeDropdown: some View {
        Button { showsTypes = true } label: {
            BuilderDropdownLabel(
                title: L10n.string(action.type.titleKey),
                tag: action.type.isLegacyOnly ? L10n.string("rules.editor2.legacyTag") : nil
            ) {
                ConditionDirectionIcon(direction: action.type.direction)
            }
        }
        .buttonStyle(.plain)
        .frame(minWidth: 130, idealWidth: Self.typeDropdownIdealWidth, maxWidth: 240)
        .help(action.type.direction.title())
        .accessibilityLabel(actionFieldLabel(index: index, "rules.card.type"))
        .accessibilityValue(L10n.format("rules.editor3.fieldValue", L10n.string(action.type.titleKey), action.type.direction.title()))
        .popover(isPresented: $showsTypes, arrowEdge: .bottom) {
            ActionTypePicker(
                availability: { session.document?.availability(of: $0, replacing: action.id) ?? .available },
                selected: action.type
            ) { type in
                showsTypes = false
                let id = action.id
                session.update { $0.changeType(of: id, to: type) }
            }
        }
    }

    @ViewBuilder private func keyField(_ descriptor: ActionEditorDescriptor) -> some View {
        if !action.isOpaque, descriptor.showsKey {
            ActionKeyField(store: store, index: index, descriptor: descriptor, action: $action)
        }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            if !notices.isEmpty { ActionNoticeBadge(index: index, notices: notices) }
            dragHandle
            Menu {
                moveButtons
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(IconSquareButtonStyle(side: BuilderDropdownLabel<EmptyView>.height))
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L10n.format("rules.card.more", index + 1))
            .accessibilityLabel(L10n.format("rules.card.more", index + 1))
            Button {
                let id = action.id
                session.update { $0.duplicateAction(id) }
            } label: {
                Image(systemName: "plus.square.on.square")
            }
            .buttonStyle(IconSquareButtonStyle(side: BuilderDropdownLabel<EmptyView>.height))
            .help(L10n.string("rules.builder.duplicateAction"))
            .accessibilityLabel(L10n.string("rules.builder.duplicateAction"))
            Button {
                let id = action.id
                session.update { $0.removeAction(id) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(DeleteSquareButtonStyle())
            .disabled(!(session.document?.canRemoveAction ?? false))
            .help(L10n.string("rules.builder.deleteAction"))
            .accessibilityLabel(L10n.string("rules.builder.deleteAction"))
        }
    }

    /// Dragging this grip reorders the cards; the menu next to it does the same from the keyboard.
    private var dragHandle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 12))
            .foregroundStyle(ShellStyle.color(.textSecondary))
            .frame(width: 18, height: BuilderDropdownLabel<EmptyView>.height)
            .contentShape(Rectangle())
            .onDrag {
                beginDrag()
            } preview: {
                Text(L10n.format("rules.card.dragPreview", index + 1, L10n.string(action.type.titleKey)))
                    .font(.system(size: 13))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: ShellStyle.cornerRadius).fill(ShellStyle.color(.content)))
                    .overlay(RoundedRectangle(cornerRadius: ShellStyle.cornerRadius).strokeBorder(ShellStyle.color(.separator), lineWidth: 1))
            }
            .help(L10n.format("rules.card.dragHandle", index + 1))
            .accessibilityElement()
            .accessibilityLabel(L10n.format("rules.card.dragHandle", index + 1))
    }

    @ViewBuilder private var moveButtons: some View {
        Button(L10n.string("rules.list.moveUp")) { move(-1) }
            .disabled(index == 0)
        Button(L10n.string("rules.list.moveDown")) { move(1) }
            .disabled(index >= count - 1)
    }

    private func move(_ delta: Int) {
        let id = action.id
        guard index + delta >= 0, index + delta < count else { return }
        session.update { $0.moveAction(id, by: delta) }
    }

    // MARK: description and stop processing

    /// The one-line explanation of the type on a grey strip; a click opens the whole text.
    private var hint: some View {
        Button { showsHint.toggle() } label: {
            HStack(alignment: .top, spacing: 4) {
                Image(systemName: showsHint ? "chevron.down" : "chevron.right").font(.caption2).frame(width: 10, height: 14)
                Text(L10n.string(action.type.hintKey))
                    .font(.caption)
                    .lineLimit(showsHint ? nil : 1)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: showsHint)
                Spacer(minLength: 0)
            }
            .foregroundStyle(ShellStyle.color(.textSecondary))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: ShellStyle.cornerRadius).fill(ShellStyle.color(.sidebar)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.string(action.type.hintKey))
        .accessibilityValue(L10n.string(showsHint ? "rules.card.hint.expanded" : "rules.card.hint.collapsed"))
    }

    /// "Stop processing more rules" with its ⓘ; ticked and locked for an action that ends the pass by nature.
    private var stopRow: some View {
        let stop = RuleBuilderPresentation.stopProcessing(for: action)
        let hintKey = RuleBuilderPresentation.stopProcessingHintKey(for: action)
        return HStack(spacing: 6) {
            Toggle(
                L10n.string("rules.builder.stop"),
                isOn: Binding(get: { stop.isOn }, set: { action.isFinal = $0 })
            )
            .toggleStyle(.checkbox)
            .font(.system(size: 13))
            .disabled(stop.isLocked)
            .accessibilityLabel(L10n.string("rules.builder.stop"))
            Button { showsStopHint.toggle() } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(ShellStyle.color(.textSecondary))
            }
            .buttonStyle(.plain)
            .help(L10n.string(hintKey))
            .accessibilityLabel(L10n.string(hintKey))
            .popover(isPresented: $showsStopHint, arrowEdge: .bottom) {
                Text(L10n.string(hintKey))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(width: 280, alignment: .leading)
            }
            Spacer(minLength: 8)
            if let key = state.labelKey {
                Text(L10n.string(key))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Palette.pendingColor.opacity(0.2)))
                    .foregroundStyle(state == .final ? Palette.pendingColor : .secondary)
            }
        }
    }

    // MARK: parameters

    @ViewBuilder private func parameters(_ problems: ActionIssues, _ descriptor: ActionEditorDescriptor) -> some View {
        switch action.type {
        case .modifyURL, .modifyQuery, .editRequestHeaders, .editResponseHeaders, .editRequestCookies, .editResponseCookies,
            .rewriteRequestBody, .rewriteResponseBody, .rewriteStatus, .delay, .comment, .magicString:
            ActionEditForm(session: session, store: store, index: index, descriptor: descriptor, action: $action, issues: problems)
        case .mapRemote: MapRemoteForm(action: $action, issues: problems)
        case .requestBreakpoint, .responseBreakpoint: BreakpointNotes(session: session, descriptor: descriptor)
        case .returnFile: ReturnFileForm(session: session, action: $action, issues: problems)
        case .returnDirectory: ReturnDirectoryForm(session: session, action: $action, issues: problems)
        case .returnHandwritten: HandwrittenForm(session: session, index: index, action: $action, issues: problems)
        case .returnPreset: PresetForm(index: index, descriptor: descriptor, action: $action, issues: problems)
        case .mark: MarkForm(index: index, descriptor: descriptor, action: $action, issues: problems)
        case .closeConnectionGraceful, .closeConnectionReset, .returnConnectTunnel, .noDecrypt, .hide: EmptyView()
        }
    }
}
