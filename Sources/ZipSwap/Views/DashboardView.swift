import SwiftUI

struct DashboardView: View {
    let model = AppModel.shared
    @State private var selection: String? = "overview"

    init(initialSelection: String = "overview") {
        _selection = State(initialValue: initialSelection)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.line).frame(width: 1)
            VStack(spacing: 0) {
                if let error = model.persistentError {
                    HStack {
                        Text(error).font(.system(size: 12)).foregroundStyle(Theme.amber).textSelection(.enabled)
                        Spacer()
                        Button("Dismiss") { model.persistentError = nil }
                    }.padding(14)
                }
            Group {
                if selection == "handoffs" {
                    HandoffView()
                } else if let id = selection, let account = (model.claude + model.codex).first(where: { $0.id == id }) {
                    AccountDetail(account: account)
                } else {
                    OverviewDetail()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .frame(minWidth: 860, minHeight: 540)
        .onAppear { model.panelOpened() }
        .onReceive(NotificationCenter.default.publisher(for: .showHandoffs)) { _ in selection = "handoffs" }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                AppMark(size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("ZipSwap").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(summary).font(.system(size: 11)).foregroundStyle(Theme.faint)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 14)

            SidebarItem(title: "Overview", systemImage: "square.grid.2x2", selected: selection == "overview") { selection = "overview" }
            SidebarItem(title: "Handoffs", systemImage: "arrow.triangle.branch", selected: selection == "handoffs") { selection = "handoffs" }

            ScrollView {
            VStack(alignment: .leading, spacing: 4) {
            ForEach(Provider.allCases) { provider in
                let list = provider == .claude ? model.claude : model.codex
                SectionLabel(text: provider.title).padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 4)
                ForEach(list) { account in
                    SidebarAccount(account: account, selected: selection == account.id) { selection = account.id }
                }
                if list.isEmpty {
                    Text("No accounts yet").font(.system(size: 11.5)).foregroundStyle(Theme.faint).padding(.horizontal, 10)
                }
            }
            }
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Circle().fill(model.claudeEngineRunning ? Theme.mint : Theme.faint).frame(width: 7, height: 7)
                Text("Claude auto-switch: \(model.claudeEngineStatus)")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.muted)
            }
            .padding(10)
        }
        .padding(10)
        .frame(width: 250)
        .background(Theme.sunken)
    }

    private var summary: String {
        let all = model.claude + model.codex
        let limited = all.filter(\.isBlocked).count
        return "\(all.count) accounts" + (limited > 0 ? " · \(limited) limited" : "")
    }
}

