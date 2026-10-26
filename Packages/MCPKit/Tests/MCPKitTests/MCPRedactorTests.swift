import FlowStore
import Foundation
import Testing

@testable import MCPKit

@Suite struct MCPRedactorTests {
    private let on = MCPRedactor(MCPRedactionSettings())
    private let off = MCPRedactor(MCPRedactionSettings(enabled: false, extraNames: ["foo"]))
    private let R = MCPRedactor.redactedValue

    private func snapshot(_ headers: [HeaderField]) -> HTTPMessageSnapshot {
        HTTPMessageSnapshot(
            boundary: .downstreamRequest,
            head: .request(
                HTTPMessageTarget(scheme: "https", host: "h", port: 443, method: "GET", pathAndQuery: "/"),
                headers: headers))
    }

    private func h(_ name: String, _ value: String = "v") -> HeaderField { HeaderField(name: name, value: value) }

    @Test func redactsAuthorizationCookieSetCookieCaseInsensitively() {
        let input = [
            h("Authorization", "Bearer abc"), h("proxy-authorization", "x"), h("COOKIE", "a=b"),
            h("Set-Cookie", "s=1; Path=/"), h("Set-Cookie", "t=2"), h("x-api-key", "k"),
            h("X-Auth-Token", "t"), h("X-CSRF-Token", "c"), h("X-Amz-Security-Token", "z"),
            h("Accept", "*/*"), h("Content-Type", "application/json"),
        ]
        let out = on.headers(input)
        #expect(out.map(\.name) == input.map(\.name))
        #expect(out.prefix(9).allSatisfy { $0.value == R })
        #expect(out[9].value == "*/*")
        #expect(out[10].value == "application/json")
    }

    @Test func redactsHeadersWithTokenInName() {
        let out = on.headers([
            h("X-My-Token", "1"), h("Client-Secret", "2"), h("X-PassWord-Hint", "3"), h("X-ApiKey", "4"),
            h("X-Request-Id", "5"),
        ])
        #expect(out.map(\.value) == [R, R, R, R, "5"])
    }

    @Test func extraNamesApplyToHeadersQueryAndBody() {
        let r = MCPRedactor(MCPRedactionSettings(enabled: true, extraNames: [" X-Mine ", "Pin"]))
        #expect(r.headers([h("x-mine", "1"), h("Other", "2")]).map(\.value) == [R, "2"])
        #expect(r.url("/p?pin=1234&a=b") == "/p?pin=\(R)&a=b")
        #expect(
            r.bodyText(#"{"PIN":"1234","a":"b"}"#, contentType: "application/json") == #"{"PIN":"\#(R)","a":"b"}"#)
        #expect(r.bodyText("pin=1&a=b", contentType: "application/x-www-form-urlencoded") == "pin=\(R)&a=b")
    }

    @Test func urlRedactsSensitiveQueryKeysOnly() {
        #expect(on.url("/a?id=1&token=abc&x=%20y#f") == "/a?id=1&token=\(R)&x=%20y#f")
        #expect(
            on.url("https://h/p?Access_Token=a&KEY=b&sig=c&code=d&auth=e&session=f&sessionid=g&pwd=h&passwd=i&secret=j&api_key=k&apikey=l&id_token=m&refresh_token=n&password=o&signature=p&keep=q")
                == "https://h/p?"
                + ["Access_Token", "KEY", "sig", "code", "auth", "session", "sessionid", "pwd", "passwd", "secret", "api_key", "apikey", "id_token", "refresh_token", "password", "signature"]
                .map { "\($0)=\(R)" }.joined(separator: "&") + "&keep=q")
        // percent-encoded key, empty value, valueless key, repeated keys, fragment containing '?'
        #expect(on.url("/a?%74oken=abc&token=&flag&token=2&&x=1#f?token=zz") == "/a?%74oken=\(R)&token=\(R)&flag&token=\(R)&&x=1#f?token=\(R)")
    }

    @Test func urlWithoutQueryIsUntouched() {
        for u in ["/a/b", "", "/a?", "/a?#f", "/token=1", "/a#frag", "/a?x=1#y=2"] {
            #expect(on.url(u) == u)
        }
    }

