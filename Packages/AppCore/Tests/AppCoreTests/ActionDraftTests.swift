import FlowStore
import Foundation
import RulesEngine
import Testing

@testable import AppCore

@Suite(.productionChinese) struct ActionDraftTests {
    private let limits = RulesLimits()

    private func build(_ draft: ActionDraft) -> ActionBuildResult { draft.build(limits: limits) }

    // MARK: one minimal legal input per type

    @Test func modifyURLBuildsFromTheFields() {
        var draft = ActionDraft(type: .modifyURL)
        draft.url.mode = .set
        draft.url.replacement = "https://b.test/x?y=1"
        draft.isFinal = true
        let result = build(draft)
        #expect(result.action == RuleAction(.modifyURL(URLEditAction(mode: .set, replacement: "https://b.test/x?y=1")), isFinal: true))
        #expect(result.issues.isEmpty && result.warnings.isEmpty)
    }

    @Test func modifyQueryBuildsFromTheRows() {
        var draft = ActionDraft(type: .modifyQuery)
        draft.queryRows = [QueryEditRow(method: .set, name: "a", value: "1")]
        #expect(build(draft).action == RuleAction(.modifyQuery(QueryEditAction(operations: [.set(name: "a", value: "1")]))))
    }

    @Test func editRequestHeadersBuildsAndCarriesFinal() {
        var draft = ActionDraft(type: .editRequestHeaders)
        draft.headerRows = [HeaderEditRow(method: .set, name: "X-A", value: "1")]
        draft.isFinal = true
        #expect(build(draft).action == RuleAction(.editHeaders(direction: .request, operations: [.set(name: "X-A", value: "1")]), isFinal: true))
    }

    @Test func editRequestCookiesBuilds() {
        var draft = ActionDraft(type: .editRequestCookies)
        draft.cookieRows = [CookieEditRow(method: .remove, name: "sid")]
        #expect(build(draft).action == RuleAction(.editCookies(direction: .request, operations: [.remove(name: "sid")])))
    }

    @Test func rewriteRequestBodyBuilds() {
        var draft = ActionDraft(type: .rewriteRequestBody)
        draft.body.find = "a"
        draft.body.replacement = "b"
        #expect(build(draft).action == RuleAction(.rewriteBody(direction: .request, BodyRewriteAction(find: "a", replacement: "b"))))
    }

    @Test func mapRemoteBuildsFromFields() {
        var draft = ActionDraft(type: .mapRemote)
        draft.remote.targetScheme = .http
        draft.remote.targetHost = " b.test "
        draft.remote.targetPort = "8080"
        draft.remote.pathChoice = .replace
        draft.remote.replacementPath = "/v2?x=1"
        draft.remote.preserveCredentials = true
        let expected = MapRemoteAction(
            targetScheme: "http", targetHost: "b.test", targetPort: 8080, path: .replace("/v2?x=1"), preserveCredentials: true)
        #expect(build(draft).action == RuleAction(.mapRemote(expected)))
    }

    @Test func mapRemoteErrorsLandOnTheirFields() {
        var draft = ActionDraft(type: .mapRemote)
        draft.remote.targetHost = ""
        draft.remote.targetPort = "x"
        draft.remote.pathChoice = .replace
        draft.remote.replacementPath = "no-slash"
        let result = build(draft)
        #expect(result.action == nil)
        #expect(result.issues[.targetHost] == .invalidTargetHost)
        #expect(result.issues[.targetPort] == .notANumber)
        #expect(result.issues[.targetPath] == .invalidTargetPath)
        draft.remote.targetPort = "70000"
        #expect(build(draft).issues[.targetPort] == .invalidTargetPort)
        draft.remote.targetPort = ""
        #expect(build(draft).issues[.targetPort] == .required)
    }

    @Test func requestBreakpointKeepsTheMode() {
        var draft = ActionDraft(type: .requestBreakpoint)
        draft.breakpointMode = .fullBody
        #expect(build(draft).action == RuleAction(.breakpoint(direction: .request, mode: .fullBody)))
        var response = ActionDraft(type: .responseBreakpoint)
        response.breakpointMode = .headers
        #expect(build(response).action == RuleAction(.breakpoint(direction: .response, mode: .headers)))
    }

    @Test func delayBuilds() {
        var draft = ActionDraft(type: .delay)
        draft.delayText = " 250 "
        #expect(build(draft).action == RuleAction(.delay(milliseconds: 250)))
        draft.delayText = "0"
        #expect(build(draft).action == RuleAction(.delay(milliseconds: 0)))
    }

