import FlowStore
import Foundation
import Testing

@testable import RulesEngine

@Suite("HandwrittenResponseParser")
struct HandwrittenResponseParserTests {
    private func parse(_ text: String, limits: RulesLimits = RulesLimits())
        -> Result<(response: GeneratedResponse, warnings: [HandwrittenResponseWarning]), HandwrittenResponseError>
    {
        HandwrittenResponse(text: text).parse(limits: limits)
    }

    private func ok(_ text: String, limits: RulesLimits = RulesLimits())
        throws -> (response: GeneratedResponse, warnings: [HandwrittenResponseWarning])
    {
        try parse(text, limits: limits).get()
    }

    private func error(_ text: String, limits: RulesLimits = RulesLimits()) -> HandwrittenResponseError? {
        if case .failure(let error) = parse(text, limits: limits) { return error }
        return nil
    }

    @Test func parsesCRLFAndLFAlike() throws {
        let crlf = try ok("HTTP/1.1 200 OK\r\nX-A: 1\r\nContent-Length: 2\r\n\r\nhi")
        let lf = try ok("HTTP/1.1 200 OK\nX-A: 1\nContent-Length: 2\n\nhi")
        #expect(crlf.response == lf.response)
        #expect(crlf.response.status == 200)
        #expect(crlf.response.body == Data("hi".utf8))
        #expect(crlf.warnings.isEmpty)
        #expect(crlf.response.headers == [HeaderField(name: "X-A", value: "1"), HeaderField(name: "Content-Length", value: "2")])
        #expect(crlf.response.kind == .handwritten)
    }

    @Test func statusLineMustBeHTTP11() {
        #expect(error("HTTP/2 200") == .unsupportedVersion)
        #expect(error("HTTP/1.0 200 OK") == .unsupportedVersion)
        #expect(error("HTTP/1.1 20 OK") == .invalidStatusLine)
        #expect(error("HTTP/1.1 2000 OK") == .invalidStatusLine)
        #expect(error("HTTP/1.1  200 OK") == .invalidStatusLine)
        #expect(error("HTTP/1.1") == .invalidStatusLine)
        #expect(error("200 OK") == .invalidStatusLine)
        #expect(error("\nHTTP/1.1 200 OK") == .invalidStatusLine)
        #expect(error("HTTP/1.1 2x0 OK") == .invalidStatusLine)
    }

    @Test func statusRange() throws {
        #expect(error("HTTP/1.1 199 X") == .invalidStatus)
        #expect(error("HTTP/1.1 600 X") == .invalidStatus)
        #expect(try ok("HTTP/1.1 200 OK").response.status == 200)
        #expect(try ok("HTTP/1.1 599 Odd").response.status == 599)
    }

    @Test func reasonDefaultsFromStatusWhenMissing() throws {
        #expect(try ok("HTTP/1.1 404").response.reason == "Not Found")
        #expect(try ok("HTTP/1.1 404 ").response.reason == "Not Found")
        #expect(try ok("HTTP/1.1 599").response.reason == "")
        #expect(try ok("HTTP/1.1 200 Fine Thanks").response.reason == "Fine Thanks")
    }

    @Test func headersAndBodySplitAtFirstBlankLine() throws {
        let result = try ok("HTTP/1.1 200 OK\nA: 1\n\nbody\n\nmore: x")
        #expect(result.response.headers.first == HeaderField(name: "A", value: "1"))
        #expect(result.response.body == Data("body\n\nmore: x".utf8))
    }

    @Test func noBlankLineMeansNoBody() throws {
        let result = try ok("HTTP/1.1 200 OK\nA: 1")
        #expect(result.response.body.isEmpty)
        #expect(result.response.headers.contains(HeaderField(name: "Content-Length", value: "0")))
    }

    @Test func bodyBytesAreVerbatim() throws {
        let body = "line1\nline2\r\n\u{4F60}\u{597D}e\u{301}"
        let result = try ok("HTTP/1.1 200 OK\r\n\r\n" + body)
        #expect(Array(result.response.body) == Array(body.utf8))
        #expect(result.response.headers.value(for: "Content-Length") == String(body.utf8.count))
    }

    @Test func contentLengthAddedWhenMissing() throws {
        let result = try ok("HTTP/1.1 200 OK\nX: 1\n\nabc")
        #expect(result.warnings == [.contentLengthAdded])
        #expect(result.response.headers == [HeaderField(name: "X", value: "1"), HeaderField(name: "Content-Length", value: "3")])
    }

    @Test func contentLengthCorrectedWhenWrong() throws {
        let result = try ok("HTTP/1.1 200 OK\nCONTENT-LENGTH: 99\nX: 1\n\nabc")
        #expect(result.warnings == [.contentLengthCorrected])
        #expect(result.response.headers == [HeaderField(name: "CONTENT-LENGTH", value: "3"), HeaderField(name: "X", value: "1")])
        let junk = try ok("HTTP/1.1 200 OK\nContent-Length: abc\n\nabc")
        #expect(junk.warnings == [.contentLengthCorrected])
        let duplicated = try ok("HTTP/1.1 200 OK\nContent-Length: 3\nContent-Length: 3\n\nabc")
        #expect(duplicated.warnings == [.contentLengthCorrected])
        #expect(duplicated.response.headers == [HeaderField(name: "Content-Length", value: "3")])
    }

