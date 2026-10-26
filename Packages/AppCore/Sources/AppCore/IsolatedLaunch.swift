import Darwin
import Foundation

/// Every location the app writes to. The standard layout is the one the app always used; an
/// isolated layout keeps the same structure under one private root.
public struct AppStorageLayout: Equatable, Sendable {
    /// `<Application Support>/<app name>`: rules, rule assets, the root CA, the proxy backup.
    public let applicationSupport: URL
    /// `<Caches>/<app name>`: spilled bodies and the breakpoint spool.
    public let caches: URL

    public init(applicationSupport: URL, caches: URL) {
        self.applicationSupport = applicationSupport
        self.caches = caches
    }

    public var ruleAssets: URL { applicationSupport.appending(path: "RuleAssets", directoryHint: .isDirectory) }
    public var rules: URL { applicationSupport.appending(path: "Rules", directoryHint: .isDirectory) }
    public var certificateAuthority: URL { applicationSupport.appending(path: "CA", directoryHint: .isDirectory) }
    public var proxyBackup: URL { applicationSupport.appending(path: "proxy-backup.json") }
    public var bodies: URL { caches.appending(path: "Bodies", directoryHint: .isDirectory) }
    public var breakpointSpool: URL { caches.appending(path: "BreakpointSpool", directoryHint: .isDirectory) }

    public static func standard(appName: String, applicationSupportBase: URL = .applicationSupportDirectory,
                                cachesBase: URL = .cachesDirectory) -> AppStorageLayout {
        AppStorageLayout(applicationSupport: applicationSupportBase.appending(path: appName, directoryHint: .isDirectory),
                         caches: cachesBase.appending(path: appName, directoryHint: .isDirectory))
    }

    /// `<root>/Library/Application Support/<app name>` and `<root>/Library/Caches/<app name>`.
    public static func isolated(root: URL, appName: String) -> AppStorageLayout {
        let library = root.appending(path: "Library", directoryHint: .isDirectory)
        return standard(appName: appName,
                        applicationSupportBase: library.appending(path: "Application Support", directoryHint: .isDirectory),
                        cachesBase: library.appending(path: "Caches", directoryHint: .isDirectory))
    }
}

/// The launch-time isolated test mode, for verifying a build without touching the user's real
/// data: turned on only by `-ProxyWomanIsolatedRoot <absolute directory>` in a re-identified copy
/// of the app (its own unique `CFBundleIdentifier`).
///
/// What it isolates, and how:
/// - The app's own files (rules, rule assets, root CA, proxy backup, captured bodies, breakpoint
///   spool) are written only under the root; the app's own settings live only in memory; the
///   system proxy and certificate trust are never read or changed (`AppRuntime`).
/// - State the frameworks write (SwiftUI/AppKit window frames, split widths, saved application
///   state) goes through cfprefsd into the *bundle identifier's* preferences domain, which
///   `CFFIXED_USER_HOME` does not redirect (project probe, ledger-v0.1-ui). It is kept away from
///   the real ProxyWoman preferences only because the official identifier is refused here; it
///   lands in the copy's own throw-away domain.
///
/// The root must be a directory strictly inside a temporary directory, owned by this user, not
/// writable by others, and must contain HOME (the launcher sets `CFFIXED_USER_HOME` inside it, so
/// framework files built from HOME land there too). Anything doubtful is a `Rejection` and the app
/// exits with `refusalExitCode`: a near miss of an isolation argument, or signs of a test launch
/// (an overridden HOME, a non-official bundle) without a valid root, never fall back to a normal
/// launch, which would read the system proxy and the keychain trust.
public struct IsolatedLaunch: Equatable, Sendable {
    public static let rootArgument = "-ProxyWomanIsolatedRoot"
    /// Optional listener port (1024–65535); without it the system picks a free one.
    public static let portArgument = "-ProxyWomanIsolatedPort"

    /// Absolute, with symbolic links resolved.
    public let root: URL
    /// 0 lets the system pick a free loopback port.
    public let port: Int

    public init(root: URL, port: Int) {
        self.root = root
        self.port = port
    }

    /// `EX_USAGE`: the process exit status of every refused launch.
    public static let refusalExitCode: Int32 = 64

    /// Stable codes, shown inside the localized refusal sentence.
    public enum Rejection: String, Error, Sendable, CaseIterable {
        case repeatedArgument, portWithoutRoot, missingRoot, notAbsolute, invalidPort, notADirectory
        case notOwnedByUser, writableByOthers, notInTemporaryDirectory, homeOutsideRoot
        /// An argument that looks like an isolation argument but is not exactly one.
        case malformedArgument
        /// Isolation was asked for in the official (or an unidentified) bundle.
        case officialBundleIdentifier
        /// `CFFIXED_USER_HOME` is set but no isolation root was given.
        case homeOverriddenWithoutRoot
        /// A re-identified copy was started without an isolation root.
        case unofficialBundleWithoutRoot
    }