    @Test func rewriteStatusBuilds() {
        var draft = ActionDraft(type: .rewriteStatus)
        draft.status = RewriteStatusDraft(status: "404", includeLocalResponses: true)
        #expect(build(draft).action == RuleAction(.rewriteStatus(RewriteStatusAction(status: 404, includeLocalResponses: true))))
    }

    @Test func editResponseHeadersAndCookiesBuild() {
        var headers = ActionDraft(type: .editResponseHeaders)
        headers.headerRows = [HeaderEditRow(method: .remove, name: "X-A")]
        #expect(build(headers).action == RuleAction(.editHeaders(direction: .response, operations: [.remove(name: "X-A")])))
        var cookies = ActionDraft(type: .editResponseCookies)
        cookies.cookieRows = [CookieEditRow(method: .set, name: "a", value: "1")]
        #expect(build(cookies).action == RuleAction(.editCookies(direction: .response, operations: [.set(name: "a", value: "1")])))
    }

    @Test func rewriteResponseBodyBuilds() {
        var draft = ActionDraft(type: .rewriteResponseBody)
        draft.body = BodyEditDraft(operation: .findReplace, syntax: .regex, find: "a+", replacement: "b", caseSensitive: false, scope: .first)
        let expected = BodyRewriteAction(find: "a+", replacement: "b", syntax: .regex, caseSensitive: false, scope: .first)
        #expect(build(draft).action == RuleAction(.rewriteBody(direction: .response, expected)))
    }

    // MARK: header rows

    @Test func headerRowsBuildEveryMethod() {
        var draft = ActionDraft(type: .editRequestHeaders)
        draft.headerRows = [
            HeaderEditRow(method: .set, name: "A", value: "1"),
            HeaderEditRow(method: .addIfMissing, name: "B", value: "2"),
            HeaderEditRow(method: .append, name: "C", value: "3"),
            HeaderEditRow(method: .appendToValue, name: "D", value: "-x"),
            HeaderEditRow(method: .findReplace, name: "E", value: "old", replacement: "new", caseSensitive: true),
            HeaderEditRow(method: .regex, name: "F", value: "o+", replacement: "0", caseSensitive: false),
            HeaderEditRow(method: .remove, name: "G"),
        ]
        let expected: [HeaderEdit] = [
            .set(name: "A", value: "1"), .addIfMissing(name: "B", value: "2"), .append(name: "C", value: "3"),
            .appendToValue(name: "D", text: "-x"), .findReplace(name: "E", find: "old", replacement: "new", caseSensitive: true),
            .regex(name: "F", pattern: "o+", replacement: "0", caseSensitive: false), .remove(name: "G"),
        ]
        let result = build(draft)
        #expect(result.action == RuleAction(.editHeaders(direction: .request, operations: expected)))
        #expect(HeaderMethod.allCases.count == 7)
        #expect(HeaderMethod.append.titleKey == "rules.headerMethod.append")
    }

    @Test func headerRowWithProtectedNameReportsOnThatRow() {
        var draft = ActionDraft(type: .editRequestHeaders)
        let good = HeaderEditRow(method: .set, name: "X-A", value: "1")
        let bad = HeaderEditRow(method: .set, name: "Host", value: "evil")
        draft.headerRows = [good, bad]
        let result = build(draft)
        #expect(result.action == nil)
        #expect(result.issues[.headerRow(bad.id)] == .headerProtected)
        #expect(result.issues[.headerRow(good.id)] == nil)
    }

    @Test func headerRegexMustCompileAndNeedsFind() {
        var draft = ActionDraft(type: .editResponseHeaders)
        let regex = HeaderEditRow(method: .regex, name: "A", value: "(", replacement: "")
        let empty = HeaderEditRow(method: .findReplace, name: "A", value: "", replacement: "x")
        draft.headerRows = [regex, empty]
        let result = build(draft)
        #expect(result.issues[.headerRow(regex.id)] == .invalidRegex)
        #expect(result.issues[.headerRow(empty.id)] == .emptyEditFind)
    }

    // MARK: query, cookie, URL

    @Test func queryRowAmpersandInNameIsRejected() {
        var draft = ActionDraft(type: .modifyQuery)
        let amp = QueryEditRow(method: .set, name: "a&b", value: "1")
        let eq = QueryEditRow(method: .add, name: "a=b", value: "1")
        let ok = QueryEditRow(method: .remove, name: "z")
        draft.queryRows = [amp, eq, ok]
        let result = build(draft)
        #expect(result.issues[.queryRow(amp.id)] == .invalidQueryEdit)
        #expect(result.issues[.queryRow(eq.id)] == .invalidQueryEdit)
        #expect(result.issues[.queryRow(ok.id)] == nil)
    }

