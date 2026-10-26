import FlowStore
import Foundation
import Testing

@testable import RulesEngine

@Suite("MessageFieldReaders")
struct MessageFieldReaderTests {
    private func h(_ name: String, _ value: String) -> HeaderField { HeaderField(name: name, value: value) }

    @Test func headerNameIsCaseInsensitiveAndFirstWins() {
        let headers = [h("X-A", "one"), h("x-a", "two")]
        #expect(MessageFields.header("x-A", in: headers) == "one")
    }

    @Test func missingHeaderIsNil() {
        #expect(MessageFields.header("X", in: [h("Y", "1")]) == nil)
        #expect(MessageFields.header("X", in: []) == nil)
    }

    @Test func cookieNameIsCaseSensitive() {
        let headers = [h("Cookie", "Sid=1; sid=2")]
        #expect(MessageFields.cookie("sid", inRequestHeaders: headers) == "2")
        #expect(MessageFields.cookie("SID", inRequestHeaders: headers) == nil)
    }

    @Test func duplicateCookieTakesTheFirst() {
        #expect(MessageFields.cookie("a", inRequestHeaders: [h("cookie", "a=1; b=2; a=3")]) == "1")
    }

    @Test func cookieValueMayContainEquals() {
        #expect(MessageFields.cookie("t", inRequestHeaders: [h("Cookie", "t=abc==; u=1")]) == "abc==")
    }

    @Test func cookieAbsentIsNil() {
        #expect(MessageFields.cookie("z", inRequestHeaders: [h("Cookie", "a=1")]) == nil)
        #expect(MessageFields.cookie("z", inRequestHeaders: []) == nil)
    }

    @Test func setCookieSearchesEveryLine() {
        let headers = [h("Set-Cookie", "a=1; Path=/"), h("set-cookie", "b=2"), h("Other", "c=3")]
        #expect(MessageFields.setCookie("b", inResponseHeaders: headers) == "2")
        #expect(MessageFields.setCookie("c", inResponseHeaders: headers) == nil)
    }

    @Test func setCookieStopsAtAttributes() {
        #expect(MessageFields.setCookie("a", inResponseHeaders: [h("Set-Cookie", "a=1; Path=/")]) == "1")
        #expect(MessageFields.setCookie("Path", inResponseHeaders: [h("Set-Cookie", "a=1; Path=/")]) == nil)
    }

    @Test func queryParamPercentDecodesNameAndValue() {
        #expect(MessageFields.queryParam("a b", inPathAndQuery: "/p?a%20b=c%26d") == "c&d")
    }

    @Test func queryParamKeepsPlusAsPlus() {
        #expect(MessageFields.queryParam("q", inPathAndQuery: "/p?q=a+b") == "a+b")
    }

    @Test func queryParamFirstOfDuplicatesWins() {
        #expect(MessageFields.queryParam("a", inPathAndQuery: "/p?a=1&a=2") == "1")
        #expect(MessageFields.queryParam("A", inPathAndQuery: "/p?a=1") == nil)
    }

    @Test func queryParamWithoutValueIsEmptyString() {
        #expect(MessageFields.queryParam("flag", inPathAndQuery: "/p?flag&x=1") == "")
        #expect(MessageFields.queryParam("flag", inPathAndQuery: "/p?flag=&x=1") == "")
    }

    @Test func queryParamAbsentIsNil() {
        #expect(MessageFields.queryParam("a", inPathAndQuery: "/p") == nil)
        #expect(MessageFields.queryParam("a", inPathAndQuery: "/p?b=1") == nil)
    }

    @Test func queryParamValueMayContainEquals() {
        #expect(MessageFields.queryParam("a", inPathAndQuery: "/p?a=b=c") == "b=c")
    }

    @Test func pathAndQueryStringSplit() {
        #expect(MessageFields.path(of: "/a?b=1#x") == "/a")
        #expect(MessageFields.queryString(of: "/a?b=1#x") == "b=1")
        #expect(MessageFields.path(of: "/a") == "/a")
        #expect(MessageFields.queryString(of: "/a") == "")
        #expect(MessageFields.path(of: "*") == "*")
        #expect(MessageFields.queryString(of: "*") == "")
        #expect(MessageFields.queryString(of: "/a?") == "")
        #expect(MessageFields.queryString(of: "/a?b=1?c=2") == "b=1?c=2")
    }

    @Test func httpVersionLabels() {
        #expect(MessageFields.httpVersionLabel(.http1_0) == "h1")
        #expect(MessageFields.httpVersionLabel(.http1_1) == "h1")
        #expect(MessageFields.httpVersionLabel(.http2) == "h2")
    }

    private func target(_ path: String, method: String = "GET") -> HTTPMessageTarget {
        HTTPMessageTarget(scheme: "https", host: "e.com", port: 443, method: method, pathAndQuery: path)
    }

    private let ws = [HeaderField(name: "Upgrade", value: "websocket"), HeaderField(name: "Connection", value: "keep-alive, Upgrade")]
    private let grpc = [HeaderField(name: "Content-Type", value: "application/grpc+proto")]
    private let sse = [HeaderField(name: "content-type", value: "text/event-stream; charset=utf-8")]

    @Test func appProtocolPriority() {
        func p(_ req: [HeaderField], _ path: String = "/", _ res: [HeaderField]? = nil) -> String {
            MessageFields.appProtocol(requestHeaders: req, target: target(path), responseHeaders: res)
        }
        #expect(p([]) == "http")
        #expect(p(ws) == "websocket")
        #expect(p(grpc) == "grpc")
        #expect(p([], "/socket.io/?EIO=4") == "socketio")
        #expect(p([], "/", sse) == "sse")
        // Two classes at once: the higher one wins.
        #expect(p(ws + grpc) == "websocket")
        // R8F2-5: websocket > socketio > grpc > rpc > sse > http.
        #expect(p(grpc, "/socket.io/") == "socketio")
        #expect(p(ws, "/socket.io/") == "websocket")
        #expect(p([], "/socket.io/", sse) == "socketio")
        #expect(p(grpc, "/", sse) == "grpc")
        #expect(p(ws, "/", sse) == "websocket")
    }

    @Test func websocketNeedsBothHeaders() {
        let onlyUpgrade = [HeaderField(name: "Upgrade", value: "websocket")]
        #expect(MessageFields.appProtocol(requestHeaders: onlyUpgrade, target: target("/"), responseHeaders: nil) == "http")
    }

    @Test func socketIOChecksThePathNotTheQuery() {
        #expect(MessageFields.appProtocol(requestHeaders: [], target: target("/x?u=/socket.io/"), responseHeaders: nil) == "http")
        #expect(MessageFields.appProtocol(requestHeaders: [], target: target("/api/socket.io/"), responseHeaders: nil) == "http")
        #expect(MessageFields.appProtocol(requestHeaders: [], target: target("/socket.io/?x=1"), responseHeaders: nil) == "socketio")
    }
}
