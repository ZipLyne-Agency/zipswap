import Foundation

/// Claude's free resets, as entered by hand. Anthropic reports them only to
/// claude.ai, Claude Desktop and Claude Code, so ZipSwap keeps the count the
/// person reads there and lowers it when they mark one used.
struct ClaudeResetBalance: Codable, Equatable {
    var left: Int
    /// The last day the resets can be used, as yyyy-MM-dd in Israel time.
    var expires: String?

    func expiryDate() -> Date? { expires.flatMap(ClaudeResetLedger.day) }

    /// Resets are usable through the whole of their last day.
    func usable(at now: Date) -> Int {
        guard left > 0 else { return 0 }
        guard let last = expiryDate(), let end = ClaudeResetLedger.calendar.date(byAdding: .day, value: 1, to: last) else { return left }
        return now < end ? left : 0
    }
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

    func usable(for email: String, at now: Date = .now) -> Int { balance(for: email)?.usable(at: now) ?? 0 }

    mutating func set(_ email: String, left: Int, expires: Date?) {
        let id = Self.id(email)
        guard !id.isEmpty else { return }
        balances[id] = ClaudeResetBalance(left: min(max(left, 0), Self.maximum), expires: expires.map(Self.dayText))
        save()
    }

    /// Counts one reset as used. False when none is left.
    @discardableResult
    mutating func use(_ email: String, at now: Date = .now) -> Bool {
        let id = Self.id(email)
        guard var balance = balances[id], balance.usable(at: now) > 0 else { return false }
        balance.left -= 1
        balances[id] = balance
        save()
        return true
    }

    private func save() {
        if let data = try? JSONEncoder().encode(balances) { defaults.set(data, forKey: Self.key) }
    }
}
