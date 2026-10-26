import Foundation
import Localization

/// Starts a new instance of this app after the running one has exited. Replaceable so tests never
/// start a process.
struct AppRelauncher {
    /// Why a relaunch could not be arranged; `reason` is the localized sentence shown after "could not restart".
    enum Failure: Error {
        /// The running executable is not inside a `.app` bundle (for example a `swift run` build).
        case notAnAppBundle(path: String)
        /// The `/bin/sh` helper could not be started; `detail` is the system's description.
        case helperFailed(detail: String)

        var reason: String {
            switch self {
            case .notAnAppBundle(let path): L10n.format("appModel.restartFailed.notBundle", path)
            case .helperFailed(let detail): L10n.format("appModel.restartFailed.helper", detail)
            }
        }
    }

    /// Arranges the relaunch. Throws when it cannot be arranged; then nothing may quit. The returned closure
    /// calls the arrangement off again (the helper is stopped and never opens the app) for a quit that
    /// did not happen.
    var launch: () throws -> () -> Void

    /// How long the helper keeps waiting for this process to exit before it gives up without opening anything.
    static let maximumWait: TimeInterval = 600
    static let pollInterval: TimeInterval = 0.2

    /// The only environment variable forwarded. An isolated preview points the app at its own home with it, and
    /// `open` does not hand the launching process's environment on, so it is passed explicitly with `open --env`.
    static let forwardedEnvironment = ["CFFIXED_USER_HOME"]

    /// The arguments of `/usr/bin/open`: a new instance of `bundlePath`, with `CFFIXED_USER_HOME` forwarded when the
    /// environment has it (no other environment variable is carried over), then the original launch arguments after
    /// `--args`. Every value is its own element and reaches `open` positionally, never through shell parsing.
    static func openArguments(bundlePath: String, environment: [String: String], launchArguments: [String]) -> [String] {
        var arguments = ["-n"]
        for name in forwardedEnvironment {
            if let value = environment[name] { arguments += ["--env", "\(name)=\(value)"] }
        }
        arguments.append(bundlePath)
        if !launchArguments.isEmpty { arguments += ["--args"] + launchArguments }
        return arguments
    }

    /// The `/bin/sh` argument vector: the script, then `$0`, then the pid and the `open` arguments.
    static func helperArguments(pid: Int32, openArguments: [String]) -> [String] {
        ["-c", script, "sh", String(pid)] + openArguments
    }

    /// A detached `/bin/sh` waits until this process is gone, so the listener port is free, then runs `open` with
    /// `openArguments` (the same arguments, plus `CFFIXED_USER_HOME` when this launch had it). It keeps waiting as
    /// long as the old process is alive, up to `maximumWait` (ten minutes); if the process is still alive then, it
    /// exits and opens nothing, so a quit that never happened never produces a second instance much later.
    static var system: AppRelauncher { AppRelauncher {
        let bundlePath = Bundle.main.bundlePath
        guard bundlePath.hasSuffix(".app") else { throw Failure.notAnAppBundle(path: bundlePath) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = helperArguments(
            pid: ProcessInfo.processInfo.processIdentifier,
            openArguments: openArguments(
                bundlePath: bundlePath, environment: ProcessInfo.processInfo.environment,
                launchArguments: Array(CommandLine.arguments.dropFirst())))
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw Failure.helperFailed(detail: error.localizedDescription) }
        return { if process.isRunning { process.terminate() } }
    } }

    /// `$1` is the pid to wait for, the rest the arguments of `open`.
    static let script = """
        n=0
        while kill -0 "$1" 2>/dev/null; do
            n=$((n+1)); [ "$n" -gt \(Int(maximumWait / pollInterval)) ] && exit 0
            sleep \(pollInterval)
        done
        shift
        exec /usr/bin/open "$@"
        """
}
