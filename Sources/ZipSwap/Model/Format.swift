import Foundation
#if SWIFT_PACKAGE
import HandoffCore
#endif

enum Format {
    static let timeZone = TimeZone(identifier: "Asia/Jerusalem")!
    private static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = timeZone
        return value
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let fractionalISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Provider timestamps can carry fractional seconds or an explicit offset.
    static func date(_ value: Any?) -> Date? {
        if let seconds = JSONScalar.number(value), (0...32_503_680_000).contains(seconds) { return Date(timeIntervalSince1970: seconds) }
        guard let text = value as? String else { return nil }
        guard let date = fractionalISO.date(from: text) ?? iso.date(from: text), displayable(date) else { return nil }
        return date
    }

    static func countdown(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "not started" }
        let interval = date.timeIntervalSince(now)
        guard interval.isFinite, abs(interval) < Double(Int.max / 2) else { return "unknown" }
        let seconds = Int(interval)
        if seconds <= 0 { return "now" }
        let days = seconds / 86400, hours = (seconds % 86400) / 3600, minutes = (seconds % 3600) / 60
        if days > 0 { return "in \(days)d \(hours)h" }
        if hours > 0 { return "in \(hours)h \(minutes)m" }
        return "in \(max(minutes, 1))m"
    }

    /// "4h 49m", "6d 11h": a reset countdown without the "in".
    static func short(_ date: Date?, now: Date = .now) -> String {
        let text = countdown(date, now: now)
        return text.hasPrefix("in ") ? String(text.dropFirst(3)) : text.capitalized
    }

    /// "19:59": always 24-hour. The locale's hour cycle with AM/PM dropped
    /// turned 19:59 into "07:59".
    static func hm(_ date: Date) -> String {
        guard displayable(date) else { return "Unknown" }
        return date.formatted(Date.VerbatimFormatStyle(
            format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
            timeZone: timeZone,
            calendar: calendar
        ))
    }

    static func clock(_ date: Date) -> String {
        clock(date, now: .now)
    }

    static func clock(_ date: Date, now: Date) -> String {
        guard displayable(date) else { return "Unknown" }
        let time = hm(date)
        if calendar.isDate(date, inSameDayAs: now) { return "Today \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) { return "Tomorrow \(time)" }
        return dateText(date, format: "MMM d") + " " + time
    }

    // Reset timestamps jitter by fractions of a second around the minute.
    // Match the provider's minute display without changing the real deadline.
    static func resetClock(_ date: Date) -> String { resetClock(date, now: .now) }
    static func exactReset(_ date: Date) -> String { dateText(date, format: "yyyy-MM-dd HH:mm:ss XXX") + " Israel time" }

    static func resetClock(_ date: Date, now: Date) -> String {
        clock(resetDisplayDate(date), now: now)
    }

    private static func resetDisplayDate(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded() * 60)
    }

    /// "09:59" today, otherwise "Tue 09:59": short enough for a table cell.
    static func backTime(_ date: Date) -> String {
        backTime(date, now: .now)
    }

    static func backTime(_ date: Date, now: Date) -> String {
        guard displayable(date) else { return "Unknown" }
        let date = resetDisplayDate(date)
        let time = hm(date)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        return dateText(date, format: "EEE") + " " + time
    }

    private static func dateText(_ date: Date, format: String) -> String {
        guard displayable(date) else { return "Unknown" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    private static func displayable(_ date: Date) -> Bool {
        date.timeIntervalSince1970.isFinite && (0...32_503_680_000).contains(date.timeIntervalSince1970)
    }

    static func ago(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "never" }
        let interval = now.timeIntervalSince(date)
        guard interval.isFinite, abs(interval) < Double(Int.max / 2) else { return "unknown" }
        let seconds = Int(interval)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }

    static func pct(_ value: Double) -> String {
        guard value.isFinite, (0...100).contains(value) else { return "Unknown" }
        return "\(Int(value.rounded()))%"
    }

    static func expectedPct(for window: UsageWindow, windowMinutes: Double) -> Double? {
        guard let reset = window.resetsAt, windowMinutes.isFinite, windowMinutes > 0, reset > .now else { return nil }
        let length = windowMinutes * 60
        let start = reset.addingTimeInterval(-length)
        let elapsed = Date.now.timeIntervalSince(start)
        guard elapsed > 0, length > 0 else { return nil }
        return min(100, elapsed / length * 100)
    }

    static func projectExhaustion(_ window: UsageWindow, expected: Double) -> Date? {
        guard let reset = window.resetsAt, window.pct > 0, expected > 0 else { return nil }
        let length = (window.windowMinutes ?? 10080) * 60
        let start = reset.addingTimeInterval(-length)
        let elapsed = Date.now.timeIntervalSince(start)
        let rate = window.pct / elapsed
        let remaining = (100 - window.pct) / rate
        let date = Date.now.addingTimeInterval(remaining)
        return date < reset ? date : nil
    }

    static func credits(_ raw: String?) -> String? {
        guard let raw, let value = Double(raw), value.isFinite, value >= 0 else { return nil }
        if value >= 1000 { return String(format: "%.1fk", value / 1000) }
        return String(format: "%.0f", value)
    }

    static func windowLabel(minutes: Int?) -> String {
        guard let minutes else { return "Limit" }
        switch minutes {
        case 300: return "5h"
        case 10080: return "Week"
        case 1440: return "Day"
        default: return minutes % 1440 == 0 ? "\(minutes / 1440)d" : "\(max(minutes / 60, 1))h"
        }
    }
}
