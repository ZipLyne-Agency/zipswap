import AppKit
import Foundation
import Observation
import ServiceManagement
import UserNotifications

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var claude: [Account] = []
    var codex: [Account] = []
    var claudeError: String?
    var codexError: String?
    var claudeLoading = false
    var codexLoading = false
    var busy: Set<String> = []
    var toast: String?
    var persistentError: String?
    let coordinator = AccountCoordinator()
    var history: [HistoryItem] = []
    var legacyRunning = false
    var flashUntil: Date?
    var lastClaudeRefresh: Date?
    var lastCodexRefresh: Date?
    var addingCodex = false
    var runtimeTools: [RuntimeTool] = []
    var claudeIdentityReady = false

    var claudeAutoOn: Bool { didSet { save("claudeAutoOn", claudeAutoOn); applyClaudeAuto() } }
    private var claudeThresholdValue: Double = 95
    var claudeThreshold: Double {
        get { claudeThresholdValue }
        set {
            let value = RotationSettings.threshold(newValue, fallback: 95)
            guard value != claudeThresholdValue else { return }
            claudeThresholdValue = value; save("claudeThreshold", value); scheduleThresholdSync()
        }
    }
    var codexAutoOn: Bool { didSet { save("codexAutoOn", codexAutoOn) } }
    private var codexThresholdValue: Double = 90
    var codexThreshold: Double {
        get { codexThresholdValue }
        set {
            let value = RotationSettings.threshold(newValue, fallback: 90)
            guard value != codexThresholdValue else { return }
            codexThresholdValue = value; save("codexThreshold", value)
        }
    }
    var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue, !updatingLoginItem else { return }
            updatingLoginItem = true
            defer { updatingLoginItem = false }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                showError("Couldn't change login item: \(error.localizedDescription)")
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if !launchAtLogin && SMAppService.mainApp.status == .requiresApproval {
                showError("Approve ZipSwap in System Settings > Login Items.")
            }
        }
    }

    @ObservationIgnored var stored: [CodexStoredAccount] = []
    @ObservationIgnored let engine = ClaudeAutoEngine()
    @ObservationIgnored private var timers: [Timer] = []
    @ObservationIgnored var thresholdTask: Task<Void, Never>?
    @ObservationIgnored var lastCodexAutoSwitch: Date = UserDefaults.standard.object(forKey: "lastCodexVerifiedSwitch") as? Date ?? .distantPast
    @ObservationIgnored var codexCooldownUntil: TimeInterval = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private var updatingLoginItem = false
    @ObservationIgnored private var pendingClaudeRefresh = false
    @ObservationIgnored var codexPoll: [String: CodexPollState] = [:]
    @ObservationIgnored var loginTask: Task<Void, Never>?

    private init() {
        let d = UserDefaults.standard
        d.register(defaults: ["claudeAutoOn": true, "claudeThreshold": 95.0, "codexAutoOn": true, "codexThreshold": 90.0])
        claudeAutoOn = d.bool(forKey: "claudeAutoOn")
        claudeThresholdValue = RotationSettings.threshold(d.double(forKey: "claudeThreshold"), fallback: 95)
        codexAutoOn = d.bool(forKey: "codexAutoOn")
        codexThresholdValue = RotationSettings.threshold(d.double(forKey: "codexThreshold"), fallback: 90)
        launchAtLogin = SMAppService.mainApp.status == .enabled
        codexCooldownUntil = ProcessInfo.processInfo.systemUptime + RotationSettings.remainingCooldown(lastSwitch: lastCodexAutoSwitch, now: .now)
    }

    private func save(_ key: String, _ value: Any) { UserDefaults.standard.set(value, forKey: key) }

    // MARK: lifecycle

    func start() {
        guard !started else { return }
        started = true
        enableLoginItemOnFirstRun()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        engine.onEvent = { [weak self] event in self?.handleEngine(event) }
        do { stored = try CodexService.loadIndex() }
        catch { codexError = error.localizedDescription; showError(error.localizedDescription) }
        codexPoll = UserDefaults.standard.data(forKey: "codexPoll.v1")
            .flatMap { try? JSONDecoder().decode([String: CodexPollState].self, from: $0) } ?? [:]

        Task {
            await checkTools()
            legacyRunning = await ClaudeService.legacyMenuBarRunning()
            applyClaudeAuto()
            await refreshAll()
        }

        timers.append(Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshClaude() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshCodex() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let running = await ClaudeService.legacyMenuBarRunning()
                self.legacyRunning = running
                self.applyClaudeAuto()
                self.expireReadings()
            }
        })
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.stop() }
        }
    }

    private func enableLoginItemOnFirstRun() {
        let key = "didSetUpLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        launchAtLogin = true
        if launchAtLogin { UserDefaults.standard.set(true, forKey: key) }
    }

    /// Opening the panel refreshes anything older than a short grace period.
    func panelOpened() {
        Task {
            if (lastClaudeRefresh.map { Date.now.timeIntervalSince($0) > 20 } ?? true) { await refreshClaude() }
            if (lastCodexRefresh.map { Date.now.timeIntervalSince($0) > 60 } ?? true) { await refreshCodex() }
        }
    }

    func refreshAll() async {
        async let a: Void = refreshClaude()
        async let b: Void = refreshCodex()
        _ = await (a, b)
    }

    func refreshClaude() async {
        guard !claudeLoading else { pendingClaudeRefresh = true; return }
        guard runtimeTools.first(where: { $0.name == "claude-swap" })?.issue == nil else { return }
        guard ClaudeService.isInstalled else {
            claudeError = "claude-swap isn't installed. Run: uv tool install 'claude-swap==0.28.0'"
            return
        }
        claudeLoading = true
        let generation = coordinator.generation(.claude)
        defer {
            claudeLoading = false
            if pendingClaudeRefresh {
                pendingClaudeRefresh = false
                Task { await refreshClaude() }
            }
        }
        do {
            var fresh = try await ClaudeService.list()
            if let active = fresh.first(where: \.isActive) {
                try await ClaudeService.verifyDefaultIdentity(email: active.email, organizationID: active.organizationID)
                fresh = fresh.map { var value = $0; value.activeIdentityVerified = value.isActive; return value }
            }
            guard coordinator.generation(.claude) == generation else { pendingClaudeRefresh = true; return }
            claudeIdentityReady = fresh.contains(where: { $0.isActive && $0.activeIdentityVerified })
            claude = fresh
            claudeError = nil
            lastClaudeRefresh = .now
            Diagnostics.record(provider: .claude, operation: "refresh", outcome: "verified")
        } catch {
            guard coordinator.generation(.claude) == generation else { pendingClaudeRefresh = true; return }
            claudeError = error.localizedDescription
            claudeIdentityReady = false; engine.stop()
            claude = claude.map { var value = $0; value.stale = true; value.activeIdentityVerified = false; return value }
            Diagnostics.record(provider: .claude, operation: "refresh", outcome: "failed")
        }
        rebuildHistory()
        if !coordinator.busy(.claude) { applyClaudeAuto() }
        HandoffController.shared.publishUsage()
    }

    func refreshCodex() async {
        guard !codexLoading else { return }
        guard runtimeTools.first(where: { $0.name == "codex" })?.issue == nil else { return }
        guard CodexService.isInstalled else {
            codexError = "Codex CLI isn't installed."
            return
        }
        codexLoading = true
        defer { codexLoading = false }
        let generation = coordinator.generation(.codex)
        do { try CodexService.syncLive(into: &stored) }
        catch {
            codexError = error.localizedDescription
            codex = codex.map { var value = $0; value.stale = true; return value }
            Diagnostics.record(provider: .codex, operation: "storage", outcome: "failed")
            return
        }
        let liveId = CodexService.liveAccountId()
        let accounts = CodexPollPlan.select(stored, liveID: liveId, states: codexPoll, now: .now)
        var refreshed: [Account] = []
        for offset in stride(from: 0, to: accounts.count, by: CodexPollPlan.maximumConcurrent) {
            let batch = Array(accounts[offset..<min(offset + CodexPollPlan.maximumConcurrent, accounts.count)])
            let results = await withTaskGroup(of: Account.self) { group in
                for item in batch { group.addTask { await CodexService.fetch(item, isActive: item.accountId == liveId) } }
                var result: [Account] = []
                for await value in group { result.append(value) }
                return result
            }
            refreshed.append(contentsOf: results)
        }
        guard coordinator.generation(.codex) == generation, CodexService.liveAccountId() == liveId else { return }
        var values = Dictionary(codex.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for account in refreshed {
            var reading = account
            if account.problem != nil, let previous = values[account.id], !previous.windows.isEmpty {
                reading.windows = previous.windows; reading.fetchedAt = previous.fetchedAt; reading.stale = true
            }
            var state = codexPoll[account.id.replacingOccurrences(of: "codex-", with: "")] ?? CodexPollState()
            state.record(success: account.problem == nil, now: .now, jitter: Double.random(in: 0...15))
            if account.problem != nil { reading.usageRetryAt = state.retryAt }
            values[account.id] = reading
            codexPoll[account.id.replacingOccurrences(of: "codex-", with: "")] = state
        }
        let ids = Set(stored.map(\.id))
        codexPoll = codexPoll.filter { ids.contains($0.key) }
        if let data = try? JSONEncoder().encode(codexPoll) { UserDefaults.standard.set(data, forKey: "codexPoll.v1") }
        let results = stored.map { item in
            values["codex-\(item.id)"] ?? CodexService.parse(item, isActive: item.accountId == liveId, account: nil, limits: nil, error: "Waiting for a usage refresh")
        }
        // Learn emails and plans the first time we see them.
        var changed = false
        let previous = stored
        for (i, acc) in results.enumerated() where i < stored.count && acc.problem == nil {
            if stored[i].email.isEmpty, !acc.email.isEmpty {
                stored[i].email = acc.email
                if stored[i].name == "Codex" { stored[i].name = String(acc.email.split(separator: "@").first ?? "Codex") }
                changed = true
            }
        }
        if changed {
            do { try CodexService.saveIndex(stored, replacing: previous) }
            catch { stored = previous; codexError = error.localizedDescription; return }
        }
        codex = results.map { acc in
            var a = acc
            a.isActive = a.providerAccountID == liveId
            if let s = stored.first(where: { "codex-\($0.id)" == acc.id }) { a.name = s.name }
            return a
        }
        codexError = codex.contains(where: { $0.problem != nil }) ? "Some Codex readings are unavailable. Select an account for details." : nil
        if refreshed.contains(where: { $0.problem == nil }) { lastCodexRefresh = .now }
        rebuildHistory()
        await evaluateCodexAuto()
    }

    private func rebuildHistory() {
        let names = Dictionary(claude.compactMap { a in a.slot.map { (String($0), a.name) } }, uniquingKeysWith: { first, _ in first })
        do { history = try SwitchJournal.load {
            ClaudeService.history().map {
                HistoryItem(provider: .claude, from: names[$0.from] ?? "slot \($0.from)", to: names[$0.to] ?? "slot \($0.to)", at: $0.at, reason: $0.reason)
            } + CodexService.loadHistory()
        }.sorted { $0.at > $1.at }.prefix(100).map { $0 } }
        catch { showError("Switch history could not be read or saved. Account state was retained.") }
    }

    // MARK: feedback

    func checkTools() async {
        legacyRunning = await ClaudeService.legacyMenuBarRunning()
        runtimeTools = await RuntimeCompatibility.check()
        if let issue = runtimeTools.first(where: { ($0.name == "claude-swap" || $0.name == "claude") && $0.issue != nil })?.issue { claudeError = issue }
        if let issue = runtimeTools.first(where: { $0.name == "codex" })?.issue { codexError = issue }
        if !runtimeTools.contains(where: { ($0.name == "claude-swap" || $0.name == "claude") && $0.issue != nil }) {
            do {
                let token = try coordinator.begin(.claude, accountID: "default-reconciliation")
                defer { coordinator.finish(token) }
                try await engine.pause()
                try await ClaudeService.reconcileDefaultLogin(); claudeIdentityReady = true
            } catch { claudeIdentityReady = false; claudeError = error.localizedDescription }
        } else { claudeIdentityReady = false }
        applyClaudeAuto()
    }

    func showError(_ message: String) {
        persistentError = ContextRedaction.clean(message)
        show(persistentError ?? "Account operation failed")
    }

    func expireReadings() {
        claude = claude.map { value in
            var value = value
            if !value.readingTrusted(at: .now) { value.stale = true }
            return value
        }
        let liveID = CodexService.liveAccountId()
        codex = codex.map { value in
            var value = value
            let selected = value.providerAccountID == liveID
            if value.isActive != selected { value.activeIdentityVerified = false }
            value.isActive = selected
            if !value.readingTrusted(at: .now) { value.stale = true }
            return value
        }
    }

    func show(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(for: .seconds(4))
            if toast == message { toast = nil }
        }
    }

    func flash() {
        flashUntil = .now.addingTimeInterval(4)
        Task {
            try? await Task.sleep(for: .seconds(4.2))
            flashUntil = flashUntil
        }
    }

    var isFlashing: Bool { (flashUntil ?? .distantPast) > .now }

    func notify(_ title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: menu bar title

    /// The account auto-switch would move to next: not active, not limited,
    /// not skipped, with the most room left.
    func upNext(_ provider: Provider) -> Account? {
        let list = provider == .claude ? claude : codex
        return list
            .filter { !$0.isActive && $0.eligibilityReason() == nil }
            .min { $0.tightest < $1.tightest }
    }

    var activeClaude: Account? { claude.first(where: \.isActive) }
    var activeCodex: Account? { codex.first(where: \.isActive) }
}
