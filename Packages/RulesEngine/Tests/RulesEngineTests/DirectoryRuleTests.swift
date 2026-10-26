import FlowStore
import Foundation
import Testing

@testable import RulesEngine

private func resolve(_ rest: String, prefix: String = "/static/") -> DirectorySubpath {
    DirectorySubpath.resolve(pathAndQuery: prefix + rest, prefix: prefix)
}

private let bookmark = Data([0x62, 0x6F, 0x6F, 0x6B, 0x00, 0xFF, 0x10])

private func directory(
    bookmark: Data = bookmark, displayName: String = "dist", headers: [HeaderField] = []
) -> MapLocalDirectoryAction {
    MapLocalDirectoryAction(bookmark: bookmark, displayName: displayName, headers: headers)
}

private func rule(
    _ id: UUID = UUID(), order: Int = 0, matcher: RuleMatcher = RuleMatcher(path: .prefix("/static/")),
    action: LegacyRuleAction = .mapLocalDirectory(directory())
) -> LegacyRule {
    LegacyRule(id: id, name: "dir", enabled: true, order: order, matcher: matcher, action: action)
}

private func validation(_ rule: LegacyRule) -> (RuleValidationError.Code, RuleValidationError.Field)? {
    do { try rule.validate(); return nil } catch let error as RuleValidationError { return (error.code, error.field) } catch { return nil }
}

private func request(
    path: String = "/static/css/app.css?v=1", method: String = "GET", headers: [HeaderField] = []
) -> HTTPMessageHead {
    .request(
        HTTPMessageTarget(scheme: "https", host: "a.test", port: 443, method: method, pathAndQuery: path),
        headers: headers)
}

private func remote() -> MapRemoteAction {
    MapRemoteAction(targetScheme: "https", targetHost: "other.test", targetPort: 8443, path: .preserve)
}

private struct Stack {
    var root: URL
    var configFile: URL { root.appendingPathComponent("config").appendingPathComponent("rules.json") }
    var repository: RuleRepository

    init(root: URL) {
        self.root = root
        let limits = RulesLimits()
        let budgets = OwnedFileBudgets(limits: limits, freeDiskBytes: ample)
        let assets = ManagedAssetStore(directory: root.appendingPathComponent("assets"), limits: limits, budgets: budgets)
        repository = RuleRepository(directory: root.appendingPathComponent("config"), assets: assets, limits: limits)
    }
}

@Suite("DirectoryRule") struct DirectoryRuleTests {
    // MARK: subpath

    @Test func subpathBasic() {
        #expect(resolve("css/app.css?v=1") == .safe(["css", "app.css"]))
    }

    @Test func rootAndTrailingSlashAreEmptyOrDirectory() {
        #expect(resolve("") == .safe([]))
        #expect(resolve("?x=1") == .safe([]))
        #expect(resolve("css/") == .safe(["css"]))
    }

    @Test func percentDecodedPerSegment() {
        #expect(resolve("%E4%B8%AD.txt") == .safe(["中.txt"]))
        #expect(resolve("a%20b/c%2520d") == .safe(["a b", "c%20d"]))
    }

    @Test func encodedSlashIsUnsafe() {
        #expect(resolve("a%2Fb") == .unsafe)
        #expect(resolve("a%2fb") == .unsafe)
    }

    @Test func encodedAndPlainDotDotAreUnsafe() {
        #expect(resolve("..") == .unsafe)
        #expect(resolve("a/../b") == .unsafe)
        #expect(resolve("%2e%2e") == .unsafe)
        #expect(resolve("%2E.") == .unsafe)
        #expect(resolve(".") == .unsafe)
        #expect(resolve("%2e") == .unsafe)
    }

    @Test func nulIsUnsafe() {
        #expect(resolve("a%00b") == .unsafe)
    }

    /// P2 T5 minor: a decoded segment must not carry line breaks or other control bytes.
    @Test func controlBytesAreUnsafe() {
        for escape in ["%0d", "%0A", "%09", "%1f", "%7f", "%7F", "%01"] {
            #expect(resolve("a\(escape)b") == .unsafe, "\(escape)")
        }
        #expect(resolve("a%20b") == .safe(["a b"]))  // a space is an ordinary file name byte
        #expect(resolve("%E4%BD%A0") == .safe(["你"]))
    }

    @Test func backslashIsUnsafe() {
        #expect(resolve("a%5Cb") == .unsafe)
        #expect(resolve("a%5cb") == .unsafe)
        #expect(resolve("a\\b") == .unsafe)
    }

    @Test func invalidUTF8IsUnsafe() {
        #expect(resolve("%FF") == .unsafe)
        #expect(resolve("a%C3") == .unsafe)
    }

    @Test func malformedEscapeIsUnsafe() {
        #expect(resolve("%G1") == .unsafe)
        #expect(resolve("%4") == .unsafe)
        #expect(resolve("a%") == .unsafe)
        #expect(resolve("%4G") == .unsafe)
    }

