import AppCore
import AppKit

/// An event on its way through a local monitor, which AppKit runs on the main thread.
private struct HandedEvent: @unchecked Sendable { let event: NSEvent }

/// The monitor's token, shared with the monitor's own closure so that either side can remove it, once. Removal is guarded
/// by a lock: a guard's `deinit` is not formally main-actor isolated.
private final class MonitorToken: @unchecked Sendable {
    private static let count = LockedCounter()
    private let lock = NSLock()
    private var monitor: Any?

    static var activeCount: Int { count.value }

    init(matching mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> NSEvent?) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler)
        if monitor != nil { Self.count.add(1) }
    }

    func remove() {
        let taken = lock.withLock { () -> Any? in
            defer { monitor = nil }
            return monitor
        }
        guard let taken else { return }
        NSEvent.removeMonitor(taken)
        Self.count.add(-1)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int { lock.withLock { stored } }
    func add(_ delta: Int) { lock.withLock { stored += delta } }
}

/// Hands the monitor's closure its own token, which only exists after the closure does.
private final class TokenBox: @unchecked Sendable { weak var token: MonitorToken? }

/// Asks before the rule editor window closes with unsaved changes (R8F3-8): the red close button and ⌘W both ask; Cancel
/// does not come through here and closes at once.
///
/// SwiftUI owns the window's delegate and this never touches it. Instead:
///  - the red button is retargeted to this guard (`standardWindowButton(.closeButton)`); its original target and action
///    are put back when the window closes. `performClose:` (the File > Close menu item) clicks that button, so it comes
///    through here too;
///  - ⌘W is caught by a local key monitor scoped to this one window. A monitor sees the event before any key-equivalent
///    handling (window views and main menu alike), so it does not depend on the order those two run in.
///
/// The guard is owned by the window (an associated object) and tears itself down on `willClose`: button restored,
/// monitor removed, closures dropped (they capture the editor view), association released. Nothing else keeps it alive.
@MainActor final class RuleEditorCloseGuard: NSObject {
    enum Answer { case save, dontSave, cancel }
    typealias Ask = @MainActor (RuleEditorWindowPresentation.ClosePrompt, NSWindow, @escaping (Answer) -> Void) -> Void

    private weak var window: NSWindow?
    private weak var button: NSButton?
    private weak var originalTarget: AnyObject?
    private var originalAction: Selector?
    private var monitor: MonitorToken?
    private var decide: (() -> RuleEditorSession.CloseDecision)?
    private var discard: (() -> Void)?
    private var requestSave: (@MainActor () async -> Void)?
    private var ask: Ask?
    /// A question or a save that came from it is in progress: another close request meanwhile is ignored.
    private(set) var asking = false
    private(set) var isActive = true

    /// How many key monitors of guards are installed right now (a test hook).
    static var activeMonitorCount: Int { MonitorToken.activeCount }

    /// A selector is a unique, immortal pointer: it serves as the associated-object key.
    private static var associationKey: UnsafeRawPointer {
        unsafeBitCast(Selector(("proxywomanRuleEditorCloseGuard")), to: UnsafeRawPointer.self)
    }

    /// The guard installed on `window`, if it is still active.
    static func installed(on window: NSWindow) -> RuleEditorCloseGuard? {
        (objc_getAssociatedObject(window, associationKey) as? RuleEditorCloseGuard).flatMap { $0.isActive ? $0 : nil }
    }

    /// Installs a guard on `window` unless an active one is already there (which is then pointed at the window's current
    /// red button, should that have changed). `requestSave` saves and closes the window; it returns once the save has
    /// finished (the guard keeps refusing a second close until then). A window that is not on screen (never shown, or
    /// already closed) gets no guard, since no `willClose` could be counted on to end it: the result is then nil.
    @discardableResult static func install(
        on window: NSWindow, decide: @escaping () -> RuleEditorSession.CloseDecision, discard: @escaping () -> Void,
        requestSave: @escaping @MainActor () async -> Void, ask: @escaping Ask = RuleEditorCloseGuard.sheet,
        requiresVisibleWindow: Bool = true
    ) -> RuleEditorCloseGuard? {
        if let existing = installed(on: window) {
            existing.retargetCloseButtonIfChanged()
            return existing
        }
        if requiresVisibleWindow, !window.isVisible { return nil }
        let guardian = RuleEditorCloseGuard(window: window, decide: decide, discard: discard, requestSave: requestSave, ask: ask)
        objc_setAssociatedObject(window, associationKey, guardian, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return guardian
    }

    private init(
        window: NSWindow, decide: @escaping () -> RuleEditorSession.CloseDecision, discard: @escaping () -> Void,
        requestSave: @escaping @MainActor () async -> Void, ask: @escaping Ask
    ) {
        self.window = window
        self.decide = decide
        self.discard = discard
        self.requestSave = requestSave
        self.ask = ask
        // The closure reaches its own token through a box: with the guard gone, the next key event removes the monitor.
        super.init()
        let box = TokenBox()
        let token = MonitorToken(matching: .keyDown) { [weak self, box] event in
            guard let self else {
                box.token?.remove()
                return event
            }
            // AppKit calls local monitors on the main thread; the event never leaves it.
            let handed = HandedEvent(event: event)
            let swallowed = MainActor.assumeIsolated { self.swallowsKeyDown(handed.event) }
            return swallowed ? nil : event
        }
        box.token = token
        monitor = token
        retargetCloseButtonIfChanged()
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: window)
    }

