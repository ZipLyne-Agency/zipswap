import Foundation

/// The two kinds of Claude free reset: one clears the weekly limit, the
/// other clears only the Fable limit.
enum ClaudeResetKind: String, CaseIterable, Identifiable {
    case weekly, fable
    var id: String { rawValue }
    var title: String { self == .weekly ? "Weekly" : "Fable" }
}

/// Claude's free resets, as entered by hand. Anthropic reports them only to
/// claude.ai, Claude Desktop and Claude Code, so ZipSwap keeps the counts the
/// person reads there and lowers one when they mark it used.
struct ClaudeResetBalance: Codable, Equatable {
    /// Weekly resets. The stored name predates Fable resets.
    var left: Int
    var fable: Int = 0
    /// The last day the resets can be used, as yyyy-MM-dd in Israel time.
    var expires: String?

    init(left: Int, fable: Int = 0, expires: String? = nil) {
        self.left = left
        self.fable = fable
        self.expires = expires
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        left = try c.decode(Int.self, forKey: .left)
        fable = try c.decodeIfPresent(Int.self, forKey: .fable) ?? 0
        expires = try c.decodeIfPresent(String.self, forKey: .expires)
    }

    func expiryDate() -> Date? { expires.flatMap(ClaudeResetLedger.day) }

    func count(_ kind: ClaudeResetKind) -> Int { kind == .weekly ? left : fable }

    /// Resets are usable through the whole of their last day.
    func usable(_ kind: ClaudeResetKind, at now: Date) -> Int {
        let n = count(kind)
        guard n > 0 else { return 0 }
        guard let last = expiryDate(), let end = ClaudeResetLedger.calendar.date(byAdding: .day, value: 1, to: last) else { return n }
        return now < end ? n : 0
    }

    func usable(at now: Date) -> Int { ClaudeResetKind.allCases.reduce(0) { $0 + usable($1, at: now) } }
}

struct ClaudeResetLedger {
    static let key = "claudeManualResets.v1"
    static let maximum = 99
    static var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Jerusalem") ?? .current
        return calendar
    }()

    static func day(_ text: String) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func dayText(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private(set) var balances: [String: ClaudeResetBalance]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        balances = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([String: ClaudeResetBalance].self, from: $0) } ?? [:]
    }

    /// Keyed by email: slot numbers move when accounts are re-added or swapped.
    static func id(_ email: String) -> String { email.trimmingCharacters(in: .whitespaces).lowercased() }

    func balance(for email: String) -> ClaudeResetBalance? { balances[Self.id(email)] }

    /// Both kinds together.
    func usable(for email: String, at now: Date = .now) -> Int { balance(for: email)?.usable(at: now) ?? 0 }

    func usable(_ kind: ClaudeResetKind, for email: String, at now: Date = .now) -> Int {
        balance(for: email)?.usable(kind, at: now) ?? 0
    }

    mutating func set(_ email: String, left: Int, fable: Int, expires: Date?) {
        let id = Self.id(email)
        guard !id.isEmpty else { return }
        let clamp = { min(max($0, 0), Self.maximum) }
        balances[id] = ClaudeResetBalance(left: clamp(left), fable: clamp(fable), expires: expires.map(Self.dayText))
        save()
    }

    /// Counts one reset of that kind as used. False when none is left.
    @discardableResult
    mutating func use(_ kind: ClaudeResetKind, _ email: String, at now: Date = .now) -> Bool {
        let id = Self.id(email)
        guard var balance = balances[id], balance.usable(kind, at: now) > 0 else { return false }
        if kind == .weekly { balance.left -= 1 } else { balance.fable -= 1 }
        balances[id] = balance
        save()
        return true
    }

    private func save() {
        if let data = try? JSONEncoder().encode(balances) { defaults.set(data, forKey: Self.key) }
    }
}
