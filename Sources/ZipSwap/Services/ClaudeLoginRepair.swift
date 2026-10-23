import Foundation

/// Uses the supported CLI login and helper capture. The browser cannot repair
/// a CLI identity by itself. Login occurs in a stable account-specific profile;
/// the previous default account is verified before capture and restored after.
enum ClaudeLoginRepair {
    static func repair(slot: Int, email: String) async throws {
        let before = try await ClaudeService.list()
        guard let original = before.first(where: \.isActive), let originalSlot = original.slot,
              before.contains(where: { $0.slot == slot && $0.email.caseInsensitiveCompare(email) == .orderedSame }) else {
            throw ShellError.failed("Refresh the account list before repairing this login.")
        }
        try await ClaudeService.verifyDefaultIdentity(email: original.email, organizationID: original.organizationID)
        let profile = Shell.home.appendingPathComponent("Library/Application Support/ZipSwap/ClaudeLogins/slot-\(slot)")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try profile.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw ShellError.failed("The repair profile must not be a symbolic link.")
        }
        let environment = ["CLAUDE_CONFIG_DIR": profile.path, "CLAUDE_SECURESTORAGE_CONFIG_DIR": profile.path]
        let login = try await Shell.run("claude", ["auth", "login", "--claudeai", "--email", email], env: environment, timeout: 600)
        guard login.status == 0 else { throw ShellError.failed("Sign-in did not finish. Choose Repair login to retry.") }
        try Task.checkCancellation()
        let status = try await Shell.run("claude", ["auth", "status"], env: environment, timeout: 15)
        guard status.status == 0, let object = try? JSONSerialization.jsonObject(with: status.stdout) as? [String: Any],
              object["loggedIn"] as? Bool == true,
              (object["email"] as? String)?.caseInsensitiveCompare(email) == .orderedSame,
              before.first(where: { $0.slot == slot })?.organizationID == nil || object["orgId"] as? String == before.first(where: { $0.slot == slot })?.organizationID else {
            throw ShellError.failed("The browser signed in to a different account. The saved login was not changed.")
        }
        try await ClaudeService.verifyDefaultIdentity(email: original.email, organizationID: original.organizationID)
        let capture: Result<ShellResult, Error>
        do { capture = .success(try await Shell.run(ClaudeService.tool, ["add", "--slot", String(slot)], env: environment, timeout: 90)) }
        catch { capture = .failure(error) }
        // Capture updates the helper's active metadata even for an isolated
        // profile. Re-capture the actual default CLI into its matching slot;
        // this does not write any default credential or undo an external login.
        // Cancellation cannot skip this bounded metadata reconciliation.
        try await Task.detached {
            let result = try await Shell.run(ClaudeService.tool, ["add"], timeout: 90)
            guard result.status == 0 else { throw ShellError.failed("The login was captured, but the default account needs reconciliation. Add the current default login in ZipSwap.") }
            try await ClaudeService.verifyDefaultIdentity(email: original.email, organizationID: original.organizationID)
        }.value
        let result = try capture.get()
        guard result.status == 0 else { throw ShellError.failed("The helper could not save this login. Confirm the account and organization, then retry.") }
        let after = try await ClaudeService.list()
        guard after.contains(where: { $0.slot == slot && $0.email.caseInsensitiveCompare(email) == .orderedSame && $0.problem != "Needs a fresh /login" }),
              after.first(where: \.isActive)?.slot == originalSlot else {
            throw ShellError.failed("Login repair could not be verified. The previous default account was retained.")
        }
    }
}
