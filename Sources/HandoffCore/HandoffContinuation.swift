import Foundation
import Darwin

public enum HandoffContinuation {
    /// The process inherits the terminal's foreground group and stdio. Only
    /// preparation/usage helpers use private groups and finite lifetimes.
    public static func run(store: HandoffStore, id: String, executable: URL,
                           environment: [String: String], verifyAccount: () throws -> String) throws -> Int32 {
        let lease = try HandoffConsumerLease(root: store.root, recordID: id)
        defer { withExtendedLifetime(lease) {} }
        guard let record = try store.record(id), record.canOpen else { throw HandoffError.unavailable("This handoff is not ready.") }
        if let pid = record.consumerPID, let start = record.consumerStartTime,
           ProcessIdentity.matches(pid: pid, startTime: start) {
            throw HandoffError.unavailable("The previous Codex CLI is still running. Return to that terminal.")
        }
        let initial = record.startedAt == nil && record.continuationAttemptedAt == nil
        if initial && (record.codexAccountID?.isEmpty ?? true) {
            throw HandoffError.unavailable("This older handoff has no verified Codex account. Prepare a new handoff before continuing automatically.")
        }
        let actual = try verifyAccount()
        if let expected = record.codexAccountID, !expected.isEmpty, actual != expected {
            throw HandoffError.unavailable("The Codex account changed since preparation. Select the original account before continuing this thread.")
        }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: record.cwd, isDirectory: &directory), directory.boolValue else {
            throw HandoffError.unavailable("The project folder no longer exists.")
        }
        let arguments = try HandoffCommands.resumeArguments(record, initial: initial)
        try store.update(id) {
            $0.phase = .opening; $0.continuationAttemptedAt = Date(); $0.updatedAt = Date()
            $0.detail = "Starting the Codex CLI. No successful start has been recorded yet."
        }
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var child: pid_t = 0
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        if #available(macOS 26, *) { posix_spawn_file_actions_addchdir(&actions, record.cwd) }
        else { posix_spawn_file_actions_addchdir_np(&actions, record.cwd) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        defer { posix_spawnattr_destroy(&attributes) }
        let code = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { env in
                posix_spawn(&child, executable.path, &actions, &attributes,
                            UnsafeMutablePointer(mutating: args.baseAddress!), UnsafeMutablePointer(mutating: env.baseAddress!))
            }
        }
        guard code == 0 else {
            try store.update(id) {
                $0.phase = .ready; $0.consumerPID = nil; $0.consumerStartTime = nil; $0.continuationAttemptedAt = record.continuationAttemptedAt
                $0.detail = "Codex could not launch (system error \(code)). No continuation was started; try opening it again."
                $0.updatedAt = Date()
            }
            throw HandoffError.unavailable("Could not start Codex (system error \(code)).")
        }
        let terminal = isatty(STDIN_FILENO) != 0
        let foreground = terminal ? tcgetpgrp(STDIN_FILENO) : 0
        let oldSignal = signal(SIGTTOU, SIG_IGN)
        if terminal { _ = tcsetpgrp(STDIN_FILENO, child); kill(-child, SIGCONT) }
        defer {
            if terminal && foreground > 0 { _ = tcsetpgrp(STDIN_FILENO, foreground) }
            signal(SIGTTOU, oldSignal)
        }
        do {
            try store.update(id) {
                $0.phase = .running; $0.consumerPID = child; $0.consumerStartTime = ProcessIdentity.capture(child)?.startTime
                $0.startedAt = $0.startedAt ?? Date(); $0.updatedAt = Date()
                $0.detail = "The saved Codex thread is running in Terminal."
            }
        } catch {
            kill(-child, SIGTERM)
            Thread.sleep(forTimeInterval: 0.1)
            kill(-child, SIGKILL)
            var status: Int32 = 0
            _ = waitpid(child, &status, 0)
            throw error
        }
        var status: Int32 = 0
        while waitpid(child, &status, 0) == -1 && errno == EINTR {}
        kill(-child, SIGKILL)
        let exitCode: Int32 = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        try store.update(id) {
            $0.consumerPID = nil; $0.consumerStartTime = nil; $0.phase = exitCode == 0 ? .opened : .failed; $0.updatedAt = Date()
            $0.detail = exitCode == 0 ? "Codex CLI closed. Open the saved thread to resume it."
                : "Codex CLI exited (\(exitCode)). Its initial prompt will not be sent again because its outcome may be ambiguous."
        }
        return exitCode
    }
}
