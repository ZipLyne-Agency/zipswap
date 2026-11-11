import Foundation

extension AppModel {
    // MARK: auto-switch

    var claudeEngineRunning: Bool { engine.isRunning }
    var claudeEngineStatus: String { legacyRunning ? "Paused while cswap runs" : engine.status }

    func applyClaudeAuto() {
        if claudeAutoOn && claudeIdentityReady && !legacyRunning && ClaudeService.isInstalled && !coordinator.busy(.claude)
            && runtimeTools.first(where: { $0.name == "claude-swap" })?.issue == nil {
            engine.start(threshold: Int(claudeThreshold))
        } else {
            engine.stop()
        }
    }

    /// Slider drags fire constantly; persist and restart the engine once it settles.
    func scheduleThresholdSync() {
        thresholdTask?.cancel()
        let value = Int(claudeThreshold)
        thresholdTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            do { try await ClaudeService.setThreshold(value); applyClaudeAuto() }
            catch { showError(error.localizedDescription) }
        }
    }

    func handleEngine(_ event: ClaudeAutoEngine.Event) {
        if ["poll", "no-switch", "switch"].contains(event.kind) { claudeEngineHeardAt = .now; engineStopNotified = false }
        switch event.kind {
        case "poll":
            break
        case "no-switch":
            claudeEngineDecision = Self.engineReason(event.payload["reason"] as? String, detail: event.payload["detail"] as? String)
        case "switch":
            let to = (event.payload["to"] as? [String: Any])?["number"] as? Int
            let from = activeClaude?.name ?? "none"
            lastClaudeSwitchAt = .now
            claudeEngineDecision = "Switched accounts"
            Task {
                await refreshClaude()
                guard let active = activeClaude, active.slot == to else { return }
                do {
                    try await ClaudeService.verifyDefaultIdentity(email: active.email, organizationID: active.organizationID)
                    notify("Claude switched to \(active.title)", body: "The default Claude CLI login was verified.")
                    Diagnostics.record(provider: .claude, operation: "switch", accountID: active.id, outcome: "verified")
                    try SwitchJournal.append(provider: .claude, from: from, to: active.name, reason: "auto")
                    flash()
                } catch { showError(error.localizedDescription) }
            }
        case "account-quarantined":
            notify("A Claude account needs a fresh login", body: "Select the account in ZipSwap and choose Repair login.")
        case "error", "engine-health":
            Diagnostics.record(provider: .claude, operation: "engine", outcome: "failed")
            notifyIfEngineStopped()
        default:
            break
        }
    }

    /// The engine's own reason, in the panel's words.
    static func engineReason(_ reason: String?, detail: String?) -> String {
        let text: String
        switch reason {
        case "below-threshold": text = "Below the line"
        case "cooldown": text = "Waiting after the last switch"
        case "no-candidates": text = "No other account to switch to"
        case "no-viable-target": text = "No other account has room"
        case "active-usage-unknown": text = "Waiting for a usage reading"
        case "active-idle": text = "Claude Code is idle"
        case "no-active-account", "unmanaged-active-account": text = "The default login isn't a saved account"
        case "active-api-key": text = "The active account uses an API key"
        default: text = reason.map { $0.replacingOccurrences(of: "-", with: " ").capitalized } ?? "No switch"
        }
        return detail.map { "\(text) · \($0)" } ?? text
    }

    /// A stopped engine is never silent: one notification per stop. The safety
    /// net keeps switching an account that has run out while it is down.
    func notifyIfEngineStopped() {
        guard claudeAutoOn, !engine.isRunning, engine.retryAt == nil, !engineStopNotified,
              engine.status.contains("Retry") else { return }
        engineStopNotified = true
        notify("Claude auto-switch stopped", body: "Open ZipSwap Settings and choose Retry Auto-Switch. Used-up accounts are still switched.")
    }

    /// Restarts an engine that is running but has said nothing for 15 minutes;
    /// it reports every tick, and its longest sleep is 10 minutes.
    func checkEngineHealth() {
        if engine.restartIfSilent(after: 900) {
            claudeEngineDecision = "Restarted after it stopped responding"
            Diagnostics.record(provider: .claude, operation: "engine", outcome: "retry")
        }
        notifyIfEngineStopped()
    }

    // MARK: safety net

    /// Returns false when it couldn't decide yet (busy, unverified, or just after a switch).
    @discardableResult
    func evaluateClaudeSafetyNet(limitReportedAt: Date? = nil) async -> Bool {
        // Only on a successful refresh: a failed one marks every reading stale,
        // which would read as a blind active account with nowhere to go.
        guard claudeAutoOn, !legacyRunning, !safetyNetRunning, !coordinator.busy(.claude), claudeIdentityReady,
              claudeRefreshFailures == 0, let active = activeClaude, active.activeIdentityVerified else { return false }
        let now = Date()
        // Let a new account's first reading settle, and don't hammer a failing switch.
        if let last = lastClaudeSwitchAt, now.timeIntervalSince(last) < 120 { return false }
        if let failed = safetyNetFailedAt, now.timeIntervalSince(failed) < 180 { return false }
        if active.isBlocked && active.readingTrusted(at: now) {
            if claudeBlockedSince?.id != active.id { claudeBlockedSince = (active.id, now) }
        } else { claudeBlockedSince = nil }
        claudeLeftBySafetyNet = claudeLeftBySafetyNet.filter { now.timeIntervalSince($0.value) < 7 * 86_400 }
        let input = ClaudeSafetyNet.Input(accounts: claude, line: claudeThreshold, engineRunning: engine.isRunning,
                                          limitReportedAt: limitReportedAt, blockedSince: claudeBlockedSince?.at,
                                          left: claudeLeftBySafetyNet, now: now)
        switch ClaudeSafetyNet.decide(input) {
        case .stay:
            claudeNoTargetKey = nil
        case .noTarget(let trigger):
            let why = ClaudeSafetyNet.explanation(trigger, from: active.title)
            claudeSafetyNote = why + " No other account has room."
            let key = "\(active.id)|\(trigger.rawValue)"
            guard claudeNoTargetKey != key else { return true }
            claudeNoTargetKey = key
            notify("No Claude account to switch to", body: why + " Every other account is used up, skipped or unreadable.")
            Diagnostics.record(provider: .claude, operation: "safety-net", accountID: active.id, outcome: "cancelled")
        case .switchTo(let id, let trigger):
            guard let target = claude.first(where: { $0.id == id }) else { return true }
            safetyNetRunning = true
            defer { safetyNetRunning = false }
            let why = ClaudeSafetyNet.explanation(trigger, from: active.title)
            do {
                try await performSwitch(target, reason: "safety net", expectingActive: active)
                claudeLeftBySafetyNet[active.id] = now
                claudeNoTargetKey = nil
                claudeSafetyNote = why + " Switched to \(target.title)."
                notify("Claude switched to \(target.title)", body: why)
                Diagnostics.record(provider: .claude, operation: "safety-net", accountID: target.id, outcome: "verified")
                flash()
            } catch {
                safetyNetFailedAt = now
                Diagnostics.record(provider: .claude, operation: "safety-net", accountID: target.id, outcome: "failed")
                claudeSafetyNote = why + " The switch failed: \(error.localizedDescription)"
            }
        }
        return true
    }

    /// Claude Code's own report that the default login hit its limit.
    /// A report stays pending until it is decided on or five minutes old.
    func checkLimitSignal() async {
        guard limitSwitchOn, let signal = ClaudeLimitSignals.latest(HandoffStore()), signal.at > lastLimitSignal else { return }
        func handled() {
            lastLimitSignal = signal.at
            UserDefaults.standard.set(signal.at, forKey: "lastClaudeLimitSignal")
        }
        // Old reports, and reports from sessions still holding the previous
        // login right after a switch, say nothing about the active account.
        if Date().timeIntervalSince(signal.at) > 300 { handled(); return }
        if let last = lastClaudeSwitchAt, signal.at < last.addingTimeInterval(60) { handled(); return }
        if lastClaudeRefresh.map({ Date().timeIntervalSince($0) > 20 }) ?? true { await refreshClaude() }
        if await evaluateClaudeSafetyNet(limitReportedAt: signal.at) { handled() }
    }

    func setLimitSwitch(_ enabled: Bool) {
        do {
            try ClaudeLimitSignals.setEnabled(enabled, store: HandoffStore())
            limitSwitchOn = enabled
            if enabled {
                // Reports written before switching it on are not acted on.
                lastLimitSignal = .now
                UserDefaults.standard.set(lastLimitSignal, forKey: "lastClaudeLimitSignal")
            }
        } catch { showError(error.localizedDescription) }
    }

    func evaluateCodexAuto() async {
        guard codexAutoOn, !coordinator.busy(.codex), codex.count > 1, let active = codex.first(where: \.isActive),
              active.readingTrusted(at: .now), active.activeIdentityVerified else { return }
        guard active.isBlocked || active.tightest >= codexThreshold else { return }
        guard ProcessInfo.processInfo.systemUptime >= codexCooldownUntil else { return }
        let candidates = codex.filter { !$0.isActive && $0.eligibilityReason() == nil && $0.tightest < codexThreshold - 10 }
        guard let best = candidates.min(by: { $0.tightest < $1.tightest }) else { return }
        do {
            try await performSwitch(best, reason: "auto at \(Format.pct(active.tightest))")
            notify("Codex switched to \(best.title)", body: "The default Codex CLI login was verified.")
            flash()
            await refreshCodex()
        } catch {
            showError(error.localizedDescription)
        }
    }

}
