import FlowStore
import Foundation
import Testing
@testable import AppCore

// MARK: support

private let mib = 1_048_576
private let originalTarget = HTTPMessageTarget(scheme: "https", host: "api.test", port: 443, method: "POST", pathAndQuery: "/v1/items?x=1")

private func field(_ name: String, _ value: String) -> HeaderField { HeaderField(name: name, value: value) }

private func message(
    _ boundary: HTTPMessageBoundary, target: HTTPMessageTarget, headers: [HeaderField], body: HTTPBodySlice?,
    state: HTTPBodyState = .complete, observed: UInt64? = nil
) -> HTTPMessageSnapshot {
    HTTPMessageSnapshot(boundary: boundary, head: .request(target, headers: headers), body: body, bodyState: state,
                        observedBytes: observed ?? UInt64(body?.count ?? 0), transferState: .finished)
}

private func slice(_ data: Data) -> HTTPBodySlice { HTTPBodySlice(ref: .memory(data), offset: 0, count: data.count) }

private let originalHeaders = [
    field("Host", "api.test"), field("Content-Type", "application/json"), field("Content-Length", "4"), field("Accept", "a"),
]

/// A POST whose upstream request starts out the same as the downstream one (plus the framing and
/// connection fields a transport writes).
private func flow(
    upstreamTarget: HTTPMessageTarget? = originalTarget, upstreamHeaders: [HeaderField]? = nil,
    upstreamBody: HTTPBodySlice? = slice(Data("body".utf8)), upstreamState: HTTPBodyState = .complete, upstreamObserved: UInt64? = nil,
    hasUpstream: Bool = true
) -> Flow {
    var flow = Flow(id: 9, scheme: "https", method: "POST", host: "api.test", port: 443, path: "/v1/items?x=1")
    flow.state = .completed
    flow.messages[.downstreamRequest] = message(.downstreamRequest, target: originalTarget, headers: originalHeaders,
                                                body: slice(Data("body".utf8)))
    if hasUpstream, let upstreamTarget {
        let headers = upstreamHeaders ?? [
            field("host", "api.test"), field("Content-Type", "application/json"), field("Content-Length", "4"),
            field("Connection", "keep-alive"), field("Accept", "a"),
        ]
        flow.messages[.upstreamRequest] = message(.upstreamRequest, target: upstreamTarget, headers: headers, body: upstreamBody,
                                                  state: upstreamState, observed: upstreamObserved)
    }
    return flow
}

private func pairs(_ draft: ComposeDraft) -> [[String]] { draft.headers.map { [$0.name, $0.value] } }

// MARK: tests

@Suite(.productionChinese) struct ComposeVariantTests {
    @Test func originalVariantMatchesCurrentBehaviour() {
        let source = flow(upstreamTarget: HTTPMessageTarget(scheme: "http", host: "other.test", port: 80, method: "PUT", pathAndQuery: "/z"))
        let plain = ComposeDraft(from: source)
        let original = ComposeDraft(from: source, variant: .original)
        #expect(original.hasSameContent(as: plain))
        #expect(original.sourceFlowID == plain.sourceFlowID && original.query.rawValue == plain.query.rawValue)
        #expect(original.url == "https://api.test/v1/items?x=1" && original.method == "POST")
        #expect(pairs(original) == originalHeaders.map { [$0.name, $0.value] })
        #expect(original.body == .text("body"))
    }

    @Test func effectiveUsesUpstreamTargetAndHeaders() {
        let mapped = HTTPMessageTarget(scheme: "http", host: "staging.test", port: 8080, method: "POST", pathAndQuery: "/v2/items?x=1&y=2")
        let source = flow(upstreamTarget: mapped, upstreamHeaders: [field("Host", "staging.test:8080"), field("Accept", "a")])
        let draft = ComposeDraft(from: source, variant: .effective)
        #expect(draft.url == "http://staging.test:8080/v2/items?x=1&y=2" && draft.method == "POST")
        #expect(draft.query.rawValue == "x=1&y=2" && draft.sourceFlowID == 9)
        #expect(pairs(draft) == [["Accept", "a"]])
        #expect(draft.policy == ComposeDraftPolicy())
        #expect(draft.body == .text("body"))
    }

    @Test func effectiveStripsTransportFieldsKeepsOrderAndDuplicates() {
        let headers = [
            field("X-Dup", "1"), field("CONTENT-LENGTH", "4"), field("Accept", "a"), field("Transfer-Encoding", "chunked"),
            field("Keep-Alive", "timeout=5"), field("x-dup", "2"), field("Proxy-Connection", "keep-alive"), field("Connection", "close"),
            field("HOST", "API.test"), field("Content-Type", "text/plain"), field("X-Dup", "3"),
        ]
        let draft = ComposeDraft(from: flow(upstreamHeaders: headers, upstreamBody: nil, upstreamObserved: 0), variant: .effective)
        #expect(pairs(draft) == [["X-Dup", "1"], ["Accept", "a"], ["x-dup", "2"], ["Content-Type", "text/plain"], ["X-Dup", "3"]])
        // The default port may be spelled out too.
        let explicit = ComposeDraft(from: flow(upstreamHeaders: [field("Host", "api.test:443"), field("A", "1")]), variant: .effective)
        #expect(pairs(explicit) == [["A", "1"]])
    }

