import Foundation

/// ZipSwap's own backstop for Claude auto-switch.
///
/// claude-swap's engine decides from usage readings, and Anthropic's usage API
/// admits roughly 30 reads an hour per account. Within 15 points of the switch
/// line the engine reads every minute, so a long session runs out of reads
/// before the line. During the 429 that follows, the engine keeps trusting the
/// last reading (a lower bound) for up to two hours and reports "below
/// threshold" while Claude Code is already stopped. Logged on 9–11 November
/// 2026: every switch landed 6 minutes to 2 hours after the account ran out.
///
/// This rule needs no fresh reading of the active account. It acts when that
/// reading has stopped updating near the line, when the engine is down, when
/// the account sits at its limit without the engine moving, or when Claude
/// Code itself reported the limit.
enum ClaudeSafetyNet {
    /// claude-swap reads the active account at least every 300 s (plus 10%
    /// jitter) and ZipSwap refreshes every minute, so a reading older than six
    /// minutes means the reads are being refused.
    static let blindAfter: TimeInterval = 360
    /// Same band claude-swap uses for its urgent polling.
    static let margin: Double = 15
    /// Alternates are read every 600 s; allow one missed read plus backoff.
    static let candidateMaxAge: TimeInterval = 1500
    /// Without claude-swap's 429 history, only a much older reading counts as blind.
    static let blindWithoutEvidenceAfter: TimeInterval = 900
    /// A fresh reading of the active account that is this young overrides a
    /// limit report from Claude Code (an ordinary throttle, not a quota).
    static let freshReading: TimeInterval = 180
    /// How long the engine gets to leave an account that is already at its limit.
    static let stuckAfter: TimeInterval = 300

    enum Trigger: String, Equatable {
        /// The active reading stopped updating near the line.
        case blind
        /// Claude Code reported its usage limit.
        case limitReported
        /// The engine isn't running and the active account is over its line.
        case engineDown
        /// The active account has been at its limit without the engine leaving it.
        case stuck
    }

    enum Decision: Equatable {
        case stay
        case switchTo(id: String, trigger: Trigger)
        case noTarget(trigger: Trigger)
    }

    struct Input {
        var accounts: [Account]
        /// The global switch line; a per-account override wins.
        var line: Double
        var engineRunning: Bool
        /// When Claude Code last reported a usage limit from the default
        /// profile, already filtered for age and recent switches.
        var limitReportedAt: Date?
        /// When the active account was first seen at its limit, if it still is.
        var blockedSince: Date?
        /// Accounts this rule left, and when. They stay out until a reading
        /// taken after that moment shows room.
        var left: [String: Date] = [:]
        var now: Date
    }

    static func line(for account: Account, global: Double) -> Double { account.switchLine ?? global }

    /// The single statuses under which a reading is a real (if frozen) measurement.
    /// Login problems and an idle expired token belong to the engine and to Repair Login.
    static func readingUsable(_ account: Account) -> Bool {
        ["ok", "unavailable"].contains(account.usageStatus ?? "ok") && !account.relevantWindows.isEmpty
    }

    static func age(_ account: Account, now: Date) -> TimeInterval? {
        account.fetchedAt.map { now.timeIntervalSince($0) }
    }

    static func trigger(_ input: Input) -> Trigger? {
        guard let active = input.accounts.first(where: \.isActive), active.provider == .claude else { return nil }
        let line = line(for: active, global: input.line)
        let age = age(active, now: input.now)

        if input.limitReportedAt != nil {
            // A young reading with room everywhere means an ordinary throttle.
            let fresh = age.map { $0 <= freshReading } ?? false
            let roomEverywhere = !active.windows.isEmpty && active.windows.allSatisfy { $0.pct < line - margin }
            if !(fresh && roomEverywhere && active.problem == nil) { return .limitReported }
        }
        guard readingUsable(active), let age else { return nil }
        if active.tightest >= line - margin && blind(active, age: age) { return .blind }
        if !input.engineRunning && age < blindAfter && (active.isBlocked || active.tightest >= line) { return .engineDown }
        if let since = input.blockedSince, active.isBlocked, input.now.timeIntervalSince(since) >= stuckAfter { return .stuck }
        return nil
    }

    /// A reading stopped by refused reads, not by a network drop or a sleep:
    /// claude-swap met a 429 after (or just before) the reading was taken.
    static func blind(_ active: Account, age: TimeInterval) -> Bool {
        if active.usageError == "http-429" { return age >= blindAfter }
        guard active.rateLimitKnown else { return age >= blindWithoutEvidenceAfter }
        guard let limited = active.rateLimitedAt, let fetched = active.fetchedAt else { return false }
        return age >= blindAfter && limited >= fetched.addingTimeInterval(-120)
    }

    /// The account auto-switch moves to next: the most room among accounts with
    /// a recent, usable reading, under their own line. The panel's "Next" and
    /// the safety net use this one rule.
    static func nextInLine(_ accounts: [Account], line: Double, left: [String: Date] = [:], now: Date,
                           below ceiling: Double = 100) -> Account? {
        let candidates = accounts.filter { account in
            guard account.provider == .claude, !account.isActive, !account.disabled, account.problem == nil,
                  !account.stale, readingUsable(account), !account.isBlocked,
                  let age = age(account, now: now), age >= -60, age <= candidateMaxAge else { return false }
            if let left = left[account.id], (account.fetchedAt ?? .distantPast) <= left { return false }
            return account.tightest < self.line(for: account, global: line) && account.tightest < ceiling
        }
        return candidates.min { ($0.tightest, $0.slot ?? .max) < ($1.tightest, $1.slot ?? .max) }
    }

    static func target(_ input: Input, trigger: Trigger) -> Account? {
        guard let active = input.accounts.first(where: \.isActive) else { return nil }
        // A reported or confirmed limit means the active account has nothing left,
        // whatever its frozen reading says. A blind reading is only a lower bound,
        // so the target must have more room than it.
        let leaving = trigger == .limitReported || trigger == .stuck || active.isBlocked ? 100 : active.tightest
        return nextInLine(input.accounts, line: input.line, left: input.left, now: input.now, below: leaving)
    }

    static func decide(_ input: Input) -> Decision {
        guard let trigger = trigger(input) else { return .stay }
        guard let best = target(input, trigger: trigger) else { return .noTarget(trigger: trigger) }
        return .switchTo(id: best.id, trigger: trigger)
    }

    static func explanation(_ trigger: Trigger, from name: String) -> String {
        switch trigger {
        case .blind: return "\(name)'s usage stopped updating near its limit."
        case .limitReported: return "Claude Code reported that \(name) reached its limit."
        case .engineDown: return "\(name) passed its line while auto-switch was down."
        case .stuck: return "\(name) stayed at its limit."
        }
    }
}
