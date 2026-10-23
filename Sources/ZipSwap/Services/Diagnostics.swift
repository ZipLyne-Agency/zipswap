import Foundation

/// The diagnostic schema deliberately has no free-text, credential, email,
/// transcript, command, endpoint or environment field.
struct DiagnosticEvent: Codable {
    let at: Date
    let provider: Provider
    let operation: String
    let accountID: String?
    let outcome: String
}

enum Diagnostics {
    private static let lock = NSLock()
    static let root = Shell.home.appendingPathComponent("Library/Application Support/ZipSwap/Diagnostics")
    static func record(provider: Provider, operation: String, accountID: String? = nil, outcome: String) {
        lock.lock(); defer { lock.unlock() }
        let allowedOperations = ["refresh", "switch", "engine", "repair", "reset", "storage", "compatibility"]
        let allowedOutcomes = ["started", "verified", "failed", "expired", "retry", "cancelled"]
        guard allowedOperations.contains(operation), allowedOutcomes.contains(outcome) else { return }
        let url = root.appendingPathComponent("events.json")
        do {
            var events = try PrivateFile.readIfPresent(url).flatMap { try JSONDecoder().decode([DiagnosticEvent].self, from: $0) } ?? []
            let id = accountID.flatMap { $0.hasPrefix("claude-") || $0.hasPrefix("codex-") ? $0 : nil }
            events.append(DiagnosticEvent(at: .now, provider: provider, operation: operation, accountID: id, outcome: outcome))
            try PrivateFile.write(try JSONEncoder().encode(Array(events.suffix(200))), to: url)
        } catch {
            // Diagnostics are best effort and never cause a second provider call.
            NSLog("ZipSwap diagnostics could not be saved")
        }
    }
    static func supportData() throws -> Data {
        struct Support: Encodable {
            let version: String
            let build: String
            let revision: String
            let events: [DiagnosticEvent]
        }
        let events = try PrivateFile.readIfPresent(root.appendingPathComponent("events.json"))
            .flatMap { try JSONDecoder().decode([DiagnosticEvent].self, from: $0) } ?? []
        return try JSONEncoder().encode(Support(version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development",
            build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "local",
            revision: Bundle.main.infoDictionary?["ZipSwapSourceRevision"] as? String ?? "unrecorded", events: events))
    }
}
