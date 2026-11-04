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

    /// Seconds until this limit runs out at the current pace, when the provider's pace says it will.
    func runway(now: Date) -> TimeInterval? {
        guard let date = window.projectedExhaustion, date > now else { return nil }
        return date.timeIntervalSince(now)
    }
}

/// What needs attention, most urgent first: the panel's Priority tab, after
/// OpenUsage's board (MIT, Robin Ebers), shaped for switching accounts.
struct PriorityBoard {
    /// The tightest limit of each account in use, Claude first.
    let inUse: [UsageLine]
    /// The account auto-switch would pick next, per provider.
    let upNext: [Account]
    /// Other accounts' limits with 30% or less left; what runs out soonest first.
    let runningOut: [UsageLine]
    /// Accounts at a limit, soonest back first.
    let usedUp: [UsageLine]
    /// Accounts whose reading failed or whose login needs repair.
    let notices: [Account]
    /// Accounts with no first reading yet.
    let waiting: [Account]

    var isEmpty: Bool { inUse.isEmpty && upNext.isEmpty && runningOut.isEmpty && usedUp.isEmpty && notices.isEmpty && waiting.isEmpty }

    /// Every account has reported and nothing is running out.
    var allClear: Bool {
        waiting.isEmpty && notices.isEmpty && runningOut.isEmpty && usedUp.isEmpty
            && !inUse.isEmpty && inUse.allSatisfy { $0.usedPct < 70 }
    }

    static func make(claude: [Account], codex: [Account], upNext: (Provider) -> Account?, now: Date = .now) -> PriorityBoard {
        let all = claude + codex
        let order = Dictionary(all.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        var inUse: [UsageLine] = []
        var runningOut: [UsageLine] = []
        var usedUp: [UsageLine] = []
        var notices: [Account] = []
        var waiting: [Account] = []

        for account in all {
            if account.awaitingFirstReading { waiting.append(account); continue }
            if account.problem != nil { notices.append(account); continue }
            let windows = account.relevantWindows
            if windows.isEmpty { waiting.append(account); continue }
            let lines = windows.map { UsageLine(account: account, window: $0) }
            if account.isActive {
                if let tightest = lines.max(by: { $0.usedPct < $1.usedPct }) { inUse.append(tightest) }
                continue
            }
            if account.isBlocked {
                // The limit that keeps the account out longest decides when it is back.
                let full = lines.filter(\.isUsedUp)
                let deciding = full.max { ($0.window.resetsAt ?? .distantPast) < ($1.window.resetsAt ?? .distantPast) }
                    ?? lines.max { $0.usedPct < $1.usedPct }
                if let deciding { usedUp.append(deciding) }
                continue
            }
            runningOut += lines.filter { $0.usedPct >= 70 }
        }

        runningOut.sort { lhs, rhs in
            let left = rank(lhs, now: now), right = rank(rhs, now: now)
            if left.tier != right.tier { return left.tier < right.tier }
            if left.closeness != right.closeness { return left.closeness < right.closeness }
            return (order[lhs.account.id] ?? 0) < (order[rhs.account.id] ?? 0)
        }
        usedUp.sort { ($0.window.resetsAt ?? .distantFuture) < ($1.window.resetsAt ?? .distantFuture) }

        return PriorityBoard(
            inUse: inUse,
            upNext: Provider.allCases.compactMap(upNext),
            runningOut: runningOut,
            usedUp: usedUp,
            notices: notices,
            waiting: waiting
        )
    }

    private static func rank(_ line: UsageLine, now: Date) -> (tier: Int, closeness: Double) {
        if let runway = line.runway(now: now) { return (0, runway) }
        return (1, line.leftPct)
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
