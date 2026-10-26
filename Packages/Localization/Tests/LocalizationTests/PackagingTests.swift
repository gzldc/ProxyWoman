import Foundation
import Testing

@testable import Localization

// Limit concurrent filesystem/process fixtures while other suites exercise timed asynchronous work.
@Suite(.serialized, .productionChinese) struct PackagingTests {
    private struct BuildFixture: Sendable {
        let directory: URL
        let output: URL
        let resources: URL
        let builtResources: URL
        let resourceRoot: URL
        let nested: Bool
        /// Whether the fake build produces the `proxywoman-mcp` helper next to the app executable.
        let buildsHelper: Bool

        init(
            languages: [String] = ["zh-Hans"], nested: Bool = false, buildsHelper: Bool = true,
            pluralLanguages: [String] = [], builtPluralLanguages: [String]? = nil
        ) throws {
            self.nested = nested
            self.buildsHelper = buildsHelper
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            output = directory.appendingPathComponent("build/ProxyWoman.app")
            resources = directory.appendingPathComponent("Packages/Localization/Sources/Localization/Resources")
            let binaries = directory.appendingPathComponent("fixture-bin")
            let build = directory.appendingPathComponent("fixture-build")
            builtResources = build.appendingPathComponent("ProxyWoman_Localization.bundle")
            resourceRoot = nested ? builtResources.appendingPathComponent("Contents/Resources") : builtResources
            try FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            let scripts = directory.appendingPathComponent("scripts")
            try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
            let repository = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            try FileManager.default.copyItem(
                at: repository.appendingPathComponent("scripts/build-app.sh"),
                to: scripts.appendingPathComponent("build-app.sh"))
            // The script packages the committed icon assets from App/Resources, so the fixture needs them too.
            let appResources = directory.appendingPathComponent("App/Resources")
            try FileManager.default.createDirectory(at: appResources, withIntermediateDirectories: true)
            for icon in ["AppIcon.icns", "menubar-diamond.png", "menubar-diamond@2x.png"] {
                try FileManager.default.copyItem(
                    at: repository.appendingPathComponent("App/Resources/\(icon)"),
                    to: appResources.appendingPathComponent(icon))
            }
            try FileManager.default.copyItem(at: L10n.bundle.bundleURL, to: builtResources)
            if nested {
                let contents = builtResources.appendingPathComponent("Contents")
                let originalFiles = try FileManager.default.contentsOfDirectory(
                    at: builtResources, includingPropertiesForKeys: nil)
                try FileManager.default.createDirectory(at: resourceRoot, withIntermediateDirectories: true)
                for file in originalFiles where file.pathExtension == "lproj" {
                    try FileManager.default.moveItem(
                        at: file, to: resourceRoot.appendingPathComponent(file.lastPathComponent))
                }
                let plist = try PropertyListSerialization.data(
                    fromPropertyList: [
                        "CFBundleIdentifier": "dev.pwapp.release-fixture",
                        "CFBundlePackageType": "BNDL", "CFBundleDevelopmentRegion": "zh-Hans",
                    ],
                    format: .xml, options: 0)
                try plist.write(to: contents.appendingPathComponent("Info.plist"))
                try Data("whole bundle".utf8).write(to: contents.appendingPathComponent("fixture-marker"))
            }
            // The fixture decides which languages the "build" contains, not the languages production ships.
            for entry in try FileManager.default.contentsOfDirectory(at: resourceRoot, includingPropertiesForKeys: nil)
            where entry.pathExtension == "lproj" && entry.lastPathComponent.lowercased() != "zh-hans.lproj" {
                try FileManager.default.removeItem(at: entry)
            }
            try Data("fixture executable".utf8).write(to: build.appendingPathComponent("ProxyWoman"))
            if buildsHelper { try Data("fixture helper".utf8).write(to: build.appendingPathComponent("proxywoman-mcp")) }
            for language in languages {
                let source = resources.appendingPathComponent("\(language).lproj")
                try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
                try Data("\"common.cancel\" = \"fixture\";".utf8).write(
                    to: source.appendingPathComponent("Localizable.strings"))
                if pluralLanguages.contains(language) {
                    try Data("<plist version=\"1.0\"><dict/></plist>".utf8).write(
                        to: source.appendingPathComponent("Localizable.stringsdict"))
                }
                if language != "zh-Hans" {
                    let target = resourceRoot.appendingPathComponent("\(language).lproj")
                    try FileManager.default.copyItem(at: source, to: target)
                    if !(builtPluralLanguages ?? pluralLanguages).contains(language) {
                        try? FileManager.default.removeItem(
                            at: target.appendingPathComponent("Localizable.stringsdict"))
                    }
                }
            }
            let swift = """
                #!/bin/bash
                printf '%s\\n' "$@" >> "$LOCALIZATION_FIXTURE_BUILD/arguments"
                printf '%s\\n' '---' >> "$LOCALIZATION_FIXTURE_BUILD/arguments"
                architecture=""
                previous=""
                for argument in "$@"; do
                    if [[ "$previous" == "--arch" ]]; then architecture="$argument"; fi
                    previous="$argument"
                done
                if [[ -n "$architecture" && "$architecture" == "${LOCALIZATION_FIXTURE_FAIL_ARCH:-}" ]]; then exit 42; fi
                if [[ " $* " == *" --show-bin-path "* ]]; then
                    if [[ -n "$architecture" ]]; then
                        printf '%s\\n' "$LOCALIZATION_FIXTURE_BUILD/$architecture"
                    else
                        printf '%s\\n' "$LOCALIZATION_FIXTURE_BUILD"
                    fi
                fi
                """
            try Data(swift.utf8).write(to: binaries.appendingPathComponent("swift"))
            try Data("#!/bin/bash\nexit 0\n".utf8).write(to: binaries.appendingPathComponent("codesign"))
            let lipo = """
                #!/bin/bash
                printf '%s\\n' "$@" >> "$LOCALIZATION_FIXTURE_BUILD/lipo-arguments"
                printf '%s\\n' '---' >> "$LOCALIZATION_FIXTURE_BUILD/lipo-arguments"
                if [[ "$1" == "-create" ]]; then
                    if [[ "${LOCALIZATION_FIXTURE_MERGE_FAIL:-0}" == "1" ]]; then exit 43; fi
                    cat "$2" "$3" > "$5"
                elif [[ "$2" == "-verify_arch" && -f "$1" ]]; then
                    shift 2
                    for architecture in "$@"; do
                        case "$architecture" in arm64|x86_64) ;; *) exit 64 ;; esac
                    done
                else
                    exit 64
                fi
                """
            try Data(lipo.utf8).write(to: binaries.appendingPathComponent("lipo"))
            for binary in ["swift", "codesign", "lipo"] {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: binaries.appendingPathComponent(binary).path)
            }
        }