    /// Everything the decision depends on, read once from the process by the caller.
    public struct Context: Sendable {
        public var arguments: [String]
        public var environment: [String: String]
        /// nil for an unbundled executable (`swift run`).
        public var bundleIdentifier: String?
        public var officialBundleIdentifier: String
        public var temporaryDirectories: [URL]
        public var home: URL
        public var userID: uid_t

        public init(arguments: [String], environment: [String: String], bundleIdentifier: String?,
                    officialBundleIdentifier: String, temporaryDirectories: [URL], home: URL, userID: uid_t = getuid()) {
            self.arguments = arguments
            self.environment = environment
            self.bundleIdentifier = bundleIdentifier
            self.officialBundleIdentifier = officialBundleIdentifier
            self.temporaryDirectories = temporaryDirectories
            self.home = home
            self.userID = userID
        }
    }

    private static let argumentStem = "proxywomanisolated"

    /// nil for a normal launch: no isolation argument, no overridden HOME, and the official bundle
    /// (or an unbundled developer executable).
    public static func parse(_ context: Context) throws(Rejection) -> IsolatedLaunch? {
        let arguments = context.arguments
        for argument in arguments.dropFirst() where argument != rootArgument && argument != portArgument {
            let stem = argument.drop { $0 == "-" }.lowercased()
            if stem.hasPrefix(argumentStem) { throw .malformedArgument }
        }
        let rootIndices = arguments.indices.filter { arguments[$0] == rootArgument }
        let portIndices = arguments.indices.filter { arguments[$0] == portArgument }
        guard rootIndices.count <= 1, portIndices.count <= 1 else { throw .repeatedArgument }
        guard let rootIndex = rootIndices.first else {
            if !portIndices.isEmpty { throw .portWithoutRoot }
            if context.environment["CFFIXED_USER_HOME"] != nil { throw .homeOverriddenWithoutRoot }
            if let bundle = context.bundleIdentifier, !isOfficial(bundle, context) { throw .unofficialBundleWithoutRoot }
            return nil
        }
        guard let rootText = value(after: rootIndex, in: arguments) else { throw .missingRoot }
        guard rootText.hasPrefix("/") else { throw .notAbsolute }
        var port = 0
        if let portIndex = portIndices.first {
            guard let text = value(after: portIndex, in: arguments), text.allSatisfy(\.isASCII), let number = Int(text),
                  (1024...65535).contains(number) else { throw .invalidPort }
            port = number
        }
        // Framework state is isolated only by the copy's own preferences domain.
        guard let bundle = context.bundleIdentifier, !isOfficial(bundle, context) else { throw .officialBundleIdentifier }
        let root = resolved(URL(fileURLWithPath: rootText))
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw .notADirectory
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: root.path),
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == context.userID else { throw .notOwnedByUser }
        guard let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue, permissions & 0o022 == 0 else {
            throw .writableByOthers
        }
        guard context.temporaryDirectories.contains(where: { isStrictlyInside(root, resolved($0)) }) else {
            throw .notInTemporaryDirectory
        }
        let resolvedHome = resolved(context.home)
        guard resolvedHome == root || isStrictlyInside(resolvedHome, root) else { throw .homeOutsideRoot }
        return IsolatedLaunch(root: URL(fileURLWithPath: root.path, isDirectory: true), port: port)
    }

    /// The argument after `index`; nil when there is none or it is another option.
    private static func value(after index: Int, in arguments: [String]) -> String? {
        let next = arguments.index(after: index)
        guard next < arguments.endIndex, !arguments[next].hasPrefix("-") || Int(arguments[next]) != nil else { return nil }
        return arguments[next]
    }

    /// Bundle identifiers compare case-insensitively.
    private static func isOfficial(_ bundle: String, _ context: Context) -> Bool {
        bundle.caseInsensitiveCompare(context.officialBundleIdentifier) == .orderedSame
    }

    private static func resolved(_ url: URL) -> URL {
        URL(fileURLWithPath: url.standardizedFileURL.path).resolvingSymlinksInPath().standardizedFileURL
    }

    private static func isStrictlyInside(_ url: URL, _ directory: URL) -> Bool {
        let inner = url.pathComponents, outer = directory.pathComponents
        return inner.count > outer.count && Array(inner.prefix(outer.count)) == outer
    }
}
