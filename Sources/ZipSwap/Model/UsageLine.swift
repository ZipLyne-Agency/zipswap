import Foundation

/// One limit of one account, as a row in the panel.
struct UsageLine: Identifiable, Hashable {
    let account: Account
    let window: UsageWindow

    var id: String { "\(account.id)|\(window.label)" }
    var title: String { UsageLine.title(for: window.label) }
    var usedPct: Double { min(100, max(0, window.pct)) }
    var leftPct: Double { 100 - usedPct }
    var isUsedUp: Bool { window.isFull }

    static func title(for label: String) -> String {
        switch label {
        case "5h": return "Session"
        case "Week": return "Weekly"
        case "Day": return "Daily"
        default: return label.prefix(1).uppercased() + label.dropFirst()
        }
    }
}

/// A heads-up when the account in use is nearly out and nothing will take over.
enum LowLimitAlert {
    struct Alert: Equatable {
        let key: String
        let title: String
        let body: String
    }

    /// `autoSwitchOn` with a ready `upNext` means auto-switch will handle it, so no alert.
    static func alert(active: Account?, upNext: Account?, autoSwitchOn: Bool, now: Date = .now) -> Alert? {
        guard let active, active.readingTrusted(at: now), !active.isBlocked else { return nil }
        guard let line = active.relevantWindows.map({ UsageLine(account: active, window: $0) }).max(by: { $0.usedPct < $1.usedPct }),
              line.usedPct >= 90 else { return nil }
        if autoSwitchOn && upNext != nil { return nil }
        let reset = line.window.resetsAt.map { Int($0.timeIntervalSince1970 / 60) } ?? 0
        let title = "\(active.title) has \(Format.pct(line.leftPct)) left"
        let body: String
        if let upNext {
            body = "\(line.title) resets \(line.window.resetsAt.map { Format.resetClock($0, now: now) } ?? "later"). Switch to \(upNext.title) to keep going."
        } else {
            body = "\(line.title) resets \(line.window.resetsAt.map { Format.resetClock($0, now: now) } ?? "later"). No other \(active.provider.title) account is ready."
        }
        return Alert(key: "\(active.id)|\(line.window.label)|\(reset)", title: title, body: body)
    }
}
