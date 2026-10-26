import AppCore
import AppKit
import FlowStore
import Localization
import os
import RulesEngine
import SwiftUI

/// The rule editor window in the rule-builder layout: the name on top, the conditions on the left, the actions on the
/// right, Cancel and Save at the bottom. It edits the one document of the app-lifetime `RuleEditorSession`; nothing is written until Save.
/// The window's shortcuts (⌘S, ⇧⌘N, ⇧⌘A; Esc does nothing here) belong to its buttons, so they work only while this window is key.
struct RuleEditorWindow: View {
    let session: RuleEditorSession
    let store: FlowStore
    let flowList: FlowListModel

    @Environment(\.openWindow) private var openWindow
    /// What to do once a save that needed the user's go-ahead has been confirmed.
    private enum AfterSave { case stay, close, continueSwitch }

    /// Weak: the window owns this view, not the other way round.
    @State private var window = WeakWindow()
    @State private var chromeKeeper: RuleEditorWindowChrome.ChromeKeeper?
    @FocusState private var nameFocused: Bool
    /// 1100 pt for Chinese; each of the two columns gets the extra room the language's field and comparison columns take.
    private static let minimumWidth = 1100 + 2 * RuleBuilderMetrics.conditionRowExtraWidth()
    @State private var askingPending = false
    private struct Confirmation { var items: [RuleDocumentConfirmation]; var after: AfterSave }
    @State private var confirmation: Confirmation?
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            if let document = session.document {
                topBar(document)
                if session.hasExternalChange { externalChangeBanner }
                if let count = session.validation?.issues.count, count > 0 { errorBanner(count) }
                // Two boxes side by side with no divider between them.
                HStack(alignment: .top, spacing: 0) {
                    RuleConditionsColumn(session: session, store: store, flowList: flowList, showMatches: showMatches)
                        .frame(minWidth: 420, maxWidth: .infinity)
                    // 12 pt of padding on the outer edges and 8 on the inner ones leaves a 16 pt gap between the boxes.
                    RuleActionsColumn(session: session, store: store)
                        .frame(minWidth: 420, maxWidth: .infinity)
                }
                Divider()
                bottomBar
            } else {
                Text(L10n.string("rules.editor2.empty"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: Self.minimumWidth, minHeight: 640)
        // Plain white, running up under the (transparent) title bar so the name field sits beside the traffic lights.
        .background(ShellStyle.color(.content).ignoresSafeArea())
        .ignoresSafeArea(.container, edges: .top)
        // The title stays for the Window menu and VoiceOver; it is not drawn.
        .navigationTitle(RuleEditorWindowPresentation.windowTitle(isNew: session.isNew))
        .background(WindowReader { target in
            // A transient nil (the view between windows) says nothing about the window: keep what is there.
            guard let target else { return }
            // The chrome is applied once, when the window first appears, not on every edit.
            if window.value !== target {
                chromeKeeper = RuleEditorWindowChrome.keep(target)
                window.value = target
            }
            // The red button and ⌘W ask about unsaved changes; Cancel (below) never does. The guard belongs to the window
            // and ends with it; installing again on a window that already has one does nothing.
            RuleEditorCloseGuard.install(
                on: target, decide: { [session] in session.closeDecision() }, discard: { [session] in session.discard() },
                requestSave: { await save(then: .close) })
        })
        .onAppear { focusFirstInput() }
        .onChange(of: session.document?.id) { _, _ in focusFirstInput() }
        // Another writer (MCP, the outline's group operations) changed the saved rules: follow, or surface the conflict.
        .onChange(of: session.modelRevision) { _, _ in session.reconcile() }
        .task(id: session.pendingSwitch) { askingPending = session.pendingSwitch != nil }
        .alert(L10n.string("rules.editor2.pending.title"), isPresented: $askingPending) {
            Button(L10n.string("rules.editor2.pending.save")) { Task { await savePendingSwitch() } }
            Button(L10n.string("rules.editor2.pending.discard"), role: .destructive) {
                Task { await session.resolvePendingSwitch(.discard) }
            }
            Button(L10n.string("rules.editor2.pending.cancel"), role: .cancel) {
                Task { await session.resolvePendingSwitch(.cancel) }
            }
        } message: {
            Text(L10n.string("rules.editor2.pending.message"))
        }
        .confirmationDialog(
            confirmation?.items.first.map { L10n.string($0.titleKey) } ?? "",
            isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { dismissConfirmation() } }),
            titleVisibility: .visible, presenting: confirmation
        ) { asked in
            Button(L10n.string("rules.editor2.pending.save")) {
                confirmation = nil
                Task { await save(then: asked.after, confirmed: true) }
            }
            Button(L10n.string("rules.editor2.pending.cancel"), role: .cancel) { dismissConfirmation() }
        } message: { asked in
            Text(asked.items.first.map { L10n.string($0.messageKey) } ?? "")
        }
    }

    /// The question went away without an answer: a pending switch is cancelled so no question stays without a window.
    private func dismissConfirmation() {
        guard let asked = confirmation else { return }
        confirmation = nil
        if asked.after == .continueSwitch { Task { await session.resolvePendingSwitch(.cancel) } }
    }

    // MARK: top bar

    /// A new rule opens with the cursor in its first (empty) condition value; an existing one in the name.
    private func focusFirstInput() {
        if !session.isNew { nameFocused = true }
    }

    /// The name sits on the traffic-light row, left-aligned right of the three buttons.
    private func topBar(_ document: RuleDocument) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(L10n.string("rules.builder.nameRequiredLabel"))
                    .font(.system(size: 13))
                TextField(
                    RuleEditorWindowPresentation.autoName(), text: documentBinding(\.name, default: "")
                )
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($nameFocused)
                .builderBordered()
                .overlay {
                    // The focused name field shows the accent border, as in the reference.
                    RoundedRectangle(cornerRadius: ShellStyle.cornerRadius)
                        .strokeBorder(ShellStyle.color(.accent), lineWidth: nameFocused ? 1 : 0)
                }
                .frame(width: 260)
                .accessibilityLabel(L10n.string("rules.builder.nameField.accessibility"))
            }
            RuleDocumentIssueText(session: session, field: .name)
        }
        // 78 pt clears the traffic lights; the 6 pt top puts the 28 pt field on their centre line (40 pt title bar).
        .padding(.leading, RuleEditorWindowChrome.trafficLightsWidth)
        .padding(.trailing, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func errorBanner(_ count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(L10n.format("rules.builder.errorBanner", count)).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
        .foregroundStyle(ShellStyle.color(.failure))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(ShellStyle.color(.failure).opacity(0.12))
        .accessibilityElement(children: .combine)
    }

    private var externalChangeBanner: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Palette.pendingColor)
                Text(L10n.string("rules.editor2.external.message")).frame(maxWidth: .infinity, alignment: .leading)
                Button(L10n.string("rules.editor2.external.keepMine")) { session.keepMyVersion() }
                Button(L10n.string("rules.editor2.external.reload")) { session.reloadSaved() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Palette.pendingColor.opacity(0.12))
            Divider()
        }
    }

    // MARK: bottom bar

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Spacer()
            if let message {
                Text(message).font(.caption).foregroundStyle(ShellStyle.color(.failure)).textSelection(.enabled)
            }
            cancelButton
            Button(L10n.string("rules.builder.save")) { Task { await save(then: .stay) } }
                .buttonStyle(PrimaryButtonStyle(minHeight: 28))
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!canSave)
                .accessibilityLabel(L10n.string("rules.builder.save"))
        }
        .padding(12)
    }

    private var cancelButton: some View {
        Button(L10n.string("rules.builder.cancel")) { cancel() }
            // No Esc shortcut (R8F3-5): the reference's rule editor ignores Esc; an open suggestion list, popover or menu takes it itself.
            .buttonStyle(OutlineButtonStyle(minHeight: 28))
            .disabled(session.isBusy)
            .accessibilityLabel(L10n.string("rules.builder.cancel"))
    }

    private var canSave: Bool {
        RuleBuilderPresentation.canSave(
            hasDocument: session.document != nil, isBusy: session.isBusy, isImporting: session.importState == .importing)
    }

    // MARK: actions

    /// Cancel closes at once, without a question, and drops the unsaved edits (R8F3-8, as the reference does).
    private func cancel() {
        closeWindow(discarding: true)
    }

    /// The document is dropped only when there is a window to close, so a Cancel that cannot close loses nothing.
    private func closeWindow(discarding: Bool) {
        guard let target = window.value else { return }
        if discarding { session.discard() }
        message = nil
        target.close()
    }

    /// Saves; a problem shows under the bar, a question that needs the user's go-ahead is asked and the save resumes.
    private func save(then after: AfterSave, confirmed: Bool = false) async {
        message = nil
        let result = await session.save(confirmed: confirmed)
        switch result {
        case .saved:
            switch after {
            case .stay: break
            case .close: closeWindow(discarding: true)
            case .continueSwitch: await session.resolvePendingSwitch(.save)
            }
        case .needsConfirmation(let items):
            confirmation = Confirmation(items: items, after: after)
        case .invalid, .failed, .busy:
            message = RuleEditorWindowPresentation.failureMessage(result)
            // The user stays with the rule they were editing.
            if after == .continueSwitch { await session.resolvePendingSwitch(.cancel) }
        }
    }

    private func savePendingSwitch() async {
        await save(then: .continueSwitch)
    }

    private func showMatches(_ ids: [Int]) {
        flowList.showRuleMatches(ids: ids)
        MainWindowLocator.bringToFront(openWindow: openWindow)
    }

    /// Edits go through the session, which ignores them while a save runs.
    private func documentBinding<Value>(_ path: WritableKeyPath<RuleDocument, Value>, default fallback: Value) -> Binding<Value> {
        Binding(
            get: { session.document?[keyPath: path] ?? fallback },
            set: { new in session.update { $0[keyPath: path] = new } })
    }
}

