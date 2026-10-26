import FlowStore
import Foundation
import Testing

@testable import RulesEngine

private func field(_ name: String, _ value: String) -> HeaderField { HeaderField(name: name, value: value) }

private func values(_ headers: [HeaderField], _ name: String) -> [String] {
    headers.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
}

@Suite("NoCaching")
struct NoCachingTests {
    @Test func requestEditsRemoveValidatorsAndSetNoCache() throws {
        let input = [
            field("Host", "a.test"), field("If-None-Match", "\"x\""), field("if-modified-since", "Mon"),
            field("Cache-Control", "max-age=0"), field("X-A", "1"),
        ]
        let output = try NoCaching.apply(input, direction: .request, upgradeCandidate: false)
        #expect(values(output, "If-None-Match").isEmpty)
        #expect(values(output, "If-Modified-Since").isEmpty)
        #expect(values(output, "Cache-Control") == ["no-cache"])
        #expect(values(output, "Pragma") == ["no-cache"])
        let names = output.map(\.name)
        let host = try #require(names.firstIndex(of: "Host"))
        let xa = try #require(names.firstIndex(of: "X-A"))
        #expect(host < xa)
        #expect(output.count == 4)
    }

    @Test func responseEditsDropValidatorsAndForbidStoring() throws {
        let input = [
            field("ETag", "\"x\""), field("Last-Modified", "Mon"), field("Expires", "Tue"),
            field("Cache-Control", "max-age=60"), field("Content-Type", "text/plain"),
        ]
        let output = try NoCaching.apply(input, direction: .response, status: 200, upgradeCandidate: false)
        #expect(values(output, "ETag").isEmpty)
        #expect(values(output, "Last-Modified").isEmpty)
        #expect(values(output, "Expires") == ["0"])
        #expect(values(output, "Cache-Control") == ["no-cache, no-store"])
        #expect(values(output, "Content-Type") == ["text/plain"])
        let bare = try NoCaching.apply([], direction: .response, status: 204, upgradeCandidate: false)
        #expect(bare.map(\.name) == ["Cache-Control", "Expires"])
    }

    @Test func upgradeAndSwitchingProtocolsAreUntouched() throws {
        let input = [field("Connection", "Upgrade"), field("Upgrade", "websocket"), field("ETag", "x")]
        #expect(try NoCaching.apply(input, direction: .request, upgradeCandidate: true) == input)
        #expect(try NoCaching.apply(input, direction: .response, status: 101, upgradeCandidate: false) == input)
        #expect(try NoCaching.apply(input, direction: .response, status: 101, upgradeCandidate: true) == input)
        #expect(try NoCaching.apply(input, direction: .response, status: 200, upgradeCandidate: false) != input)
    }

    @Test func builtInEditsPassTheSharedValidator() throws {
        try HTTPMutationValidator.validateEdits(NoCaching.requestEdits, originalHeaders: [])
        try HTTPMutationValidator.validateEdits(NoCaching.responseEdits, originalHeaders: [])
        #expect(NoCaching.requestEdits == [
            .remove(name: "If-None-Match"), .remove(name: "If-Modified-Since"),
            .set(name: "Cache-Control", value: "no-cache"), .set(name: "Pragma", value: "no-cache"),
        ])
        #expect(NoCaching.responseEdits == [
            .remove(name: "ETag"), .remove(name: "Last-Modified"), .remove(name: "Expires"),
            .set(name: "Cache-Control", value: "no-cache, no-store"), .set(name: "Expires", value: "0"),
        ])
    }

    @Test func oversizedBlockIsRejected() {
        let limits = RulesLimits(headerFields: 2)
        let input = [field("Host", "a.test"), field("X-A", "1")]
        #expect(throws: HTTPMutationError.self) {
            try NoCaching.apply(input, direction: .request, upgradeCandidate: false, limits: limits)
        }
        let tight = RulesLimits(headerBytes: 100)
        #expect(throws: HTTPMutationError.self) {
            try NoCaching.apply(input, direction: .request, upgradeCandidate: false, limits: tight)
        }
    }

    @Test func connectionNominatedCacheHeaderIsRejectedNotSilentlyChanged() {
        let input = [field("Connection", "close, Cache-Control"), field("Cache-Control", "max-age=1")]
        #expect(throws: HTTPMutationError.self) {
            try NoCaching.apply(input, direction: .request, upgradeCandidate: false)
        }
    }
}