    @Test func queryFindReplaceMayLeaveTheNameEmpty() {
        var draft = ActionDraft(type: .modifyQuery)
        draft.queryRows = [QueryEditRow(method: .findReplace, name: "", value: "a", replacement: "b", caseSensitive: true)]
        #expect(build(draft).action == RuleAction(.modifyQuery(QueryEditAction(operations: [.findReplace(name: nil, find: "a", replacement: "b", caseSensitive: true)]))))
    }

    @Test func cookieRegexMustCompile() {
        var draft = ActionDraft(type: .editRequestCookies)
        let bad = CookieEditRow(method: .regex, name: "", value: "[", replacement: "x")
        let good = CookieEditRow(method: .regex, name: "sid", value: "a+", replacement: "b", caseSensitive: true)
        draft.cookieRows = [bad, good]
        let result = build(draft)
        #expect(result.issues[.cookieRow(bad.id)] == .invalidRegex)
        #expect(result.issues[.cookieRow(good.id)] == nil)
        draft.cookieRows = [good]
        #expect(build(draft).action == RuleAction(.editCookies(direction: .request, operations: [.regex(name: "sid", pattern: "a+", replacement: "b", caseSensitive: true)])))
    }

    @Test func urlSetNeedsAbsoluteHTTPURL() {
        var draft = ActionDraft(type: .modifyURL)
        draft.url.mode = .set
        draft.url.replacement = "/relative"
        #expect(build(draft).issues[.urlReplacement] == .invalidURLEdit)
        draft.url.replacement = ""
        #expect(build(draft).issues[.urlReplacement] == .required)
        draft.url.mode = .findReplace
        draft.url.find = ""
        #expect(build(draft).issues[.urlFind] == .emptyEditFind)
        draft.url.mode = .regex
        draft.url.find = "("
        #expect(build(draft).issues[.urlFind] == .invalidRegex)
    }

    // MARK: body

    @Test func bodySetValueAllowsEmptyFind() {
        var draft = ActionDraft(type: .rewriteResponseBody)
        draft.body.operation = .setValue
        draft.body.find = ""
        draft.body.replacement = "ok"
        let expected = BodyRewriteAction(find: "", replacement: "ok", operation: .setValue)
        #expect(build(draft).action == RuleAction(.rewriteBody(direction: .response, expected)))
    }

    @Test func bodyFindReplaceNeedsFind() {
        var draft = ActionDraft(type: .rewriteRequestBody)
        draft.body.find = ""
        draft.body.replacement = "x"
        #expect(build(draft).issues[.bodyFind] == .emptyFind)
        draft.body.find = "("
        draft.body.syntax = .regex
        #expect(build(draft).issues[.bodyFind] == .invalidRegex)
    }

    @Test func bodyClearIgnoresOtherFields() {
        var draft = ActionDraft(type: .rewriteResponseBody)
        draft.body.operation = .clear
        draft.body.find = "("
        draft.body.syntax = .regex
        draft.body.replacement = String(repeating: "x", count: 100_000)
        let result = build(draft)
        #expect(result.issues.isEmpty)
        #expect(result.action == RuleAction(.rewriteBody(direction: .response, BodyRewriteAction(find: "", replacement: "", operation: .clear))))
    }

    // MARK: status, delay

    @Test func statusMustBe200to599() {
        var draft = ActionDraft(type: .rewriteStatus)
        draft.status.status = "199"
        #expect(build(draft).issues[.status] == .invalidStatus)
        draft.status.status = "600"
        #expect(build(draft).issues[.status] == .invalidStatus)
        draft.status.status = "abc"
        #expect(build(draft).issues[.status] == .notANumber)
        draft.status.status = ""
        #expect(build(draft).issues[.status] == .required)
        draft.status.status = "200"
        #expect(build(draft).issues.isEmpty)
        draft.status.status = "599"
        #expect(build(draft).issues.isEmpty)
    }

    @Test func delayAboveMaxIsRefused() {
        var draft = ActionDraft(type: .delay)
        draft.delayText = String(limits.delayMillisecondsMax + 1)
        #expect(build(draft).issues[.delay] == .invalidDelay)
        draft.delayText = "-1"
        #expect(build(draft).issues[.delay] == .invalidDelay)
        draft.delayText = String(limits.delayMillisecondsMax)
        #expect(build(draft).action == RuleAction(.delay(milliseconds: limits.delayMillisecondsMax)))
    }

    @Test func delayNotANumber() {
        var draft = ActionDraft(type: .delay)
        draft.delayText = "1.5"
        #expect(build(draft).issues[.delay] == .notANumber)
        draft.delayText = "  "
        #expect(build(draft).issues[.delay] == .required)
    }

