import FlowStore
import Foundation

/// How a rule ends a connection.
public enum CloseMode: String, Codable, Sendable, CaseIterable {
    /// An orderly close (FIN).
    case graceful
    /// An abrupt close (RST).
    case reset
}

/// A response a rule made up: the evaluated form of a handwritten or preset response.
public struct GeneratedResponse: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case handwritten
        case preset(PresetResponse.Preset)
    }

    public var status: Int
    public var reason: String
    public var headers: [HeaderField]
    public var body: Data
    public var kind: Kind

    public init(status: Int, reason: String, headers: [HeaderField], body: Data, kind: Kind) {
        self.status = status
        self.reason = reason
        self.headers = headers
        self.body = body
        self.kind = kind
    }
}

extension GeneratedResponse {
    /// The headers the client receives: the response path states the body's length in `Content-Length` (replacing a
    /// declared one in place, or appending it), except for a 1xx or 204 answer, which carries none. It adds no
    /// `Content-Type`: a preset declares its own and a handwritten response sends what it wrote.
    public var clientHeaders: [HeaderField] {
        let isLength: (HeaderField) -> Bool = { $0.name.lowercased() == "content-length" }
        if (100..<200).contains(status) || status == 204 { return headers.filter { !isLength($0) } }
        let length = String(body.count)
        guard let first = headers.firstIndex(where: isLength) else {
            return headers + [HeaderField(name: "Content-Length", value: length)]
        }
        var result: [HeaderField] = []
        for (index, field) in headers.enumerated() {
            if index == first { result.append(HeaderField(name: field.name, value: length)) }
            else if !isLength(field) { result.append(field) }
        }
        return result
    }

    /// The conventional reason phrase for a status code, or "" for an unusual one.
    static func standardReason(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 202: "Accepted"
        case 203: "Non-Authoritative Information"
        case 204: "No Content"
        case 205: "Reset Content"
        case 206: "Partial Content"
        case 300: "Multiple Choices"
        case 301: "Moved Permanently"
        case 302: "Found"
        case 303: "See Other"
        case 304: "Not Modified"
        case 307: "Temporary Redirect"
        case 308: "Permanent Redirect"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 402: "Payment Required"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 406: "Not Acceptable"
        case 407: "Proxy Authentication Required"
        case 408: "Request Timeout"
        case 409: "Conflict"
        case 410: "Gone"
        case 411: "Length Required"
        case 412: "Precondition Failed"
        case 413: "Content Too Large"
        case 414: "URI Too Long"
        case 415: "Unsupported Media Type"
        case 416: "Range Not Satisfiable"
        case 417: "Expectation Failed"
        case 418: "I'm a teapot"
        case 421: "Misdirected Request"
        case 422: "Unprocessable Content"
        case 425: "Too Early"
        case 426: "Upgrade Required"
        case 428: "Precondition Required"
        case 429: "Too Many Requests"
        case 431: "Request Header Fields Too Large"
        case 451: "Unavailable For Legal Reasons"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        case 504: "Gateway Timeout"
        case 505: "HTTP Version Not Supported"
        default: ""
        }
    }
}
