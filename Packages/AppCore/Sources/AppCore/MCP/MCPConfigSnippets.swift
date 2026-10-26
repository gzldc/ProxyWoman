import Foundation

/// Ready-to-paste configurations that point an AI client at the bundled `proxywoman-mcp` helper (spec D18, D19).
/// The path is escaped for the format it is pasted into: JSON for the two JSON clients, a POSIX shell word for
/// the Claude Code command. These strings are code for another program, not user-facing text.
public enum MCPConfigSnippets {
    public enum Client: String, CaseIterable, Sendable {
        case claudeDesktop, claudeCode, cursor
    }

    /// The server name the clients list.
    static let serverName = "proxywoman"

    public static func snippet(for client: Client, helperPath: String, handshakePath: String?) -> String {
        switch client {
        case .claudeDesktop, .cursor: json(helperPath: helperPath, handshakePath: handshakePath)
        case .claudeCode: command(helperPath: helperPath, handshakePath: handshakePath)
        }
    }

    /// The helper next to the running executable: `Contents/MacOS/proxywoman-mcp` in the app bundle, the build
    /// folder when run with `swift run`. Without an executable URL the name alone is returned.
    public static func helperURL(executableURL: URL?) -> URL {
        let name = "proxywoman-mcp"
        guard let executableURL else { return URL(fileURLWithPath: name) }
        return executableURL.deletingLastPathComponent().appendingPathComponent(name, isDirectory: false)
    }

    // MARK: formats

    private static func json(helperPath: String, handshakePath: String?) -> String {
        var entry: [String: Any] = ["command": helperPath]
        if let handshakePath { entry["args"] = ["--handshake", handshakePath] }
        let root: [String: Any] = ["mcpServers": [serverName: entry]]
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: options),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    /// Options come before the server name: Claude Code's `claude mcp add [options] <name> <commandOrUrl> [args...]`
    /// takes `--transport` there, and everything after `--` belongs to the helper. (`claude` was not available
    /// offline to check this against `claude mcp add --help`; the order follows the documented usage.)
    private static func command(helperPath: String, handshakePath: String?) -> String {
        var line = "claude mcp add --transport stdio \(serverName) -- \(shellWord(helperPath))"
        if let handshakePath { line += " --handshake \(shellWord(handshakePath))" }
        return line
    }

    /// A single-quoted POSIX shell word: everything is literal inside single quotes, so only a single quote
    /// itself needs care (close the quote, add an escaped quote, reopen).
    static func shellWord(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
