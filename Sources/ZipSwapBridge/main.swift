import Foundation
import Darwin
#if SWIFT_PACKAGE
import HandoffCore
#endif

enum Bridge {
    static func value(_ name: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[index + 1]
    }

    static func run() throws {
        let command = CommandLine.arguments.dropFirst().first ?? ""
        let root = value("--root").map { URL(fileURLWithPath: $0) } ?? HandoffPaths.root
        let store = HandoffStore(root: root)
        switch command {
        case "hook":
            // Disabled means no transcript access, writes, child processes, or network.
            guard (try? store.settings().enabled) == true else { print("{}"); return }
            let data = try FileHandle.standardInput.read(upToCount: 1_048_577) ?? Data()
            let projects = value("--projects").map { URL(fileURLWithPath: $0) } ?? HandoffPaths.claudeProjects
            do {
                let result = try ClaudeHandoffHook.handle(data, store: store, projects: projects)
                print(String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self))
            } catch {
                // Exit zero so neither a busy store nor a malformed event stalls Claude.
                print("{}")
            }
        case "rpc-server":
            try serveCodex()
        case "resume":
            guard let id = value("--id"), let record = try store.record(id), record.canOpen,
                  let codex = HandoffCommands.find("codex") else {
                throw HandoffError.unavailable("This handoff is not ready, or Codex CLI is missing. Open ZipSwap > Handoffs.")
            }
            guard chdir(record.cwd) == 0 else { throw HandoffError.unavailable("The project folder no longer exists.") }
            var initial = false
            try store.update(record.id) {
                initial = $0.startedAt == nil
                $0.startedAt = $0.startedAt ?? Date()
                $0.phase = .opened
                $0.detail = "Opened in Codex. Use Open Codex Thread to resume this conversation."
                $0.updatedAt = Date()
            }
            try replaceProcess(codex, arguments: HandoffCommands.resumeArguments(record, initial: initial))
        case "prepare":
            // Diagnostic command uses the same admission and execution path as the app.
            guard let id = value("--id") else { throw HandoffError.invalid("Missing --id.") }
            let helper = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            let projects = value("--projects").map { URL(fileURLWithPath: $0) } ?? HandoffPaths.claudeProjects
            let result = try HandoffEngine(store: store, projects: projects).prepare(id, workspaceStatus: HandoffCommands.workspaceStatus) {
                LocalCodexBackend(rpc: try CodexRPC(executable: helper, arguments: ["rpc-server"],
                                                  environment: HandoffCommands.environment()))
            }
            guard let result else { throw HandoffError.invalid("No handoff found.") }
            print(String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
        default:
            print("ZipSwapBridge: hook | prepare --id UUID | resume --id UUID\nOptional diagnostic flags: --root PATH, --projects PATH")
        }
    }

    static func serveCodex() throws {
        guard let codex = HandoffCommands.find("codex") else { throw HandoffError.unavailable("Codex CLI is missing.") }
        guard setpgid(0, 0) == 0 || getpgrp() == getpid() else {
            throw HandoffError.unavailable("Cannot isolate the handoff helper process.")
        }
        let parent = getppid()
        let server = Process()
        server.executableURL = codex
        server.arguments = HandoffEnvironment.subscriptionArguments + ["app-server", "--stdio"]
        server.environment = HandoffCommands.environment()
        server.standardInput = FileHandle.standardInput
        server.standardOutput = FileHandle.standardOutput
        server.standardError = FileHandle.standardError
        try server.run()
        // The supervisor survives SIGTERM long enough to bound cleanup. The
        // child was spawned first, so it keeps its normal signal disposition.
        signal(SIGTERM, SIG_IGN)
        let deadline = Date().addingTimeInterval(85)
        while server.isRunning && Date() < deadline && getppid() == parent {
            Thread.sleep(forTimeInterval: 0.05)
        }
        // This private group contains only this helper and its Codex children.
        // It is also cleaned if ZipSwap crashes or its stdio client disappears.
        kill(-getpgrp(), SIGTERM)
        Thread.sleep(forTimeInterval: 0.2)
        kill(-getpgrp(), SIGKILL)
    }

    static func replaceProcess(_ executable: URL, arguments: [String]) throws -> Never {
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = HandoffCommands.environment().map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        _ = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { env in
                execve(executable.path, UnsafeMutablePointer(mutating: args.baseAddress!), UnsafeMutablePointer(mutating: env.baseAddress!))
            }
        }
        throw HandoffError.unavailable("Could not start Codex (system error \(errno)).")
    }
}

do { try Bridge.run() }
catch {
    FileHandle.standardError.write(Data("ZipSwap: \(error.localizedDescription)\n".utf8))
    exit(1)
}
