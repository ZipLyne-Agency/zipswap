import Foundation

enum Provider: String, CaseIterable, Identifiable, Codable {
    case claude, codex
    var id: String { rawValue }
    var title: String { self == .claude ? "Claude Code" : "Codex" }
}

struct UsageWindow: Identifiable, Hashable {
    var id: String { label }
    let label: String
    let pct: Double
    let resetsAt: Date?
    /// Where usage would be if spread evenly across the window (weekly windows only).
    let expectedPct: Double?
    let projectedExhaustion: Date?
    let willLastToReset: Bool?

    var isFull: Bool { pct >= 100 }
}

struct ResetCredit: Identifiable, Hashable {
    let id: String
    let title: String
    let expiresAt: Date?
}

struct Account: Identifiable, Hashable {
    let id: String
    let provider: Provider
    /// Claude slot number; nil for Codex.
    let slot: Int?
    var name: String
    let email: String
    let plan: String
    let isActive: Bool
    let disabled: Bool
    let windows: [UsageWindow]
    /// A problem worth showing instead of (or next to) usage, like an expired login.
    let problem: String?
    let fetchedAt: Date?
    var credits: String? = nil
    var resetCredits: [ResetCredit] = []
    var limitReached: Bool = false

    /// The name as shown: every word starts with a capital letter.
    var title: String {
        name.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    var initial: String { String(name.first ?? email.first ?? "?").uppercased() }

    var tightest: Double { windows.map(\.pct).max() ?? 0 }

    var isBlocked: Bool { limitReached || windows.contains(where: \.isFull) }

    var fiveHour: UsageWindow? { windows.first { $0.label == "5h" } }
    var weekly: UsageWindow? { windows.first { $0.label == "Week" } }

    /// When a full account becomes usable again.
    var backAt: Date? {
        windows.filter(\.isFull).compactMap(\.resetsAt).max()
    }
}

struct HistoryItem: Identifiable, Hashable {
    let id = UUID()
    let provider: Provider
    let from: String
    let to: String
    let at: Date
    let reason: String
}

enum Pace {
    case under, on, ahead(exhausts: Date?), full(back: Date?), unknown

    static func of(_ account: Account) -> Pace {
        if account.isBlocked { return .full(back: account.backAt) }
        guard let week = account.weekly ?? account.windows.first else { return .unknown }
        let expected = week.expectedPct ?? Format.expectedPct(for: week, windowMinutes: 10080)
        guard let expected else { return .unknown }
        if week.willLastToReset == false || week.pct > expected + 5 {
            return .ahead(exhausts: week.projectedExhaustion ?? Format.projectExhaustion(week, expected: expected))
        }
        if week.pct < expected - 5 { return .under }
        return .on
    }

    var text: String {
        switch self {
        case .under: return "Under pace, lasts to reset"
        case .on: return "Right on pace"
        case .ahead(let date):
            if let date { return "Ahead of pace, runs dry \(Format.clock(date))" }
            return "Ahead of pace"
        case .full(let back):
            if let back { return "Limit reached, back \(Format.clock(back))" }
            return "Limit reached"
        case .unknown: return "Waiting for usage data"
        }
    }
}
