import Foundation

public struct HandoffAccountUsage {
    public let active: Bool
    public let disabled: Bool
    public let percent: Double?
    public let blocked: Bool
    public let healthy: Bool
    public let fetchedAt: Date?

    public init(active: Bool, disabled: Bool, percent: Double?, blocked: Bool, healthy: Bool, fetchedAt: Date?) {
        self.active = active
        self.disabled = disabled
        self.percent = percent
        self.blocked = blocked
        self.healthy = healthy
        self.fetchedAt = fetchedAt
    }

    func known(at now: Date) -> Bool {
        healthy && (percent.map { $0.isFinite && (0...100).contains($0) } ?? false)
            && (fetchedAt.map { (0...180).contains(now.timeIntervalSince($0)) } ?? false)
    }
}

public enum HandoffUsagePolicy {
    public static func evaluate(_ accounts: [HandoffAccountUsage], rotationEnabled: Bool, now: Date) -> HandoffUsage {
        let active = accounts.first(where: \.active)
        let candidates = rotationEnabled ? accounts.filter { !$0.disabled || $0.active } : accounts.filter(\.active)
        let known = active != nil && !candidates.isEmpty && candidates.allSatisfy { $0.known(at: now) }
        // With rotation enabled, every candidate must actually be exhausted.
        // Otherwise a healthy spare at 96% could be bypassed, or a late failure
        // from the previous account could launch Codex after rotation succeeds.
        // Metering lag is tolerated only when there is a single eligible account
        // and a fresh StopFailure event independently confirms its failure.
        let threshold = candidates.count == 1 ? 95.0 : 100.0
        let exhausted = known && candidates.allSatisfy { $0.blocked || ($0.percent ?? 0) >= threshold }
        return HandoffUsage(checkedAt: now, activePercent: active?.known(at: now) == true ? active?.percent : nil,
                            claudeExhausted: exhausted,
                            explanation: exhausted ? "All eligible Claude accounts are near their limits."
                                : "Claude account rotation will be tried before a Codex handoff.")
    }
}
