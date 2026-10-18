import Foundation
import Darwin

/// A bounded, sequential stdio client. Notifications are discarded, and no
/// model turn is started by this client. The bridge creates a private process
/// group so timeout cleanup cannot affect other Codex sessions.
public final class CodexRPC {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let condition = NSCondition()
    private var pending = Data()
    private var responses: [Int: [String: Any]] = [:]
    private var failure: Error?
    private var nextID = 1
    private var expectedID: Int?
    private let deadline: Date
    private var closed = false

    public init(executable: URL, arguments: [String], environment: [String: String],
                lifetime: TimeInterval = 75) throws {
        signal(SIGPIPE, SIG_IGN)
        deadline = Date().addingTimeInterval(lifetime)
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.receive(data)
        }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.condition.lock()
            self.failure = HandoffError.unavailable("Codex closed the handoff connection.")
            self.condition.broadcast()
            self.condition.unlock()
        }
        do {
            try process.run()
            _ = try call("initialize", params: [
                "clientInfo": ["name": "zipswap_handoff", "title": "ZipSwap Handoff", "version": "1.0.0"],
                "capabilities": ["experimentalApi": true],
            ])
            try send(["method": "initialized"])
        } catch {
            close()
            throw error
        }
    }

    public func call(_ method: String, params: [String: Any] = [:]) throws -> [String: Any] {
        let id = nextID
        nextID += 1
        condition.lock()
        expectedID = id
        condition.unlock()
        try send(["id": id, "method": method, "params": params])
        condition.lock()
        defer { expectedID = nil; condition.unlock() }
        while responses[id] == nil && failure == nil {
            guard condition.wait(until: deadline) else {
                throw HandoffError.unavailable("Codex handoff timed out. No automatic retry will run.")
            }
        }
        guard let reply = responses.removeValue(forKey: id) else {
            throw failure ?? HandoffError.unavailable("Codex did not answer.")
        }
        if let error = reply["error"] as? [String: Any] {
            let code = error["code"] as? Int ?? 0
            throw HandoffError.unavailable("Codex rejected \(method) (\(code)). Update Codex if this method is unsupported.")
        }
        guard let result = reply["result"] as? [String: Any] else {
            throw HandoffError.invalid("Codex returned an invalid response to \(method).")
        }
        return result
    }

    private func send(_ value: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: value)
        guard data.count <= 2_000_000 else { throw HandoffError.invalid("The handoff exceeds Codex's local request limit.") }
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        condition.lock()
        defer { condition.broadcast(); condition.unlock() }
        if data.isEmpty {
            failure = HandoffError.unavailable("Codex closed the handoff connection.")
            return
        }
        pending.append(data)
        guard pending.count <= 4_000_000 else {
            failure = HandoffError.invalid("Codex emitted an oversized handoff response.")
            pending.removeAll()
            return
        }
        while let newline = pending.firstIndex(of: 10) {
            let line = pending.prefix(upTo: newline)
            if let reply = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
               let id = reply["id"] as? Int, id == expectedID {
                responses[id] = reply
            }
            pending.removeSubrange(...newline)
        }
    }

    public func close() {
        guard !closed else { return }
        closed = true
        try? input.fileHandleForWriting.close()
        let gracefulDeadline = Date().addingTimeInterval(1)
        while process.isRunning && Date() < gracefulDeadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            let pid = process.processIdentifier
            if getpgid(pid) == pid { kill(-pid, SIGTERM) } else { process.terminate() }
            let killDeadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < killDeadline { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning {
                if getpgid(pid) == pid { kill(-pid, SIGKILL) } else { kill(pid, SIGKILL) }
            }
        }
        output.fileHandleForReading.readabilityHandler = nil
        try? output.fileHandleForReading.close()
    }

    deinit { close() }
}

public enum HandoffEnvironment {
    /// Use the existing subscription login. Never fall through to an API key or
    /// an alternate provider inherited from a terminal environment.
    public static func subscription(_ base: [String: String]) -> [String: String] {
        var env = base
        for key in ["OPENAI_API_KEY", "CODEX_API_KEY", "OPENAI_BASE_URL", "CODEX_ACCESS_TOKEN",
                    "CODEX_INTERNAL_ORIGINATOR_OVERRIDE", "CODEX_THREAD_ID", "CLAUDE_CODE_SESSION_ID"] {
            env.removeValue(forKey: key)
        }
        return env
    }

    public static let subscriptionArguments = ["-c", "model_provider=\"openai\"",
                                              "-c", "forced_login_method=\"chatgpt\""]
}
