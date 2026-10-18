import Foundation

enum HandoffIntegration {
    static var helper: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ZipSwapBridge")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static var destination: URL {
        HandoffPaths.root.deletingLastPathComponent().appendingPathComponent("HandoffIntegration", isDirectory: true)
    }

    static func installed() async -> Bool {
        guard let result = try? await Shell.run("claude", ["plugin", "list", "--json"], timeout: 15),
              result.status == 0,
              let rows = try? JSONSerialization.jsonObject(with: result.stdout) as? [[String: Any]] else { return false }
        return rows.contains { ($0["id"] as? String) == "zipswap-handoff@zipswap-local" && $0["enabled"] as? Bool == true }
    }

    static func install() async throws {
        guard let helper,
              let template = Bundle.main.resourceURL?.appendingPathComponent("HandoffIntegration"),
              FileManager.default.fileExists(atPath: template.path) else {
            throw HandoffError.unavailable("This build is missing the bundled Claude integration.")
        }
        let fm = FileManager.default
        // Only ZipSwap's own plugin directory is replaced. Claude settings are
        // managed through its supported plugin CLI, never edited directly.
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.copyItem(at: template, to: destination)
        let script = destination.appendingPathComponent("plugins/handoff/bin/handoff")
        try Data("#!/bin/sh\nexec \(HandoffCommands.quote(helper.path)) hook\n".utf8).write(to: script, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let validation = try await Shell.run("claude", ["plugin", "validate", destination.path, "--json"], timeout: 15)
        guard validation.status == 0 else { throw HandoffError.unavailable("Claude rejected the bundled integration manifest.") }
        let installation = try await Shell.run("claude", ["plugin", "install", "zipswap-handoff", "--marketplace",
                                                          destination.path, "--scope", "user", "--json"], timeout: 60)
        guard installation.status == 0, await installed() else {
            throw HandoffError.unavailable("Claude could not install the integration. Check Claude's /plugin screen, then try again.")
        }
    }
}