    // MARK: round trip, type changes

    private static let stored: [RuleAction] = [
        RuleAction(.modifyURL(URLEditAction(mode: .set, replacement: "https://b.test/"))),
        RuleAction(.modifyURL(URLEditAction(mode: .regex, find: "a+", replacement: "b", caseSensitive: true, preserveCredentials: true))),
        RuleAction(.modifyQuery(QueryEditAction(operations: [
            .set(name: "a", value: "1"), .add(name: "b", value: "2"), .remove(name: "c"),
            .findReplace(name: nil, find: "x", replacement: "y", caseSensitive: true),
            .findReplace(name: "n", find: "x", replacement: "y", caseSensitive: false),
        ])), isFinal: true),
        RuleAction(.editHeaders(direction: .request, operations: [
            .set(name: "A", value: "1"), .addIfMissing(name: "B", value: "2"), .append(name: "C", value: "3"),
            .appendToValue(name: "D", text: "x"), .findReplace(name: "E", find: "a", replacement: "b", caseSensitive: true),
            .regex(name: "F", pattern: "a", replacement: "b", caseSensitive: false), .remove(name: "G"),
        ])),
        RuleAction(.editCookies(direction: .request, operations: [
            .set(name: "a", value: "1"), .addIfMissing(name: "b", value: "2"), .remove(name: "c"),
            .findReplace(name: nil, find: "x", replacement: "y", caseSensitive: true),
            .regex(name: "d", pattern: "x", replacement: "y", caseSensitive: false),
        ])),
        RuleAction(.rewriteBody(direction: .request, BodyRewriteAction(find: "a", replacement: "b", syntax: .regex, caseSensitive: false, scope: .first))),
        RuleAction(.rewriteBody(direction: .request, BodyRewriteAction(find: "", replacement: "v", operation: .setValue))),
        RuleAction(.mapRemote(MapRemoteAction(targetScheme: "https", targetHost: "b.test", targetPort: 443, path: .preserve))),
        RuleAction(.mapRemote(MapRemoteAction(targetScheme: "http", targetHost: "b.test", targetPort: 81, path: .replace("/p"), preserveCredentials: true)), isFinal: true),
        RuleAction(.breakpoint(direction: .request, mode: .fullBody)),
        RuleAction(.delay(milliseconds: 40)),
        RuleAction(.rewriteStatus(RewriteStatusAction(status: 503, includeLocalResponses: true))),
        RuleAction(.editHeaders(direction: .response, operations: [.remove(name: "X")])),
        RuleAction(.editCookies(direction: .response, operations: [.remove(name: "sid")])),
        RuleAction(.rewriteBody(direction: .response, BodyRewriteAction(find: "", replacement: "", operation: .clear))),
        RuleAction(.breakpoint(direction: .response, mode: .headers)),
    ]

    @Test func initFromActionRoundTripsEveryType() {
        var covered = Set<ActionType>()
        for action in Self.stored {
            let draft = ActionDraft(action: action)
            #expect(draft.isFinal == action.isFinal)
            #expect(build(draft).action == action, "\(action)")
            if let type = ActionType(action.kind) { covered.insert(type) }
        }
        let thirteen: Set<ActionType> = [
            .modifyURL, .modifyQuery, .editRequestHeaders, .editRequestCookies, .rewriteRequestBody, .mapRemote,
            .requestBreakpoint, .delay, .rewriteStatus, .editResponseHeaders, .editResponseCookies, .rewriteResponseBody,
            .responseBreakpoint,
        ]
        #expect(covered == thirteen)
    }

    @Test func changingActionTypeKeepsFinalFlag() {
        var draft = ActionDraft(type: .delay)
        draft.isFinal = true
        draft.setType(.rewriteStatus)
        #expect(draft.type == .rewriteStatus)
        #expect(draft.isFinal)
        draft.setType(.modifyURL)
        #expect(draft.isFinal)
    }

    @Test func changingRequestHeadersToResponseHeadersKeepsTheRows() {
        var draft = ActionDraft(type: .editRequestHeaders)
        draft.headerRows = [HeaderEditRow(method: .appendToValue, name: "A", value: "x")]
        let rows = draft.headerRows
        draft.setType(.editResponseHeaders)
        #expect(draft.headerRows == rows)
        #expect(build(draft).action == RuleAction(.editHeaders(direction: .response, operations: [.appendToValue(name: "A", text: "x")])))
        draft.setType(.editRequestHeaders)
        #expect(draft.headerRows == rows)
    }

