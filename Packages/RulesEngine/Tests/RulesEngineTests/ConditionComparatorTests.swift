import Foundation
import Testing

@testable import RulesEngine

@Suite("ConditionComparator")
struct ConditionComparatorTests {
    private func text(_ op: ConditionOperator, _ actual: String, _ expected: String = "", cs: Bool = false) -> Bool {
        TextComparison.test(op, actual: actual, expected: expected, caseSensitive: cs)
    }

    @Test func containsIsCaseInsensitiveByDefault() {
        #expect(text(.contains, "Hello World", "WORLD"))
        #expect(text(.equals, "ABC", "abc"))
        #expect(text(.startsWith, "ABC", "ab"))
    }

    @Test func caseSensitiveFlagIsHonoured() {
        #expect(!text(.contains, "Hello World", "WORLD", cs: true))
        #expect(text(.contains, "Hello World", "World", cs: true))
        #expect(!text(.equals, "ABC", "abc", cs: true))
        #expect(!text(.startsWith, "ABC", "ab", cs: true))
        #expect(!text(.endsWith, "ABC", "bc", cs: true))
    }

    @Test func notContainsAndNotEqualsAreNegations() {
        for cs in [false, true] {
            for (a, e) in [("abc", "b"), ("abc", "x"), ("ABC", "b"), ("abc", "abc"), ("abc", "ABC"), ("", "")] {
                #expect(text(.notContains, a, e, cs: cs) == !text(.contains, a, e, cs: cs))
                #expect(text(.notEquals, a, e, cs: cs) == !text(.equals, a, e, cs: cs))
            }
        }
    }

    @Test func startsWithEndsWith() {
        #expect(text(.startsWith, "/api/v1", "/api"))
        #expect(!text(.startsWith, "/api/v1", "api"))
        #expect(text(.endsWith, "/api/v1", "v1"))
        #expect(!text(.endsWith, "/api/v1", "api"))
        #expect(!text(.startsWith, "a", "ab"))
        #expect(!text(.endsWith, "a", "ba"))
    }

    @Test func isEmptyAndIsNotEmptyIgnoreExpected() {
        #expect(text(.isEmpty, "", "whatever"))
        #expect(!text(.isEmpty, "x", ""))
        #expect(text(.isNotEmpty, "x", "whatever"))
        #expect(!text(.isNotEmpty, "", "x"))
    }

    @Test func emptyExpectedContainsIsTrue() {
        #expect(text(.contains, "abc", ""))
        #expect(text(.contains, "", ""))
        #expect(!text(.notContains, "abc", ""))
    }

    @Test func turkishDottedIDoesNotLeakTheLocale() {
        // `lowercased()` is locale independent: "I" -> "i", never the dotless "ı".
        #expect(text(.equals, "I", "i"))
        #expect(!text(.equals, "I", "ı"))
        #expect(!text(.equals, "ı", "I"))
    }

    @Test func regexAndNumericOperatorsAreNotTextComparisons() {
        #expect(!text(.regex, "a", "a"))
        #expect(!text(.greaterThan, "b", "a"))
    }

    // MARK: numbers

    private func number(_ op: ConditionOperator, _ actual: Int, _ expected: String) -> Bool? {
        NumberComparison.test(op, actual: actual, expected: expected)
    }

    @Test func numberOperatorsIncludeRange() {
        #expect(number(.equals, 200, "200") == true)
        #expect(number(.notEquals, 200, "200") == false)
        #expect(number(.greaterThan, 5, "4") == true)
        #expect(number(.greaterThan, 4, "4") == false)
        #expect(number(.greaterOrEqual, 4, "4") == true)
        #expect(number(.lessThan, 4, "4") == false)
        #expect(number(.lessOrEqual, 4, "4") == true)
        #expect(number(.inRange, 200, "200-299") == true)
        #expect(number(.inRange, 299, "200-299") == true)
        #expect(number(.inRange, 300, "200-299") == false)
        #expect(number(.inRange, 199, "200-299") == false)
    }

    @Test func numberRangeRejectsReversedBounds() {
        #expect(number(.inRange, 250, "299-200") == nil)
        #expect(number(.inRange, 250, "200") == nil)
    }

    @Test func unparsableNumberReturnsNil() {
        #expect(number(.equals, 1, "abc") == nil)
        #expect(number(.equals, 1, "") == nil)
        #expect(number(.lessThan, 1, "1.5") == nil)
    }

    // MARK: dates

    private let utc = TimeZone(identifier: "UTC")!
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    private func day(_ op: ConditionOperator, _ actual: Date, _ expected: String, _ zone: TimeZone) -> Bool? {
        DateComparison.test(op, actual: actual, expected: expected, timeZone: zone)
    }

    @Test func dateEqualsMeansSameLocalDay() {
        #expect(day(.equals, date("2026-10-23T00:00:00Z"), "2026-10-23", utc) == true)
        #expect(day(.equals, date("2026-10-23T23:59:59Z"), "2026-10-23", utc) == true)
        // Across midnight.
        #expect(day(.equals, date("2026-10-24T00:00:00Z"), "2026-10-23", utc) == false)
        #expect(day(.equals, date("2026-10-22T23:59:59Z"), "2026-10-23", utc) == false)
        // Across zones: 20:00Z on the 22nd is already the 23rd in Tokyo.
        let instant = date("2026-10-22T20:00:00Z")
        #expect(day(.equals, instant, "2026-10-23", tokyo) == true)
        #expect(day(.equals, instant, "2026-10-23", utc) == false)
        #expect(day(.notEquals, instant, "2026-10-23", utc) == true)
    }

    @Test func dateBeforeAfterAreStrict() {
        let noon = date("2026-10-23T12:00:00Z")
        #expect(day(.before, noon, "2026-10-23", utc) == false)
        #expect(day(.before, noon, "2026-10-24", utc) == true)
        #expect(day(.after, noon, "2026-10-23", utc) == false)
        #expect(day(.after, noon, "2026-10-22", utc) == true)
        #expect(day(.after, date("2026-10-24T00:00:00Z"), "2026-10-23", utc) == true)
    }

    @Test func dateRangeIncludesBothDays() {
        let range = "2026-10-20..2026-10-22"
        #expect(day(.inRange, date("2026-10-20T00:00:00Z"), range, utc) == true)
        #expect(day(.inRange, date("2026-10-22T23:59:59Z"), range, utc) == true)
        #expect(day(.inRange, date("2026-10-23T00:00:00Z"), range, utc) == false)
        #expect(day(.inRange, date("2026-10-19T23:59:59Z"), range, utc) == false)
        #expect(day(.inRange, date("2026-10-21T00:00:00Z"), "2026-10-22..2026-10-20", utc) == nil)
    }

    @Test func unparsableDateReturnsNil() {
        #expect(day(.equals, Date(), "2026-02-30", utc) == nil)
        #expect(day(.equals, Date(), "yesterday", utc) == nil)
    }
}
