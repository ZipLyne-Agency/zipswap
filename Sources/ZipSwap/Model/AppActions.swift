import AppKit
import Foundation

extension AppModel {
    func activate(_ account: Account) {
        if let reason = account.manualSwitchReason() { showError(reason); return }
        Task {
            do {
                try await performSwitch(account, reason: "manual")
                await refreshAll()
                flash(); show("Default \(account.provider.title) login: \(account.title)")
            } catch { showError(error.localizedDescription) }
        }
    }

    /// A success receipt is created only after identity readback in the default
    /// CLI scope. Existing Orca/terminal processes are never claimed as switched.
    func performSwitch(_ account: Account, reason: String) async throws {
        let token = try coordinator.begin(account.provider, accountID: account.id)
        busy.insert(account.id)
        defer {
            busy.remove(account.id)
            coordinator.finish(token)
            if account.provider == .claude { applyClaudeAuto() }
        }
        Diagnostics.record(provider: account.provider, operation: "switch", accountID: account.id, outcome: "started")
        let fromName = (account.provider == .claude ? activeClaude : activeCodex)?.name ?? "none"
        do {
            if account.provider == .claude { try await engine.pause() }
            switch account.provider {
            case .claude:
                guard let slot = account.slot else { throw ShellError.failed("This Claude account has no valid slot.") }
                try await ClaudeService.switchTo(slot: slot)
                claude = claude.map { var value = $0; value.isActive = value.id == account.id; value.activeIdentityVerified = value.isActive; return value }
            case .codex:
                guard let target = storedAccount(for: account) else { throw ShellError.failed("This Codex account is no longer saved.") }
                let activeID = activeCodex?.providerAccountID
                let preflight = await CodexService.fetch(target, isActive: false)
                guard preflight.readingTrusted(at: .now), !preflight.isBlocked else {
                    throw ShellError.failed(preflight.problem ?? "The selected Codex account has no confirmed allowance.")
                }
                try CodexService.switchTo(target, expectedLiveID: activeID)
                try await CodexService.verifyDefaultIdentity(target.accountId)
                lastCodexAutoSwitch = .now
                codexCooldownUntil = ProcessInfo.processInfo.systemUptime + 300
                UserDefaults.standard.set(lastCodexAutoSwitch, forKey: "lastCodexVerifiedSwitch")
                codex = codex.map { var value = $0; value.isActive = value.id == account.id; value.activeIdentityVerified = value.isActive; return value }
            }
            coordinator.finish(token, verified: true)
            Diagnostics.record(provider: account.provider, operation: "switch", accountID: account.id, outcome: "verified")
            do { try SwitchJournal.append(provider: account.provider, from: fromName, to: account.name, reason: reason) }
            catch { showError("The account switched, but its history receipt could not be saved.") }
        } catch {
            Diagnostics.record(provider: account.provider, operation: "switch", accountID: account.id, outcome: "failed")
            // A concurrently changed external login is authoritative. Never
            // restore an older credential to conceal an ambiguous outcome.
            Task { await refreshAll() }
            throw error
        }
    }

    func rename(_ account: Account, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != account.name, trimmed.count <= 100 else { return }
        Task {
            do {
                let token = try coordinator.begin(account.provider, accountID: account.id)
                defer { coordinator.finish(token) }
                switch account.provider {
                case .claude:
                    guard let slot = account.slot else { return }
                    try await ClaudeService.rename(slot: slot, to: trimmed)
                    await refreshClaude()
                case .codex:
                    guard !trimmed.isEmpty, let index = stored.firstIndex(where: { "codex-\($0.id)" == account.id }) else { return }
                    let previous = stored
                    var next = stored; next[index].name = trimmed
                    try CodexService.saveIndex(next, replacing: previous)
                    stored = next
                    if let index = codex.firstIndex(where: { $0.id == account.id }) { codex[index].name = trimmed }
                }
            } catch { showError(error.localizedDescription) }
        }
    }

    func setInRotation(_ account: Account, _ enabled: Bool) {
        guard let slot = account.slot else { return }
        Task {
            do {
                let token = try coordinator.begin(.claude, accountID: account.id)
                defer { coordinator.finish(token) }
                try await ClaudeService.setInRotation(slot: slot, enabled)
                await refreshClaude()
            } catch { showError(error.localizedDescription) }
        }
    }