// MARK: left column

/// Conditions: how they combine, which of the matching exchanges count, the rows, the judgment point and the live count.
private struct RuleConditionsColumn: View {
    let session: RuleEditorSession
    let store: FlowStore
    let flowList: FlowListModel
    let showMatches: ([Int]) -> Void

    var body: some View {
        if let document = session.document {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.string("rules.builder.conditions")).font(.headline)
                GeometryReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            header(document)
                                .padding(10)
                            ForEach(Array(document.conditions.rows.enumerated()), id: \.element.id) { index, row in
                                Divider()
                                ConditionRowView(
                                    session: session, rowID: row.id, store: store,
                                    focusValueOnAppear: session.isNew && row.id == document.conditions.rows.first?.id)
                                    // An earlier row's suggestion list draws over the rows under it.
                                    .zIndex(Double(document.conditions.rows.count - index))
                            }
                            RuleDocumentIssueText(session: session, field: .conditions).padding(.horizontal, 10)
                            if let text = document.conditions.deprecationText() {
                                ConditionDeprecationCard(text: text).padding(.horizontal, 10).padding(.top, 4)
                            }
                            ConditionGroupCountLine(
                                group: document.conditions.conditionGroup(limits: session.limits), store: store, showMatches: showMatches
                            )
                            .id(document.id)
                            .padding(10)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: ShellStyle.cornerRadius).fill(ShellStyle.color(.content)))
                        .overlay(RoundedRectangle(cornerRadius: ShellStyle.cornerRadius).strokeBorder(ShellStyle.color(.separator), lineWidth: 1))
                        // The scrolled area fills the viewport, so a suggestion list may hang below the last row.
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .topLeading)
                    }
                    // A suggestion list opens upward when the viewport has no room for it below the box.
                    .coordinateSpace(name: SuggestionViewport.space)
                    .environment(\.suggestionViewportHeight, proxy.size.height)
                }
            }
            .padding(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 8))
        }
    }

    /// "当 [满足全部条件 ⌄] 时 [不限次数 ⌄] [N]", then the judgment line with the info mark and "＋ 添加条件".
    private func header(_ document: RuleDocument) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(L10n.string("rules.builder.when")).font(.system(size: 13))
                modeDropdown(document)
                Text(L10n.string("rules.builder.header.then")).font(.system(size: 13))
                occurrenceDropdown(document)
                occurrenceCount(document)
            }
            RuleDocumentIssueText(session: session, field: .occurrence)
            HStack(spacing: 6) {
                ConditionExecutionLineView(line: document.conditions.executionLine())
                Spacer(minLength: 8)
                Button {
                    session.update { $0.conditions.addRow() }
                } label: {
                    Label(L10n.string("rules.builder.addCondition"), systemImage: "plus")
                }
                .buttonStyle(OutlineButtonStyle(minHeight: 28))
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .accessibilityLabel(L10n.string("rules.builder.addCondition"))
            }
            .font(.system(size: 13))
        }
    }

    private func modeDropdown(_ document: RuleDocument) -> some View {
        BuilderDropdown(
            label: L10n.string("rules.editor2.mode.label"),
            options: [ConditionGroup.Mode.all, .any, .none].map {
                BuilderDropdown.Option(value: $0, title: RuleEditorWindowPresentation.headerModeTitle($0))
            },
            selection: Binding(
                get: { session.document?.conditions.mode ?? document.conditions.mode },
                set: { new in session.update { $0.conditions.mode = new } }))
    }

    private func occurrenceDropdown(_ document: RuleDocument) -> some View {
        BuilderDropdown(
            label: L10n.string("rules.editor2.occurrence.label"),
            options: [false, true].map { BuilderDropdown.Option(value: $0, title: ConditionEditorPresentation.title(specific: $0)) },
            selection: Binding(
                get: { session.document?.conditions.occurrence.isSpecific ?? document.conditions.occurrence.isSpecific },
                set: { specific in session.update { $0.conditions.occurrence.setSpecific(specific) } }))
    }

    /// For a rule loaded with a range such as 3...5, the original range (the box shows only its upper bound).
    private func occurrenceLegacyHelp(_ document: RuleDocument) -> String? {
        let occurrence = session.document?.conditions.occurrence ?? document.conditions.occurrence
        return occurrence.preservedLegacyRange.map {
            L10n.format("rules.editor2.occurrence.legacyHelp", $0.lowerBound, $0.upperBound)
        }
    }

    @ViewBuilder private func occurrenceCount(_ document: RuleDocument) -> some View {
        if document.conditions.occurrence.isSpecific {
            TextField(L10n.string("rules.editor2.occurrence.count"), text: Binding(
                get: { session.document?.conditions.occurrence.countText ?? document.conditions.occurrence.countText },
                set: { new in session.update { $0.conditions.occurrence.setCountText(new) } }))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .builderBordered()
                .frame(minWidth: 60, maxWidth: .infinity)
                .accessibilityLabel(L10n.string("rules.editor2.occurrence.count"))
                .help(occurrenceLegacyHelp(document) ?? "")
        }
    }
}

