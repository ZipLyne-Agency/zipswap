import AppKit
import SwiftUI

/// The menu bar panel: one quiet table per provider. Every row shows the three
/// limits that matter, the active account and the one auto-switch picks next.
struct PanelView: View {
    let model = AppModel.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
            VStack(spacing: 18) {
                ProviderTable(provider: .claude)
                ProviderTable(provider: .codex)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
            }
            // MenuBarExtra can propose zero height when measuring its panel.
            // A maximum alone lets ScrollView collapse and hide every account.
            .frame(height: min(540, max(180, (NSScreen.main?.visibleFrame.height ?? 800) - 160)))
            if let error = model.persistentError {
                HStack {
                    Text(error).font(.system(size: 12)).foregroundStyle(Theme.amber).textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { model.persistentError = nil }.controlSize(.small)
                }.padding(.horizontal, 16).padding(.bottom, 10)
            }
            footer
        }
        .frame(width: 720)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .onAppear { model.panelOpened() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            AppMark(size: 22)
            Text("ZipSwap").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
            Text("Israel time").font(.system(size: 10.5)).foregroundStyle(Theme.faint)
            if let toast = model.toast {
                Text(toast)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .transition(.opacity)
            }
            Spacer()
            if model.loginTask != nil { Button("Cancel sign-in") { model.cancelLogin() }.controlSize(.small) }
            Menu {
                Button("Add Current Claude Code Login") { model.addClaudeLogin() }
                Button(model.addingCodex ? "Waiting for ChatGPT Sign-In…" : "Add Codex Account…") { model.addCodexAccount() }
                    .disabled(model.addingCodex)
            } label: {
                Image(systemName: "plus").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted)
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add Account")
            .accessibilityLabel("Add account")
            .disabled(model.coordinator.busy(.claude) || model.coordinator.busy(.codex))
            IconButton(systemName: "arrow.clockwise", help: "Refresh", spinning: model.claudeLoading || model.codexLoading) {
                Task { await model.refreshAll() }
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 12)
        .animation(.easeOut(duration: 0.2), value: model.toast)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button { Dashboard.shared.show() } label: {
                HStack(spacing: 7) {
                    Circle().fill(autoOn ? Theme.mint : Theme.faint).frame(width: 7, height: 7)
                    Text(autoSummary).font(.system(size: 12)).foregroundStyle(Theme.text2)
                }
            }
            .buttonStyle(.plain)
            .help("Change Auto-Switch in Settings")
            Spacer()
            FooterButton(title: "Handoffs", shortcut: "") { Dashboard.shared.showHandoffs() }
            FooterButton(title: "Settings", shortcut: "⌘,") { Dashboard.shared.show() }
                .keyboardShortcut(",")
            Menu {
                Button("Check for Updates…") { Updater.shared.checkForUpdates() }
                Toggle("Open at Login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                Divider()
                Button("Quit ZipSwap") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.muted)
                    .frame(width: 30, height: 30)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var autoOn: Bool { model.claudeAutoOn || model.codexAutoOn }

    private var autoSummary: String {
        var parts: [String] = []
        if model.claudeAutoOn { parts.append("Claude at \(Format.pct(model.claudeThreshold))") }
        if model.codexAutoOn { parts.append("Codex at \(Format.pct(model.codexThreshold))") }
        return parts.isEmpty ? "Auto-Switch Off" : "Auto-Switch On · " + parts.joined(separator: " · ")
    }
}

// MARK: table

private enum Col {
    static let metric: CGFloat = 108
    static let action: CGFloat = 70
}

struct ProviderTable: View {
    let provider: Provider
    let model = AppModel.shared

    private var accounts: [Account] {
        let list = provider == .claude ? model.claude : model.codex
        let next = model.upNext(provider)?.id
        // Active first, then up next, then the rest in their usual order.
        return list.sorted { rank($0, next) < rank($1, next) }
    }

    private func rank(_ a: Account, _ next: String?) -> Int { a.isActive ? 0 : a.id == next ? 1 : 2 }

    private var columns: [String] {
        let watched = ClaudeService.watchedModels().map { $0.capitalized }.joined(separator: ", ")
        return provider == .claude ? ["5-Hour", "Weekly", watched.isEmpty ? "Model" : watched] : ["5-Hour", "Weekly", "Free Resets"]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(provider == .claude ? Theme.claudeMark : Theme.codexMark).frame(width: 8, height: 8)
                    Text(provider.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                }
                Spacer()
                ForEach(columns, id: \.self) { title in
                    Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.faint)
                        .frame(width: Col.metric, alignment: .leading)
                }
                Color.clear.frame(width: Col.action, height: 1)
            }
            .padding(.horizontal, 14)

            VStack(spacing: 0) {
                if accounts.isEmpty {
                    emptyRow
                } else {
                    ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                        if index > 0 { Rectangle().fill(Theme.line).frame(height: 1).padding(.horizontal, 14) }
                        AccountLine(account: account, isUpNext: model.upNext(provider)?.id == account.id)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.cardBorder))
            if !accounts.isEmpty, let error = provider == .claude ? model.claudeError : model.codexError {
                Text(error).font(.system(size: 11)).foregroundStyle(Theme.amber)
            }
        }
    }

    private var emptyRow: some View {
        let error = provider == .claude ? model.claudeError : model.codexError
        return HStack {
            Text(error ?? (provider == .claude ? "No Claude accounts yet. Log in to Claude Code, then use + to add it." : "No Codex accounts yet. Use + to sign in."))
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
            Spacer()
        }
        .padding(14)
    }
}