    @Test func effectiveKeepsHostWhenItDiffersFromAuthority() {
        let headers = [field("Host", "virtual.test"), field("Accept", "a")]
        let draft = ComposeDraft(from: flow(upstreamHeaders: headers), variant: .effective)
        #expect(pairs(draft) == [["Host", "virtual.test"], ["Accept", "a"]])
        // A Host naming another port than the target's is not the target's authority either.
        let port = ComposeDraft(from: flow(upstreamHeaders: [field("Host", "api.test:8443")]), variant: .effective)
        #expect(pairs(port) == [["Host", "api.test:8443"]])
        // IPv6 targets are bracketed in their authority.
        let v6 = HTTPMessageTarget(scheme: "http", host: "::1", port: 8080, method: "GET", pathAndQuery: "/")
        let six = ComposeDraft(from: flow(upstreamTarget: v6, upstreamHeaders: [field("Host", "[::1]:8080"), field("A", "1")]),
                               variant: .effective)
        #expect(pairs(six) == [["A", "1"]] && six.url == "http://[::1]:8080/")
    }

    @Test func effectiveReflectsNoCachingAndRuleHeaderEdits() {
        // The proxy dropped the conditional headers (no-caching) and a rule added and changed headers.
        let source = flow(upstreamHeaders: [
            field("Host", "api.test"), field("Accept", "rewritten"), field("Cache-Control", "no-cache"), field("X-Rule", "1"),
        ])
        #expect(ComposeEntry.effectiveAvailable(source))
        let draft = ComposeDraft(from: source, variant: .effective)
        #expect(pairs(draft) == [["Accept", "rewritten"], ["Cache-Control", "no-cache"], ["X-Rule", "1"]])
        #expect(pairs(ComposeDraft(from: source)) == originalHeaders.map { [$0.name, $0.value] })
    }

    @Test func effectiveUnavailableWithoutUpstreamSnapshot() {
        let blocked = flow(hasUpstream: false)
        #expect(!ComposeEntry.effectiveAvailable(blocked))
        #expect(ComposeEntry.edit(blocked, variant: .effective) == .noEffectiveRequest)
        // A legacy flow (no snapshots at all) has none either.
        var legacy = Flow(id: 1, scheme: "http", method: "GET", host: "h", port: 80, path: "/")
        legacy.state = .completed
        #expect(!ComposeEntry.effectiveAvailable(legacy))
        #expect(ComposeEntry.edit(legacy, variant: .effective) == .noEffectiveRequest)
        // Without a snapshot the draft is the original one.
        #expect(ComposeDraft(from: blocked, variant: .effective).hasSameContent(as: ComposeDraft(from: blocked)))
    }

