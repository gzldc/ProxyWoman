import Foundation
import Testing

@testable import FlowStore

private func makeFlow(_ id: Int) -> Flow {
    Flow(id: id, scheme: "https", method: "POST", host: "example.com", port: 443, path: "/p?q=1")
}

private let target = HTTPMessageTarget(scheme: "https", host: "example.com", port: 443, method: "POST", pathAndQuery: "/p?q=1")

private func snapshot(
    _ boundary: HTTPMessageBoundary, body: HTTPBodySlice? = nil, state: HTTPBodyState = .complete,
    observed: UInt64 = 0, version: HTTPWireVersion? = .http1_1
) -> HTTPMessageSnapshot {
    let head: HTTPMessageHead = boundary == .downstreamRequest || boundary == .upstreamRequest || boundary == .composeSubmitted
        ? .request(target, headers: [HeaderField(name: "X-Boundary", value: boundary.rawValue)])
        : .response(status: 200, reason: "OK", headers: [HeaderField(name: "X-Boundary", value: boundary.rawValue)])
    return HTTPMessageSnapshot(
        boundary: boundary, head: head, wireVersion: version, body: body, bodyState: state, observedBytes: observed,
        transferState: .finished)
}

@Suite struct HTTPMessageSnapshotTests {
    @Test func oneBodyHandleBacksDifferentSlicesAndIsChargedOnce() throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let store = env.store
        let data = Data((0..<100).map { UInt8($0) })
        let body = store.makeManagedBody(data)
        let id = store.begin(makeFlow)
        store.update(id) { flow in
            flow.requestBody = body
            flow.messages[.downstreamRequest] = snapshot(
                .downstreamRequest, body: .init(ref: body, offset: 0, count: 100), observed: 100, version: .http2)
            flow.messages[.upstreamRequest] = snapshot(
                .upstreamRequest, body: .init(ref: body, offset: 0, count: 40), state: .incomplete, observed: 40)
        }
        let flow = try #require(store.flow(id))
        #expect(try flow.messages[.downstreamRequest]?.body?.load() == data)
        let upstream = try #require(flow.messages[.upstreamRequest])
        #expect(try upstream.body?.load() == data.prefix(40))
        #expect(upstream.bodyState == .incomplete)
        #expect(upstream.observedBytes == 40)
        // Heads and versions stay paired with their own boundary.
        #expect(flow.messages[.downstreamRequest]?.wireVersion == .http2)
        #expect(flow.messages[.upstreamRequest]?.wireVersion == .http1_1)
        #expect(flow.messages[.downstreamRequest]?.headers.first?.value == "downstreamRequest")
        #expect(flow.messages[.upstreamRequest]?.headers.first?.value == "upstreamRequest")
        // Three references, one retained body.
        let ownership = store.bodyOwnershipSnapshot()
        #expect(ownership.retainedBodies == 1)
        #expect(ownership.retainedMemoryBytes == 100)
        #expect(store.state.withLock { $0.residentBodyBytes } == 100)

