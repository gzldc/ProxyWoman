import Foundation
import Testing
@testable import Viewers

struct JWTDecoderTests {
    // {"alg":"HS256","typ":"JWT"} . {"sub":"42","name":"Ada","iat":1700000000,"exp":1700003600} . signature
    static let token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
        + ".eyJzdWIiOiI0MiIsIm5hbWUiOiJBZGEiLCJpYXQiOjE3MDAwMDAwMDAsImV4cCI6MTcwMDAwMzYwMH0"
        + ".c2lnbmF0dXJl"

    @Test func decodesHeaderPayloadAndTimes() throws {
        let jwt = try #require(JWTDecoder.decode(Self.token, source: "Authorization"))
        #expect(jwt.algorithm == "HS256")
        #expect(jwt.header.contains("\"typ\" : \"JWT\""))
        #expect(jwt.payload.contains("\"name\" : \"Ada\""))
        #expect(jwt.issuedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(jwt.expiresAt == Date(timeIntervalSince1970: 1_700_003_600))
        #expect(jwt.isExpired(now: Date(timeIntervalSince1970: 1_700_003_600)))
        #expect(!jwt.isExpired(now: Date(timeIntervalSince1970: 1_700_000_001)))
    }

    @Test func findsTokensInBearerCookieAndQueryOnce() {
        let found = JWTDecoder.find(in: [
            ("Authorization", "Bearer \(Self.token)"),
            ("Cookie: session", Self.token),
            ("Query: t", "\(Self.token)&x=1"),
        ])
        #expect(found.map(\.source) == ["Authorization"])
        #expect(found.first?.token == Self.token)
    }

    @Test(arguments: ["abc.def.ghi", "eyJub3Q.anNvbg.x", "eyJhbGciOiJub25lIn0.bm90LWpzb24.", "1.2.3.4.5"])
    func rejectsStringsThatAreNotJWTs(_ value: String) {
        #expect(JWTDecoder.find(in: [("Header", value)]).isEmpty)
    }

    @Test func unsignedTokenWithEmptySignatureIsStillDecoded() throws {
        // {"alg":"none"} . {"a":1} .
        let jwt = try #require(JWTDecoder.decode("eyJhbGciOiJub25lIn0.eyJhIjoxfQ.", source: "X"))
        #expect(jwt.algorithm == "none")
        #expect(jwt.expiresAt == nil)
        #expect(!jwt.isExpired())
    }
}