        func run(
            arguments: [String] = [], useDefault: Bool = false, failure: String? = nil, environment extra: [String: String] = [:]
        ) async throws -> (status: Int32, output: String) {
            // Pipe reads and process waits are blocking I/O; keep them off cooperative task workers.
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().async {
                    do {
                        let build = directory.appendingPathComponent("fixture-build")
                        for architecture in ["arm64", "x86_64"] {
                            let thin = build.appendingPathComponent(architecture)
                            try FileManager.default.createDirectory(at: thin, withIntermediateDirectories: true)
                            try Data("fixture executable \(architecture)\n".utf8).write(to: thin.appendingPathComponent("ProxyWoman"))
                            if buildsHelper {
                                try Data("fixture helper \(architecture)\n".utf8).write(to: thin.appendingPathComponent("proxywoman-mcp"))
                            }
                            if FileManager.default.fileExists(atPath: builtResources.path) {
                                try FileManager.default.copyItem(at: builtResources, to: thin.appendingPathComponent("ProxyWoman_Localization.bundle"))
                            }
                        }
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: "/bin/bash")
                        process.arguments = [directory.appendingPathComponent("scripts/build-app.sh").path]
                            + (useDefault ? [] : [nested ? "release" : "debug"]) + arguments
                        var environment = ProcessInfo.processInfo.environment
                        environment["PATH"] =
                            directory.appendingPathComponent("fixture-bin").path + ":/usr/bin:/bin:/usr/sbin:/sbin"
                        environment["LOCALIZATION_FIXTURE_BUILD"] =
                            directory.appendingPathComponent("fixture-build").path
                        environment["LOCALIZATION_FIXTURE_FAIL_ARCH"] = failure == "second-arch" ? "x86_64" : ""
                        environment["LOCALIZATION_FIXTURE_MERGE_FAIL"] = failure == "merge" ? "1" : "0"
                        environment.merge(extra) { _, new in new }
                        process.environment = environment
                        let pipe = Pipe()
                        process.standardOutput = pipe
                        process.standardError = pipe
                        try process.run()
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        process.waitUntilExit()
                        continuation.resume(
                            returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }

    @Test(arguments: [false, true]) func forwardsBuildOptionsIdentically(nested: Bool) async throws {
        let fixture = try BuildFixture(nested: nested)
        defer { fixture.cleanUp() }
        let extra = ["--jobs", "2", "--disable-index-store", "-Xswiftc", "-warnings-as-errors", "-Xswiftc", "value with spaces"]
        let result = try await fixture.run(arguments: extra)
        #expect(result.status == 0)
        let arguments = try String(contentsOf: fixture.directory.appendingPathComponent("fixture-build/arguments"), encoding: .utf8)
        func base(_ product: String) -> [[String]] {
            nested ? ["arm64", "x86_64"].map {
                ["-c", "release", "--build-system", "native", "--arch", $0, "--product", product]
            } : [["--product", product]]
        }
        // Per slice: the app, then the helper, then the bin path of the app build.
        var calls: [String] = []
        for (app, helper) in zip(base("ProxyWoman"), base("proxywoman-mcp")) {
            calls += ["build"] + app + extra + ["---"]
            calls += ["build"] + helper + extra + ["---"]
            calls += ["build"] + app + extra + ["--show-bin-path", "---"]
        }
        let expected = calls.joined(separator: "\n") + "\n"
        #expect(arguments == expected)
    }

    @Test func defaultReleaseMergesBothDistinctNativeExecutables() async throws {
        let fixture = try BuildFixture(nested: true)
        defer { fixture.cleanUp() }
        let result = try await fixture.run(useDefault: true)
        #expect(result.status == 0, "\(result.output)")
        let binary = fixture.output.appendingPathComponent("Contents/MacOS/ProxyWoman")
        #expect(try String(contentsOf: binary, encoding: .utf8) == "fixture executable arm64\nfixture executable x86_64\n")
        let lipo = try String(contentsOf: fixture.directory.appendingPathComponent("fixture-build/lipo-arguments"), encoding: .utf8)
        #expect(lipo.contains("fixture-build/arm64/ProxyWoman"))
        #expect(lipo.contains("fixture-build/x86_64/ProxyWoman"))
        #expect(lipo.contains("-verify_arch\narm64\nx86_64\n"))
        // The helper is merged the same way and ships beside the app executable.
        let helper = fixture.output.appendingPathComponent("Contents/MacOS/proxywoman-mcp")
        #expect(try String(contentsOf: helper, encoding: .utf8) == "fixture helper arm64\nfixture helper x86_64\n")
        #expect(lipo.contains("fixture-build/arm64/proxywoman-mcp"))
        #expect(lipo.contains("fixture-build/x86_64/proxywoman-mcp"))
        #expect(lipo.contains("fixture-build/arm64/proxywoman-mcp\n-verify_arch\narm64\n"))
        #expect(lipo.contains("fixture-build/x86_64/proxywoman-mcp\n-verify_arch\nx86_64\n"))
    }

    @Test(arguments: [false, true]) func theHelperShipsNextToTheAppExecutable(nested: Bool) async throws {
        let fixture = try BuildFixture(nested: nested)
        defer { fixture.cleanUp() }
        let result = try await fixture.run()
        #expect(result.status == 0, "\(result.output)")
        let helper = fixture.output.appendingPathComponent("Contents/MacOS/proxywoman-mcp")
        #expect(FileManager.default.fileExists(atPath: helper.path))
        #expect(FileManager.default.fileExists(atPath: fixture.output.appendingPathComponent("Contents/MacOS/ProxyWoman").path))
    }

    @Test(arguments: [false, true]) func aMissingHelperFailsPackagingAndPreservesTheExistingCandidate(nested: Bool) async throws {
        let fixture = try BuildFixture(nested: nested, buildsHelper: false)
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(at: fixture.output, withIntermediateDirectories: true)
        let sentinel = fixture.output.appendingPathComponent("existing-candidate")
        try Data("preserved".utf8).write(to: sentinel)
        let result = try await fixture.run()
        #expect(result.status != 0)
        #expect(result.output.contains("Missing helper executable"), "\(result.output)")
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "preserved")
        #expect(!FileManager.default.fileExists(atPath: fixture.output.appendingPathComponent("Contents/MacOS/proxywoman-mcp").path))
    }

    @Test(arguments: ["second-arch", "merge"]) func releaseFailurePreservesExistingCandidate(failure: String) async throws {
        let fixture = try BuildFixture(nested: true)
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(at: fixture.output, withIntermediateDirectories: true)
        let sentinel = fixture.output.appendingPathComponent("existing-candidate")
        try Data("preserved".utf8).write(to: sentinel)
        let result = try await fixture.run(failure: failure)
        #expect(result.status != 0)
        #expect(FileManager.default.fileExists(atPath: sentinel.path))
        if FileManager.default.fileExists(atPath: sentinel.path) {
            #expect(try String(contentsOf: sentinel, encoding: .utf8) == "preserved")
        }
        let arguments = try String(contentsOf: fixture.directory.appendingPathComponent("fixture-build/arguments"), encoding: .utf8)
        #expect(arguments.contains("--arch\narm64\n"))
        #expect(arguments.contains("--arch\nx86_64\n"))
        #expect(arguments.components(separatedBy: "---\n").count - 1 == (failure == "second-arch" ? 4 : 6))
    }

    // Catches rejecting the real macOS release layout or copying only its resource subdirectory.
    @Test func packagesNestedReleaseBundleWithoutFlatteningIt() async throws {
        let fixture = try BuildFixture(nested: true)
        defer { fixture.cleanUp() }
        let result = try await fixture.run()
        #expect(result.status == 0, "\(result.output)")
        guard result.status == 0 else { return }
        let bundleURL = fixture.output.appendingPathComponent("Contents/Resources/Localization.bundle")
        #expect(
            try String(contentsOf: bundleURL.appendingPathComponent("Contents/fixture-marker"), encoding: .utf8)
                == "whole bundle")
        let bundle = try #require(Bundle(url: bundleURL))
        #expect(Localizer(bundle: bundle, preferredLanguages: ["en"]).string("common.cancel") == "取消")
        let plist = try Data(contentsOf: fixture.output.appendingPathComponent("Contents/Info.plist"))
        let info = try #require(PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any])
        #expect(info["CFBundleLocalizations"] as? [String] == ["zh-Hans"])
        #expect(info["CFBundleDevelopmentRegion"] as? String == "zh-Hans")
    }

