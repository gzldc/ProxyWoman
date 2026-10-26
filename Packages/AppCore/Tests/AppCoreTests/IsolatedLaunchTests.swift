import Darwin
import Foundation
import Testing

@testable import AppCore

/// The launch-time isolation switch: only an explicit, valid argument turns it on; anything
/// doubtful is refused (never silently treated as a normal launch); without it the storage layout
/// is exactly the one the app always used. Every path here is a fresh temporary directory.
@Suite(.serialized, .productionChinese) struct IsolatedLaunchTests {
    private let root = IsolatedLaunch.rootArgument
    private let port = IsolatedLaunch.portArgument
    private let official = "dev.pwapp.mac"

    @Test func withoutTheArgumentTheLaunchIsNormal() throws {
        try withSandbox { s throws in
            // The official bundle with no HOME override and no isolation argument: a normal launch.
            #expect(try s.parse(["/app"], bundle: official, environment: [:]) == nil)
            #expect(try s.parse(["/app", "-port", "9091", "-ApplePersistenceIgnoreState", "YES"], bundle: official,
                                environment: ["HOME": "/Users/u", "TMPDIR": "/var/folders/x/T/"]) == nil)
            // An unbundled developer executable (`swift run`) has no bundle identifier: normal too.
            #expect(try s.parse(["/app"], bundle: nil, environment: [:]) == nil)
        }
    }

    // Fix round 1 (I1): framework state (window frames, saved state) goes to the bundle's own
    // preferences domain, so isolation needs a re-identified copy.
    @Test func theOfficialBundleOrNoBundleCannotRunIsolated() throws {
        try withSandbox { s throws in
            for bundle in [official, "DEV.PWAPP.MAC", nil] as [String?] {
                #expect(throws: IsolatedLaunch.Rejection.officialBundleIdentifier, "\(String(describing: bundle))") {
                    try s.parse(["/app", root, s.root.path], bundle: bundle)
                }
            }
            #expect(try s.parse(["/app", root, s.root.path], bundle: "dev.pwapp.mac.t12a-copy")?.port == 0)
        }
    }

    // Fix round 1 (I2a): a near miss of an isolation argument never means a normal launch.
    @Test func nearMissIsolationArgumentsAreRefused() throws {
        try withSandbox { s throws in
            let cases: [[String]] = [
                ["-ProxyWomanIsolatedroot", s.root.path],
                ["-proxywomanisolatedroot", s.root.path],
                ["--ProxyWomanIsolatedRoot", s.root.path],
                ["ProxyWomanIsolatedRoot", s.root.path],
                ["-ProxyWomanIsolatedRoot=" + s.root.path],
                ["-ProxyWomanIsolatedRoots", s.root.path],
                ["-ProxyWomanIsolated", s.root.path],
                ["-ProxyWomanIsolatedport", "50000"],
                [root, s.root.path, "-ProxyWomanIsolatedPort=50000"],
            ]
            for arguments in cases {
                // Even from the official bundle without a HOME override, where it would otherwise run normally.
                #expect(throws: IsolatedLaunch.Rejection.malformedArgument, "\(arguments)") {
                    try s.parse(["/app"] + arguments, bundle: official, environment: [:])
                }
            }
        }
    }

    // Fix round 1 (I2b): signs of a test launch without a valid isolation root are refused.
    @Test func testLaunchSignsWithoutARootAreRefused() throws {
        try withSandbox { s throws in
            #expect(throws: IsolatedLaunch.Rejection.homeOverriddenWithoutRoot) {
                try s.parse(["/app", "-port", "9091"], bundle: official, environment: ["CFFIXED_USER_HOME": s.home.path])
            }
            #expect(throws: IsolatedLaunch.Rejection.homeOverriddenWithoutRoot) {
                try s.parse(["/app"], bundle: nil, environment: ["CFFIXED_USER_HOME": ""])
            }
            #expect(throws: IsolatedLaunch.Rejection.unofficialBundleWithoutRoot) {
                try s.parse(["/app"], bundle: "dev.pwapp.mac.t12a-copy", environment: [:])
            }
            #expect(throws: IsolatedLaunch.Rejection.missingRoot) {
                try s.parse(["/app", root], bundle: official, environment: [:])
            }
        }
    }

    @Test func aValidRootIsAcceptedResolvedAndPortIsOptional() throws {
        try withSandbox { s throws in
            let resolved = URL(fileURLWithPath: s.root.path).resolvingSymlinksInPath().path
            func summary(_ launch: IsolatedLaunch?) -> [String]? { launch.map { [$0.root.path, String($0.port)] } }
            #expect(summary(try s.parse(["/app", root, s.root.path])) == [resolved, "0"])
            #expect(summary(try s.parse(["/app", root, s.root.path + "/home/.."])) == [resolved, "0"])
            #expect(summary(try s.parse(["/app", port, "54321", root, s.root.path])) == [resolved, "54321"])
            #expect(try s.parse(["/app", root, s.root.path, port, "1024"])?.port == 1024)
            #expect(try s.parse(["/app", root, s.root.path, port, "65535"])?.port == 65535)
        }
    }

    @Test func doubtfulArgumentsAreRefused() throws {
        try withSandbox { s throws in
            let file = s.base.appendingPathComponent("file")
            try Data("x".utf8).write(to: file)
            let cases: [([String], IsolatedLaunch.Rejection)] = [
                ([root], .missingRoot),
                ([root, "-NSDocumentRevisionsDebugMode"], .missingRoot),
                ([root, "relative/run"], .notAbsolute),
                ([root, "~/run"], .notAbsolute),
                ([root, s.base.appendingPathComponent("absent").path], .notADirectory),
                ([root, file.path], .notADirectory),
                ([root, s.root.path, root, s.root.path], .repeatedArgument),
                ([root, s.root.path, port, "2000", port, "2001"], .repeatedArgument),
                ([port, "50000"], .portWithoutRoot),
                ([root, s.root.path, port], .invalidPort),
                ([root, s.root.path, port, "80"], .invalidPort),
                ([root, s.root.path, port, "1023"], .invalidPort),
                ([root, s.root.path, port, "65536"], .invalidPort),
                ([root, s.root.path, port, "12ab"], .invalidPort),
                ([root, s.root.path, port, "-1"], .invalidPort),
                // The allowed temporary directory itself is not a private root.
                ([root, s.base.path], .notInTemporaryDirectory),
            ]
            for (arguments, rejection) in cases {
                #expect(throws: rejection, "\(arguments)") { try s.parse(["/app"] + arguments) }
            }
        }
    }

    @Test func aRootOutsideTheTemporaryDirectoriesIsRefusedEvenThroughASymlink() throws {
        try withSandbox { s throws in
            try withSandbox { elsewhere throws in
                // `elsewhere.root` is a valid directory, but not under `s.base`.
                #expect(throws: IsolatedLaunch.Rejection.notInTemporaryDirectory) {
                    try s.parse(["/app", root, elsewhere.root.path], home: elsewhere.home)
                }
                let link = s.base.appendingPathComponent("link")
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere.root)
                #expect(throws: IsolatedLaunch.Rejection.notInTemporaryDirectory) {
                    try s.parse(["/app", root, link.path], home: elsewhere.home)
                }
            }
        }
    }

    @Test func ownershipPermissionsAndHomeAreChecked() throws {
        try withSandbox { s throws in
            #expect(throws: IsolatedLaunch.Rejection.notOwnedByUser) {
                try s.parse(["/app", root, s.root.path], userID: getuid() &+ 1)
            }
            #expect(throws: IsolatedLaunch.Rejection.homeOutsideRoot) {
                try s.parse(["/app", root, s.root.path], home: s.base)
            }
            #expect(throws: IsolatedLaunch.Rejection.homeOutsideRoot) {
                try s.parse(["/app", root, s.root.path], home: FileManager.default.homeDirectoryForCurrentUser)
            }
            // HOME may be the root itself.
            #expect(try s.parse(["/app", root, s.root.path], home: s.root)?.port == 0)
            try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: s.root.path)
            #expect(throws: IsolatedLaunch.Rejection.writableByOthers) { try s.parse(["/app", root, s.root.path]) }
            try FileManager.default.setAttributes([.posixPermissions: 0o720], ofItemAtPath: s.root.path)
            #expect(throws: IsolatedLaunch.Rejection.writableByOthers) { try s.parse(["/app", root, s.root.path]) }
        }
    }

    @Test func standardLayoutIsTheExistingOne() {
        let layout = AppStorageLayout.standard(
            appName: "ProxyWoman",
            applicationSupportBase: URL(fileURLWithPath: "/Users/u/Library/Application Support", isDirectory: true),
            cachesBase: URL(fileURLWithPath: "/Users/u/Library/Caches", isDirectory: true))
        #expect(layout.applicationSupport.path == "/Users/u/Library/Application Support/ProxyWoman")
        #expect(layout.ruleAssets.path == "/Users/u/Library/Application Support/ProxyWoman/RuleAssets")
        #expect(layout.rules.path == "/Users/u/Library/Application Support/ProxyWoman/Rules")
        #expect(layout.certificateAuthority.path == "/Users/u/Library/Application Support/ProxyWoman/CA")
        #expect(layout.proxyBackup.path == "/Users/u/Library/Application Support/ProxyWoman/proxy-backup.json")
        #expect(layout.bodies.path == "/Users/u/Library/Caches/ProxyWoman/Bodies")
        #expect(layout.breakpointSpool.path == "/Users/u/Library/Caches/ProxyWoman/BreakpointSpool")
        // By default the bases are the ones the app always used.
        let defaults = AppStorageLayout.standard(appName: "ProxyWoman")
        #expect(defaults == AppStorageLayout.standard(appName: "ProxyWoman", applicationSupportBase: .applicationSupportDirectory,
                                                       cachesBase: .cachesDirectory))
        #expect(defaults.applicationSupport.path == URL.applicationSupportDirectory.path + "/ProxyWoman")
        #expect(defaults.bodies.path == URL.cachesDirectory.path + "/ProxyWoman/Bodies")
    }

    @Test func isolatedLayoutKeepsEverythingUnderTheRoot() {
        let layout = AppStorageLayout.isolated(root: URL(fileURLWithPath: "/private/tmp/run", isDirectory: true), appName: "ProxyWoman")
        let paths = [layout.applicationSupport, layout.caches, layout.ruleAssets, layout.rules, layout.certificateAuthority,
                     layout.proxyBackup, layout.bodies, layout.breakpointSpool].map(\.path)
        #expect(paths == [
            "/private/tmp/run/Library/Application Support/ProxyWoman", "/private/tmp/run/Library/Caches/ProxyWoman",
            "/private/tmp/run/Library/Application Support/ProxyWoman/RuleAssets",
            "/private/tmp/run/Library/Application Support/ProxyWoman/Rules",
            "/private/tmp/run/Library/Application Support/ProxyWoman/CA",
            "/private/tmp/run/Library/Application Support/ProxyWoman/proxy-backup.json",
            "/private/tmp/run/Library/Caches/ProxyWoman/Bodies", "/private/tmp/run/Library/Caches/ProxyWoman/BreakpointSpool",
        ])
    }
}

/// A private temporary base standing in for the allowed temporary directory, a root inside it
/// (0700, owned by this user) and a HOME inside the root.
private struct IsolationSandbox {
    let base: URL
    let root: URL
    let home: URL

    /// Defaults describe a proper isolated launch: a re-identified copy with HOME overridden.
    func parse(_ arguments: [String], home: URL? = nil, userID: uid_t = getuid(), bundle: String? = "dev.pwapp.mac.t12a-copy",
               environment: [String: String]? = nil) throws -> IsolatedLaunch? {
        let home = home ?? self.home
        return try IsolatedLaunch.parse(IsolatedLaunch.Context(
            arguments: arguments, environment: environment ?? ["CFFIXED_USER_HOME": home.path], bundleIdentifier: bundle,
            officialBundleIdentifier: "dev.pwapp.mac", temporaryDirectories: [base], home: home, userID: userID))
    }
}

private func withSandbox(_ body: (IsolationSandbox) throws -> Void) throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("isolated-launch-\(UUID().uuidString)", isDirectory: true)
    let root = base.appendingPathComponent("run", isDirectory: true)
    let home = root.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    defer { try? FileManager.default.removeItem(at: base) }
    try body(IsolationSandbox(base: base, root: root, home: home))
}