    @Test func effectiveUnavailableWhenIdentical() {
        // Only transport-generated fields differ: nothing the user could see or change.
        let same = flow()
        #expect(!ComposeEntry.effectiveAvailable(same))
        #expect(ComposeEntry.edit(same, variant: .effective) == .noEffectiveRequest)
        #expect(ComposeEntry.edit(same, variant: .original) == nil && ComposeEntry.edit(same) == nil)

        // Each of target, headers and body size alone makes it available.
        let otherPath = HTTPMessageTarget(scheme: "https", host: "api.test", port: 443, method: "POST", pathAndQuery: "/v1/items?x=2")
        #expect(ComposeEntry.effectiveAvailable(flow(upstreamTarget: otherPath)))
        #expect(ComposeEntry.effectiveAvailable(flow(upstreamHeaders: [field("Host", "api.test"), field("Content-Type", "application/json"),
                                                                       field("Accept", "b")])))
        #expect(ComposeEntry.effectiveAvailable(flow(upstreamBody: slice(Data("bodies".utf8)))))
        #expect(ComposeEntry.edit(flow(upstreamBody: slice(Data("bodies".utf8))), variant: .effective) == nil)
    }

    @Test func effectiveBodyUsesSameEligibilityRules() {
        let big = HTTPBodySlice(ref: .memory(Data(repeating: 7, count: 2 * mib)), offset: 0, count: 2 * mib)
        let pending = ComposeDraft(from: flow(upstreamBody: big), variant: .effective)
        #expect(pending.body == .pending(CapturedBodyImport(slice: big, displayName: "request-body.bin", size: Int64(2 * mib))))
        // The original body is still the small one.
        #expect(ComposeDraft(from: flow(upstreamBody: big)).body == .text("body"))

        let truncated = ComposeDraft(from: flow(upstreamBody: slice(Data("bo".utf8)), upstreamState: .truncated, upstreamObserved: 9),
                                     variant: .effective)
        #expect(truncated.body == .omitted(.replay(.bodyTruncated)))
        let incomplete = ComposeDraft(from: flow(upstreamBody: nil, upstreamState: .incomplete, upstreamObserved: 3), variant: .effective)
        #expect(incomplete.body == .omitted(.replay(.bodyIncomplete)))
        let empty = ComposeDraft(from: flow(upstreamBody: nil, upstreamObserved: 0), variant: .effective)
        #expect(empty.body == ComposeDraftBody.none)
        let binary = ComposeDraft(from: flow(upstreamBody: slice(Data([0xFF, 0x00]))), variant: .effective)
        #expect(binary.body == .hex("ff 00"))
        // Over the asset limit.
        let huge = ComposeDraft(from: flow(upstreamBody: nil, upstreamObserved: UInt64(600 * mib)), variant: .effective)
        #expect(huge.body == .omitted(.replay(.bodyTooLarge)))
    }

    @Test func blockedEffectiveReturnsNoEffectiveEntry() {
        var tunnel = flow()
        tunnel.method = "CONNECT"
        // The ordinary blocks win over the missing variant.
        #expect(ComposeEntry.edit(tunnel, variant: .effective) == .tunnel)
        var upgraded = flow(upstreamHeaders: [field("Host", "api.test")])
        upgraded.messages[.downstreamRequest] = message(
            .downstreamRequest, target: originalTarget,
            headers: [field("Connection", "Upgrade"), field("Upgrade", "websocket")], body: nil)
        #expect(ComposeEntry.edit(upgraded, variant: .effective) == .upgrade)
        #expect(ComposeEntryBlock.noEffectiveRequest.localizationKey == "compose.entry.blocked.noEffective")
        #expect(!ComposeEntryBlock.noEffectiveRequest.localizedDescription.isEmpty)
        #expect(!ComposeEntryBlock.noEffectiveRequest.localizedDescription.hasPrefix("compose."))
    }

    @Test func replayAlwaysUsesOriginal() {
        let changed = HTTPMessageTarget(scheme: "http", host: "staging.test", port: 80, method: "PUT", pathAndQuery: "/other")
        let source = flow(upstreamTarget: changed, upstreamHeaders: [field("X", "1")])
        #expect(ComposeEntry.replay(source) == nil)
        #expect(ComposeDraft(from: source).url == "https://api.test/v1/items?x=1")
        #expect(ComposeRequestVariant.allCases == [.original, .effective])
        // Replay is judged on the original body only.
        let upstreamBig = HTTPBodySlice(ref: .memory(Data(repeating: 1, count: 2 * mib)), offset: 0, count: 2 * mib)
        #expect(ComposeEntry.replay(flow(upstreamBody: upstreamBig)) == nil)
    }

    @Test func effectiveUnavailableForTranslationOnlyDifferences() {
        // An h2 upstream lowercases names, joins/splits cookies, and drops te and upgrade.
        let downstream = [
            field("Host", "api.test"), field("Accept", "a"), field("Content-Type", "application/json"),
            field("Cookie", "a=1"), field("TE", "trailers"), field("Cookie", "b=2"), field("X-Dup", "1"), field("X-Dup", "2"),
        ]
        func available(upstream: [HeaderField], original: [HeaderField] = downstream) -> Bool {
            var source = flow(upstreamHeaders: upstream)
            source.messages[.downstreamRequest] = message(.downstreamRequest, target: originalTarget, headers: original,
                                                          body: slice(Data("body".utf8)))
            return ComposeEntry.effectiveAvailable(source)
        }
        let lowercased = [
            field("accept", "a"), field("content-type", "application/json"), field("cookie", "a=1"), field("cookie", "b=2"),
            field("x-dup", "1"), field("x-dup", "2"),
        ]
        #expect(!available(upstream: lowercased))
        // Split versus joined cookie, either way round.
        let joined = [
            field("accept", "a"), field("content-type", "application/json"), field("cookie", "a=1; b=2"),
            field("x-dup", "1"), field("x-dup", "2"),
        ]
        #expect(!available(upstream: joined))
        #expect(!available(upstream: lowercased, original: [
            field("Accept", "a"), field("Content-Type", "application/json"), field("Cookie", "a=1; b=2"),
            field("X-Dup", "1"), field("X-Dup", "2"),
        ]))
        // te and upgrade dropped by the translator.
        #expect(!available(upstream: joined, original: downstream + [field("Upgrade", "h2c")]))

        // Real differences still count.
        var changed = joined
        changed[0] = field("accept", "b")
        #expect(available(upstream: changed))
        #expect(available(upstream: joined + [field("cache-control", "no-cache")]))
        #expect(available(upstream: joined.filter { $0.name != "x-dup" } + [field("x-dup", "2"), field("x-dup", "1")]))
        var cookieChanged = joined
        cookieChanged[2] = field("cookie", "a=1; b=3")
        #expect(available(upstream: cookieChanged))
        // Map Remote: the target changed, headers the same.
        let mapped = HTTPMessageTarget(scheme: "https", host: "staging.test", port: 443, method: "POST", pathAndQuery: "/v1/items?x=1")
        #expect(ComposeEntry.effectiveAvailable(flow(upstreamTarget: mapped)))
    }
}
