import FlowStore
import Foundation
import Testing

@testable import RulesEngine

private func target(
    scheme: String = "https", host: String = "a.test", port: Int = 443, path: String = "/v1/items?a=1"
) -> HTTPMessageTarget {
    HTTPMessageTarget(scheme: scheme, host: host, port: port, method: "GET", pathAndQuery: path)
}

private let credentialedHeaders = [
    HeaderField(name: "Host", value: "a.test"),
    HeaderField(name: "Proxy-Authorization", value: "Basic cHJveHk="),
    HeaderField(name: "Authorization", value: "Bearer secret"),
    HeaderField(name: "Cookie", value: "sid=1"),
    HeaderField(name: "Origin", value: "https://a.test"),
    HeaderField(name: "Referer", value: "https://a.test/page"),
    HeaderField(name: "Accept", value: "*/*"),
]

@Suite("RequestRouting")
struct RequestRoutingTests {
    @Test func sameTargetKeepsEveryHeader() {
        let original = target()
        let kept = RequestRouting.sanitizedHeaders(credentialedHeaders, from: original, to: original, preserveCredentials: false)
        #expect(kept == credentialedHeaders)
    }

    @Test func movedTargetDropsHostAndProxyAuthorization() {
        let moved = target(path: "/other")
        let kept = RequestRouting.sanitizedHeaders(credentialedHeaders, from: target(), to: moved, preserveCredentials: true)
        #expect(kept.map(\.name) == ["Authorization", "Cookie", "Origin", "Referer", "Accept"])
    }

    @Test func crossOriginDropsCredentialsUnlessPreserved() {
        let other = target(host: "b.test")
        let stripped = RequestRouting.sanitizedHeaders(credentialedHeaders, from: target(), to: other, preserveCredentials: false)
        #expect(stripped == [HeaderField(name: "Accept", value: "*/*")])

        let preserved = RequestRouting.sanitizedHeaders(credentialedHeaders, from: target(), to: other, preserveCredentials: true)
        #expect(preserved.map(\.name) == ["Authorization", "Cookie", "Origin", "Referer", "Accept"])
    }

    @Test func sameOriginPathChangeKeepsCredentials() {
        let moved = target(path: "/elsewhere?b=2")
        #expect(RequestRouting.sameOrigin(target(), moved))
        let kept = RequestRouting.sanitizedHeaders(credentialedHeaders, from: target(), to: moved, preserveCredentials: false)
        #expect(kept.map(\.name) == ["Authorization", "Cookie", "Origin", "Referer", "Accept"])
    }

    @Test func explicitCredentialSurvivesOnlyWhenValueMatches() {
        let other = target(host: "b.test")
        let explicit = [
            HeaderField(name: "authorization", value: "Bearer secret"),
            HeaderField(name: "Cookie", value: "new=1"),
        ]
        let kept = RequestRouting.sanitizedHeaders(
            credentialedHeaders, from: target(), to: other, preserveCredentials: false,
            explicitCredentialFields: explicit)
        // Authorization matches the explicit field's value and survives; the Cookie value differs and does not.
        #expect(kept == [
            HeaderField(name: "Authorization", value: "Bearer secret"),
            HeaderField(name: "Accept", value: "*/*"),
        ])
    }

    @Test func ipv6BracketsAndCaseAreNormalised() {
        let bracketed = target(scheme: "HTTPS", host: "[::1]", port: 8443)
        let plain = target(scheme: "https", host: "::1", port: 8443)
        #expect(RequestRouting.sameOrigin(bracketed, plain))
        #expect(RequestRouting.sanitizedHeaders(credentialedHeaders, from: bracketed, to: plain, preserveCredentials: false)
            == credentialedHeaders)
        #expect(RequestRouting.normalized(target(host: "A.Test")).host == "a.test")
        #expect(RequestRouting.normalized(bracketed).host == "::1")
    }
}