    // Runs the real script; only compilation and signing are replaced with local commands.
    @Test func packagesRuntimeResourcesAndDerivesSupportedLanguages() async throws {
        let fixture = try BuildFixture(languages: ["fr", "zh-Hans"])
        defer { fixture.cleanUp() }
        let result = try await fixture.run()
        #expect(result.status == 0, "\(result.output)")
        let bundleURL = fixture.output.appendingPathComponent("Contents/Resources/Localization.bundle")
        let bundle = try #require(Bundle(url: bundleURL))
        #expect(Localizer(bundle: bundle, preferredLanguages: ["en"]).string("common.cancel") == "取消")
        let plist = try Data(contentsOf: fixture.output.appendingPathComponent("Contents/Info.plist"))
        let info = try #require(PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any])
        #expect(info["CFBundleLocalizations"] as? [String] == ["fr", "zh-Hans"])
        #expect(info["CFBundleDevelopmentRegion"] as? String == "zh-Hans")
    }

    private func localizationInfo(_ fixture: BuildFixture) throws -> [String: Any] {
        let plist = try Data(contentsOf: fixture.output.appendingPathComponent("Contents/Info.plist"))
        return try #require(PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any])
    }

    private func packagedRoot(_ fixture: BuildFixture) -> URL {
        let bundle = fixture.output.appendingPathComponent("Contents/Resources/Localization.bundle")
        return fixture.nested ? bundle.appendingPathComponent("Contents/Resources") : bundle
    }

