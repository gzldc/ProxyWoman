import FlowStore
import Foundation

/// What a condition row sees of a message body (D12): a read-only look at the text, never the bytes
/// that are forwarded.
public enum BodyPeek: Sendable, Equatable {
    /// Nothing was collected at this point (no rule needs it, or it is too early): the body is unknown
    /// and no outcome is recorded.
    case notCollected
    /// The message has no body: rows compare it as the empty string.
    case empty
    /// The decoded text, at most `RulesLimits.conditionBodyBytes`.
    case text(String)
    /// Text in a charset conditions can read but the rewriter cannot write back (GBK): body rewrites
    /// never touch it, so later rows keep reading the original text.
    case readOnlyText(String)
    /// The body was not read; the code says why (`bodyTooLarge`, `bodySkippedNotText`,
    /// `bodySkippedStreaming`, `bodySkippedOnDisk`).
    case skipped(RuleOutcomeCode)

    /// Decompresses (`Content-Encoding`) and decodes (`Content-Type` charset) a collected body. A body
    /// that cannot be turned into text is `bodySkippedNotText`; one that grows past the cap is
    /// `bodyTooLarge`.
    public static func decode(_ data: Data, headers: [HeaderField], limits: RulesLimits = RulesLimits()) -> BodyPeek {
        guard !data.isEmpty else { return .empty }
        let contentType = headers.values(for: "content-type").first
        guard BodyTextCodec.isTextLike(contentType: contentType) else { return .skipped(.bodySkippedNotText) }
        let cap = limits.conditionBodyBytes
        let plain: Data
        do {
            plain = try BodyContentCodec.decode(
                data, contentEncoding: headers.values(for: "content-encoding").first, maxOutputBytes: cap)
        } catch BodyContentCodec.Failure.tooLarge {
            return .skipped(.bodyTooLarge)
        } catch {
            return .skipped(.bodySkippedNotText)
        }
        guard plain.count <= cap else { return .skipped(.bodyTooLarge) }
        let decoded: String?
        var readOnly = false
        if let declared = BodyTextCodec.encoding(contentType: contentType) {
            decoded = try? BodyTextCodec.decode(plain, as: BodyTextCodec.resolvedEncoding(declared, for: plain))
        } else {
            // The rewriter cannot write these charsets back, but a condition only reads them.
            readOnly = true
            decoded = readOnlyCharset(contentType).flatMap { String(data: plain, encoding: $0) }
        }
        guard let text = decoded else { return .skipped(.bodySkippedNotText) }
        if text.isEmpty { return .empty }
        return readOnly ? .readOnlyText(text) : .text(text)
    }

    /// GBK, GB2312 and GB 18030 (read as GB 18030, which contains the others).
    private static func readOnlyCharset(_ contentType: String?) -> String.Encoding? {
        let names: Set = ["gbk", "gb2312", "gb18030", "x-gbk"]
        for parameter in (contentType ?? "").split(separator: ";").dropFirst() {
            let pair = parameter.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "charset" else {
                continue
            }
            let name = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'")).lowercased()
            guard names.contains(name) else { return nil }
            let gb18030 = CFStringEncodings.GB_18030_2000.rawValue
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(gb18030)))
        }
        return nil
    }

    /// The text after the body rewrites of earlier rules ran on it, in order (spec 5.5.5). Only text is
    /// rewritten (read-only charsets are left as they are: the executor skips them). A step that cannot
    /// run as the executor would run it (an unusable pattern, a timeout, a disabled pattern) leaves the
    /// text unknown, a result over the cap says `bodyTooLarge`: later rows must not read a text the
    /// message will not have. The runs never count strikes against the patterns' breakers: only the
    /// executor's own run does.
    func applying(_ steps: [BodyRewriteStep], limits: RulesLimits, cache: PatternCache) -> BodyPeek {
        guard case .text(var text) = self, !steps.isEmpty else { return self }
        for step in steps {
            if let whole = step.action.wholeText {
                guard whole.utf8.count <= limits.conditionBodyBytes else { return .skipped(.bodyTooLarge) }
                text = whole
                continue
            }
            guard let pattern = try? cache.bodyPattern(step.action) else { return .skipped(.bodySkippedNotText) }
            switch pattern.replace(
                in: text, with: step.action.replacement, scope: step.action.scope,
                maxOutputUnits: limits.conditionBodyBytes, countsStrikes: false)
            {
            case .replaced(let result, _): text = result
            case .noMatch: break
            case .inputTooLong: return .skipped(.bodyTooLarge)
            case .timedOut, .disabled: return .skipped(.bodySkippedNotText)
            }
        }
        return .text(text)
    }
}

/// What to do about a message's body for conditions (D12).
public enum BodyPeekPlan: Sendable, Equatable {
    case collect
    case empty
    case skip(RuleOutcomeCode)
}

/// The message-level rules of what may be peeked; shared by ProxyCore and `LiveMatcher`.
package enum BodyPeekRules {
    /// First match wins: no body, event stream, unknown length or chunked, over the cap, not text.
    /// `knownLength` is the length the caller knows (an HTTP/2 stream that has ended); without it the
    /// `Content-Length` header is read.
    package static func classify(
        headers: [HeaderField], knownLength: Int?, isHeadOrNoBody: Bool, limits: RulesLimits
    ) -> BodyPeekPlan {
        let length = knownLength ?? declaredLength(headers)
        if isHeadOrNoBody || length == 0 { return .empty }
        let contentType = headers.values(for: "content-type").first
        if mediaType(contentType) == "text/event-stream" { return .skip(.bodySkippedStreaming) }
        let chunked = headers.values(for: "transfer-encoding").contains {
            $0.lowercased().split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == "chunked" }
        }
        guard !chunked, let length else { return .skip(.bodySkippedStreaming) }
        if length > limits.conditionBodyBytes { return .skip(.bodyTooLarge) }
        guard BodyTextCodec.isTextLike(contentType: contentType) else { return .skip(.bodySkippedNotText) }
        return .collect
    }

    /// The first `Content-Length` of plain digits; digits too many for an Int are larger than any cap.
    private static func declaredLength(_ headers: [HeaderField]) -> Int? {
        guard let value = headers.values(for: "content-length").first?.trimmingCharacters(in: .whitespaces),
            !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) })
        else { return nil }
        return Int(value) ?? .max
    }

    private static func mediaType(_ contentType: String?) -> String? {
        contentType?.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased()
    }
}

extension RuleOutcomeCode {
    /// A body condition of the rule could not be judged: the body is over the size a condition reads.
    public static let bodyTooLarge = RuleOutcomeCode(rawValue: "bodyTooLarge")!
    /// A body condition of the rule could not be judged: the body is already on disk, so the live count did not read it.
    public static let bodySkippedOnDisk = RuleOutcomeCode(rawValue: "bodySkippedOnDisk")!
    /// A body condition of the rule could not be judged: the body is a stream or its length is unknown.
    public static let bodySkippedStreaming = RuleOutcomeCode(rawValue: "bodySkippedStreaming")!
}
