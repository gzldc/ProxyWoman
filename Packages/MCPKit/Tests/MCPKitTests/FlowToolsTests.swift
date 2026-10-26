import FlowStore
import Foundation
import MCPWire
import Testing

@testable import MCPKit

/// Shared with the end-to-end tests.
struct StubStatus: MCPStatusSource {
    var value: MCPAppStatus
    func status() async -> MCPAppStatus { value }
}

private let reference = Date(timeIntervalSince1970: 1_800_000_000)

private final class StoreFixture {
    let directory: URL
    let store: FlowStore

    init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("flowtools-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = FlowStore(bodyDirectory: directory)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    @discardableResult
    func add(
        method: String = "GET", host: String = "example.com", path: String = "/", status: Int? = 200,
        age: TimeInterval = 0, state: FlowState = .completed, requestBody: Data? = nil, responseBody: Data? = nil,
        contentType: String? = nil, edit: (inout Flow) -> Void = { _ in }
    ) -> Int {
        let id = store.begin {
            Flow(
                id: $0, startedAt: reference.addingTimeInterval(-age), scheme: "https", method: method, host: host,
                port: 443, path: path)
        }
        store.update(id) { flow in
            flow.statusCode = status
            flow.state = state
            flow.completedAt = flow.startedAt.addingTimeInterval(0.25)
            if let contentType { flow.responseHeaders = [HeaderField(name: "Content-Type", value: contentType)] }
            // Bodies are text unless a test says otherwise (redaction hides bodies without a text type).
            if let requestBody {
                flow.requestBody = store.makeManagedBody(requestBody)
                flow.bytesSent = requestBody.count
                flow.requestHeaders = [HeaderField(name: "Content-Type", value: "text/plain")]
            }
            if let responseBody {
                flow.responseBody = store.makeManagedBody(responseBody)
                flow.bytesReceived = responseBody.count
                if contentType == nil { flow.responseHeaders = [HeaderField(name: "Content-Type", value: "text/plain")] }
            }
            edit(&flow)
        }
        return id
    }
}

private func context(_ settings: MCPSettings = enabledSettings()) -> MCPToolContext {
    MCPToolContext(settings: settings, redactor: MCPRedactor(settings.redaction), now: reference)
}

private func ids(_ result: JSONValue) -> [Int] {
    (result["flows"]?.arrayValue ?? []).compactMap { $0["id"]?.intValue }
}

private func text(_ value: JSONValue) -> String {
    (try? value.encoded()).flatMap { String(data: $0, encoding: .utf8) } ?? ""
}

@Suite struct FlowToolsTests {
    @Test func listFlowsFiltersByHostMethodStatusTimeText() async throws {
        let fixture = StoreFixture()
        let a = fixture.add(method: "GET", host: "api.example.com", path: "/users", status: 200, age: 3600)
        let b = fixture.add(method: "POST", host: "api.example.com", path: "/users", status: 404, age: 600)
        let c = fixture.add(method: "GET", host: "cdn.other.net", path: "/logo.png", status: 500, age: 60)
        let tool = ListFlowsTool(store: fixture.store)

        func run(_ arguments: [String: JSONValue]) async throws -> [Int] {
            ids(try await tool.call(arguments, context: context()))
        }
        #expect(try await run([:]) == [c, b, a])
        #expect(try await run(["host": .string("EXAMPLE")]) == [b, a])
        #expect(try await run(["method": .string("post")]) == [b])
        #expect(try await run(["status": .string("4xx")]) == [b])
        #expect(try await run(["status": .string("404")]) == [b])
        #expect(try await run(["status": .string("400-599")]) == [c, b])
        #expect(try await run(["since": .string("30m")]) == [c, b])
        #expect(try await run(["until": .string("30m")]) == [a])
        #expect(try await run(["since": .string("2h"), "until": .string("30m")]) == [a])
        #expect(try await run(["text": .string("LOGO")]) == [c])
        #expect(try await run(["host": .string("example"), "method": .string("GET")]) == [a])
        #expect(try await run(["host": .string("nomatch")]) == [])
    }

