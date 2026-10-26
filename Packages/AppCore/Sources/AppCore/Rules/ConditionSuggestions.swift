import FlowStore
import Foundation
import RulesEngine

/// Values worth offering while the user types a condition: what recent traffic actually had, most frequent first.
public enum ConditionSuggestions {
    /// What a keyed field (header, cookie, query parameter) offers when no key is given: the `names` of the keys (the key
    /// box) or the `values` of every key (the value box of a row whose key is still empty). With a key, the values of
    /// that key are offered whatever the role.
    public enum Role: Sendable, Equatable {
        case names
        case values
    }

    public static func values(
        field: ConditionField, name: String?, role: Role = .names, in flows: [Flow], limit: Int
    ) -> [String] {
        guard limit > 0 else { return [] }
        let name = (name?.isEmpty ?? true) ? nil : name
        var counts: [String: (display: String, count: Int, first: Int)] = [:]
        var seen = 0
        func add(_ text: String?, caseInsensitive: Bool = false) {
            guard let text, !text.isEmpty else { return }
            let key = caseInsensitive ? text.lowercased() : text
            if var entry = counts[key] {
                entry.count += 1
                counts[key] = entry
            } else {
                counts[key] = (text, 1, seen)
                seen += 1
            }
        }
        for flow in flows { collect(field, name, role, flow) { add($0, caseInsensitive: $1) } }
        return counts.values.sorted { ($0.count, $1.first) > ($1.count, $0.first) }.prefix(limit).map(\.display)
    }

    private static func collect(
        _ field: ConditionField, _ name: String?, _ role: Role, _ flow: Flow, _ emit: (String?, Bool) -> Void
    ) {
        func add(_ text: String?) { emit(text, false) }
        func header(_ fields: [HeaderField]) {
            if let name {
                for item in fields where item.name.caseInsensitiveCompare(name) == .orderedSame { add(item.value) }
            } else {
                for item in fields { role == .names ? emit(item.name, true) : emit(item.value, false) }
            }
        }
        /// Cookie names (no key given) or the values of the cookie named `name`, from `Cookie` request headers and/or `Set-Cookie`
        /// response headers.
        func cookies(request: Bool, response: Bool) {
            var pairs: [(String, String)] = []
            if request {
                for item in flow.requestHeaders where item.name.caseInsensitiveCompare("Cookie") == .orderedSame {
                    for part in item.value.split(separator: ";") { pairs.append(Self.cookiePair(part)) }
                }
            }
            if response {
                for item in flow.responseHeaders where item.name.caseInsensitiveCompare("Set-Cookie") == .orderedSame {
                    if let first = item.value.split(separator: ";", maxSplits: 1).first { pairs.append(Self.cookiePair(first)) }
                }
            }
            for (key, value) in pairs where !key.isEmpty {
                if let name {
                    if key.caseInsensitiveCompare(name) == .orderedSame { add(value) }
                } else if role == .names {
                    emit(key, true)
                } else {
                    add(value)
                }
            }
        }
        let query = flow.path.firstIndex(of: "?").map { String(flow.path[flow.path.index(after: $0)...]) }
        switch field {
        case .host: add(flow.host)
        case .method: add(flow.method)
        case .scheme: add(flow.scheme)
        case .port: add(String(flow.port))
        case .statusCode: add(flow.statusCode.map(String.init))
        case .pathAndQuery: add(flow.path)
        case .path: add(flow.path.firstIndex(of: "?").map { String(flow.path[..<$0]) } ?? flow.path)
        case .queryString: add(query)
        case .url:
            let defaultPort = flow.scheme == "https" ? 443 : 80
            add("\(flow.scheme)://\(flow.host)\(flow.port == defaultPort ? "" : ":\(flow.port)")\(flow.path)")
        case .requestCookie: cookies(request: true, response: false)
        case .responseCookie: cookies(request: false, response: true)
        case .cookie: cookies(request: true, response: true)
        case .requestHeader: header(flow.requestHeaders)
        case .responseHeader: header(flow.responseHeaders)
        case .queryParam:
            for pair in (query ?? "").split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let key = parts.first.map(String.init) else { continue }
                if let name {
                    if key == name, parts.count > 1 { add(String(parts[1])) }
                } else if role == .names {
                    add(key)
                } else if parts.count > 1 {
                    add(String(parts[1]))
                }
            }
        case .clientApp:
            switch name {
            case "path": add(flow.client?.executablePath)
            case "pid": add(flow.client.map { String($0.pid) })
            case nil: add(flow.client.map { "\($0.name):\($0.pid)" })
            default: add(flow.client?.name)
            }
        case .clientIP: add(flow.clientIP)
        case .remoteIP: add(flow.remoteIP)
        case .clientHTTPVersion: add(flow.transport.downstreamRequest.map(Self.httpVersionText))
        case .upstreamHTTPVersion:
            add((flow.transport.upstreamRequest ?? flow.transport.upstreamResponse).map(Self.httpVersionText))
        case .clientTLSVersion: add(flow.transport.downstreamTLSVersion)
        case .upstreamTLSVersion: add(flow.transport.upstreamTLSVersion)
        case .tlsVersion:
            add(flow.transport.downstreamTLSVersion)
            add(flow.transport.upstreamTLSVersion)
        case .requestTime: add(ConditionFieldText.requestTime(flow.startedAt))
        case .comment: add(flow.comment)
        case .requestBodySize: add(ConditionFieldText.declaredRequestLength(flow.requestHeaders).map(String.init))
        case .responseBodySize: add(flow.statusCode == nil ? nil : String(flow.bytesReceived))
        case .durationMs: add(flow.duration.map { String(Int(($0 * 1000).rounded())) })
        case .allSessions, .requestBody, .responseBody, .sessionState, .requestDate, .certificate, .appProtocol,
            .rulesModified, .magicString:
            break
        }
    }
}

extension ConditionSuggestions {
    fileprivate static func cookiePair(_ part: Substring) -> (String, String) {
        let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let key = pieces.first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        return (key, pieces.count > 1 ? String(pieces[1]).trimmingCharacters(in: .whitespaces) : "")
    }
}

extension ConditionSuggestions {
    /// `HTTP/1.0`, `HTTP/1.1`, `HTTP/2`: the text the engine compares the version fields with.
    fileprivate static func httpVersionText(_ version: HTTPWireVersion) -> String {
        switch version {
        case .http1_0: "HTTP/1.0"
        case .http1_1: "HTTP/1.1"
        case .http2: "HTTP/2"
        }
    }
}