    @Test func dotfilesAreUnsafe() {
        #expect(resolve(".git/config") == .unsafe)
        #expect(resolve("a/.env") == .unsafe)
        #expect(resolve("%2Egit") == .unsafe)
    }

    @Test func emptySegmentsCollapse() {
        #expect(resolve("//a///b") == .safe(["a", "b"]))
    }

    @Test func queryIsStrippedBeforeSplit() {
        #expect(resolve("a?b/../c") == .safe(["a"]))
        #expect(resolve("a?%") == .safe(["a"]))
    }

    @Test func plusIsLiteral() {
        #expect(resolve("a+b") == .safe(["a+b"]))
    }

    @Test func longSegmentIsUnsafe() {
        #expect(resolve(String(repeating: "a", count: 255)) == .safe([String(repeating: "a", count: 255)]))
        #expect(resolve(String(repeating: "a", count: 256)) == .unsafe)
        #expect(resolve(String(repeating: "%61", count: 256)) == .unsafe)
    }

    @Test func prefixMismatchIsUnsafe() {
        #expect(DirectorySubpath.resolve(pathAndQuery: "/other/a", prefix: "/static/") == .unsafe)
        #expect(DirectorySubpath.resolve(pathAndQuery: "/stat", prefix: "/static/") == .unsafe)
    }

    // MARK: validation

    @Test func directoryRuleNeedsSlashTerminatedPrefix() {
        for path in [PathMatch.any, .exact("/static/"), .wildcard("/static/*"), .prefix("/static"), .prefix("static/")] {
            let result = validation(rule(matcher: RuleMatcher(path: path)))
            #expect(result?.0 == .directoryNeedsPrefix)
            #expect(result?.1 == .path)
        }
        #expect(validation(rule(matcher: RuleMatcher(path: .prefix("/static/")))) == nil)
        #expect(validation(rule(matcher: RuleMatcher(path: .prefix("/")))) == nil)
    }

    @Test func emptyOrOversizedBookmarkIsInvalid() {
        let empty = validation(rule(action: .mapLocalDirectory(directory(bookmark: Data()))))
        #expect(empty?.0 == .invalidDirectory)
        #expect(empty?.1 == .directory)
        let limit = MapLocalDirectoryAction.maxBookmarkBytes
        #expect(limit == 65_536)
        #expect(validation(rule(action: .mapLocalDirectory(directory(bookmark: Data(count: limit))))) == nil)
        #expect(validation(rule(action: .mapLocalDirectory(directory(bookmark: Data(count: limit + 1)))))?.0 == .invalidDirectory)
    }

    @Test func displayNameIsBoundedByFieldBytes() {
        let tooLong = String(repeating: "d", count: RulesLimits().fieldBytes + 1)
        let result = validation(rule(action: .mapLocalDirectory(directory(displayName: tooLong))))
        #expect(result?.0 == .fieldTooLong)
        #expect(result?.1 == .directory)
    }

    @Test func headerValidationMatchesMapLocal() {
        let cases: [[HeaderField]] = [
            [HeaderField(name: "Content-Length", value: "1")],
            [HeaderField(name: "Transfer-Encoding", value: "chunked")],
            [HeaderField(name: "Bad Name", value: "x")],
            [HeaderField(name: "X-A", value: "a\r\nb")],
        ]
        for headers in cases {
            let local = validation(rule(
                matcher: RuleMatcher(), action: .mapLocal(MapLocalAction(assetID: UUID(), headers: headers))))
            let dir = validation(rule(action: .mapLocalDirectory(directory(headers: headers))))
            #expect(local?.0 == .invalidHeaderEdit)
            #expect(dir?.0 == local?.0)
            #expect(dir?.1 == local?.1)
        }
        #expect(validation(rule(action: .mapLocalDirectory(directory(headers: [HeaderField(name: "Cache-Control", value: "no-store")])))) == nil)
    }

    @Test func statusRangeStillRejected() {
        let matcher = RuleMatcher(path: .prefix("/static/"), statusRange: 200...299)
        let result = validation(rule(matcher: matcher))
        #expect(result?.0 == .statusRangeNotAllowed)
        #expect(result?.1 == .statusRange)
    }

    // MARK: evaluation

