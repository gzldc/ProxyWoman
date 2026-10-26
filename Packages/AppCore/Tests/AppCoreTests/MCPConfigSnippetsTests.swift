import Foundation
import Testing
@testable import AppCore

private func servers(_ snippet: String) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: Data(snippet.utf8))
    let root = try #require(object as? [String: Any])
    return try #require(root["mcpServers"] as? [String: Any])
}

private let awkwardPath = "/Users/Jo \"Q\" O'Neil/Apps & Co/ProxyWoman.app/Contents/MacOS/proxywoman-mcp"
private let awkwardHandshake = "/tmp/pw iso/it's \"here\"/mcp.json"

@Suite(.productionChinese) struct MCPConfigSnippetsTests {
    @Test func claudeDesktopSnippetIsValidJSONWithCommand() throws {
        for path in ["/Applications/ProxyWoman.app/Contents/MacOS/proxywoman-mcp", awkwardPath, "/tmp/ü ñ/路径/proxywoman-mcp"] {
            let snippet = MCPConfigSnippets.snippet(for: .claudeDesktop, helperPath: path, handshakePath: nil)
            let entry = try #require(try servers(snippet)["proxywoman"] as? [String: Any])
            #expect(entry["command"] as? String == path)
            // No handshake: no arguments at all.
            #expect(entry["args"] == nil)
            #expect(!snippet.contains("\\/"), "slashes stay readable")
        }
    }

    @Test func cursorSnippetMatchesDesktopShape() throws {
        for handshake in [nil, awkwardHandshake] {
            let desktop = MCPConfigSnippets.snippet(for: .claudeDesktop, helperPath: awkwardPath, handshakePath: handshake)
            let cursor = MCPConfigSnippets.snippet(for: .cursor, helperPath: awkwardPath, handshakePath: handshake)
            let left = try #require(try servers(desktop)["proxywoman"] as? NSDictionary)
            let right = try #require(try servers(cursor)["proxywoman"] as? NSDictionary)
            #expect(left == right)
            #expect(try servers(cursor).count == 1)
        }
    }

    @Test func claudeCodeCommandQuotesPath() {
        let plain = MCPConfigSnippets.snippet(for: .claudeCode, helperPath: "/Applications/Proxy Woman.app/x/proxywoman-mcp", handshakePath: nil)
        #expect(plain == "claude mcp add --transport stdio proxywoman -- '/Applications/Proxy Woman.app/x/proxywoman-mcp'")
        // A single quote inside single quotes is closed, escaped and reopened, as a POSIX shell reads it.
        let tricky = MCPConfigSnippets.snippet(for: .claudeCode, helperPath: "/a/it's/proxywoman-mcp", handshakePath: nil)
        #expect(tricky == #"claude mcp add --transport stdio proxywoman -- '/a/it'\''s/proxywoman-mcp'"#)
        // Double quotes, dollar signs and backticks stay literal inside single quotes.
        let meta = MCPConfigSnippets.snippet(for: .claudeCode, helperPath: "/a/$HOME/`x`/\"y\"/proxywoman-mcp", handshakePath: nil)
        #expect(meta == "claude mcp add --transport stdio proxywoman -- '/a/$HOME/`x`/\"y\"/proxywoman-mcp'")
    }

    /// The command round-trips through a real shell word split.
    @Test func claudeCodeCommandRoundTripsThroughTheShell() throws {
        let snippet = MCPConfigSnippets.snippet(for: .claudeCode, helperPath: awkwardPath, handshakePath: awkwardHandshake)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // `claude` is replaced by a function that prints each argument on its own line (NUL separated).
        process.arguments = ["-c", "claude() { printf '%s\\0' \"$@\"; }; " + snippet]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let words = String(decoding: data, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
        #expect(words == ["mcp", "add", "--transport", "stdio", "proxywoman", "--", awkwardPath, "--handshake", awkwardHandshake])
    }

    @Test func handshakeAddsArgsInAllThree() throws {
        let path = "/p/proxywoman-mcp", handshake = "/tmp/iso dir/mcp.json"
        for client in [MCPConfigSnippets.Client.claudeDesktop, .cursor] {
            let snippet = MCPConfigSnippets.snippet(for: client, helperPath: path, handshakePath: handshake)
            let entry = try #require(try servers(snippet)["proxywoman"] as? [String: Any])
            #expect(entry["command"] as? String == path)
            #expect(entry["args"] as? [String] == ["--handshake", handshake])
        }
        let code = MCPConfigSnippets.snippet(for: .claudeCode, helperPath: path, handshakePath: handshake)
        #expect(code == "claude mcp add --transport stdio proxywoman -- '/p/proxywoman-mcp' --handshake '/tmp/iso dir/mcp.json'")
    }

    @Test func everyClientHasASnippet() {
        #expect(Set(MCPConfigSnippets.Client.allCases) == [.claudeDesktop, .claudeCode, .cursor])
        for client in MCPConfigSnippets.Client.allCases {
            #expect(!MCPConfigSnippets.snippet(for: client, helperPath: "/x/proxywoman-mcp", handshakePath: nil).isEmpty)
        }
    }

    @Test func helperURLIsSiblingOfExecutable() {
        let bundled = URL(fileURLWithPath: "/Applications/ProxyWoman.app/Contents/MacOS/ProxyWoman")
        #expect(MCPConfigSnippets.helperURL(executableURL: bundled).path == "/Applications/ProxyWoman.app/Contents/MacOS/proxywoman-mcp")
        let swiftRun = URL(fileURLWithPath: "/work/ProxyWoman/.build/debug/ProxyWoman")
        #expect(MCPConfigSnippets.helperURL(executableURL: swiftRun).path == "/work/ProxyWoman/.build/debug/proxywoman-mcp")
        // No executable URL: still a usable file URL named after the helper.
        #expect(MCPConfigSnippets.helperURL(executableURL: nil).lastPathComponent == "proxywoman-mcp")
    }
}