struct AccountLine: View {
    let account: Account
    let isUpNext: Bool
    let model = AppModel.shared
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                Avatar(account: account, size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 10) {
                        NameField(account: account, font: .system(size: 13.5, weight: .semibold))
                        if account.isActive { Tag(text: account.activeIdentityVerified ? "Active" : "Selected · unverified", color: account.activeIdentityVerified ? Theme.mint : Theme.amber) }
                    }
                    Text(account.email.isEmpty ? "No Email Reported" : account.email)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .textSelection(.enabled)
                    status
                    if account.stale {
                        TimelineView(.everyMinute) { _ in
                            Text(account.usageFreshness(now: .now))
                                .font(.system(size: 10)).foregroundStyle(Theme.amber).lineLimit(1)
                        }
                    }
                }
            }
            Spacer(minLength: 8)
            let asOf = account.stale ? account.fetchedAt : nil
            if account.provider == .claude {
                LimitCell(window: account.fiveHour, asOf: asOf)
                LimitCell(window: account.weekly, asOf: asOf)
                LimitCell(window: account.watchedWindow, asOf: asOf)
            } else {
                LimitCell(window: account.fiveHour, asOf: asOf)
                LimitCell(window: account.weekly ?? account.windows.first, asOf: asOf)
                ResetsCell(account: account)
            }
            ZStack(alignment: .trailing) { Color.clear; trailing }.frame(width: Col.action, height: 30)
        }
        .frame(minHeight: account.stale ? 78 : 62)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(hovering && !account.isActive ? Theme.hover : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { menu }
    }

    /// Ticks every minute: "Back 07:59" turns into "Back Fri 07:59" overnight.
    private var status: some View {
        TimelineView(.everyMinute) { _ in statusTag }
    }

    @ViewBuilder private var statusTag: some View {
        if let problem = account.problem {
            Tag(text: problem, color: Theme.amber)
        } else if !account.readingTrusted(at: .now) {
            Tag(text: "Awaiting provider update", color: Theme.amber)
        } else if account.isBlocked {
            Tag(text: "Limited · Back \(account.backAt.map(Format.backTime) ?? "Soon")", color: Theme.coral)
        } else if isUpNext {
            Tag(text: "Candidate", color: Theme.blue)
        } else if account.disabled {
            Tag(text: "Skipped by Auto-Switch", color: Theme.faint)
        } else if !account.isActive {
            Tag(text: "Ready", color: Theme.faint)
        }
    }

    @ViewBuilder private var trailing: some View {
        if account.isActive {
            Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.mint)
        } else if hovering || model.busy.contains(account.id) {
            SwitchButton(account: account)
        }
    }

    @ViewBuilder private var menu: some View {
        Button("Use for default CLI") { model.activate(account) }
            .disabled(account.isActive || account.manualSwitchReason() != nil || model.coordinator.busy(account.provider))
        if account.provider == .claude {
            Button("Repair login") { model.repairClaudeLogin(account) }.disabled(model.coordinator.busy(.claude))
            Button(account.disabled ? "Include in Auto-Switch" : "Skip in Auto-Switch") { model.setInRotation(account, account.disabled) }
        }
        if !account.resetCredits.isEmpty || account.pendingResetID != nil {
            Button(account.pendingResetID == nil ? "Use a Free Reset (\(account.resetCredits.count) Left)" : "Retry pending reset") { model.useResetCredit(account) }
                .disabled(model.coordinator.busy(.codex) || model.busy.contains(account.id) || !account.readingTrusted(at: .now) || account.resetProblem != nil)
        }
        if account.provider == .codex {
            Divider()
            Button("Remove from ZipSwap", role: .destructive) { model.removeCodex(account) }
        }
    }
}