    @Test func directoryRuleProducesLocalDirectoryRoute() throws {
        let id = UUID()
        let decision = try LegacyRuleEvaluator.request(
            request(path: "/static/css/app.css?v=1", method: "POST"),
            snapshot: LegacyRuleSnapshot(schemaVersion: 2, revision: 3, rules: [rule(id)]))
        #expect(decision.route == .localDirectory(DirectoryRoute(
            action: directory(), subpath: .safe(["css", "app.css"]), method: "POST")))
        #expect(decision.matches.outcomes == [RuleOutcome(ruleID: id, code: .applied)])
    }

    @Test func unsafePathStillRoutesToTheDirectoryRule() throws {
        let decision = try LegacyRuleEvaluator.request(
            request(path: "/static/%2e%2e/secret"), snapshot: LegacyRuleSnapshot(revision: 1, rules: [rule()]))
        guard case .localDirectory(let route) = decision.route else { Issue.record("expected directory route"); return }
        #expect(route.subpath == .unsafe)
    }

    /// P2 T5 minor: validation requires a prefix path, but a hand-edited or stale snapshot may
    /// not have one. The subpath must then be rejected, never resolved against prefix "".
    @Test func directoryRuleWithoutPrefixPathFailsClosed() throws {
        for path in [PathMatch.any, .exact("/static/css/app.css")] {
            let decision = try LegacyRuleEvaluator.request(
                request(path: "/static/css/app.css"),
                snapshot: LegacyRuleSnapshot(schemaVersion: 2, revision: 1, rules: [rule(matcher: RuleMatcher(path: path))]))
            guard case .localDirectory(let route) = decision.route else { Issue.record("expected directory route"); return }
            #expect(route.subpath == .unsafe, "\(path)")
        }
    }

    @Test func firstMapWinsOverDirectoryRule() throws {
        let first = UUID(), second = UUID()
        let local = MapLocalAction(assetID: UUID(), headers: [])
        let decision = try LegacyRuleEvaluator.request(
            request(), snapshot: LegacyRuleSnapshot(revision: 1, rules: [
                rule(first, order: 0, matcher: RuleMatcher(), action: .mapLocal(local)),
                rule(second, order: 1),
            ]))
        #expect(decision.route == .local(local))
        #expect(decision.matches.outcomes == [
            RuleOutcome(ruleID: first, code: .applied), RuleOutcome(ruleID: second, code: .shadowed),
        ])
    }

    @Test func directoryRuleBeforeMapRemoteShadowsIt() throws {
        let first = UUID(), second = UUID()
        let decision = try LegacyRuleEvaluator.request(
            request(), snapshot: LegacyRuleSnapshot(revision: 1, rules: [
                rule(first, order: 0),
                rule(second, order: 1, matcher: RuleMatcher(), action: .mapRemote(remote())),
            ]))
        guard case .localDirectory = decision.route else { Issue.record("expected directory route"); return }
        #expect(decision.matches.outcomes == [
            RuleOutcome(ruleID: first, code: .applied), RuleOutcome(ruleID: second, code: .shadowed),
        ])
    }

    @Test func secondDirectoryRuleIsShadowed() throws {
        let first = UUID(), second = UUID()
        let decision = try LegacyRuleEvaluator.request(
            request(), snapshot: LegacyRuleSnapshot(revision: 1, rules: [rule(first, order: 0), rule(second, order: 1)]))
        #expect(decision.matches.outcomes.map(\.code) == [.applied, .shadowed])
    }

    @Test func upgradeRequestMarksDirectoryRuleUnsupported() throws {
        let id = UUID()
        let decision = try LegacyRuleEvaluator.request(
            request(headers: [HeaderField(name: "Connection", value: "Upgrade"), HeaderField(name: "Upgrade", value: "websocket")]),
            snapshot: LegacyRuleSnapshot(revision: 1, rules: [rule(id)]))
        #expect(decision.route == .original)
        #expect(decision.matches.outcomes == [RuleOutcome(ruleID: id, code: .unsupportedUpgradeAction)])
    }

    // MARK: storage

    @Test func codableRoundTripKeepsBookmarkBytes() throws {
        let original = rule(action: .mapLocalDirectory(MapLocalDirectoryAction(
            bookmark: bookmark, displayName: "dist", servesIndex: false, missing: .network,
            headers: [HeaderField(name: "X-A", value: "1")])))
        let decoded = try JSONDecoder().decode(LegacyRule.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        guard case .mapLocalDirectory(let action) = decoded.action else { Issue.record("wrong action"); return }
        #expect(action.bookmark == bookmark)
    }

    @Test func repositoryWritesSchema4ForDirectoryRule() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        _ = try await stack.repository.load()
        let directoryRule = Rule(migrating: rule())
        let saved = try await stack.repository.save(groups: [], rules: [directoryRule], expectedRevision: 0)
        #expect(saved.schemaVersion == 4)
        // Every save writes schema 4 (spec 5.1).
        let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: stack.configFile)) as? [String: Any]
        #expect(stored?["schemaVersion"] as? Int == 4)
        let reloaded = try await Stack(root: root).repository.load()
        #expect(reloaded.rules == [directoryRule])
    }

    @Test func directoryRuleDoesNotPinAssets() async throws {
        let root = makeTempDirectory(); defer { removeTree(root) }
        let stack = Stack(root: root)
        _ = try await stack.repository.load()
        _ = try await stack.repository.save(groups: [], rules: [Rule(migrating: rule())], expectedRevision: 0)
        let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: stack.configFile)) as? [String: Any]
        #expect((stored?["assets"] as? [Any])?.isEmpty == true)
    }
}
