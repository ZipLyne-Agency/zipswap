import Foundation
#if SWIFT_PACKAGE
import HandoffCore
#endif

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
    var windowMinutes: Double? = nil

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
    var isActive: Bool
    var activeIdentityVerified = false
    let disabled: Bool
    var windows: [UsageWindow]
    /// A problem worth showing instead of (or next to) usage, like an expired login.
    var problem: String?
    var fetchedAt: Date?
    /// The windows are the last good reading, not a current one: the fetch is
    /// failing, so the percentages are as old as `fetchedAt`.
    var stale: Bool = false
    var usageRetryAt: Date? = nil
    var credits: String? = nil
    var resetCredits: [ResetCredit] = []
    var pendingResetID: String?
    var resetProblem: String?
    var limitReached: Bool = false
    var providerAccountID: String? = nil
    var watchedModels: [String] = []
    var organizationID: String?

    var relevantWindows: [UsageWindow] {
        guard provider == .claude else { return windows }
        return windows.filter { window in
            window.label == "5h" || window.label == "Week" || watchedModels.contains("all")
                || watchedModels.contains(where: { $0.caseInsensitiveCompare(window.label) == .orderedSame })
        }
    }

    /// The name as shown: every word starts with a capital letter.
    var title: String {
        name.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    var initial: String { String(name.first ?? email.first ?? "?").uppercased() }

    var tightest: Double { relevantWindows.map(\.pct).max() ?? 0 }

    var isBlocked: Bool { limitReached || relevantWindows.contains(where: \.isFull) }

    var trustUntil: Date? {
        UsageValidity.trustUntil(fetchedAt: fetchedAt, exhausted: isBlocked, reset: backAt)
    }

    func readingTrusted(at now: Date) -> Bool {
        problem == nil && !stale && !relevantWindows.isEmpty
            && UsageValidity.isTrusted(fetchedAt: fetchedAt, until: trustUntil, now: now)
    }

    func eligibilityReason(at now: Date = .now) -> String? {
        if disabled { return "Skipped by auto-switch" }
        if let problem { return problem }
        if !readingTrusted(at: now) { return "Awaiting provider update" }
        if isBlocked { return "At its usage limit" }
        return nil
    }

    /// Manual choice still verifies credentials at activation. The helper's
    /// cache cadence must not disable a user's explicit choice between reads.
    func manualSwitchReason() -> String? {
        if let problem { return problem }
        if relevantWindows.isEmpty { return "No confirmed usage reading" }
        if isBlocked { return "At its usage limit" }
        return nil
    }

    var usageDisplay: String { relevantWindows.isEmpty ? "Unknown" : Format.pct(tightest) }
    var watchedWindow: UsageWindow? { relevantWindows.filter { $0.label != "5h" && $0.label != "Week" }.max { $0.pct < $1.pct } }

    var fiveHour: UsageWindow? { windows.first { $0.label == "5h" } }
    var weekly: UsageWindow? { windows.first { $0.label == "Week" } }

    func usageFreshness(now: Date) -> String {
        var reading = fetchedAt.map { "Updated \(Format.ago($0, now: now))" } ?? "No usage reading"
        reading += (!readingTrusted(at: now) && problem == nil ? " · Awaiting provider update" : "")
        guard let retry = usageRetryAt else { return reading }
        return reading + (retry > now ? " · Retry \(Format.countdown(retry, now: now))" : " · Retry due")
    }

    /// When a full account becomes usable again.
    var backAt: Date? {
        relevantWindows.filter(\.isFull).compactMap(\.resetsAt).max()
    }
}

enum UsageGeometry {
    static func fraction(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value / 100)) : 0 }
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
        guard account.readingTrusted(at: .now), let week = account.weekly else { return .unknown }
        let expected = week.expectedPct ?? Format.expectedPct(for: week, windowMinutes: week.windowMinutes ?? 10080)
        guard let expected else { return .unknown }
        if week.willLastToReset == false || week.pct > expected + 5 {
            return .ahead(exhausts: week.projectedExhaustion)
        }
        if week.pct < expected - 5 { return .under }
        return .on
    }

    var text: String {
        switch self {
        case .under: return "Under pace, lasts to reset"
        case .on: return "Right on pace"
        case .ahead(let date):
            if let date { return "Ahead of pace · estimated limit \(Format.clock(date))" }
            return "Ahead of pace"
        case .full(let back):
            if let back { return "Limit reached, back \(Format.resetClock(back))" }
            return "Limit reached"
        case .unknown: return "Waiting for usage data"
        }
    }
}