    @Test func listFlowsReturnsTheSummaryFields() async throws {
        let fixture = StoreFixture()
        let id = fixture.add(
            method: "GET", host: "example.com", path: "/p?q=1", status: 201, age: 10,
            requestBody: Data("abc".utf8), responseBody: Data("hello".utf8), contentType: "application/json")
        let result = try await ListFlowsTool(store: fixture.store).call([:], context: context())
        let flow = try #require(result["flows"]?.arrayValue?.first)
        #expect(flow["id"]?.intValue == id)
        #expect(flow["method"]?.stringValue == "GET")
        #expect(flow["url"]?.stringValue == "https://example.com/p?q=1")
        #expect(flow["host"]?.stringValue == "example.com")
        #expect(flow["status"]?.intValue == 201)
        #expect(flow["state"]?.stringValue == "completed")
        #expect(flow["durationMs"]?.intValue == 250)
        #expect(flow["requestBytes"]?.intValue == 3)
        #expect(flow["responseBytes"]?.intValue == 5)
        #expect(flow["contentType"]?.stringValue == "application/json")
        #expect(flow["tags"]?.arrayValue == [])
        #expect(flow["startedAt"]?.stringValue == "2027-01-15T07:59:50.000Z")
        #expect(result["nextBeforeId"] == .null)
    }

    @Test func listFlowsIsNewestFirstWithBeforeIDPaging() async throws {
        let fixture = StoreFixture()
        let all = (0..<7).map { fixture.add(path: "/\($0)", age: Double(100 - $0)) }
        let tool = ListFlowsTool(store: fixture.store)

        var collected: [Int] = []
        var before: JSONValue = .null
        var pages = 0
        while true {
            var arguments: [String: JSONValue] = ["limit": .int(3)]
            if before != .null { arguments["before_id"] = before }
            let page = try await tool.call(arguments, context: context())
            collected += ids(page)
            pages += 1
            before = page["nextBeforeId"] ?? .null
            if before == .null { break }
            #expect(pages < 10)
        }
        #expect(pages == 3)
        #expect(collected == all.reversed())
        #expect(Set(collected).count == collected.count)

        // A page that exactly exhausts the matches has no next page.
        let exact = try await tool.call(["limit": .int(7)], context: context())
        #expect(exact["nextBeforeId"] == .null)
        #expect(ids(exact).count == 7)
    }

    @Test func listFlowsRedactsQueryTokensInURL() async throws {
        let fixture = StoreFixture()
        fixture.add(path: "/cb?access_token=SECRETVALUE1&page=2")
        let result = try await ListFlowsTool(store: fixture.store).call([:], context: context())
        let output = text(result)
        #expect(!output.contains("SECRETVALUE1"))
        #expect(output.contains("page=2"))
        #expect(output.contains(MCPRedactor.redactedValue))
    }

    @Test func listFlowsWithRedactionOffShowsToken() async throws {
        let fixture = StoreFixture()
        fixture.add(path: "/cb?access_token=SECRETVALUE1")
        var settings = enabledSettings()
        settings.redaction.enabled = false
        let result = try await ListFlowsTool(store: fixture.store).call([:], context: context(settings))
        #expect(text(result).contains("access_token=SECRETVALUE1"))
    }

    @Test func listFlowsPagesAcrossTheByteBudgetWithoutGapsOrDuplicates() async throws {
        let fixture = StoreFixture()
        // 150 flows of ~2.3 KB each is well over the 192 KiB page budget.
        let all = (0..<150).map { index in
            fixture.add(path: "/" + String(repeating: "a", count: 5000) + "\(index)")
        }
        let tool = ListFlowsTool(store: fixture.store)
        let first = try await tool.call(["limit": .int(200)], context: context())
        #expect(ids(first).count < 150)
        #expect(ids(first).count > 10)
        #expect(first["nextBeforeId"]?.intValue == ids(first).last)
        #expect(try first.encoded().count < MCPToolRunner.maxResultBytes)
        let url = try #require(first["flows"]?.arrayValue?.first?["url"]?.stringValue)
        #expect(url.count == MCPFlowSummary.maxURLLength + 3)

        var collected: [Int] = []
        var before: JSONValue = .null
        for _ in 0..<50 {
            var arguments: [String: JSONValue] = ["limit": .int(200)]
            if before != .null { arguments["before_id"] = before }
            let page = try await tool.call(arguments, context: context())
            #expect(try page.encoded().count < MCPToolRunner.maxResultBytes)
            collected += ids(page)
            before = page["nextBeforeId"] ?? .null
            if before == .null { break }
        }
        #expect(collected == all.reversed())
    }

