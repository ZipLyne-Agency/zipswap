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
        case "supervise":
            try supervise()
        case "watchdog":
            try watchdog()
        case "resume":
            guard let id = value("--id"), let record = try store.record(id), record.canOpen,
                  let codex = HandoffCommands.find("codex") else {
                throw HandoffError.unavailable("This handoff is not ready, or Codex CLI is missing. Open ZipSwap > Handoffs.")
            }
            let helper = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            let status = try HandoffContinuation.run(store: store, id: id, executable: codex,
                                                      environment: HandoffCommands.environment()) {
                let backend = LocalCodexBackend(rpc: try CodexRPC(executable: helper, arguments: ["rpc-server"],
                                                                 environment: HandoffCommands.environment()))
                defer { backend.close() }
                try backend.preflight()
                guard let identity = backend.accountID else { throw HandoffError.unavailable("Codex did not verify its account.") }
                return identity
            }
            exit(status)
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

    /// Exec preserves the real command's PID and exit status. A separate
    /// watchdog remains in its private group if the app loses its timers.
    static func supervise() throws -> Never {
        let ownerOnly = CommandLine.arguments.contains("--owner-only")
        let lifetime = value("--lifetime").flatMap(Double.init)
        let grace = value("--termination-grace").flatMap(Double.init) ?? 0.25
        guard let divider = CommandLine.arguments.firstIndex(of: "--"), divider + 1 < CommandLine.arguments.count,
              ownerOnly ? value("--lifetime") == nil : (lifetime.map { $0.isFinite && $0 > 0 && $0 <= 900 } ?? false),
              grace.isFinite, (0.05...5).contains(grace),
              let rawPID = value("--owner-pid"), let owner = Int32(rawPID), owner > 1,
              let rawStart = value("--owner-start"), let ownerStart = Double(rawStart), ownerStart.isFinite else {
            throw HandoffError.invalid("Invalid supervised command.")
        }
        guard setpgid(0, 0) == 0 || getpgrp() == getpid(),
              let command = ProcessIdentity.capture(getpid()) else { throw HandoffError.unavailable("Cannot isolate the command.") }
        var clock = timespec()
        clock_gettime(CLOCK_MONOTONIC, &clock)
        let deadline = lifetime.map { Double(clock.tv_sec) + Double(clock.tv_nsec) / 1_000_000_000 + $0 }
        let helper = CommandLine.arguments[0]
        let bounds = deadline.map { ["--deadline", String($0)] } ?? ["--owner-only"]
        let monitorArgs = [helper, "watchdog"] + bounds + ["--termination-grace", String(grace), "--owner-pid", String(owner),
                           "--owner-start", String(ownerStart), "--command-pid", String(command.pid), "--command-start", String(command.startTime)]
        let monitorArgv = monitorArgs.map { strdup($0) } + [nil]
        let envp = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { monitorArgv.forEach { free($0) }; envp.forEach { free($0) } }
        var watcher: pid_t = 0
        let code = monitorArgv.withUnsafeBufferPointer { args in envp.withUnsafeBufferPointer { env in
            posix_spawn(&watcher, helper, nil, nil, UnsafeMutablePointer(mutating: args.baseAddress!),
                        UnsafeMutablePointer(mutating: env.baseAddress!))
        }}
        guard code == 0 else { throw HandoffError.unavailable("Cannot start the command watchdog (\(code)).") }
        let arguments = Array(CommandLine.arguments[(divider + 1)...])
        let argv = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        _ = argv.withUnsafeBufferPointer { execv(arguments[0], UnsafeMutablePointer(mutating: $0.baseAddress!)) }
        throw HandoffError.unavailable("Could not execute the supervised command (system error \(errno)).")
    }

    static func watchdog() throws -> Never {
        let ownerOnly = CommandLine.arguments.contains("--owner-only")
        let deadline = value("--deadline").flatMap(Double.init)
        let grace = value("--termination-grace").flatMap(Double.init) ?? 0.25
        guard ownerOnly ? value("--deadline") == nil : (deadline.map { $0.isFinite } ?? false),
              grace.isFinite, (0.05...5).contains(grace),
              let rawOwner = value("--owner-pid"), let owner = Int32(rawOwner), owner > 1,
              let rawOwnerStart = value("--owner-start"), let ownerStart = Double(rawOwnerStart), ownerStart.isFinite,
              let rawCommand = value("--command-pid"), let command = Int32(rawCommand), command > 1,
              let rawCommandStart = value("--command-start"), let commandStart = Double(rawCommandStart), commandStart.isFinite,
              getpgrp() == command else { throw HandoffError.invalid("Invalid watchdog ownership.") }
        signal(SIGTERM, SIG_IGN)
        var clock = timespec()
        clock_gettime(CLOCK_MONOTONIC, &clock)
        let now = Double(clock.tv_sec) + Double(clock.tv_nsec) / 1_000_000_000
        guard deadline.map({ $0 <= now + 900 }) ?? true else { throw HandoffError.invalid("Invalid watchdog deadline.") }
        while ProcessIdentity.matches(pid: command, startTime: commandStart) && ProcessIdentity.matches(pid: owner, startTime: ownerStart) {
            clock_gettime(CLOCK_MONOTONIC, &clock)
            if let deadline, Double(clock.tv_sec) + Double(clock.tv_nsec) / 1_000_000_000 >= deadline { break }
            usleep(50_000)
        }
        kill(-getpgrp(), SIGTERM)
        usleep(useconds_t(grace * 1_000_000))
        kill(-getpgrp(), SIGKILL)
        _exit(127)
    }

    static func serveCodex() throws {
        guard let codex = HandoffCommands.find("codex") else { throw HandoffError.unavailable("Codex CLI is missing.") }
        guard setpgid(0, 0) == 0 || getpgrp() == getpid() else {
            throw HandoffError.unavailable("Cannot isolate the handoff helper process.")
        }
        let parent = getppid()
        let arguments = HandoffEnvironment.subscriptionArguments + ["app-server", "--stdio"]
        let argv = ([codex.path] + arguments).map { strdup($0) } + [nil]
        let envp = HandoffCommands.environment().map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var child: pid_t = 0
        let code = argv.withUnsafeBufferPointer { args in envp.withUnsafeBufferPointer { env in
            posix_spawn(&child, codex.path, nil, nil, UnsafeMutablePointer(mutating: args.baseAddress!),
                        UnsafeMutablePointer(mutating: env.baseAddress!))
        }}
        guard code == 0 else { throw HandoffError.unavailable("Could not launch the Codex server (\(code)).") }
        signal(SIGTERM, SIG_IGN)
        let deadline = ProcessInfo.processInfo.systemUptime + 85
        var status: Int32 = 0
        while waitpid(child, &status, WNOHANG) == 0 && ProcessInfo.processInfo.systemUptime < deadline && getppid() == parent {
            Thread.sleep(forTimeInterval: 0.05)
        }
        kill(-getpgrp(), SIGTERM)
        Thread.sleep(forTimeInterval: 0.2)
        kill(-getpgrp(), SIGKILL)
    }

}

do { try Bridge.run() }
catch {
    FileHandle.standardError.write(Data("ZipSwap: \(error.localizedDescription)\n".utf8))
    exit(1)
}
