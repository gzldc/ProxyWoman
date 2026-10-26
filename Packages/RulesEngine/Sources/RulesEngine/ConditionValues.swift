import Foundation

/// Parsing of the value texts of condition rows (D7).
enum ConditionValues {
    /// Plain ASCII digits only, at most 18 of them so the value cannot overflow.
    static func wholeNumber(_ text: String) -> Int? {
        let digits = text.utf8
        guard !digits.isEmpty, digits.count <= 18 else { return nil }
        var number = 0
        for byte in digits {
            guard byte >= 0x30, byte <= 0x39 else { return nil }
            number = number * 10 + Int(byte - 0x30)
        }
        return number
    }

    /// `lo-hi` with `lo <= hi`, both whole numbers.
    static func numberRange(_ text: String) -> ClosedRange<Int>? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let low = wholeNumber(String(parts[0])), let high = wholeNumber(String(parts[1])),
            low <= high
        else { return nil }
        return low...high
    }

    /// `yyyy-MM-dd` as that local day: from 00:00 up to, not including, the next day's 00:00.
    static func day(_ text: String, timeZone: TimeZone) -> DateInterval? {
        let bytes = Array(text.utf8)
        guard bytes.count == 10, bytes[4] == 0x2D, bytes[7] == 0x2D else { return nil }
        func digits(_ range: Range<Int>) -> Int? {
            var number = 0
            for byte in bytes[range] {
                guard byte >= 0x30, byte <= 0x39 else { return nil }
                number = number * 10 + Int(byte - 0x30)
            }
            return number
        }
        guard let year = digits(0..<4), let month = digits(5..<7), let dayOfMonth = digits(8..<10), year >= 1 else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(year: year, month: month, day: dayOfMonth)
        guard let start = calendar.date(from: components),
            calendar.dateComponents([.year, .month, .day], from: start) == components,
            let end = calendar.date(byAdding: .day, value: 1, to: start)
        else { return nil }
        return DateInterval(start: start, end: end)
    }

    /// `yyyy-MM-dd..yyyy-MM-dd`, both ends included, first day not after the second.
    static func dayRange(_ text: String, timeZone: TimeZone) -> DateInterval? {
        let parts = text.components(separatedBy: "..")
        guard parts.count == 2, let first = day(parts[0], timeZone: timeZone),
            let last = day(parts[1], timeZone: timeZone), first.start <= last.start
        else { return nil }
        return DateInterval(start: first.start, end: last.end)
    }
}
