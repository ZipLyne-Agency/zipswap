import Foundation
#if SWIFT_PACKAGE
import HandoffCore
#endif

struct ShellResult {
    let status: Int32
    let stdout: Data
    let stderr: Data
    var out: String { String(decoding: stdout, as: UTF8.self) }
    var err: String { String(decoding: stderr, as: UTF8.self) }
}

enum ShellError: LocalizedError {
    case notFound(String), timedOut(String), failed(String)
    var errorDescription: String? {
        switch self {
        case .notFound(let tool): return "\(tool) isn't installed or isn't on the PATH."
        case .timedOut(let tool): return "\(tool) took too long to answer."
        case .failed(let message): return message
        }
    }
}

enum Shell {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let searchPath = [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    static func environment(_ extra: [String: String] = [:], base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = HandoffEnvironment.subscription(base)
        env["PATH"] = searchPath.joined(separator: ":")
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        for (key, value) in extra { env[key] = value }
        return env
    }

    static func which(_ tool: String) -> URL? {
        if tool.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: tool) ? URL(fileURLWithPath: tool) : nil }
        return searchPath.map { URL(fileURLWithPath: $0).appendingPathComponent(tool) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func run(_ tool: String, _ args: [String], env: [String: String] = [:], timeout: TimeInterval = 60) async throws -> ShellResult {
        guard let executable = which(tool) else { throw ShellError.notFound(tool) }
        let session = CommandSession(tool: tool)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                session.start(executable: executable, arguments: args, environment: environment(env), timeout: timeout, continuation: continuation)
            }
        } onCancel: { session.cancel() }
    }
}

private final class CommandSession: @unchecked Sendable {
    private let process = OwnedProcess()
    private let lock = NSLock()
    private let tool: String
    private var continuation: CheckedContinuation<ShellResult, Error>?
    private var cancelled = false
    private var done = false
    private var stdout = Data()
    private var stderr = Data()
    private var ended = Set<Int>()
    private var exitStatus: Int32?
    private var overflow = false
    private var timedOut = false
    private var timer: DispatchWorkItem?
    init(tool: String) { self.tool = tool }

    func start(executable: URL, arguments: [String], environment: [String: String], timeout: TimeInterval,
               continuation: CheckedContinuation<ShellResult, Error>) {
        lock.lock()
        self.continuation = continuation
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled { finish(.failure(CancellationError())); return }
        process.output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            self?.receive(data, stream: 1)
        }
        process.errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            self?.receive(data, stream: 2)
        }
        process.onExit = { [weak self] status in
            guard let self else { return }
            self.lock.withLock { self.exitStatus = status }
            self.completeIfReady()
        }
        do {
            try process.start(executable: executable, arguments: arguments, environment: environment, lifetime: timeout)
            try? process.input.fileHandleForWriting.close()
        } catch { finish(.failure(error)); return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.timedOut = true }
            self.process.stop()
            // Even a broken pipe observer cannot hold the caller past this bound.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                self.finish(.failure(ShellError.timedOut(self.tool)))
            }
        }
        lock.withLock { timer = item; if done { item.cancel() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
    }

    private func receive(_ data: Data, stream: Int) {
        let shouldStop = lock.withLock { () -> Bool in
            if data.isEmpty { ended.insert(stream) }
            let limit = stream == 1 ? 1_048_576 : 65_536
            let count = stream == 1 ? stdout.count : stderr.count
            if stream == 1 { stdout.append(data.prefix(max(0, limit - count))) }
            else { stderr.append(data.prefix(max(0, limit - count))) }
            if !overflow && data.count > limit - count { overflow = true; return true }
            return false
        }
        if shouldStop { process.stop() }
        completeIfReady()
    }

    private func completeIfReady() {
        let result: Result<ShellResult, Error>? = lock.withLock {
            guard let status = exitStatus, ended.count == 2 else { return nil }
            if cancelled { return .failure(CancellationError()) }
            if timedOut || process.didTimeOut { return .failure(ShellError.timedOut(tool)) }
            if overflow { return .failure(ShellError.failed("\(tool) exceeded its output limit.")) }
            return .success(ShellResult(status: status, stdout: stdout, stderr: stderr))
        }
        if let result { finish(result) }
    }

    func cancel() {
        lock.withLock { cancelled = true }
        process.stop()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<ShellResult, Error>) {
        let callback: CheckedContinuation<ShellResult, Error>? = lock.withLock {
            guard !done, let continuation else { return nil }
            done = true
            timer?.cancel()
            self.continuation = nil
            return continuation
        }
        guard let callback else { return }
        process.stop()
        process.output.fileHandleForReading.readabilityHandler = nil
        process.errors.fileHandleForReading.readabilityHandler = nil
        callback.resume(with: result)
    }
}

/// Bounded stream framing. An oversized or unterminated line is rejected, never
/// truncated into a different valid message.
final class LineReader: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var exceeded = false
    var overflow: Bool { lock.withLock { exceeded } }
    func feed(_ data: Data) -> [String] {
        lock.withLock {
            guard !exceeded, pending.count + data.count <= 1_048_576 else { exceeded = true; pending.removeAll(); return [] }
            pending.append(data)
            var lines: [String] = []
            while let newline = pending.firstIndex(of: 10) {
                lines.append(String(decoding: pending.prefix(upTo: newline), as: UTF8.self))
                pending.removeSubrange(...newline)
            }
            return lines
        }
    }
}
