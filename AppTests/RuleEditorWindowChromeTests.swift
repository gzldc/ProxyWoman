import AppKit
import Testing
@testable import ProxyWoman

/// R8F3-4: the name field sits under a transparent title bar, so it stays visible only while the chrome holds. SwiftUI
/// re-applies the window's title state when the window updates; the kept chrome puts it back.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)), .productionChinese) struct RuleEditorWindowChromeTests {
    private static func window() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
    }

    @Test func applyHidesTheTitleAndKeepsAnEmptyToolbar() {
        let window = Self.window()
        RuleEditorWindowChrome.apply(to: window)
        #expect(RuleEditorWindowChrome.isIntact(window))
        #expect(window.titleVisibility == .hidden && window.titlebarAppearsTransparent)
    }

    @Test func aSecondApplyWithNothingDriftedDoesNoWork() {
        let window = Self.window()
        #expect(RuleEditorWindowChrome.apply(to: window))
        let toolbar = window.toolbar
        #expect(!RuleEditorWindowChrome.apply(to: window))
        #expect(window.toolbar === toolbar)
    }

    @Test func driftedTitleStateIsPutBackWhenTheWindowUpdates() async throws {
        let window = Self.window()
        let keeper = RuleEditorWindowChrome.keep(window)
        // What SwiftUI does on a popover-driven refresh: the title shows again and the title bar turns opaque.
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.toolbar = nil
        #expect(!RuleEditorWindowChrome.isIntact(window))
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        #expect(RuleEditorWindowChrome.isIntact(window))
        try await Task.sleep(for: .milliseconds(50))
        window.titleVisibility = .visible
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        #expect(window.titleVisibility == .hidden)
        withExtendedLifetime(keeper) {}
    }

    @Test func everyKeptNotificationRepairsDrift() async throws {
        let window = Self.window()
        let clock = Clock()
        let keeper = RuleEditorWindowChrome.ChromeKeeper(window: window, log: { _ in }, now: { clock.now })
        let names: [Notification.Name] = [
            NSWindow.didUpdateNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didResizeNotification, NSWindow.didEndSheetNotification,
        ]
        #expect(Set(RuleEditorWindowChrome.ChromeKeeper.notificationNames) == Set(names))
        for name in names {
            window.titleVisibility = .visible
            #expect(!RuleEditorWindowChrome.isIntact(window))
            NotificationCenter.default.post(name: name, object: window)
            #expect(RuleEditorWindowChrome.isIntact(window), "\(name.rawValue)")
            // Repairs of different notifications are far enough apart not to look like a ping-pong.
            clock.now += 3
            try await Task.sleep(for: .milliseconds(20))
        }
        withExtendedLifetime(keeper) {}
    }

    @Test func releasingTheKeeperStopsRepairs() {
        let window = Self.window()
        var keeper: RuleEditorWindowChrome.ChromeKeeper? = RuleEditorWindowChrome.keep(window)
        #expect(keeper != nil)
        keeper = nil
        window.titleVisibility = .visible
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        #expect(window.titleVisibility == .visible)
    }

    @Test func aRepairReusesTheCachedToolbar() {
        let window = Self.window()
        let keeper = RuleEditorWindowChrome.keep(window)
        let first = window.toolbar
        window.toolbar = nil
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        #expect(window.toolbar === first)
        withExtendedLifetime(keeper) {}
    }

    @Test func atMostOneRepairRunsPerRunLoopTurn() async throws {
        let window = Self.window()
        let keeper = RuleEditorWindowChrome.keep(window)
        window.titleVisibility = .visible
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        #expect(window.titleVisibility == .hidden)
        // A window that puts its state back at once is left alone for the rest of this turn ...
        window.titleVisibility = .visible
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        #expect(window.titleVisibility == .visible)
        // ... and repaired on the next.
        try await Task.sleep(for: .milliseconds(50))
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        #expect(window.titleVisibility == .hidden)
        withExtendedLifetime(keeper) {}
    }

    @Test func aToolbarSwiftUIAlreadyHasIsNeverReplaced() {
        let window = Self.window()
        let theirs = NSToolbar(identifier: "swiftui-toolbar")
        window.toolbar = theirs
        RuleEditorWindowChrome.apply(to: window)
        #expect(window.toolbar === theirs)
        #expect(RuleEditorWindowChrome.isIntact(window))
        let keeper = RuleEditorWindowChrome.keep(window)
        window.titleVisibility = .visible
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        #expect(window.toolbar === theirs && window.titleVisibility == .hidden)
        withExtendedLifetime(keeper) {}
    }

    @Test func ourToolbarIsAddedOnlyWhenThereIsNone() {
        let window = Self.window()
        #expect(window.toolbar == nil)
        RuleEditorWindowChrome.apply(to: window)
        #expect(window.toolbar?.identifier == RuleEditorWindowChrome.toolbarIdentifier)
    }

    @MainActor private final class Lines { var values: [String] = [] }

    @Test func aWindowThatUndoesEveryRepairIsLeftAloneAfterThreeInARow() async throws {
        let window = Self.window()
        let lines = Lines()
        let keeper = RuleEditorWindowChrome.ChromeKeeper(window: window, log: { lines.values.append($0) })
        for _ in 0..<6 {
            window.titleVisibility = .visible
            NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(keeper.repairCount == 3 && keeper.gaveUp)
        #expect(window.titleVisibility == .visible)
        #expect(lines.values.filter { $0.contains("giving up") }.count == 1)
        #expect(lines.values.filter { $0.contains("repair ") }.count == 3)
        withExtendedLifetime(keeper) {}
    }

    @MainActor private final class Clock { var now: TimeInterval = 0 }

    private func pingPong(_ window: NSWindow, _ keeper: RuleEditorWindowChrome.ChromeKeeper, rounds: Int, step: (() -> Void)? = nil) async throws {
        for _ in 0..<rounds {
            window.titleVisibility = .visible
            NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
            // The window held its state in between, which no longer buys the keeper more repairs.
            NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
            step?()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func anIntactCheckBetweenRepairsDoesNotResetTheLimit() async throws {
        let window = Self.window()
        let clock = Clock()
        let keeper = RuleEditorWindowChrome.ChromeKeeper(window: window, log: { _ in }, now: { clock.now })
        try await pingPong(window, keeper, rounds: 6)
        #expect(keeper.repairCount == 3 && keeper.gaveUp)
        withExtendedLifetime(keeper) {}
    }

    @Test func aWindowThatPutsStateBackEverySecondIsRepairedUntilTheLifetimeCap() async throws {
        let window = Self.window()
        let clock = Clock()
        let keeper = RuleEditorWindowChrome.ChromeKeeper(window: window, log: { _ in }, now: { clock.now })
        // 1 s apart: never more than 2 repairs within the 2 s window.
        try await pingPong(window, keeper, rounds: 30) { clock.now += 1 }
        #expect(keeper.repairCount == RuleEditorWindowChrome.ChromeKeeper.maxLifetimeRepairs && keeper.gaveUp)
        withExtendedLifetime(keeper) {}
    }

    @Test func repairsSpreadBeyondTheWindowAreNotAPingPong() async throws {
        let window = Self.window()
        let clock = Clock()
        let keeper = RuleEditorWindowChrome.ChromeKeeper(window: window, log: { _ in }, now: { clock.now })
        try await pingPong(window, keeper, rounds: 10) { clock.now += 3 }
        #expect(keeper.repairCount == 10 && !keeper.gaveUp)
        withExtendedLifetime(keeper) {}
    }

    @Test func aToolbarOfSwiftUIsKeepsItsStyle() {
        let window = Self.window()
        window.toolbar = NSToolbar(identifier: "swiftui-toolbar")
        window.toolbarStyle = .expanded
        RuleEditorWindowChrome.apply(to: window)
        #expect(window.toolbarStyle == .expanded && window.titleVisibility == .hidden && window.titlebarAppearsTransparent)
        #expect(RuleEditorWindowChrome.isIntact(window))
    }
}
