import Foundation
#if SWIFT_PACKAGE
import HandoffCore
#endif

/// One unresolved scarce-credit operation per saved account. An ambiguous
/// response survives restart and can only retry the same provider credit.
enum ResetOperations {
    enum Phase: String, Codable { case pending, unknown, confirmed, unavailable }
    struct Record: Codable {
        let accountID: String
        let creditID: String
        let key: String
        var phase: Phase
    }
    static func read(_ file: URL) throws -> Record? {
        try PrivateFile.readIfPresent(file).map { try JSONDecoder().decode(Record.self, from: $0) }
    }
    static func pendingCredit(_ file: URL) throws -> String? {
        guard let record = try read(file), [.pending,.unknown].contains(record.phase) else { return nil }
        return record.creditID
    }
    static func reserve(_ file: URL, accountID: String, creditID: String) throws -> Record {
        guard !creditID.isEmpty, creditID.count <= 512 else { throw ShellError.failed("Invalid reset credit identifier.") }
        if let old = try read(file), [.pending,.unknown].contains(old.phase) {
            guard old.accountID == accountID else { throw ShellError.failed("The saved reset operation belongs to another account.") }
            return old
        }
        let record = Record(accountID: accountID, creditID: creditID, key: UUID().uuidString.lowercased(), phase: .pending)
        try save(record, to: file)
        return record
    }
    static func save(_ record: Record, to file: URL) throws { try PrivateFile.write(try JSONEncoder().encode(record), to: file) }
    static func failurePhase(_ error: Error) -> Phase {
        (error as? CodexRPCError)?.rejectedBeforeExecution == true ? .unavailable : .unknown
    }
    static func reconcile(_ file: URL, credits: [[String: Any]]) throws {
        guard var record = try read(file), [.pending,.unknown].contains(record.phase) else { return }
        guard let credit = credits.first(where: { $0["id"] as? String == record.creditID }) else {
            // Only called with a fresh, complete provider credit inventory.
            // Absence means this credit cannot be selected again; it does not
            // claim whether the earlier ambiguous attempt consumed it.
            record.phase = .unavailable; try save(record, to: file); return
        }
        guard let status = credit["status"] as? String else { return }
        switch status {
        case "redeemed": record.phase = .confirmed
        case "expired", "revoked": record.phase = .unavailable
        default: return
        }
        try save(record, to: file)
    }
}