    @Test(arguments: [false, true]) func packagesBothProductionLanguages(nested: Bool) async throws {
        // Listed out of order: the generated list is sorted, not directory-creation ordered.
        let fixture = try BuildFixture(languages: ["zh-Hans", "en"], nested: nested)
        defer { fixture.cleanUp() }
        let result = try await fixture.run()
        #expect(result.status == 0, "\(result.output)")
        let root = packagedRoot(fixture)
        for language in ["en", "zh-Hans"] {
            let strings = root.appendingPathComponent("\(language.lowercased()).lproj/Localizable.strings")
            let alternate = root.appendingPathComponent("\(language).lproj/Localizable.strings")
            #expect(
                FileManager.default.fileExists(atPath: strings.path)
                    || FileManager.default.fileExists(atPath: alternate.path),
                "missing \(language)")
        }
        let info = try localizationInfo(fixture)
        #expect(info["CFBundleLocalizations"] as? [String] == ["en", "zh-Hans"])
        #expect(info["CFBundleDevelopmentRegion"] as? String == "zh-Hans")
    }

    @Test(arguments: [false, true]) func missingBuiltEnglishStringsIsRejectedAndKeepsCandidate(nested: Bool) async throws {
        let fixture = try BuildFixture(languages: ["zh-Hans", "en"], nested: nested)
        defer { fixture.cleanUp() }
        try FileManager.default.removeItem(at: fixture.resourceRoot.appendingPathComponent("en.lproj"))
        try FileManager.default.createDirectory(at: fixture.output, withIntermediateDirectories: true)
        let sentinel = fixture.output.appendingPathComponent("existing-candidate")
        try Data("preserved".utf8).write(to: sentinel)
        let result = try await fixture.run()
        #expect(result.status != 0)
        #expect(result.output.contains("Missing localization strings for en"), "\(result.output)")
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "preserved")
        #expect(!FileManager.default.fileExists(atPath: fixture.output.appendingPathComponent("Contents/Info.plist").path))
    }

    @Test func emptySourceEnglishStringsIsRejected() async throws {
        let fixture = try BuildFixture(languages: ["zh-Hans", "en"])
        defer { fixture.cleanUp() }
        try Data().write(to: fixture.resources.appendingPathComponent("en.lproj/Localizable.strings"))
        #expect(try await fixture.run().status != 0)
    }

    @Test func optionalPluralRulesAreCopiedAndNotRequired() async throws {
        let withRules = try BuildFixture(languages: ["zh-Hans", "en"], pluralLanguages: ["en"])
        defer { withRules.cleanUp() }
        #expect(try await withRules.run().status == 0)
        #expect(
            FileManager.default.fileExists(
                atPath: packagedRoot(withRules).appendingPathComponent("en.lproj/Localizable.stringsdict").path))

        let without = try BuildFixture(languages: ["zh-Hans", "en"])
        defer { without.cleanUp() }
        #expect(try await without.run().status == 0)
    }

    @Test func pluralRulesInSourceButMissingFromTheBuildAreRejected() async throws {
        let fixture = try BuildFixture(
            languages: ["zh-Hans", "en"], pluralLanguages: ["en"], builtPluralLanguages: [])
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(at: fixture.output, withIntermediateDirectories: true)
        let sentinel = fixture.output.appendingPathComponent("existing-candidate")
        try Data("preserved".utf8).write(to: sentinel)
        let result = try await fixture.run()
        #expect(result.status != 0)
        #expect(result.output.contains("Missing localization plural rules for en"), "\(result.output)")
        #expect(FileManager.default.fileExists(atPath: sentinel.path))
    }

    // The caller's locale (LC_ALL wins over LC_COLLATE) must not reorder the languages: byte order, uppercase first.
    @Test(arguments: ["en_US.UTF-8", "C", "fr_FR.UTF-8"]) func languageOrderIgnoresTheCallersLocale(locale: String) async throws {
        let fixture = try BuildFixture(languages: ["zh-Hans", "en", "Zh-Hant"])
        defer { fixture.cleanUp() }
        let result = try await fixture.run(environment: ["LC_ALL": locale, "LC_COLLATE": locale, "LANG": locale])
        #expect(result.status == 0, "\(result.output)")
        let info = try localizationInfo(fixture)
        #expect(info["CFBundleLocalizations"] as? [String] == ["Zh-Hant", "en", "zh-Hans"])
    }

    private func rejectsAndKeepsCandidate(
        _ fixture: BuildFixture, expecting message: String, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try FileManager.default.createDirectory(at: fixture.output, withIntermediateDirectories: true)
        let sentinel = fixture.output.appendingPathComponent("existing-candidate")
        try Data("preserved".utf8).write(to: sentinel)
        let result = try await fixture.run()
        #expect(result.status != 0, sourceLocation: sourceLocation)
        #expect(result.output.contains(message), "\(result.output)", sourceLocation: sourceLocation)
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "preserved", sourceLocation: sourceLocation)
        #expect(!FileManager.default.fileExists(atPath: fixture.output.appendingPathComponent("Contents/Info.plist").path), sourceLocation: sourceLocation)
    }

    private static let malformedPlist = "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>a</key></plist>"

    @Test func malformedSourcePluralRulesAreRejected() async throws {
        let fixture = try BuildFixture(languages: ["zh-Hans", "en"], pluralLanguages: ["en"])
        defer { fixture.cleanUp() }
        try Data(Self.malformedPlist.utf8).write(to: fixture.resources.appendingPathComponent("en.lproj/Localizable.stringsdict"))
        try await rejectsAndKeepsCandidate(fixture, expecting: "Invalid localization plural rules for en")
    }

    @Test func emptySourcePluralRulesAreRejected() async throws {
        let fixture = try BuildFixture(languages: ["zh-Hans", "en"], pluralLanguages: ["en"])
        defer { fixture.cleanUp() }
        try Data().write(to: fixture.resources.appendingPathComponent("en.lproj/Localizable.stringsdict"))
        try await rejectsAndKeepsCandidate(fixture, expecting: "Empty localization plural rules for en")
    }

    @Test(arguments: [false, true]) func malformedOrEmptyBuiltPluralRulesAreRejected(empty: Bool) async throws {
        let fixture = try BuildFixture(languages: ["zh-Hans", "en"], pluralLanguages: ["en"])
        defer { fixture.cleanUp() }
        try Data((empty ? "" : Self.malformedPlist).utf8).write(
            to: fixture.resourceRoot.appendingPathComponent("en.lproj/Localizable.stringsdict"))
        try await rejectsAndKeepsCandidate(fixture, expecting: "Invalid localization plural rules for en in")
    }

    @Test func missingBuiltResourceBundleFailsBeforeReplacingExistingApp() async throws {
        let fixture = try BuildFixture()
        defer { fixture.cleanUp() }
        try FileManager.default.removeItem(at: fixture.builtResources)
        try FileManager.default.createDirectory(at: fixture.output, withIntermediateDirectories: true)
        let sentinel = fixture.output.appendingPathComponent("existing-candidate")
        try Data("preserved".utf8).write(to: sentinel)
        #expect(try await fixture.run().status != 0)
        #expect(FileManager.default.fileExists(atPath: sentinel.path))
    }

    @Test func zeroProductionLanguagesFailsPackaging() async throws {
        let fixture = try BuildFixture(languages: [])
        defer { fixture.cleanUp() }
        #expect(try await fixture.run().status != 0)
    }

    @Test(arguments: [false, true]) func missingBuiltLanguagePreservesExistingCandidate(nested: Bool) async throws {
        let fixture = try BuildFixture(nested: nested)
        defer { fixture.cleanUp() }
        try FileManager.default.removeItem(at: fixture.resourceRoot.appendingPathComponent("zh-hans.lproj"))
        try FileManager.default.createDirectory(at: fixture.output, withIntermediateDirectories: true)
        let sentinel = fixture.output.appendingPathComponent("existing-candidate")
        try Data("preserved".utf8).write(to: sentinel)
        #expect(try await fixture.run().status != 0)
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "preserved")
    }
}
