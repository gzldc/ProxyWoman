import FlowStore
import Foundation
import Testing
@testable import AppCore

private let target = HTTPMessageTarget(scheme: "https", host: "api.test", port: 8443, method: "POST", pathAndQuery: "/v1/items?a=%2F&a=2&flag")

private func capturedFlow(body: Data?, bodyState: HTTPBodyState = .complete, observed: UInt64? = nil) -> Flow {
    var flow = Flow(id: 7, scheme: "https", method: "PUT", host: "legacy.test", port: 443, path: "/legacy",
                    requestHeaders: [HeaderField(name: "X-Legacy", value: "1")])
    flow.state = .completed
    let headers = [
        HeaderField(name: "Host", value: "api.test:8443"), HeaderField(name: "Accept", value: "a"),
        HeaderField(name: "X-Dup", value: "1"), HeaderField(name: "accept", value: "b"), HeaderField(name: "X-Dup", value: "2"),
        HeaderField(name: "Content-Type", value: "application/json"),
    ]
    flow.messages[.downstreamRequest] = HTTPMessageSnapshot(
        boundary: .downstreamRequest, head: .request(target, headers: headers),
        body: body.map { HTTPBodySlice(ref: .memory($0), offset: 0, count: $0.count) },
        bodyState: bodyState, observedBytes: observed ?? UInt64(body?.count ?? 0), transferState: .finished)
    // What the proxy actually sent upstream (after rules) is not the draft's source.
    let edited = HTTPMessageTarget(scheme: "https", host: "edited.test", port: 443, method: "DELETE", pathAndQuery: "/edited")
    flow.messages[.upstreamRequest] = HTTPMessageSnapshot(
        boundary: .upstreamRequest, head: .request(edited, headers: [HeaderField(name: "X-Edited", value: "1")]),
        bodyState: .complete, transferState: .finished)
    return flow
}

private extension Flow {
    init(copying flow: Flow, id: Int) {
        self.init(id: id, startedAt: flow.startedAt, scheme: flow.scheme, method: flow.method, host: flow.host, port: flow.port,
                  path: flow.path, requestHeaders: flow.requestHeaders)
        state = flow.state
        messages = flow.messages
    }
}

