import AppKit
import SwiftUI

enum PanelTab: String, CaseIterable {
    case priority, allUsage
    var label: String { self == .priority ? "Priority" : "All Usage" }
}

extension EnvironmentValues {
    /// Set while drawing a picture for the clipboard: controls are left out.
    @Entry var isSnapshot = false
}

/// The menu bar panel, laid out after OpenUsage: Priority shows what needs you,
/// All Usage shows every account and limit.
struct PanelView: View {
    let model = AppModel.shared
    @AppStorage("panelTab") private var tab: PanelTab = .priority
    @Environment(\.colorScheme) private var colorScheme
    @State private var contentHeight: CGFloat = 200
    @State private var copiedAt: Date?

    private var maxContentHeight: CGFloat {
        min(560, max(220, (NSScreen.main?.visibleFrame.height ?? 800) - 180))
    }

    var body: some View {
        VStack(spacing: 0) {
            CapsuleSegments(options: PanelTab.allCases.map { ($0, $0.label) }, selection: $tab)
                .padding(.horizontal, PanelMetrics.margin)
                .padding(.top, PanelMetrics.margin)
                .padding(.bottom, 10)
            banners
            ScrollView {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    PanelContent(tab: tab, now: context.date)
                }
                .padding(.horizontal, PanelMetrics.margin)
                .padding(.bottom, 4)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                    }
                }
            }
            .scrollIndicators(.automatic)
            // MenuBarExtra sizes the window to its content; a ScrollView has no
            // height of its own, so give it the measured height up to a cap.
            .frame(height: min(maxContentHeight, max(60, contentHeight)))
            .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
            footer
        }
        .frame(width: PanelMetrics.width)
        .background(Theme.bg)
        .onAppear { model.panelOpened() }
    }

    @ViewBuilder private var banners: some View {
        if let error = model.persistentError {
            Banner(systemImage: "exclamationmark.triangle.fill", tint: Theme.amber, text: error, action: "Dismiss") {
                model.persistentError = nil
            }
        }
        if model.loginTask != nil {
            Banner(systemImage: "person.badge.key", tint: Theme.accent, text: "Waiting for Claude sign-in", action: "Cancel") {
                model.cancelLogin()
            }
        }
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 8) {
            nextUpdate
            Spacer(minLength: 8)
            if !(model.claude + model.codex).isEmpty {
                RoundIconButton(systemName: "doc.on.doc", help: "Copy \(tab.label) Screenshot") { copyScreenshot() }
            }
            optionsMenu
        }
        .padding(.horizontal, PanelMetrics.margin + 4)
        .padding(.top, 10)
        .padding(.bottom, PanelMetrics.margin)
        .overlay(alignment: .top) {
            Group {
                if let copiedAt, Date.now.timeIntervalSince(copiedAt) < 2 {
                    TransientPill(systemImage: "checkmark.circle.fill", text: "Copied to Clipboard")
                } else if let toast = model.toast {
                    TransientPill(systemImage: "info.circle.fill", text: toast, tint: Theme.accent)
                }
            }
            .offset(y: -34)
        }
        .animation(.spring(duration: 0.3), value: copiedAt)
        .animation(.spring(duration: 0.3), value: model.toast)
    }

    private var nextUpdate: some View {
        Button {
            Task { await model.refreshAll() }
        } label: {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 5) {
                    Text(updateText(now: context.date))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    if updating { ProgressView().controlSize(.mini) }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("r", modifiers: .command)
        .help("Refresh Now (⌘R)")
        .disabled(updating)
    }

    private var updating: Bool { model.claudeLoading || model.codexLoading }

    private func updateText(now: Date) -> String {
        if updating { return "Updating…" }
        // Count from the last attempt: a failed refresh still schedules the next one.
        let next = [model.claudeRefreshStarted.map { $0.addingTimeInterval(60) },
                    model.codexRefreshStarted.map { $0.addingTimeInterval(30) }]
            .compactMap { $0 }.filter { $0 > now }.min()
        guard let next else { return "Next update soon" }
        let seconds = Int(max(0, next.timeIntervalSince(now)).rounded(.up))
        return seconds >= 60 ? "Next update in \(Int((Double(seconds) / 60).rounded(.up)))m" : "Next update in \(seconds)s"
    }

    private var optionsMenu: some View {
        Menu {
            Button("Add Current Claude Code Login") { model.addClaudeLogin() }
                .disabled(model.coordinator.busy(.claude))
            Button(model.addingCodex ? "Waiting for ChatGPT Sign-In…" : "Add Codex Account…") { model.addCodexAccount() }
                .disabled(model.addingCodex || model.coordinator.busy(.codex))
            Divider()
            Toggle("Claude Auto-Switch at \(Format.pct(model.claudeThreshold))", isOn: Binding(get: { model.claudeAutoOn }, set: { model.claudeAutoOn = $0 }))
            Toggle("Codex Auto-Switch at \(Format.pct(model.codexThreshold))", isOn: Binding(get: { model.codexAutoOn }, set: { model.codexAutoOn = $0 }))
            Toggle("Show Usage Left", isOn: Binding(get: { model.showsUsageLeft }, set: { model.showsUsageLeft = $0 }))
            Toggle("Show Reset Times", isOn: Binding(get: { model.showsResetClock }, set: { model.showsResetClock = $0 }))
            Divider()
            Button("Handoffs") { Dashboard.shared.showHandoffs() }
            Button("Settings") { Dashboard.shared.show() }.keyboardShortcut(",")
            Button("Check for Updates…") { Updater.shared.checkForUpdates() }
            Toggle("Open at Login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
            Divider()
            Button("Quit ZipSwap") { NSApp.terminate(nil) }.keyboardShortcut("q")
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(Theme.controlFill, in: Circle())
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Options")
    }

    private func copyScreenshot() {
        let card = ShareCard(tab: tab, now: .now).environment(\.colorScheme, colorScheme)
        if ShareImage.copy(card) { copiedAt = .now }
        Task {
            try? await Task.sleep(for: .seconds(2.1))
            copiedAt = copiedAt
        }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// A one-line notice above the panel's content with its one action.
struct Banner: View {
    let systemImage: String
    let tint: Color
    let text: String
    let action: String
    let perform: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
            Text(text).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action, action: perform).controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .padding(.horizontal, PanelMetrics.margin)
        .padding(.bottom, 10)
    }
}

/// The picture Copy Screenshot puts on the clipboard.
struct ShareCard: View {
    let tab: PanelTab
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelContent(tab: tab, now: now)
            HStack(spacing: 6) {
                AppMark(size: 14)
                Text("ZipSwap").font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(Format.clock(now, now: now)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
        .padding(16)
        .frame(width: PanelMetrics.width, alignment: .topLeading)
        .background(Theme.bg)
        .environment(\.isSnapshot, true)
    }
}

struct PanelContent: View {
    let tab: PanelTab
    let now: Date

    var body: some View {
        if tab == .priority { PriorityList(now: now) } else { AllUsageList(now: now) }
    }
}

// MARK: shared row text

/// How a limit's amount and reset read, under the user's two display switches.
@MainActor
enum UsageText {
    static var left: Bool { AppModel.shared.showsUsageLeft }
    static var clock: Bool { AppModel.shared.showsResetClock }

    static func percent(used: Double) -> String { Format.pct(left ? 100 - min(100, max(0, used)) : used) }
    static func fill(_ line: UsageLine) -> Double { (left ? line.leftPct : line.usedPct) / 100 }
    static func value(_ line: UsageLine) -> String { Format.pct(left ? line.leftPct : line.usedPct) }
    static func amount(_ line: UsageLine) -> String { value(line) + (left ? " left" : " used") }

    /// `back` adds "Back" to a used-up limit where the row has room for it.
    static func reset(_ window: UsageWindow, now: Date, back: Bool = true) -> String? {
        guard let reset = window.resetsAt else { return nil }
        let time = clock || window.isFull ? Format.backTime(reset, now: now) : Format.short(reset, now: now)
        return window.isFull && back ? "Back \(time)" : time
    }

    static func toggleAmount() { AppModel.shared.showsUsageLeft.toggle() }
    static func toggleReset() { AppModel.shared.showsResetClock.toggle() }
}

// MARK: Priority

struct PriorityList: View {
    let now: Date
    let model = AppModel.shared
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        let board = PriorityBoard.make(claude: model.claude, codex: model.codex, upNext: model.upNext, now: now)
        VStack(alignment: .leading, spacing: PanelMetrics.margin) {
            if model.claude.isEmpty && model.codex.isEmpty {
                emptyState
            } else {
                if !board.inUse.isEmpty {
                    section("In Use") {
                        ForEach(board.inUse) { line in
                            limitRow(line).contextMenu { AccountMenu(account: line.account) }
                        }
                    }
                }
                if !board.upNext.isEmpty {
                    section("Up Next") { ForEach(board.upNext) { upNextRow($0) } }
                }
                if !board.runningOut.isEmpty || board.allClear {
                    section("Running Out") {
                        if board.runningOut.isEmpty { clearRow }
                        ForEach(board.runningOut) { line in
                            limitRow(line).contextMenu { AccountMenu(account: line.account) }
                        }
                    }
                }
                if !board.usedUp.isEmpty {
                    section("Used Up") {
                        ForEach(board.usedUp) { line in
                            usedUpRow(line).contextMenu { AccountMenu(account: line.account) }
                        }
                    }
                    .opacity(0.5)
                }
                if !board.notices.isEmpty {
                    section("Needs Attention", warning: true) { ForEach(board.notices) { noticeRow($0) } }
                }
                if !board.waiting.isEmpty {
                    VStack(spacing: 0) { ForEach(board.waiting) { _ in skeletonRow } }
                }
                errors
            }
        }
    }

    private func section<Content: View>(_ title: String, warning: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 3) {
                SectionLabel(text: title)
                if warning {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.amber)
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 2)
            content().padding(.horizontal, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func limitRow(_ line: UsageLine) -> some View {
        let severity = Theme.severity(line.usedPct)
        return HStack(spacing: 10) {
            PriorityGauge(fraction: UsageText.fill(line), severity: severity, provider: line.account.provider)
            VStack(alignment: .leading, spacing: 1) {
                Text(line.title).font(.system(size: 13, weight: .medium))
                HStack(spacing: 4) {
                    Text(line.account.title).font(.system(size: 11)).foregroundStyle(.secondary)
                    StatusGlyph(account: line.account, now: now)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 1) {
                tappable(UsageText.toggleAmount) {
                    Text(UsageText.amount(line))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.severityText(severity))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                if let reset = UsageText.reset(line.window, now: now) {
                    tappable(UsageText.toggleReset) {
                        Text(reset).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            .lineLimit(1)
            .fixedSize()
        }
        .frame(height: 46)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func upNextRow(_ account: Account) -> some View {
        let tightest = account.relevantWindows.map { UsageLine(account: account, window: $0) }.max { $0.usedPct < $1.usedPct }
        let auto = account.provider == .claude ? model.claudeAutoOn : model.codexAutoOn
        let threshold = account.provider == .claude ? model.claudeThreshold : model.codexThreshold
        return HStack(spacing: 10) {
            PriorityGauge(fraction: tightest.map(UsageText.fill) ?? 0, severity: Theme.severity(tightest?.usedPct ?? 0), provider: account.provider)
            VStack(alignment: .leading, spacing: 1) {
                Text(account.title).font(.system(size: 13, weight: .medium))
                Text(auto ? "Auto-Switch at \(Format.pct(threshold))" : "Auto-Switch Off")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            if isSnapshot {
                if let tightest { Text(UsageText.amount(tightest)).font(.system(size: 13, weight: .medium)).monospacedDigit() }
            } else {
                SwitchButton(account: account)
            }
        }
        .frame(height: 46)
        .contextMenu { AccountMenu(account: account) }
    }

    private func usedUpRow(_ line: UsageLine) -> some View {
        HStack(spacing: 8) {
            ProviderMark(provider: line.account.provider, size: 15).frame(width: 16)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(line.title).font(.system(size: 13))
                Text(line.account.title).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            if let reset = line.window.resetsAt {
                tappable(UsageText.toggleReset) {
                    Text(UsageText.clock ? Format.backTime(reset, now: now) : Format.short(reset, now: now))
                        .font(.system(size: 12)).monospacedDigit().lineLimit(1).fixedSize()
                }
                .help("Back \(Format.resetClock(reset, now: now))")
            }
        }
        .frame(height: 28)
    }

    private func noticeRow(_ account: Account) -> some View {
        HStack(spacing: 8) {
            ProviderMark(provider: account.provider, size: 15).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(account.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(account.problem ?? "").font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if !isSnapshot {
                Button("Fix") {
                    if account.provider == .claude { model.repairClaudeLogin(account) } else { Dashboard.shared.show() }
                }
                .controlSize(.small)
                .disabled(model.coordinator.busy(account.provider))
                .help(account.provider == .claude ? "Repair Login" : "Open Account Settings")
            }
        }
        .padding(.vertical, 6)
        .contextMenu { AccountMenu(account: account) }
    }

    private var clearRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.positive)
                .frame(width: PanelMetrics.gaugeSide, height: PanelMetrics.gaugeSide)
                .background(Theme.positive.opacity(0.16), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text("All Clear").font(.system(size: 13, weight: .medium))
                Text("Nothing is running out").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 46)
        .accessibilityElement(children: .combine)
    }

    private var skeletonRow: some View {
        HStack(spacing: 10) {
            Circle().frame(width: PanelMetrics.gaugeSide, height: PanelMetrics.gaugeSide)
            VStack(alignment: .leading, spacing: 6) {
                Capsule().frame(width: 84, height: 9)
                Capsule().frame(width: 56, height: 7)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 6) {
                Capsule().frame(width: 48, height: 9)
                Capsule().frame(width: 32, height: 7)
            }
        }
        .skeleton()
        .frame(height: 46)
        .padding(.horizontal, 4)
        .accessibilityElement()
        .accessibilityLabel("Waiting for Usage")
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            AppMark(size: 32)
            Text("No Accounts").font(.system(size: 13, weight: .semibold))
            if let error = model.claudeError ?? model.codexError {
                Text(error).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if !isSnapshot {
                HStack(spacing: 8) {
                    Button("Add Claude Code Login") { model.addClaudeLogin() }
                    Button("Add Codex Account") { model.addCodexAccount() }
                }
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    @ViewBuilder private var errors: some View {
        ForEach([model.claudeError, model.codexError].compactMap { $0 }, id: \.self) { error in
            Text(error).font(.system(size: 11)).foregroundStyle(Theme.amber).padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private func tappable<Label: View>(_ action: @escaping () -> Void, @ViewBuilder label: () -> Label) -> some View {
        if isSnapshot { label() } else { Button(action: action, label: label).buttonStyle(.plain) }
    }
}

/// A spinner, warning or clock after an account's name.
struct StatusGlyph: View {
    let account: Account
    let now: Date

    var body: some View {
        if AppModel.shared.busy.contains(account.id) {
            ProgressView().controlSize(.mini).accessibilityLabel("Working")
        } else if let problem = account.problem, !account.awaitingFirstReading {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.amber)
                .help(problem).accessibilityLabel(problem)
        } else if account.isActive && !account.activeIdentityVerified {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.amber)
                .help("Selected, login not yet verified").accessibilityLabel("Login not yet verified")
        } else if account.stale || !account.readingTrusted(at: now) {
            Image(systemName: "clock")
                .font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary)
                .help(account.usageFreshness(now: now)).accessibilityLabel(account.usageFreshness(now: now))
        }
    }
}

// MARK: All Usage

struct AllUsageList: View {
    let now: Date
    let model = AppModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Provider.allCases) { provider in
                let accounts = ordered(provider)
                let error = provider == .claude ? model.claudeError : model.codexError
                if !accounts.isEmpty || error != nil {
                    ProviderCard(provider: provider, accounts: accounts, error: error, now: now)
                }
            }
            if model.claude.isEmpty && model.codex.isEmpty && model.claudeError == nil && model.codexError == nil {
                PriorityList(now: now)
            }
        }
    }

    /// Active first, then the one up next, then the rest in their usual order.
    private func ordered(_ provider: Provider) -> [Account] {
        let list = provider == .claude ? model.claude : model.codex
        let next = model.upNext(provider)?.id
        func rank(_ a: Account) -> Int { a.isActive ? 0 : a.id == next ? 1 : 2 }
        return list.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }
}

struct ProviderCard: View {
    let provider: Provider
    let accounts: [Account]
    let error: String?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                Text(provider.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 8)
                ProviderMark(provider: provider, size: 16)
            }
            .padding(.horizontal, PanelMetrics.cardPadding)
            .frame(height: 24)

            VStack(alignment: .leading, spacing: 10) {
                if accounts.isEmpty, let error {
                    Text(error).font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    ForEach(accounts) { AccountBlock(account: $0, now: now) }
                    if let error {
                        Text(error).font(.system(size: 11)).foregroundStyle(Theme.amber)
                    }
                }
            }
            .padding(.horizontal, PanelMetrics.cardPadding)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
    }
}

struct AccountBlock: View {
    let account: Account
    let now: Date
    @Environment(\.isSnapshot) private var isSnapshot

    private var lines: [UsageLine] {
        let windows = account.relevantWindows
        let ordered = windows.filter { $0.label == "5h" } + windows.filter { $0.label == "Week" }
            + windows.filter { $0.label != "5h" && $0.label != "Week" }
        return ordered.map { UsageLine(account: account, window: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            caption.padding(.bottom, 4)
            if lines.isEmpty {
                if account.problem == nil || account.awaitingFirstReading {
                    skeleton
                } else {
                    Text(account.problem ?? "").font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ForEach(lines) { MetricRow(line: $0, now: now) }
            }
            if account.provider == .codex && (!account.resetCredits.isEmpty || account.pendingResetID != nil) {
                FreeResetsRow(account: account)
            }
        }
        .contentShape(Rectangle())
        .contextMenu { AccountMenu(account: account) }
    }

    private var caption: some View {
        HStack(spacing: 6) {
            if isSnapshot {
                Text(account.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
            } else {
                NameField(account: account, font: .system(size: 11, weight: .semibold), color: Theme.text2)
                    .help(account.email.isEmpty ? "Rename" : account.email)
            }
            StatusGlyph(account: account, now: now)
            Spacer(minLength: 8)
            if account.isActive {
                PlanBadge(text: "Active", color: account.activeIdentityVerified ? Theme.positive : Theme.amber)
            } else if !isSnapshot {
                SwitchButton(account: account, size: .mini)
            }
            if !account.plan.isEmpty { PlanBadge(text: account.plan) }
        }
        .frame(height: 20)
    }

    private var skeleton: some View {
        VStack(spacing: 0) {
            ForEach(0..<2, id: \.self) { _ in
                HStack(spacing: 8) {
                    Capsule().frame(width: 50, height: 8).frame(width: PanelMetrics.labelWidth, alignment: .leading)
                    Capsule().frame(height: 6)
                    Capsule().frame(width: 28, height: 8).frame(width: PanelMetrics.valueWidth, alignment: .trailing)
                    Capsule().frame(width: 30, height: 7).frame(width: PanelMetrics.resetWidth, alignment: .trailing)
                }
                .frame(height: PanelMetrics.rowHeight)
            }
        }
        .skeleton()
        .accessibilityElement()
        .accessibilityLabel("Waiting for Usage")
    }
}

/// Label, bar, amount and reset: one limit in All Usage.
struct MetricRow: View {
    let line: UsageLine
    let now: Date
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        let severity = Theme.severity(line.usedPct)
        let stale = line.account.stale
        HStack(spacing: 8) {
            Text(line.title).lineLimit(1).frame(width: PanelMetrics.labelWidth, alignment: .leading)
            LevelBar(fill: UsageText.fill(line), severity: severity, pace: pace)
                .opacity(stale ? 0.4 : 1)
                .help(paceHelp)
            tappable(UsageText.toggleAmount) {
                Text(UsageText.value(line))
                    .foregroundStyle(severity == .normal ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.severityText(severity)))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .frame(width: PanelMetrics.valueWidth, alignment: .trailing)
            tappable(UsageText.toggleReset) {
                Text(UsageText.reset(line.window, now: now, back: false) ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(line.isUsedUp ? AnyShapeStyle(Theme.severityText(.critical)) : AnyShapeStyle(.secondary))
                    .monospacedDigit()
            }
            .lineLimit(1)
            .frame(width: PanelMetrics.resetWidth, alignment: .trailing)
            .help(line.window.resetsAt.map { (line.isUsedUp ? "Back " : "Resets ") + Format.exactReset($0) } ?? "Starts when used")
        }
        .font(.system(size: 12))
        .frame(height: PanelMetrics.rowHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(line.title)
        .accessibilityValue("\(UsageText.amount(line))\(UsageText.reset(line.window, now: now).map { ", resets \($0)" } ?? "")")
    }

    /// Where an even pace would have the bar by now, on weekly limits.
    private var pace: Double? {
        guard line.window.label == "Week",
              let expected = line.window.expectedPct ?? Format.expectedPct(for: line.window, windowMinutes: line.window.windowMinutes ?? 10080)
        else { return nil }
        return (UsageText.left ? 100 - expected : expected) / 100
    }

    private var paceHelp: String {
        guard line.window.label == "Week" else { return "" }
        return Pace.of(line.account).text
    }

    @ViewBuilder
    private func tappable<Label: View>(_ action: @escaping () -> Void, @ViewBuilder label: () -> Label) -> some View {
        if isSnapshot { label() } else { Button(action: action, label: label).buttonStyle(.plain) }
    }
}

struct FreeResetsRow: View {
    let account: Account
    @State private var confirming = false
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        let model = AppModel.shared
        HStack(spacing: 8) {
            Text("Free Resets").lineLimit(1)
            Spacer(minLength: 0)
            Text("\(account.resetCredits.count)").monospacedDigit()
            if !isSnapshot {
                Button(account.pendingResetID == nil ? "Use" : "Retry") { confirming = true }
                    .buttonStyle(.link)
                    .disabled(model.coordinator.busy(.codex) || model.busy.contains(account.id) || !account.readingTrusted(at: .now) || account.resetProblem != nil)
                    .help(account.resetProblem ?? account.resetCredits.compactMap(\.expiresAt).min().map { "Earliest expires \(Format.resetClock($0))" } ?? "")
            }
        }
        .font(.system(size: 12))
        .frame(height: PanelMetrics.rowHeight)
        .confirmationDialog("Use a Free Reset on \(account.title)?", isPresented: $confirming) {
            Button("Reset Limits Now") { model.useResetCredit(account) }
        } message: {
            Text(account.pendingResetID == nil ? "This spends one of \(account.resetCredits.count) free Codex resets and clears the current limits." : "This retries the previous reset using the same credit and operation ID.")
        }
    }
}

/// An account's right-click menu, the same wherever the account shows.
struct AccountMenu: View {
    let account: Account

    var body: some View {
        let model = AppModel.shared
        Button("Use for Default CLI") { model.activate(account) }
            .disabled(account.isActive || account.manualSwitchReason() != nil || model.coordinator.busy(account.provider))
        if account.provider == .claude {
            Button("Repair Login") { model.repairClaudeLogin(account) }.disabled(model.coordinator.busy(.claude))
            Button(account.disabled ? "Include in Auto-Switch" : "Skip in Auto-Switch") { model.setInRotation(account, account.disabled) }
        }
        if !account.resetCredits.isEmpty || account.pendingResetID != nil {
            Button(account.pendingResetID == nil ? "Use a Free Reset (\(account.resetCredits.count) Left)" : "Retry Pending Reset") { model.useResetCredit(account) }
                .disabled(model.coordinator.busy(.codex) || model.busy.contains(account.id) || !account.readingTrusted(at: .now) || account.resetProblem != nil)
        }
        Divider()
        Button("Show in Settings") { Dashboard.shared.show() }
        if account.provider == .codex {
            Button("Remove from ZipSwap", role: .destructive) { model.removeCodex(account) }
        }
    }
}

// MARK: shared pieces used by the dashboard too

struct ResetCreditControl: View {
    let account: Account
    @State private var confirming = false

    var body: some View {
        HStack(spacing: 6) {
            Text("\(account.resetCredits.count) Free Reset\(account.resetCredits.count == 1 ? "" : "s")")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accent)
            Button(account.pendingResetID == nil ? "Use One" : "Retry Reset") { confirming = true }
                .controlSize(.small)
                .disabled(AppModel.shared.busy.contains(account.id) || AppModel.shared.coordinator.busy(.codex) || !account.readingTrusted(at: .now) || account.resetProblem != nil)
        }
        .confirmationDialog("Use a Free Reset on \(account.title)?", isPresented: $confirming) {
            Button("Reset Limits Now") { AppModel.shared.useResetCredit(account) }
        } message: {
            Text(account.pendingResetID == nil ? "This spends one of \(account.resetCredits.count) free Codex resets and clears the current limits." : "This retries the previous reset using the same credit and operation ID.")
        }
    }
}
