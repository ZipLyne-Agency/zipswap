import Foundation

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

    static func loadIndex() -> [CodexStoredAccount] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        return (try? JSONDecoder().decode([CodexStoredAccount].self, from: data)) ?? []
    }

    static func saveIndex(_ accounts: [CodexStoredAccount]) {
        ensureStore()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(accounts) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    static func ensureStore() {
        try? FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    /// The ChatGPT account id inside an auth.json, used to tell accounts apart.
    static func accountId(in url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any] else { return nil }
        return tokens["account_id"] as? String
    }

    static func liveAccountId() -> String? { accountId(in: liveAuth) }

    /// Writes auth data with owner-only permissions, atomically.
    static func writeAuth(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temp = url.deletingLastPathComponent().appendingPathComponent(".auth.json.zipswap-tmp")
        FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600])
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: url)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Copies the live login back into its stored folder so the store always
    /// holds the newest refresh token, and adopts a live login it hasn't seen.
    static func syncLive(into accounts: inout [CodexStoredAccount]) {
        guard let liveId = liveAccountId(), let data = try? Data(contentsOf: liveAuth) else { return }
        if let match = accounts.first(where: { $0.accountId == liveId }) {
            let stored = home(for: match.id).appendingPathComponent("auth.json")
            if (try? Data(contentsOf: stored)) != data { try? writeAuth(data, to: stored) }
        } else {
            let id = UUID().uuidString.lowercased()
            try? writeAuth(data, to: home(for: id).appendingPathComponent("auth.json"))
            accounts.append(CodexStoredAccount(id: id, name: "Codex", email: "", accountId: liveId, plan: ""))
            saveIndex(accounts)
        }
    }

    // MARK: usage

    static func fetch(_ stored: CodexStoredAccount, isActive: Bool) async -> Account {
        let home: URL? = isActive ? nil : home(for: stored.id)
        do {
            let replies = try await CodexAppServer.call(home: home, [
                .init(method: "account/read", params: ["refreshToken": false]),
                .init(method: "account/rateLimits/read", params: nil),
            ])
            return parse(stored, isActive: isActive, account: replies[0]["result"] as? [String: Any],
                         limits: replies[1]["result"] as? [String: Any],
                         error: (replies[1]["error"] as? [String: Any])?["message"] as? String)
        } catch {
            return parse(stored, isActive: isActive, account: nil, limits: nil, error: error.localizedDescription)
        }
    }

    static func parse(_ stored: CodexStoredAccount, isActive: Bool, account: [String: Any]?,
                      limits: [String: Any]?, error: String?) -> Account {
        let info = account?["account"] as? [String: Any]
        let email = info?["email"] as? String ?? stored.email
        let plan = (info?["planType"] as? String ?? stored.plan)

        var windows: [UsageWindow] = []
        var credits: String?
        var reached = false
        var seen = Set<String>()

        func add(_ snapshot: [String: Any], prefix: String?) {
            for key in ["primary", "secondary"] {
                guard let w = snapshot[key] as? [String: Any], let pct = (w["usedPercent"] as? NSNumber)?.doubleValue else { continue }
                var label = Format.windowLabel(minutes: (w["windowDurationMins"] as? NSNumber)?.intValue)
                if let prefix { label = "\(prefix) \(label)" }
                guard seen.insert(label).inserted else { continue }
                let reset = Format.date(w["resetsAt"])
                let minutes = (w["windowDurationMins"] as? NSNumber)?.doubleValue ?? 10080
                let draft = UsageWindow(label: label, pct: pct, resetsAt: reset, expectedPct: nil, projectedExhaustion: nil, willLastToReset: nil)
                windows.append(UsageWindow(label: label, pct: pct, resetsAt: reset,
                                           expectedPct: minutes >= 1440 ? Format.expectedPct(for: draft, windowMinutes: minutes) : nil,
                                           projectedExhaustion: nil, willLastToReset: nil))
            }
            if let c = snapshot["credits"] as? [String: Any], c["hasCredits"] as? Bool == true {
                credits = (c["unlimited"] as? Bool == true) ? "unlimited" : Format.credits(c["balance"] as? String)
            }
            if snapshot["rateLimitReachedType"] is String { reached = true }
        }

        if let main = limits?["rateLimits"] as? [String: Any] { add(main, prefix: nil) }
        for (key, value) in (limits?["rateLimitsByLimitId"] as? [String: Any]) ?? [:] where key != "codex" {
            if let snap = value as? [String: Any] {
                add(snap, prefix: snap["limitName"] as? String ?? key.capitalized)
            }
        }
        if limits?["ordinaryUsageAllowed"] as? Bool == false { reached = true }

        let resets = ((limits?["rateLimitResetCredits"] as? [String: Any])?["credits"] as? [[String: Any]] ?? [])
            .filter { ($0["status"] as? String) == "available" }
            .map { ResetCredit(id: $0["id"] as? String ?? "", title: $0["title"] as? String ?? "Full reset", expiresAt: Format.date($0["expiresAt"])) }

        return Account(
            id: "codex-\(stored.id)",
            provider: .codex,
            slot: nil,
            name: stored.name,
            email: email,
            plan: plan.isEmpty ? "ChatGPT" : "ChatGPT \(plan.capitalized)",
            isActive: isActive,
            disabled: false,
            windows: windows,
            problem: limits == nil ? (error.map { "Couldn't read usage: \($0)" } ?? "Usage unavailable") : nil,
            fetchedAt: limits == nil ? nil : .now,
            credits: credits,
            resetCredits: resets,
            limitReached: reached
        )
    }

    // MARK: actions

    static func switchTo(_ target: CodexStoredAccount, accounts: [CodexStoredAccount]) throws {
        var all = accounts
        syncLive(into: &all)
        let source = home(for: target.id).appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: source) else {
            throw ShellError.failed("The saved login for \(target.name) is missing. Add the account again.")
        }
        try writeAuth(data, to: liveAuth)
    }

    /// Runs `codex login` in a fresh CODEX_HOME. Codex opens the browser for
    /// sign-in and exits once the login lands.
    static func addAccount(existing: [CodexStoredAccount]) async throws -> (CodexStoredAccount, Bool) {
        ensureStore()
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

    static func remove(_ account: CodexStoredAccount) {
        try? FileManager.default.removeItem(at: home(for: account.id))
    }

    static func useResetCredit(_ stored: CodexStoredAccount, isActive: Bool, creditId: String?) async throws -> String {
        var params: [String: Any] = ["idempotencyKey": UUID().uuidString]
        if let creditId { params["creditId"] = creditId }
        let replies = try await CodexAppServer.call(home: isActive ? nil : home(for: stored.id), [
            .init(method: "account/rateLimitResetCredit/consume", params: params),
        ])
        if let error = replies.first?["error"] as? [String: Any] {
            throw ShellError.failed(error["message"] as? String ?? "Codex refused the reset.")
        }
        let outcome = (replies.first?["result"] as? [String: Any])?["outcome"] as? String ?? ""
        switch outcome {
        case "reset": return "Limits reset on \(stored.name)."
        case "nothingToReset": return "Nothing to reset yet, the credit was kept."
        case "noCredit": return "No reset credits left."
        case "alreadyRedeemed": return "That credit was already used."
        default: return "Reset sent."
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
            ensureStore()
            try? data.write(to: historyURL, options: .atomic)
        }
    }
}
