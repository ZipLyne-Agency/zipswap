import AppKit
import Foundation
import Observation
import UserNotifications

@MainActor
@Observable
final class HandoffController {
    static let shared = HandoffController()
    private(set) var settings = HandoffSettings()
    private(set) var records: [HandoffRecord] = []
    private(set) var integrationInstalled = false
    private(set) var installing = false
    private(set) var preparing = false
    var message: String?

    @ObservationIgnored private let store: HandoffStore
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var opening = Set<String>()
    @ObservationIgnored private var started = false

    init(store: HandoffStore = HandoffStore()) {
        self.store = store
        do { settings = try store.settings(); records = try store.records() }
        catch { message = "Handoff state could not be read. Automatic handoff remains off." }
    }

    func start() {
        guard !started else { return }
        started = true
        configureTimer()
    }

    func inspectIntegration() {
        Task { integrationInstalled = await HandoffIntegration.installed() }
    }

    func installIntegration() {
        guard !installing, !settings.enabled else { return }
        installing = true
        Task {
            defer { installing = false }
            do {
                try await HandoffIntegration.install()
                integrationInstalled = true
                message = "Integration installed. Restart or resume Claude Code to load it, then enable handoff here."
            } catch { message = error.localizedDescription }
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard !enabled || integrationInstalled else {
            message = "Install the Claude integration first."
            return
        }
        var next = settings
        next.enabled = enabled
        next.enabledAt = enabled ? Date() : nil
        do {
            try store.saveSettings(next)
            settings = next
            configureTimer()
            if enabled {
                publishUsage()
                message = "Enabled for new rate-limit events. Keep ZipSwap running."
            } else { message = "Automatic handoff is off. Saved Codex threads can still be opened." }
        } catch { message = error.localizedDescription }
    }

    func setAutomaticallyOpen(_ enabled: Bool) {
        var next = settings
        next.automaticallyOpen = enabled
        do { try store.saveSettings(next); settings = next }
        catch { message = error.localizedDescription }
    }

    func publishUsage() {
        guard settings.enabled else { return }
        let model = AppModel.shared
        let accounts = model.claude.map {
            HandoffAccountUsage(active: $0.isActive, disabled: $0.disabled, percent: $0.windows.isEmpty ? nil : $0.tightest,
                                blocked: $0.isBlocked, healthy: $0.problem == nil, fetchedAt: $0.fetchedAt)
        }
        let usage = HandoffUsagePolicy.evaluate(accounts, rotationEnabled: model.claudeAutoOn, now: Date())
        do { try store.saveUsage(usage) } catch { message = error.localizedDescription }
    }

    private func configureTimer() {
        timer?.invalidate()
        timer = nil
        guard settings.enabled else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        Task { await tick() }
    }

    func refreshRecords() {
        do { records = try store.records() } catch { message = error.localizedDescription }
    }

    private func tick() async {
        guard settings.enabled, !preparing else { return }
        do {
            try store.recoverInterrupted(now: Date())
            refreshRecords()
            if settings.automaticallyOpen, let enabledAt = settings.enabledAt,
               let pending = records.first(where: {
                   $0.phase == .ready && $0.canOpen && !$0.autoOpenAttempted && $0.eventDate >= enabledAt
                       && Date().timeIntervalSince($0.updatedAt) < 300
               }) {
                try store.update(pending.id) { $0.autoOpenAttempted = true }
                await openThread(pending)
                return
            }
            guard let queued = records.first(where: { $0.phase == .queued }) else { return }
            preparing = true
            defer { preparing = false }
            await AppModel.shared.refreshClaude()
            publishUsage()
            guard settings.enabled else { return }
            guard let helper = HandoffIntegration.helper else {
                throw HandoffError.unavailable("The handoff helper is missing from this build.")
            }
            let store = store
            let result = try await Task.detached(priority: .utility) {
                try HandoffEngine(store: store).prepare(queued.id, workspaceStatus: HandoffCommands.workspaceStatus) {
                    LocalCodexBackend(rpc: try CodexRPC(executable: helper, arguments: ["rpc-server"],
                                                      environment: HandoffCommands.environment()))
                }
            }.value
            refreshRecords()
            if let result, result.canOpen {
                notify(result)
                if settings.enabled && settings.automaticallyOpen && !result.autoOpenAttempted {
                    try store.update(result.id) { $0.autoOpenAttempted = true }
                    await openThread(result)
                }
            }
        } catch { message = error.localizedDescription }
    }

    func openThread(_ record: HandoffRecord) async {
        guard record.canOpen, !opening.contains(record.id) else { return }
        opening.insert(record.id)
        defer { opening.remove(record.id); refreshRecords() }
        do {
            guard let helper = HandoffIntegration.helper,
                  let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                throw HandoffError.unavailable("Terminal or the handoff helper is missing. Use Copy Resume Command.")
            }
            let data = try HandoffCommands.terminalScript(helper: helper, root: store.root, recordID: record.id)
            let script = try store.writePrivate(data, name: "resume-\(record.id).command", executable: true)
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            try await NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: config)
            message = "Opening the saved Codex thread in Terminal."
        } catch {
            message = error.localizedDescription
            try? store.update(record.id) { $0.detail = "Thread saved. Terminal could not open it. Use Open Codex Thread or Copy Resume Command." }
        }
    }

    func copyResumeCommand(_ record: HandoffRecord) {
        do {
            guard let codex = HandoffCommands.find("codex") else { throw HandoffError.unavailable("Codex CLI is missing.") }
            let command = try HandoffCommands.resumeCommand(record, codex: codex)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            message = "Resume command copied. Paste it into your preferred terminal."
        } catch { message = error.localizedDescription }
    }

    private func notify(_ record: HandoffRecord) {
        let content = UNMutableNotificationContent()
        content.title = "Your Codex thread is ready"
        content.body = "\(record.title): open ZipSwap > Handoffs to continue or reopen the thread."
        content.userInfo = ["handoffID": record.id]
        let request = UNNotificationRequest(identifier: "handoff-\(record.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
