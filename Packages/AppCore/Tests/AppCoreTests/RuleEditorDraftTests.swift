import FlowStore
import Foundation
import Localization
import RulesEngine
import Testing
@testable import AppCore

private let fixedID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
private let asset = ManagedAsset(
    id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!, size: 12, displayName: "page.html",
    importedAt: Date(timeIntervalSince1970: 1_800_000_000))

private func headerRow(_ kind: HeaderOperationKind, _ name: String, _ value: String = "") -> HeaderOperationRow {
    HeaderOperationRow(kind: kind, name: name, value: value)
}

@Suite(.productionChinese) struct RuleEditorDraftTests {
    // MARK: the four action forms

    @Test func headerFormKeepsRepeatedOperationsInOrderAndTheResponseStatusRange() throws {
        var draft = RuleEditorDraft(kind: .editHeaders, id: fixedID)
        draft.name = "Cookies"
        draft.direction = .response
        draft.match.host = "api.test"
        draft.match.statusLower = "200"
        draft.match.statusUpper = "299"
        draft.headerOperations = [
            headerRow(.set, "X-A", "1"), headerRow(.append, "Set-Cookie", "a=1"),
            headerRow(.append, "Set-Cookie", "b=2"), headerRow(.remove, "X-Old"),
        ]
        let rule = try #require(draft.validate(order: 3, limits: RulesLimits()).rule)
        #expect(rule == Rule(
            id: fixedID, name: "Cookies", enabled: true, order: 3,
            matcher: RuleMatcher(hostPattern: "api.test", statusRange: 200...299),
            action: .editHeaders(direction: .response, operations: [
                .set(name: "X-A", value: "1"), .append(name: "Set-Cookie", value: "a=1"),
                .append(name: "Set-Cookie", value: "b=2"), .remove(name: "X-Old"),
            ])))

        // Moving a row is moving the operation.
        draft.headerOperations.swapAt(1, 3)
        let moved = try #require(draft.validate(order: 3, limits: RulesLimits()).rule)
        guard case .editHeaders(_, let operations) = moved.action else { Issue.record("wrong kind"); return }
        #expect(operations.map(\.name) == ["X-A", "X-Old", "Set-Cookie", "Set-Cookie"])
    }

    @Test func mapRemoteFormBuildsTargetPathPolicyAndCredentialChoice() throws {
        var draft = RuleEditorDraft(kind: .mapRemote, id: fixedID)
        draft.match.scheme = .https
        draft.match.host = "*.example.test"
        draft.mapRemote.targetScheme = .http
        draft.mapRemote.targetHost = "127.0.0.1"
        draft.mapRemote.targetPort = "8080"
        draft.mapRemote.pathChoice = .replace
        draft.mapRemote.replacementPath = "/v2/items?a=1&a=2"
        draft.mapRemote.preserveCredentials = true
        let rule = try #require(draft.validate(order: 0, limits: RulesLimits()).rule)
        #expect(rule.matcher == RuleMatcher(scheme: "https", hostPattern: "*.example.test"))
        #expect(rule.action == .mapRemote(MapRemoteAction(
            targetScheme: "http", targetHost: "127.0.0.1", targetPort: 8080,
            path: .replace("/v2/items?a=1&a=2"), preserveCredentials: true)))
        #expect(draft.mapRemote.preview == "http://127.0.0.1:8080/v2/items?a=1&a=2")

        draft.mapRemote.pathChoice = .preserve
        draft.mapRemote.targetScheme = .https
        draft.mapRemote.targetPort = "443"
        let preserving = try #require(draft.validate(order: 0, limits: RulesLimits()).rule)
        #expect(preserving.action == .mapRemote(MapRemoteAction(
            targetScheme: "https", targetHost: "127.0.0.1", targetPort: 443, path: .preserve, preserveCredentials: true)))
        // The default port is omitted, and only the origin is fixed while the path is preserved.
        #expect(draft.mapRemote.preview == "https://127.0.0.1")
    }

    @Test func mapLocalFormKeepsTheManagedAssetStatusAndDuplicateHeaders() throws {
        var draft = RuleEditorDraft(kind: .mapLocal, id: fixedID)
        draft.mapLocal.asset = asset
        draft.mapLocal.status = "404"
        draft.mapLocal.headers = [
            HeaderFieldRow(name: "Content-Type", value: "text/html"), HeaderFieldRow(name: "X-Dup", value: "1"),
            HeaderFieldRow(name: "X-Dup", value: "2"),
        ]
        let rule = try #require(draft.validate(order: 0, limits: RulesLimits()).rule)
        #expect(rule.action == .mapLocal(MapLocalAction(assetID: asset.id, status: 404, headers: [
            HeaderField(name: "Content-Type", value: "text/html"), HeaderField(name: "X-Dup", value: "1"),
            HeaderField(name: "X-Dup", value: "2"),
        ])))
    }

    @Test func breakpointFormBuildsDirectionAndPauseMode() throws {
        var draft = RuleEditorDraft(kind: .breakpoint, id: fixedID)
        draft.direction = .response
        draft.breakpointMode = .fullBody
        draft.match.method = "POST"
        let rule = try #require(draft.validate(order: 0, limits: RulesLimits()).rule)
        #expect(rule.action == .breakpoint(direction: .response, mode: .fullBody))
        #expect(rule.matcher == RuleMatcher(method: "POST"))
    }

    @Test func savedRulesRoundTripThroughTheEditorUnchanged() throws {
        let rules = [
            Rule(id: UUID(), name: "a", enabled: false, order: 0,
                 matcher: RuleMatcher(scheme: "http", hostPattern: "a.test", port: 81, method: "GET", path: .prefix("/x?")),
                 action: .editHeaders(direction: .request, operations: [.remove(name: "Cookie"), .append(name: "X", value: "")])),
            Rule(id: UUID(), name: "b", enabled: true, order: 1, matcher: RuleMatcher(path: .exact("/p?q=1&q=2")),
                 action: .mapRemote(MapRemoteAction(targetScheme: "https", targetHost: "b.test", targetPort: 9443, path: .preserve))),
            Rule(id: UUID(), name: "c", enabled: true, order: 2, matcher: RuleMatcher(hostPattern: "c.test", statusRange: 500...599),
                 action: .breakpoint(direction: .response, mode: .headers)),
            Rule(id: UUID(), name: "d", enabled: true, order: 3, matcher: RuleMatcher(),
                 action: .mapLocal(MapLocalAction(assetID: asset.id, status: 201, headers: [HeaderField(name: "A", value: "1")]))),
        ]
        for rule in rules {
            let draft = RuleEditorDraft(rule: rule, asset: asset)
            #expect(draft.validate(order: rule.order, limits: RulesLimits()).rule == rule)
        }
    }

    // MARK: field-specific validation through the shared validator

    @Test(arguments: [
        ("port", "abc", RuleDraftField.port, RuleDraftIssue.notANumber),
        ("port", "0", .port, .invalidPort),
        ("host", "http://a.test", .host, .invalidHostPattern),
        ("method", "GE T", .method, .invalidMethod),
        ("pathExact", "", .path, .required),
        ("pathExact", "/a b", .path, .invalidPath),
        ("statusOnRequest", "200", .statusRange, .statusRangeNotAllowed),
        ("statusReversed", "300", .statusRange, .invalidStatusRange),
        ("statusHalf", "300", .statusRange, .required),
    ])
    func invalidMatcherInputMarksItsOwnField(_ input: String, _ value: String, _ field: RuleDraftField, _ issue: RuleDraftIssue) {
        var draft = RuleEditorDraft(kind: .editHeaders, id: fixedID)
        draft.direction = .response
        switch input {
        case "port": draft.match.port = value
        case "host": draft.match.host = value
        case "method": draft.match.method = value
        case "pathExact": draft.match.pathMode = .exact; draft.match.path = value
        case "statusOnRequest":
            draft.direction = .request
            draft.match.statusLower = value; draft.match.statusUpper = value
        case "statusReversed": draft.match.statusLower = value; draft.match.statusUpper = "200"
        case "statusHalf": draft.match.statusLower = value
        default: Issue.record("unknown input")
        }
        let result = draft.validate(order: 0, limits: RulesLimits())
        #expect(result.rule == nil)
        #expect(result.issues == [field: issue])
    }

    @Test func everyBrokenFieldIsReportedAtOnce() {
        var draft = RuleEditorDraft(kind: .mapRemote, id: fixedID)
        draft.match.port = "abc"
        draft.match.method = "GE T"
        draft.mapRemote.targetHost = "bad host"
        draft.mapRemote.targetPort = "70000"
        draft.mapRemote.pathChoice = .replace
        draft.mapRemote.replacementPath = "relative"
        let result = draft.validate(order: 0, limits: RulesLimits())
        #expect(result.rule == nil)
        #expect(result.issues == [
            .port: .notANumber, .method: .invalidMethod, .targetHost: .invalidTargetHost,
            .targetPort: .invalidTargetPort, .targetPath: .invalidTargetPath,
        ])
    }

    @Test func actionFieldsAreMarkedPerRow() {
        var headers = RuleEditorDraft(kind: .editHeaders, id: fixedID)
        let protected = headerRow(.set, "Content-Length", "1"), badName = headerRow(.append, "Bad Name", "x")
        headers.headerOperations = [headerRow(.set, "X-Fine", "1"), protected, badName]
        #expect(headers.validate(order: 0, limits: RulesLimits()).issues == [
            .headerOperation(protected.id): .headerProtected, .headerOperation(badName.id): .headerNameInvalid,
        ])

        var local = RuleEditorDraft(kind: .mapLocal, id: fixedID)
        local.mapLocal.status = "99"
        let badValue = HeaderFieldRow(name: "X-Value", value: "a\r\nb")
        local.mapLocal.headers = [badValue]
        #expect(local.validate(order: 0, limits: RulesLimits()).issues == [
            .mapLocalAsset: .assetRequired, .mapLocalStatus: .invalidStatus, .mapLocalHeader(badValue.id): .headerValueInvalid,
        ])

        var long = RuleEditorDraft(kind: .breakpoint, id: fixedID)
        long.name = String(repeating: "n", count: 17)
        #expect(long.validate(order: 0, limits: RulesLimits(fieldBytes: 16)).issues == [.name: .fieldTooLong])
    }

    // MARK: method case (Task 3 carried UI obligation)

    @Test func methodCaseIsKeptExactlyAndWarnedBecauseMatchingIsCaseSensitive() throws {
        var draft = RuleEditorDraft(kind: .breakpoint, id: fixedID)
        draft.match.method = "get"
        let rule = try #require(draft.validate(order: 0, limits: RulesLimits()).rule)
        #expect(rule.matcher.method == "get")
        #expect(draft.warnings == [.methodCase("get")])
        let target = HTTPMessageTarget(scheme: "https", host: "a.test", port: 443, method: "GET", pathAndQuery: "/")
        #expect(!rule.matcher.matches(target, status: nil))

        draft.match.method = "PURGE"
        #expect(draft.warnings.isEmpty)
        draft.match.method = ""
        #expect(draft.warnings.isEmpty)
    }

    // MARK: drafts from a captured flow (T9a-GPT-R32)

    /// Replaces manual07's `makeRuleFromFlowUsesHostPathWithoutQuery`: design §3, the original Task 9
    /// and the matcher's path+query contract require the full original target, duplicate query
    /// items, order, case and percent spelling included (R32).
    @Test func flowDraftMatchesTheFullOriginalTargetIncludingDuplicateQueryItems() throws {
        var flow = Flow(id: 7, scheme: "https", method: "PATCH", host: "legacy.test", port: 8443, path: "/legacy")
        let original = HTTPMessageTarget(
            scheme: "https", host: "API.Example.test", port: 8443, method: "PATCH",
            pathAndQuery: "/Search/%7Euser?q=b&q=a&Q=%2f")
        flow.messages[.downstreamRequest] = HTTPMessageSnapshot(boundary: .downstreamRequest, head: .request(original, headers: []))
        // A remapped upstream target must never leak into the draft.
        flow.messages[.upstreamRequest] = HTTPMessageSnapshot(boundary: .upstreamRequest, head: .request(
            HTTPMessageTarget(scheme: "http", host: "127.0.0.1", port: 9000, method: "PATCH", pathAndQuery: "/other"), headers: []))

        for kind in RuleKind.allCases {
            var draft = RuleEditorDraft.fromFlow(flow, kind: kind)
            // The one thing a rewrite draft cannot take from the flow (it has no response here).
            if kind == .rewriteBody { draft.bodyRewrite.find = "x" }
            if kind == .rewriteStatus { draft.rewriteStatus.status = "404" }
            if kind == .comment { draft.comment.text = "x" }
            #expect(draft.kind == kind)
            #expect(draft.name == "API.Example.test")
            if kind == .mapLocal {
                // The file is the one thing a Map Local draft cannot take from the flow.
                #expect(draft.validate(order: 0, limits: RulesLimits()).issues == [.mapLocalAsset: .assetRequired])
                draft.mapLocal.asset = asset
            }
            if kind == .mapLocalDirectory {
                // A directory serves a prefix, so it matches the directory part of the original path.
                #expect(draft.validate(order: 0, limits: RulesLimits()).issues == [.directory: .directoryRequired])
                draft.mapLocalDirectory.bookmark = Data([1])
                let rule = try #require(draft.validate(order: 0, limits: RulesLimits()).rule)
                #expect(rule.matcher.path == .prefix("/Search/"))
                #expect(rule.matcher.matches(original, status: nil))
                continue
            }
            let rule = try #require(draft.validate(order: 0, limits: RulesLimits()).rule)
            let matcher = try #require(rule.simpleAnnotation?.matcher ?? rule.simple?.matcher)
            #expect(matcher == RuleMatcher(
                scheme: "https", hostPattern: "API.Example.test", port: 8443, method: "PATCH",
                path: .exact("/Search/%7Euser?q=b&q=a&Q=%2f")))
            #expect(matcher.matches(original, status: nil))
            var reordered = original
            reordered.pathAndQuery = "/Search/%7Euser?q=a&q=b&Q=%2f"
            #expect(!matcher.matches(reordered, status: nil))
        }
        // Map Remote starts at the same origin, preserving the path, so the user only edits the target.
        let remote = RuleEditorDraft.fromFlow(flow, kind: .mapRemote)
        #expect(remote.mapRemote.targetHost == "API.Example.test" && remote.mapRemote.targetPort == "8443")
        #expect(remote.mapRemote.targetScheme == .https && remote.mapRemote.pathChoice == .preserve)
    }

    @Test func legacyFlowWithoutBoundariesFallsBackToItsRecordedFields() throws {
        let flow = Flow(id: 1, scheme: "http", method: "GET", host: "old.test", port: 8080, path: "/a?x=1&x=1")
        let rule = try #require(RuleEditorDraft.fromFlow(flow, kind: .breakpoint).validate(order: 0, limits: RulesLimits()).rule)
        #expect(rule.matcher == RuleMatcher(scheme: "http", hostPattern: "old.test", port: 8080, method: "GET", path: .exact("/a?x=1&x=1")))
    }

    // MARK: Map Local directory (P2 task 8)

    private func directoryDraft(path: String = "/static/") -> RuleEditorDraft {
        var draft = RuleEditorDraft(kind: .mapLocalDirectory, id: fixedID)
        draft.match.host = "app.test"
        draft.match.path = path
        draft.mapLocalDirectory.bookmark = Data([1, 2, 3])
        draft.mapLocalDirectory.displayName = "dist"
        return draft
    }

    @Test func directoryDraftBuildsDirectoryRule() throws {
        var draft = directoryDraft()
        draft.mapLocalDirectory.servesIndex = false
        draft.mapLocalDirectory.missing = .network
        draft.mapLocalDirectory.headers = [HeaderFieldRow(name: "Cache-Control", value: "no-store")]
        #expect(draft.match.syntax == .literal && draft.match.pathMode == .prefix)
        let rule = try #require(draft.validate(order: 2, limits: RulesLimits()).rule)
        #expect(rule == Rule(
            id: fixedID, name: "", enabled: true, order: 2,
            matcher: RuleMatcher(hostPattern: "app.test", path: .prefix("/static/")),
            action: .mapLocalDirectory(MapLocalDirectoryAction(
                bookmark: Data([1, 2, 3]), displayName: "dist", servesIndex: false, missing: .network,
                headers: [HeaderField(name: "Cache-Control", value: "no-store")]))))
        #expect(!RuleKind.mapLocalDirectory.hasDirection)
        #expect(RuleKind.mapLocalDirectory.systemImage == "folder")
        #expect(RuleKind.mapLocalDirectory.localizationKey == "rules.kind.mapLocalDirectory")
    }

    @Test func directoryDraftWithoutBookmarkReportsDirectoryRequired() {
        var draft = directoryDraft()
        draft.mapLocalDirectory.bookmark = nil
        let validation = draft.validate(order: 0, limits: RulesLimits())
        #expect(validation.rule == nil)
        #expect(validation.issues == [.directory: .directoryRequired])
    }

    @Test func directoryDraftRejectsPrefixWithoutTrailingSlash() {
        for path in ["/static", "static/", "/static?x=1", "x"] {
            let validation = directoryDraft(path: path).validate(order: 0, limits: RulesLimits())
            #expect(validation.rule == nil, "\(path)")
            #expect(validation.issues == [.path: .directoryNeedsPrefix], "\(path)")
        }
        // Not a prefix at all: exact and "any" cannot serve a directory.
        for mode in [RulePathMode.exact, .any] {
            var draft = directoryDraft()
            draft.match.pathMode = mode
            #expect(draft.validate(order: 0, limits: RulesLimits()).issues == [.path: .directoryNeedsPrefix])
        }
        var empty = directoryDraft(path: "")
        #expect(empty.validate(order: 0, limits: RulesLimits()).issues == [.path: .required])
        empty.match.path = "/"
        #expect(empty.validate(order: 0, limits: RulesLimits()).rule?.matcher.path == .prefix("/"))
    }

    @Test func directoryDraftForcesLiteralSyntax() {
        for syntax in [PatternSyntax.regex, .wildcard] {
            var draft = directoryDraft()
            draft.match.host = ""
            draft.match.syntax = syntax
            let validation = draft.validate(order: 0, limits: RulesLimits())
            #expect(validation.rule == nil && validation.issues == [.path: .directoryNeedsPrefix], "\(syntax)")
        }
        // Choosing the kind takes the draft back to a literal prefix.
        var other = RuleEditorDraft(kind: .mapLocal, id: fixedID)
        other.match.chooseSyntax(.regex)
        other.kind = .mapLocalDirectory
        #expect(other.match.syntax == .literal && other.match.pathMode == .prefix)
    }

    @Test func loadingDirectoryRuleRoundTrips() throws {
        var draft = directoryDraft()
        draft.name = "SPA"
        draft.mapLocalDirectory.servesIndex = false
        draft.mapLocalDirectory.missing = .network
        draft.mapLocalDirectory.headers = [HeaderFieldRow(name: "X-A", value: "1"), HeaderFieldRow(name: "X-A", value: "2")]
        let rule = try #require(draft.validate(order: 0, limits: RulesLimits()).rule)
        let loaded = RuleEditorDraft(rule: rule, asset: nil)
        #expect(loaded.kind == .mapLocalDirectory && RuleKind(rule.action) == .mapLocalDirectory)
        #expect(loaded.mapLocalDirectory.bookmark == Data([1, 2, 3]) && loaded.mapLocalDirectory.displayName == "dist")
        #expect(loaded.mapLocalDirectory.servesIndex == false && loaded.mapLocalDirectory.missing == .network)
        #expect(loaded.mapLocalDirectory.headers.map(\.name) == ["X-A", "X-A"] && loaded.mapLocalDirectory.headers.map(\.value) == ["1", "2"])
        #expect(loaded.match.syntax == .literal && loaded.match.pathMode == .prefix && loaded.match.path == "/static/")
        #expect(try #require(loaded.validate(order: 0, limits: RulesLimits()).rule) == rule)
    }

    @Test func directoryHeaderAndOversizedNameIssuesLandOnTheirFields() {
        var draft = directoryDraft()
        draft.mapLocalDirectory.headers = [HeaderFieldRow(name: "Bad Name", value: "x")]
        let headerRow = draft.mapLocalDirectory.headers[0]
        #expect(draft.validate(order: 0, limits: RulesLimits()).issues == [.mapLocalHeader(headerRow.id): .headerNameInvalid])
        draft.mapLocalDirectory.headers = []
        draft.mapLocalDirectory.displayName = String(repeating: "d", count: RulesLimits().fieldBytes + 1)
        #expect(draft.validate(order: 0, limits: RulesLimits()).issues == [.directory: .fieldTooLong])
    }

    @Test func flowDraftOfDirectoryKindMatchesTheContainingDirectory() throws {
        let flow = Flow(id: 1, scheme: "https", method: "GET", host: "app.test", port: 443, path: "/static/js/app.js?v=1")
        var draft = RuleEditorDraft.fromFlow(flow, kind: .mapLocalDirectory)
        #expect(draft.validate(order: 0, limits: RulesLimits()).issues == [.directory: .directoryRequired])
        draft.mapLocalDirectory.bookmark = Data([9])
        let rule = try #require(draft.validate(order: 0, limits: RulesLimits()).rule)
        #expect(rule.matcher.path == .prefix("/static/js/"))
    }

    @Test func summaryShowsPrefixAndDirectoryName() throws {
        let localizer = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        let rule = try #require(directoryDraft().validate(order: 0, limits: RulesLimits()).rule)
        #expect(RulePresentation.summary(of: rule, localizer: localizer) == "*://app.test/static/* → 目录 dist")
        #expect(RulePresentation.summary(of: rule, localizer: localizer)
            == localizer.format("rules.summary.directory", arguments: ["*://app.test/static/*", "dist"]))
        // Other kinds are unchanged.
        let header = Rule(id: fixedID, name: "", enabled: true, order: 0, matcher: RuleMatcher(hostPattern: "a.test"),
                          action: .breakpoint(direction: .request, mode: .headers))
        #expect(RulePresentation.summary(of: header, localizer: localizer) == RulePresentation.matchSummary(header.matcher, localizer: localizer))
    }

    // MARK: list presentation

    @Test func matchSummaryShowsEveryConstraintVerbatim() {
        let localizer = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        #expect(RulePresentation.matchSummary(RuleMatcher(
            scheme: "https", hostPattern: "*.a.test", port: 8443, method: "GET", path: .prefix("/api?")), localizer: localizer)
            == "GET https://*.a.test:8443/api?*")
        #expect(RulePresentation.matchSummary(RuleMatcher(path: .exact("/x?y=%2F")), localizer: localizer) == "*://*/x?y=%2F")
        #expect(RulePresentation.matchSummary(RuleMatcher(), localizer: localizer) == localizer.string("rules.summary.anyRequest"))
        #expect(RulePresentation.matchSummary(RuleMatcher(hostPattern: "a.test", statusRange: 500...599), localizer: localizer)
            == localizer.format("rules.summary.withStatus", arguments: ["*://a.test/*", 500, 599]))
    }

    // MARK: match syntax

    private func advancedDraft(_ syntax: PatternSyntax, host: String = "", path: String = "") -> RuleEditorDraft {
        var draft = RuleEditorDraft(kind: .breakpoint, id: fixedID)
        draft.match.syntax = syntax
        draft.match.host = host
        draft.match.path = path
        return draft
    }

    @Test func wildcardDraftBuildsWildcardRule() throws {
        let draft = advancedDraft(.wildcard, host: "*.example.com", path: "/api/*")
        let rule = try #require(draft.validate(order: 0, limits: RulesLimits()).rule)
        #expect(rule.matcher.hostSyntax == .wildcard)
        #expect(rule.matcher.hostPattern == "*.example.com")
        #expect(rule.matcher.path == .wildcard("/api/*"))
    }

    @Test func regexDraftBuildsRegexRule() throws {
        var draft = advancedDraft(.regex, host: #"api\d+\.example\.com"#, path: #"/v[0-9]+/items"#)
        draft.match.pathMode = .prefix  // ignored outside the literal syntax
        let rule = try #require(draft.validate(order: 0, limits: RulesLimits()).rule)
        #expect(rule.matcher.hostSyntax == .regex)
        #expect(rule.matcher.hostPattern == #"api\d+\.example\.com"#)
        #expect(rule.matcher.path == .regex(#"/v[0-9]+/items"#))
    }

    @Test func emptyPathUnderWildcardMeansAny() throws {
        let draft = advancedDraft(.wildcard, host: "*.example.com")
        let rule = try #require(draft.validate(order: 0, limits: RulesLimits()).rule)
        #expect(rule.matcher.path == .any)
        let neither = advancedDraft(.regex)
        let anything = try #require(neither.validate(order: 0, limits: RulesLimits()).rule)
        #expect(anything.matcher.hostPattern == nil && anything.matcher.path == .any)
        #expect(anything.matcher.hostSyntax == .literal)  // nothing to interpret, so no schema 2 marker
    }

    @Test func invalidRegexReportsPathIssue() {
        let result = advancedDraft(.regex, path: "([a-z").validate(order: 0, limits: RulesLimits())
        #expect(result.rule == nil)
        #expect(result.issues == [.path: .invalidRegex])
    }

    @Test func invalidWildcardOnHostReportsHostIssue() {
        let result = advancedDraft(.wildcard, host: #"bad\q"#).validate(order: 0, limits: RulesLimits())
        #expect(result.rule == nil)
        #expect(result.issues == [.host: .invalidWildcard])
        let path = advancedDraft(.wildcard, path: "/a\\q").validate(order: 0, limits: RulesLimits())
        #expect(path.issues == [.path: .invalidWildcard])
    }

    @Test func riskyRegexReportsTooComplex() {
        let path = advancedDraft(.regex, path: "(a+)+").validate(order: 0, limits: RulesLimits())
        #expect(path.rule == nil && path.issues == [.path: .regexTooComplex])
        let host = advancedDraft(.regex, host: "(a+)+").validate(order: 0, limits: RulesLimits())
        #expect(host.issues == [.host: .regexTooComplex])
    }

    @Test func literalDraftStillBuildsOldRule() throws {
        var draft = RuleEditorDraft(kind: .editHeaders, id: fixedID)
        draft.name = "n"
        draft.direction = .response
        draft.match.scheme = .https
        draft.match.host = "*.a.test"
        draft.match.port = "8443"
        draft.match.method = "GET"
        draft.match.pathMode = .prefix
        draft.match.path = "/api*?"  // literal characters, not a wildcard
        draft.match.statusLower = "500"
        draft.match.statusUpper = "599"
        draft.headerOperations = [headerRow(.remove, "X")]
        #expect(draft.match.syntax == .literal)
        let rule = try #require(draft.validate(order: 2, limits: RulesLimits()).rule)
        #expect(rule == Rule(
            id: fixedID, name: "n", enabled: true, order: 2,
            matcher: RuleMatcher(
                scheme: "https", hostPattern: "*.a.test", port: 8443, method: "GET", path: .prefix("/api*?"),
                statusRange: 500...599),
            action: .editHeaders(direction: .response, operations: [.remove(name: "X")])))
        #expect(rule.matcher.hostSyntax == .literal)
    }

    @Test func loadingKeepsSyntaxRoundTrip() throws {
        let matchers = [
            RuleMatcher(hostPattern: "*.example.com", path: .wildcard("/api/*"), hostSyntax: .wildcard),
            RuleMatcher(hostPattern: #"api\d+\.example\.com"#, path: .regex("/v[0-9]+/.*"), hostSyntax: .regex),
            RuleMatcher(hostPattern: "*.example.com", path: .any, hostSyntax: .wildcard),
            RuleMatcher(path: .wildcard("/x/?")),
            RuleMatcher(path: .regex("/a|/b")),
            RuleMatcher(scheme: "https", port: 443, method: "GET", path: .regex("/a"), statusRange: 200...299),
        ]
        for (index, matcher) in matchers.enumerated() {
            let rule = Rule(
                id: UUID(), name: "r\(index)", enabled: true, order: index, matcher: matcher,
                action: .breakpoint(direction: .response, mode: .headers))
            let draft = RuleEditorDraft(rule: rule, asset: nil)
            #expect(!draft.match.hasMixedSyntax, "\(index)")
            #expect(draft.validate(order: index, limits: RulesLimits()).rule == rule, "\(index)")
        }
        let regex = RuleEditorDraft(rule: Rule(
            id: UUID(), name: "", enabled: true, order: 0,
            matcher: RuleMatcher(hostPattern: "a.test", path: .regex("/a"), hostSyntax: .regex),
            action: .breakpoint(direction: .request, mode: .headers)), asset: nil)
        #expect(regex.match.syntax == .regex && regex.match.host == "a.test" && regex.match.path == "/a")
    }

    @Test func hostLiteralPathRegexLoadsAsMixedSyntax() {
        func load(_ matcher: RuleMatcher) -> (RuleEditorDraft, RuleDraftValidation) {
            let draft = RuleEditorDraft(rule: Rule(
                id: fixedID, name: "", enabled: true, order: 0, matcher: matcher,
                action: .breakpoint(direction: .request, mode: .headers)), asset: nil)
            return (draft, draft.validate(order: 0, limits: RulesLimits()))
        }
        let (draft, result) = load(RuleMatcher(hostPattern: "a.test", path: .regex("/a.*")))
        #expect(draft.match.hasMixedSyntax)
        #expect(result.rule == nil)
        #expect(result.issues == [.path: .mixedSyntax])
        #expect(load(RuleMatcher(hostPattern: "*.a.test", path: .wildcard("/a*"))).1.issues == [.path: .mixedSyntax])
        #expect(load(RuleMatcher(hostPattern: "a.*", path: .regex("/a"), hostSyntax: .wildcard)).1.issues == [.path: .mixedSyntax])
        #expect(load(RuleMatcher(hostPattern: "a.+", path: .wildcard("/a"), hostSyntax: .regex)).1.issues == [.path: .mixedSyntax])

        // Choosing a syntax resolves it: the user takes responsibility for the text now shown.
        var fixed = draft
        fixed.match.syntax = .literal
        fixed.match.pathMode = .exact
        fixed.match.path = "/a"
        #expect(fixed.validate(order: 0, limits: RulesLimits()).rule != nil)
        var regex = draft
        regex.match.syntax = .wildcard
        regex.match.syntax = .regex
        #expect(!regex.match.hasMixedSyntax)
    }

    @Test func choosingTheSameSyntaxAgainClearsTheMixedFlag() {
        var draft = RuleEditorDraft(rule: Rule(
            id: fixedID, name: "", enabled: true, order: 0,
            matcher: RuleMatcher(hostPattern: "*.a.test", path: .wildcard("/a*")),
            action: .breakpoint(direction: .request, mode: .headers)), asset: nil)
        #expect(draft.match.hasMixedSyntax && draft.match.syntax == .wildcard)
        #expect(draft.validate(order: 0, limits: RulesLimits()).issues == [.path: .mixedSyntax])
        draft.match.chooseSyntax(.wildcard)
        #expect(!draft.match.hasMixedSyntax && draft.match.syntax == .wildcard)
        let rule = draft.validate(order: 0, limits: RulesLimits()).rule
        #expect(rule?.matcher == RuleMatcher(hostPattern: "*.a.test", path: .wildcard("/a*"), hostSyntax: .wildcard))
    }

    @Test func switchingAnAdvancedPathToLiteralKeepsTheTextAndAPathMode() throws {
        for original in [PathMatch.wildcard("/api/*"), .regex("/api/.*")] {
            var draft = RuleEditorDraft(rule: Rule(
                id: fixedID, name: "", enabled: true, order: 0,
                matcher: RuleMatcher(path: original),
                action: .breakpoint(direction: .request, mode: .headers)), asset: nil)
            #expect(draft.match.pathMode == .any)
            draft.match.chooseSyntax(.literal)
            #expect(draft.match.path == (original == .wildcard("/api/*") ? "/api/*" : "/api/.*"))
            #expect(draft.match.pathMode == .exact, "the text must not silently stop applying")
            let rule = try #require(draft.validate(order: 0, limits: RulesLimits()).rule)
            #expect(rule.matcher.path == .exact(draft.match.path))
        }
        // A path mode the user picked is never overridden, and an empty path stays "any".
        var chosen = RuleMatchDraft()
        chosen.pathMode = .prefix
        chosen.path = "/x"
        chosen.chooseSyntax(.regex)
        chosen.chooseSyntax(.literal)
        #expect(chosen.pathMode == .prefix && chosen.path == "/x")
        var empty = RuleMatchDraft()
        empty.chooseSyntax(.wildcard)
        empty.chooseSyntax(.literal)
        #expect(empty.pathMode == .any && empty.path.isEmpty)
    }

    @Test func advancedHostWithLiteralPathLoadsFaithfully() throws {
        let exact = Rule(
            id: fixedID, name: "", enabled: true, order: 0,
            matcher: RuleMatcher(hostPattern: "*.a.test", path: .exact("/a*b?c\\d"), hostSyntax: .wildcard),
            action: .breakpoint(direction: .request, mode: .headers))
        let draft = RuleEditorDraft(rule: exact, asset: nil)
        #expect(!draft.match.hasMixedSyntax && draft.match.syntax == .wildcard)
        let saved = try #require(draft.validate(order: 0, limits: RulesLimits()).rule)
        let target = { (path: String) in HTTPMessageTarget(scheme: "https", host: "x.a.test", port: 443, method: "GET", pathAndQuery: path) }
        #expect(saved.matcher.matches(target("/a*b?c\\d"), status: nil))
        #expect(!saved.matcher.matches(target("/aXXb1c\\d"), status: nil))

        let prefix = Rule(
            id: fixedID, name: "", enabled: true, order: 0,
            matcher: RuleMatcher(hostPattern: #"x\.a\.test"#, path: .prefix("/p.q"), hostSyntax: .regex),
            action: .breakpoint(direction: .request, mode: .headers))
        let regexSaved = try #require(RuleEditorDraft(rule: prefix, asset: nil).validate(order: 0, limits: RulesLimits()).rule)
        #expect(regexSaved.matcher.matches(target("/p.q/more?x=1"), status: nil))
        #expect(!regexSaved.matcher.matches(target("/pXq"), status: nil))
    }

    @Test func requestRuleStillRejectsStatusRange() {
        var draft = advancedDraft(.wildcard, host: "*.example.com", path: "/api/*")
        draft.match.statusLower = "200"
        draft.match.statusUpper = "299"
        let result = draft.validate(order: 0, limits: RulesLimits())
        #expect(result.rule == nil)
        #expect(result.issues == [.statusRange: .statusRangeNotAllowed])
    }

    @Test func everyEngineValidationCodeHasItsOwnIssue() {
        #expect(RuleDraftIssue(RuleValidationError(code: .invalidWildcard, field: .path)) == .invalidWildcard)
        #expect(RuleDraftIssue(RuleValidationError(code: .invalidRegex, field: .hostPattern)) == .invalidRegex)
        #expect(RuleDraftIssue(RuleValidationError(code: .regexTooComplex, field: .path)) == .regexTooComplex)
    }

    @Test func unsupportedStructureIssueMapsFromTheNewErrorCodes() {
        let structural: [RuleValidationError.Code] = [
            .tooManyActions, .noActions, .tooManyConditions, .invalidOperator, .tooManyRules, .groupTooDeep, .unknownGroup,
            .groupCycle, .duplicateID,
        ]
        for code in structural {
            #expect(RuleDraftIssue(RuleValidationError(code: code, field: .conditions)) == .unsupportedStructure, "\(code)")
        }
        // A request-side action behind a status row is what the old editor calls a status range on a request rule.
        #expect(
            RuleDraftIssue(RuleValidationError(code: .actionNotAllowedAtJudgmentPoint, field: .action(index: 0)))
                == .statusRangeNotAllowed)
        // The old codes keep their issues.
        #expect(RuleDraftIssue(RuleValidationError(code: .invalidPort, field: .port)) == .invalidPort)
    }

    @Test func everyR4ValidationCodeHasItsOwnIssueAndMessage() {
        let table: [(RuleValidationError.Code, RuleDraftIssue, String)] = [
            (.invalidURLEdit, .invalidURLEdit, "rules.issue.invalidURLEdit"),
            (.invalidQueryEdit, .invalidQueryEdit, "rules.issue.invalidQueryEdit"),
            (.invalidCookieEdit, .invalidCookieEdit, "rules.issue.invalidCookieEdit"),
            (.emptyEditFind, .emptyEditFind, "rules.issue.emptyEditFind"),
            (.invalidDelay, .invalidDelay, "rules.issue.invalidDelay"),
            (.invalidHandwrittenResponse, .invalidHandwrittenResponse, "rules.issue.invalidHandwrittenResponse"),
            (.handwrittenResponseTooLarge, .handwrittenResponseTooLarge, "rules.issue.handwrittenResponseTooLarge"),
            (.presetNeedsLocation, .presetNeedsLocation, "rules.issue.presetNeedsLocation"),
            (.invalidPresetField, .invalidPresetField, "rules.issue.invalidPresetField"),
            (.connectActionCondition, .connectActionCondition, "rules.issue.connectActionCondition"),
            (.connectActionMixed, .connectActionMixed, "rules.issue.connectActionMixed"),
        ]
        let zh = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        for (code, issue, key) in table {
            #expect(RuleDraftIssue(RuleValidationError(code: code, field: .action(index: 0))) == issue, "\(code)")
            #expect(issue.localizationKey == key)
            #expect(zh.string(key) != key, "\(key) is translated")
            #expect(issue.rawValue == "\(code)", "the MCP issue code is the raw value")
        }
    }

    @Test func summaryShowsSyntaxLabel() {
        let localizer = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        let wildcard = RulePresentation.matchSummary(
            RuleMatcher(hostPattern: "*.a.test", path: .wildcard("/api/*"), hostSyntax: .wildcard), localizer: localizer)
        #expect(wildcard == localizer.format("rules.summary.withSyntax", arguments: [
            "*://*.a.test/api/*", localizer.string("rules.summary.syntaxWildcard"),
        ]))
        let regex = RulePresentation.matchSummary(RuleMatcher(path: .regex("/v[0-9]+")), localizer: localizer)
        #expect(regex == localizer.format("rules.summary.withSyntax", arguments: [
            "*://*/v[0-9]+", localizer.string("rules.summary.syntaxRegex"),
        ]))
        #expect(wildcard != regex)
        // The label closes the whole summary, status included.
        let withStatus = RulePresentation.matchSummary(
            RuleMatcher(path: .wildcard("/a*"), statusRange: 500...599), localizer: localizer)
        #expect(withStatus == localizer.format("rules.summary.withSyntax", arguments: [
            localizer.format("rules.summary.withStatus", arguments: ["*://*/a*", 500, 599]),
            localizer.string("rules.summary.syntaxWildcard"),
        ]))
    }

    @Test func literalSummaryUnchanged() {
        let localizer = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        #expect(RulePresentation.matchSummary(RuleMatcher(hostPattern: "*.a.test", path: .prefix("/api")), localizer: localizer)
            == "*://*.a.test/api*")
        #expect(RulePresentation.matchSummary(RuleMatcher(path: .exact("/a*b")), localizer: localizer) == "*://*/a*b")
    }

    @Test func syntaxTitlesAndHintsResolveToTheirOwnKeys() {
        let localizer = Localizer(bundle: L10n.bundle, preferredLanguages: ["zh-Hans"])
        #expect(PatternSyntax.literal.titleKey == "rules.match.syntax.literal" && PatternSyntax.literal.hintKey == nil)
        #expect(PatternSyntax.wildcard.titleKey == "rules.match.syntax.wildcard" && PatternSyntax.wildcard.hintKey == "rules.match.hint.wildcard")
        #expect(PatternSyntax.regex.titleKey == "rules.match.syntax.regex" && PatternSyntax.regex.hintKey == "rules.match.hint.regex")
        #expect(PatternSyntax.regex.title(localizer: localizer) == "正则表达式")
        #expect(PatternSyntax.literal.hint(localizer: localizer) == nil)
        #expect(PatternSyntax.wildcard.hint(localizer: localizer)?.contains("*.example.com") == true)
    }
}
