import Foundation
import Testing

@testable import RulesEngine

@Suite("RegexPattern.replacingMatches")
struct RegexReplaceTests {
    private func find(_ pattern: String) throws -> RegexPattern {
        try RegexPattern(pattern, mode: .find, caseInsensitive: false)
    }

    @Test func replacesEveryMatch() throws {
        let result = try find("a").replacingMatches(in: "banana", template: "o", allowance: RegexAllowance())
        #expect(result == .replaced("bonono"))
    }

    @Test func noMatchIsReportedAsSuch() throws {
        #expect(try find("z").replacingMatches(in: "banana", template: "o", allowance: RegexAllowance()) == .noMatch)
    }

    @Test func emptyMatchesInsertAtEveryPosition() throws {
        let result = try find("x*").replacingMatches(in: "ab", template: "-", allowance: RegexAllowance())
        #expect(result == .replaced("-a-b-"))
    }

    @Test func nonBMPTextSurvives() throws {
        let result = try find("(\\p{L})").replacingMatches(in: "\u{1F600}a\u{1F600}", template: "[$1]", allowance: RegexAllowance())
        #expect(result == .replaced("\u{1F600}[a]\u{1F600}"))
        let emoji = try find("\u{1F600}").replacingMatches(in: "x\u{1F600}y", template: "!", allowance: RegexAllowance())
        #expect(emoji == .replaced("x!y"))
    }

    @Test func templateExpandsGroupsAndEscapesDollar() throws {
        let result = try find("(\\d+)-(\\d+)").replacingMatches(in: "12-34", template: "$2-$1\\$", allowance: RegexAllowance())
        #expect(result == .replaced("34-12$"))
    }

    @Test func consumesTheSharedAllowance() throws {
        let clock = StepClock()
        let allowance = RegexAllowance(total: .milliseconds(8), clock: { clock.read() })
        _ = try find("a").replacingMatches(in: "banana", template: "o", allowance: allowance)
        #expect(allowance.remaining < .milliseconds(8))
    }

    @Test func anExhaustedAllowanceTimesOutWithoutRunning() throws {
        let allowance = RegexAllowance(total: .zero)
        #expect(try find("a").replacingMatches(in: "a", template: "b", allowance: allowance) == .timedOut)
    }

    @Test func inputOverTheCapIsRefused() throws {
        let text = String(repeating: "a", count: RegexPattern.maxInputBytes + 1)
        #expect(try find("a").replacingMatches(in: text, template: "b", allowance: RegexAllowance()) == .inputTooLong)
    }

    @Test func outputOverTheCapIsRefusedInsteadOfGrowingWithoutBound() throws {
        // An empty-match pattern fires at every position; with a large template the output explodes.
        let text = String(repeating: "a", count: 1_000)
        let template = String(repeating: "t", count: 100)
        let pattern = try find("x*")
        #expect(pattern.replacingMatches(in: text, template: template, allowance: RegexAllowance()) == .inputTooLong)
        // The cap is a parameter: the same work fits under a larger one and stops under a smaller one.
        #expect(
            pattern.replacingMatches(in: text, template: template, allowance: RegexAllowance(), outputLimit: 200_000)
                != .inputTooLong)
        #expect(
            pattern.replacingMatches(in: "ab", template: "-", allowance: RegexAllowance(), outputLimit: 4)
                == .inputTooLong)
        #expect(
            pattern.replacingMatches(in: "ab", template: "-", allowance: RegexAllowance(), outputLimit: 5)
                == .replaced("-a-b-"))
    }

    @Test func aWholeModePatternDoesNothing() throws {
        let whole = try RegexPattern("a", caseInsensitive: false)
        #expect(whole.replacingMatches(in: "a", template: "b", allowance: RegexAllowance()) == .noMatch)
    }
}
