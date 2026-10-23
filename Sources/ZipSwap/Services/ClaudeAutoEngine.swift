import Foundation
import Observation
#if SWIFT_PACKAGE
import HandoffCore
#endif

struct EngineRecovery: Codable {
    var failures: [Date] = []
    var retryAt: Date?
    mutating func failed(at now: Date) -> Date? {
        failures.removeAll { now.timeIntervalSince($0) >= 3600 }
        failures.append(now)
        guard failures.count < 5 else { retryAt = nil; return nil }
        retryAt = now.addingTimeInterval(min(300, pow(2, Double(failures.count)) * 2))
        return retryAt
    }
    mutating func reset() { failures = []; retryAt = nil }
}

/// One engine, owned by the app. Five failed starts per hour is a terminal
/// state until a deliberate retry; changing a threshold cannot reset the budget.
@MainActor @Observable
final class ClaudeAutoEngine {
    struct Event { let kind: String; let payload: [String: Any] }
    private(set) var isRunning = false
    private(set) var status = "Off"
    private(set) var retryAt: Date?
    @ObservationIgnored private var process: OwnedProcess?
    @ObservationIgnored private var retiring: OwnedProcess?
    @ObservationIgnored private var restart: Task<Void, Never>?
    @ObservationIgnored private var threshold: Int?
    @ObservationIgnored private var models: [String] = []
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var recovery: EngineRecovery
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let executableOverride: URL?
    @ObservationIgnored private let supervisor: URL?
    @ObservationIgnored private let processFactory: (() -> OwnedProcess)?
    @ObservationIgnored var onEvent: ((Event) -> Void)?
    private static let stateKey = "claudeEngineRecovery.v1"

    init(executable: URL? = nil, defaults: UserDefaults = .standard, supervisor: URL? = OwnedProcess.bundleSupervisor,
         processFactory: (() -> OwnedProcess)? = nil) {
        self.defaults = defaults; executableOverride = executable
        self.supervisor = supervisor
        self.processFactory = processFactory
        recovery = defaults.data(forKey: Self.stateKey)
            .flatMap { try? JSONDecoder().decode(EngineRecovery.self, from: $0) } ?? EngineRecovery()
    }

    func start(threshold: Int) {
        let currentModels = ClaudeService.watchedModels()
        guard self.threshold != threshold || models != currentModels || (!isRunning && restart == nil) else { return }
        let changing = self.threshold != nil && (self.threshold != threshold || models != currentModels)
        self.threshold = threshold
        models = currentModels
        if changing { stopChild() }
        guard restart == nil else { return }
        if let retry = recovery.retryAt, retry > .now { schedule(at: retry); return }
        recovery.failures.removeAll { Date.now.timeIntervalSince($0) >= 3600 }
        guard recovery.failures.count < 5 else { status = "Stopped after repeated failures. Retry auto-switch."; return }
        launch()
    }

    func retry() {
        recovery.reset(); persist()
        restart?.cancel(); restart = nil
        stopChild()
        if threshold != nil { launch() }
    }

    private func launch() {
        guard let threshold, process == nil else { return }
        if retiring?.isRunning == true { status = "Restarting"; schedule(at: Date().addingTimeInterval(0.4)); return }
        retiring = nil
        guard let executable = executableOverride ?? Shell.which(ClaudeService.tool) else { failed("claude-swap is missing"); return }
        let child = processFactory?() ?? OwnedProcess(supervisor: supervisor)
        let reader = LineReader()
        let token = UUID()
        generation = token
        process = child
        child.output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            let lines = reader.feed(data)
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                if reader.overflow { self.failed("Engine output exceeded its limit"); self.stopChild(); return }
                for line in lines {
                    guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                    let kind = obj["event"] as? String ?? (obj["error"] != nil ? "error" : "unknown")
                    self.onEvent?(Event(kind: kind, payload: obj))
                }
            }
        }
        // Drain stderr without retaining credentials or unbounded diagnostics.
        child.errors.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        child.onExit = { [weak self, weak child] code in
            child?.closePipes()
            Task { @MainActor [weak self, weak child] in
                guard let self else { return }
                if self.retiring === child { self.retiring = nil }
                guard self.generation == token else { return }
                self.process = nil; self.isRunning = false
                self.failed("Engine exited (\(code))")
            }
        }
        do {
            try child.start(executable: executable, arguments: ["auto", "--json", "--threshold", String(threshold)],
                            environment: Shell.environment(), lifetime: nil, terminationGrace: 3)
            try? child.input.fileHandleForWriting.close()
            isRunning = true; status = "Running"; retryAt = nil
        } catch { process = nil; failed(error.localizedDescription) }
    }

    private func failed(_ reason: String) {
        isRunning = false
        let next = recovery.failed(at: .now)
        persist()
        status = next == nil ? "\(reason). Retry auto-switch." : "\(reason). Restart scheduled."
        onEvent?(Event(kind: "engine-health", payload: ["message": status]))
        if let next, threshold != nil { schedule(at: next) }
    }

    private func schedule(at date: Date) {
        restart?.cancel(); retryAt = date
        restart = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            self.restart = nil; self.launch()
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(recovery) { defaults.set(data, forKey: Self.stateKey) }
    }
    private func stopChild() {
        generation = UUID()
        if let process { retiring = process; process.stop() }
        process = nil; isRunning = false
    }
    func stop() {
        threshold = nil; restart?.cancel(); restart = nil; retryAt = nil
        stopChild(); status = "Off"
    }
    func pause() async throws {
        stop()
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while retiring?.isRunning == true && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard retiring?.isRunning != true else { throw ShellError.failed("The previous auto-switch engine could not stop. Retry after it exits.") }
        retiring = nil
    }
}
