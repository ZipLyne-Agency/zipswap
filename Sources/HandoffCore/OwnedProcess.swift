import Foundation
import Darwin

/// A subprocess in its own process group. Its deadline also covers descendants
/// and blocked pipe writes; cancellation never signals an unrelated session.
public final class OwnedProcess: @unchecked Sendable {
    public let input = Pipe()
    public let output = Pipe()
    public let errors = Pipe()
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var running = false
    private var status: Int32 = -1
    private var stopped = false
    private var deadlineItem: DispatchWorkItem?
    private var expired = false
    private var terminationGrace: TimeInterval = 0.25
    private let supervisor: URL?
    public var onExit: ((Int32) -> Void)?

    public static var bundleSupervisor: URL? {
        let bundle = Bundle.main.bundleURL
        return bundle.pathExtension == "app" ? bundle.appendingPathComponent("Contents/Helpers/ZipSwapBridge") : nil
    }
    public init(supervisor: URL? = OwnedProcess.bundleSupervisor) { self.supervisor = supervisor }
    public var processIdentifier: pid_t { lock.withLock { pid } }
    public var isRunning: Bool { lock.withLock { running } }
    public var terminationStatus: Int32 { lock.withLock { status } }
    public var didTimeOut: Bool { lock.withLock { expired } }

    public func start(executable: URL, arguments: [String], environment: [String: String],
                      lifetime: TimeInterval?, terminationGrace: TimeInterval = 0.25) throws {
        guard lifetime.map({ $0.isFinite && $0 > 0 && $0 <= 900 }) ?? true,
              terminationGrace.isFinite, (0.05...5).contains(terminationGrace) else {
            throw HandoffError.invalid("Invalid subprocess deadline.")
        }
        guard arguments.count <= 256, arguments.reduce(0, { $0 + $1.utf8.count }) <= 2_000_000,
              arguments.allSatisfy({ !$0.contains("\0") }) else { throw HandoffError.invalid("Command arguments exceed their limit.") }
        let useSupervisor = supervisor != nil && executable != supervisor
        guard lifetime != nil || useSupervisor else { throw HandoffError.invalid("An owner-bound service requires its independent watchdog.") }
        self.terminationGrace = terminationGrace
        let command = useSupervisor ? supervisor! : executable
        guard let owner = ProcessIdentity.capture(getpid()) else { throw HandoffError.unavailable("Cannot identify the command owner.") }
        let bounds = lifetime.map { ["--lifetime", String($0)] } ?? ["--owner-only"]
        let commandArguments = useSupervisor ? ["supervise"] + bounds + ["--termination-grace", String(terminationGrace), "--owner-pid", String(owner.pid),
                                               "--owner-start", String(owner.startTime), "--", executable.path] + arguments : arguments
        signal(SIGPIPE, SIG_IGN)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, input.fileHandleForReading.fileDescriptor, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errors.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        let directoryCode: Int32
        if #available(macOS 26, *) { directoryCode = posix_spawn_file_actions_addchdir(&actions, FileManager.default.homeDirectoryForCurrentUser.path) }
        else { directoryCode = posix_spawn_file_actions_addchdir_np(&actions, FileManager.default.homeDirectoryForCurrentUser.path) }
        guard directoryCode == 0 else { throw HandoffError.unavailable("Cannot set the command working directory.") }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        let argv = ([command.path] + commandArguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var child: pid_t = 0
        lock.lock()
        guard pid == 0, !stopped else {
            lock.unlock()
            throw HandoffError.unavailable("The command was cancelled before starting.")
        }
        let code = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { env in
                posix_spawn(&child, command.path, &actions, &attributes,
                            UnsafeMutablePointer(mutating: args.baseAddress!),
                            UnsafeMutablePointer(mutating: env.baseAddress!))
            }
        }
        if code != 0 {
            lock.unlock()
            closePipes()
            throw HandoffError.unavailable("Could not start \(executable.lastPathComponent) (system error \(code)).")
        }
        pid = child
        running = true
        lock.unlock()
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        if let lifetime {
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.expired = true }
            self.stop()
        }
        deadlineItem = item
        DispatchQueue.global().asyncAfter(deadline: .now() + lifetime, execute: item)
        }
        DispatchQueue.global(qos: .utility).async { [self] in
            var waitStatus: Int32 = 0
            while waitpid(child, &waitStatus, 0) == -1 && errno == EINTR {}
            // A successful parent exit must not leave its grandchildren alive.
            kill(-child, SIGKILL)
            let exitStatus: Int32 = waitStatus & 0x7f == 0 ? (waitStatus >> 8) & 0xff : 128 + (waitStatus & 0x7f)
            let callback = lock.withLock { () -> ((Int32) -> Void)? in
                running = false
                status = exitStatus
                deadlineItem?.cancel()
                return onExit
            }
            callback?(exitStatus)
        }
    }

    public func stop() {
        let child = lock.withLock { () -> pid_t in
            guard !stopped else { return 0 }
            stopped = true
            return running ? pid : 0
        }
        guard child > 0 else { return }
        kill(-child, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + terminationGrace) { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                if self.running && self.pid == child { kill(-child, SIGKILL) }
            }
        }
    }

    public func closePipes() {
        input.fileHandleForReading.readabilityHandler = nil
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        for handle in [input.fileHandleForReading, input.fileHandleForWriting,
                       output.fileHandleForReading, output.fileHandleForWriting,
                       errors.fileHandleForReading, errors.fileHandleForWriting] { try? handle.close() }
    }

    deinit { stop(); closePipes() }
}
