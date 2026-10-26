import Foundation
import os

public enum CommandError: Error, Equatable {
    case needsAuthorization
    /// The administrator authorization prompt was dismissed. Localized by the app.
    case userCancelled
    /// `executable` could not be started; `reason` is the system's own (untranslated) diagnostic.
    case launchFailed(executable: String, reason: String)
    case failed(String)
}

/// Runs `networksetup`. Abstracted so tests never touch the real system proxy.
public protocol CommandRunner: Sendable {
    func networksetup(_ args: [String]) throws(CommandError) -> String
    /// Runs all commands in order behind a single administrator authorization.
    func networksetupPrivileged(_ commands: [[String]]) throws(CommandError)
    /// Like `networksetupPrivileged(_:)` with one authorization, but each group (one network service's
    /// commands) runs independently: a failing group does not stop the other groups. Commands inside a
    /// group stay ordered and stop at their first failure. Throws if any group failed.
    func networksetupPrivileged(groups: [[[String]]]) throws(CommandError)
}

extension CommandRunner {
    public func networksetupPrivileged(groups: [[[String]]]) throws(CommandError) {
        try networksetupPrivileged(groups.flatMap { $0 })
    }
}

public struct ProcessCommandRunner: CommandRunner {
    static let networksetupPath = "/usr/sbin/networksetup"

    public init() {}

    public func networksetup(_ args: [String]) throws(CommandError) -> String {
        let result = try Self.run(Self.networksetupPath, args)
        if let error = Self.classify(status: result.status, stdout: result.stdout, stderr: result.stderr) { throw error }
        // Only stdout is parsed: networksetup also writes log lines to stderr.
        return result.stdout
    }

    public func networksetupPrivileged(_ commands: [[String]]) throws(CommandError) {
        guard !commands.isEmpty else { return }
        try runPrivileged(script: Self.privilegedScript(for: commands))
    }

    public func networksetupPrivileged(groups: [[[String]]]) throws(CommandError) {
        let groups = groups.filter { !$0.isEmpty }
        guard groups.count > 1 else { return try networksetupPrivileged(groups.flatMap { $0 }) }
        try runPrivileged(script: Self.privilegedScript(forGroups: groups))
    }

    private func runPrivileged(script: String) throws(CommandError) {
        let result = try Self.run("/usr/bin/osascript", ["-e", Self.appleScript(forShellScript: script)])
        if let error = Self.classifyOsascript(status: result.status, output: result.stderr + result.stdout) { throw error }
    }

    // MARK: - Pure helpers (unit-tested without executing anything)

    /// Maps a finished `networksetup` run to an error. `networksetup` sometimes exits 0 yet prints `** Error:`.
    /// Any failure mentioning "admin" is taken as a missing-authorization problem.
    static func classify(status: Int32, stdout: String, stderr: String) -> CommandError? {
        let text = [stderr, stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let reportedError = [stdout, stderr].contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("** Error")
        }
        guard status != 0 || reportedError else { return nil }
        if text.lowercased().contains("admin") { return .needsAuthorization }
        return .failed(text)
    }

    static func classifyOsascript(status: Int32, output: String) -> CommandError? {
        guard status != 0 else { return nil }
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("(-128)") { return .userCancelled }
        return .failed(text)
    }

    /// `/usr/sbin/networksetup 'a' 'b' && /usr/sbin/networksetup ...` with every argument POSIX single-quoted.
    static func privilegedScript(for commands: [[String]]) -> String {
        commands
            .map { ([networksetupPath] + $0.map(shellQuote)).joined(separator: " ") }
            .joined(separator: " && ")
    }

    /// One `&&` chain per group, groups run one after another regardless of each other's result;
    /// the script exits non-zero if any group failed.
    static func privilegedScript(forGroups groups: [[[String]]]) -> String {
        let chains = groups.map { "\(privilegedScript(for: $0)) || fail=1" }
        return (["fail=0"] + chains + ["exit $fail"]).joined(separator: "; ")
    }

    static func shellQuote(_ arg: String) -> String {
        "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptLiteral(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func appleScript(forShellScript script: String) -> String {
        "do shell script \"\(appleScriptLiteral(script))\" with administrator privileges"
    }

    // MARK: - Process plumbing

    static func run(_ executable: String, _ args: [String]) throws(CommandError) -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            throw .launchFailed(executable: executable, reason: error.localizedDescription)
        }
        // Drain stderr concurrently so neither pipe can fill up and block the child.
        let errData = OSAllocatedUnfairLock(initialState: Data())
        let errDone = DispatchGroup()
        errDone.enter()
        DispatchQueue.global().async {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            errData.withLock { $0 = data }
            errDone.leave()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        errDone.wait()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: outData, as: UTF8.self),
            String(decoding: errData.withLock { $0 }, as: UTF8.self)
        )
    }
}
