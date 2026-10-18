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
    var history: [HistoryItem] = []
    var legacyRunning = false
    var flashUntil: Date?
    var lastClaudeRefresh: Date?
    var lastCodexRefresh: Date?
    var addingCodex = false

    var claudeAutoOn: Bool { didSet { save("claudeAutoOn", claudeAutoOn); applyClaudeAuto() } }
    var claudeThreshold: Double { didSet { save("claudeThreshold", claudeThreshold); scheduleThresholdSync() } }
    var codexAutoOn: Bool { didSet { save("codexAutoOn", codexAutoOn) } }
    var codexThreshold: Double { didSet { save("codexThreshold", codexThreshold) } }
    var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                show("Couldn't change login item: \(error.localizedDescription)")
            }
        }
    }

    @ObservationIgnored private var stored: [CodexStoredAccount] = []
    @ObservationIgnored private let engine = ClaudeAutoEngine()
    @ObservationIgnored private var timers: [Timer] = []
    @ObservationIgnored private var thresholdTask: Task<Void, Never>?
    @ObservationIgnored private var lastCodexAutoSwitch: Date = .distantPast
    @ObservationIgnored private var started = false

    private init() {
        let d = UserDefaults.standard
        d.register(defaults: ["claudeAutoOn": true, "claudeThreshold": 95.0, "codexAutoOn": true, "codexThreshold": 90.0])
        claudeAutoOn = d.bool(forKey: "claudeAutoOn")
        claudeThreshold = d.double(forKey: "claudeThreshold")
        codexAutoOn = d.bool(forKey: "codexAutoOn")
        codexThreshold = d.double(forKey: "codexThreshold")
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func save(_ key: String, _ value: Any) { UserDefaults.standard.set(value, forKey: key) }

    // MARK: lifecycle

    func start() {
        guard !started else { return }
        started = true
        enableLoginItemOnFirstRun()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        engine.onEvent = { [weak self] event in self?.handleEngine(event) }
        stored = CodexService.loadIndex()

        Task {
            legacyRunning = await ClaudeService.legacyMenuBarRunning()
            applyClaudeAuto()
            await refreshAll()
        }

        timers.append(Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshClaude() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshCodex() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let running = await ClaudeService.legacyMenuBarRunning()
                if running != self.legacyRunning { self.legacyRunning = running; self.applyClaudeAuto() }
            }
        })
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.stop() }
        }
    }

    private func enableLoginItemOnFirstRun() {
        let key = "didSetUpLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        launchAtLogin = true
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
        guard !claudeLoading else { return }
        guard ClaudeService.isInstalled else {
            claudeError = "claude-swap isn't installed. Run: uv tool install claude-swap"
            return
        }
        claudeLoading = true
        defer { claudeLoading = false }
        do {
            claude = try await ClaudeService.list()
            claudeError = nil
        } catch {
            claudeError = error.localizedDescription
        }
        lastClaudeRefresh = .now
        rebuildHistory()
        HandoffController.shared.publishUsage()
    }

    func refreshCodex() async {
        guard !codexLoading else { return }
        guard CodexService.isInstalled else {
            codexError = "Codex CLI isn't installed."
            return
        }
        codexLoading = true
        defer { codexLoading = false }
        CodexService.syncLive(into: &stored)
        let liveId = CodexService.liveAccountId()
        let accounts = stored
        let results = await withTaskGroup(of: (Int, Account).self) { group in
            for (index, item) in accounts.enumerated() {
                group.addTask { (index, await CodexService.fetch(item, isActive: item.accountId == liveId)) }
            }
            var out: [(Int, Account)] = []
            for await r in group { out.append(r) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
        // Learn emails and plans the first time we see them.
        var changed = false
        for (i, acc) in results.enumerated() where i < stored.count {
            if stored[i].email.isEmpty, !acc.email.isEmpty {
                stored[i].email = acc.email
                if stored[i].name == "Codex" { stored[i].name = String(acc.email.split(separator: "@").first ?? "Codex") }
                changed = true
            }
        }
        if changed { CodexService.saveIndex(stored) }
        codex = results.map { acc in
            var a = acc
            if let s = stored.first(where: { "codex-\($0.id)" == acc.id }) { a.name = s.name }
            return a
        }
        codexError = nil
        lastCodexRefresh = .now
        rebuildHistory()
        await evaluateCodexAuto()
    }

    private func rebuildHistory() {
        let names = Dictionary(uniqueKeysWithValues: claude.compactMap { a in a.slot.map { (String($0), a.name) } })
        let claudeItems = ClaudeService.history().map {
            HistoryItem(provider: .claude, from: names[$0.from] ?? "slot \($0.from)", to: names[$0.to] ?? "slot \($0.to)", at: $0.at, reason: $0.reason)
        }
        history = (claudeItems + CodexService.loadHistory()).sorted { $0.at > $1.at }.prefix(40).map { $0 }
    }

    // MARK: actions

    func activate(_ account: Account) {
        guard !busy.contains(account.id) else { return }
        busy.insert(account.id)
        Task {
            defer { busy.remove(account.id) }
            do {
                switch account.provider {
                case .claude:
                    guard let slot = account.slot else { return }
                    try await ClaudeService.switchTo(slot: slot)
                    await refreshClaude()
                case .codex:
                    guard let target = storedAccount(for: account) else { return }
                    let from = codex.first(where: \.isActive)?.name ?? "none"
                    try CodexService.switchTo(target, accounts: stored)
                    CodexService.appendHistory(from: from, to: target.name, reason: "manual")
                    await refreshCodex()
                }
                flash()
                show("Now using \(account.title) for \(account.provider.title)")
            } catch {
                show(error.localizedDescription)
            }
        }
    }

    func rename(_ account: Account, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != account.name else { return }
        switch account.provider {
        case .claude:
            guard let slot = account.slot else { return }
            if let i = claude.firstIndex(where: { $0.id == account.id }) { claude[i].name = trimmed }
            Task {
                do { try await ClaudeService.rename(slot: slot, to: trimmed) } catch { show(error.localizedDescription) }
                await refreshClaude()
            }
        case .codex:
            guard !trimmed.isEmpty, let i = stored.firstIndex(where: { "codex-\($0.id)" == account.id }) else { return }
            stored[i].name = trimmed
            CodexService.saveIndex(stored)
            if let j = codex.firstIndex(where: { $0.id == account.id }) { codex[j].name = trimmed }
        }
    }

    func setInRotation(_ account: Account, _ enabled: Bool) {
        guard let slot = account.slot else { return }
        Task {
            do { try await ClaudeService.setInRotation(slot: slot, enabled) } catch { show(error.localizedDescription) }
            await refreshClaude()
        }
    }

    func addClaudeLogin() {
        Task {
            do {
                _ = try await ClaudeService.addCurrentLogin()
                show("Added your current Claude Code login")
                await refreshClaude()
            } catch {
                show(error.localizedDescription)
            }
        }
    }

    func addCodexAccount() {
        guard !addingCodex else { return }
        addingCodex = true
        show("Finish signing in to ChatGPT in your browser")
        Task {
            defer { addingCodex = false }
            do {
                let (account, isNew) = try await CodexService.addAccount(existing: stored)
                if isNew { stored.append(account); CodexService.saveIndex(stored) }
                show(isNew ? "Added \(account.name)" : "\(account.name) was already saved, login refreshed")
                await refreshCodex()
            } catch {
                show(error.localizedDescription)
            }
        }
    }

    func removeCodex(_ account: Account) {
        guard !account.isActive, let target = storedAccount(for: account) else {
            show("Switch away from this account before removing it")
            return
        }
        CodexService.remove(target)
        stored.removeAll { $0.id == target.id }
        CodexService.saveIndex(stored)
        codex.removeAll { $0.id == account.id }
    }

    func useResetCredit(_ account: Account) {
        guard let target = storedAccount(for: account) else { return }
        busy.insert(account.id)
        Task {
            defer { busy.remove(account.id) }
            do {
                let message = try await CodexService.useResetCredit(target, isActive: account.isActive, creditId: account.resetCredits.first?.id)
                show(message)
                await refreshCodex()
            } catch {
                show(error.localizedDescription)
            }
        }
    }

    func retireLegacyMenuBar() {
        Task {
            do {
                try await ClaudeService.retireLegacyMenuBar()
                legacyRunning = await ClaudeService.legacyMenuBarRunning()
                applyClaudeAuto()
                show("Old cswap menu bar retired, ZipSwap runs auto-switch now")
            } catch {
                show(error.localizedDescription)
            }
        }
    }

    private func storedAccount(for account: Account) -> CodexStoredAccount? {
        stored.first { "codex-\($0.id)" == account.id }
    }

    // MARK: auto-switch

    var claudeEngineRunning: Bool { engine.isRunning }

    private func applyClaudeAuto() {
        if claudeAutoOn && !legacyRunning && ClaudeService.isInstalled {
            engine.start(threshold: Int(claudeThreshold))
        } else {
            engine.stop()
        }
    }

    /// Slider drags fire constantly; persist and restart the engine once it settles.
    private func scheduleThresholdSync() {
        thresholdTask?.cancel()
        let value = Int(claudeThreshold)
        thresholdTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            try? await ClaudeService.setThreshold(value)
            applyClaudeAuto()
        }
    }

    private func handleEngine(_ event: ClaudeAutoEngine.Event) {
        switch event.kind {
        case "switch":
            let to = (event.payload["to"] as? [String: Any])?["number"] as? Int
            let name = claude.first { $0.slot == to }?.name ?? "another account"
            notify("Claude switched to \(name)", body: "The active account was nearing its limit.")
            flash()
            Task { await refreshClaude() }
        case "account-quarantined":
            notify("A Claude account needs a fresh login", body: "Run /login in Claude Code, then add it again.")
        default:
            break
        }
    }

    private func evaluateCodexAuto() async {
        guard codexAutoOn, codex.count > 1, let active = codex.first(where: \.isActive) else { return }
        guard active.isBlocked || active.tightest >= codexThreshold else { return }
        guard Date.now.timeIntervalSince(lastCodexAutoSwitch) > 300 else { return }
        let candidates = codex.filter { !$0.isActive && !$0.isBlocked && $0.problem == nil && $0.tightest < codexThreshold - 10 }
        guard let best = candidates.min(by: { $0.tightest < $1.tightest }), let target = storedAccount(for: best) else { return }
        do {
            try CodexService.switchTo(target, accounts: stored)
            lastCodexAutoSwitch = .now
            CodexService.appendHistory(from: active.name, to: best.name, reason: "auto at \(Int(active.tightest))%")
            notify("Codex switched to \(best.name)", body: "\(active.name) reached \(Int(active.tightest))%.")
            flash()
            await refreshCodex()
        } catch {
            show(error.localizedDescription)
        }
    }

    // MARK: feedback

    func show(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(for: .seconds(4))
            if toast == message { toast = nil }
        }
    }

    private func flash() {
        flashUntil = .now.addingTimeInterval(4)
        Task {
            try? await Task.sleep(for: .seconds(4.2))
            flashUntil = flashUntil
        }
    }

    var isFlashing: Bool { (flashUntil ?? .distantPast) > .now }

    private func notify(_ title: String, body: String) {
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
            .filter { !$0.isActive && !$0.isBlocked && !$0.disabled && $0.problem == nil }
            .min { $0.tightest < $1.tightest }
    }

    var activeClaude: Account? { claude.first(where: \.isActive) }
    var activeCodex: Account? { codex.first(where: \.isActive) }
}
