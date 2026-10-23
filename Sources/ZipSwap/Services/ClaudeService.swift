import Foundation
#if SWIFT_PACKAGE
import HandoffCore
#endif

/// Everything Claude goes through the claude-swap CLI; ZipSwap never touches
/// Claude credentials itself.
enum ClaudeService {
    static let tool = "claude-swap"
    static let dataDir = Shell.home.appendingPathComponent(".claude-swap-backup")
    static let legacyLabel = "com.cswap.menubar"

    static var isInstalled: Bool { Shell.which(tool) != nil }

    static func list() async throws -> [Account] {
        let result = try await Shell.run(tool, ["list", "--json"], timeout: 90)
        return try decode(result)
    }

    static func decode(_ result: ShellResult) throws -> [Account] {
        try check(result)
        guard let root = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
            throw ShellError.failed(errorText(result) ?? "claude-swap returned something unreadable.")
        }
        if let error = root["error"] as? [String: Any] {
            throw ShellError.failed(error["message"] as? String ?? "claude-swap failed.")
        }
        guard JSONScalar.number(root["schemaVersion"]) == 1 else {
            throw ShellError.failed("Unsupported claude-swap account schema. Update the helper and ZipSwap together.")
        }
        guard let rows = root["accounts"] as? [[String: Any]], rows.count <= 256 else {
            throw ShellError.failed("claude-swap returned an incomplete account list.")
        }
        var slots = Set<Int>()
        for row in rows {
            guard let slot = row["number"] as? Int, let numericSlot = JSONScalar.number(row["number"]), numericSlot == Double(slot), slot > 0, slots.insert(slot).inserted,
                  let email = row["email"] as? String, !email.isEmpty,
                  JSONScalar.boolean(row["active"]) != nil, row["usageStatus"] is String else {
                throw ShellError.failed("claude-swap returned an invalid or duplicate account. The previous inventory was kept.")
            }
            for name in ["usage", "lastGoodUsage"] {
                guard let raw = row[name], !(raw is NSNull) else { continue }
                guard let usage = raw as? [String: Any] else { throw ShellError.failed("Invalid Claude usage payload.") }
                var labels = Set<String>()
                var objects: [(String, Any)] = ["fiveHour", "sevenDay"].compactMap { key in usage[key].map { (key, $0) } }
                if let scoped = usage["scoped"] as? [[String: Any]] {
                    for item in scoped {
                        guard let label = item["name"] as? String, !label.isEmpty, labels.insert(label).inserted else {
                            throw ShellError.failed("Invalid or duplicate Claude model usage window.")
                        }
                        objects.append((label, item))
                    }
                } else if let scoped = usage["scoped"], !(scoped is NSNull) {
                    throw ShellError.failed("Invalid Claude model usage windows.")
                }
                for (_, rawWindow) in objects where !(rawWindow is NSNull) {
                    guard let window = rawWindow as? [String: Any], let pct = JSONScalar.number(window["pct"]),
                          (0...100).contains(pct) else { throw ShellError.failed("Invalid Claude usage percentage.") }
                    for field in ["resetsAt", "projectedExhaustionAt"] {
                        if let value = window[field], !(value is NSNull), Format.date(value) == nil {
                            throw ShellError.failed("Invalid Claude reset timestamp.")
                        }
                    }
                    if let expected = window["expectedPct"], !(expected is NSNull) {
                        guard let value = JSONScalar.number(expected), (0...100).contains(value) else {
                            throw ShellError.failed("Invalid Claude pace value.")
                        }
                    }
                }
            }
        }
        guard rows.filter({ $0["active"] as? Bool == true }).count <= 1 else {
            throw ShellError.failed("claude-swap reported more than one active account.")
        }
        let models = watchedModels()
        return rows.map { row in var account = parse(row); account.watchedModels = models; return account }
    }

    static func watchedModels() -> [String] {
        guard let data = try? Data(contentsOf: dataDir.appendingPathComponent("settings.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let autoswitch = root["autoswitch"] as? [String: Any], let names = autoswitch["model"] as? String else { return [] }
        return names.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }

    static func parse(_ row: [String: Any]) -> Account {
        let slot = row["number"] as? Int ?? 0
        let email = row["email"] as? String ?? ""
        let alias = row["alias"] as? String
        let status = row["usageStatus"] as? String ?? "unavailable"
        let current = row["usage"] as? [String: Any]
        let usage = current ?? (row["lastGoodUsage"] as? [String: Any]) ?? [:]
        let fetched = Format.date(current == nil ? row["lastGoodFetchedAt"] : row["usageFetchedAt"])

        var windows: [UsageWindow] = []
        func window(_ label: String, _ obj: Any?) {
            guard let w = obj as? [String: Any], let pct = w["pct"] as? Double else { return }
            windows.append(UsageWindow(
                label: label,
                pct: pct,
                resetsAt: Format.date(w["resetsAt"]),
                expectedPct: w["expectedPct"] as? Double,
                projectedExhaustion: Format.date(w["projectedExhaustionAt"]),
                willLastToReset: w["willLastToReset"] as? Bool,
                windowMinutes: label == "5h" ? 300 : 10080
            ))
        }
        window("5h", usage["fiveHour"])
        window("Week", usage["sevenDay"])
        for scoped in usage["scoped"] as? [[String: Any]] ?? [] {
            window(scoped["name"] as? String ?? "Model", scoped)
        }

        let problems: [String: String] = [
            "token_expired": "Token refreshing",
            "relogin_required": "Needs a fresh /login",
            "keychain_unavailable": "Keychain locked",
            "foreign_credential": "Credential mismatch, switch to repair",
            "no_credentials": "No saved login",
            "unavailable": "Usage unavailable",
        ]
        let fetchProblems = ["http-429": "Usage throttled", "timeout": "Usage request timed out", "network": "Usage connection failed"]
        let problem = status == "api_key" || (status == "ok" && current != nil && fetched != nil && !windows.isEmpty) ? nil
            : status == "unavailable" ? (fetchProblems[row["usageError"] as? String ?? ""] ?? "Usage unavailable")
            : (problems[status] ?? "Usage unavailable")
        let org = row["organizationName"] as? String ?? ""
        let plan = org.contains("@") || org.isEmpty ? "Claude" : org

        return Account(
            id: "claude-\(slot)",
            provider: .claude,
            slot: slot,
            name: (alias?.isEmpty == false ? alias! : String(email.split(separator: "@").first ?? "")),
            email: email,
            plan: plan,
            isActive: row["active"] as? Bool ?? false,
            disabled: row["disabled"] as? Bool ?? false,
            windows: windows,
            problem: problem,
            fetchedAt: fetched,
            stale: current == nil && !windows.isEmpty,
            usageRetryAt: Format.date(row["usageRetryAt"]),
            organizationID: row["organizationUuid"] as? String
        )
    }

    static func switchTo(slot: Int) async throws {
        let result = try await Shell.run(tool, ["switch", String(slot), "--json"], timeout: 90)
        try check(result)
        let accounts = try await list()
        guard let active = accounts.first(where: \.isActive), active.slot == slot else {
            throw ShellError.failed("Claude switch could not be verified. Refresh the account list.")
        }
        try await verifyDefaultIdentity(email: active.email, organizationID: active.organizationID)
    }

    static func defaultIdentity(env: [String: String] = [:]) async throws -> (email: String, organizationID: String?) {
        let status = try await Shell.run("claude", ["auth", "status"], env: env, timeout: 15)
        guard status.status == 0,
              let root = try? JSONSerialization.jsonObject(with: status.stdout) as? [String: Any],
              root["loggedIn"] as? Bool == true, let email = root["email"] as? String, !email.isEmpty else {
            throw ShellError.failed("The default Claude CLI needs a subscription login.")
        }
        return (email, root["orgId"] as? String)
    }

    static func reconcileDefaultLogin() async throws {
        let identity = try await defaultIdentity()
        let accounts = try await list()
        if let active = accounts.first(where: \.isActive), active.email.caseInsensitiveCompare(identity.email) == .orderedSame,
           active.organizationID == nil || active.organizationID == identity.organizationID { return }
        // Capture the actual CLI profile to reconcile helper metadata. This
        // never writes a default credential or restores an older external login.
        _ = try await addCurrentLogin()
        let fresh = try await list()
        guard let active = fresh.first(where: \.isActive), active.email.caseInsensitiveCompare(identity.email) == .orderedSame else {
            throw ShellError.failed("The default Claude login changed during reconciliation. Refresh and try again.")
        }
        try await verifyDefaultIdentity(email: active.email, organizationID: active.organizationID)
    }

    static func verifyDefaultIdentity(email: String, organizationID: String? = nil) async throws {
        let status = try await Shell.run("claude", ["auth", "status"], timeout: 15)
        guard status.status == 0,
              let root = try? JSONSerialization.jsonObject(with: status.stdout) as? [String: Any],
              root["loggedIn"] as? Bool == true,
              (root["email"] as? String)?.caseInsensitiveCompare(email) == .orderedSame,
              organizationID == nil || organizationID?.isEmpty == true || root["orgId"] as? String == organizationID else {
            throw ShellError.failed("The default Claude CLI login changed. Choose Check tools or Add Current Claude Code Login to reconcile it.")
        }
    }

    static func rename(slot: Int, to name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let args = trimmed.isEmpty ? ["alias", String(slot), "--unset"] : ["alias", String(slot), trimmed]
        try check(try await Shell.run(tool, args))
    }

    static func setInRotation(slot: Int, _ enabled: Bool) async throws {
        try check(try await Shell.run(tool, [enabled ? "enable" : "disable", String(slot)]))
    }

    static func addCurrentLogin() async throws -> String {
        let result = try await Shell.run(tool, ["add"], timeout: 120)
        try check(result)
        return result.out
    }

    static func setThreshold(_ value: Int) async throws {
        try check(try await Shell.run(tool, ["config", "set", "autoswitch.threshold", String(value)]))
    }

    static func setWatchedModel(_ model: String) async throws {
        try check(try await Shell.run(tool, ["config", "set", "autoswitch.model", model]))
    }

    /// The claude-swap Python menu bar also runs an auto-switch engine. Two
    /// engines would race, so ZipSwap holds its own until that one is retired.
    static func legacyMenuBarRunning() async -> Bool {
        let uid = getuid()
        guard let result = try? await Shell.run("launchctl", ["print", "gui/\(uid)/\(legacyLabel)"], timeout: 10) else { return false }
        return result.status == 0 && result.out.contains("state = running")
    }

    static func retireLegacyMenuBar() async throws {
        try check(try await Shell.run(tool, ["menubar", "--uninstall-service"], timeout: 30))
    }

    static func history(limit: Int = 30) -> [HistoryItem] {
        let log = dataDir.appendingPathComponent("claude-swap.log")
        guard let handle = try? FileHandle(forReadingFrom: log) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 400_000 ? size - 400_000 : 0)
        let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // Legacy helper logs have no offset. Pin the historical installation
        // zone instead of reinterpreting old entries when the Mac travels.
        formatter.timeZone = Format.timeZone
        var items: [HistoryItem] = []
        for line in text.split(separator: "\n") where line.contains("Switched from account") {
            let parts = line.components(separatedBy: "Switched from account ")
            guard parts.count == 2 else { continue }
            let nums = parts[1].components(separatedBy: " to ")
            guard nums.count == 2, let date = formatter.date(from: String(line.prefix(19))) else { continue }
            items.append(HistoryItem(
                provider: .claude,
                from: nums[0].trimmingCharacters(in: .whitespaces),
                to: nums[1].trimmingCharacters(in: .whitespaces),
                at: date,
                reason: ""
            ))
        }
        return Array(items.suffix(limit).reversed())
    }

    private static func errorText(_ result: ShellResult) -> String? {
        if let root = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
           let error = root["error"] as? [String: Any] {
            return error["message"] as? String
        }
        let text = (result.err.isEmpty ? result.out : result.err).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : ContextRedaction.clean(String(text.suffix(300)))
    }

    private static func check(_ result: ShellResult) throws {
        guard result.status == 0 else {
            throw ShellError.failed(errorText(result) ?? "claude-swap exited with \(result.status).")
        }
    }
}