@Suite(.productionChinese) struct ComposeDraftTests {
    @Test func draftFromFlowCopiesHeadersInOrder() throws {
        let flow = capturedFlow(body: Data(#"{"a":1}"#.utf8))
        let draft = ComposeDraft(from: flow)
        #expect(draft.sourceFlowID == 7)
        #expect(draft.method == "POST")
        #expect(draft.url == "https://api.test:8443/v1/items?a=%2F&a=2&flag")
        #expect(draft.query.rawValue == "a=%2F&a=2&flag")
        #expect(draft.headers.map { HeaderField(name: $0.name, value: $0.value) } == flow.messages[.downstreamRequest]?.headers)
        #expect(draft.body == .text(#"{"a":1}"#))
        #expect(draft.policy == ComposeDraftPolicy())
        #expect(draft.policy.applyRules == false && draft.policy.timeoutSeconds == 60 && draft.policy.http1Only == false)

        let request = try #require(draft.outgoingRequest(id: UUID()))
        #expect(request.headers == flow.messages[.downstreamRequest]?.headers)
        #expect(request.body == Data(#"{"a":1}"#.utf8))
        #expect(request.sourceFlowID == 7)
    }

    @Test func draftFromLegacyFlowUsesTheLegacyRequestFields() {
        var flow = Flow(id: 3, scheme: "http", method: "GET", host: "::1", port: 8080, path: "/x?y=%2f",
                        requestHeaders: [HeaderField(name: "B", value: "2"), HeaderField(name: "A", value: "1")])
        flow.state = .completed
        let draft = ComposeDraft(from: flow)
        #expect(draft.url == "http://[::1]:8080/x?y=%2f")
        #expect(draft.headers.map(\.name) == ["B", "A"])
        #expect(draft.body == ComposeDraftBody.none)
    }

    @Test func binaryBodyIsKeptAsHexBytes() throws {
        let bytes = Data([0x00, 0xFF, 0x10, 0x80])
        let draft = ComposeDraft(from: capturedFlow(body: bytes))
        #expect(draft.body == .hex("00 ff 10 80"))
        #expect(try #require(draft.outgoingRequest(id: UUID())).body == bytes)
    }

    @Test func draftFromLargeOrSpooledFlowBecomesPendingAndOtherwiseOmitsBodyWithReason() throws {
        // Complete but large or on disk: the body is copied later (task 10), never read here.
        let big = Data(repeating: 0x61, count: 1_048_577)
        let spooled = ({
            var flow = capturedFlow(body: nil)
            flow.messages[.downstreamRequest]?.body = HTTPBodySlice(ref: .file(URL(fileURLWithPath: "/nonexistent/x.body"), size: 3), offset: 0, count: 3)
            flow.messages[.downstreamRequest]?.observedBytes = 3
            return flow
        })()
        for (flow, size) in [(capturedFlow(body: big), 1_048_577), (spooled, 3)] {
            let draft = ComposeDraft(from: flow)
            guard case .pending(let captured) = draft.body else { Issue.record("not pending"); continue }
            #expect(captured.size == Int64(size) && captured.slice == flow.messages[.downstreamRequest]?.body)
            #expect(draft.body.mode == nil && draft.body.bytes == nil)
            #expect(draft.validate().contains { $0.code == .bodyImporting && $0.severity == .error })
            #expect(draft.outgoingRequest(id: UUID()) == nil)
        }
        let cases: [(Flow, ReplayBlockReason)] = [
            (capturedFlow(body: Data("abc".utf8), bodyState: .truncated, observed: 9), .bodyTruncated),
            (capturedFlow(body: nil, bodyState: .incomplete, observed: 4), .bodyIncomplete),
        ]
        for (flow, reason) in cases {
            var draft = ComposeDraft(from: flow)
            #expect(draft.body == .omitted(.replay(reason)))
            #expect(draft.url == "https://api.test:8443/v1/items?a=%2F&a=2&flag")
            #expect(draft.headers.count == 6)
            let issues = draft.validate()
            #expect(issues.contains { $0.code == .bodyOmitted && $0.severity == .error })
            #expect(draft.outgoingRequest(id: UUID()) == nil)
            #expect(ComposeDraftBody.omitted(.replay(reason)).omissionReason == reason.localizedDescription)
            // Only an explicit choice makes it sendable.
            draft.body = .none
            #expect(draft.outgoingRequest(id: UUID())?.body == Data())
        }
    }

    @Test func clearedBodyIsOmittedAsUnreadable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FlowStore(bodyDirectory: directory)
        let capture = store.makeBodyCapture()
        capture.append(Array("hello".utf8))
        let body = try #require(capture.finish().body)
        // Only a body a stored flow references is owned, and revoked, by the store.
        let id = store.begin { id in
            var flow = capturedFlow(body: nil)
            flow.messages[.downstreamRequest]?.body = HTTPBodySlice(ref: body, offset: 0, count: 5)
            flow.messages[.downstreamRequest]?.observedBytes = 5
            return Flow(copying: flow, id: id)
        }
        let flow = try #require(store.flow(id))
        #expect(ComposeDraft(from: flow).body == .text("hello"))
        store.clear()
        #expect(ComposeDraft(from: flow).body == .omitted(.unreadable))
    }

    @Test func validateRejectsNonHTTPSchemeAndBadHeaderName() {
        func codes(_ draft: ComposeDraft) -> [ComposeDraftIssue.Code] {
            draft.validate().filter { $0.severity == .error }.map(\.code)
        }
        #expect(codes(ComposeDraft(method: "GET", url: "https://h/p")) == [])
        #expect(codes(ComposeDraft(method: "GET", url: "ftp://h/p")) == [.unsupportedScheme])
        #expect(codes(ComposeDraft(method: "GET", url: "ws://h/p")) == [.unsupportedScheme])
        #expect(codes(ComposeDraft(method: "GET", url: "h/p")) == [.unsupportedScheme])
        #expect(codes(ComposeDraft(method: "GET", url: "http://user:pw@h/p")) == [.userinfoNotAllowed])
        #expect(codes(ComposeDraft(method: "GET", url: "http:///p")) == [.invalidURL])
        #expect(codes(ComposeDraft(method: "GET", url: "http://h:99999/p")) == [.invalidURL])
        #expect(codes(ComposeDraft(method: "GET", url: "http://h/p?a=%Z1")) == [.invalidPercentEncoding])
        #expect(codes(ComposeDraft(method: "GE T", url: "http://h/")) == [.invalidMethod])
        #expect(codes(ComposeDraft(method: "CONNECT", url: "http://h/")) == [.connectNotAllowed])

        let bad = HeaderFieldRow(name: "Bad Name", value: "x")
        let draft = ComposeDraft(method: "GET", url: "https://h/", headers: [HeaderFieldRow(name: "Good", value: "1"), bad,
                                                                            HeaderFieldRow(name: "X", value: "a\r\nb")])
        let issues = draft.validate()
        #expect(issues.contains(ComposeDraftIssue(code: .invalidHeaderName, field: .header(bad.id))))
        #expect(issues.contains { $0.code == .invalidHeaderValue })
        #expect(draft.outgoingRequest(id: UUID()) == nil)

        var timeout = ComposeDraft(method: "GET", url: "https://h/")
        timeout.policy.timeoutSeconds = 601
        #expect(codes(timeout) == [.timeoutOutOfRange])
        timeout.policy.timeoutSeconds = 0
        #expect(codes(timeout) == [.timeoutOutOfRange])

        let upgrade = ComposeDraft(method: "GET", url: "https://h/", headers: [
            HeaderFieldRow(name: "Connection", value: "Upgrade"), HeaderFieldRow(name: "Upgrade", value: "websocket"),
        ])
        #expect(codes(upgrade) == [.upgradeNotSupported])

        let hex = ComposeDraft(method: "POST", url: "https://h/", body: .hex("0g"))
        #expect(codes(hex) == [.invalidHex])
        #expect(codes(ComposeDraft(method: "POST", url: "https://h/", body: .hex("abc"))) == [.invalidHex])
    }

    @Test func bodyAndContentTypeMismatchOnlyWarns() throws {
        let json = ComposeDraft(method: "POST", url: "https://h/", headers: [HeaderFieldRow(name: "Content-Type", value: "application/json")],
                                body: .text("not json"))
        #expect(json.validate().map(\.code) == [.bodyNotJSON])
        #expect(json.validate().allSatisfy { $0.severity == .warning })
        #expect(try #require(json.outgoingRequest(id: UUID())).body == Data("not json".utf8))

        let untyped = ComposeDraft(method: "POST", url: "https://h/", body: .text("a=1"))
        #expect(untyped.validate().map(\.code) == [.missingContentType])
        #expect(untyped.outgoingRequest(id: UUID()) != nil)

        let host = ComposeDraft(method: "GET", url: "https://h/", headers: [HeaderFieldRow(name: "Host", value: "other")])
        #expect(host.validate().map(\.code) == [.hostHeaderMismatch])
        #expect(ComposeDraft(method: "GET", url: "https://H:443/", headers: [HeaderFieldRow(name: "host", value: "h")]).validate() == [])
    }

    @Test func outgoingRequestKeepsQueryBytesAndDropsTheFragment() throws {
        var draft = ComposeDraft(method: "PATCH", url: "http://127.0.0.1:8080/a b/é?a=1&a=2&b=%2F&c=+&flag&e=&q=é|x&#frag")
        draft.policy = ComposeDraftPolicy(applyRules: true, timeoutSeconds: 5, http1Only: true)
        let id = UUID()
        let request = try #require(draft.outgoingRequest(id: id))
        #expect(request.id == id && request.method == "PATCH")
        // Bytes a URL cannot carry are percent-encoded one by one; everything else is untouched.
        #expect(request.url == "http://127.0.0.1:8080/a%20b/%C3%A9?a=1&a=2&b=%2F&c=+&flag&e=&q=%C3%A9%7Cx&")
        #expect(request.applyRules && request.timeoutSeconds == 5 && request.http1Only)
    }

    @Test func entryEligibilityExplainsWhyEditOrReplayIsUnavailable() {
        var tunnel = Flow(id: 1, scheme: "https", method: "CONNECT", host: "h", port: 443, path: "")
        tunnel.state = .tunnel
        #expect(ComposeEntry.edit(tunnel) == .tunnel)
        #expect(ComposeEntry.replay(tunnel) == .tunnel)

        var socket = capturedFlow(body: nil)
        socket.messages[.downstreamRequest]?.head = .request(target, headers: [
            HeaderField(name: "Connection", value: "Upgrade"), HeaderField(name: "Upgrade", value: "websocket"),
        ])
        #expect(ComposeEntry.edit(socket) == .upgrade)
        #expect(ComposeEntry.replay(socket) == .upgrade)

        let truncated = capturedFlow(body: Data("ab".utf8), bodyState: .truncated, observed: 5)
        #expect(ComposeEntry.edit(truncated) == nil)
        #expect(ComposeEntry.replay(truncated) == .body(.bodyTruncated))

        let complete = capturedFlow(body: Data("ab".utf8))
        #expect(ComposeEntry.edit(complete) == nil)
        #expect(ComposeEntry.replay(complete) == nil)
        for block in [ComposeEntryBlock.tunnel, .upgrade, .body(.bodyOnDisk)] {
            #expect(!block.localizedDescription.isEmpty && !block.localizedDescription.hasPrefix("compose."))
        }
    }

    @Test func switchingBodyModesNeverDropsBytesSilently() {
        var draft = ComposeDraft(method: "POST", url: "https://h/", body: .text("hé"))
        #expect(draft.body.mode == .text)
        // "No body" is a chosen mode, unlike an omitted body.
        #expect(ComposeDraftBody.none.mode == ComposeBodyMode.none)
        #expect(ComposeDraftBody.hex("").mode == ComposeBodyMode.hex)
        #expect(draft.switchBody(to: .hex) && draft.body == .hex("68 c3 a9"))
        #expect(draft.switchBody(to: .text) && draft.body == .text("hé"))

        draft.body = .hex("ff 00")
        #expect(!draft.canSwitchBody(to: .text))
        #expect(!draft.switchBody(to: .text) && draft.body == .hex("ff 00"))
        draft.body = .hex("0")
        #expect(!draft.canSwitchBody(to: .text))

        draft.body = .omitted(.replay(.bodyTruncated))
        #expect(draft.body.mode == nil)
        #expect(draft.switchBody(to: .text) && draft.body == .text(""))
        #expect(draft.switchBody(to: .none) && draft.body == ComposeDraftBody.none)
        #expect(draft.switchBody(to: .hex) && draft.body == .hex(""))
    }
}
