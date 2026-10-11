import Foundation

/// Everything Claude goes through the claude-swap CLI; ZipSwap never touches
/// Claude credentials itself.
enum ClaudeService {
    static let tool = "claude-swap"
    static let dataDir = Shell.home.appendingPathComponent(".claude-swap-backup")
    static let legacyLabel = "com.cswap.menubar"

    static var isInstalled: Bool { Shell.which(tool) != nil }

    static func list() async throws -> [Account] {
        let result = try await Shell.run(tool, ["list", "--json"], timeout: 90)
        guard let root = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
            throw ShellError.failed(errorText(result) ?? "claude-swap returned something unreadable.")
        }
        if let error = root["error"] as? [String: Any] {
            throw ShellError.failed(error["message"] as? String ?? "claude-swap failed.")
        }
        let rows = root["accounts"] as? [[String: Any]] ?? []
        return rows.map(parse)
    }

    static func parse(_ row: [String: Any]) -> Account {
        let slot = row["number"] as? Int ?? 0
        let email = row["email"] as? String ?? ""
        let alias = row["alias"] as? String
        let status = row["usageStatus"] as? String ?? "unavailable"
        let usage = (row["usage"] as? [String: Any]) ?? (row["lastGoodUsage"] as? [String: Any]) ?? [:]
        let fetched = Format.date(row["usageFetchedAt"] ?? row["lastGoodFetchedAt"])

        var windows: [UsageWindow] = []
        func window(_ label: String, _ obj: Any?) {
            guard let w = obj as? [String: Any], let pct = w["pct"] as? Double else { return }
            windows.append(UsageWindow(
                label: label,
                pct: pct,
                resetsAt: Format.date(w["resetsAt"]),
                expectedPct: w["expectedPct"] as? Double,
                projectedExhaustion: Format.date(w["projectedExhaustionAt"]),
                willLastToReset: w["willLastToReset"] as? Bool
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
            problem: status == "ok" || status == "api_key" ? nil : problems[status],
            fetchedAt: fetched
        )
    }

    static func switchTo(slot: Int) async throws {
        let result = try await Shell.run(tool, ["switch", String(slot), "--json"], timeout: 90)
        try check(result)
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
        return text.isEmpty ? nil : String(text.suffix(300))
    }

    private static func check(_ result: ShellResult) throws {
        guard result.status == 0 else {
            throw ShellError.failed(errorText(result) ?? "claude-swap exited with \(result.status).")
        }
    }
}

/// Hosts `claude-swap auto --json` as a child process for as long as Claude
/// auto-switch is on, and reports the events it prints.
final class ClaudeAutoEngine: @unchecked Sendable {
    struct Event {
        let kind: String
        let payload: [String: Any]
    }

    private var process: Process?
    private let reader = LineReader()
    var onEvent: ((Event) -> Void)?

    var isRunning: Bool { process?.isRunning ?? false }

    func start(threshold: Int) {
        stop()
        guard let proc = try? Shell.makeProcess(ClaudeService.tool, ["auto", "--json", "--threshold", String(threshold)], env: [:]) else { return }
        let output = Pipe()
        proc.standardOutput = output
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            for line in self.reader.feed(data) {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                let kind = obj["event"] as? String ?? (obj["error"] != nil ? "error" : "unknown")
                let event = Event(kind: kind, payload: obj)
                DispatchQueue.main.async { self.onEvent?(event) }
            }
        }
        do {
            try proc.run()
            process = proc
        } catch {
            process = nil
        }
    }

    func stop() {
        guard let proc = process else { return }
        process = nil
        if proc.isRunning {
            proc.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            }
        }
    }

    deinit { stop() }
}
