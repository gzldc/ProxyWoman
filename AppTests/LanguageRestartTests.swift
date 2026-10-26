import AppCore
import AppKit
import Foundation
import Testing
@testable import ProxyWoman

/// L1 Task 2: restarting after a language change leaves the system proxy as it was. The one-shot mark,
/// the launch decision and the restart sequence are checked without starting a process, a server or
/// touching the system proxy: the relauncher and the termination are fakes, the settings are in memory.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)), .productionChinese) struct LanguageRestartTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func theMarkIsReadOnceAndClearedByReading() {
        let settings = AppSettings(defaults: InMemorySettingsStorage())
        #expect(!settings.takeResumeSystemProxyAfterRestart(now: start))
        settings.markResumeSystemProxyAfterRestart(true, now: start)
        #expect(settings.takeResumeSystemProxyAfterRestart(now: start.addingTimeInterval(3)))
        #expect(!settings.takeResumeSystemProxyAfterRestart(now: start.addingTimeInterval(4)))
    }

    @Test func markingFalseForgetsAnEarlierMark() {
        let settings = AppSettings(defaults: InMemorySettingsStorage())
        settings.markResumeSystemProxyAfterRestart(true, now: start)
        settings.markResumeSystemProxyAfterRestart(false, now: start)
        #expect(!settings.takeResumeSystemProxyAfterRestart(now: start))
    }

    // A relaunch that never happened must not switch the system proxy on at some later start; the stale mark is also cleared.
    @Test func aStaleMarkIsIgnoredAndCleared() {
        let storage = InMemorySettingsStorage()
        let settings = AppSettings(defaults: storage)
        settings.markResumeSystemProxyAfterRestart(true, now: start)
        #expect(!settings.takeResumeSystemProxyAfterRestart(now: start.addingTimeInterval(AppSettings.restartResumeWindow + 1)))
        #expect(storage.integer(forKey: "resumeSystemProxyAfterRestart") == 0)
        #expect(!settings.takeResumeSystemProxyAfterRestart(now: start))
    }

    @Test func theMarkIsNotAPreferenceSavedWithTheOthers() {
        let storage = InMemorySettingsStorage()
        let settings = AppSettings(defaults: storage)
        settings.markResumeSystemProxyAfterRestart(true, now: start)
        #expect(storage.data(forKey: "preferences") == nil)
    }

    @Test(arguments: [
        // autoOverride, resume, listening, enabled, expected
        (false, false, true, false, false), (true, false, true, false, true), (false, true, true, false, true),
        (true, true, true, false, true), (false, true, false, false, false), (false, true, true, true, false),
    ])
    func launchEnablesTheSystemProxyForTheSettingOrAResumedRestart(
        auto: Bool, resume: Bool, listening: Bool, enabled: Bool, expected: Bool
    ) {
        #expect(
            AppModel.shouldEnableSystemProxyAtLaunch(
                autoOverride: auto, resumeAfterRestart: resume, isListening: listening, isEnabled: enabled) == expected)
    }

    private func withModel(_ body: (AppModel) throws -> Void) throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("language-restart-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("root", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        defer { try? FileManager.default.removeItem(at: base) }
        let runner = RecordingCommandRunner()
        let runtime = try AppRuntime.resolve(
            arguments: ["/app", IsolatedLaunch.rootArgument, root.path], environment: ["CFFIXED_USER_HOME": home.path],
            bundleIdentifier: "dev.pwapp.mac.t12a-copy", temporaryDirectories: [base], home: home,
            commandRunner: runner, trust: TrustRecorder().operations)
        let model = AppModel(runtime: runtime)
        do { try body(model) } catch { model.shutdown(); throw error }
        model.shutdown()
        #expect(runner.calls.isEmpty)
    }

    private func withModelAndDelegate(_ body: (AppModel, AppDelegate) throws -> Void) throws {
        try withModel { model in
            let delegate = AppDelegate(
                model: model, flowList: FlowListModel(store: model.store, breakpoints: model.breakpointClient))
            try body(model, delegate)
        }
    }

    // The quit a restart asks for goes through the real delegate: it is let through, and consumes the one-shot mark.
    @Test func restartArrangesTheRelaunchBeforeQuittingAndTheDelegateConsumesTheMark() throws {
        try withModelAndDelegate { model, delegate in
            var events: [String] = []
            var reply: NSApplication.TerminateReply?
            #expect(!model.isRestarting)
            model.restart(using: AppRelauncher { events.append("relaunch"); return { events.append("cancel") } }) {
                events.append("terminate")
                #expect(model.isRestarting)
                reply = delegate.applicationShouldTerminate(NSApplication.shared)
            }
            #expect(events == ["relaunch", "terminate"])
            #expect(reply == .terminateNow)
            #expect(!model.isRestarting)
            // The approved quit is not undone, and the mark is gone: a second terminate request is an ordinary quit.
            #expect(!model.takeRestartForTermination())
            #expect(!model.settings.takeResumeSystemProxyAfterRestart())
        }
    }

    // A quit that does not happen (terminate returns) must not leave the restart state behind.
    @Test func aCancelledQuitResetsTheRestartAndCallsOffTheRelaunch() throws {
        try withModelAndDelegate { model, delegate in
            var events: [String] = []
            model.settings.markResumeSystemProxyAfterRestart(true)
            model.restart(using: AppRelauncher { events.append("relaunch"); return { events.append("cancel") } }) {
                events.append("terminate")
            }
            #expect(events == ["relaunch", "terminate", "cancel"])
            #expect(!model.isRestarting)
            #expect(!model.settings.takeResumeSystemProxyAfterRestart())
            // Nothing stays marked: the delegate sees an ordinary quit, and a new restart works.
            #expect(!model.takeRestartForTermination())
            model.restart(using: AppRelauncher { events.append("relaunch"); return {} }) {
                events.append("terminate")
                #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
            }
            #expect(events == ["relaunch", "terminate", "cancel", "relaunch", "terminate"])
        }
    }

    @Test func aRelaunchThatCannotBeArrangedQuitsNothingAndExplainsWhy() throws {
        try withModel { model in
            var terminated = false
            let failure = AppRelauncher.Failure.notAnAppBundle(path: "/tmp/x/Build")
            model.restart(using: AppRelauncher { throw failure }) { terminated = true }
            #expect(!terminated && !model.isRestarting)
            // A localized reason, with the path as its own detail.
            #expect(model.lastError == "无法重新启动：当前不是从应用程序包运行（位置：/tmp/x/Build）")
            model.restart(using: AppRelauncher { throw AppRelauncher.Failure.helperFailed(detail: "denied") }) { terminated = true }
            #expect(model.lastError == "无法重新启动：无法启动重启辅助进程（denied）")
            #expect(!terminated)
            #expect(!model.settings.takeResumeSystemProxyAfterRestart())
        }
    }

    // The helper script waits for the old process, then opens a new instance with the arguments it was given.
    @Test func theRelaunchScriptWaitsForTheOldProcessBeforeOpening() throws {
        let script = AppRelauncher.script
        let wait = try #require(script.range(of: "kill -0"))
        let open = try #require(script.range(of: "/usr/bin/open \"$@\""))
        #expect(wait.lowerBound < open.lowerBound)
    }

    // The old process is alive: keep waiting (ten minutes in 0.2 s steps) and open nothing when the bound is reached.
    @Test func theRelaunchScriptWaitsTenMinutesAndOpensNothingIfTheOldProcessIsStillAlive() throws {
        #expect(AppRelauncher.maximumWait == 600)
        #expect(AppRelauncher.script.contains("-gt 3000 ] && exit 0"))
        // Run for real: a live pid with a tiny bound exits without running open; a dead pid runs it.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relaunch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("opened")
        // Replace only the absolute `open` and the bound, so the loop and the exec are the shipped ones.
        let script = AppRelauncher.script
            .replacingOccurrences(of: "/usr/bin/open", with: "/usr/bin/touch")
            .replacingOccurrences(of: "-gt 3000", with: "-gt 2")
        func run(pid: Int32) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script, "sh", String(pid), marker.path]
            try process.run()
            process.waitUntilExit()
        }
        try run(pid: ProcessInfo.processInfo.processIdentifier)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        let finished = Process()
        finished.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try finished.run()
        finished.waitUntilExit()
        try run(pid: finished.processIdentifier)
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    // An isolated preview is `open -n --env CFFIXED_USER_HOME=<root>/home ... --args -ProxyWomanIsolatedRoot <root>`; the restarted
    // instance must get the same home, or its isolated-root check refuses the launch.
    @Test func theOpenArgumentsForwardTheIsolatedHome() {
        let root = "/private/var/folders/x y/T/preview"
        let arguments = AppRelauncher.openArguments(
            bundlePath: "/Applications/Proxy Woman.app",
            environment: ["CFFIXED_USER_HOME": "\(root)/home", "HOME": "/Users/real", "PATH": "/usr/bin"],
            launchArguments: [IsolatedLaunch.rootArgument, root])
        #expect(
            arguments == [
                "-n", "--env", "CFFIXED_USER_HOME=\(root)/home", "/Applications/Proxy Woman.app", "--args",
                IsolatedLaunch.rootArgument, root,
            ])
    }

    @Test func theOpenArgumentsOmitTheEnvironmentWhenThereIsNoneToForward() {
        #expect(
            AppRelauncher.openArguments(bundlePath: "/A.app", environment: ["HOME": "/Users/real"], launchArguments: [])
                == ["-n", "/A.app"])
        #expect(
            AppRelauncher.openArguments(bundlePath: "/A.app", environment: [:], launchArguments: ["-x", "a b;$(id)"])
                == ["-n", "/A.app", "--args", "-x", "a b;$(id)"])
    }

    // Values reach the shell only as positional arguments: nothing is interpolated into the script text.
    @Test func hostileValuesNeverEnterTheScript() throws {
        let hostile = "a'b\"; touch /tmp/pwned #$(id)`id`"
        let open = AppRelauncher.openArguments(
            bundlePath: "/x/\(hostile).app", environment: ["CFFIXED_USER_HOME": hostile], launchArguments: [hostile])
        let arguments = AppRelauncher.helperArguments(pid: 42, openArguments: open)
        #expect(arguments.prefix(4) == ["-c", AppRelauncher.script, "sh", "42"])
        #expect(!AppRelauncher.script.contains(hostile))
        #expect(arguments.dropFirst(4).joined(separator: "\n").contains(hostile))
    }
}
