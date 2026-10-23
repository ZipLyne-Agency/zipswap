import Foundation

extension CodexStore {
    private struct Removal: Codable { let accountID: String; let nonce: String }
    private var removalFile: URL { root.appendingPathComponent("removal.json") }
    private func removalPath(_ record: Removal) throws -> URL {
        guard UUID(uuidString: record.accountID) != nil, UUID(uuidString: record.nonce) != nil else { throw ShellError.failed("Invalid account-removal journal.") }
        return root.appendingPathComponent(".remove-\(record.accountID)-\(record.nonce)")
    }
    /// Caller holds the store lock. A crash before index replacement restores
    /// the saved directory; a crash after replacement completes its cleanup.
    func recoverPendingRemoval() throws {
        guard let data = try PrivateFile.readIfPresent(removalFile) else { return }
        let record = try JSONDecoder().decode(Removal.self, from: data)
        let staged = try removalPath(record), original = home(for: record.accountID)
        let listed = try loadIndex().contains { $0.id == record.accountID }
        if FileManager.default.fileExists(atPath: staged.path) {
            if listed {
                guard !FileManager.default.fileExists(atPath: original.path) else { throw ShellError.failed("Account removal needs manual storage reconciliation. Both generations were retained.") }
                try FileManager.default.moveItem(at: staged, to: original)
            } else { try FileManager.default.removeItem(at: staged) }
        }
        try FileManager.default.removeItem(at: removalFile)
    }
    func removeAccount(_ account: CodexStoredAccount) throws {
        try locked {
            try recoverPendingRemoval()
            guard try credential(liveAuth)?.accountID != account.accountId else { throw ShellError.failed("Switch away from this account before removing it.") }
            let previous = try loadIndex()
            guard previous.contains(where: { $0.id == account.id && $0.accountId == account.accountId }) else { throw ShellError.failed("This saved account changed. Refresh before removing it.") }
            let removal = Removal(accountID: account.id, nonce: UUID().uuidString.lowercased())
            let staged = try removalPath(removal), original = home(for: account.id)
            try PrivateFile.write(try JSONEncoder().encode(removal), to: removalFile)
            do {
                if FileManager.default.fileExists(atPath: original.path) { try FileManager.default.moveItem(at: original, to: staged) }
                try PrivateFile.write(try JSONEncoder().encode(previous), to: root.appendingPathComponent("accounts.backup.json"))
                try PrivateFile.write(try JSONEncoder().encode(previous.filter { $0.id != account.id }), to: indexURL)
            } catch {
                try? recoverPendingRemoval()
                throw error
            }
            do { try recoverPendingRemoval() }
            catch { throw ShellError.failed("The account was removed. Its private credential cleanup is pending; refresh to retry cleanup.") }
        }
    }
}