    deinit { monitor?.remove() }

    /// Points the guard at the window's current red button. Nothing happens while it is still the one we hold; a
    /// replaced button is retargeted, and the old one (if it lives) gets its target and action back.
    private func retargetCloseButtonIfChanged() {
        guard let window else { return }
        let current = window.standardWindowButton(.closeButton)
        if let button, button === current { return }
        restoreButton()
        guard let current else { return }
        button = current
        originalTarget = current.target
        originalAction = current.action
        current.target = self
        current.action = #selector(closeRequested(_:))
    }

    /// Puts the held button's target and action back exactly as captured.
    private func restoreButton() {
        if let button, button.target === self {
            button.target = originalTarget
            button.action = originalAction
        }
        button = nil
        originalTarget = nil
        originalAction = nil
    }

    // MARK: closing

    /// The red button.
    @objc private func closeRequested(_ sender: Any?) {
        requestClose()
    }

    /// The window is closing for good (Cancel, Don't Save, a finished save, or an unguarded path): undo everything.
    @objc private func windowWillClose(_ note: Notification) {
        tearDown()
    }

    /// ⌘W in this window; nil swallows the event. Anything else passes on untouched.
    func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        swallowsKeyDown(event) ? nil : event
    }

    fileprivate func swallowsKeyDown(_ event: NSEvent) -> Bool {
        guard isActive, let window, event.window === window,
            Self.isCloseShortcut(characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags)
        else { return false }
        requestClose()
        return true
    }

    static func isCloseShortcut(characters: String?, modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock) == .command && characters?.lowercased() == "w"
    }

    /// A clean document closes at once (and is dropped, so the next open starts from the saved rule); otherwise the
    /// question is asked, once.
    func requestClose() {
        guard isActive, !asking, let window, let decide, let discard, let ask else { return }
        guard let prompt = RuleEditorWindowPresentation.closePrompt(decide()) else {
            discard()
            withExtendedLifetime(self) { window.close() }
            return
        }
        asking = true
        ask(prompt, window) { [weak self] answer in
            guard let self else { return }
            switch answer {
            case .save:
                // `asking` stays set until the save has finished, so ⌘W during it does not ask again.
                guard let requestSave else { asking = false; return }
                Task { @MainActor [weak self] in
                    await requestSave()
                    self?.asking = false
                }
            case .dontSave:
                asking = false
                discard()
                withExtendedLifetime(self) { window.close() }
            case .cancel:
                asking = false
            }
        }
    }

    /// Puts the red button back and lets go of everything. Safe to call more than once.
    func tearDown() {
        guard isActive else { return }
        isActive = false
        restoreButton()
        monitor?.remove()
        monitor = nil
        NotificationCenter.default.removeObserver(self)
        decide = nil
        discard = nil
        requestSave = nil
        ask = nil
        asking = false
        // Last: this may release the guard, which `withExtendedLifetime` keeps alive until the end of the call.
        withExtendedLifetime(self) {
            if let window { objc_setAssociatedObject(window, Self.associationKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
        }
    }

    // MARK: the question

    /// The sheet's buttons and keys: Save is the default button (Return); only Don't Save (default) and Cancel when it
    /// cannot be saved. Esc is Cancel and ⌘D is Don't Save, set explicitly (AppKit guesses them from English titles). When
    /// Don't Save is the first button it is the default button and keeps Return instead of ⌘D.
    static func makeAlert(_ prompt: RuleEditorWindowPresentation.ClosePrompt) -> (NSAlert, [Answer]) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = prompt.message
        alert.informativeText = prompt.detail
        var answers: [Answer] = []
        if prompt.canSave {
            alert.addButton(withTitle: prompt.saveTitle)
            answers.append(.save)
        }
        let discard = alert.addButton(withTitle: prompt.discardTitle)
        answers.append(.dontSave)
        if prompt.canSave {
            discard.keyEquivalent = "d"
            discard.keyEquivalentModifierMask = .command
        } else {
            // The only choice besides Cancel keeps Return explicitly: AppKit would otherwise give a button titled
            // "Don't Save" its own Command-D in some languages and take Return away.
            discard.keyEquivalent = "\r"
        }
        let cancel = alert.addButton(withTitle: prompt.cancelTitle)
        cancel.keyEquivalent = "\u{1b}"
        answers.append(.cancel)
        return (alert, answers)
    }

    static func sheet(_ prompt: RuleEditorWindowPresentation.ClosePrompt, window: NSWindow, answer: @escaping (Answer) -> Void) {
        let (alert, answers) = makeAlert(prompt)
        alert.beginSheetModal(for: window) { response in
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            answer(answers.indices.contains(index) ? answers[index] : .cancel)
        }
    }
}
