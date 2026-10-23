import Foundation
#if SWIFT_PACKAGE
import HandoffCore
#endif

/// Usage and handoff share the same bounded, sequential protocol client.
/// No account read starts a model turn. Requests wait for initialize to succeed.
enum CodexAppServer {
    struct Request { let method: String; let params: [String: Any]? }

    static func call(home: URL?, _ requests: [Request], timeout: TimeInterval = 25) async throws -> [[String: Any]] {
        guard requests.count <= 8 else { throw ShellError.failed("Too many Codex requests in one refresh.") }
        guard let executable = Shell.which("codex") else { throw ShellError.notFound("codex") }
        let cancellation = RPCCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Task.detached(priority: .utility) {
                let env = home.map { Shell.environment(["CODEX_HOME": $0.path]) } ?? Shell.environment()
                let rpc = try CodexRPC(executable: executable,
                                       arguments: HandoffEnvironment.subscriptionArguments + ["app-server", "--stdio"],
                                       environment: env, lifetime: timeout, onStart: { client in
                                           if !cancellation.attach(client) { client.cancel() }
                                       })
                guard cancellation.attach(rpc) else { rpc.close(); throw CancellationError() }
                defer { cancellation.detach(); rpc.close() }
                return try requests.map { ["result": try rpc.call($0.method, params: $0.params ?? [:])] }
            }.value
        } onCancel: { cancellation.cancel() }
    }
}

private final class RPCCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var rpc: CodexRPC?
    private var cancelled = false
    func attach(_ rpc: CodexRPC) -> Bool { lock.withLock { if cancelled { return false }; self.rpc = rpc; return true } }
    func detach() { lock.withLock { rpc = nil } }
    func cancel() {
        let client = lock.withLock { () -> CodexRPC? in cancelled = true; return rpc }
        client?.cancel()
    }
}
