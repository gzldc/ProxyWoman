import FlowStore
import Foundation
import Testing

@testable import RulesEngine

@Suite("PresetResponse")
struct PresetResponseTests {
    private func build(_ preset: PresetResponse.Preset, body: String? = nil, location: String? = nil,
                       challenge: String? = nil) -> Result<GeneratedResponse, PresetResponse.BuildError> {
        PresetResponse(preset: preset, body: body, location: location, challenge: challenge).build()
    }

    private func response(_ preset: PresetResponse.Preset, body: String? = nil, location: String? = nil,
                          challenge: String? = nil) throws -> GeneratedResponse {
        try build(preset, body: body, location: location, challenge: challenge).get()
    }

    private static let text = "text/plain; charset=utf-8"

    /// preset, status, reason, Content-Type (nil = none), needs a Location.
    private static let table: [(PresetResponse.Preset, Int, String, String?, Bool)] = [
        (.emptyHTML200, 200, "OK", "text/html; charset=utf-8", false),
        (.gif200, 200, "OK", "image/gif", false),
        (.noContent204, 204, "No Content", nil, false),
        (.movedPermanently301, 301, "Moved Permanently", nil, true),
        (.found302, 302, "Found", nil, true),
        (.seeOther303, 303, "See Other", nil, true),
        (.notModified304, 304, "Not Modified", nil, false),
        (.temporaryRedirect307, 307, "Temporary Redirect", nil, true),
        (.permanentRedirect308, 308, "Permanent Redirect", nil, true),
        (.badRequest400, 400, "Bad Request", text, false),
        (.unauthorized401, 401, "Unauthorized", text, false),
        (.forbidden403, 403, "Forbidden", text, false),
        (.notFound404, 404, "Not Found", text, false),
        (.proxyAuthRequired407, 407, "Proxy Authentication Required", text, false),
        (.tooManyRequests429, 429, "Too Many Requests", text, false),
        (.internalError500, 500, "Internal Server Error", text, false),
        (.serviceUnavailable503, 503, "Service Unavailable", text, false),
        (.transparentPixel200, 200, "OK", "image/gif", false),
        (.digestAuth401, 401, "Unauthorized", text, false),
        (.unreachable502, 502, "Bad Gateway", text, false),
    ]

    @Test func allPresetsBuild() throws {
        #expect(Self.table.count == 20)
        #expect(Set(Self.table.map(\.0)) == Set(PresetResponse.Preset.allCases))
        for (preset, status, reason, contentType, needsLocation) in Self.table {
            let built = try response(preset, location: needsLocation ? "https://example.com/next" : nil)
            #expect(built.status == status, "\(preset)")
            #expect(built.reason == reason, "\(preset)")
            #expect(built.kind == .preset(preset))
            #expect(built.headers.value(for: "Content-Type") == contentType, "\(preset)")
            #expect(PresetResponse(preset: preset).requiresLocation == needsLocation)
            if status != 204 && status != 304 {
                #expect(built.headers.value(for: "Content-Length") == String(built.body.count), "\(preset)")
            }
            if status == 204 || status == 304 {
                #expect(built.headers.value(for: "Content-Length") == nil)
                #expect(built.body.isEmpty)
            }
        }
    }

    @Test func redirectsRequireLocation() {
        for preset in [PresetResponse.Preset.movedPermanently301, .found302, .seeOther303, .temporaryRedirect307, .permanentRedirect308] {
            #expect(build(preset) == .failure(.locationRequired))
            #expect(build(preset, location: "") == .failure(.locationRequired))
            #expect(build(preset, location: "/a\r\nSet-Cookie: x=1") == .failure(.invalidLocation))
            #expect(build(preset, location: "/a\nb") == .failure(.invalidLocation))
            #expect(build(preset, location: "/a\u{0}") == .failure(.invalidLocation))
            #expect((try? response(preset, location: "/a\u{4F60}?x=1").headers.value(for: "Location")) == "/a\u{4F60}?x=1")
        }
    }

