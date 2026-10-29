import Foundation

/// Reads HAR 1.2 files (from ProxyWoman, browsers' DevTools, Charles, Proxyman, …) into finished flows.
/// HAR stores bodies already decoded, so `Content-Encoding`/`Transfer-Encoding` are dropped from the
/// imported headers: keeping them would make the viewers try to decode plain bytes again.
public enum HARImporter {
    public struct ImportError: Error, Equatable, LocalizedError {
        public var message: String
        public var errorDescription: String? { message }
    }

    /// One parsed entry, before it becomes a `Flow` in a store.
    public struct Entry: Equatable, Sendable {
        public var startedAt: Date
        public var duration: TimeInterval?
        public var method: String
        public var scheme: String
        public var host: String
        public var port: Int
        public var path: String
        public var requestHeaders: [HeaderField]
        public var requestBody: Data?
        public var statusCode: Int?
        public var statusReason: String?
        public var responseHeaders: [HeaderField]
        public var responseBody: Data?
        public var comment: String?
    }

    public static func parse(_ data: Data) throws -> [Entry] {
        let file: File
        do { file = try JSONDecoder().decode(File.self, from: data) } catch {
            throw ImportError(message: "not a HAR file (\(error.localizedDescription))")
        }
        return file.log.entries.compactMap(entry)
    }

    /// Adds the entries as completed flows (in file order) and returns how many were added.
    @discardableResult
    public static func add(_ entries: [Entry], to store: FlowStore) -> Int {
        for entry in entries {
            // `begin` runs its closure under the store's lock, so bodies are wrapped first.
            let requestBody = entry.requestBody.map(store.makeManagedBody)
            let responseBody = entry.responseBody.map(store.makeManagedBody)
            store.begin { id in
                var flow = Flow(id: id, startedAt: entry.startedAt, scheme: entry.scheme, method: entry.method,
                                host: entry.host, port: entry.port, path: entry.path, requestHeaders: entry.requestHeaders)
                flow.requestBody = requestBody
                flow.bytesSent = entry.requestBody?.count ?? 0
                flow.statusCode = entry.statusCode
                flow.statusReason = entry.statusReason
                flow.responseHeaders = entry.responseHeaders
                flow.responseBody = responseBody
                flow.bytesReceived = entry.responseBody?.count ?? 0
                flow.completedAt = entry.duration.map { entry.startedAt.addingTimeInterval($0) } ?? entry.startedAt
                flow.state = entry.statusCode == nil ? .failed("no response in HAR") : .completed
                flow.comment = entry.comment
                return flow
            }
        }
        return entries.count
    }

    private static func entry(_ raw: RawEntry) -> Entry? {
        guard let components = URLComponents(string: raw.request.url), let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = components.host, !host.isEmpty else { return nil }
        let port = components.port ?? (scheme == "https" ? 443 : 80)
        var path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery { path += "?" + query }
        let status = raw.response?.status ?? 0
        let content = raw.response?.content
        return Entry(
            startedAt: date(raw.startedDateTime) ?? Date(),
            duration: raw.time.flatMap { $0 >= 0 ? $0 / 1000 : nil },
            method: raw.request.method.uppercased(), scheme: scheme, host: host, port: port, path: path,
            requestHeaders: headers(raw.request.headers),
            requestBody: body(raw.request.postData?.text, encoding: raw.request.postData?.encoding),
            statusCode: status > 0 ? status : nil,
            statusReason: raw.response?.statusText.flatMap { $0.isEmpty ? nil : $0 },
            responseHeaders: headers(raw.response?.headers ?? []),
            responseBody: body(content?.text, encoding: content?.encoding),
            comment: raw.comment.flatMap { $0.isEmpty ? nil : $0 })
    }

    private static func headers(_ pairs: [Pair]) -> [HeaderField] {
        pairs.filter { name in
            // HTTP/2 pseudo-headers and framing that no longer matches the decoded body.
            let lower = name.name.lowercased()
            return !lower.hasPrefix(":") && lower != "content-encoding" && lower != "transfer-encoding"
        }.map { HeaderField(name: $0.name, value: $0.value) }
    }

    private static func body(_ text: String?, encoding: String?) -> Data? {
        guard let text, !text.isEmpty else { return nil }
        if encoding?.lowercased() == "base64" { return Data(base64Encoded: text) }
        return Data(text.utf8)
    }

    private static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    private struct File: Decodable { var log: Log }
    private struct Log: Decodable { var entries: [RawEntry] }
    private struct RawEntry: Decodable {
        var startedDateTime: String
        var time: Double?
        var request: RawRequest
        var response: RawResponse?
        var comment: String?
    }
    private struct RawRequest: Decodable {
        var method: String
        var url: String
        var headers: [Pair]
        var postData: Content?
    }
    private struct RawResponse: Decodable {
        var status: Int
        var statusText: String?
        var headers: [Pair]
        var content: Content?
    }
    private struct Content: Decodable {
        var text: String?
        var encoding: String?
    }
    private struct Pair: Decodable {
        var name: String
        var value: String
    }
}