struct SidebarItem: View {
    let title: String
    let systemImage: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage).font(.system(size: 12)).frame(width: 28)
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer()
            }
            .foregroundStyle(selected ? Theme.text : Theme.text2)
            .padding(.vertical, 7)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Color(hex: 0x1E2025) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SidebarAccount: View {
    let account: Account
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Avatar(account: account, size: 28)
                VStack(alignment: .leading, spacing: 5) {
                    Text(account.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                    UsageBar(pct: account.tightest, height: 3)
                }
                Text(account.usageDisplay).font(Theme.mono(10.5)).foregroundStyle(Theme.muted).frame(width: 36, alignment: .trailing)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Color(hex: 0x1E2025) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct AccountDetail: View {
    let account: Account
    let model = AppModel.shared

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 16) {
                Avatar(account: account, size: 54)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        NameField(account: account, font: .system(size: 26, weight: .semibold))
                        if account.isActive { Chip(text: account.activeIdentityVerified ? "Active" : "Selected · unverified", color: account.activeIdentityVerified ? Theme.mint : Theme.amber) }
                        if account.disabled { Chip(text: "Skipped by Auto-Switch", color: Theme.faint) }
                    }
                    Text([account.provider.title, account.plan, account.email].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
                Spacer()
                if !account.isActive {
                    if account.isBlocked {
                        Text("Limited Until \(account.backAt.map(Format.resetClock) ?? "Reset")")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
                            .padding(.horizontal, 14).frame(height: 34)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.line))
                    } else {
                        Button {
                            model.activate(account)
                        } label: {
                            Text("Switch to \(account.title)").font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.bg).padding(.horizontal, 14).frame(height: 34)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.mint))
                        }
                        .buttonStyle(.plain)
                        .disabled(model.coordinator.busy(account.provider) || account.manualSwitchReason() != nil)
                    }
                }
            }

            Text("Default CLI scope · Israel time").font(.system(size: 11.5)).foregroundStyle(Theme.muted)
            if let problem = account.problem ?? (account.provider == .claude ? model.claudeError : model.codexError) {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.amber)
            }

            HStack {
                if account.provider == .claude {
                    Button(model.busy.contains(account.id) ? "Signing in…" : "Repair login") { model.repairClaudeLogin(account) }
                        .disabled(model.coordinator.busy(.claude))
                }
                if model.loginTask != nil { Button("Cancel sign-in") { model.cancelLogin() } }
                if let reason = account.eligibilityReason() { Text(reason).font(.system(size: 12)).foregroundStyle(Theme.amber) }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                ForEach(account.windows) { WindowCard(window: $0, stale: account.stale) }
                if let credits = account.credits {
                    StatCard(title: "Credits", value: credits, detail: "balance on this ChatGPT account")
                }
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Forecast").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(account.problem ?? Pace.of(account).text).font(.system(size: 13)).foregroundStyle(Theme.text2)
                    // The schedule can start before a just-fetched reading.
                    // Use the live clock for validity, not the scheduled tick.
                    TimelineView(.everyMinute) { _ in
                        Text(account.usageFreshness(now: .now)).font(.system(size: 11.5)).foregroundStyle(account.stale ? Theme.amber : Theme.faint)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardStyle()

                if account.provider == .codex {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Free Resets").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                            Spacer()
                            if !account.resetCredits.isEmpty || account.pendingResetID != nil { ResetCreditControl(account: account) }
                        }
                        if account.resetCredits.isEmpty {
                            Text("None available on this account.").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                        }
                        if let problem = account.resetProblem { Text(problem).font(.system(size: 12)).foregroundStyle(Theme.amber) }
                        if account.pendingResetID != nil { Text("A previous reset is unconfirmed. Retry uses the same credit.").font(.system(size: 12)).foregroundStyle(Theme.amber) }
                        ForEach(account.resetCredits) { credit in
                            HStack {
                                Text(credit.title).font(.system(size: 12.5)).foregroundStyle(Theme.text2)
                                Spacer()
                                Text(credit.expiresAt.map { "expires \(Format.clock($0))" } ?? "no expiry")
                                    .font(Theme.mono(11)).foregroundStyle(Theme.faint)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardStyle()
                }
            }
            Spacer()
        }
        .padding(28)
        }
    }
}

