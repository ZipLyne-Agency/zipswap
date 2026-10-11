import Foundation

struct ShellResult {
    let status: Int32
    let stdout: Data
    let stderr: Data

    var out: String { String(decoding: stdout, as: UTF8.self) }
    var err: String { String(decoding: stderr, as: UTF8.self) }
}

enum ShellError: LocalizedError {
    case notFound(String)
    case timedOut(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let tool): return "\(tool) isn't installed or isn't on the PATH."
        case .timedOut(let tool): return "\(tool) took too long to answer."
        case .failed(let message): return message
        }
    }
}

/// Runs the command line tools Swap sits on top of. A menu bar app launched by
/// launchd gets a bare PATH, so every lookup goes through an explicit search path.
enum Shell {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static let searchPath: [String] = [
        home.appendingPathComponent(".local/bin").path,
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]

    static func environment(_ extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath.joined(separator: ":")
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        for (key, value) in extra { env[key] = value }
        return env
    }

    static func which(_ tool: String) -> URL? {
        for dir in searchPath {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(tool)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    static func makeProcess(_ tool: String, _ args: [String], env: [String: String]) throws -> Process {
        guard let url = which(tool) else { throw ShellError.notFound(tool) }
        let process = Process()
        process.executableURL = url
        process.arguments = args
        process.environment = environment(env)
        process.currentDirectoryURL = home
        return process
    }

    static func run(
        _ tool: String,
        _ args: [String],
        env: [String: String] = [:],
        timeout: TimeInterval = 60
    ) async throws -> ShellResult {
        let process = try makeProcess(tool, args, env: env)
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let buffer = OutputBuffer()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            buffer.appendOut(handle.availableData)
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            buffer.appendErr(handle.availableData)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let timedOut = Flag()
            process.terminationHandler = { proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                buffer.appendOut(outPipe.fileHandleForReading.readDataToEndOfFile())
                buffer.appendErr(errPipe.fileHandleForReading.readDataToEndOfFile())
                if timedOut.value {
                    continuation.resume(throwing: ShellError.timedOut(tool))
                } else {
                    let (out, err) = buffer.snapshot()
                    continuation.resume(returning: ShellResult(status: proc.terminationStatus, stdout: out, stderr: err))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning {
                    timedOut.value = true
                    process.terminate()
                }
            }
        }
    }
}

final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func appendOut(_ data: Data) { lock.lock(); out.append(data); lock.unlock() }
    func appendErr(_ data: Data) { lock.lock(); err.append(data); lock.unlock() }
    func snapshot() -> (Data, Data) { lock.lock(); defer { lock.unlock() }; return (out, err) }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// Splits a byte stream into newline-terminated lines.
final class LineReader: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    func feed(_ data: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        pending.append(data)
        var lines: [String] = []
        while let range = pending.firstRange(of: Data([0x0A])) {
            let line = pending.subdata(in: pending.startIndex..<range.lowerBound)
            pending.removeSubrange(pending.startIndex..<range.upperBound)
            lines.append(String(decoding: line, as: UTF8.self))
        }
        return lines
    }
}
