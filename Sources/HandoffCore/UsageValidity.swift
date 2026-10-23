import Foundation
import CoreFoundation

public enum JSONScalar {
    public static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
    public static func boolean(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }
}

public enum UsageValidity {
    public static let availableLifetime: TimeInterval = 180
    public static let exhaustedLifetime: TimeInterval = 660

    /// Positive exhaustion may be cached through the helper's ten-minute full
    /// account cadence, but never across the reset that could restore capacity.
    public static func trustUntil(fetchedAt: Date?, exhausted: Bool, reset: Date?) -> Date? {
        guard let fetchedAt else { return nil }
        let expiry = fetchedAt.addingTimeInterval(exhausted && reset != nil ? exhaustedLifetime : availableLifetime)
        return exhausted ? reset.map { min($0, expiry) } ?? expiry : expiry
    }
    public static func isTrusted(fetchedAt: Date?, until: Date?, now: Date) -> Bool {
        guard let fetchedAt, let until else { return false }
        // Compare in the same epoch used by provider serialization. Date's
        // reference-epoch conversion can otherwise invent a sub-microsecond
        // future reading after a Double timestamp makes a round trip.
        return fetchedAt.timeIntervalSince1970 <= now.timeIntervalSince1970
            && until.timeIntervalSince1970 >= now.timeIntervalSince1970
    }
}

public struct CodexUsageSnapshot {
    public struct Window {
        public let used: Double
        public let durationMinutes: Double
        public let resetsAt: Date?
        public let scope: String?
    }
    public let windows: [Window]
    public let ordinaryUsageAllowed: Bool
    public let reached: Bool

    public init(_ limits: [String: Any], expectedAccountID: String?) throws {
        if let expectedAccountID {
            guard let id = limits["accountId"] as? String, !id.isEmpty, id == expectedAccountID else {
                throw HandoffError.invalid("Codex usage belongs to a different account. Refresh the login.")
            }
        }
        guard let permission = JSONScalar.boolean(limits["ordinaryUsageAllowed"]) else {
            throw HandoffError.unavailable("Codex included-usage permission is unknown. Update Codex or retry later.")
        }
        guard let main = limits["rateLimits"] as? [String: Any] else {
            throw HandoffError.invalid("Codex did not report its usage limits.")
        }
        var parsed: [Window] = []
        var snapshots: [(String?, [String: Any])] = [(nil, main)]
        if let raw = limits["rateLimitsByLimitId"], !(raw is NSNull) {
            guard let byID = raw as? [String: Any], byID.count <= 64 else { throw HandoffError.invalid("Codex returned invalid model limits.") }
            for key in byID.keys.sorted() where key != "codex" {
                guard let snapshot = byID[key] as? [String: Any] else { throw HandoffError.invalid("Codex returned invalid model limits.") }
                let name = snapshot["limitName"] as? String ?? key.capitalized
                snapshots.append((String(name.prefix(120)), snapshot))
            }
        }
        var explicitLimit = false
        for (scope, snapshot) in snapshots {
        let previousCount = parsed.count
        let snapshotReached = snapshot["rateLimitReachedType"] is String
        explicitLimit = explicitLimit || snapshotReached
        for key in ["primary", "secondary"] {
            guard let raw = snapshot[key], !(raw is NSNull) else { continue }
            guard let item = raw as? [String: Any],
                  let used = JSONScalar.number(item["usedPercent"]), (0...100).contains(used),
                  let minutes = JSONScalar.number(item["windowDurationMins"]), minutes > 0, minutes <= 525_600 else {
                throw HandoffError.invalid("Codex returned an invalid usage window.")
            }
            var reset: Date?
            if let rawReset = item["resetsAt"], !(rawReset is NSNull) {
                guard let seconds = JSONScalar.number(rawReset), (0...32_503_680_000).contains(seconds) else {
                    throw HandoffError.invalid("Codex returned an invalid reset timestamp.")
                }
                reset = Date(timeIntervalSince1970: seconds)
            }
            parsed.append(Window(used: used, durationMinutes: minutes, resetsAt: reset, scope: scope))
        }
        guard scope == nil || parsed.count > previousCount || snapshotReached else { throw HandoffError.unavailable("Codex did not report a model usage window.") }
        }
        guard !parsed.isEmpty else { throw HandoffError.unavailable("Codex did not report a usage window.") }
        windows = parsed
        ordinaryUsageAllowed = permission
        reached = !permission || explicitLimit || parsed.contains { $0.used >= 100 }
    }
}
