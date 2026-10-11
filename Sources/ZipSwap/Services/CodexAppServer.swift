import Foundation

/// One short-lived `codex app-server` session over stdio JSON-RPC.
/// `home` picks the account: nil means the live `~/.codex`, otherwise a stored
/// account directory passed as CODEX_HOME.
enum CodexAppServer {
    struct Request {
        let method: String
        let params: [String: Any]?
    }

    static func call(home: URL?, _ requests: [Request], timeout: TimeInterval = 25) async throws -> [[String: Any]] {
        var env: [String: String] = [:]
        if let home { env["CODEX_HOME"] = home.path }
        let process = try Shell.makeProcess("codex", ["app-server"], env: env)
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let reader = LineReader()
        let state = SessionState(expected: requests.count)

        return try await withCheckedThrowingContinuation { continuation in
            state.onFinish = { result in
                output.fileHandleForReading.readabilityHandler = nil
                if process.isRunning { process.terminate() }
                continuation.resume(with: result)
            }
            output.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    state.finish(.failure(ShellError.failed("Codex closed the connection.")))
                    return
                }
                for line in reader.feed(data) {
                    guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          let id = obj["id"] as? Int, id >= 100 else { continue }
                    state.receive(index: id - 100, message: obj)
                }
            }
            do {
                try process.run()
            } catch {
                state.finish(.failure(error))
                return
            }

            var lines: [[String: Any]] = [
                ["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "zipswap", "title": "ZipSwap", "version": "1.0"]]],
                ["method": "initialized"],
            ]
            for (index, request) in requests.enumerated() {
                var msg: [String: Any] = ["id": 100 + index, "method": request.method]
                if let params = request.params { msg["params"] = params }
                lines.append(msg)
            }
            let handle = input.fileHandleForWriting
            for line in lines {
                if let data = try? JSONSerialization.data(withJSONObject: line) {
                    handle.write(data)
                    handle.write(Data([0x0A]))
                }
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                state.finish(.failure(ShellError.timedOut("Codex")))
            }
        }
    }
}

private final class SessionState: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Int: [String: Any]] = [:]
    private var done = false
    private let expected: Int
    var onFinish: ((Result<[[String: Any]], Error>) -> Void)?

    init(expected: Int) { self.expected = expected }

    func receive(index: Int, message: [String: Any]) {
        lock.lock()
        results[index] = message
        let complete = results.count >= expected
        let ordered = (0..<expected).map { results[$0] ?? [:] }
        lock.unlock()
        if complete { finish(.success(ordered)) }
    }

    func finish(_ result: Result<[[String: Any]], Error>) {
        lock.lock()
        if done { lock.unlock(); return }
        done = true
        let callback = onFinish
        lock.unlock()
        callback?(result)
    }
}