    @Test func changingBetweenBodyDirectionsKeepsTheBodyForm() {
        var draft = ActionDraft(type: .rewriteRequestBody)
        draft.body.find = "a"
        draft.body.replacement = "b"
        draft.setType(.rewriteResponseBody)
        #expect(build(draft).action == RuleAction(.rewriteBody(direction: .response, BodyRewriteAction(find: "a", replacement: "b"))))
    }

    @Test func allIssuesAreNilWhenValid() {
        for action in Self.stored {
            let result = build(ActionDraft(action: action))
            #expect(result.issues.isEmpty)
            #expect(result.action != nil)
        }
    }

    @Test func aFreshDraftOfEachTypeNamesWhatIsMissing() {
        for type in [ActionType.modifyURL, .rewriteRequestBody, .mapRemote, .delay, .rewriteStatus, .magicString] {
            let result = build(ActionDraft(type: type))
            #expect(result.action == nil && !result.issues.isEmpty, "\(type)")
        }
        #expect(build(ActionDraft(type: .requestBreakpoint)).action != nil)
        // An empty key means every key now, so a fresh edit card is a valid "set every field" edit; creating a field needs a name.
        for type in [ActionType.modifyQuery, .editRequestHeaders, .editRequestCookies] {
            var draft = ActionDraft(type: type)
            #expect(build(draft).action != nil, "\(type)")
            draft.setMode("addIfMissing")
            let result = build(draft)
            #expect(result.action == nil && !result.issues.isEmpty, "\(type)")
        }
    }

    @Test func aListWithNoRowsIsReportedOnTheDraft() {
        var draft = ActionDraft(type: .modifyQuery)
        draft.queryRows = []
        #expect(build(draft).issues[.queryRow(draft.id)] == .invalidQueryEdit)
        var headers = ActionDraft(type: .editRequestHeaders)
        headers.headerRows = []
        #expect(build(headers).issues[.headerRow(headers.id)] == .required)
    }

    // MARK: Task 8: return, connection and record actions

    private func asset(_ id: UUID = UUID()) -> ManagedAsset { ManagedAsset(id: id, size: 3, displayName: "a.txt", importedAt: .distantPast) }

    @Test func returnFileNeedsAnAsset() {
        let draft = ActionDraft(type: .returnFile)
        let result = build(draft)
        #expect(result.action == nil)
        #expect(result.issues[.file] == .assetRequired)
    }

    @Test func returnFileBuildsFromAssetStatusAndHeaders() {
        let id = UUID()
        var draft = ActionDraft(type: .returnFile)
        draft.file.asset = asset(id)
        draft.file.status = "201"
        draft.file.headers = [HeaderFieldRow(name: "X-A", value: "1"), HeaderFieldRow(name: "X-A", value: "2")]
        let expected = MapLocalAction(assetID: id, status: 201, headers: [HeaderField(name: "X-A", value: "1"), HeaderField(name: "X-A", value: "2")])
        #expect(build(draft).action == RuleAction(.returnFile(expected)))
    }

    @Test func returnFileStatusRange() {
        var draft = ActionDraft(type: .returnFile)
        draft.file.asset = asset()
        draft.file.status = "199"
        #expect(build(draft).issues[.status] == .invalidStatus)
        draft.file.status = "600"
        #expect(build(draft).issues[.status] == .invalidStatus)
        draft.file.status = "x"
        #expect(build(draft).issues[.status] == .notANumber)
        draft.file.status = ""
        #expect(build(draft).issues[.status] == .required)
        draft.file.status = "200"
        #expect(build(draft).issues.isEmpty)
    }

    @Test func returnFileHeaderProblemLandsOnItsRow() {
        var draft = ActionDraft(type: .returnFile)
        draft.file.asset = asset()
        let bad = HeaderFieldRow(name: "Bad Name", value: "1")
        draft.file.headers = [HeaderFieldRow(name: "X-A", value: "1"), bad]
        let result = build(draft)
        #expect(result.action == nil)
        #expect(result.issues[.headerRow(bad.id)] != nil)
        #expect(result.issues.count == 1)
    }

