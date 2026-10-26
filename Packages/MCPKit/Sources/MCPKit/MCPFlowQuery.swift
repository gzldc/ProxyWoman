import FlowStore
import Foundation
import MCPWire

/// The filter shared by `list_flows`, `search_flows` and (later) `export_har`. Parsed once from the AI
/// client's arguments; every failure names the offending field.
public struct MCPFlowQuery: Sendable, Equatable {
    public static let defaultLimit = 50
    public static let maxLimit = 200
    static let maxTextLength = 256

    public enum StatusFilter: Sendable, Equatable {
        case exact(Int)
        case range(ClosedRange<Int>)

        func contains(_ code: Int) -> Bool {
            switch self {
            case .exact(let value): code == value
            case .range(let range): range.contains(code)
            }
        }
    }

    public var host: String?
    public var method: String?
    public var status: StatusFilter?
    public var since: Date?
    public var until: Date?
    public var text: String?
    public var beforeID: Int?
    /// Clamped to `1...maxLimit` by `parse`.
    public var limit: Int

    public init(
        host: String? = nil, method: String? = nil, status: StatusFilter? = nil, since: Date? = nil,
        until: Date? = nil, text: String? = nil, beforeID: Int? = nil, limit: Int = MCPFlowQuery.defaultLimit
    ) {
        self.host = host
        self.method = method
        self.status = status
        self.since = since
        self.until = until
        self.text = text
        self.beforeID = beforeID
        self.limit = min(max(limit, 1), Self.maxLimit)
    }

    // MARK: Parsing

    public static func parse(_ arguments: [String: JSONValue], now: Date) throws -> MCPFlowQuery {
        var query = MCPFlowQuery()
        query.host = try optionalText(arguments, "host")
        query.method = try optionalText(arguments, "method")?.uppercased()
        query.text = try optionalText(arguments, "text")
        if let value = arguments["status"], value != .null { query.status = try parseStatus(value) }
        if let value = try optionalText(arguments, "since") { query.since = try parseTime(value, field: "since", now: now) }
        if let value = try optionalText(arguments, "until") { query.until = try parseTime(value, field: "until", now: now) }
        if let value = try optionalInt(arguments, "before_id") { query.beforeID = value }
        if let value = try optionalInt(arguments, "limit") { query.limit = min(max(value, 1), maxLimit) }
        return query
    }

    /// Absent, null and blank strings all mean "not given".
    static func optionalText(_ arguments: [String: JSONValue], _ field: String) throws -> String? {
        guard let value = arguments[field], value != .null else { return nil }
        guard let text = value.stringValue else { throw MCPToolError.invalidArguments("\(field) must be a string.") }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= maxTextLength else {
            throw MCPToolError.invalidArguments("\(field) is too long (at most \(maxTextLength) characters).")
        }
        return trimmed.isEmpty ? nil : trimmed
    }

    static func optionalInt(_ arguments: [String: JSONValue], _ field: String) throws -> Int? {
        guard let value = arguments[field], value != .null else { return nil }
        switch value {
        case .int(let number): return number
        case .double(let number) where number == number.rounded() && abs(number) < 1e15: return Int(number)
        default: throw MCPToolError.invalidArguments("\(field) must be an integer.")
        }
    }

    static func parseStatus(_ value: JSONValue) throws -> StatusFilter {
        let invalid = MCPToolError.invalidArguments("status must look like 404, 4xx or 400-499 (100 to 599).")
        let valid = 100...599
        func code(_ text: Substring) -> Int? {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let number = Int(trimmed),
                valid.contains(number)
            else { return nil }
            return number
        }
        switch value {
        case .int(let number):
            guard valid.contains(number) else { throw invalid }
            return .exact(number)
        case .double(let number):
            guard number == number.rounded(), valid.contains(Int(exactly: number) ?? 0) else { throw invalid }
            return .exact(Int(number))
        case .string(let raw):
            let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if text.count == 3, text.hasSuffix("xx"), let digit = Int(text.prefix(1)), (1...5).contains(digit) {
                return .range(digit * 100...digit * 100 + 99)
            }
            if let dash = text.firstIndex(of: "-") {
                guard let low = code(text[..<dash]), let high = code(text[text.index(after: dash)...]), low <= high
                else { throw invalid }
                return .range(low...high)
            }
            guard let number = code(text[...]) else { throw invalid }
            return .exact(number)
        default:
            throw invalid
        }
    }

    /// ISO-8601 (with or without fractional seconds, or a bare date) or relative `15m`, `2h`, `1d`, `30s`
    /// (that long before `now`).
    static func parseTime(_ raw: String, field: String, now: Date) throws -> Date {
        let invalid = MCPToolError.invalidArguments("\(field) must be ISO-8601 or relative like 15m, 2h, 1d.")
        let text = raw.trimmingCharacters(in: .whitespaces)
        if let unit = text.last, let seconds = ["s": 1.0, "m": 60, "h": 3600, "d": 86400][String(unit).lowercased()] {
            let digits = text.dropLast()
            guard (1...6).contains(digits.count), digits.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                let count = Int(digits)
            else { throw invalid }
            return now.addingTimeInterval(-Double(count) * seconds)
        }
        let formatter = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [
            [.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime], [.withFullDate],
        ] {
            formatter.formatOptions = options
            if let date = formatter.date(from: text) { return date }
        }
        throw invalid
    }

    // MARK: Matching

    /// With an enabled `redactor`, `host` and `text` are matched against the redacted URL, never the raw
    /// one, so a filter cannot be used to recover a redacted value one prefix at a time.
    public func matches(_ flow: Flow, redactor: MCPRedactor) -> Bool {
        if let beforeID, flow.id >= beforeID { return false }
        if let method, flow.method.uppercased() != method { return false }
        if let status {
            guard let code = flow.statusCode, status.contains(code) else { return false }
        }
        if let since, flow.startedAt < since { return false }
        if let until, flow.startedAt > until { return false }
        let redactedURL = redactor.isEnabled && (host != nil || text != nil) ? redactor.url(flow.url) : nil
        if let host {
            guard flow.host.localizedCaseInsensitiveContains(host) else { return false }
            if let redactedURL, !redactedURL.localizedCaseInsensitiveContains(host) { return false }
        }
        if let text, !Self.textMatches(flow, text, url: redactedURL) { return false }
        return true
    }

    /// URL (the main window's filter semantics) plus method, status code, host and client app name.
    /// `url` replaces the raw URL when given.
    static func textMatches(_ flow: Flow, _ text: String, url: String? = nil) -> Bool {
        if let url {
            if url.localizedCaseInsensitiveContains(text) { return true }
        } else {
            var filter = FlowFilter()
            filter.text = text
            if filter.matches(flow) { return true }
        }
        if flow.method.localizedCaseInsensitiveContains(text) { return true }
        if let code = flow.statusCode, String(code).contains(text) { return true }
        if flow.host.localizedCaseInsensitiveContains(text) { return true }
        if let app = flow.client?.name, app.localizedCaseInsensitiveContains(text) { return true }
        return false
    }
}