    @Test func redirectsIgnoreBody() throws {
        let built = try response(.found302, body: "ignored", location: "/x")
        #expect(built.body.isEmpty)
        #expect(built.headers.value(for: "Content-Type") == nil)
        #expect(built.headers.value(for: "Content-Length") == "0")
        #expect(built.headers.value(for: "Location") == "/x")
    }

    @Test func unauthorizedCarriesDefaultChallenge() throws {
        let built = try response(.unauthorized401)
        #expect(built.headers.value(for: "WWW-Authenticate") == #"Basic realm="ProxyWoman""#)
        #expect(built.headers.value(for: "Proxy-Authenticate") == nil)
    }

    @Test func proxyAuthRequiredUsesProxyAuthenticate() throws {
        let built = try response(.proxyAuthRequired407)
        #expect(built.headers.value(for: "Proxy-Authenticate") == #"Basic realm="ProxyWoman""#)
        #expect(built.headers.value(for: "WWW-Authenticate") == nil)
    }

    @Test func challengeOverrides() throws {
        #expect(try response(.unauthorized401, challenge: "Bearer").headers.value(for: "WWW-Authenticate") == "Bearer")
        #expect(try response(.proxyAuthRequired407, challenge: "Digest").headers.value(for: "Proxy-Authenticate") == "Digest")
        #expect(build(.unauthorized401, challenge: "Bearer\r\nX: y") == .failure(.invalidField))
        #expect(try response(.forbidden403, challenge: "Bearer").headers.value(for: "WWW-Authenticate") == nil)
    }

    @Test func noContentAndNotModifiedHaveNoBody() throws {
        for preset in [PresetResponse.Preset.noContent204, .notModified304] {
            let built = try response(preset)
            #expect(built.body.isEmpty)
            #expect(built.headers.isEmpty)
            #expect(!PresetResponse(preset: preset).acceptsBody)
        }
    }

    @Test func gifBodyIsTheKnown43ByteGIF() throws {
        let built = try response(.gif200)
        #expect(built.body.count == 43)
        #expect(Array(built.body.prefix(6)) == Array("GIF89a".utf8))
        #expect(built.body.last == 0x3B)
        #expect(built.headers.value(for: "Content-Length") == "43")
    }

    @Test func emptyGifBodyFallsBackToTheDefaultGIF() throws {
        let built = try response(.gif200, body: "")
        #expect(built.body.count == 43 && built.headers.value(for: "Content-Length") == "43")
        #expect(try response(.gif200, body: "GIF").body == Data("GIF".utf8))
    }

    @Test func whitespaceOnlyLocationIsMissing() {
        for preset: PresetResponse.Preset in [.movedPermanently301, .found302, .temporaryRedirect307] {
            for blank in [" ", "   ", "\t", " \t "] {
                #expect(build(preset, location: blank) == .failure(.locationRequired), "\(preset) \(blank.debugDescription)")
            }
        }
    }

    @Test func bodyOnlyWhereAccepted() throws {
        let forbidden = try response(.forbidden403, body: "no entry \u{4F60}")
        #expect(forbidden.body == Data("no entry \u{4F60}".utf8))
        #expect(forbidden.headers.value(for: "Content-Length") == String(forbidden.body.count))
        #expect(try response(.emptyHTML200, body: "<p>x</p>").body == Data("<p>x</p>".utf8))
        #expect(try response(.notFound404).body.isEmpty)
        #expect(build(.noContent204, body: "x") == .failure(.invalidField))
        #expect(build(.notModified304, body: "x") == .failure(.invalidField))
        #expect(try response(.noContent204, body: "").body.isEmpty)
        #expect(PresetResponse(preset: .forbidden403).acceptsBody)
        #expect(PresetResponse(preset: .gif200).acceptsBody)
        #expect(!PresetResponse(preset: .found302).acceptsBody)
    }

    @Test func requiresLocationCoversExactlyTheFiveRedirects() {
        let required = PresetResponse.Preset.allCases.filter { PresetResponse(preset: $0).requiresLocation }
        #expect(Set(required) == [.movedPermanently301, .found302, .seeOther303, .temporaryRedirect307, .permanentRedirect308])
    }
}
