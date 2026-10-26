import Foundation

public struct CurlOptions: Sendable {
    /// 例如 "http://127.0.0.1:9090"；设置后在命令末尾追加 `--proxy`。
    public var proxy: String? = nil
    /// 为 true 时保留 Content-Length。
    public var preserveOriginalHeaders = false

    public init(proxy: String? = nil, preserveOriginalHeaders: Bool = false) {
        self.proxy = proxy
        self.preserveOriginalHeaders = preserveOriginalHeaders
    }
}

public enum CurlExporter {
    /// 生成可直接粘贴到终端的 curl 命令。省略与 URL 主机一致的 Host 头和 Content-Length。
    public static func command(for flow: Flow) -> String {
        command(for: flow, options: CurlOptions())
    }

    public static func command(for flow: Flow, options: CurlOptions) -> String {
        render(
            method: flow.method, url: flow.url, host: flow.host, port: flow.port, headers: flow.requestHeaders,
            body: bodyLine(for: flow), options: options)
    }

    /// The command for the request that really passed `boundary` (`downstreamRequest` is the
    /// client's original, `upstreamRequest` what the origin was sent, the Compose submitted
    /// request for a send). Nil when that boundary never happened. A body that is not complete
    /// is never sent as if it were whole: it is replaced by a comment that says what is missing.
    public static func command(for flow: Flow, options: CurlOptions = CurlOptions(), boundary: HTTPMessageBoundary) -> String? {
        guard let snapshot = flow.messages[boundary], let target = snapshot.target else { return nil }
        return render(
            method: target.method, url: target.url, host: target.host, port: target.port,
            headers: snapshot.headers, body: bodyLine(for: snapshot), options: options)
    }

    private static func render(
        method rawMethod: String, url: String, host: String, port: Int, headers: [HeaderField],
        body: (text: String, sendsData: Bool)?, options: CurlOptions
    ) -> String {
        let method = rawMethod.uppercased()
        var command = "curl"
        switch method {
        case "GET":
            // 先读 body：GET 带 body 时 curl 会默认改发 POST，必须显式写 -X GET。
            if body?.sendsData == true { command += " -X GET" }
        case "HEAD":
            // -X HEAD 会让 curl 一直等响应 body，-I 才是正确的 HEAD。
            command += " -I"
        default:
            command += " -X \(rawMethod)"
        }
        command += " \(quoted(url))"

        let authorities = [host, "\(host):\(port)"].map { $0.lowercased() }
        for header in headers {
            let name = header.name.lowercased()
            if name == "content-length", !options.preserveOriginalHeaders { continue }
            if name == "host", authorities.contains(header.value.lowercased()) { continue }
            command += " \\\n  -H \(quoted("\(header.name): \(header.value)"))"
        }

        if let body, body.sendsData { command += body.text }
        if let proxy = options.proxy { command += " \\\n  --proxy \(quoted(proxy))" }
        // 二进制请求体的说明是注释行，必须放在最后，否则它后面的内容会被注释掉。
        if let body, !body.sendsData { command += body.text }
        return command
    }

    /// 请求 body 对应的命令行片段；没有可读取的 body 时返回 nil。
    private static func bodyLine(for flow: Flow) -> (text: String, sendsData: Bool)? {
        guard let ref = flow.requestBody, ref.size > 0 else { return nil }
        guard let data = try? ref.load() else { return (unreadableBodyLine, false) }
        return data.isEmpty ? nil : bodyLine(data: data)
    }

    private static func bodyLine(for snapshot: HTTPMessageSnapshot) -> (text: String, sendsData: Bool)? {
        switch snapshot.bodyState {
        case .complete:
            guard let slice = snapshot.body, slice.count > 0 else { return nil }
            guard let data = try? slice.load() else {
                return (unreadableBodyLine, false)
            }
            return data.isEmpty ? nil : bodyLine(data: data)
        case .pending, .truncated, .incomplete, .unavailable:
            let kept = snapshot.body?.count ?? 0
            return (" \\\n  # request body omitted: incomplete (\(snapshot.bodyState.rawValue), recorded \(kept) of \(snapshot.observedBytes) bytes)", false)
        }
    }

    private static let unreadableBodyLine = " \\\n  # request body omitted: unreadable (the recording may have been cleared)"

    private static func bodyLine(data: Data) -> (text: String, sendsData: Bool) {
        if let text = String(data: data, encoding: .utf8) {
            return (" \\\n  --data-binary \(quoted(text))", true)
        }
        return (" \\\n  # request body omitted: binary (\(data.count) bytes)", false)
    }

    /// 单引号包裹，内部的单引号写成 '\''。
    private static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