        // Dropping the legacy field and one slice keeps the body alive for the last slice.
        store.update(id) { $0.requestBody = nil; $0.messages[.downstreamRequest] = nil }
        #expect(store.bodyOwnershipSnapshot().retainedBodies == 1)
        #expect(try store.flow(id)?.messages[.upstreamRequest]?.body?.load() == data.prefix(40))
        store.update(id) { $0.messages[.upstreamRequest] = nil }
        #expect(store.bodyOwnershipSnapshot().retainedBodies == 0)
        #expect(store.state.withLock { $0.residentBodyBytes } == 0)
    }

    @Test func clearRevokesSliceReadsWithAnIdentifiableError() throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let store = env.store
        let body = store.makeManagedBody(Data("hello".utf8))
        let id = store.begin(makeFlow)
        store.update(id) { $0.messages[.upstreamResponse] = snapshot(.upstreamResponse, body: .init(ref: body, offset: 0, count: 5), observed: 5) }
        let slice = try #require(store.flow(id)?.messages[.upstreamResponse]?.body)
        store.clear()
        do {
            _ = try slice.load()
            Issue.record("a cleared record must not stay readable")
        } catch let error as HTTPBodyError {
            #expect(error.isRevoked)
        }
    }

    @Test func sliceReadsClampToWhatWasKeptAndStayBounded() throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let body = env.store.makeManagedBody(Data("0123456789".utf8))
        // 25 bytes passed the boundary but only 10 were kept.
        let slice = HTTPBodySlice(ref: body, offset: 0, count: 25)
        #expect(try slice.load() == Data("0123456789".utf8))
        let limited = try slice.load(maxBytes: 4)
        #expect(limited.data == Data("0123".utf8))
        #expect(limited.isTruncated)
        let tail = HTTPBodySlice(ref: body, offset: 6, count: 100)
        #expect(try tail.load() == Data("6789".utf8))
        #expect(try HTTPBodySlice(ref: body, offset: 50, count: 5).load().isEmpty)
        // Borrowed inputs honour offsets too.
        #expect(try BodyRef.memory(Data("abcdef".utf8)).load(offset: 2, maxBytes: 3) == Data("cde".utf8))
    }

    @Test func foreignManagedHandleInASliceIsDroppedNotStoredUncharged() throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let other = TestEnvironment()
        defer { other.cleanUp() }
        let foreign = other.store.makeManagedBody(Data("foreign".utf8))
        let id = env.store.begin(makeFlow)
        env.store.update(id) {
            $0.requestBody = foreign
            $0.messages[.downstreamRequest] = snapshot(.downstreamRequest, body: .init(ref: foreign, offset: 0, count: 7), observed: 7)
        }
        let flow = try #require(env.store.flow(id))
        #expect(flow.requestBody == nil)
        #expect(flow.messages[.downstreamRequest]?.body == nil)
        #expect(flow.messages[.downstreamRequest]?.bodyState == .unavailable)
        #expect(env.store.state.withLock { $0.residentBodyBytes } == 0)
    }

    @Test func emptyCompleteBodyIsNotUnavailable() {
        let empty = snapshot(.upstreamRequest, body: nil, state: .complete, observed: 0)
        #expect(empty.body == nil)
        #expect(empty.bodyState == .complete)
        #expect(empty.bodyState != .unavailable)
    }

    @Test func clientVisibleMessageSelectsDownstreamOrComposeVirtualResult() {
        var passive = makeFlow(1)
        passive.provenance = .passive
        passive.messages[.downstreamRequest] = snapshot(.downstreamRequest)
        passive.messages[.upstreamResponse] = snapshot(.upstreamResponse)
        #expect(passive.clientVisibleMessage(.request)?.boundary == .downstreamRequest)
        // The origin's response is not what the client saw: it was never delivered.
        #expect(passive.clientVisibleMessage(.response) == nil)
        passive.messages[.downstreamResponse] = snapshot(.downstreamResponse)
        #expect(passive.clientVisibleMessage(.response)?.boundary == .downstreamResponse)

        var compose = makeFlow(2)
        compose.provenance = FlowProvenance(source: .compose(sendID: UUID(), sourceFlowID: 1, sourceBoundary: .upstreamRequest))
        compose.messages[.composeSubmitted] = snapshot(.composeSubmitted, version: nil)
        compose.messages[.composeDelivered] = snapshot(.composeDelivered, version: nil)
        compose.messages[.downstreamRequest] = snapshot(.downstreamRequest)
        #expect(compose.clientVisibleMessage(.request)?.boundary == .composeSubmitted)
        #expect(compose.clientVisibleMessage(.response)?.boundary == .composeDelivered)
        #expect(compose.clientVisibleMessage(.request)?.wireVersion == nil)
    }

    @Test func legacyFlowsClaimNothing() {
        let flow = makeFlow(1)
        #expect(flow.messages.isEmpty)
        #expect(!flow.provenance.isKnown)
        #expect(FlowProvenance.passive.isKnown)
        #expect(flow.clientVisibleMessage(.request) == nil)
    }

    @Test func ruleSummaryIsBoundedWithoutPaths() {
        let ids = (0..<300).map { _ in UUID() }
        let summary = RuleMatchSummary(
            revision: 7, ruleIDs: ids, total: 300, omitted: 0,
            outcomes: ids.map { RuleOutcome(ruleID: $0, code: .applied) })
        #expect(summary.ruleIDs == Array(ids.prefix(256)))
        #expect(summary.outcomes.count == 256)
        #expect(summary.omitted == 44)
        #expect(summary.total == 300)
        #expect(summary.revision == 7)
        let generated = GeneratedResponseSource(assetID: UUID(), size: 12)
        #expect(generated.size == 12)
    }

    @Test func outcomeCodesAreValidatedAndOutcomeOverflowIsCounted() throws {
        #expect(RuleOutcomeCode(rawValue: "unsupportedUpgradeAction") == .unsupportedUpgradeAction)
        for bad in ["", "has space", "/tmp/secret", "1leading", "中文", String(repeating: "a", count: 65), "a-b"] {
            #expect(RuleOutcomeCode(rawValue: bad) == nil, "\(bad)")
        }
        let encoded = try JSONEncoder().encode(RuleOutcome(ruleID: UUID(), code: .applied))
        #expect(try JSONDecoder().decode(RuleOutcome.self, from: encoded).code == .applied)
        let forged = Data(#"{"ruleID":"\#(UUID().uuidString)","code":"free form text"}"#.utf8)
        #expect(throws: DecodingError.self) { _ = try JSONDecoder().decode(RuleOutcome.self, from: forged) }
        // Outcomes alone exceeding the bound still count as omitted.
        let id = UUID()
        let summary = RuleMatchSummary(
            revision: 1, ruleIDs: [id], total: 300, omitted: 2,
            outcomes: (0..<300).map { _ in RuleOutcome(ruleID: id, code: .applied) })
        #expect(summary.outcomes.count == 256)
        #expect(summary.omitted == 2 + 44)
    }

    @Test func boundaryEnumIsStableAndComplete() {
        #expect(HTTPMessageBoundary.allCases.map(\.rawValue) == [
            "downstreamRequest", "upstreamRequest", "upstreamResponse", "downstreamResponse", "generatedResponse",
            "composeSubmitted", "composeDelivered",
        ])
    }

    @Test func storeMadeInMemoryCapturesAreManaged() throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let capture = env.store.makeBodyCapture()
        capture.append(Array("small".utf8))
        let body = try #require(capture.finish().body)
        guard case .managed = body else { Issue.record("store-made captures are managed even in memory"); return }
        let id = env.store.begin(makeFlow)
        env.store.update(id) { $0.requestBody = body }
        #expect(env.store.bodyOwnershipSnapshot().retainedMemoryBytes == 5)
        env.store.clear()
        #expect(env.store.bodyOwnershipSnapshot().retainedBodies == 0)
        #expect(throws: HTTPBodyError.revoked) { _ = try body.load() }
    }
}
