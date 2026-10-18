import Foundation
import Darwin

/// Local metadata only. Conversation text goes directly into Codex's own history.
/// A file lock covers admission across hook helpers and multiple app instances.
public struct HandoffStore {
    public let root: URL
    public static let maximumRecords = 1000
    public static let maximumPending = 16
    public init(root: URL = HandoffPaths.root) { self.root = root }

    public func settings() throws -> HandoffSettings {
        try read(HandoffSettings.self, name: "settings.json") ?? HandoffSettings()
    }

    public func usage() throws -> HandoffUsage? { try read(HandoffUsage.self, name: "usage.json") }

    public func saveSettings(_ value: HandoffSettings) throws {
        try locked { try write(value, name: "settings.json") }
    }

    public func saveUsage(_ value: HandoffUsage) throws {
        try locked { try write(value, name: "usage.json") }
    }

    public func records() throws -> [HandoffRecord] {
        try read([HandoffRecord].self, name: "records.json") ?? []
    }

    public func record(_ id: String) throws -> HandoffRecord? {
        try records().first { $0.id == id.lowercased() }
    }

    @discardableResult
    public func enqueue(_ input: ClaudeHookInput, now: Date) throws -> Bool {
        try locked {
            let config = try settings()
            guard config.enabled else { return false }
            var all = try records()
            let id = input.sessionID.lowercased()
            if let index = all.firstIndex(where: { $0.id == id }) {
                // A temporary throttle or a healthy alternate account must not
                // permanently disable failover for a later genuine quota event.
                // Only a NEW event may recheck admission, at most three times.
                guard all[index].phase == .skipped, all[index].threadID == nil, all[index].attemptedAt == nil,
                      (all[index].admissionChecks ?? 0) < 3,
                      now.timeIntervalSince(all[index].eventDate) >= 60,
                      all.filter({ $0.phase == .queued || $0.phase == .preparing }).count < Self.maximumPending else { return false }
                all[index].phase = .queued
                all[index].lastEventAt = now
                all[index].updatedAt = now
                all[index].detail = "A new rate-limit event is waiting for a usage check."
                try write(all, name: "records.json")
                return true
            }
            guard all.count < Self.maximumRecords,
                  all.filter({ $0.phase == .queued || $0.phase == .preparing }).count < Self.maximumPending else {
                throw HandoffError.unavailable("The handoff queue is full. Open ZipSwap to inspect it.")
            }
            all.insert(HandoffRecord(sessionID: id, transcriptPath: input.transcriptPath, cwd: input.cwd, now: now), at: 0)
            try write(all, name: "records.json")
            return true
        }
    }

    public func update(_ id: String, _ change: (inout HandoffRecord) throws -> Void) throws {
        try locked {
            var all = try records()
            guard let index = all.firstIndex(where: { $0.id == id }) else {
                throw HandoffError.invalid("This handoff no longer exists.")
            }
            try change(&all[index])
            try write(all, name: "records.json")
        }
    }

    /// Reserve before starting Codex. Never automatically retry ambiguous outcomes.
    public func claim(_ id: String, now: Date) throws -> Bool {
        try locked {
            let config = try settings()
            guard config.enabled, let enabledAt = config.enabledAt else { return false }
            var all = try records()
            guard let index = all.firstIndex(where: { $0.id == id }), all[index].phase == .queued else { return false }
            guard !all.contains(where: { $0.phase == .preparing }) else { return false }
            let recent = all.filter { $0.attemptedAt.map { (0..<3600).contains(now.timeIntervalSince($0)) } ?? false }
            if all[index].eventDate < enabledAt || !(0...300).contains(now.timeIntervalSince(all[index].eventDate)) {
                all[index].phase = .skipped
                all[index].detail = "This request expired. Start a new Claude session to enable automatic handoff again."
            } else if recent.count >= 4 {
                all[index].phase = .skipped
                all[index].detail = "Automatic handoff limit reached (4 per hour). No Codex turn was started."
            } else {
                all[index].phase = .preparing
                all[index].attemptedAt = now
                all[index].detail = "Preparing the Codex conversation."
            }
            all[index].updatedAt = now
            try write(all, name: "records.json")
            return all[index].phase == .preparing
        }
    }

    public func markWarning(_ sessionID: String, level: Int, now: Date) throws -> Bool {
        try locked {
            var stamps = try read([String: WarningStamp].self, name: "warnings.json") ?? [:]
            stamps = stamps.filter { now.timeIntervalSince($0.value.at) < 86_400 }
            if let old = stamps[sessionID], old.level >= level { return false }
            guard stamps.count < 1000 else { return false }
            stamps[sessionID] = WarningStamp(level: level, at: now)
            try write(stamps, name: "warnings.json")
            return true
        }
    }

    public func recoverInterrupted(now: Date) throws {
        try locked {
            var all = try records()
            for i in all.indices where all[i].phase == .preparing && now.timeIntervalSince(all[i].updatedAt) > 120 {
                all[i].phase = .failed
                all[i].detail = "Preparation was interrupted. No automatic retry will create a duplicate thread."
                all[i].updatedAt = now
            }
            try write(all, name: "records.json")
        }
    }

    private struct WarningStamp: Codable { let level: Int; let at: Date }

    private func read<T: Decodable>(_ type: T.Type, name: String) throws -> T? {
        let url = root.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw HandoffError.unavailable("Cannot safely read ZipSwap handoff state.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let data = try handle.read(upToCount: 16_000_001) ?? Data()
        guard data.count <= 16_000_000 else { throw HandoffError.invalid("ZipSwap handoff state exceeds its size limit.") }
        return try JSONDecoder().decode(type, from: data)
    }

    public func writePrivate(_ data: Data, name: String, executable: Bool = false) throws -> URL {
        guard !name.contains("/"), !name.hasPrefix(".") else { throw HandoffError.invalid("Invalid state filename.") }
        try ensureRoot()
        let url = root.appendingPathComponent(name)
        let temp = root.appendingPathComponent(".\(UUID().uuidString).tmp")
        let fd = Darwin.open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, executable ? 0o700 : 0o600)
        guard fd >= 0 else { throw HandoffError.unavailable("Cannot write ZipSwap handoff state.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard rename(temp.path, url.path) == 0 else { throw HandoffError.unavailable("Cannot save ZipSwap handoff state.") }
        return url
    }

    private func write<T: Encodable>(_ value: T, name: String) throws {
        let data = try JSONEncoder().encode(value)
        _ = try writePrivate(data, name: name)
    }

    private func ensureRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard (try root.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
            throw HandoffError.invalid("The handoff store must not be a symbolic link.")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }

    private func locked<T>(_ operation: () throws -> T) throws -> T {
        try ensureRoot()
        let fd = Darwin.open(root.appendingPathComponent("state.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw HandoffError.unavailable("Cannot lock ZipSwap handoff state.") }
        defer { Darwin.close(fd) }
        let deadline = Date().addingTimeInterval(0.2)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard Date() < deadline else {
                throw HandoffError.unavailable("ZipSwap is updating handoff state. Try again.")
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        defer { flock(fd, LOCK_UN) }
        return try operation()
    }
}
