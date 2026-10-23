import Foundation

public enum HandoffCommands {
    public static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    public static func find(_ name: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        return paths.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public static func environment() -> [String: String] {
        var env = HandoffEnvironment.subscription(ProcessInfo.processInfo.environment)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        return env
    }

    public static func resumeArguments(_ record: HandoffRecord, initial: Bool) throws -> [String] {
        guard record.canOpen, let threadID = record.threadID, HandoffPaths.validID(threadID) else {
            throw HandoffError.invalid("The Codex thread is not ready to open.")
        }
        var args = HandoffEnvironment.subscriptionArguments + ["-C", record.cwd, "-a", "on-request", "-s", "workspace-write",
                                                               "resume", threadID]
        if initial {
            args.append("Continue the task from the imported Claude conversation. First check current files and any unfinished operations; preserve the user's scope and approvals.")
        }
        return args
    }

    public static func resumeCommand(_ record: HandoffRecord, codex: URL) throws -> String {
        ([codex.path] + (try resumeArguments(record, initial: false))).map(quote).joined(separator: " ")
    }

    public static func guardedResumeCommand(_ record: HandoffRecord, helper: URL, root: URL) throws -> String {
        guard record.canOpen, HandoffPaths.validID(record.id) else { throw HandoffError.invalid("The handoff is not ready.") }
        return [helper.path, "resume", "--root", root.path, "--id", record.id].map(quote).joined(separator: " ")
    }

    public static func terminalScript(helper: URL, root: URL, recordID: String) throws -> Data {
        guard HandoffPaths.validID(recordID), helper.path.hasPrefix("/"), root.path.hasPrefix("/") else {
            throw HandoffError.invalid("Invalid thread launch parameters.")
        }
        let command = [helper.path, "resume", "--root", root.path, "--id", recordID].map(quote).joined(separator: " ")
        return Data("#!/bin/sh\nexec \(command)\n".utf8)
    }

    public static func workspaceStatus(_ cwd: String) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = ["--no-optional-locks", "-c", "core.fsmonitor=false", "-C", cwd,
                          "status", "--short", "--branch", "--untracked-files=normal"]
        let pipe = Pipe()
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        let buffer = BoundedOutput()
        pipe.fileHandleForReading.readabilityHandler = { buffer.append($0.availableData) }
        do { try task.run() } catch { return "Git status unavailable; inspect current files before editing." }
        let deadline = Date().addingTimeInterval(3)
        while task.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if task.isRunning { task.terminate() }
        let stopDeadline = Date().addingTimeInterval(0.5)
        while task.isRunning && Date() < stopDeadline { Thread.sleep(forTimeInterval: 0.02) }
        if task.isRunning { kill(task.processIdentifier, SIGKILL) }
        pipe.fileHandleForReading.readabilityHandler = nil
        guard !task.isRunning, task.terminationStatus == 0 else {
            return "Git status unavailable; inspect current files before editing."
        }
        buffer.append(pipe.fileHandleForReading.readDataToEndOfFile())
        return buffer.text
    }
}

private final class BoundedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ value: Data) { lock.lock(); defer { lock.unlock() }; data.append(value.prefix(max(0, 16_000 - data.count))) }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}