    func addClaudeLogin() {
        Task {
            do {
                let token = try coordinator.begin(.claude, accountID: "current")
                defer { coordinator.finish(token) }
                _ = try await ClaudeService.addCurrentLogin()
                show("Saved the current default Claude CLI login")
                await refreshClaude()
            } catch { showError(error.localizedDescription) }
        }
    }

    func repairClaudeLogin(_ account: Account) {
        guard account.provider == .claude, let slot = account.slot, loginTask == nil else { return }
        loginTask = Task {
            defer { loginTask = nil }
            do {
                let token = try coordinator.begin(.claude, accountID: account.id)
                busy.insert(account.id)
                defer { busy.remove(account.id); coordinator.finish(token); applyClaudeAuto() }
                try await engine.pause()
                show("Finish signing in to \(account.title) in your browser")
                try await ClaudeLoginRepair.repair(slot: slot, email: account.email)
                show("\(account.title) login repaired")
                await refreshClaude()
            } catch is CancellationError { show("Sign-in cancelled") }
            catch { showError(error.localizedDescription) }
        }
    }

    func addCodexAccount() {
        guard !addingCodex, loginTask == nil else { return }
        addingCodex = true
        show("Finish signing in to ChatGPT in your browser")
        loginTask = Task {
            defer { addingCodex = false; loginTask = nil }
            do {
                let token = try coordinator.begin(.codex, accountID: "new")
                defer { coordinator.finish(token) }
                let (account, isNew) = try await CodexService.addAccount(existing: stored)
                if isNew {
                    let previous = stored
                    var next = stored; next.append(account)
                    try CodexService.saveIndex(next, replacing: previous)
                    stored = next
                }
                show(isNew ? "Added \(account.name)" : "Saved login refreshed")
                await refreshCodex()
            } catch is CancellationError { show("Sign-in cancelled") }
            catch { showError(error.localizedDescription) }
        }
    }
    func cancelLogin() { loginTask?.cancel() }

    func removeCodex(_ account: Account) {
        do {
            guard !account.isActive, let target = storedAccount(for: account) else { throw ShellError.failed("Switch away from this account before removing it.") }
            let token = try coordinator.begin(.codex, accountID: account.id)
            defer { coordinator.finish(token) }
            try CodexService.remove(target)
            stored = try CodexService.loadIndex()
            codex.removeAll { $0.id == account.id }
        } catch { showError(error.localizedDescription); Task { await refreshCodex() } }
    }

    func useResetCredit(_ account: Account) {
        guard !busy.contains(account.id), !coordinator.busy(.codex), account.readingTrusted(at: .now),
              account.resetProblem == nil, let target = storedAccount(for: account),
              let creditID = account.pendingResetID ?? account.resetCredits.first?.id else { return }
        busy.insert(account.id)
        Task {
            defer { busy.remove(account.id) }
            do {
                let token = try coordinator.begin(.codex, accountID: account.id)
                defer { coordinator.finish(token) }
                let message = try await CodexService.useResetCredit(target, isActive: account.isActive, creditId: creditID)
                show(message)
                codexPoll[target.id] = nil
                await refreshCodex()
            } catch {
                showError(error.localizedDescription)
                codexPoll[target.id] = nil
                await refreshCodex()
            }
        }
    }

    func restoreCodexIndex() {
        do {
            let token = try coordinator.begin(.codex, accountID: "index")
            defer { coordinator.finish(token) }
            try CodexService.store.restoreIndexBackup()
            stored = try CodexService.loadIndex()
            codexError = nil
            Task { await refreshCodex() }
        } catch { showError(error.localizedDescription) }
    }

    func recoverSavedLogins() {
        do {
            let token = try coordinator.begin(.codex, accountID: "recovery")
            defer { coordinator.finish(token) }
            let count = try CodexService.store.recoverSavedLogins()
            stored = try CodexService.loadIndex()
            show("Recovered \(count) saved Codex logins")
            Task { await refreshCodex() }
        } catch { showError(error.localizedDescription) }
    }

    func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ZipSwap-diagnostics.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try PrivateFile.write(try Diagnostics.supportData(), to: url); show("Diagnostics saved") }
        catch { showError(error.localizedDescription) }
    }

    func retireLegacyMenuBar() {
        Task {
            do {
                try await ClaudeService.retireLegacyMenuBar()
                legacyRunning = await ClaudeService.legacyMenuBarRunning()
                applyClaudeAuto()
                show("ZipSwap now runs auto-switch")
            } catch { showError(error.localizedDescription) }
        }
    }
    func storedAccount(for account: Account) -> CodexStoredAccount? { stored.first { "codex-\($0.id)" == account.id } }
}
