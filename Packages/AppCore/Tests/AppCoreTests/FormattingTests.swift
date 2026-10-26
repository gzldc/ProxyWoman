import Foundation
import Testing

@testable import AppCore

@Suite(.productionChinese) struct FormattingTests {
    private let english = Locale(identifier: "en_US_POSIX")
    private let gmt8 = TimeZone(secondsFromGMT: 8 * 3600)!
    /// 2026-10-15 09:39:01.799 +08:00
    private var date: Date {
        var c = DateComponents()
        c.year = 2026
        c.month = 10
        c.day = 15
        c.hour = 9
        c.minute = 39
        c.second = 1
        c.nanosecond = 799_000_000
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = gmt8
        return cal.date(from: c)!
    }

    @Test func time24Hour() {
        #expect(Formatting.time(date, use24Hour: true, full: false, timeZone: gmt8, locale: english) == "09:39:01.799")
    }

    @Test func time12Hour() {
        #expect(
            Formatting.time(date, use24Hour: false, full: false, timeZone: gmt8, locale: english) == "9:39:01.799 AM")
    }

    @Test func time12HourAfternoonUsesUppercasePM() {
        let pm = date.addingTimeInterval(6 * 3600)
        #expect(Formatting.time(pm, use24Hour: false, full: false, timeZone: gmt8, locale: english) == "3:39:01.799 PM")
    }

    @Test func timeFull() {
        #expect(
            Formatting.time(date, use24Hour: true, full: true, timeZone: gmt8, locale: english)
                == "2026-10-15 09:39:01.799 +08:00")
    }

    @Test func timeFull12Hour() {
        #expect(
            Formatting.time(date, use24Hour: false, full: true, timeZone: gmt8, locale: english)
                == "2026-10-15 9:39:01.799 AM +08:00")
    }

    @Test func timeRespectsTimeZone() {
        let utc = TimeZone(secondsFromGMT: 0)!
        #expect(Formatting.time(date, use24Hour: true, full: false, timeZone: utc, locale: english) == "01:39:01.799")
    }

    @Test func sizeShowsDashForNilAndZero() {
        #expect(Formatting.size(nil) == "–")
        #expect(Formatting.size(0) == "–")
    }

    @Test func sizeUsesBinaryUnits() {
        // The system chooses unit spelling; the number must retain binary scaling and precision.
        for (bytes, expected) in [(512, 512.0), (1536, 1.5), (3 * 1024 * 1024, 3.0)] {
            let scanner = Scanner(string: Formatting.size(bytes))
            scanner.locale = Locale.current
            #expect(scanner.scanDouble() == expected)
        }
    }

    @Test func durationFormats() {
        #expect(Formatting.duration(nil, locale: english) == "–")
        #expect(Formatting.duration(0.967, locale: english) == "967 ms")
        #expect(Formatting.duration(12.6, locale: english) == "12.60 s")
        #expect(Formatting.duration(1, locale: english) == "1.00 s")
    }

    @Test func rateShowsZeroAsKilobytesPerSecond() {
        #expect(Formatting.rate(0, locale: english) == "0 KB/s")
        #expect(Formatting.rate(-5, locale: english) == "0 KB/s")
        #expect(Formatting.rate(0.4, locale: english) == "0 KB/s")
        #expect(Formatting.rate(20, locale: english) == "0 KB/s")
    }

    @Test func rateBelowTenKilobytesHasOneDecimal() {
        #expect(Formatting.rate(512, locale: english) == "0.5 KB/s")
        #expect(Formatting.rate(1536, locale: english) == "1.5 KB/s")
        #expect(Formatting.rate(1024, locale: english) == "1 KB/s")
        #expect(Formatting.rate(9.5 * 1024, locale: english) == "9.5 KB/s")
    }

    @Test func rateFromTenKilobytesIsWhole() {
        #expect(Formatting.rate(12 * 1024, locale: english) == "12 KB/s")
        #expect(Formatting.rate(12.4 * 1024, locale: english) == "12 KB/s")
        #expect(Formatting.rate(9.97 * 1024, locale: english) == "10 KB/s")
        #expect(Formatting.rate(1023 * 1024, locale: english) == "1023 KB/s")
    }

    @Test func rateAboveAThousandKilobytesUsesMegabytes() {
        #expect(Formatting.rate(1024 * 1024, locale: english) == "1 MB/s")
        #expect(Formatting.rate(1.5 * 1024 * 1024, locale: english) == "1.5 MB/s")
        #expect(Formatting.rate(3 * 1024 * 1024, locale: english) == "3 MB/s")
        #expect(Formatting.rate(12 * 1024 * 1024, locale: english) == "12 MB/s")
    }
    @Test func alternatingLocalesKeepIndependentTimeCaches() {
        let chinese = Locale(identifier: "zh_CN")
        let en = Formatting.time(date, use24Hour: false, full: false, timeZone: gmt8, locale: english)
        let zh = Formatting.time(date, use24Hour: false, full: false, timeZone: gmt8, locale: chinese)
        #expect(en == "9:39:01.799 AM")
        #expect(zh == "9:39:01.799 上午")
        #expect(Formatting.time(date, use24Hour: false, full: false, timeZone: gmt8, locale: english) == en)
    }

    @Test func decimalFormattingFollowsLocale() {
        let french = Locale(identifier: "fr_FR")
        #expect(Formatting.rate(1536, locale: french) == "1,5 KB/s")
        #expect(Formatting.duration(1.25, locale: french) == "1,25 s")
    }

    @Test func certificateDateKeepsDateTimeAndZoneAcrossLocales() {
        let en = Formatting.certificateDate(date, timeZone: gmt8, locale: english)
        let zh = Formatting.certificateDate(date, timeZone: gmt8, locale: Locale(identifier: "zh_CN"))
        #expect(en.contains("2026") && zh.contains("2026"))
        #expect(en.contains("09:39:01") && zh.contains("09:39:01"))
        #expect(en.contains("+08:00") && zh.contains("+08:00"))
        #expect(en != zh)
    }
}
