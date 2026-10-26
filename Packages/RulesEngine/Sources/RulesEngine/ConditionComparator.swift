import Foundation

/// Text comparisons of a condition row (everything but `regex`). A missing value is the empty
/// string; the caller decides that.
enum TextComparison {
    static func test(_ op: ConditionOperator, actual: String, expected: String, caseSensitive: Bool) -> Bool {
        switch op {
        case .isEmpty: return actual.isEmpty
        case .isNotEmpty: return !actual.isEmpty
        default: break
        }
        // `lowercased()` does not depend on the locale.
        let left = Array((caseSensitive ? actual : actual.lowercased()).utf8)
        let right = Array((caseSensitive ? expected : expected.lowercased()).utf8)
        switch op {
        case .equals: return left == right
        case .notEquals: return left != right
        case .contains: return contains(left, right)
        case .notContains: return !contains(left, right)
        case .startsWith: return left.starts(with: right)
        case .endsWith: return left.reversed().starts(with: right.reversed())
        default: return false
        }
    }

    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        if needle.isEmpty { return true }
        guard needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count)
        where haystack[start..<start + needle.count].elementsEqual(needle) {
            return true
        }
        return false
    }
}

enum NumberComparison {
    /// `nil` when `expected` cannot be read for this operator (or the operator is not numeric).
    static func test(_ op: ConditionOperator, actual: Int, expected: String) -> Bool? {
        if op == .inRange { return ConditionValues.numberRange(expected).map { $0.contains(actual) } }
        guard let number = ConditionValues.wholeNumber(expected) else { return nil }
        switch op {
        case .equals: return actual == number
        case .notEquals: return actual != number
        case .greaterThan: return actual > number
        case .greaterOrEqual: return actual >= number
        case .lessThan: return actual < number
        case .lessOrEqual: return actual <= number
        default: return nil
        }
    }
}

enum DateComparison {
    /// Days are local days in `timeZone`. `nil` when `expected` cannot be read for this operator.
    static func test(_ op: ConditionOperator, actual: Date, expected: String, timeZone: TimeZone) -> Bool? {
        if op == .inRange {
            guard let span = ConditionValues.dayRange(expected, timeZone: timeZone) else { return nil }
            return actual >= span.start && actual < span.end
        }
        guard let span = ConditionValues.day(expected, timeZone: timeZone) else { return nil }
        let inDay = actual >= span.start && actual < span.end
        switch op {
        case .equals: return inDay
        case .notEquals: return !inDay
        case .before: return actual < span.start
        case .after: return actual >= span.end
        case .beforeOrEqual: return actual < span.end
        case .afterOrEqual: return actual >= span.start
        default: return nil
        }
    }
}