    @Test func emittedMethodAndHostAreCapped() async throws {
        let fixture = StoreFixture()
        fixture.add(method: String(repeating: "M", count: 400), host: String(repeating: "h", count: 400))
        let result = try await ListFlowsTool(store: fixture.store).call([:], context: context())
        let flow = try #require(result["flows"]?.arrayValue?.first)
        #expect(flow["method"]?.stringValue?.count == 256)
        #expect(flow["host"]?.stringValue?.count == 256)
    }

    @Test func contentTypeKeepsOnlyTypeAndCharset() async throws {
        let fixture = StoreFixture()
        fixture.add(contentType: "Application/JSON; token=CTSECRET; charset=\"UTF-8\"; boundary=BSECRET")
        let result = try await ListFlowsTool(store: fixture.store).call([:], context: context())
        let output = text(result)
        #expect(!output.contains("CTSECRET"))
        #expect(!output.contains("BSECRET"))
        #expect(result["flows"]?.arrayValue?.first?["contentType"]?.stringValue == "Application/JSON; charset=UTF-8")
    }

    @Test func contentTypeWithoutATypeSlashSubtypeIsNull() async throws {
        let fixture = StoreFixture()
        for value in ["token=SECRET", "SECRET", "/json", "text/", "a/b/c; x=1", ";charset=utf-8", ""] {
            fixture.add(contentType: value)
        }
        let result = try await ListFlowsTool(store: fixture.store).call(["limit": .int(200)], context: context())
        #expect(!text(result).contains("SECRET"))
        for flow in result["flows"]?.arrayValue ?? [] { #expect(flow["contentType"] == .null) }
    }

    @Test func fragmentTokensInURLsAreRedacted() async throws {
        let fixture = StoreFixture()
        fixture.add(path: "/cb?x=1#access_token=FRAGSECRET&state=ok")
        let result = try await ListFlowsTool(store: fixture.store).call([:], context: context())
        let output = text(result)
        #expect(!output.contains("FRAGSECRET"))
        #expect(output.contains("state=ok"))
    }

    // MARK: Redaction is not an oracle

    @Test func textAndHostFiltersDoNotMatchRedactedURLValues() async throws {
        let fixture = StoreFixture()
        let id = fixture.add(host: "api.example.com", path: "/cb?access_token=SECRETVALUE&page=2")
        let tool = ListFlowsTool(store: fixture.store)
        func run(_ arguments: [String: JSONValue], redaction: Bool) async throws -> [Int] {
            var settings = enabledSettings()
            settings.redaction.enabled = redaction
            return ids(try await tool.call(arguments, context: context(settings)))
        }
        // Redaction on: a secret value, or a prefix of it, finds nothing; public parts still match.
        #expect(try await run(["text": .string("SECRETVALUE")], redaction: true) == [])
        #expect(try await run(["text": .string("secretv")], redaction: true) == [])
        #expect(try await run(["text": .string("access_token=S")], redaction: true) == [])
        #expect(try await run(["text": .string("page=2")], redaction: true) == [id])
        #expect(try await run(["text": .string("api.example")], redaction: true) == [id])
        #expect(try await run(["host": .string("EXAMPLE.com")], redaction: true) == [id])
        #expect(try await run(["text": .string("GET")], redaction: true) == [id])
        // Redaction off: raw matching, as the main window does.
        #expect(try await run(["text": .string("SECRETVALUE")], redaction: false) == [id])
        #expect(try await run(["text": .string("access_token=S")], redaction: false) == [id])
    }

    @Test func searchBodyContainsMatchesRedactedTextWhenRedactionIsOn() async throws {
        let fixture = StoreFixture()
        let json = Data("{\"access_token\":\"SECRETVAL\",\"name\":\"publicname\"}".utf8)
        let id = fixture.add(
            requestBody: json, responseBody: json,
            edit: {
                $0.requestHeaders = [HeaderField(name: "Content-Type", value: "application/json")]
                $0.responseHeaders = [HeaderField(name: "Content-Type", value: "application/json")]
            })
        let tool = SearchFlowsTool(store: fixture.store)
        func run(_ needle: String, redaction: Bool, where side: String = "both") async throws -> [Int] {
            var settings = enabledSettings()
            settings.redaction.enabled = redaction
            let result = try await tool.call(
                ["body_contains": .string(needle), "where": .string(side)], context: context(settings))
            return ids(result)
        }
        for side in ["both", "request", "response"] {
            #expect(try await run("SECRETVAL", redaction: true, where: side) == [])
            #expect(try await run("SECR", redaction: true, where: side) == [])
            #expect(try await run("publicname", redaction: true, where: side) == [id])
            #expect(try await run("SECRETVAL", redaction: false, where: side) == [id])
            #expect(try await run("publicname", redaction: false, where: side) == [id])
        }
        // The redaction marker itself is searchable (it is what the client would see elsewhere).
        #expect(try await run(MCPRedactor.redactedValue, redaction: true) == [id])
    }

    @Test func searchNeverMatchesTokensInsideUrlsInBodies() async throws {
        let fixture = StoreFixture()
        let id = fixture.add(
            requestBody: Data(#"{"next":"https://api/x?access_token=URLSECRET&page=2"}"#.utf8),
            responseBody: Data(#"<a href="/cb?code=HTMLSECRET">go</a> plain https://h/o?sig=TEXTSECRET"#.utf8),
            edit: {
                $0.requestHeaders = [HeaderField(name: "Content-Type", value: "application/json")]
                $0.responseHeaders = [HeaderField(name: "Content-Type", value: "text/html")]
            })
        let tool = SearchFlowsTool(store: fixture.store)
        func run(_ needle: String, redaction: Bool) async throws -> [Int] {
            var settings = enabledSettings()
            settings.redaction.enabled = redaction
            return ids(try await tool.call(["body_contains": .string(needle)], context: context(settings)))
        }
        for secret in ["URLSECRET", "HTMLSECRET", "TEXTSECRET"] {
            #expect(try await run(secret, redaction: true) == [], "\(secret)")
            #expect(try await run(secret, redaction: false) == [id], "\(secret)")
        }
        #expect(try await run("page=2", redaction: true) == [id])
    }

    @Test func searchDescriptionExplainsRedactedMatching() {
        let fixture = StoreFixture()
        let description = SearchFlowsTool(store: fixture.store).definition.description
        #expect(description.contains("redaction"))
        let schema = SearchFlowsTool(store: fixture.store).definition.inputSchema["properties"]?["body_contains"]
        #expect(schema?["maxLength"] == nil)
        #expect(schema?["description"]?.stringValue?.contains("bytes") == true)
    }

    @Test func searchNeverMatchesBodiesThatGetFlowWouldHideWhenRedactionIsOn() async throws {
        let fixture = StoreFixture()
        let secret = "SECRETNEEDLE"
        let plain = Data("prefix \(secret) suffix".utf8)
        func gzipLike() -> Data { Data([0x1f, 0x8b, 0x08, 0x00]) + plain }
        // Decodable UTF-16 is shown by get_flow (redacted), so the secret sits under a sensitive key.
        let utf16 = String("{\"access_token\":\"\(secret)\"}").data(using: .utf16LittleEndian)!
        let big = Data("\(secret)".utf8) + Data(repeating: UInt8(ascii: "a"), count: 1_048_576)
        func body(_ contentType: String?, _ data: Data, extra: [HeaderField] = []) -> Int {
            fixture.add(responseBody: data) { flow in
                flow.responseHeaders = extra + (contentType.map { [HeaderField(name: "Content-Type", value: $0)] } ?? [])
            }
        }
        let hidden: [String: Int] = [
            "octet-stream": body("application/octet-stream", plain),
            "no content type": body(nil, plain),
            "gzip": body("text/plain", gzipLike(), extra: [HeaderField(name: "Content-Encoding", value: "gzip")]),
            "over 1 MiB": body("text/plain", big),
            "utf-16": body("text/plain; charset=utf-16le", utf16),
            "multipart": body("multipart/form-data; boundary=zz", plain),
            "image": body("image/png", plain),
        ]
        let visible = body("text/plain; charset=utf-8", plain)
        let publicOnly = body("text/plain", Data("only public text".utf8))
        let tool = SearchFlowsTool(store: fixture.store)
        func found(_ needle: String, redaction: Bool) async throws -> Set<Int> {
            var settings = enabledSettings()
            settings.redaction.enabled = redaction
            return Set(ids(try await tool.call(["body_contains": .string(needle)], context: context(settings))))
        }
        // Redaction on: none of the hidden bodies matches; the plain text body still does.
        #expect(try await found(secret, redaction: true) == [visible])
        #expect(try await found("only public", redaction: true) == [publicOnly])
        // The same flows match with redaction off (except UTF-16, whose bytes are not the ASCII needle).
        let off = try await found(secret, redaction: false)
        for (name, id) in hidden where name != "utf-16" { #expect(off.contains(id), "\(name)") }
        #expect(off.contains(visible))
    }

    @Test func searchMatchesATextPrefixCutInsideAMultiByteCharacter() async throws {
        let fixture = StoreFixture()
        // 64 KiB boundary falls inside the 3-byte character; the redacted decode must still work.
        let head = String(repeating: "a", count: 64 * 1024 - 2)
        let data = Data((head + "€€€ tail").utf8)
        let id = fixture.add(responseBody: data) {
            $0.responseHeaders = [HeaderField(name: "Content-Type", value: "text/plain; charset=utf-8")]
        }
        let tool = SearchFlowsTool(store: fixture.store)
        let result = try await tool.call(["body_contains": .string("aaaa")], context: context())
        #expect(ids(result) == [id])
    }

    // MARK: Cancellation and leases

    @Test func listFlowsStopsWhenCancelled() async throws {
        let fixture = StoreFixture()
        for index in 0..<300 { fixture.add(path: "/\(index)") }
        let tool = ListFlowsTool(store: fixture.store)
        let call = context()
        let task = Task { () throws -> JSONValue in
            while !Task.isCancelled { await Task.yield() }
            // Nothing matches, so the whole store is traversed and the periodic check is what stops it.
            return try await tool.call(["host": .string("zzz")], context: call)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func searchStopsWhenCancelledInsteadOfReportingNoMatch() async throws {
        let fixture = StoreFixture()
        for _ in 0..<5 { fixture.add(responseBody: Data("hit".utf8)) }
        let tool = SearchFlowsTool(store: fixture.store)
        let call = context()
        let task = Task { () throws -> JSONValue in
            while !Task.isCancelled { await Task.yield() }
            return try await tool.call(["body_contains": .string("hit")], context: call)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }

        // Many non-matching flows: the filter pass itself notices the cancellation.
        let other = StoreFixture()
        for _ in 0..<300 { other.add() }
        let filterOnly = SearchFlowsTool(store: other.store)
        let second = Task { () throws -> JSONValue in
            while !Task.isCancelled { await Task.yield() }
            return try await filterOnly.call(["body_contains": .string("x"), "host": .string("zzz")], context: call)
        }
        second.cancel()
        await #expect(throws: CancellationError.self) { try await second.value }
    }

    @Test func leasesAreReleasedSoClearRemovesSpilledBodyFiles() async throws {
        let fixture = StoreFixture()
        // Over the 1 MiB spill threshold, so the body lives in a file inside the store's directory.
        func spilled(_ marker: String) throws -> BodyRef {
            let capture = fixture.store.makeBodyCapture()
            capture.append(Array(marker.utf8))
            capture.append([UInt8](repeating: UInt8(ascii: "x"), count: BodyCapture.spillThreshold + 1))
            return try #require(capture.finish().body)
        }
        func files() -> [String] {
            (try? FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)) ?? []
        }
        var settings = enabledSettings()
        settings.redaction.enabled = false
        let (responseSpill, requestSpill) = (try spilled("findme"), try spilled("findme"))
        let first = fixture.add { $0.responseBody = responseSpill }
        fixture.add { $0.requestBody = requestSpill }
        #expect(files().count == 2)
        let tool = SearchFlowsTool(store: fixture.store)
        let found = try await tool.call(["body_contains": .string("findme")], context: context(settings))
        #expect(ids(found).count == 2)
        #expect(files().count == 2)
        fixture.store.clear()
        // A lease still held by the search would keep the reader slot and so the files.
        #expect(files().isEmpty)
        #expect(fixture.store.flowCount == 0)
        #expect(ids(try await tool.call(["body_contains": .string("findme")], context: context(settings))) == [])
        _ = first
    }

    @Test func tagsReflectProvenance() async throws {
        let fixture = StoreFixture()
        let applied = RuleMatchSummary(
            revision: 1, ruleIDs: [UUID()], total: 1, outcomes: [RuleOutcome(ruleID: UUID(), code: .applied)])
        let plain = fixture.add()
        let compose = fixture.add { $0.provenance.source = .compose(sendID: UUID(), sourceFlowID: nil, sourceBoundary: nil) }
        let repeated = fixture.add { $0.provenance.tools.repeatRun = RepeatRunTag(runID: UUID(), index: 1, total: 2) }
        let blocked = fixture.add {
            $0.provenance.tools.blockedByEntry = UUID()
            $0.provenance.generatedResponse = GeneratedResponseSource(size: 1)
        }
        let mocked = fixture.add { $0.provenance.generatedResponse = GeneratedResponseSource(size: 1) }
        let rewritten = fixture.add { $0.provenance.ruleMatches = applied }
        let websocket = fixture.add(status: 101) {
            $0.requestHeaders = [
                HeaderField(name: "Upgrade", value: "websocket"), HeaderField(name: "Connection", value: "Upgrade"),
            ]
        }
        let tunnel = fixture.add(method: "CONNECT", status: nil, state: .tunnel)
        let refusedUpgrade = fixture.add(status: 400) {
            $0.requestHeaders = [
                HeaderField(name: "Upgrade", value: "websocket"), HeaderField(name: "Connection", value: "Upgrade"),
            ]
        }

        let result = try await ListFlowsTool(store: fixture.store).call(["limit": .int(200)], context: context())
        var tags: [Int: [String]] = [:]
        for flow in result["flows"]?.arrayValue ?? [] {
            tags[flow["id"]?.intValue ?? -1] = (flow["tags"]?.arrayValue ?? []).compactMap(\.stringValue)
        }
        #expect(tags[plain] == [])
        #expect(tags[compose] == ["compose"])
        #expect(tags[repeated] == ["repeat"])
        #expect(tags[blocked] == ["blocked"])
        #expect(tags[mocked] == ["mocked"])
        #expect(tags[rewritten] == ["rewritten"])
        #expect(tags[websocket] == ["websocket"])
        #expect(tags[tunnel] == ["tunnel"])
        #expect(tags[refusedUpgrade] == [])
    }

    // MARK: search_flows

    @Test func searchFindsRequestAndResponseBodies() async throws {
        let fixture = StoreFixture()
        let inRequest = fixture.add(requestBody: Data("{\"Name\":\"NeedleValue\"}".utf8), responseBody: Data("ok".utf8))
        let inResponse = fixture.add(requestBody: Data("x".utf8), responseBody: Data("some needlevalue here".utf8))
        let inBoth = fixture.add(requestBody: Data("NEEDLEVALUE".utf8), responseBody: Data("needlevalue".utf8))
        let none = fixture.add(requestBody: Data("zzz".utf8), responseBody: Data("zzz".utf8))
        let noBody = fixture.add()
        _ = (none, noBody)
        let tool = SearchFlowsTool(store: fixture.store)

        func run(_ extra: [String: JSONValue] = [:]) async throws -> JSONValue {
            try await tool.call(["body_contains": .string("needleValue")].merging(extra) { $1 }, context: context())
        }
        func matches(_ result: JSONValue) -> [Int: [String]] {
            var map: [Int: [String]] = [:]
            for flow in result["flows"]?.arrayValue ?? [] {
                map[flow["id"]?.intValue ?? -1] = (flow["matchedIn"]?.arrayValue ?? []).compactMap(\.stringValue)
            }
            return map
        }

        let both = try await run()
        #expect(matches(both) == [inRequest: ["request"], inResponse: ["response"], inBoth: ["request", "response"]])
        #expect(ids(both) == [inBoth, inResponse, inRequest])
        #expect(both["scanned"]?.intValue == 5)
        #expect(both["scanLimited"]?.boolValue == false)
        #expect(both["nextBeforeId"] == .null)

        #expect(matches(try await run(["where": .string("request")])) == [inRequest: ["request"], inBoth: ["request"]])
        #expect(matches(try await run(["where": .string("response")])) == [inResponse: ["response"], inBoth: ["response"]])
        // The shared filters still apply.
        #expect(ids(try await run(["limit": .int(1)])) == [inBoth])
        #expect(ids(try await run(["method": .string("POST")])) == [])
    }

    @Test func searchPagesWithBeforeIDWhenLimitReached() async throws {
        let fixture = StoreFixture()
        let all = (0..<5).map { _ in fixture.add(responseBody: Data("hit".utf8)) }
        let tool = SearchFlowsTool(store: fixture.store)
        var collected: [Int] = []
        var before: JSONValue = .null
        for _ in 0..<10 {
            var arguments: [String: JSONValue] = ["body_contains": .string("hit"), "limit": .int(2)]
            if before != .null { arguments["before_id"] = before }
            let page = try await tool.call(arguments, context: context())
            collected += ids(page)
            before = page["nextBeforeId"] ?? .null
            if before == .null { break }
        }
        #expect(collected == all.reversed())
    }

    @Test func searchPagesAcrossTheByteBudgetWithoutGapsOrDuplicates() async throws {
        let fixture = StoreFixture()
        let all = (0..<150).map { index in
            fixture.add(path: "/" + String(repeating: "b", count: 5000) + "\(index)", responseBody: Data("hit".utf8))
        }
        let tool = SearchFlowsTool(store: fixture.store)
        let first = try await tool.call(["body_contains": .string("hit"), "limit": .int(200)], context: context())
        #expect(ids(first).count < 150)
        #expect(first["nextBeforeId"]?.intValue == ids(first).last)
        #expect(try first.encoded().count < MCPToolRunner.maxResultBytes)

        var collected: [Int] = []
        var before: JSONValue = .null
        for _ in 0..<50 {
            var arguments: [String: JSONValue] = ["body_contains": .string("hit"), "limit": .int(200)]
            if before != .null { arguments["before_id"] = before }
            let page = try await tool.call(arguments, context: context())
            #expect(try page.encoded().count < MCPToolRunner.maxResultBytes)
            collected += ids(page)
            before = page["nextBeforeId"] ?? .null
            if before == .null { break }
        }
        #expect(collected == all.reversed())
    }

    @Test func searchScanBudgetSetsScanLimited() async throws {
        let fixture = StoreFixture()
        let oldest = fixture.add(responseBody: Data("target".utf8))
        let middle = fixture.add(responseBody: Data("other".utf8))
        let newest = fixture.add(responseBody: Data("other".utf8))
        let limited = SearchFlowsTool(store: fixture.store, scanLimit: 2)
        let result = try await limited.call(["body_contains": .string("target")], context: context())
        #expect(ids(result) == [])
        #expect(result["scanned"]?.intValue == 2)
        #expect(result["scanLimited"]?.boolValue == true)
        // The caller can carry on below the last flow that was scanned.
        #expect(result["nextBeforeId"]?.intValue == middle)
        _ = newest

        let resumed = try await limited.call(
            ["body_contains": .string("target"), "before_id": result["nextBeforeId"] ?? .null], context: context())
        #expect(ids(resumed) == [oldest])
        #expect(resumed["scanLimited"]?.boolValue == false)

        // Exactly as many candidates as the budget is not "limited".
        let exact = try await SearchFlowsTool(store: fixture.store, scanLimit: 3)
            .call(["body_contains": .string("target")], context: context())
        #expect(exact["scanLimited"]?.boolValue == false)
        #expect(exact["scanned"]?.intValue == 3)
        #expect(ids(exact) == [oldest])
    }

    @Test func searchIgnoresBytesBeyond64KiB() async throws {
        let fixture = StoreFixture()
        let filler = Data(repeating: UInt8(ascii: "a"), count: 64 * 1024)
        let before = fixture.add(responseBody: filler.dropLast(6) + Data("NEEDLE".utf8))
        let straddling = fixture.add(responseBody: filler.dropLast(3) + Data("NEEDLE".utf8))
        let after = fixture.add(responseBody: filler + Data("NEEDLE".utf8))
        // A borrowed file body goes through the same cap.
        let fileURL = fixture.directory.appendingPathComponent("borrowed.bin")
        try (filler + Data("NEEDLE".utf8)).write(to: fileURL)
        let borrowed = fixture.add {
            $0.responseBody = .file(fileURL, size: 64 * 1024 + 6)
            $0.responseHeaders = [HeaderField(name: "Content-Type", value: "text/plain")]
        }
        let tool = SearchFlowsTool(store: fixture.store)
        let result = try await tool.call(["body_contains": .string("needle")], context: context())
        #expect(ids(result) == [before])
        _ = (straddling, after, borrowed)
    }

    @Test func searchRequiresBodyContains() async throws {
        let fixture = StoreFixture()
        fixture.add(responseBody: Data("x".utf8))
        let tool = SearchFlowsTool(store: fixture.store)
        for arguments: [String: JSONValue] in [
            [:], ["body_contains": .string("")], ["body_contains": .int(3)],
            ["body_contains": .string(String(repeating: "a", count: 257))],
            ["body_contains": .string("x"), "where": .string("neither")],
            ["body_contains": .string("x"), "status": .string("99")],
        ] {
            do {
                _ = try await tool.call(arguments, context: context())
                Issue.record("accepted \(arguments)")
            } catch let error as MCPToolError {
                #expect(error.code == "invalid_arguments")
            }
        }
        // 256 bytes is allowed.
        _ = try await tool.call(["body_contains": .string(String(repeating: "a", count: 256))], context: context())
        // The limit is in bytes, not characters.
        do {
            _ = try await tool.call(["body_contains": .string(String(repeating: "é", count: 129))], context: context())
            Issue.record("accepted 258 bytes")
        } catch let error as MCPToolError {
            #expect(error.code == "invalid_arguments")
        }
    }

    // MARK: get_status

    @Test func getStatusReportsRecordingPortRulesAndWritePermissions() async throws {
        let fixture = StoreFixture()
        fixture.add()
        fixture.add()
        let source = StubStatus(
            value: MCPAppStatus(
                recording: true, listeningPort: 9090, rulesCount: 4, enabledRulesCount: 3, globalRulesSwitchOn: false))
        let tool = GetStatusTool(app: MCPAppInfo(name: "ProxyWoman", version: "0.6"), flows: fixture.store, status: source)
        var settings = enabledSettings([.createRule, .setRecording])
        settings.allowEnablingRules = true
        let result = try await tool.call([:], context: context(settings))
        #expect(result["app"] == .object(["name": .string("ProxyWoman"), "version": .string("0.6")]))
        #expect(result["mcp"]?["protocol"]?.stringValue == MCPSession.supportedProtocolVersions.first)
        #expect(result["mcp"]?["redaction"]?["enabled"]?.boolValue == true)
        #expect(result["recording"]?.boolValue == true)
        #expect(result["listeningPort"]?.intValue == 9090)
        #expect(result["flowCount"]?.intValue == 2)
        #expect(result["rules"] == .object(["count": .int(4), "enabledCount": .int(3), "globalSwitchOn": .bool(false)]))
        #expect(
            result["writePermissions"]
                == .object([
                    "create_rule": .bool(true), "update_rule": .bool(false), "set_rule_enabled": .bool(false),
                    "set_recording": .bool(true), "allow_enabling_rules": .bool(true),
                ]))

        var off = enabledSettings()
        off.redaction.enabled = false
        let nothing = StubStatus(
            value: MCPAppStatus(recording: false, listeningPort: nil, rulesCount: 0, enabledRulesCount: 0, globalRulesSwitchOn: true))
        let quiet = try await GetStatusTool(app: MCPAppInfo(name: "A", version: "1"), flows: fixture.store, status: nothing)
            .call([:], context: context(off))
        #expect(quiet["listeningPort"] == .null)
        #expect(quiet["mcp"]?["redaction"]?["enabled"]?.boolValue == false)
        #expect(quiet["writePermissions"]?["create_rule"]?.boolValue == false)
    }

    @Test func definitionsAreReadOnlyWithEnglishDescriptions() {
        let fixture = StoreFixture()
        let status = StubStatus(
            value: MCPAppStatus(recording: true, listeningPort: nil, rulesCount: 0, enabledRulesCount: 0, globalRulesSwitchOn: true))
        let tools: [any MCPTool] = [
            GetStatusTool(app: MCPAppInfo(name: "A", version: "1"), flows: fixture.store, status: status),
            ListFlowsTool(store: fixture.store), SearchFlowsTool(store: fixture.store),
        ]
        #expect(tools.map(\.definition.name) == ["get_status", "list_flows", "search_flows"])
        for tool in tools {
            #expect(tool.definition.kind == .read)
            #expect(tool.definition.description.contains("."))
            #expect(tool.definition.inputSchema["type"]?.stringValue == "object")
        }
        let required = SearchFlowsTool(store: fixture.store).definition.inputSchema["required"]?.arrayValue
        #expect(required == [.string("body_contains")])
    }
}