    @Test func returnDirectoryNeedsBookmarkAndPrefix() {
        var draft = ActionDraft(type: .returnDirectory)
        draft.directoryPrefix = "assets"
        var result = build(draft)
        #expect(result.issues[.directory] == .directoryRequired)
        #expect(result.issues[.directoryPrefix] == .directoryNeedsPrefix)
        draft.directory.bookmark = Data([1, 2, 3])
        draft.directoryPrefix = "/assets"
        result = build(draft)
        #expect(result.issues[.directory] == nil)
        #expect(result.issues[.directoryPrefix] == .directoryNeedsPrefix)
        draft.directoryPrefix = "/assets/"
        draft.directory.displayName = "www"
        draft.directory.servesIndex = false
        draft.directory.missing = .network
        draft.directory.headers = [HeaderFieldRow(name: "X-D", value: "1")]
        let expected = MapLocalDirectoryAction(
            bookmark: Data([1, 2, 3]), displayName: "www", servesIndex: false, missing: .network,
            headers: [HeaderField(name: "X-D", value: "1")])
        #expect(build(draft).action == RuleAction(.returnDirectory(expected, pathPrefix: "/assets/")))
        draft.directoryPrefix = "/"
        #expect(build(draft).issues.isEmpty)
    }

    @Test func returnDirectoryBadHeaderLandsOnItsRow() {
        var draft = ActionDraft(type: .returnDirectory)
        draft.directory.bookmark = Data([1])
        let bad = HeaderFieldRow(name: "Bad Name", value: "1")
        draft.directory.headers = [bad]
        #expect(build(draft).issues[.headerRow(bad.id)] != nil)
    }

    @Test func handwrittenBuildsTheDefaultTemplateWithoutWarnings() {
        let draft = ActionDraft(type: .returnHandwritten)
        let result = build(draft)
        #expect(result.action == RuleAction(.returnHandwritten(HandwrittenResponse(text: "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n"))))
        #expect(result.warnings.isEmpty)
    }

    @Test func handwrittenParsesAndReportsFieldError() {
        var draft = ActionDraft(type: .returnHandwritten)
        draft.handwrittenText = "this is not http"
        let result = build(draft)
        #expect(result.action == nil)
        #expect(result.issues[.handwritten] == .invalidHandwrittenResponse)
        draft.handwrittenText = ""
        #expect(build(draft).issues[.handwritten] == .invalidHandwrittenResponse)
    }

    @Test func handwrittenLengthCorrectionIsAWarningNotAnError() {
        var draft = ActionDraft(type: .returnHandwritten)
        draft.handwrittenText = "HTTP/1.1 200 OK\r\nContent-Length: 99\r\n\r\nhi"
        let result = build(draft)
        #expect(result.action != nil && result.issues.isEmpty)
        #expect(result.warnings == [.contentLengthCorrected])
        draft.handwrittenText = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi"
        #expect(build(draft).warnings.isEmpty)
    }

    @Test func handwrittenTooLarge() {
        var draft = ActionDraft(type: .returnHandwritten)
        draft.handwrittenText = "HTTP/1.1 200 OK\r\n\r\n" + String(repeating: "a", count: 200)
        var small = RulesLimits()
        small.handwrittenResponseBytes = 64
        let result = draft.build(limits: small)
        #expect(result.action == nil)
        #expect(result.issues[.handwritten] == .handwrittenResponseTooLarge)
    }

