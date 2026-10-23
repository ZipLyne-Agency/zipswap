import Foundation
import Darwin
#if SWIFT_PACKAGE
import HandoffCore
#endif

/// Serializes ZipSwap writers. External CLI changes are compared again at the
/// write boundary and verified after activation; they are never rolled back.
struct CodexStore {
    let root: URL
    let liveHome: URL
    var indexURL: URL { root.appendingPathComponent("accounts.json") }
    var liveAuth: URL { liveHome.appendingPathComponent("auth.json") }
    func home(for id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    private struct Index: Codable { let version: Int; let accounts: [CodexStoredAccount] }

    func loadIndex() throws -> [CodexStoredAccount] {
        guard let data = try PrivateFile.readIfPresent(indexURL) else { return [] }
        do { return try decodeIndex(data) }
        catch { throw ShellError.failed("Saved Codex accounts could not be read. Restore the account-list backup in Settings.") }
    }
    private func decodeIndex(_ data: Data) throws -> [CodexStoredAccount] {
        let decoder = JSONDecoder()
        let accounts: [CodexStoredAccount]
        if let legacy = try? decoder.decode([CodexStoredAccount].self, from: data) { accounts = legacy }
        else {
            let index = try decoder.decode(Index.self, from: data)
            guard index.version == 1 else { throw ShellError.failed("Unsupported Codex account-list version.") }
            accounts = index.accounts
        }
        guard accounts.count <= 128, Set(accounts.map(\.id)).count == accounts.count,
              Set(accounts.map(\.accountId)).count == accounts.count,
              accounts.allSatisfy({ UUID(uuidString: $0.id) != nil && !$0.accountId.isEmpty }) else {
            throw ShellError.failed("Invalid or duplicate saved Codex accounts.")
        }
        return accounts
    }
    func saveIndex(_ accounts: [CodexStoredAccount], replacing previous: [CodexStoredAccount]) throws {
        try locked {
            guard try loadIndex() == previous else { throw ShellError.failed("The account list changed in another window. Refresh and try again.") }
            // Preserve the public release's array contract so an app rollback
            // keeps every saved account readable. Object envelopes are read
            // for recovery, but never required by a new write.
            let data = try JSONEncoder().encode(accounts)
            _ = try decodeIndex(data)
            if let old = try PrivateFile.readIfPresent(indexURL) {
                try PrivateFile.write(old, to: root.appendingPathComponent("accounts.backup.json"))
            }
            try PrivateFile.write(data, to: indexURL)
        }
    }
    func restoreIndexBackup() throws {
        try locked {
            let backup = root.appendingPathComponent("accounts.backup.json")
            guard let data = try PrivateFile.readIfPresent(backup) else { throw ShellError.failed("No account-list backup is available.") }
            let accounts = try decodeIndex(data)
            for account in accounts {
                guard try credential(home(for: account.id).appendingPathComponent("auth.json"))?.accountID == account.accountId else {
                    throw ShellError.failed("The backup references a missing or mismatched saved login.")
                }
            }
            try PrivateFile.write(data, to: indexURL)
        }
    }

    struct Credential {
        let data: Data
        let accountID: String
        let refreshedAt: Date?
    }
    enum CredentialIssue: LocalizedError {
        case nonSubscriptionOrMalformed
        var errorDescription: String? { "The Codex login is not a valid ChatGPT subscription login. Sign in to that account again." }
    }
    func credential(_ url: URL) throws -> Credential? {
        guard let data = try PrivateFile.readIfPresent(url) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["auth_mode"] == nil || object["auth_mode"] as? String == "chatgpt",
              (object["OPENAI_API_KEY"] as? String).map({ $0.isEmpty }) ?? true,
              let tokens = object["tokens"] as? [String: Any],
              let id = tokens["account_id"] as? String, !id.isEmpty,
              let access = tokens["access_token"] as? String, !access.isEmpty else {
            throw CredentialIssue.nonSubscriptionOrMalformed
        }
        return Credential(data: data, accountID: id, refreshedAt: Format.date(object["last_refresh"]))
    }
    private func copyNewest(_ source: Credential, to destination: URL) throws {
        let existing = try credential(destination)
        if let existing {
            guard existing.accountID == source.accountID else { throw ShellError.failed("Saved Codex login identity does not match its account.") }
            if existing.data == source.data { return }
            guard let from = source.refreshedAt, let to = existing.refreshedAt else {
                throw ShellError.failed("Two Codex logins changed without refresh timestamps. Sign in again to reconcile them.")
            }
            guard from >= to else { return }
            guard from != to else { throw ShellError.failed("Codex logins changed in the same refresh generation. Sign in again to reconcile them.") }
        }
        try PrivateFile.write(source.data, to: destination, expected: existing?.data, compare: true)
    }

    func syncLive(into accounts: inout [CodexStoredAccount]) throws {
        let updated = try locked { () -> [CodexStoredAccount] in
            try recoverPendingRemoval()
            var latest = try loadIndex()
            let live: Credential
            do {
                guard let value = try credential(liveAuth) else { return latest }
                live = value
            } catch is CredentialIssue {
                // A separate API-key or incomplete CLI login does not prevent
                // reading saved subscription profiles. Activation stays strict.
                return latest
            }
            if let match = latest.first(where: { $0.accountId == live.accountID }) {
                try copyNewest(live, to: home(for: match.id).appendingPathComponent("auth.json"))
            } else {
                guard latest.count < 128 else { throw ShellError.failed("The saved-account limit is 128.") }
                let id = UUID().uuidString.lowercased()
                try PrivateFile.write(live.data, to: home(for: id).appendingPathComponent("auth.json"), expected: nil, compare: true)
                latest.append(CodexStoredAccount(id: id, name: "Codex", email: "", accountId: live.accountID, plan: ""))
                try PrivateFile.write(try JSONEncoder().encode(latest), to: indexURL)
            }
            guard try credential(liveAuth)?.data == live.data else {
                throw ShellError.failed("Codex signed in or refreshed in another client. Refresh before switching.")
            }
            return latest
        }
        accounts = updated
    }

    func activate(_ target: CodexStoredAccount, expectedLiveID: String?) throws {
        try locked {
            let accounts = try loadIndex()
            guard accounts.contains(where: { $0.id == target.id && $0.accountId == target.accountId }) else {
                throw ShellError.failed("The selected Codex account changed. Refresh before switching.")
            }
            let old = try credential(liveAuth)
            guard old?.accountID == expectedLiveID else { throw ShellError.failed("Another client changed the active Codex account. Refresh before switching.") }
            if let old, let previous = accounts.first(where: { $0.accountId == old.accountID }) {
                try copyNewest(old, to: home(for: previous.id).appendingPathComponent("auth.json"))
            }
            guard let source = try credential(home(for: target.id).appendingPathComponent("auth.json")), source.accountID == target.accountId else {
                throw ShellError.failed("The saved login does not match the selected Codex account.")
            }
            try PrivateFile.write(source.data, to: liveAuth, expected: old?.data, compare: true)
            guard try credential(liveAuth)?.data == source.data else {
                throw ShellError.failed("The Codex login changed during activation. Refresh to verify its identity.")
            }
        }
    }

    func locked<T>(_ operation: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw ShellError.failed("The Codex store must not be a symbolic link.") }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let fd = Darwin.open(root.appendingPathComponent("accounts.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ShellError.failed("Cannot lock the Codex account store.") }
        defer { Darwin.close(fd) }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.3
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ShellError.failed("Another account operation is in progress. Try again.") }
            Thread.sleep(forTimeInterval: 0.01)
        }
        defer { flock(fd, LOCK_UN) }
        return try operation()
    }
}

/// Bounded, owner-only, no-symlink I/O. Comparisons reject stale cooperating
/// writers; provider identity readback remains mandatory after a live change.
public enum PrivateFile {
    public static func readIfPresent(_ url: URL, maximum: Int = 2_000_000) throws -> Data? {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw ShellError.failed("Cannot safely read local account state.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_size <= maximum else {
            throw ShellError.failed("Local account state is invalid or exceeds its size limit.")
        }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw ShellError.failed("Local account state exceeds its size limit.") }
        return data
    }
    public static func write(_ data: Data, to url: URL, expected: Data? = nil, compare: Bool = false) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw ShellError.failed("The account directory must not be a symbolic link.") }
        let temporary = directory.appendingPathComponent(".zipswap-\(UUID().uuidString).tmp")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ShellError.failed("Cannot create private account state.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        if compare, try readIfPresent(url) != expected { throw ShellError.failed("Account state changed during this operation. Refresh and try again.") }
        guard Darwin.rename(temporary.path, url.path) == 0 else { throw ShellError.failed("Cannot save private account state.") }
        let parentFD = Darwin.open(directory.path, O_RDONLY)
        if parentFD >= 0 { _ = fsync(parentFD); Darwin.close(parentFD) }
    }
}