    @Test func transferEncodingForbidden() {
        #expect(error("HTTP/1.1 200 OK\nTransfer-Encoding: chunked") == .forbiddenHeader(name: "Transfer-Encoding"))
        #expect(error("HTTP/1.1 200 OK\ntransfer-encoding: chunked") == .forbiddenHeader(name: "transfer-encoding"))
    }

    @Test func hopByHopHeadersForbidden() {
        for name in ["Connection", "Keep-Alive", "Proxy-Connection", "TE", "Trailer", "Upgrade"] {
            #expect(error("HTTP/1.1 200 OK\n\(name): x") == .forbiddenHeader(name: name), "\(name)")
            #expect(error("HTTP/1.1 200 OK\n\(name.lowercased()): x") == .forbiddenHeader(name: name.lowercased()))
            #expect(error("HTTP/1.1 200 OK\n\(name.uppercased()): x") == .forbiddenHeader(name: name.uppercased()))
        }
    }

    @Test func contentLengthOn204IsRejectedButAllowedOn304() throws {
        // RFC 9110 8.6: a 204 never carries Content-Length; a 304 may repeat the one of the 200.
        #expect(error("HTTP/1.1 204 No Content\nContent-Length: 0\n\n") == .bodyNotAllowed)
        #expect(error("HTTP/1.1 204 No Content\ncontent-length: 5\n\n") == .bodyNotAllowed)
        let notModified = try ok("HTTP/1.1 304 Not Modified\nContent-Length: 120\n\n")
        #expect(notModified.response.headers.value(for: "Content-Length") == "120" && notModified.warnings.isEmpty)
    }

    @Test func body204And304Rejected() throws {
        #expect(error("HTTP/1.1 204 No Content\n\nx") == .bodyNotAllowed)
        #expect(error("HTTP/1.1 304 Not Modified\r\n\r\nx") == .bodyNotAllowed)
        let empty = try ok("HTTP/1.1 204 No Content\n\n")
        #expect(empty.response.body.isEmpty)
        #expect(empty.response.headers.isEmpty)
        #expect(empty.warnings.isEmpty)
        #expect(try ok("HTTP/1.1 304 Not Modified").response.headers.isEmpty)
    }

    @Test func tooLargeAt64KiBPlusOne() throws {
        let small = RulesLimits(handwrittenResponseBytes: 64)
        let line = "HTTP/1.1 200 OK\n\n"
        let fits = line + String(repeating: "a", count: 64 - line.utf8.count)
        #expect(try ok(fits, limits: small).response.body.count == 64 - line.utf8.count)
        #expect(error(fits + "a", limits: small) == .tooLarge)
        let big = line + String(repeating: "a", count: 65_536 - line.utf8.count)
        #expect(try ok(big).response.body.count == 65_536 - line.utf8.count)
        #expect(error(big + "a") == .tooLarge)
        // The limit counts UTF-8 bytes, not characters.
        #expect(error(line + String(repeating: "\u{4F60}", count: 20), limits: small) == .tooLarge)
    }

    @Test func emptyText() {
        #expect(error("") == .empty)
    }

    @Test func headerWithoutColonReportsItsLine() {
        #expect(error("HTTP/1.1 200 OK\nA: 1\nbroken\nB: 2") == .invalidHeader(line: 3))
        #expect(error("HTTP/1.1 200 OK\r\nbroken\r\n") == .invalidHeader(line: 2))
        #expect(error("HTTP/1.1 200 OK\nA: 1\n folded") == .invalidHeader(line: 3))
        #expect(error("HTTP/1.1 200 OK\n: novalue") == .invalidHeader(line: 2))
    }

    @Test func invalidHeaderNameOrValueRejected() {
        #expect(error("HTTP/1.1 200 OK\nBad Name: 1") == .invalidHeader(line: 2))
        #expect(error("HTTP/1.1 200 OK\nA: x\u{0}y") == .invalidHeader(line: 2))
        #expect(error("HTTP/1.1 200 OK\nA: x\ry") == .invalidHeader(line: 2))
        #expect(error("HTTP/1.1 200 OK\nA\u{0}: y") == .invalidHeader(line: 2))
        #expect(error("HTTP/1.1 200 OK\n\u{FF1A}x: y") == .invalidHeader(line: 2))
    }

    @Test func headerValuesAreTrimmedAndKeptAsWritten() throws {
        let result = try ok("HTTP/1.1 200 OK\nX-A:   hello \u{4F60}e\u{301}  \nX-B:\n")
        #expect(result.response.headers.first == HeaderField(name: "X-A", value: "hello \u{4F60}e\u{301}"))
        #expect(result.response.headers.dropFirst().first == HeaderField(name: "X-B", value: ""))
    }

    @Test func forbiddenNameDetectionIsASCIIOnly() throws {
        // Kelvin sign lowercases to "k" under Unicode folding; it is still not the token "Keep-Alive".
        #expect(error("HTTP/1.1 200 OK\n\u{212A}eep-Alive: x") == .invalidHeader(line: 2))
    }
}
