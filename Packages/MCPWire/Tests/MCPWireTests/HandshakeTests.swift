import Foundation
import Testing

@testable import MCPWire

@Suite struct HandshakeTests {
    private final class Scratch {
        let root: URL
        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("mcpwire-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        deinit { try? FileManager.default.removeItem(at: root) }
    }

    private let validToken = String(repeating: "ab12", count: 16)

    private func sample(token: String? = nil, pid: Int32 = 4242) -> MCPHandshake {
        MCPHandshake(
            version: MCPHandshake.currentVersion, pid: pid, socketPath: "/tmp/x/mcp.sock",
            token: token ?? validToken, startedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func permissions(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    /// Writes raw bytes with the given mode, bypassing `HandshakeFile.write`.
    private func plant(_ bytes: Data, at url: URL, mode: mode_t = 0o600) throws {
        try bytes.write(to: url)
        #expect(chmod(url.path, mode) == 0)
    }

    private func json(token: String? = nil, version: Int = 1) -> Data {
        Data(
            """
            {"version":\(version),"pid":1,"socketPath":"/tmp/s","token":"\(token ?? validToken)","startedAt":"2023-11-14T22:13:20Z"}
            """.utf8)
    }

    @Test func writeThenReadRoundTrips() throws {
        let scratch = try Scratch()
        let url = MCPPaths.handshakeURL(in: scratch.root)
        let handshake = sample()
        try HandshakeFile.write(handshake, to: url)
        #expect(try HandshakeFile.read(at: url) == handshake)
    }

    @Test func fileIs0600AndDirectoryIs0700() throws {
        let scratch = try Scratch()
        let directory = MCPPaths.standardDirectory(applicationSupport: scratch.root, appName: "ProxyWoman")
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        let url = MCPPaths.handshakeURL(in: directory)
        try HandshakeFile.write(sample(), to: url)
        #expect(try permissions(url) == 0o600)
        #expect(try permissions(directory) == 0o700)
    }

    @Test func existingDirectoryPermissionsAreLeftAlone() throws {
        let scratch = try Scratch()
        #expect(chmod(scratch.root.path, 0o750) == 0)
        try HandshakeFile.write(sample(), to: MCPPaths.handshakeURL(in: scratch.root))
        #expect(try permissions(scratch.root) == 0o750)
    }

    @Test func readRejectsWiderPermissions() throws {
        let scratch = try Scratch()
        let url = MCPPaths.handshakeURL(in: scratch.root)
        try HandshakeFile.write(sample(), to: url)
        for mode: mode_t in [0o644, 0o640, 0o604, 0o660, 0o666] {
            #expect(chmod(url.path, mode) == 0)
            #expect(throws: HandshakeFile.Failure.tooPermissive) { try HandshakeFile.read(at: url) }
        }
        #expect(chmod(url.path, 0o400) == 0)
        #expect(try HandshakeFile.read(at: url) == sample())
    }

    @Test func readRejectsMissing() throws {
        let scratch = try Scratch()
        let url = MCPPaths.handshakeURL(in: scratch.root)
        #expect(throws: HandshakeFile.Failure.missing) { try HandshakeFile.read(at: url) }
        let inMissingDirectory = scratch.root.appendingPathComponent("nope/mcp-handshake.json")
        #expect(throws: HandshakeFile.Failure.missing) { try HandshakeFile.read(at: inMissingDirectory) }
    }

    @Test func readRejectsSymlink() throws {
        let scratch = try Scratch()
        let real = scratch.root.appendingPathComponent("real.json")
        try HandshakeFile.write(sample(), to: real)
        let link = MCPPaths.handshakeURL(in: scratch.root)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(throws: HandshakeFile.Failure.malformed) { try HandshakeFile.read(at: link) }
        #expect(try HandshakeFile.read(at: real) == sample())
    }

    @Test func readRejectsDirectoryAndFIFO() throws {
        let scratch = try Scratch()
        let dir = scratch.root.appendingPathComponent("adir", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        #expect(throws: HandshakeFile.Failure.malformed) { try HandshakeFile.read(at: dir) }
        let fifo = scratch.root.appendingPathComponent("fifo")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: HandshakeFile.Failure.malformed) { try HandshakeFile.read(at: fifo) }
    }

    @Test func readRejectsOversizeAndBadToken() throws {
        let scratch = try Scratch()
        let url = MCPPaths.handshakeURL(in: scratch.root)

        var big = json()
        big.append(Data(repeating: 0x20, count: 5000))
        try plant(big, at: url)
        #expect(throws: HandshakeFile.Failure.tooLarge) { try HandshakeFile.read(at: url) }

        let atLimit = json() + Data(repeating: 0x20, count: 4096 - json().count)
        #expect(atLimit.count == 4096)
        try plant(atLimit, at: url)
        #expect(try HandshakeFile.read(at: url).token == validToken)

        let badTokens = [
            String(repeating: "a", count: 63),
            String(repeating: "a", count: 65),
            String(repeating: "A", count: 64),
            String(repeating: "g", count: 64),
            "",
        ]
        for token in badTokens {
            try plant(json(token: token), at: url)
            #expect(throws: HandshakeFile.Failure.malformed) { try HandshakeFile.read(at: url) }
        }
    }

    @Test func readRejectsMalformedContent() throws {
        let scratch = try Scratch()
        let url = MCPPaths.handshakeURL(in: scratch.root)
        for text in ["", "not json", "[]", #"{"version":1}"#, #"{"version":"1","pid":1}"#] {
            try plant(Data(text.utf8), at: url)
            #expect(throws: HandshakeFile.Failure.malformed) { try HandshakeFile.read(at: url) }
        }
    }

    @Test func readRejectsUnsupportedVersion() throws {
        let scratch = try Scratch()
        let url = MCPPaths.handshakeURL(in: scratch.root)
        for version in [0, 2, 99] {
            try plant(json(version: version), at: url)
            #expect(throws: HandshakeFile.Failure.unsupportedVersion) { try HandshakeFile.read(at: url) }
        }
    }

    @Test func rewriteReplacesAtomically() throws {
        let scratch = try Scratch()
        let url = MCPPaths.handshakeURL(in: scratch.root)
        let first = sample(token: String(repeating: "1", count: 64), pid: 1)
        let second = sample(token: String(repeating: "2", count: 64), pid: 2)
        try HandshakeFile.write(first, to: url)
        try HandshakeFile.write(second, to: url)
        #expect(try HandshakeFile.read(at: url) == second)
        #expect(try permissions(url) == 0o600)
        let names = try FileManager.default.contentsOfDirectory(atPath: scratch.root.path)
        #expect(names == [MCPPaths.handshakeFileName])
    }

    @Test func writeReplacesAPlantedSymlinkInsteadOfFollowingIt() throws {
        let scratch = try Scratch()
        let victim = scratch.root.appendingPathComponent("victim.txt")
        try Data("keep".utf8).write(to: victim)
        let url = MCPPaths.handshakeURL(in: scratch.root)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: victim)
        try HandshakeFile.write(sample(), to: url)
        #expect(try Data(contentsOf: victim) == Data("keep".utf8))
        #expect(try HandshakeFile.read(at: url) == sample())
    }

    @Test func removeIsIdempotent() throws {
        let scratch = try Scratch()
        let url = MCPPaths.handshakeURL(in: scratch.root)
        HandshakeFile.remove(at: url)  // nothing there yet
        try HandshakeFile.write(sample(), to: url)
        HandshakeFile.remove(at: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        HandshakeFile.remove(at: url)
        #expect(throws: HandshakeFile.Failure.missing) { try HandshakeFile.read(at: url) }
    }

    @Test func pathHelpersAndLengthLimit() {
        let support = URL(fileURLWithPath: "/Users/me/Library/Application Support", isDirectory: true)
        let standard = MCPPaths.standardDirectory(applicationSupport: support, appName: "ProxyWoman")
        #expect(standard.path == "/Users/me/Library/Application Support/ProxyWoman/MCP")

        let isolated = URL(fileURLWithPath: "/tmp/iso-root", isDirectory: true)
        #expect(MCPPaths.isolatedDirectory(root: isolated) == isolated)

        #expect(MCPPaths.handshakeFileName == "mcp-handshake.json")
        #expect(MCPPaths.socketFileName == "mcp.sock")
        #expect(MCPPaths.handshakeURL(in: isolated).path == "/tmp/iso-root/mcp-handshake.json")
        #expect(MCPPaths.socketURL(in: isolated).path == "/tmp/iso-root/mcp.sock")

        #expect(MCPPaths.maxSocketPathBytes == 103)
        let at103 = URL(fileURLWithPath: "/" + String(repeating: "a", count: 102))
        let at104 = URL(fileURLWithPath: "/" + String(repeating: "a", count: 103))
        #expect(at103.path.utf8.count == 103)
        #expect(at104.path.utf8.count == 104)
        #expect(MCPPaths.fitsSocketPath(at103))
        #expect(!MCPPaths.fitsSocketPath(at104))
    }

    @Test func socketPathLengthCountsUTF8Bytes() {
        // Three-byte characters: 34 of them plus the slash = 103 bytes (fits), 35 = 106 (does not).
        let fits = URL(fileURLWithPath: "/" + String(repeating: "\u{65E5}", count: 34))
        #expect(fits.path.utf8.count == 103)
        #expect(MCPPaths.fitsSocketPath(fits))
        let tooLong = URL(fileURLWithPath: "/" + String(repeating: "\u{65E5}", count: 35))
        #expect(tooLong.path.utf8.count == 106)
        #expect(!MCPPaths.fitsSocketPath(tooLong))
    }

    @Test func socketPathLengthUsesTheLongerNormalizedForm() {
        // "e" + combining acute (NFD) is what the file system sees for "\u{E9}"; 52 of them overflow.
        let url = URL(fileURLWithPath: "/" + String(repeating: "\u{E9}", count: 52))
        #expect(!MCPPaths.fitsSocketPath(url))
    }
}
