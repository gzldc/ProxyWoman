import FlowStore
import Foundation

public enum BodyRewriteResult: Sendable, Equatable {
    /// The bytes changed: `data` is the decoded, rewritten plaintext, so the caller must drop
    /// `Content-Encoding` and fix the length.
    case rewritten(Data, [RuleOutcome])
    /// Forward the original bytes: nothing matched, or the whole message was skipped (the
    /// outcomes say why).
    case unchanged([RuleOutcome])
}

/// Applies find-and-replace steps to one collected body: decode, strict text view, each step in
/// order on the same text, re-encode. It never partially rewrites: any failure after decoding
/// leaves the original bytes to be forwarded untouched.
public enum BodyRewriter {
    /// Call from a `Task`; it checks `Task.isCancelled` before each step and a running replace
    /// stops at its next progress report, after which `CancellationError` is thrown.
    public static func apply(
        steps: [BodyRewriteStep], to body: Data, contentType: String?, contentEncoding: String?,
        limits: RulesLimits, cache: PatternCache
    ) async throws -> BodyRewriteResult {
        guard !steps.isEmpty else { return .unchanged([]) }
        try Task.checkCancellation()

        func skipped(_ code: RuleOutcomeCode) -> BodyRewriteResult {
            .unchanged(steps.map { RuleOutcome(ruleID: $0.ruleID, code: code, actionIndex: $0.actionIndex) })
        }

        guard !body.isEmpty else { return skipped(.bodySkippedNoBody) }
        guard BodyTextCodec.isTextLike(contentType: contentType) else { return skipped(.bodySkippedNotText) }
        guard body.count <= limits.rewriteBodyBytes else { return skipped(.bodySkippedTooLarge) }

        let decoded: Data
        do {
            decoded = try BodyContentCodec.decode(
                body, contentEncoding: contentEncoding, maxOutputBytes: limits.rewriteBodyBytes)
        } catch BodyContentCodec.Failure.tooLarge {
            return skipped(.bodySkippedTooLarge)
        } catch {
            return skipped(.bodySkippedUndecodable)
        }

        guard let declared = BodyTextCodec.encoding(contentType: contentType) else {
            return skipped(.bodySkippedUndecodable)
        }
        let encoding = BodyTextCodec.resolvedEncoding(declared, for: decoded)
        let original: String
        do { original = try BodyTextCodec.decode(decoded, as: encoding) } catch { return skipped(.bodySkippedUndecodable) }

        var text = original
        var outcomes: [RuleOutcome] = []
        for step in steps {
            try Task.checkCancellation()
            let code: RuleOutcomeCode
            if let whole = step.action.wholeText {
                guard whole.utf8.count <= limits.rewriteBodyBytes else { return skipped(.bodySkippedTooLarge) }
                text = whole
                code = .applied
            } else {
                do {
                    let pattern = try cache.bodyPattern(step.action)
                    switch pattern.replace(
                        in: text, with: step.action.replacement, scope: step.action.scope,
                        maxOutputUnits: limits.rewriteBodyBytes)
                    {
                    case .replaced(let result, _):
                        text = result
                        code = .applied
                    case .noMatch: code = .bodyNoMatch
                    case .timedOut: code = .patternTimedOut
                    case .disabled: code = .patternDisabled
                    case .inputTooLong: return skipped(.bodySkippedTooLarge)
                    }
                } catch {
                    // Rules are validated when saved, so this is a stale or hand-edited pattern; the
                    // step cannot run until the rule is saved again, which is what "disabled" says.
                    code = .patternDisabled
                }
            }
            // A cancelled replace returns early without a result.
            try Task.checkCancellation()
            outcomes.append(RuleOutcome(ruleID: step.ruleID, code: code, actionIndex: step.actionIndex))
        }

        guard text.utf16.elementsEqual(original.utf16) == false else { return .unchanged(outcomes) }
        let encoded: Data
        do { encoded = try BodyTextCodec.encode(text, as: encoding) } catch { return skipped(.bodySkippedUndecodable) }
        guard encoded.count <= limits.rewriteBodyBytes else { return skipped(.bodySkippedTooLarge) }
        guard encoded != decoded else { return .unchanged(outcomes) }
        return .rewritten(encoded, outcomes)
    }
}
