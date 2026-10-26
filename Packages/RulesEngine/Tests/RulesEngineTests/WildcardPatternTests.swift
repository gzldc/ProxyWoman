import Testing

@testable import RulesEngine

@Suite("WildcardPattern")
struct WildcardPatternTests {
    private func match(_ pattern: String, _ text: String) throws -> Bool {
        try WildcardPattern(pattern).matches(text)
    }

    @Test func starMatchesAcrossSlashAndDots() throws {
        #expect(try match("*.example.com", "a.b.example.com"))
        #expect(try match("*.example.com", "a/b.example.com"))
        #expect(try !match("*.example.com", "example.com"))
    }

    @Test func questionMatchesExactlyOneScalar() throws {
        #expect(try match("a?c", "abc"))
        #expect(try match("a?c", "a😀c"))
        #expect(try !match("a?c", "ac"))
        #expect(try !match("a?c", "abbc"))
    }

    @Test func escapesAreLiteral() throws {
        #expect(try match("a\\*b", "a*b"))
        #expect(try !match("a\\*b", "aXb"))
        #expect(try !match("a\\*b", "ab"))
        #expect(try match("a\\?b", "a?b"))
        #expect(try !match("a\\?b", "aXb"))
        #expect(try match("a\\\\b", "a\\b"))
        #expect(try !match("a\\\\b", "aXb"))
    }

    @Test func invalidEscapesAreRejected() {
        #expect(throws: PatternError.invalidEscape) { try WildcardPattern("a\\x") }
        #expect(throws: PatternError.invalidEscape) { try WildcardPattern("abc\\") }
    }

    @Test func emptyAndTooLongAreRejected() {
        #expect(throws: PatternError.empty) { try WildcardPattern("") }
        #expect(throws: PatternError.tooLong) {
            try WildcardPattern(String(repeating: "a", count: WildcardPattern.maxPatternBytes + 1))
        }
        #expect(throws: Never.self) {
            try WildcardPattern(String(repeating: "a", count: WildcardPattern.maxPatternBytes))
        }
    }

    @Test func matchIsWholeString() throws {
        #expect(try match("/api/*", "/api/"))
        #expect(try match("/api/*", "/api/x?y=1"))
        #expect(try !match("/api/*", "/api"))
        #expect(try !match("/api/*", "/v1/api/x"))
    }

    @Test func pathIsCaseSensitive() throws {
        #expect(try match("/Api/*", "/Api/x"))
        #expect(try !match("/Api/*", "/api/x"))
    }

    @Test func overlongInputNeverMatches() throws {
        let long = String(repeating: "a", count: WildcardPattern.maxInputScalars + 1)
        #expect(try !match("*", long))
        let ok = String(repeating: "a", count: WildcardPattern.maxInputScalars)
        #expect(try match("*", ok))
    }

    @Test func pathologicalStarsStayWithinStepBound() throws {
        let pattern = try WildcardPattern(String(repeating: "*a", count: 30) + "b")
        let input = String(repeating: "a", count: 8192)
        let result = pattern.matchWithSteps(input)
        #expect(result.matched == false)
        #expect(result.steps <= 8192 * 64)
    }

    @Test func equalityFollowsThePattern() throws {
        #expect(try WildcardPattern("a*") == WildcardPattern("a*"))
        #expect(try WildcardPattern("a*") != WildcardPattern("a?"))
    }
}
