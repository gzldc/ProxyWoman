import Foundation

/// Installs the root certificate into every booted iOS Simulator with `xcrun simctl keychain <udid> add-root-cert`.
/// Simulators use the Mac's network settings, so with the system proxy on their traffic is captured.
public struct SimulatorCertificateInstaller: Sendable {
    public struct Device: Equatable, Sendable {
        public var udid: String
        public var name: String
        public var runtime: String
    }

    public enum Outcome: Equatable, Sendable {
        case installed([Device])
        case noBootedSimulator
    }

    public struct Failure: Error, Equatable, LocalizedError {
        public var message: String
        public var errorDescription: String? { message }
    }

    /// Runs `/usr/bin/xcrun` with the arguments; returns exit status, stdout and stderr.
    public typealias Run = @Sendable (_ arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String)

    private let run: Run

    public init(run: @escaping Run = SimulatorCertificateInstaller.runXcrun) {
        self.run = run
    }

    public func install(certificate: URL) throws -> Outcome {
        let devices = try bootedDevices()
        guard !devices.isEmpty else { return .noBootedSimulator }
        for device in devices {
            let result = try run(["simctl", "keychain", device.udid, "add-root-cert", certificate.path])
            guard result.status == 0 else { throw Failure(message: Self.reason(result, device: device.name)) }
        }
        return .installed(devices)
    }

    func bootedDevices() throws -> [Device] {
        let result = try run(["simctl", "list", "devices", "booted", "--json"])
        guard result.status == 0 else { throw Failure(message: Self.reason(result, device: nil)) }
        return Self.parseBooted(Data(result.stdout.utf8))
    }

    /// `simctl list --json` groups devices by runtime identifier, for example
    /// "com.apple.CoreSimulator.SimRuntime.iOS-18-2".
    static func parseBooted(_ json: Data) -> [Device] {
        struct List: Decodable { var devices: [String: [Entry]] }
        struct Entry: Decodable { var udid: String; var name: String; var state: String }
        guard let list = try? JSONDecoder().decode(List.self, from: json) else { return [] }
        return list.devices.keys.sorted().flatMap { runtime in
            list.devices[runtime, default: []].filter { $0.state == "Booted" }.map {
                Device(udid: $0.udid, name: $0.name, runtime: runtimeName(runtime))
            }
        }
    }

    static func runtimeName(_ identifier: String) -> String {
        let last = identifier.split(separator: ".").last.map(String.init) ?? identifier
        guard let dash = last.firstIndex(of: "-") else { return last }
        return last[..<dash] + " " + last[last.index(after: dash)...].replacingOccurrences(of: "-", with: ".")
    }

    private static func reason(_ result: (status: Int32, stdout: String, stderr: String), device: String?) -> String {
        let text = (result.stderr.isEmpty ? result.stdout : result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = text.isEmpty ? "xcrun exited with status \(result.status)" : text
        return device.map { "\($0): \(detail)" } ?? detail
    }

    public static let runXcrun: Run = { arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Read before waiting: a full pipe would otherwise block simctl.
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: stdout, as: UTF8.self), String(decoding: stderr, as: UTF8.self))
    }
}