struct WindowCard: View {
    let window: UsageWindow
    var stale = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text2)
                Spacer()
                Text(window.resetsAt.map(Format.resetClock) ?? "Not Started").font(Theme.mono(11)).foregroundStyle(Theme.faint)
                    .help(window.resetsAt.map(Format.exactReset) ?? "No reset deadline reported")
            }
            Text(Format.pct(window.pct)).font(.system(size: 34, weight: .semibold)).monospacedDigit().foregroundStyle(stale ? Theme.faint : Theme.text)
            UsageBar(pct: window.pct, height: 8, pace: window.expectedPct)
            HStack {
                Text(window.expectedPct.map { "even pace: \(Format.pct($0))" } ?? "rolling window")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
                Spacer()
                TimelineView(.everyMinute) { _ in
                    Text(Format.countdown(window.resetsAt, now: .now)).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                }
            }
        }
        .cardStyle()
    }

    private var title: String {
        switch window.label {
        case "5h": return "5-Hour"
        case "Week": return "Weekly"
        default: return window.windowMinutes == 10080 ? "\(window.label) Weekly" : window.label
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text2)
            Text(value).font(.system(size: 34, weight: .semibold)).foregroundStyle(Theme.blue)
            Text(detail).font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

struct OverviewDetail: View {
    let model = AppModel.shared
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                if geometry.size.width < 760 {
                    VStack(alignment: .leading, spacing: 16) { historyCard; settingsPanel }
                        .padding(24)
                } else {
                    HStack(alignment: .top, spacing: 16) { historyCard; settingsPanel.frame(width: 330) }
                        .padding(24)
                }
            }
        }
    }
    private var historyCard: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("Recent Switches").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                if model.history.isEmpty {
                    Text("No switches yet.").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                }
                ForEach(model.history.prefix(14)) { item in
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 2).fill(item.provider == .claude ? Theme.claudeMark : Theme.codexMark).frame(width: 8, height: 8)
                        Text("\(item.from) → \(item.to)").font(.system(size: 12.5)).foregroundStyle(Theme.text)
                        if !item.reason.isEmpty { Text(item.reason).font(.system(size: 11)).foregroundStyle(Theme.faint) }
                        Spacer()
                        Text(Format.clock(item.at)).font(Theme.mono(11)).foregroundStyle(Theme.faint)
                    }
                    .padding(.vertical, 5)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .cardStyle()

    }
    @ViewBuilder private var settingsPanel: some View {
        @Bindable var model = model
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Auto-Switch").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                    Lever(title: "Claude Code", isOn: $model.claudeAutoOn, value: $model.claudeThreshold,
                          note: model.legacyRunning && model.claudeAutoOn ? "Paused While the Old Menu Bar Runs" : nil)
                    Lever(title: "Codex", isOn: $model.codexAutoOn, value: $model.codexThreshold)
                    Text("Default CLI accounts · Codex waits 5 minutes between switches")
                        .font(.system(size: 11)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
                }
                .cardStyle()

                VStack(alignment: .leading, spacing: 12) {
                    Text("App").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                    HStack {
                        Text("Open at Login").font(.system(size: 12.5)).foregroundStyle(Theme.text2)
                        Spacer()
                        ToggleSwitch(isOn: $model.launchAtLogin, label: "Open at Login")
                    }
                    HStack {
                        Text("Version \(Bundle.main.shortVersion) (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "local"))")
                            .font(.system(size: 12.5)).foregroundStyle(Theme.text2)
                        Spacer()
                        Button("Check for Updates") { Updater.shared.checkForUpdates() }.controlSize(.small)
                    }
                    Text("Claude auto-switch: \(model.claudeEngineStatus)").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    if model.claudeAutoOn && !model.claudeEngineRunning && !model.legacyRunning {
                        Button("Retry auto-switch") { model.engine.retry(); model.applyClaudeAuto() }
                    }
                    Button("Export diagnostics") { model.exportDiagnostics() }
                    if model.codexError != nil { Button("Restore account-list backup") { model.restoreCodexIndex() } }
                    if model.codexError != nil { Button("Recover saved logins") { model.recoverSavedLogins() } }
                    ForEach(model.runtimeTools) { tool in
                        HStack {
                            Text(tool.name).font(.system(size: 12)).foregroundStyle(Theme.text2)
                            Spacer()
                            Text(tool.version).font(Theme.mono(11)).foregroundStyle(tool.issue == nil ? Theme.muted : Theme.amber)
                        }
                        if let issue = tool.issue { Text(issue).font(.system(size: 12)).foregroundStyle(Theme.amber) }
                    }
                    Button("Check tools") { Task { await model.checkTools(); await model.refreshAll() } }
                    Text(Bundle.main.infoDictionary?["ZipSwapSourceRevision"] as? String ?? "Local source revision unrecorded")
                        .font(Theme.mono(10)).foregroundStyle(Theme.muted).textSelection(.enabled)
                    if model.legacyRunning {
                        HStack {
                            Text("Old cswap Menu Bar Is Running").font(.system(size: 12.5)).foregroundStyle(Theme.amber)
                            Spacer()
                            Button("Retire It") { model.retireLegacyMenuBar() }.controlSize(.small)
                        }
                    }
                }
                .cardStyle()
            }
    }
}

extension View {
    func cardStyle() -> some View {
        padding(18)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.cardBorder))
    }
}

extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0" }
}
