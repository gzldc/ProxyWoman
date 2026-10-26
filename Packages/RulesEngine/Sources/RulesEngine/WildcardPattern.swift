/// A whole-string wildcard pattern: `*` matches any number (including zero) of Unicode scalars,
/// `?` exactly one, and `\*`, `\?`, `\\` are literals. Matching is iterative (no recursion) and
/// bounded by O(input x pattern); inputs longer than `maxInputScalars` never match.
public struct WildcardPattern: Sendable, Equatable {
    public static let maxPatternBytes = 1024
    public static let maxInputScalars = 8192

    private enum Token: Sendable, Equatable {
        case scalar(UInt32)
        case any
        case star
    }

    private let tokens: [Token]

    public init(_ pattern: String) throws {
        guard !pattern.isEmpty else { throw PatternError.empty }
        guard pattern.utf8.count <= Self.maxPatternBytes else { throw PatternError.tooLong }
        var tokens: [Token] = []
        var iterator = pattern.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            switch scalar {
            case "*":
                // Consecutive stars are equivalent to one; collapsing keeps the step bound tight.
                if tokens.last != .star { tokens.append(.star) }
            case "?":
                tokens.append(.any)
            case "\\":
                guard let escaped = iterator.next(), escaped == "*" || escaped == "?" || escaped == "\\" else {
                    throw PatternError.invalidEscape
                }
                tokens.append(.scalar(escaped.value))
            default:
                tokens.append(.scalar(scalar.value))
            }
        }
        self.tokens = tokens
    }

    public func matches(_ text: String) -> Bool {
        matchWithSteps(text).matched
    }

    /// Matches and reports the number of loop iterations, so tests can assert the step bound.
    package func matchWithSteps(_ text: String) -> (matched: Bool, steps: Int) {
        let input = Array(text.unicodeScalars.lazy.prefix(Self.maxInputScalars + 1).map(\.value))
        guard input.count <= Self.maxInputScalars else { return (false, 0) }
        var steps = 0
        var t = 0  // input index
        var p = 0  // token index
        var starToken = -1  // index of the most recent star
        var starInput = 0  // input index that star currently extends to
        while t < input.count {
            steps += 1
            if p < tokens.count {
                switch tokens[p] {
                case .star:
                    starToken = p
                    starInput = t
                    p += 1
                    continue
                case .any:
                    t += 1
                    p += 1
                    continue
                case .scalar(let value) where value == input[t]:
                    t += 1
                    p += 1
                    continue
                case .scalar:
                    break
                }
            }
            guard starToken >= 0 else { return (false, steps) }
            starInput += 1
            t = starInput
            p = starToken + 1
        }
        while p < tokens.count, tokens[p] == .star {
            steps += 1
            p += 1
        }
        return (p == tokens.count, steps)
    }
}
