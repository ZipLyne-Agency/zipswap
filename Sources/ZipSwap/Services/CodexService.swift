import Foundation
#if SWIFT_PACKAGE
import HandoffCore
#endif

/// Codex has no account switcher of its own, so ZipSwap keeps one: each saved
/// account lives in its own CODEX_HOME folder holding just its auth.json, and
/// switching copies that file into ~/.codex. Usage for every account comes from
/// `codex app-server`, pointed at the account's folder.
struct CodexStoredAccount: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var email: String
    var accountId: String
    var plan: String
}

enum CodexService {
    static let liveHome = Shell.home.appendingPathComponent(".codex")
    static var liveAuth: URL { liveHome.appendingPathComponent("auth.json") }

    static let storeRoot: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ZipSwap/Codex", isDirectory: true)
    }()
    static var indexURL: URL { storeRoot.appendingPathComponent("accounts.json") }
    static var historyURL: URL { storeRoot.appendingPathComponent("history.json") }

    static var isInstalled: Bool { Shell.which("codex") != nil }

    static func home(for id: String) -> URL { storeRoot.appendingPathComponent(id, isDirectory: true) }

    // MARK: store

    static var store: CodexStore { CodexStore(root: storeRoot, liveHome: liveHome) }
    static func loadIndex() throws -> [CodexStoredAccount] { try store.loadIndex() }
    static func saveIndex(_ accounts: [CodexStoredAccount], replacing previous: [CodexStoredAccount]) throws {
        try store.saveIndex(accounts, replacing: previous)
    }
    static func ensureStore() throws {
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    static func accountId(in url: URL) -> String? { (try? store.credential(url))?.accountID }
    static func liveAccountId() -> String? { accountId(in: liveAuth) }
    static func writeAuth(_ data: Data, to url: URL) throws {
        try PrivateFile.write(data, to: url, expected: try PrivateFile.readIfPresent(url), compare: true)
    }
    static func syncLive(into accounts: inout [CodexStoredAccount]) throws { try store.syncLive(into: &accounts) }

    // MARK: usage

    static func fetch(_ stored: CodexStoredAccount, isActive: Bool) async -> Account {
        let home: URL? = isActive ? nil : home(for: stored.id)
        let auth = (home ?? liveHome).appendingPathComponent("auth.json")
        do {
            guard try store.credential(auth)?.accountID == stored.accountId else {
                throw ShellError.failed("The saved Codex login does not match this account. Sign in again.")
            }
            let replies = try await CodexAppServer.call(home: home, [
                .init(method: "account/read", params: ["refreshToken": false]),
                .init(method: "account/rateLimits/read", params: nil),
            ])
            guard try store.credential(auth)?.accountID == stored.accountId else {
                throw ShellError.failed("Codex changed accounts during the refresh. Refresh again.")
            }
            var reading = parse(stored, isActive: isActive, account: replies[0]["result"] as? [String: Any],
                                limits: replies[1]["result"] as? [String: Any], error: nil)
            do {
                if reading.problem == nil, let limits = replies[1]["result"] as? [String: Any] {
                    if let credits = (limits["rateLimitResetCredits"] as? [String: Any])?["credits"] as? [[String: Any]] {
                        try store.locked { try ResetOperations.reconcile(resetOperationFile(stored), credits: credits) }
                    }
                }
                reading.pendingResetID = try ResetOperations.pendingCredit(resetOperationFile(stored))
            } catch { reading.resetProblem = "The saved reset status could not be read. Repair account storage before using another credit." }
            return reading
        } catch {
            return parse(stored, isActive: isActive, account: nil, limits: nil, error: ContextRedaction.clean(error.localizedDescription))
        }
    }

    static func parse(_ stored: CodexStoredAccount, isActive: Bool, account: [String: Any]?,
                      limits: [String: Any]?, error: String?) -> Account {
        let info = account?["account"] as? [String: Any]
        let email = info?["email"] as? String ?? stored.email
        let plan = info?["planType"] as? String ?? stored.plan
        var problem = error
        var snapshot: CodexUsageSnapshot?
        do {
            guard let limits else { throw ShellError.failed(error ?? "Codex usage is unavailable.") }
            snapshot = try CodexUsageSnapshot(limits, expectedAccountID: stored.accountId)
            guard info?["type"] as? String == "chatgpt" else { throw ShellError.failed("Sign in to Codex with ChatGPT to read subscription usage.") }
        } catch { problem = ContextRedaction.clean(error.localizedDescription) }
        let windows = snapshot?.windows.map { value -> UsageWindow in
            let duration = Format.windowLabel(minutes: Int(value.durationMinutes))
            let label = value.scope.map { "\($0) \(duration)" } ?? duration
            var window = UsageWindow(label: label, pct: value.used, resetsAt: value.resetsAt,
                                     expectedPct: nil, projectedExhaustion: nil, willLastToReset: nil,
                                     windowMinutes: value.durationMinutes)
            if value.durationMinutes >= 1440 { window = UsageWindow(label: label, pct: value.used, resetsAt: value.resetsAt,
                expectedPct: Format.expectedPct(for: window, windowMinutes: value.durationMinutes),
                projectedExhaustion: nil, willLastToReset: nil, windowMinutes: value.durationMinutes) }
            return window
        } ?? []
        var unique: [UsageWindow] = []
        for window in windows {
            let label = unique.contains(where: { $0.label == window.label }) ? "Secondary " + window.label : window.label
            unique.append(UsageWindow(label: label, pct: window.pct, resetsAt: window.resetsAt,
                                      expectedPct: window.expectedPct, projectedExhaustion: nil, willLastToReset: nil,
                                      windowMinutes: window.windowMinutes))
        }
        let creditInfo = (limits?["rateLimits"] as? [String: Any])?["credits"] as? [String: Any]
        let credits = creditInfo?["hasCredits"] as? Bool == true
            ? (creditInfo?["unlimited"] as? Bool == true ? "unlimited" : Format.credits(creditInfo?["balance"] as? String)) : nil
        let resets = ((limits?["rateLimitResetCredits"] as? [String: Any])?["credits"] as? [[String: Any]] ?? [])
            .filter { ($0["status"] as? String) == "available" }
            .compactMap { row -> ResetCredit? in
                guard let id = row["id"] as? String, !id.isEmpty else { return nil }
                return ResetCredit(id: id, title: row["title"] as? String ?? "Full reset", expiresAt: Format.date(row["expiresAt"]))
            }
        var seenCredits = Set<String>()
        return Account(id: "codex-\(stored.id)", provider: .codex, slot: nil, name: stored.name,
                       email: email, plan: plan.isEmpty ? "ChatGPT" : "ChatGPT \(plan.capitalized)",
                       isActive: isActive, activeIdentityVerified: isActive && info?["type"] as? String == "chatgpt" && limits?["accountId"] as? String == stored.accountId,
                       disabled: false, windows: unique, problem: problem,
                       fetchedAt: problem == nil ? .now : nil, stale: problem != nil, credits: credits,
                       resetCredits: resets.filter { seenCredits.insert($0.id).inserted },
                       limitReached: snapshot?.reached ?? false, providerAccountID: stored.accountId)
    }

    // MARK: actions

    static func switchTo(_ target: CodexStoredAccount, expectedLiveID: String?) throws {
        try store.activate(target, expectedLiveID: expectedLiveID)
    }

    static func verifyDefaultIdentity(_ expected: String) async throws {
        let replies = try await CodexAppServer.call(home: nil, [
            .init(method: "account/read", params: ["refreshToken": false]),
            .init(method: "account/rateLimits/read", params: nil),
        ])
        guard let info = (replies[0]["result"] as? [String: Any])?["account"] as? [String: Any],
              info["type"] as? String == "chatgpt",
              let limits = replies[1]["result"] as? [String: Any], limits["accountId"] as? String == expected,
              liveAccountId() == expected else {
            throw ShellError.failed("The default Codex CLI account could not be verified. Refresh before continuing.")
        }
    }

    /// Runs `codex login` in a fresh CODEX_HOME. Codex opens the browser for
    /// sign-in and exits once the login lands.
    static func addAccount(existing: [CodexStoredAccount]) async throws -> (CodexStoredAccount, Bool) {
        try ensureStore()
        let id = UUID().uuidString.lowercased()
        let dir = home(for: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let result = try await Shell.run("codex", ["login"], env: ["CODEX_HOME": dir.path], timeout: 600)
        let auth = dir.appendingPathComponent("auth.json")
        guard result.status == 0, let accountId = accountId(in: auth) else {
            try? FileManager.default.removeItem(at: dir)
            throw ShellError.failed("Codex sign-in didn't finish.")
        }
        // Keep only auth.json in the account folder.
        if let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for item in items where item.lastPathComponent != "auth.json" { try? FileManager.default.removeItem(at: item) }
        }
        if let match = existing.first(where: { $0.accountId == accountId }) {
            let data = try Data(contentsOf: auth)
            try writeAuth(data, to: home(for: match.id).appendingPathComponent("auth.json"))
            try? FileManager.default.removeItem(at: dir)
            return (match, false)
        }
        let replies = try? await CodexAppServer.call(home: dir, [.init(method: "account/read", params: ["refreshToken": false])])
        let info = (replies?.first?["result"] as? [String: Any])?["account"] as? [String: Any]
        let email = info?["email"] as? String ?? ""
        let name = email.split(separator: "@").first.map(String.init) ?? "Codex"
        return (CodexStoredAccount(id: id, name: name, email: email, accountId: accountId,
                                   plan: info?["planType"] as? String ?? ""), true)
    }

    static func remove(_ account: CodexStoredAccount) throws { try store.removeAccount(account) }

    static func resetOperationFile(_ account: CodexStoredAccount) -> URL { home(for: account.id).appendingPathComponent("reset-operation.json") }

    static func useResetCredit(_ stored: CodexStoredAccount, isActive: Bool, creditId: String?) async throws -> String {
        guard let creditId, !creditId.isEmpty else { throw ShellError.failed("Refresh the account to select an available reset credit.") }
        guard accountId(in: (isActive ? liveHome : home(for: stored.id)).appendingPathComponent("auth.json")) == stored.accountId else {
            throw ShellError.failed("The Codex account changed. Refresh before using a reset.")
        }
        let file = resetOperationFile(stored)
        var operation = try store.locked { try ResetOperations.reserve(file, accountID: stored.accountId, creditID: creditId) }
        do {
            let replies = try await CodexAppServer.call(home: isActive ? nil : home(for: stored.id), [
                .init(method: "account/rateLimitResetCredit/consume", params: ["idempotencyKey": operation.key, "creditId": operation.creditID]),
            ])
            let outcome = (replies.first?["result"] as? [String: Any])?["outcome"] as? String ?? ""
            let message: String
            switch outcome {
            case "reset": operation.phase = .confirmed; message = "Limits reset on \(stored.name)."
            case "nothingToReset": operation.phase = .unavailable; message = "Nothing to reset; the credit was kept."
            case "noCredit": operation.phase = .unavailable; message = "No reset credits left."
            case "alreadyRedeemed": operation.phase = .confirmed; message = "That credit was already used."
            default: throw ShellError.failed("Reset result is unknown. Retry the pending reset; a different credit will not be selected.")
            }
            try store.locked { try ResetOperations.save(operation, to: file) }
            return message
        } catch {
            operation.phase = ResetOperations.failurePhase(error)
            try? store.locked { try ResetOperations.save(operation, to: file) }
            throw error
        }
    }

    // MARK: history

    struct StoredHistory: Codable {
        let from: String
        let to: String
        let at: Date
        let reason: String
    }

    static func loadHistory() -> [HistoryItem] {
        guard let data = try? Data(contentsOf: historyURL),
              let items = try? JSONDecoder().decode([StoredHistory].self, from: data) else { return [] }
        return items.map { HistoryItem(provider: .codex, from: $0.from, to: $0.to, at: $0.at, reason: $0.reason) }
    }

    static func appendHistory(from: String, to: String, reason: String) {
        var items = (try? JSONDecoder().decode([StoredHistory].self, from: Data(contentsOf: historyURL))) ?? []
        items.insert(StoredHistory(from: from, to: to, at: .now, reason: reason), at: 0)
        if let data = try? JSONEncoder().encode(Array(items.prefix(50))) {
            try? ensureStore()
            try? PrivateFile.write(data, to: historyURL)
        }
    }
}
