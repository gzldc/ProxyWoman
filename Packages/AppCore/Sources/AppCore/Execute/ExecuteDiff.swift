import FlowStore
import Foundation
import Localization
import RulesEngine

public struct ExecuteDiffReport: Equatable, Sendable {
    public struct Line: Equatable, Sendable {
        public var text: String
        public init(text: String) { self.text = text }
    }

    public var request: [Line]
    public var response: [Line]

    public init(request: [Line] = [], response: [Line] = []) {
        self.request = request
        self.response = response
    }

    public var isEmpty: Bool { request.isEmpty && response.isEmpty }
}

/// What an Execute run changed in a flow's messages: address, status, headers and body sizes (D14, Q3).
/// Not a byte-level text diff.
public enum ExecuteDiff {
    /// Header values are cut to this many characters.
    static let valueLimit = 200
    /// Equal-sized bodies are compared on at most this many leading bytes.
    static let contentCompareBytes = 1 << 20

    public static func compare(_ flow: Flow, localizer: Localizer = L10n.localizer) -> ExecuteDiffReport {
        guard let overlay = flow.executeOverlay, !overlay.isEmpty, let originals = FlowOriginals.of(flow) else {
            return ExecuteDiffReport()
        }
        var report = ExecuteDiffReport()
        if let after = overlay.request {
            report.request = lines(before: originals.request, after: after, localizer: localizer)
        }
        if let after = overlay.response {
            var lines: [ExecuteDiffReport.Line] = []
            if overlay.responseIsLocal, originals.response != nil {
                lines.append(.init(text: localizer.string("executeDiff.response.replaced")))
            }
            lines += Self.lines(before: originals.response, after: after, localizer: localizer)
            report.response = lines
        }
        return report
    }

    private static func lines(
        before: FlowOriginals.Message?, after: HTTPMessageSnapshot, localizer: Localizer
    ) -> [ExecuteDiffReport.Line] {
        var out: [String] = []
        if let was = before?.target, let now = after.target, was.url != now.url || was.method != now.method {
            out.append(localizer.format("executeDiff.target", arguments: [was.url, now.url]))
        }
        if let was = before?.status, let now = after.status, was != now {
            out.append(localizer.format("executeDiff.status", arguments: [was, now]))
        }
        out += headerLines(before: before?.headers ?? [], after: after.headers, localizer: localizer)
        let wasBody = before?.body ?? FlowOriginals.Body()
        if let line = bodyLine(before: wasBody, after: after.body, localizer: localizer) { out.append(line) }
        return out.map { ExecuteDiffReport.Line(text: $0) }
    }

    private static func grouped(_ headers: [HeaderField]) -> (order: [String], fields: [String: (name: String, values: [String])]) {
        var order: [String] = []
        var fields: [String: (name: String, values: [String])] = [:]
        for header in headers {
            let key = header.name.lowercased()
            if fields[key] == nil {
                order.append(key)
                fields[key] = (header.name, [header.value])
            } else {
                fields[key]?.values.append(header.value)
            }
        }
        return (order, fields)
    }

    private static func headerLines(before: [HeaderField], after: [HeaderField], localizer: Localizer) -> [String] {
        let was = grouped(before), now = grouped(after)
        var removed: [String] = [], changed: [String] = [], added: [String] = []
        for key in was.order {
            guard let old = was.fields[key] else { continue }
            guard let new = now.fields[key] else {
                removed.append(localizer.format("executeDiff.header.removed", arguments: [old.name, shortened(old.values)]))
                continue
            }
            if old.values != new.values {
                changed.append(
                    localizer.format(
                        "executeDiff.header.changed", arguments: [new.name, shortened(old.values), shortened(new.values)]))
            }
        }
        for key in now.order where was.fields[key] == nil {
            guard let new = now.fields[key] else { continue }
            added.append(localizer.format("executeDiff.header.added", arguments: [new.name, shortened(new.values)]))
        }
        return removed + changed + added
    }

    private static func shortened(_ values: [String]) -> String {
        let joined = values.joined(separator: ", ")
        return joined.count > valueLimit ? String(joined.prefix(valueLimit)) : joined
    }

    private static func bodyLine(
        before: FlowOriginals.Body, after: HTTPBodySlice?, localizer: Localizer
    ) -> String? {
        let wasSize = before.size, nowSize = after?.count ?? 0
        let different: Bool
        if wasSize != nowSize {
            different = true
        } else if wasSize == 0 || sameBytes(before, after) {
            different = false
        } else {
            different = contentDiffers(before, after)
        }
        guard different else { return nil }
        return localizer.format("executeDiff.body.changed", arguments: [wasSize, nowSize])
    }

    private static func sameBytes(_ before: FlowOriginals.Body, _ after: HTTPBodySlice?) -> Bool {
        guard let after else { return false }
        if let slice = before.slice { return slice == after }
        if let legacy = before.legacy { return after.offset == 0 && after.ref == legacy }
        return false
    }

    /// Equal sizes, different slices: compare the leading bytes. A body that cannot be read counts as unchanged.
    private static func contentDiffers(_ before: FlowOriginals.Body, _ after: HTTPBodySlice?) -> Bool {
        guard let after, let old = try? before.load(maxBytes: contentCompareBytes),
            let new = try? after.load(maxBytes: contentCompareBytes).data
        else { return false }
        return old != new
    }
}
