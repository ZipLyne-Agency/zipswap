import Foundation
import Observation
import Darwin

/// All account-changing UI routes share this coordinator. A file lease extends
/// serialization to other ZipSwap instances without locking unrelated clients.
@MainActor @Observable
final class AccountCoordinator {
    struct Token: Equatable {
        let id: UUID
        let provider: Provider
        let accountID: String
        let generation: Int
    }
    private(set) var active: [Provider: Token] = [:]
    private(set) var generations: [Provider: Int] = [:]
    private(set) var lastVerified: [Provider: String] = [:]
    @ObservationIgnored private var locks: [Provider: Int32] = [:]
    private let root: URL
    init(root: URL = Shell.home.appendingPathComponent("Library/Application Support/ZipSwap/Operations")) { self.root = root }

    func begin(_ provider: Provider, accountID: String) throws -> Token {
        guard active[provider] == nil else { throw ShellError.failed("Another \(provider.title) account operation is in progress.") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(root.appendingPathComponent(provider.rawValue + ".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ShellError.failed("Could not lock the account operation.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            throw ShellError.failed("Another ZipSwap window is changing this account. Try again.")
        }
        let generation = (generations[provider] ?? 0) + 1
        let token = Token(id: UUID(), provider: provider, accountID: accountID, generation: generation)
        locks[provider] = fd; generations[provider] = generation; active[provider] = token
        return token
    }
    func finish(_ token: Token, verified: Bool = false) {
        guard active[token.provider] == token else { return }
        if verified { lastVerified[token.provider] = token.accountID }
        active.removeValue(forKey: token.provider)
        if let fd = locks.removeValue(forKey: token.provider) { flock(fd, LOCK_UN); Darwin.close(fd) }
    }
    func generation(_ provider: Provider) -> Int { generations[provider] ?? 0 }
    func busy(_ provider: Provider) -> Bool { active[provider] != nil }
}

struct CodexPollState: Codable {
    var failures = 0
    var lastAttempt: Date?
    var retryAt: Date?
    mutating func record(success: Bool, now: Date, providerRetry: Date? = nil, jitter: TimeInterval = 0) {
        lastAttempt = now
        failures = success ? 0 : min(8, max(0, failures) + 1)
        let cadence = success ? 120.0 : min(1800, 90 * pow(2, Double(failures)))
        retryAt = max(providerRetry ?? now, now.addingTimeInterval(cadence + min(30, max(0, jitter))))
    }
    func due(at now: Date) -> Bool { retryAt.map { $0 <= now || $0.timeIntervalSince(now) > 1830 } ?? true }
}

enum RotationSettings {
    static func threshold(_ raw: Double, fallback: Double) -> Double { raw.isFinite && (50...99).contains(raw) ? raw.rounded() : fallback }
    static func remainingCooldown(lastSwitch: Date, now: Date, interval: TimeInterval = 300) -> TimeInterval {
        min(interval, max(0, interval - now.timeIntervalSince(lastSwitch)))
    }
}

struct CodexPollPlan {
    static let maximumConcurrent = 2
    static let maximumPerPass = 4
    static func select(_ accounts: [CodexStoredAccount], liveID: String?, states: [String: CodexPollState], now: Date) -> [CodexStoredAccount] {
        Array(accounts.filter { states[$0.id]?.due(at: now) ?? true }.sorted {
            if ($0.accountId == liveID) != ($1.accountId == liveID) { return $0.accountId == liveID }
            return (states[$0.id]?.lastAttempt ?? .distantPast) < (states[$1.id]?.lastAttempt ?? .distantPast)
        }.prefix(maximumPerPass))
    }
}