// MARK: window handle

/// The hosting window, held weakly.
@MainActor private final class WeakWindow {
    weak var value: NSWindow?
}

/// Hands the hosting `NSWindow` to the view (to close it from Cancel).
private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        Task { @MainActor [weak view] in onWindow(view?.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        Task { @MainActor [weak view] in onWindow(view?.window) }
    }
}


// MARK: window chrome

/// The rule editor window's frame: no drawn title, content up under a transparent title bar, a compact title bar
/// 40 pt high (an empty unified-compact toolbar gives that height) so the traffic lights sit on the name field's line.
///
/// R8F3 root cause of the vanishing name field: the name field is ordinary content under a transparent title bar, so it is
/// visible only while `titlebarAppearsTransparent` and a hidden title hold. They were set once, but SwiftUI owns the window's
/// title and toolbar state and re-applies it when the window updates (a popover or menu taking and returning key status,
/// a title refresh), which put back the drawn title and an opaque title bar over the field. The chrome is therefore
/// idempotent and kept: `keep(_:)` re-checks it on every window update and key change and re-asserts only what drifted.
@MainActor enum RuleEditorWindowChrome {
    /// The traffic lights and the gap after them.
    static let trafficLightsWidth: CGFloat = 78
    static let toolbarIdentifier = "rule-editor-chrome"

