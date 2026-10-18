import Foundation

public enum ClaudeHandoffHook {
    /// Hooks always fail open: this helper never denies a tool or blocks Claude.
    /// It does not call any provider, launch an app, or read conversation contents.
    public static func handle(_ data: Data, store: HandoffStore, projects: URL,
                              now: Date = Date()) throws -> [String: Any] {
        guard data.count <= 1_048_576 else { throw HandoffError.invalid("Hook input exceeds its size limit.") }
        let settings = try store.settings()
        guard settings.enabled else { return [:] }
        let input = try JSONDecoder().decode(ClaudeHookInput.self, from: data)
        guard input.agentID == nil else { return [:] }
        try HandoffPaths.validate(input, projects: projects)

        if input.event == "StopFailure" {
            guard input.error == "rate_limit" else { return [:] }
            _ = try store.enqueue(input, now: now)
            // StopFailure ignores additionalContext. The dashboard is the receipt.
            return [:]
        }
        guard ["SessionStart", "UserPromptSubmit", "PostToolUse"].contains(input.event) else { return [:] }
        var messages: [String] = []
        if input.event == "SessionStart" {
            messages.append("ZipSwap Claude-to-Codex handoff is enabled. If Claude reaches its usage limit and account rotation has no usable account, ZipSwap can preserve this session's visible conversation in a Codex thread and open it in Terminal. Keep important decisions, completed work, and remaining steps in visible messages. Hidden reasoning and live tool processes cannot transfer. Do not start a second worker yourself.")
        }
        if let record = try store.record(input.sessionID), record.contextReady,
           let threadID = record.threadID {
            messages.append("ZipSwap already prepared Codex thread \(threadID) for this session. Tell the user to use ZipSwap > Handoffs > Open Codex Thread. Check with the user before resuming edits in this Claude session, to avoid two agents editing the same files.")
        } else if let usage = try store.usage(), usage.isFresh(at: now),
                  let percent = usage.activePercent, percent.isFinite,
                  percent >= settings.warningPercent {
            let level = percent >= 95 ? 95 : 90
            if try store.markWarning(input.sessionID, level: level, now: now) {
                messages.append("ZipSwap usage warning: the active Claude account is at \(Int(percent))%. \(usage.explanation) At the next natural stopping point, put a concise handoff recap in your visible response: the user's objective and constraints, decisions, files changed, checks and results, unfinished work, and any in-flight commands. Continue the authorized task; do not repeatedly retry a quota error. ZipSwap captures the saved transcript even if no recap is possible.")
            }
        }
        guard !messages.isEmpty else { return [:] }
        return ["hookSpecificOutput": ["hookEventName": input.event, "additionalContext": messages.joined(separator: "\n\n")]]
    }
}

public enum HandoffAdmission {
    public static func reasonToSkip(record: HandoffRecord, settings: HandoffSettings,
                                    usage: HandoffUsage?, now: Date) -> String? {
        guard settings.enabled else { return "Handoff is off. No Codex thread was created." }
        guard let enabledAt = settings.enabledAt, record.eventDate >= enabledAt else {
            return "This request predates the current handoff setting."
        }
        guard (0...300).contains(now.timeIntervalSince(record.eventDate)) else { return "The rate-limit event expired." }
        guard let usage, usage.isFresh(at: now) else {
            return "Claude usage could not be confirmed. No automatic handoff was started."
        }
        guard usage.claudeExhausted else {
            return "Claude still has a usable account, or the error was temporary. Account rotation takes priority."
        }
        return nil
    }
}