    @Test func presetRedirectNeedsLocation() {
        var draft = ActionDraft(type: .returnPreset)
        draft.preset = .found302
        // A redirect starts at the reference's default address (R8F2-7).
        #expect(
            build(draft).action
                == RuleAction(.returnPreset(PresetResponse(preset: .found302, location: "http://www.example.com/"))))
        draft.presetLocation = ""
        let result = build(draft)
        #expect(result.action == nil)
        #expect(result.issues[.presetLocation] == .presetNeedsLocation)
        draft.presetLocation = "   "
        #expect(build(draft).issues[.presetLocation] == .presetNeedsLocation)
        draft.presetLocation = "https://b.test/x"
        #expect(build(draft).action == RuleAction(.returnPreset(PresetResponse(preset: .found302, location: "https://b.test/x"))))
    }

    @Test func presetBuildsEveryPreset() {
        #expect(PresetResponse.Preset.allCases.count == 20)
        for preset in PresetResponse.Preset.allCases {
            var draft = ActionDraft(type: .returnPreset)
            draft.preset = preset
            let needsLocation = PresetResponse(preset: preset).requiresLocation
            if needsLocation { draft.presetLocation = "/next" }
            let result = build(draft)
            #expect(result.issues.isEmpty, "\(preset)")
            #expect(result.action == RuleAction(.returnPreset(PresetResponse(preset: preset, location: needsLocation ? "/next" : nil))), "\(preset)")
        }
    }

    @Test func presetIgnoresFieldsTheChosenPresetDoesNotTake() {
        var draft = ActionDraft(type: .returnPreset)
        draft.preset = .notFound404
        draft.presetLocation = "/stale"
        draft.presetChallenge = "Bearer"
        draft.presetBody = "gone"
        #expect(build(draft).action == RuleAction(.returnPreset(PresetResponse(preset: .notFound404, body: "gone"))))
        draft.preset = .noContent204
        #expect(build(draft).action == RuleAction(.returnPreset(PresetResponse(preset: .noContent204))))
    }

    @Test func preset401KeepsDefaultChallengeWhenEmpty() {
        var draft = ActionDraft(type: .returnPreset)
        draft.preset = .unauthorized401
        #expect(build(draft).action == RuleAction(.returnPreset(PresetResponse(preset: .unauthorized401))))
        draft.presetChallenge = #"Bearer realm="x""#
        draft.presetBody = "no"
        #expect(build(draft).action == RuleAction(.returnPreset(PresetResponse(preset: .unauthorized401, body: "no", challenge: #"Bearer realm="x""#))))
        draft.presetChallenge = "bad\nvalue"
        #expect(build(draft).issues[.presetChallenge] == .invalidPresetField)
    }

    @Test func presetBodyTooLargeLandsOnTheBody() {
        var draft = ActionDraft(type: .returnPreset)
        draft.presetBody = String(repeating: "a", count: 100)
        var small = RulesLimits()
        small.handwrittenResponseBytes = 64
        #expect(draft.build(limits: small).issues[.presetBody] == .handwrittenResponseTooLarge)
    }

    @Test func closeModesMapToGracefulAndReset() {
        #expect(build(ActionDraft(type: .closeConnectionGraceful)).action == RuleAction(.closeConnection(.graceful)))
        #expect(build(ActionDraft(type: .closeConnectionReset)).action == RuleAction(.closeConnection(.reset)))
    }

    @Test func connectOnlyTypesBuildWithoutParameters() {
        for (type, kind) in [(ActionType.returnConnectTunnel, ActionKind.returnConnectTunnel), (.noDecrypt, .noDecrypt)] {
            let result = build(ActionDraft(type: type))
            #expect(result.action == RuleAction(kind))
            #expect(result.issues.isEmpty && result.warnings.isEmpty)
        }
    }

    @Test func hideCarriesTheWarning() {
        var draft = ActionDraft(type: .hide)
        draft.isFinal = true
        let result = build(draft)
        #expect(result.action == RuleAction(.hide, isFinal: true))
        #expect(result.warnings == [.hideCutsLowerRules])
    }

    @Test func markBuildsColorAndText() {
        var draft = ActionDraft(type: .mark)
        draft.mark = MarkDraft(background: " #ff0000 ", foreground: "00ff00", text: "slow")
        #expect(build(draft).action == RuleAction(.mark(MarkAction(background: "#FF0000", foreground: "#00FF00", text: "slow"))))
        draft.mark = MarkDraft(background: "#112233", foreground: "", text: "")
        #expect(build(draft).action == RuleAction(.mark(MarkAction(background: "#112233"))))
    }

    @Test func markInvalidColorIsAFieldIssue() {
        var draft = ActionDraft(type: .mark)
        draft.mark = MarkDraft(background: "red", foreground: "blue", text: String(repeating: "x", count: 5_000))
        let result = build(draft)
        #expect(result.action == nil)
        #expect(result.issues[.markColor] == .invalidMarkColor)
        #expect(result.issues[.markForeground] == .invalidMarkColor)
        #expect(result.issues[.markText] == .markTextTooLong)
    }

    @Test func commentModes() {
        var draft = ActionDraft(type: .comment)
        draft.comment = CommentDraft(mode: .set, text: "a", replacement: "ignored")
        #expect(build(draft).action == RuleAction(.comment(CommentAction(mode: .set, text: "a"))))
        draft.comment = CommentDraft(mode: .append, text: "b")
        #expect(build(draft).action == RuleAction(.comment(CommentAction(mode: .append, text: "b"))))
        draft.comment = CommentDraft(mode: .findReplace, text: "c", replacement: "d", caseSensitive: true)
        #expect(build(draft).action == RuleAction(.comment(CommentAction(mode: .findReplace, text: "c", replacement: "d"))))
        draft.comment = CommentDraft(mode: .regex, text: "c(.)", replacement: "$1")
        #expect(
            build(draft).action
                == RuleAction(.comment(CommentAction(mode: .regex, text: "c(.)", replacement: "$1", caseSensitive: false))))
        draft.comment = CommentDraft(mode: .addIfMissing, text: "first")
        #expect(build(draft).action == RuleAction(.comment(CommentAction(mode: .addIfMissing, text: "first"))))
        draft.comment = CommentDraft(mode: .clear, text: "left over")
        #expect(build(draft).action == RuleAction(.comment(CommentAction(mode: .clear))))
    }

    @Test func commentFieldIssues() {
        var draft = ActionDraft(type: .comment)
        draft.comment = CommentDraft(mode: .set, text: "")
        #expect(build(draft).issues[.commentText] == .commentRequired)
        draft.comment = CommentDraft(mode: .findReplace, text: "")
        #expect(build(draft).issues[.commentFind] == .commentFindRequired)
        draft.comment = CommentDraft(mode: .findReplace, text: "a", replacement: String(repeating: "x", count: 5_000))
        #expect(build(draft).issues[.commentReplacement] == .commentTooLong)
    }

    private static let storedR8: [RuleAction] = [
        RuleAction(.returnFile(MapLocalAction(assetID: UUID(), status: 404, headers: [HeaderField(name: "X", value: "1")])), isFinal: true),
        RuleAction(.returnDirectory(
            MapLocalDirectoryAction(bookmark: Data([9, 9]), displayName: "site", servesIndex: false, missing: .network, headers: [HeaderField(name: "X", value: "1")]),
            pathPrefix: "/static/")),
        RuleAction(.returnHandwritten(HandwrittenResponse(text: "HTTP/1.1 204 No Content\r\n\r\n"))),
        RuleAction(.returnPreset(PresetResponse(preset: .temporaryRedirect307, location: "/x"))),
        RuleAction(.returnPreset(PresetResponse(preset: .proxyAuthRequired407, body: "b", challenge: "Basic"))),
        RuleAction(.returnPreset(PresetResponse(preset: .gif200))),
        RuleAction(.closeConnection(.graceful)),
        RuleAction(.closeConnection(.reset)),
        RuleAction(.returnConnectTunnel),
        RuleAction(.noDecrypt),
        RuleAction(.hide),
        RuleAction(.mark(MarkAction(background: "#AABBCC", foreground: "#000000", text: "t"))),
        RuleAction(.mark(MarkAction(background: "#AABBCC"))),
        RuleAction(.comment(CommentAction(mode: .set, text: "a"))),
        RuleAction(.comment(CommentAction(mode: .append, text: "a"))),
        RuleAction(.comment(CommentAction(mode: .findReplace, text: "a", replacement: "b"))),
        RuleAction(.comment(CommentAction(mode: .clear))),
    ]

    @Test func initFromActionRoundTripsEveryRemainingType() {
        for action in Self.storedR8 {
            let draft = ActionDraft(action: action)
            #expect(draft.type == ActionType(action.kind), "\(action.kind)")
            #expect(draft.build(limits: limits).action == action, "\(action.kind)")
        }
        let covered = Set(Self.storedR8.compactMap { ActionType($0.kind) })
        #expect(covered.isSuperset(of: [.returnFile, .returnDirectory, .returnHandwritten, .returnPreset, .closeConnectionGraceful, .closeConnectionReset, .returnConnectTunnel, .noDecrypt, .hide, .mark, .comment]))
    }

    @Test func everyActionTypeIsBuiltByTheDraft() {
        // No type is left on a placeholder: a fresh draft either builds or names what is missing.
        for type in ActionType.allCases {
            let result = build(ActionDraft(type: type))
            #expect(result.action != nil || !result.issues.isEmpty, "\(type)")
        }
    }

    @Test func referencedAssetIDsOfAFileAction() {
        let id = UUID()
        let draft = ActionDraft(action: RuleAction(.returnFile(MapLocalAction(assetID: id, headers: []))))
        #expect(draft.referencedAssetIDs() == [id])
        #expect(ActionDraft(type: .returnFile).referencedAssetIDs().isEmpty)
        var other = draft
        other.setType(.hide)
        #expect(other.referencedAssetIDs().isEmpty)
        #expect(ActionDraft(action: RuleAction(.hide)).referencedAssetIDs().isEmpty)
    }

    @Test func opaqueGuardKeepsAnUnknownAction() {
        let odd = RuleAction(.returnFile(MapLocalAction(assetID: UUID(), status: 418, headers: [])), isFinal: true)
        let draft = ActionDraft(action: odd, typeOf: { _ in nil })
        #expect(draft.isOpaque)
        #expect(draft.isFinal)
        let result = draft.build(limits: limits)
        #expect(result.action == odd && result.issues.isEmpty)
        #expect(draft.referencedAssetIDs().count == 1)
        var changed = draft
        changed.setType(.hide)
        #expect(!changed.isOpaque)
        #expect(changed.build(limits: limits).action == RuleAction(.hide, isFinal: true))
    }

    @Test func presetTitlesExistForEveryPreset() {
        for preset in PresetResponse.Preset.allCases {
            #expect(preset.titleKey == "rules.preset.\(preset.rawValue)")
        }
    }
}
