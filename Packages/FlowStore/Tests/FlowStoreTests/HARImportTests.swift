import Foundation
import Testing

@testable import FlowStore

@Suite struct HARImportTests {
    @Test func exportedFlowsComeBackWithHeadersBodiesAndStatus() throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        var flow = Flow(id: 1, startedAt: Date(timeIntervalSince1970: 1_700_000_000), scheme: "https", method: "POST",
                        host: "api.example.com", port: 8443, path: "/v1/items?q=a%20b",
                        requestHeaders: [HeaderField(name: "Content-Type", value: "application/json")])
        flow.requestBody = .memory(Data(#"{"name":"x"}"#.utf8))
        flow.statusCode = 201
        flow.statusReason = "Created"
        flow.responseHeaders = [HeaderField(name: "Content-Type", value: "application/json")]
        flow.responseBody = .memory(Data(#"{"id":7}"#.utf8))
        flow.completedAt = flow.startedAt.addingTimeInterval(0.25)
        flow.state = .completed
        flow.comment = "checked"

        let data = try HARExporter.export([flow], creatorName: "Test", creatorVersion: "1")
        let entries = try HARImporter.parse(data)
        #expect(HARImporter.add(entries, to: env.store) == 1)

        let imported = try #require(env.store.allFlows().first)
        #expect(imported.method == "POST")
        #expect(imported.scheme == "https")
        #expect(imported.host == "api.example.com")
        #expect(imported.port == 8443)
        #expect(imported.path == "/v1/items?q=a%20b")
        #expect(imported.statusCode == 201)
        #expect(imported.statusReason == "Created")
        #expect(imported.state == .completed)
        #expect(imported.comment == "checked")
        #expect(imported.startedAt == flow.startedAt)
        #expect(abs((imported.duration ?? 0) - 0.25) < 0.001)
        #expect(imported.requestHeaders.value(for: "content-type") == "application/json")
        #expect(try imported.requestBody?.load() == Data(#"{"name":"x"}"#.utf8))
        #expect(try imported.responseBody?.load() == Data(#"{"id":7}"#.utf8))
    }

    @Test func devToolsStyleHARWithBase64AndEncodingHeaders() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let har = """
        {"log":{"version":"1.2","creator":{"name":"WebInspector","version":"537.36"},"entries":[
          {"startedDateTime":"2026-10-29T10:00:00Z","time":12.5,
           "request":{"method":"get","url":"http://example.com/a.png","httpVersion":"HTTP/1.1",
                      "headers":[{"name":":authority","value":"example.com"},{"name":"Accept","value":"image/*"}],
                      "queryString":[],"cookies":[],"headersSize":-1,"bodySize":0},
           "response":{"status":200,"statusText":"","httpVersion":"HTTP/1.1",
                       "headers":[{"name":"Content-Encoding","value":"gzip"},{"name":"Content-Type","value":"image/png"}],
                       "cookies":[],"content":{"size":4,"mimeType":"image/png","text":"\(png.base64EncodedString())","encoding":"base64"},
                       "redirectURL":"","headersSize":-1,"bodySize":-1},
           "cache":{},"timings":{"send":0,"wait":12.5,"receive":0}},
          {"startedDateTime":"2026-10-29T10:00:01.500Z","time":-1,
           "request":{"method":"GET","url":"wss://example.com/socket","headers":[]},
           "response":{"status":101,"headers":[]}},
          {"startedDateTime":"2026-10-29T10:00:02Z",
           "request":{"method":"GET","url":"https://example.com/failed","headers":[]},
           "response":{"status":0,"statusText":"","headers":[]}}
        ]}}
        """
        let entries = try HARImporter.parse(Data(har.utf8))
        #expect(entries.count == 2) // the wss entry is skipped
        let image = entries[0]
        #expect(image.method == "GET")
        #expect(image.port == 80)
        #expect(image.statusReason == nil)
        #expect(image.responseBody == png)
        #expect(image.requestHeaders.map(\.name) == ["Accept"])
        #expect(image.responseHeaders.map(\.name) == ["Content-Type"])
        #expect(image.duration == 0.0125)
        #expect(entries[1].statusCode == nil)

        let env = TestEnvironment()
        defer { env.cleanUp() }
        HARImporter.add(entries, to: env.store)
        let failed = try #require(env.store.allFlows().last)
        #expect(failed.state == .failed("no response in HAR"))
    }

    @Test(arguments: ["", "{}", #"{"log":{}}"#, "not json"])
    func rejectsFilesThatAreNotHAR(_ text: String) {
        #expect(throws: HARImporter.ImportError.self) { try HARImporter.parse(Data(text.utf8)) }
    }
}
