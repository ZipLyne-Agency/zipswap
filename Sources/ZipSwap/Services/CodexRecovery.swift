import Foundation

extension CodexStore {
    /// Explicit local recovery only. Does not delete credentials or change the
    /// default CLI identity. Unknown generations are never silently merged.
    func recoverSavedLogins() throws -> Int {
        try locked {
            try recoverPendingRemoval()
            let previous = try? loadIndex()
            var accounts = previous ?? []
            var recovered: [String: (id: String, credential: Credential)] = [:]
            let directories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            for directory in directories.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let id = directory.lastPathComponent
                guard UUID(uuidString: id) != nil, !accounts.contains(where: { $0.id == id }) else { continue }
                let attributes = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard attributes.isDirectory == true, attributes.isSymbolicLink != true,
                      let credential = try credential(directory.appendingPathComponent("auth.json")),
                      !accounts.contains(where: { $0.accountId == credential.accountID }) else { continue }
                if let old = recovered[credential.accountID] {
                    guard let first = old.credential.refreshedAt, let second = credential.refreshedAt, first != second else {
                        throw ShellError.failed("Several saved logins have an ambiguous refresh generation. Restore the account-list backup instead.")
                    }
                    if second > first { recovered[credential.accountID] = (id, credential) }
                } else { recovered[credential.accountID] = (id, credential) }
            }
            guard accounts.count + recovered.count <= 128 else { throw ShellError.failed("The saved-account limit is 128.") }
            for value in recovered.values.sorted(by: { $0.id < $1.id }) {
                accounts.append(CodexStoredAccount(id: value.id, name: "Codex", email: "", accountId: value.credential.accountID, plan: ""))
            }
            guard !recovered.isEmpty else { throw ShellError.failed("No additional valid saved logins were found.") }
            if let old = try PrivateFile.readIfPresent(indexURL) {
                try PrivateFile.write(old, to: root.appendingPathComponent(previous == nil ? "accounts.corrupt.json" : "accounts.backup.json"))
            }
            try PrivateFile.write(try JSONEncoder().encode(accounts), to: indexURL)
            return recovered.count
        }
    }
}
