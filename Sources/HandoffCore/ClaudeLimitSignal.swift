import Foundation

/// A Claude Code session on the default profile stopped at its usage limit.
///
/// Written by the bridge's StopFailure hook when limit switching is on, and
/// read by the app, which decides whether and where to switch. It carries only
/// a time: no prompt, transcript, path, account or credential data.
public struct ClaudeLimitSignal: Codable, Equatable {
    public let at: Date
    public init(at: Date) { self.at = at }
}

public enum ClaudeLimitSignals {
    static let signalName = "claude-limit-signal.json"
    static let settingName = "claude-limit-switch.json"
    struct Setting: Codable { var enabled: Bool }

    public static func isEnabled(_ store: HandoffStore) -> Bool {
        (try? store.read(Setting.self, name: settingName))?.enabled == true
    }

    public static func setEnabled(_ enabled: Bool, store: HandoffStore) throws {
        try store.write(Setting(enabled: enabled), name: settingName)
    }

    public static func latest(_ store: HandoffStore) -> ClaudeLimitSignal? {
        try? store.read(ClaudeLimitSignal.self, name: signalName)
    }

    /// The session uses Claude Code's default login, the one ZipSwap switches.
    /// Any configured profile directory may hold a different login (claude-swap
    /// `run`, Orca, a pinned terminal), so its limit says nothing about the
    /// active account.
    public static func isDefaultProfile(_ environment: [String: String]) -> Bool {
        ["CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR"].allSatisfy { (environment[$0] ?? "").isEmpty }
    }

    /// Records a root session's usage-limit stop. Fails closed and never throws:
    /// a hook must not stall or fail Claude Code.
    @discardableResult
    public static func record(_ data: Data, store: HandoffStore, environment: [String: String],
                              now: Date = Date()) -> Bool {
        guard isEnabled(store), data.count <= 1_048_576,
              let input = try? JSONDecoder().decode(ClaudeHookInput.self, from: data),
              input.event == "StopFailure", input.error == "rate_limit", input.agentID == nil,
              isDefaultProfile(environment) else { return false }
        return (try? store.write(ClaudeLimitSignal(at: now), name: signalName)) != nil
    }
}
