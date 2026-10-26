import AppCore
import AppKit
import Testing
@testable import ProxyWoman

/// R8F3-8: the red button and ⌘W ask about unsaved changes; the guard decides from the session's close decision. The
/// window's own delegate is never replaced, and the guard leaves nothing behind once the window has closed.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)), .productionChinese) struct RuleEditorCloseGuardTests {
    @MainActor private final class Log {
        var discards = 0
        var saves = 0
        /// The guard holds its window weakly, so the test keeps it.
        var windows: [NSWindow] = []
        var prompts: [RuleEditorWindowPresentation.ClosePrompt] = []
        /// While set, a save has started and not finished.
        var saveGate: CheckedContinuation<Void, Never>?
    }

    private static func window() -> NSWindow {
        // Not deferred, so the window has a number and key events can name it; it is never ordered front.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func make(
        _ decision: RuleEditorSession.CloseDecision, answer: RuleEditorCloseGuard.Answer?, log: Log, window: NSWindow = RuleEditorCloseGuardTests.window(),
        holdSave: Bool = false
    ) -> (NSWindow, RuleEditorCloseGuard) {
        log.windows.append(window)
        let guardian = RuleEditorCloseGuard.install(
            on: window, decide: { decision }, discard: { log.discards += 1 },
            requestSave: {
                log.saves += 1
                if holdSave { await withCheckedContinuation { log.saveGate = $0 } }
            },
            ask: { prompt, _, reply in
                log.prompts.append(prompt)
                if let answer { reply(answer) }
            },
            // The test windows are never ordered front.
            requiresVisibleWindow: false)!
        return (window, guardian)
    }

    // MARK: the questions

    @Test func aCleanDocumentClosesWithoutAQuestionAndIsDropped() {
        let log = Log()
        let (window, guardian) = make(.closeNow, answer: nil, log: log)
        window.orderOut(nil)
        guardian.requestClose()
        #expect(log.prompts.isEmpty && log.discards == 1)
        #expect(!guardian.isActive)
    }

    @Test func unsavedChangesAskAndKeepTheWindowOpen() {
        let log = Log()
        let (_, guardian) = make(.askSave(name: "x"), answer: .cancel, log: log)
        guardian.requestClose()
        #expect(log.prompts.count == 1 && log.prompts[0].canSave)
        #expect(log.discards == 0 && log.saves == 0)
        #expect(guardian.isActive && !guardian.asking)
    }

    @Test func saveSavesAndKeepsAskingOffUntilTheSaveHasFinished() async {
        let log = Log()
        let (_, guardian) = make(.askSave(name: "x"), answer: .save, log: log, holdSave: true)
        guardian.requestClose()
        while log.saveGate == nil { await Task.yield() }
        #expect(log.saves == 1 && log.discards == 0)
        // ⌘W (or the red button) during the save does not ask again.
        #expect(guardian.asking)
        guardian.requestClose()
        #expect(log.prompts.count == 1)
        log.saveGate?.resume()
        while guardian.asking { await Task.yield() }
        guardian.requestClose()
        #expect(log.prompts.count == 2)
    }

    @Test func dontSaveDropsTheEditsAndCloses() {
        let log = Log()
        let (_, guardian) = make(.askDiscardOnly, answer: .dontSave, log: log)
        guardian.requestClose()
        #expect(log.prompts.first?.canSave == false)
        #expect(log.discards == 1 && !guardian.isActive)
    }

    @Test func aSecondCloseWhileTheQuestionIsOpenDoesNotAskAgain() {
        let log = Log()
        let (_, guardian) = make(.askSave(name: "x"), answer: nil, log: log)
        guardian.requestClose()
        guardian.requestClose()
        #expect(log.prompts.count == 1 && guardian.asking)
    }

    // MARK: the window's delegate and the red button

    @MainActor private final class Original: NSObject, NSWindowDelegate {
        var moved = 0
        func windowDidMove(_ notification: Notification) { moved += 1 }
        func windowShouldClose(_ sender: NSWindow) -> Bool { false }
    }

    @Test func theWindowsOwnDelegateIsNeverReplaced() {
        let log = Log()
        let window = Self.window()
        let original = Original()
        window.delegate = original
        let (_, guardian) = make(.askSave(name: "x"), answer: .cancel, log: log, window: window)
        #expect(window.delegate === original)
        // Its messages reach it as before.
        NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: window)
        #expect(original.moved == 1)
        guardian.requestClose()
        window.close()
        #expect(window.delegate === original)
        withExtendedLifetime(original) {}
    }

    @Test func theRedButtonAsksAndIsPutBackWhenTheWindowCloses() throws {
        let log = Log()
        let window = Self.window()
        let button = try #require(window.standardWindowButton(.closeButton))
        let (originalTarget, originalAction) = (button.target, button.action)
        let (_, guardian) = make(.askSave(name: "x"), answer: .cancel, log: log, window: window)
        #expect(button.target === guardian)
        #expect(button.action != originalAction)
        button.performClick(nil)
        #expect(log.prompts.count == 1)
        window.close()
        #expect(button.target === originalTarget && button.action == originalAction)
    }

    @Test func performCloseIsCaughtToo() throws {
        // File > Close sends `performClose:`, which clicks the red button.
        let log = Log()
        let window = Self.window()
        let (_, _) = make(.askSave(name: "x"), answer: .cancel, log: log, window: window)
        window.performClose(nil)
        #expect(log.prompts.count == 1)
    }

    // MARK: ⌘W

    private func keyDown(_ characters: String, _ flags: NSEvent.ModifierFlags, in window: NSWindow) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 13))
    }

    @Test func commandWInThisWindowAsksAndIsSwallowed() throws {
        let log = Log()
        let (window, guardian) = make(.askSave(name: "x"), answer: .cancel, log: log)
        let swallowed = guardian.handleKeyDown(try keyDown("w", .command, in: window))
        #expect(swallowed == nil && log.prompts.count == 1)
    }

    @Test func otherKeysAndOtherWindowsPassThrough() throws {
        let log = Log()
        let (window, guardian) = make(.askSave(name: "x"), answer: .cancel, log: log)
        let other = Self.window()
        for event in [
            try keyDown("w", [], in: window), try keyDown("w", [.command, .shift], in: window), try keyDown("q", .command, in: window),
            try keyDown("w", .command, in: other),
        ] {
            #expect(guardian.handleKeyDown(event) === event)
        }
        #expect(log.prompts.isEmpty)
    }

    @Test func theCloseShortcutIsCommandWOnly() {
        #expect(RuleEditorCloseGuard.isCloseShortcut(characters: "w", modifiers: .command))
        #expect(RuleEditorCloseGuard.isCloseShortcut(characters: "W", modifiers: [.command, .capsLock]))
        #expect(!RuleEditorCloseGuard.isCloseShortcut(characters: "w", modifiers: [.command, .option]))
        #expect(!RuleEditorCloseGuard.isCloseShortcut(characters: "w", modifiers: .control))
        #expect(!RuleEditorCloseGuard.isCloseShortcut(characters: nil, modifiers: .command))
    }

    // MARK: lifetime

    @Test func nothingIsLeftBehindOnceTheWindowHasClosed() {
        weak var weakGuard: RuleEditorCloseGuard?
        weak var weakLog: Log?
        let window = Self.window()
        do {
            let log = Log()
            weakLog = log
            var guardian: RuleEditorCloseGuard? = make(.askSave(name: "x"), answer: .cancel, log: log, window: window).1
            weakGuard = guardian
            guardian = nil
            // The window owns the guard, which owns the closures that capture the log.
            #expect(weakGuard != nil && weakLog != nil)
        }
        window.close()
        #expect(weakGuard == nil)
        #expect(weakLog == nil)
        #expect(RuleEditorCloseGuard.installed(on: window) == nil)
    }

    @Test func aGuardIsInstalledOncePerWindowAndAgainAfterItClosed() {
        let log = Log()
        let (window, first) = make(.closeNow, answer: nil, log: log)
        let (_, again) = make(.closeNow, answer: nil, log: log, window: window)
        #expect(first === again)
        window.close()
        let (_, fresh) = make(.closeNow, answer: nil, log: log, window: window)
        #expect(fresh !== first && fresh.isActive)
        fresh.tearDown()
    }

    // MARK: monitor and button robustness (F3)

    @Test func aWindowThatIsNotVisibleGetsNoGuardByDefault() {
        let window = Self.window()
        let guardian = RuleEditorCloseGuard.install(
            on: window, decide: { .closeNow }, discard: {}, requestSave: {})
        #expect(guardian == nil)
        #expect(RuleEditorCloseGuard.installed(on: window) == nil)
    }

    @Test func theMonitorGoesWhenTheWindowIsFreedWithoutWillClose() {
        let before = RuleEditorCloseGuard.activeMonitorCount
        weak var weakWindow: NSWindow?
        weak var weakGuard: RuleEditorCloseGuard?
        autoreleasepool {
            let log = Log()
            // Deferred: AppKit does not list a window that has no number yet.
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            weakWindow = window
            weakGuard = make(.closeNow, answer: nil, log: log, window: window).1
            log.windows.removeAll()
            #expect(RuleEditorCloseGuard.activeMonitorCount == before + 1)
        }
        #expect(weakWindow == nil && weakGuard == nil)
        #expect(RuleEditorCloseGuard.activeMonitorCount == before)
    }

    @Test func tearDownPutsBackTheCapturedActionAndNeverPerformClose() throws {
        let log = Log()
        let window = Self.window()
        let button = try #require(window.standardWindowButton(.closeButton))
        let custom = Original()
        button.target = custom
        button.action = nil
        let (_, guardian) = make(.closeNow, answer: nil, log: log, window: window)
        guardian.tearDown()
        #expect(button.target === custom && button.action == nil)
    }

    private final class SwappableWindow: NSWindow {
        var closeButton: NSButton?
        override func standardWindowButton(_ b: NSWindow.ButtonType) -> NSButton? {
            b == .closeButton ? closeButton : super.standardWindowButton(b)
        }
    }

    @Test func aChangedCloseButtonIsRetargeted() throws {
        let log = Log()
        let window = SwappableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let old = NSButton(), new = NSButton()
        let oldTarget = Original()
        old.target = oldTarget
        old.action = #selector(NSWindow.performClose(_:))
        new.target = window
        new.action = #selector(NSWindow.performClose(_:))
        window.closeButton = old
        let (_, first) = make(.closeNow, answer: nil, log: log, window: window)
        #expect(old.target === first)
        window.closeButton = new
        let (_, again) = make(.closeNow, answer: nil, log: log, window: window)
        #expect(again === first)
        #expect(new.target === first)
        #expect(old.target === oldTarget && old.action == #selector(NSWindow.performClose(_:)))
        window.close()
        #expect(new.target === window)
        withExtendedLifetime(oldTarget) {}
    }

    // MARK: the sheet's keys

    private func prompt(canSave: Bool) -> RuleEditorWindowPresentation.ClosePrompt {
        RuleEditorWindowPresentation.closePrompt(canSave ? .askSave(name: "x") : .askDiscardOnly)!
    }

    @Test func escapeIsCancelAndCommandDIsDontSave() {
        let (alert, answers) = RuleEditorCloseGuard.makeAlert(prompt(canSave: true))
        #expect(answers == [.save, .dontSave, .cancel])
        #expect(alert.buttons.count == 3)
        #expect(alert.buttons[0].keyEquivalent == "\r")
        #expect(alert.buttons[1].keyEquivalent == "d" && alert.buttons[1].keyEquivalentModifierMask == .command)
        #expect(alert.buttons[2].keyEquivalent == "\u{1b}")
    }

    @Test func anUnsavableRuleOnlyOffersDontSaveAndCancel() {
        let (alert, answers) = RuleEditorCloseGuard.makeAlert(prompt(canSave: false))
        #expect(answers == [.dontSave, .cancel])
        // Don't Save is the default button here and keeps Return.
        #expect(alert.buttons[0].keyEquivalent == "\r")
        #expect(alert.buttons[1].keyEquivalent == "\u{1b}")
    }
}
