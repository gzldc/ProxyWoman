import Foundation
import Testing

@testable import FlowStore

@Suite struct MessageParsingTests {
    @Test func queryItemsDecode() {
        #expect(MessageParsing.queryItems(path: "/s?q=a+b&x=%E4%B8%AD&x=2&flag") ==
            [.init(name: "q", value: "a b"), .init(name: "x", value: "中"), .init(name: "x", value: "2"), .init(name: "flag", value: "")])
    }

    @Test func queryItemsEdgeCases() {
        #expect(MessageParsing.queryItems(path: "/plain").isEmpty)
        #expect(MessageParsing.queryItems(path: "/p?").isEmpty)
        #expect(MessageParsing.queryItems(path: "/p?a=1&&b=2#frag") == [.init(name: "a", value: "1"), .init(name: "b", value: "2")])
        // 值里的 "=" 保留；%2B 解码为 "+" 而不是空格；非法百分号序列保持原样。
        #expect(MessageParsing.queryItems(path: "/p?t=a=b&p=1%2B1&bad=%zz") ==
            [.init(name: "t", value: "a=b"), .init(name: "p", value: "1+1"), .init(name: "bad", value: "%zz")])
    }

    @Test func requestCookiesParse() {
        let headers = [
            HeaderField(name: "Cookie", value: "a=1; b=2"),
            HeaderField(name: "Host", value: "x.com"),
            HeaderField(name: "cookie", value: "c=3"),
        ]
        #expect(MessageParsing.requestCookies(headers) ==
            [.init(name: "a", value: "1"), .init(name: "b", value: "2"), .init(name: "c", value: "3")])
        #expect(MessageParsing.requestCookies([]).isEmpty)
    }

    @Test func requestCookieValueKeepsEqualsSign() {
        let headers = [HeaderField(name: "Cookie", value: "tok=abc==; ; flag")]
        #expect(MessageParsing.requestCookies(headers) ==
            [.init(name: "tok", value: "abc=="), .init(name: "flag", value: "")])
    }

    @Test func responseCookiesParse() {
        let headers = [
            HeaderField(name: "Set-Cookie", value: "sid=xyz; Path=/; HttpOnly"),
            HeaderField(name: "Content-Type", value: "text/plain"),
            HeaderField(name: "set-cookie", value: "theme=dark"),
        ]
        #expect(MessageParsing.responseCookies(headers) == [
            ResponseCookie(name: "sid", value: "xyz", attributes: ["Path=/", "HttpOnly"]),
            ResponseCookie(name: "theme", value: "dark", attributes: []),
        ])
    }
}
