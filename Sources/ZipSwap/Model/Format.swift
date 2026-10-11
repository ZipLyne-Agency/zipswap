import Foundation

enum Format {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Parses claude-swap timestamps, which carry six fractional digits that
    /// ISO8601DateFormatter refuses.
    static func date(_ value: Any?) -> Date? {
        if let seconds = value as? Double { return Date(timeIntervalSince1970: seconds) }
        if let seconds = value as? Int { return Date(timeIntervalSince1970: TimeInterval(seconds)) }
        guard var text = value as? String else { return nil }
        if let dot = text.firstIndex(of: ".") {
            let rest = text[dot...].drop(while: { $0 == "." || $0.isNumber })
            text = String(text[..<dot]) + rest
        }
        return iso.date(from: text)
    }

    static func countdown(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "not started" }
        let seconds = Int(date.timeIntervalSince(now))
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

    static func clock(_ date: Date) -> String {
        let cal = Calendar.current
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        if cal.isDateInToday(date) { return "Today \(time)" }
        if cal.isDateInTomorrow(date) { return "Tomorrow \(time)" }
        return date.formatted(.dateTime.month(.abbreviated).day()) + " " + time
    }

    /// "09:59" today, otherwise "Tue 09:59": short enough for a table cell.
    static func backTime(_ date: Date) -> String {
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        if Calendar.current.isDateInToday(date) { return time }
        return date.formatted(.dateTime.weekday(.abbreviated)) + " " + time
    }

    static func ago(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "never" }
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }

    static func pct(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    static func expectedPct(for window: UsageWindow, windowMinutes: Double) -> Double? {
        guard let reset = window.resetsAt else { return nil }
        let length = windowMinutes * 60
        let start = reset.addingTimeInterval(-length)
        let elapsed = Date.now.timeIntervalSince(start)
        guard elapsed > 0, length > 0 else { return nil }
        return min(100, elapsed / length * 100)
    }

    static func projectExhaustion(_ window: UsageWindow, expected: Double) -> Date? {
        guard let reset = window.resetsAt, window.pct > 0, expected > 0 else { return nil }
        let length = 10080.0 * 60
        let start = reset.addingTimeInterval(-length)
        let elapsed = Date.now.timeIntervalSince(start)
        let rate = window.pct / elapsed
        let remaining = (100 - window.pct) / rate
        let date = Date.now.addingTimeInterval(remaining)
        return date < reset ? date : nil
    }

    static func credits(_ raw: String?) -> String? {
        guard let raw, let value = Double(raw) else { return nil }
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
