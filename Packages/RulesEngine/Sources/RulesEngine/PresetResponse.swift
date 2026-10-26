import FlowStore
import Foundation

/// A ready-made response chosen from a list.
public struct PresetResponse: Codable, Sendable, Equatable, Hashable {
    public enum Preset: String, Codable, Sendable, CaseIterable {
        case emptyHTML200, gif200, noContent204
        case movedPermanently301, found302, seeOther303, notModified304, temporaryRedirect307, permanentRedirect308
        case badRequest400, unauthorized401, forbidden403, notFound404, proxyAuthRequired407, tooManyRequests429
        case internalError500, serviceUnavailable503
        // Appended in R8F2 (raw values only ever grow).
        /// 200 with a 1x1 transparent GIF that browsers must not cache ("200 OK (Pixel)").
        case transparentPixel200
        /// 401 with a Digest challenge instead of the Basic one.
        case digestAuth401
        /// 502 for an unreachable server, no body.
        case unreachable502
    }

    public var preset: Preset
    /// Optional text body (UTF-8) for presets that may carry one.
    public var body: String?
    /// Required by the redirect presets.
    public var location: String?
    /// Overrides the default `WWW-Authenticate` / `Proxy-Authenticate` challenge of 401 / 407.
    public var challenge: String?

    public init(preset: Preset, body: String? = nil, location: String? = nil, challenge: String? = nil) {
        self.preset = preset
        self.body = body
        self.location = location
        self.challenge = challenge
    }
}

extension PresetResponse {
    public enum BuildError: Error, Equatable, Sendable {
        case locationRequired, invalidLocation, invalidField
    }

    /// 301 / 302 / 303 / 307 / 308.
    public var requiresLocation: Bool {
        switch preset {
        case .movedPermanently301, .found302, .seeOther303, .temporaryRedirect307, .permanentRedirect308: true
        default: false
        }
    }

    /// Everything except the redirects, 204 and 304.
    public var acceptsBody: Bool {
        switch preset {
        case .movedPermanently301, .found302, .seeOther303, .temporaryRedirect307, .permanentRedirect308,
            .noContent204, .notModified304: false
        default: true
        }
    }

    /// The 43-byte transparent 1x1 GIF.
    private static let gifBytes: [UInt8] = [
        0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xFF, 0xFF, 0xFF, 0x21, 0xF9, 0x04, 0x01, 0x00, 0x00, 0x00, 0x00, 0x2C, 0x00, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x01, 0x00, 0x00, 0x02, 0x02, 0x44, 0x01, 0x00, 0x3B,
    ]

    /// The Digest challenge of `digestAuth401`: realm, qop `auth`, and a fixed nonce and opaque (any
    /// string is valid; a fixed one keeps the bytes the same every time).
    private static let digestChallenge =
        #"Digest realm="ProxyWoman", qop="auth", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", "#
        + #"opaque="5ccc069c403ebaf9f0171e9517f40e41""#

    private static let plainText = "text/plain; charset=utf-8"

    private var status: Int {
        switch preset {
        case .emptyHTML200, .gif200, .transparentPixel200: 200
        case .noContent204: 204
        case .movedPermanently301: 301
        case .found302: 302
        case .seeOther303: 303
        case .notModified304: 304
        case .temporaryRedirect307: 307
        case .permanentRedirect308: 308
        case .badRequest400: 400
        case .unauthorized401, .digestAuth401: 401
        case .forbidden403: 403
        case .notFound404: 404
        case .proxyAuthRequired407: 407
        case .tooManyRequests429: 429
        case .internalError500: 500
        case .serviceUnavailable503: 503
        case .unreachable502: 502
        }
    }

    /// Traffic content, not UI text: fixed ASCII constants.
    public func build() -> Result<GeneratedResponse, BuildError> {
        var headers: [HeaderField] = []
        var body = Data()
        if requiresLocation {
            guard let location, !location.utf8.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) else { return .failure(.locationRequired) }
            guard HTTPMutationValidator.isValidValue(location) else { return .failure(.invalidLocation) }
            headers.append(HeaderField(name: "Location", value: location))
            headers.append(HeaderField(name: "Content-Length", value: "0"))
        } else if !acceptsBody {
            if let bodyText = self.body, !bodyText.isEmpty { return .failure(.invalidField) }
        } else {
            let contentType: String
            switch preset {
            case .emptyHTML200: contentType = "text/html; charset=utf-8"
            case .gif200, .transparentPixel200: contentType = "image/gif"
            default: contentType = Self.plainText
            }
            if let bodyText = self.body, !bodyText.isEmpty {
                body = Data(bodyText.utf8)
            } else if preset == .gif200 || preset == .transparentPixel200 {
                body = Data(Self.gifBytes)
            }
            headers.append(HeaderField(name: "Content-Type", value: contentType))
            headers.append(HeaderField(name: "Content-Length", value: String(body.count)))
            if preset == .transparentPixel200 {
                headers.append(HeaderField(name: "Cache-Control", value: "no-store"))
            }
            if preset == .unauthorized401 || preset == .digestAuth401 || preset == .proxyAuthRequired407 {
                let name = preset == .proxyAuthRequired407 ? "Proxy-Authenticate" : "WWW-Authenticate"
                var value = preset == .digestAuth401 ? Self.digestChallenge : #"Basic realm="ProxyWoman""#
                if let challenge, !challenge.isEmpty {
                    guard HTTPMutationValidator.isValidValue(challenge) else { return .failure(.invalidField) }
                    value = challenge
                }
                headers.append(HeaderField(name: name, value: value))
            }
        }
        let status = self.status
        return .success(GeneratedResponse(
            status: status, reason: GeneratedResponse.standardReason(for: status), headers: headers, body: body,
            kind: .preset(preset)))
    }
}
