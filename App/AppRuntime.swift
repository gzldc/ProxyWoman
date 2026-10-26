import AppCore
import CertKit
import Foundation
import Localization
import SystemProxy

/// Root-certificate trust: query, install, remove. Replaceable so that an isolated run, and tests,
/// never reach the keychain or the trust settings.
struct TrustOperations: Sendable {
    var isTrusted: @Sendable (CertificateAuthority) -> Bool
    var install: @Sendable ([UInt8]) throws -> Void
    var remove: @Sendable ([UInt8]) throws -> Void

    static let system = TrustOperations(
        isTrusted: { TrustManager.isTrusted(ca: $0) },
        install: { try TrustManager.installAndTrust(rootDER: $0) },
        remove: { try TrustManager.removeTrust(rootDER: $0) })
}

/// Where `AppSettings` keeps the preferences: the standard user defaults normally, a dictionary
/// that dies with the process in isolated mode.
protocol SettingsStorage: AnyObject {
    func integer(forKey defaultName: String) -> Int
    func bool(forKey defaultName: String) -> Bool
    func data(forKey defaultName: String) -> Data?
    func stringArray(forKey defaultName: String) -> [String]?
    func set(_ value: Any?, forKey defaultName: String)
}

extension UserDefaults: SettingsStorage {}

/// Never reads or writes any preferences domain. Not `Sendable`: it stays with the main-actor
/// `AppSettings` that owns it.
final class InMemorySettingsStorage: SettingsStorage {
    private var values: [String: Any] = [:]

    func integer(forKey defaultName: String) -> Int { values[defaultName] as? Int ?? 0 }
    func bool(forKey defaultName: String) -> Bool { values[defaultName] as? Bool ?? false }
    func data(forKey defaultName: String) -> Data? { values[defaultName] as? Data }
    func stringArray(forKey defaultName: String) -> [String]? { values[defaultName] as? [String] }
    func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
}

/// Why a launch does not start: printed to standard error, then the process exits with
/// `exitCode` before any model, path, preference, `networksetup` or trust access.
struct LaunchRefusal: Error, Equatable {
    let rejection: IsolatedLaunch.Rejection
    var exitCode: Int32 { IsolatedLaunch.refusalExitCode }
    var message: String { L10n.format("isolatedMode.rejected", rejection.rawValue) }
}

/// What one launch of the app may touch, decided once before the model exists.
///
/// Normal launch (the official bundle, no isolation argument, HOME not overridden; or an unbundled
/// `swift run` executable): exactly the previous behavior — standard locations, standard user
/// defaults, the real `networksetup` runner and the real trust operations.
/// Isolated launch (`IsolatedLaunch`, only in a re-identified copy): the app's own files under the
/// root, in-memory app settings, no system-proxy driver and no trust operations at all, a loopback
/// listener on the requested (or a system-picked) port. Framework state (window frames, saved
/// state) stays in the copy's own preferences domain, never the official one.
/// Anything else is a `LaunchRefusal`.
@MainActor struct AppRuntime {
    enum Startup {
        case run(AppRuntime)
        case refuse(LaunchRefusal)
    }

    let layout: AppStorageLayout
    let settingsStorage: any SettingsStorage
    /// nil: the system proxy is never read or changed (isolated mode).
    let systemProxyRunner: (any CommandRunner)?
    /// nil: no certificate trust query or change (isolated mode).
    let trust: TrustOperations?
    let isolated: IsolatedLaunch?
    /// The listener port when the launch fixes it (isolated mode; 0 = system-picked).
    var listenPort: Int? { isolated?.port }

    /// Throws `IsolatedLaunch.Rejection` for an unsafe or ambiguous launch; the caller must then
    /// not start at all (no fallback to the standard locations).
    static func resolve(
        arguments: [String], environment: [String: String], bundleIdentifier: String?,
        temporaryDirectories: [URL], home: URL,
        standardLayout: () -> AppStorageLayout = { .standard(appName: AppInfo.name) },
        standardDefaults: UserDefaults = .standard,
        commandRunner: any CommandRunner = ProcessCommandRunner(), trust: TrustOperations = .system
    ) throws -> AppRuntime {
        let context = IsolatedLaunch.Context(arguments: arguments, environment: environment, bundleIdentifier: bundleIdentifier,
                                             officialBundleIdentifier: AppInfo.bundleID,
                                             temporaryDirectories: temporaryDirectories, home: home)
        guard let isolated = try IsolatedLaunch.parse(context) else {
            return AppRuntime(layout: standardLayout(), settingsStorage: standardDefaults, systemProxyRunner: commandRunner,
                              trust: trust, isolated: nil)
        }
        return AppRuntime(layout: .isolated(root: isolated.root, appName: AppInfo.name), settingsStorage: InMemorySettingsStorage(),
                          systemProxyRunner: nil, trust: nil, isolated: isolated)
    }

    /// `resolve` as the launch decision the app delegate acts on.
    static func startup(
        arguments: [String], environment: [String: String], bundleIdentifier: String?,
        temporaryDirectories: [URL], home: URL,
        standardLayout: () -> AppStorageLayout = { .standard(appName: AppInfo.name) },
        standardDefaults: UserDefaults = .standard,
        commandRunner: any CommandRunner = ProcessCommandRunner(), trust: TrustOperations = .system
    ) -> Startup {
        do {
            return .run(try resolve(arguments: arguments, environment: environment, bundleIdentifier: bundleIdentifier,
                                    temporaryDirectories: temporaryDirectories, home: home, standardLayout: standardLayout,
                                    standardDefaults: standardDefaults, commandRunner: commandRunner, trust: trust))
        } catch let rejection as IsolatedLaunch.Rejection {
            return .refuse(LaunchRefusal(rejection: rejection))
        } catch {
            preconditionFailure("resolve throws only IsolatedLaunch.Rejection: \(error)")
        }
    }

    /// This process's arguments, environment, bundle identifier, temporary directories and HOME
    /// (`CFFIXED_USER_HOME` aware).
    static func startupForThisProcess() -> Startup {
        startup(arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment,
                bundleIdentifier: Bundle.main.bundleIdentifier,
                temporaryDirectories: [FileManager.default.temporaryDirectory, URL(fileURLWithPath: "/private/tmp", isDirectory: true)],
                home: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
    }
}