    /// The empty, fixed toolbar that gives the compact title bar its height.
    static func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: toolbarIdentifier)
        // No customisation sheet (View > Hide Toolbar can still hide it; native check).
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.displayMode = .iconOnly
        return toolbar
    }

    /// Sets whatever of the chrome is not already so; returns whether it had to change anything. A toolbar of ours is added
    /// only when the window has none: SwiftUI's own toolbar is never replaced (it would fight SwiftUI for the slot).
    /// A repair puts back `toolbar` (the keeper's cached one) instead of building a new toolbar each time.
    @discardableResult static func apply(to window: NSWindow, toolbar cached: NSToolbar? = nil) -> Bool {
        var changed = false
        if window.titleVisibility != .hidden { window.titleVisibility = .hidden; changed = true }
        if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true; changed = true }
        if !window.styleMask.contains(.fullSizeContentView) { window.styleMask.insert(.fullSizeContentView); changed = true }
        if window.toolbar == nil {
            window.toolbar = cached ?? makeToolbar()
            changed = true
        }
        // Visibility is asserted only for our own toolbar; one SwiftUI owns is left as it is.
        if window.toolbar?.identifier == toolbarIdentifier, window.toolbar?.isVisible != true {
            window.toolbar?.isVisible = true
            changed = true
        }
        // The compact style is ours to ask for only with our own toolbar; a toolbar SwiftUI owns keeps its style (the
        // transparent title bar and hidden title above are what keep the name field visible).
        if ours(window), window.toolbarStyle != .unifiedCompact { window.toolbarStyle = .unifiedCompact; changed = true }
        if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none; changed = true }
        return changed
    }

    /// Everything `apply` sets still holds.
    static func isIntact(_ window: NSWindow) -> Bool {
        window.titleVisibility == .hidden && window.titlebarAppearsTransparent
            && window.styleMask.contains(.fullSizeContentView) && window.toolbar != nil
            && (window.toolbar?.identifier != toolbarIdentifier || window.toolbar?.isVisible == true)
            && (!ours(window) || window.toolbarStyle == .unifiedCompact) && window.titlebarSeparatorStyle == .none
    }

    private static func ours(_ window: NSWindow) -> Bool { window.toolbar?.identifier == toolbarIdentifier }

    /// Applies the chrome and re-asserts it whenever the window updates or its key status changes. Stops with the window.
    static func keep(_ window: NSWindow) -> ChromeKeeper {
        ChromeKeeper(window: window)
    }

    /// Selector-based observers go away with their owner, so there is nothing to remove by hand: releasing the keeper
    /// stops the repairs.
    ///
    /// A window that puts its state back after every repair is not fought forever: more than `maxRepairsInWindow` repairs
    /// within `repairWindow` seconds (an intact check in between does not reset that) or `maxLifetimeRepairs` repairs in
    /// all, and the keeper gives up and says so in the log.
    @MainActor final class ChromeKeeper: NSObject {
        static let notificationNames: [Notification.Name] = [
            NSWindow.didUpdateNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didResizeNotification, NSWindow.didEndSheetNotification,
        ]
        /// More than this many repairs within `repairWindow` is a ping-pong with the window: the keeper gives up.
        static let maxRepairsInWindow = 3
        static let repairWindow: TimeInterval = 2
        /// However slowly it goes, the keeper does not repair one window more often than this in its whole life.
        static let maxLifetimeRepairs = 20
        private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ProxyWoman", category: "RuleEditorChrome")

        private let toolbar = RuleEditorWindowChrome.makeToolbar()
        private let log: @MainActor (String) -> Void
        /// A repair already ran in this run-loop turn: a window that puts its state back at once is left alone until the
        /// next turn instead of being fought over inside one.
        private var repairedThisTurn = false
        private let now: @MainActor () -> TimeInterval
        /// All repairs so far, and when the recent ones happened.
        private(set) var repairCount = 0
        private var recentRepairs: [TimeInterval] = []
        private(set) var gaveUp = false

        init(
            window: NSWindow, log: (@MainActor (String) -> Void)? = nil,
            now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        ) {
            self.now = now
            self.log = log ?? { Self.logger.notice("\($0, privacy: .public)") }
            super.init()
            RuleEditorWindowChrome.apply(to: window, toolbar: toolbar)
            for name in Self.notificationNames {
                NotificationCenter.default.addObserver(self, selector: #selector(windowChanged(_:)), name: name, object: window)
            }
        }

        @objc private func windowChanged(_ note: Notification) {
            guard let target = note.object as? NSWindow else { return }
            guard !RuleEditorWindowChrome.isIntact(target), !repairedThisTurn, !gaveUp else { return }
            let time = now()
            recentRepairs.removeAll { time - $0 > Self.repairWindow }
            guard recentRepairs.count < Self.maxRepairsInWindow, repairCount < Self.maxLifetimeRepairs else {
                gaveUp = true
                log("rule editor chrome: giving up after \(repairCount) repairs (\(recentRepairs.count) in the last \(Self.repairWindow) s); the window keeps undoing them")
                return
            }
            repairedThisTurn = true
            recentRepairs.append(time)
            repairCount += 1
            RuleEditorWindowChrome.apply(to: target, toolbar: toolbar)
            log("rule editor chrome: repair \(repairCount) (\(recentRepairs.count) in the last \(Self.repairWindow) s, on \(note.name.rawValue))")
            Task { @MainActor [weak self] in self?.repairedThisTurn = false }
        }
    }
}
