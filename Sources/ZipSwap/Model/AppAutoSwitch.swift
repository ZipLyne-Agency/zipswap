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
        switch event.kind {
        case "switch":
            let to = (event.payload["to"] as? [String: Any])?["number"] as? Int
            let from = activeClaude?.name ?? "none"
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
        default:
            break
        }
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
