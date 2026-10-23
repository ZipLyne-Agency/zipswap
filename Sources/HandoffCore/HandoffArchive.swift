import Foundation
import Darwin

extension HandoffStore {
    public func archivedRecords() throws -> [HandoffRecord] {
        try read([HandoffRecord].self, name: "archive.json") ?? []
    }
    public func archive(_ id: String, now: Date = Date()) throws {
        try locked {
            var all = try records()
            guard let record = all.first(where: { $0.id == id }), ![.queued, .preparing, .opening, .running].contains(record.phase) else {
                throw HandoffError.unavailable("Wait for this handoff operation to finish before archiving it.")
            }
            var archive = try archivedRecords().filter { $0.id != id }
            archive.insert(record, at: 0)
            // Metadata only. Original Claude and Codex conversations remain in
            // their providers' history. Recent attempts survive for admission.
            archive = Array(archive.prefix(Self.maximumRecords))
            try write(archive, name: "archive.json")
            all.removeAll { $0.id == id }
            try write(all, name: "records.json")
        }
    }
    public func restoreArchive(_ id: String) throws {
        try locked {
            var all = try records()
            var archive = try archivedRecords()
            guard all.count < Self.maximumRecords, let record = archive.first(where: { $0.id == id }) else {
                throw HandoffError.unavailable("The handoff list is full, or this archive is missing.")
            }
            if !all.contains(where: { $0.id == id }) { all.insert(record, at: 0) }
            try write(all, name: "records.json")
            archive.removeAll { $0.id == id }
            try write(archive, name: "archive.json")
        }
    }

    public func approveWorkspace(_ id: String, contextHash: String, now: Date = Date()) throws {
        guard contextHash.count == 64, contextHash.allSatisfy({ $0.isHexDigit }) else { throw HandoffError.invalid("Invalid context receipt.") }
        try locked {
            var all = try records()
            guard let index = all.firstIndex(where: { $0.id == id }), all[index].phase == .review else {
                throw HandoffError.unavailable("This handoff no longer needs a context review.")
            }
            var configuration = try settings()
            guard configuration.enabled else { throw HandoffError.unavailable("Enable handoff before approving this workspace.") }
            var allowed = configuration.approvedWorkspaces ?? []
            let workspace = HandoffPrivacy.canonicalWorkspace(all[index].cwd)
            if !allowed.contains(workspace) {
                guard allowed.count < 128 else { throw HandoffError.unavailable("The approved-workspace limit is 128.") }
                allowed.append(workspace)
            }
            configuration.approvedWorkspaces = allowed
            try write(configuration, name: "settings.json")
            all[index].phase = .queued
            all[index].reviewedContextSHA256 = contextHash
            all[index].lastEventAt = now
            all[index].updatedAt = now
            all[index].detail = "Workspace approved. Waiting to prepare the reviewed context."
            try write(all, name: "records.json")
        }
    }
    public func revokeWorkspace(_ cwd: String) throws {
        try locked {
            var configuration = try settings()
            configuration.approvedWorkspaces?.removeAll { $0 == HandoffPrivacy.canonicalWorkspace(cwd) }
            try write(configuration, name: "settings.json")
        }
    }
}

/// Held by the terminal bridge until the CLI exits. The child cannot inherit
/// this lock, so a crashed bridge releases it without touching other sessions.
public final class HandoffConsumerLease {
    private let fd: Int32
    public init(root: URL, recordID: String) throws {
        guard HandoffPaths.validID(recordID) else { throw HandoffError.invalid("Invalid handoff ID.") }
        let url = root.appendingPathComponent("consumer-\(recordID).lock")
        fd = Darwin.open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw HandoffError.unavailable("Cannot lock the handoff continuation.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            throw HandoffError.unavailable("This handoff is already open in another terminal.")
        }
    }
    deinit { flock(fd, LOCK_UN); Darwin.close(fd) }
}