extension View {
    /// Every limit cell is the same box, so columns and rows line up exactly.
    func cellFrame() -> some View {
        frame(width: Col.metric - 18, height: 44, alignment: .topLeading)
            .padding(.trailing, 18)
    }
}

struct Tag: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(color == Theme.faint ? Theme.faint : color)
                .lineLimit(1)
        }
    }
}

/// One limit: the percentage, a thin bar, and when it resets. `asOf` marks a
/// last good reading whose percentage is that old.
struct LimitCell: View {
    let window: UsageWindow?
    var asOf: Date? = nil

    var body: some View {
        // The row's data can sit unchanged for hours, so the countdown has to
        // tick on its own rather than wait for new data to redraw it.
        TimelineView(.everyMinute) { _ in cell(now: .now) }
    }

    @ViewBuilder private func cell(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let window {
                Text(Format.pct(window.pct))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(asOf != nil ? Theme.faint : window.pct >= 70 ? Theme.tone(window.pct) : Theme.text)
                UsageBar(pct: window.pct, height: 3)
                    .opacity(asOf != nil ? 0.4 : 1)
                Text(resetText(window, now: now))
                    .font(Theme.mono(10)).foregroundStyle(Theme.faint).fixedSize()
            } else {
                Text("—").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.faint)
                Color.clear.frame(height: 3)
                Text("Not Reported").font(Theme.mono(10)).foregroundStyle(Theme.faint)
            }
        }
        .cellFrame()
        .help(help)
    }

    private var help: String {
        guard let window else { return "Not reported" }
        let used = "\(Format.pct(window.pct)) used, resets \(window.resetsAt.map(Format.exactReset) ?? "when used")"
        guard let asOf else { return used }
        return "\(used). Last good reading \(Format.ago(asOf)); usage can't be fetched right now."
    }

    private func resetText(_ window: UsageWindow, now: Date) -> String {
        guard let reset = window.resetsAt else { return "Not Started" }
        if window.isFull { return "Back \(Format.backTime(reset, now: now))" }
        return Format.short(reset, now: now)
    }
}

struct ResetsCell: View {
    let account: Account
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(account.resetCredits.count)")
                .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .foregroundStyle(account.resetCredits.isEmpty ? Theme.faint : Theme.blue)
            Color.clear.frame(height: 3)
            if account.resetCredits.isEmpty && account.pendingResetID == nil {
                Text("None").font(Theme.mono(10)).foregroundStyle(Theme.faint)
            } else {
                Button(account.pendingResetID == nil ? "Use One" : "Retry reset") { confirming = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.blue)
                    .disabled(AppModel.shared.coordinator.busy(.codex) || AppModel.shared.busy.contains(account.id) || !account.readingTrusted(at: .now) || account.resetProblem != nil)
            }
        }
        .cellFrame()
        .confirmationDialog("Use a Free Reset on \(account.title)?", isPresented: $confirming) {
            Button("Reset Limits Now") { AppModel.shared.useResetCredit(account) }
        } message: {
            Text(account.pendingResetID == nil ? "This spends one of \(account.resetCredits.count) free Codex resets and clears the current limits." : "This retries the previous reset using the same credit and operation ID.")
        }
    }
}

// MARK: shared pieces used by the dashboard too

struct FooterButton: View {
    let title: String
    let shortcut: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 12.5, weight: .medium))
                Text(shortcut).font(Theme.mono(10.5)).foregroundStyle(Theme.faint)
            }
            .foregroundStyle(hovering ? Theme.text : Theme.text2)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Theme.hover : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct ResetCreditControl: View {
    let account: Account
    @State private var confirming = false

    var body: some View {
        HStack(spacing: 6) {
            Text("\(account.resetCredits.count) Free Reset\(account.resetCredits.count == 1 ? "" : "s")")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.blue)
            Button(account.pendingResetID == nil ? "Use One" : "Retry reset") { confirming = true }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.blue)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.blue.opacity(0.16)))
                .disabled(AppModel.shared.busy.contains(account.id) || AppModel.shared.coordinator.busy(.codex) || !account.readingTrusted(at: .now) || account.resetProblem != nil)
        }
        .confirmationDialog("Use a Free Reset on \(account.title)?", isPresented: $confirming) {
            Button("Reset Limits Now") { AppModel.shared.useResetCredit(account) }
        } message: {
            Text(account.pendingResetID == nil ? "This spends one of \(account.resetCredits.count) free Codex resets and clears the current limits." : "This retries the previous reset using the same credit and operation ID.")
        }
    }
}
