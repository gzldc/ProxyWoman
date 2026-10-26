import Foundation

struct CurlResult: Sendable {
    var exitCode: Int32
    var stdout: Data
    var stderr: String

    var text: String { String(decoding: stdout, as: UTF8.self) }
}

/// Runs `/usr/bin/curl -sS --max-time 10 <args>` with every `*_proxy` / `*_PROXY` variable removed
/// from the environment, so only an explicit `-x` decides whether a proxy is used.
func curl(_ args: [String]) throws -> CurlResult {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("curl-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    // Files rather than pipes: a 50 MB body would otherwise fill the pipe and stall curl.
    let stdoutURL = directory.appendingPathComponent("stdout")
    let stderrURL = directory.appendingPathComponent("stderr")
    FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
    FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
    let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
    let stderrHandle = try FileHandle(forWritingTo: stderrURL)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    process.arguments = ["-sS", "--max-time", "10"] + args
    process.environment = ProcessInfo.processInfo.environment.filter {
        !$0.key.lowercased().hasSuffix("_proxy")
    }
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = stdoutHandle
    process.standardError = stderrHandle
    try process.run()
    process.waitUntilExit()
    try stdoutHandle.close()
    try stderrHandle.close()

    return CurlResult(
        exitCode: process.terminationStatus,
        stdout: try Data(contentsOf: stdoutURL),
        stderr: String(decoding: try Data(contentsOf: stderrURL), as: UTF8.self)
    )
}