    @Test func jsonBodyRedactsStringValuesOfSensitiveKeysIncludingNested() throws {
        let body = """
            {
              "user": "bob" ,"password" : "p\\"w" ,
              "nested": {"Token":"t1", "list":[{"secret":"s","n":1}], "note":"password"},
              "x\\u0041":"y"
            }
            """
        let out = on.bodyText(body, contentType: "application/json; charset=utf-8")
        let expected = body
            .replacingOccurrences(of: #""p\"w""#, with: "\"\(R)\"")
            .replacingOccurrences(of: #""t1""#, with: "\"\(R)\"")
            .replacingOccurrences(of: #""s""#, with: "\"\(R)\"")
        #expect(out == expected)
        let parsed = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
        #expect((parsed?["password"] as? String) == R)
        #expect(((parsed?["nested"] as? [String: Any])?["note"] as? String) == "password")
        // vendor +json type, and a truncated prefix must not crash or leak
        #expect(on.bodyText(#"{"token":"abc"#, contentType: "application/vnd.api+json") == #"{"token":"\#(R)""#)
    }

    @Test func jsonSensitiveKeysMaskAnyValueShapeAndStayValidJSON() throws {
        let body = #"{"a": 1, "token": {"x": ["y", {"z": "}"}], "w": "\"]"}, "code": 200, "key": null, "secret": true, "password": [1, 2], "s": "ok", "tail": 5}"#
        let out = on.bodyText(body, contentType: "application/json")
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        for key in ["token", "code", "key", "secret", "password"] { #expect((parsed[key] as? String) == R, "\(key)") }
        #expect(parsed["a"] as? Int == 1)
        #expect(parsed["s"] as? String == "ok")
        #expect(parsed["tail"] as? Int == 5)
        // empty value after a sensitive key and truncated containers
        #expect(on.bodyText(#"{"token":"#, contentType: "application/json") == #"{"token":"#)
        #expect(!on.bodyText(#"{"token":{"a":"zzz"#, contentType: "application/json").contains("zzz"))
    }

    @Test func escapedSensitiveJSONKeyIsRedacted() {
        let out = on.bodyText(#"{"pass\u0077ord":"x","pa\"ss":"y"}"#, contentType: "application/json")
        #expect(out == #"{"pass\u0077ord":"\#(R)","pa\"ss":"y"}"#)
    }

    @Test func formBodyRedacts() {
        let out = on.bodyText("user=bob&password=p%40ss&token=&x=1", contentType: "application/x-www-form-urlencoded; charset=UTF-8")
        #expect(out == "user=bob&password=\(R)&token=\(R)&x=1")
    }

    @Test func textWithoutSecretLookingKeysIsByteIdentical() {
        let samples = ["plain words, a=b c", "<html><body>hi</body></html>", "line1\nline2", #"{"a":"b"}"#]
        for type in [nil, "text/plain", "text/html", "multipart/form-data; boundary=x", "application/octet-stream"] {
            for sample in samples { #expect(on.bodyText(sample, contentType: type) == sample) }
        }
    }

    @Test func secretsAreRedactedWhateverTheContentType() {
        let json = #"{"password":"x","a":"b"}"#
        let masked = #"{"password":"\#(R)","a":"b"}"#
        for type in [nil, "text/plain", "text/html", "application/javascript", "text/event-stream", "application/octet-stream"] {
            #expect(on.bodyText(json, contentType: type) == masked)
        }
        #expect(on.bodyText(#"cb({"token":"abc"});"#, contentType: "application/javascript") == #"cb({"token":"\#(R)"});"#)
        #expect(on.bodyText("data: {\"access_token\":\"t\"}\n\n", contentType: "text/event-stream") == "data: {\"access_token\":\"\(R)\"}\n\n")
        // text/plain shaped like a form
        #expect(on.bodyText("user=bob&password=x", contentType: "text/plain") == "user=bob&password=\(R)")
    }

    @Test func markupElementsAndAttributesAreRedacted() {
        #expect(
            on.bodyText("<login><user>bob</user><Password>x &amp; y</Password><ns:apiKey>k</ns:apiKey><token/></login>", contentType: "application/xml")
                == "<login><user>bob</user><Password>\(R)</Password><ns:apiKey>\(R)</ns:apiKey><token/></login>")
        #expect(
            on.bodyText(#"<form><input type="text" name="user" value="bob"><input type=password name='password' value="s3"><meta name="csrf-token" content="c"><div data-token="t"></div></form>"#, contentType: "text/html")
                == #"<form><input type="text" name="user" value="bob"><input type=password name='password' value="\#(R)"><meta name="csrf-token" content="\#(R)"><div data-token="\#(R)"></div></form>"#)
        // unterminated sensitive element is masked to the end
        #expect(!on.bodyText("<xml><password>hunter2", contentType: "text/xml").contains("hunter2"))
        // sniffed markup under text/plain
        #expect(on.bodyText("<a><secret>s</secret></a>", contentType: "text/plain") == "<a><secret>\(R)</secret></a>")
    }

    @Test func multipartTextPartsAreRedacted() {
        let body = "--b\r\nContent-Disposition: form-data; name=\"user\"\r\n\r\nbob\r\n--b\r\nContent-Disposition: form-data; name=\"password\"\r\n\r\nhunter2\r\n--b--\r\n"
        let out = on.bodyText(body, contentType: "multipart/form-data; boundary=b")
        #expect(!out.contains("hunter2"))
        #expect(out.contains("bob"))
    }

    @Test func keyVariantsAreSensitive() {
        let names = [
            "accessToken", "client_secret", "authenticity_token", "new_password", "password_confirmation",
            "user[password]", "X-Amz-Security-Token", "X-Amz-Signature", "X-Amz-Credential", "Api-Key",
            "X-Goog-Api-Key", "Ocp-Apim-Subscription-Key", "Access-Token", "refreshToken", "sessionId", "API_KEY",
        ]
        for name in names {
            #expect(on.headers([h(name, "v")]).first?.value == R, "header \(name)")
            let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
            #expect(on.url("/p?\(encoded)=v&keep=1") == "/p?\(encoded)=\(R)&keep=1", "query \(name)")
            #expect(on.bodyText("\(name)=v&keep=1", contentType: "application/x-www-form-urlencoded") == "\(name)=\(R)&keep=1", "form \(name)")
            #expect(on.bodyText("{\"\(name)\":\"v\",\"keep\":1}", contentType: "application/json") == "{\"\(name)\":\"\(R)\",\"keep\":1}", "json \(name)")
        }
        let presigned = "https://b.s3.amazonaws.com/o?X-Amz-Algorithm=AWS4&X-Amz-Credential=AK%2F2026&X-Amz-Security-Token=ST&X-Amz-Signature=sig&X-Amz-Date=2026"
        let out = on.url(presigned)
        #expect(out.contains("X-Amz-Algorithm=AWS4") && out.contains("X-Amz-Date=2026"))
        #expect(!out.contains("AK%2F2026") && !out.contains("=ST") && !out.contains("=sig"))
        #expect(on.headers([h("Accept", "x"), h("Content-Length", "3"), h("User-Agent", "u")]).map(\.value) == ["x", "3", "u"])
    }

    @Test func extraNamesMatchNormalizedAndAsSubstrings() {
        let r = MCPRedactor(MCPRedactionSettings(enabled: true, extraNames: ["Pin Code", "ssn"]))
        #expect(r.url("/p?pin_code=1&userSSN=2&a=3") == "/p?pin_code=\(R)&userSSN=\(R)&a=3")
    }

    @Test func urlCarryingHeadersAreScrubbed() {
        let out = on.headers([
            h("Location", "https://h/cb?code=abc&state=1"), h("Referer", "https://h/p?token=t&x=1#f"),
            h("Content-Location", "/a?api_key=k"),
            h("Link", #"<https://h/p?page=2&access_token=zz>; rel="next", <https://h/q?secret=s>; rel="prev""#),
            h("Refresh", "0; url=/next?password=p&a=b"),
        ])
        #expect(out[0].value == "https://h/cb?code=\(R)&state=1")
        #expect(out[1].value == "https://h/p?token=\(R)&x=1#f")
        #expect(out[2].value == "/a?api_key=\(R)")
        #expect(out[3].value == #"<https://h/p?page=2&access_token=\#(R)>; rel="next", <https://h/q?secret=\#(R)>; rel="prev""#)
        #expect(out[4].value == "0; url=/next?password=\(R)&a=b")
    }

    @Test func urlHeadersScanTheWholeValueIncludingFragments() {
        let out = on.headers([
            h("Location", "/cb?fields=a,b&token=abc"),
            h("Location", "https://app/cb#access_token=abc&state=1&token_type=bearer"),
            h("Referer", "https://app/p?a=1;b=2&code=zz'q#frag&id_token=t"),
            h("Refresh", "0; url=/x?token=abc"),
            h("Content-Location", "https://h/p#/route?token=abc"),
            h("Location", "/plain?x=1,2#top"),
        ])
        #expect(out[0].value == "/cb?fields=a,b&token=\(R)")
        #expect(out[1].value == "https://app/cb#access_token=\(R)&state=1&token_type=\(R)")
        #expect(out[2].value == "https://app/p?a=1;b=2&code=\(R)#frag&id_token=\(R)")
        #expect(out[3].value == "0; url=/x?token=\(R)")
        #expect(out[4].value == "https://h/p#/route?token=\(R)")
        #expect(out[5].value == "/plain?x=1,2#top")
        // flow note and failure text are scanned the same way
        var flow = Flow(id: 1, scheme: "http", method: "GET", host: "h", port: 80, path: "/p#access_token=abc")
        flow.note = "went to /x?a=1,2&token=n"
        flow.state = .failed("bad redirect https://h/c#access_token=f&x=1")
        let copy = on.flow(flow)
        #expect(copy.path == "/p#access_token=\(R)")
        #expect(copy.note == "went to /x?a=1,2&token=\(R)")
        #expect(copy.state == .failed("bad redirect https://h/c#access_token=\(R)&x=1"))
    }

    @Test func urlRedactsFragmentPairs() {
        #expect(on.url("https://h/p#token=1") == "https://h/p#token=\(R)")
        #expect(on.url("/a?x=1#state=s&id_token=t") == "/a?x=1#state=s&id_token=\(R)")
    }

    @Test func malformedPercentEncodingFailsClosed() {
        #expect(on.url("/p?to%ken=abc&x=%zz&token=1&%ZZ%74oken=2") == "/p?to%ken=\(R)&x=%zz&token=\(R)&%ZZ%74oken=\(R)")
        #expect(on.url("/p?y=%&z=%4") == "/p?y=%&z=%4")
    }

    @Test func moreCredentialNames() {
        for name in ["private_key", "aws_access_key", "JSESSIONID", "PHPSESSID", "sid", "session_id", "sessid", "access-key"] {
            #expect(on.url("/p?\(name)=v&keep=1") == "/p?\(name)=\(R)&keep=1", "\(name)")
            #expect(on.headers([h(name, "v")]).first?.value == R, "header \(name)")
        }
    }

    @Test func nestedSameNameElementDoesNotLeakTrailingText() {
        let out = on.bodyText("<r><token>a<token>b</token>c</token><x>keep</x><token/><token>z</token></r>", contentType: "application/xml")
        #expect(out == "<r><token>\(R)</token><x>keep</x><token/><token>\(R)</token></r>")
        #expect(!out.contains(">c<") && !out.contains("a<"))
    }

    @Test func strayAngleBracketsDoNotHideLaterSecrets() {
        for body in [
            "x <y and then <password>s3</password> tail",
            "if a<b it's <password>s3</password>",
            "a < b <password>s3</password>",
            "<p class=it's>text <password>s3</password>",
        ] {
            let out = on.bodyText(body, contentType: "text/html")
            #expect(!out.contains("s3"), "\(body)")
        }
        #expect(on.bodyText("1 < 2 and <b>bold</b>", contentType: "text/html") == "1 < 2 and <b>bold</b>")
    }

    @Test func lineOrientedKeyValueTextIsScanned() {
        #expect(
            on.bodyText("user=bob\npassword=x\r\nz=1\n\nAPI_KEY=k&a=b", contentType: "text/plain")
                == "user=bob\npassword=\(R)\r\nz=1\n\nAPI_KEY=\(R)&a=b")
        // JSON containing '=' and '&' inside strings is not corrupted by the pair scanner
        let json = #"{"a":"x=1&password=2"}"#
        #expect(on.bodyText(json, contentType: "text/plain") == json)
        #expect(on.bodyText(json, contentType: "application/json") == json)
    }

    @Test func hostileMarkupIsScannedInLinearTime() {
        let clock = ContinuousClock()
        let unclosedOpens = "<token>" + String(repeating: "<token ", count: 30_000)  // > 200 KB, no '>' after the first
        var out = ""
        let elapsed = clock.measure { out = on.bodyText(unclosedOpens, contentType: "text/xml") }
        #expect(out == "<token>\(R)")
        #expect(elapsed < .seconds(5))

        let nestedOpens = "<token>" + String(repeating: "<token>", count: 30_000) + "secret-tail"
        let elapsed2 = clock.measure { out = on.bodyText(nestedOpens, contentType: "text/xml") }
        #expect(!out.contains("secret-tail"))
        #expect(elapsed2 < .seconds(5))

        let manyTags = String(repeating: "<a ", count: 80_000) + "<password>pw</password>"
        let elapsed3 = clock.measure { out = on.bodyText(manyTags, contentType: "text/html") }
        #expect(!out.contains(">pw<"))
        #expect(elapsed3 < .seconds(5))
    }

    @Test func textStartingLikeJSONButNotJSONIsStillScanned() {
        #expect(
            on.bodyText("[default]\naws_access_key_id=AKIA\nsecret_access_key=x\nregion=eu", contentType: "text/plain")
                == "[default]\naws_access_key_id=\(R)\nsecret_access_key=\(R)\nregion=eu")
        #expect(on.bodyText("{token=abc&x=1", contentType: "application/json") == "{token=\(R)")
        // mislabelled json body
        #expect(on.bodyText("token=abc&x=1", contentType: "application/json") == "token=\(R)&x=1")
        // valid JSON is not corrupted by the line scan
        let pretty = "{\n  \"note\": \"a=b\",\n  \"n\": 1\n}"
        #expect(on.bodyText(pretty, contentType: "application/json") == pretty)
    }

    @Test func hashRouterQueryInFragmentIsScanned() {
        #expect(on.headers([h("Location", "https://app/#/cb?code=abc&state=1")]).first?.value == "https://app/#/cb?code=\(R)&state=1")
        #expect(on.url("/p?a=1#/cb?token=t&x=2") == "/p?a=1#/cb?token=\(R)&x=2")
        #expect(on.url("/p#/route/path") == "/p#/route/path")
    }

    @Test func urlValuedQueryParametersAreScrubbedInsideTheEncodedValue() {
        let inner = "https://app.test/cb?token=abc&x=1"
        let encoded = inner.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789"))!
        let out = on.url("/oauth?redirect_uri=\(encoded)&keep=%20y")
        #expect(out.hasSuffix("&keep=%20y"))
        let value = out.dropFirst("/oauth?redirect_uri=".count).split(separator: "&").first.map(String.init)
        #expect(value?.removingPercentEncoding == "https://app.test/cb?token=\(R)&x=1")
        // unrelated URL-valued parameter is byte-identical
        let plain = "/o?next=https%3A%2F%2Fa.test%2Fp%3Fq%3D1&z=2"
        #expect(on.url(plain) == plain)
        // two levels deep are handled, the third is not looked into
        let level2 = "https://b.test/x?token=deep"
        let wrapped = "https://a.test/cb?u=" + level2.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789"))!
        let twice = on.url("/o?r=" + wrapped.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789"))!)
        #expect(!twice.contains("deep"))
    }

    @Test func disabledRedactorIsIdentity() {
        #expect(off.isEnabled == false)
        let headers = [h("Authorization", "x"), h("foo", "y")]
        #expect(off.headers(headers) == headers)
        #expect(off.url("/a?token=1&foo=2") == "/a?token=1&foo=2")
        #expect(off.bodyText(#"{"password":"x"}"#, contentType: "application/json") == #"{"password":"x"}"#)
        var flow = Flow(id: 1, scheme: "https", method: "POST", host: "h", port: 443, path: "/a?token=1", requestHeaders: headers)
        flow.requestBody = .memory(Data(#"{"password":"x"}"#.utf8))
        flow.messages[.downstreamRequest] = snapshot(headers)
        #expect(off.flow(flow) == flow)
        #expect(off.summary(#"{"token":"abc"}"#, limit: 160) == #"{"token":"abc"}"#)
        #expect(off.bodyText("<password>x</password>", contentType: "text/xml") == "<password>x</password>")
        #expect(off.headers([h("Location", "/a?token=1")]) == [h("Location", "/a?token=1")])
    }

    @Test func flowCopyRedactsEverythingAndDropsBinaryBodies() throws {
        var flow = Flow(
            id: 7, scheme: "https", method: "POST", host: "api.test", port: 443, path: "/login?token=abc&id=1",
            requestHeaders: [h("Cookie", "a=b"), h("Content-Type", "application/json")])
        flow.requestTrailers = [h("Authorization", "t"), h("X-Trailer", "ok")]
        flow.responseTrailers = [h("Set-Cookie", "t=1")]
        flow.requestBody = .memory(Data(#"{"password":"x","name":"n"}"#.utf8))
        flow.statusCode = 200
        flow.responseHeaders = [h("Set-Cookie", "sid=1"), h("Content-Type", "application/octet-stream")]
        flow.responseBody = .memory(Data([0, 1, 2, 3]))
        flow.messages[.downstreamRequest] = snapshot([h("Cookie", "raw")])
        flow.note = "keep"
        flow.state = .failed("connect failed for http://u.test/x?access_token=zz")

        let out = on.flow(flow)
        #expect(out.state == .failed("connect failed for http://u.test/x?access_token=\(R)"))
        #expect(out.id == 7 && out.note == "keep" && out.statusCode == 200 && out.host == "api.test")
        #expect(out.path == "/login?token=\(R)&id=1")
        #expect(out.requestHeaders.map(\.value) == [R, "application/json"])
        #expect(out.requestTrailers.map(\.value) == [R, "ok"])
        #expect(out.responseTrailers.map(\.value) == [R])
        #expect(out.responseHeaders.map(\.value) == [R, "application/octet-stream"])
        #expect(out.responseBody == nil)
        #expect(out.messages.isEmpty)
        let body = try #require(out.requestBody).load()
        #expect(String(decoding: body, as: UTF8.self) == #"{"password":"\#(R)","name":"n"}"#)
    }

    @Test func flowCopyHandlesEncodedOversizeAndUnchangedBodies() throws {
        var flow = Flow(id: 1, scheme: "http", method: "GET", host: "h", port: 80, path: "/")
        flow.responseHeaders = [h("Content-Type", "text/plain")]
        flow.responseBody = .memory(Data("hello".utf8))
        #expect(try #require(on.flow(flow).responseBody).load() == Data("hello".utf8))

        flow.responseHeaders = [h("Content-Type", "text/plain"), h("Content-Encoding", "gzip")]
        #expect(on.flow(flow).responseBody == nil)
        flow.responseHeaders = [h("Content-Type", "text/plain"), h("Content-Encoding", "identity"), h("content-encoding", "br")]
        #expect(on.flow(flow).responseBody == nil)

        flow.responseHeaders = [h("Content-Type", "text/plain")]
        flow.responseBody = .memory(Data(repeating: 0x61, count: 1_048_577))
        #expect(on.flow(flow).responseBody == nil)
        flow.responseBody = .memory(Data(repeating: 0x61, count: 1_048_576))
        #expect(on.flow(flow).responseBody != nil)

        flow.responseBody = .memory(Data("<html><password>x</password></html>".utf8))
        flow.responseHeaders = [h("Content-Type", "text/html")]
        #expect(String(decoding: try #require(on.flow(flow).responseBody).load(), as: UTF8.self) == "<html><password>\(R)</password></html>")
        flow.responseHeaders = [h("Content-Type", "text/plain")]

        flow.responseBody = .memory(Data([0xff, 0xfe, 0x00]))
        #expect(on.flow(flow).responseBody == nil)

        flow.responseHeaders = []
        flow.responseBody = .memory(Data("no content type".utf8))
        #expect(on.flow(flow).responseBody == nil)

        flow.responseHeaders = [h("Content-Type", "multipart/form-data; boundary=x")]
        flow.responseBody = .memory(Data("--x\r\npassword".utf8))
        #expect(on.flow(flow).responseBody == nil)
    }

    @Test func summaryRedactsAndTruncates() {
        let s = on.summary(#"{"token":"abc","q":"x"}"#, limit: 160)
        #expect(s == #"{"token":"\#(R)","q":"x"}"#)
        let long = on.summary(#"{"q":"\#(String(repeating: "z", count: 300))"}"#, limit: 20)
        #expect(long.count == 20)
        #expect(long.hasSuffix("…"))
        // redaction happens before truncation: a secret straddling the cut never survives
        let straddle = on.summary(#"{"password":"hunter2hunter2"}"#, limit: 18)
        #expect(!straddle.contains("hunter"))
        #expect(on.summary("short", limit: 20) == "short")
    }

    // MARK: URLs embedded in bodies

    @Test func jsonStringValuesHoldingUrlsGetTheRequestUrlRule() {
        func json(_ text: String) -> String { on.bodyText(text, contentType: "application/json") }
        #expect(
            json(#"{"next":"https://api.example/x?access_token=abc123&page=2"}"#)
                == #"{"next":"https://api.example/x?access_token=\#(R)&page=2"}"#)
        #expect(
            json(#"{"redirect":"https://app/cb?code=SECRET1&state=s"}"#)
                == #"{"redirect":"https://app/cb?code=\#(R)&state=s"}"#)
        #expect(
            json(#"{"url":"https://b.s3.amazonaws.com/o?X-Amz-Signature=SIGSECRET&X-Amz-Date=1"}"#)
                == #"{"url":"https://b.s3.amazonaws.com/o?X-Amz-Signature=\#(R)&X-Amz-Date=1"}"#)
        #expect(
            json(#"{"u":"https://app/cb#access_token=FRAG&x=1"}"#) == #"{"u":"https://app/cb#access_token=\#(R)&x=1"}"#)
        #expect(json(#"["https://h/?sig=ARR","https://h/?a=b"]"#) == #"["https://h/?sig=\#(R)","https://h/?a=b"]"#)
        #expect(json(#"{"a":{"b":[{"link":"/cb?token=DEEP"}]}}"#) == #"{"a":{"b":[{"link":"/cb?token=\#(R)"}]}}"#)
        // Embedded in a sentence, and several URLs in one string.
        #expect(
            json(#"{"m":"see https://h/a?x=1 and https://h/b?token=TWO now"}"#)
                == #"{"m":"see https://h/a?x=1 and https://h/b?token=\#(R) now"}"#)
    }

    @Test func jsonEscapedUrlsAreRedactedAndStayValidJSON() throws {
        for text in [
            #"{"u":"https:\/\/api\/x?token=ESCAPED&a=1"}"#,
            #"{"u":"https://h/p?a=1\u0026token=ESCAPED"}"#,
            #"{"u":"https://h/p?a=1&access\u005ftoken=ESCAPED"}"#,
        ] {
            let out = on.bodyText(text, contentType: "application/json")
            #expect(!out.contains("ESCAPED"), "\(text)")
            #expect(out.contains(R), "\(text)")
            #expect((try? JSONSerialization.jsonObject(with: Data(out.utf8))) != nil, "\(out)")
        }
        let slashes = on.bodyText(#"{"u":"https:\/\/api\/x?token=ESCAPED&a=1"}"#, contentType: "application/json")
        let decoded = try #require(try JSONSerialization.jsonObject(with: Data(slashes.utf8)) as? [String: String])
        #expect(decoded["u"] == "https://api/x?token=\(R)&a=1")
    }

    @Test func jsonStringsWithoutSecretsInUrlsAreKeptByteForByte() {
        for text in [
            #"{"u":"https://h/p?page=2&sort=asc"}"#, #"{"expr":"a=b"}"#, #"{"q":"what? yes"}"#,
            #"{"u":"https:\/\/h\/p?page=2"}"#, ##"{ "color" : "#fff", "k": "x=#y" }"##,
        ] {
            #expect(on.bodyText(text, contentType: "application/json") == text)
        }
    }

    @Test func htmlAttributeValuesHoldingUrlsAreRedacted() {
        func html(_ text: String) -> String { on.bodyText(text, contentType: "text/html") }
        #expect(html(#"<a href="/cb?token=HREF&x=1">go</a>"#) == #"<a href="/cb?token=\#(R)&x=1">go</a>"#)
        #expect(html(#"<a href='/cb?code=SQ&x=1'>go</a>"#) == #"<a href='/cb?code=\#(R)&x=1'>go</a>"#)
        #expect(html("<a href=/cb?sig=BARE>go</a>") == "<a href=/cb?sig=\(R)>go</a>")
        #expect(
            html(#"<a href="/cb?x=1&amp;code=AMP&amp;y=2">go</a>"#) == #"<a href="/cb?x=1&amp;code=\#(R)&amp;y=2">go</a>"#)
        #expect(
            html(#"<form action="https://h/post?X-Amz-Signature=FORM"><img src="https://h/i.png?page=2"></form>"#)
                == #"<form action="https://h/post?X-Amz-Signature=\#(R)"><img src="https://h/i.png?page=2"></form>"#)
        #expect(html(#"<a href="/cb#access_token=FRAG">go</a>"#) == #"<a href="/cb#access_token=\#(R)">go</a>"#)
        // The same for XML, whose element text holds URLs (S3 listings, SAML).
        #expect(
            on.bodyText("<r><url>https://h/o?X-Amz-Signature=NODE&amp;X-Amz-Date=1</url></r>", contentType: "application/xml")
                == "<r><url>https://h/o?X-Amz-Signature=\(R)&amp;X-Amz-Date=1</url></r>")
        #expect(
            on.bodyText("<p>open https://h/cb?code=TEXT&state=s now</p>", contentType: "text/html")
                == "<p>open https://h/cb?code=\(R)&state=s now</p>")
        // Plain attribute values stay as written.
        let clean = #"<a class="x" href="/p?page=2" title="a=b">t</a> 1 < 2 "quoted" & more"#
        #expect(html(clean) == clean)
    }

    @Test func plainTextBodiesHoldingUrlsAreRedacted() {
        func text(_ body: String) -> String { on.bodyText(body, contentType: "text/plain") }
        #expect(text("Open https://h/cb?code=PLAIN&state=s now") == "Open https://h/cb?code=\(R)&state=s now")
        #expect(
            text("line one\nGET https://h/x?access_token=LINE2\nline three")
                == "line one\nGET https://h/x?access_token=\(R)\nline three")
        #expect(text("go to https://h/p?page=2 please") == "go to https://h/p?page=2 please")
        // Where the line scanner already masks to the end of the line, nothing of the secret may survive.
        #expect(!text("quoted \"https://h/x?token=Q\" here").contains("=Q"))
        #expect(!text("see https://h/a#access_token=FRAGMENT done").contains("FRAGMENT"))
        #expect(text("see https://h/a#state=1&x=2 done") == "see https://h/a#state=1&x=2 done")
    }

    @Test func unredactedWhenRedactionIsOffForEmbeddedUrls() {
        let json = #"{"next":"https://api/x?access_token=abc"}"#
        #expect(off.bodyText(json, contentType: "application/json") == json)
        #expect(off.bodyText(#"<a href="/cb?token=abc">x</a>"#, contentType: "text/html") == #"<a href="/cb?token=abc">x</a>"#)
        #expect(off.bodyText("open https://h/cb?code=abc", contentType: "text/plain") == "open https://h/cb?code=abc")
    }

    @Test func flowBodiesAndSummariesRedactEmbeddedUrls() throws {
        var flow = Flow(id: 1, startedAt: Date(), scheme: "https", method: "POST", host: "h", port: 443, path: "/")
        flow.requestHeaders = [h("Content-Type", "application/json")]
        flow.requestBody = .memory(Data(#"{"next":"https://api/x?access_token=URLSECRET"}"#.utf8))
        flow.responseHeaders = [h("Content-Type", "text/html")]
        flow.responseBody = .memory(Data(#"<a href="/cb?token=URLSECRET">x</a>"#.utf8))
        let safe = on.flow(flow)
        #expect(String(decoding: try #require(safe.requestBody).load(), as: UTF8.self) == #"{"next":"https://api/x?access_token=\#(R)"}"#)
        #expect(String(decoding: try #require(safe.responseBody).load(), as: UTF8.self) == #"<a href="/cb?token=\#(R)">x</a>"#)
        #expect(!on.summary(#"{"url":"https://h/x?sig=URLSECRET"}"#, limit: 160).contains("URLSECRET"))
    }
}
