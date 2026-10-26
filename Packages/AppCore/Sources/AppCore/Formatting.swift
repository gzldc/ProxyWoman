import Foundation
import Localization

public enum Formatting {
    private static let placeholder = "–"

    /// 24 小时制 "09:39:01.799"；12 小时制 "9:39:01.799 AM"；
    /// 完整时间 "2026-10-15 09:39:01.799 +08:00"（12 小时制时为 "2026-10-15 9:39:01.799 AM +08:00"）。
    public static func time(
        _ date: Date, use24Hour: Bool, full: Bool, timeZone: TimeZone = .current, locale: Locale = L10n.locale
    ) -> String {
        timeFormatters.string(from: date, use24Hour: use24Hour, full: full, timeZone: timeZone, locale: locale)
    }

    /// nil 或 0 显示 "–"。二进制单位（1 KB = 1024 字节），例如 1536 → "1.5 KB"。
    public static func size(_ bytes: Int?) -> String {
        guard let bytes, bytes > 0 else { return placeholder }
        return sizeFormatter.string(fromByteCount: Int64(bytes))
    }

    /// 每秒字节数，始终以 KB/s 为单位（1 KB = 1024 字节），满 1024 KB/s 改用 MB/s。
    /// 小于 10 保留一位小数（整数不带 ".0"），否则取整：0 → "0 KB/s"，512 → "0.5 KB/s"，
    /// 12 KB → "12 KB/s"，1.5 MB → "1.5 MB/s"。
    public static func rate(_ bytesPerSecond: Double, locale: Locale = L10n.locale) -> String {
        let kilobytes = max(bytesPerSecond, 0) / 1024
        if roundedForRate(kilobytes) < 1024 { return rateNumber(kilobytes, locale: locale) + " KB/s" }
        return rateNumber(kilobytes / 1024, locale: locale) + " MB/s"
    }

    private static func roundedForRate(_ value: Double) -> Double {
        value < 10 ? (value * 10).rounded() / 10 : value.rounded()
    }

    private static func rateNumber(_ value: Double, locale: Locale) -> String {
        let rounded = roundedForRate(value)
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.1f", locale: locale, rounded)
    }

    /// nil → "–"；小于 1 秒 → "967 ms"；其余 → "12.60 s"。
    public static func duration(_ seconds: TimeInterval?, locale: Locale = L10n.locale) -> String {
        guard let seconds else { return placeholder }
        if seconds < 1 { return "\(Int((seconds * 1000).rounded())) ms" }
        return String(format: "%.2f s", locale: locale, seconds)
    }

    /// Locale controls date ordering and names; preserve a 24-hour clock, seconds and UTC offset.
    public static func certificateDate(
        _ date: Date, timeZone: TimeZone = .current, locale: Locale = L10n.locale
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("yyyyMMMMdEEEE HHmmss ZZZZZ")
        return formatter.string(from: date)
    }

    public static func selectedRows(selected: Int, total: Int, localizer: Localizer = L10n.localizer) -> String {
        localizer.format("statusBar.selectedRows", arguments: [selected, total])
    }

    public static func moreFilters(_ count: Int, localizer: Localizer = L10n.localizer) -> String {
        localizer.format("quickFilterBar.moreFiltersCount", arguments: [count])
    }

    public static func deletionLimits(
        maxFlows: Int, maxSpilledBytes: Int, localizer: Localizer = L10n.localizer
    ) -> String {
        localizer.format(
            "advancedPane.deletionLimits",
            arguments: [
                maxFlows, maxFlows.formatted(.number.locale(localizer.locale)),
                maxSpilledBytes, ByteCountFormatter.string(fromByteCount: Int64(maxSpilledBytes), countStyle: .binary),
            ])
    }

    // MARK: - 缓存

    private static let timeFormatters = TimeFormatterCache()
    private static let sizeFormatter = SizeFormatterBox()
}

/// `ByteCountFormatter` 默认是自适应的：1536 字节会被取整成 "2 KB"。
/// 关闭 `isAdaptive` 后保留小数位，得到 "1.5 KB"。
private final class SizeFormatterBox: @unchecked Sendable {
    private let lock = NSLock()
    private let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .memory
        f.isAdaptive = false
        return f
    }()

    func string(fromByteCount bytes: Int64) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(fromByteCount: bytes)
    }
}

/// `DateFormatter` 不是 `Sendable`，也并非线程安全；缓存在锁内创建并使用，调用方拿不到实例。
private final class TimeFormatterCache: @unchecked Sendable {
    private struct Key: Hashable {
        var use24Hour: Bool
        var full: Bool
        var timeZone: TimeZone
        var locale: Locale
    }

    private let lock = NSLock()
    private var formatters: [Key: DateFormatter] = [:]

    func string(from date: Date, use24Hour: Bool, full: Bool, timeZone: TimeZone, locale: Locale) -> String {
        let key = Key(use24Hour: use24Hour, full: full, timeZone: timeZone, locale: locale)
        lock.lock()
        defer { lock.unlock() }
        let formatter: DateFormatter
        if let cached = formatters[key] {
            formatter = cached
        } else {
            formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = timeZone
            formatter.dateFormat = Self.pattern(use24Hour: use24Hour, full: full)
            formatters[key] = formatter
        }
        return formatter.string(from: date)
    }

    private static func pattern(use24Hour: Bool, full: Bool) -> String {
        switch (use24Hour, full) {
        case (true, false): "HH:mm:ss.SSS"
        case (false, false): "h:mm:ss.SSS a"
        case (true, true): "yyyy-MM-dd HH:mm:ss.SSS xxx"
        case (false, true): "yyyy-MM-dd h:mm:ss.SSS a xxx"
        }
    }
}
