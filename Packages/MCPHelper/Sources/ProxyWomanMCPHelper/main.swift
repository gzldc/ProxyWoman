import Foundation
import MCPWire

// proxywoman-mcp: stdio <-> ProxyWoman MCP socket relay. Protocol lines only on stdout; diagnostics on stderr.

private let version = "proxywoman-mcp 1"
private let usage = """
    usage: proxywoman-mcp [--handshake <path>] [--version]

    Relays MCP JSON-RPC between stdin/stdout and the running ProxyWoman app.
    The handshake file is chosen from --handshake, then the PROXYWOMAN_MCP_HANDSHAKE
    environment variable, then the standard location in Application Support.

    """

private func printError(_ text: String) {
    FileHandle.standardError.write(Data(text.utf8))
}

private func standardHandshakeURL() -> URL? {
    guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else { return nil }
    return MCPPaths.handshakeURL(in: MCPPaths.standardDirectory(applicationSupport: support, appName: "ProxyWoman"))
}

// A closed pipe must surface as a write error, not kill the process.
signal(SIGPIPE, SIG_IGN)

var explicitHandshake: String?
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    switch argument {
    case "--version":
        print(version)
        exit(0)
    case "--handshake":
        guard let value = arguments.popFirst(), !value.isEmpty else {
            printError("proxywoman-mcp: --handshake needs a path\n\(usage)")
            exit(64)
        }
        explicitHandshake = value
    default:
        printError("proxywoman-mcp: unknown argument \(argument)\n\(usage)")
        exit(64)
    }
}

let environmentHandshake = ProcessInfo.processInfo.environment["PROXYWOMAN_MCP_HANDSHAKE"]
let handshakePath: String
if let explicitHandshake {
    handshakePath = explicitHandshake
} else if let environmentHandshake, !environmentHandshake.isEmpty {
    handshakePath = environmentHandshake
} else if let standard = standardHandshakeURL() {
    handshakePath = standard.path
} else {
    printError("proxywoman-mcp: cannot locate the Application Support directory\n")
    exit(1)
}

let relay = StdioRelay(
    handshakeURL: URL(fileURLWithPath: handshakePath),
    input: STDIN_FILENO,
    output: STDOUT_FILENO,
    log: { printError("proxywoman-mcp: \($0)\n") })
exit(relay.run())
