import AppKit
import SwiftUI

extension EnvironmentValues {
    /// Set while drawing a picture for the clipboard: controls are left out.
    @Entry var isSnapshot = false
}

/// The menu bar panel, laid out after OpenUsage: every account and limit, the
/// active account first and the one auto-switch moves to next beside it.
struct PanelView: View {
    let model = AppModel.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var contentHeight: CGFloat = 200
    @State private var copiedAt: Date?

    private var maxContentHeight: CGFloat {
        min(560, max(220, (NSScreen.main?.visibleFrame.height ?? 800) - 180))
    }

    var body: some View {
        VStack(spacing: 0) {
            banners
            ScrollView {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    AllUsageList(now: context.date)
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
        .padding(.top, PanelMetrics.margin)
        .frame(width: PanelMetrics.width(accounts: model.claude.count + model.codex.count))
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
                RoundIconButton(systemName: "doc.on.doc", help: "Copy Screenshot") { copyScreenshot() }
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
            Button(model.loginTask != nil ? "Waiting for Claude Sign-In…" : "Add Claude Account…") { model.addClaudeAccount() }
                .disabled(model.loginTask != nil || model.coordinator.busy(.claude))
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
        let card = ShareCard(now: .now).environment(\.colorScheme, colorScheme)
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
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AllUsageList(now: now)
            HStack(spacing: 6) {
                AppMark(size: 14)
                Text("ZipSwap").font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(Format.clock(now, now: now)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
        .padding(16)
        .frame(width: PanelMetrics.width(accounts: AppModel.shared.claude.count + AppModel.shared.codex.count) + 32, alignment: .topLeading)
        .background(Theme.bg)
        .environment(\.isSnapshot, true)
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

/// Says when a card's numbers are older than usual: Anthropic refusing reads, or
/// a read that hasn't come. Nothing shows while readings are on schedule.
struct ReadingNote: View {
    let account: Account
    let now: Date

    var body: some View {
        if let text {
            Text(text)
                .font(.system(size: 11)).foregroundStyle(Theme.amber)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var text: String? {
        guard !account.relevantWindows.isEmpty, let fetched = account.fetchedAt else { return nil }
        let read = "read \(Format.ago(fetched, now: now))"
        if let paused = account.usagePausedUntil {
            return "Anthropic paused usage reads until \(Format.clock(paused, now: now)) · \(read)"
        }
        guard account.readingLate(at: now) else { return nil }
        if let retry = account.usageRetryAt, retry > now { return "Usage retry at \(Format.clock(retry, now: now)) · \(read)" }
        return "Usage \(read)"
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
        } else if account.readingLate(at: now) || account.usagePausedUntil != nil {
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
        let cards = Provider.allCases.flatMap { ordered($0) }
        let columns = PanelMetrics.columns(accounts: cards.count)
        VStack(alignment: .leading, spacing: PanelMetrics.cardGap) {
            ForEach([model.claudeError, model.codexError].compactMap { $0 }, id: \.self) { error in
                Text(error).font(.system(size: 11)).foregroundStyle(Theme.amber).padding(.horizontal, 4)
            }
            ForEach(nothingNext, id: \.self) { provider in
                Text("No \(provider.title) account is next: the others are used up, skipped or waiting for a reading.")
                    .font(.system(size: 11)).foregroundStyle(Theme.amber).padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if cards.isEmpty {
                if model.claudeError == nil && model.codexError == nil { emptyState }
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: PanelMetrics.cardGap, alignment: .top), count: columns),
                    alignment: .leading, spacing: PanelMetrics.cardGap
                ) {
                    ForEach(cards) { AccountCard(account: $0, now: now, rows: rows($0.provider), sessionRow: hasSession($0.provider)) }
                }
            }
        }
    }

    /// The most limit rows any card of this provider has. Every card of the
    /// provider keeps that many, so Free Resets sits on the same line on all of them.
    private func rows(_ provider: Provider) -> Int {
        let list = provider == .claude ? model.claude : model.codex
        let session = hasSession(provider)
        return list.map { account in
            let windows = account.relevantWindows
            // A plan without Session still draws a "Session None" row.
            return max(windows.count + (session && !windows.isEmpty && !windows.contains { $0.label == "5h" } ? 1 : 0), 2)
        }.max() ?? 2
    }

    /// Whether any card of this provider has a Session limit, so the others say "None".
    private func hasSession(_ provider: Provider) -> Bool {
        (provider == .claude ? model.claude : model.codex).contains { $0.relevantWindows.contains { $0.label == "5h" } }
    }

    /// Providers with auto-switch on and more than one account, but nowhere to go.
    private var nothingNext: [Provider] {
        Provider.allCases.filter { provider in
            let list = provider == .claude ? model.claude : model.codex
            let auto = provider == .claude ? model.claudeAutoOn : model.codexAutoOn
            return auto && list.count > 1 && list.contains(where: \.isActive) && model.upNext(provider) == nil
        }
    }

    @Environment(\.isSnapshot) private var isSnapshot

    private var emptyState: some View {
        VStack(spacing: 10) {
            AppMark(size: 32)
            Text("No Accounts").font(.system(size: 13, weight: .semibold))
            if !isSnapshot {
                HStack(spacing: 8) {
                    Button("Add Claude Account") { model.addClaudeAccount() }
                    Button("Add Codex Account") { model.addCodexAccount() }
                }
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    /// Active first, then the one up next, then the rest in their usual order.
    private func ordered(_ provider: Provider) -> [Account] {
        let list = provider == .claude ? model.claude : model.codex
        let next = model.upNext(provider)?.id
        func rank(_ a: Account) -> Int { a.isActive ? 0 : a.id == next ? 1 : 2 }
        return list.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }
}

/// Where an account stands in the rotation, shown by its card's color.
@MainActor
enum AccountRole {
    case active, next, other

    static func of(_ account: Account) -> AccountRole {
        account.isActive ? .active : AppModel.shared.upNext(account.provider)?.id == account.id ? .next : .other
    }

    /// Green for the account in use, purple for the one auto-switch moves to next.
    /// Blue already means a normal limit, and links.
    var color: Color? {
        switch self {
        case .active: return Theme.positive
        case .next: return Theme.violet
        case .other: return nil
        }
    }
}

/// One account in the All Usage grid: its own card, tinted by its role.
struct AccountCard: View {
    let account: Account
    let now: Date
    var rows = 0
    var sessionRow = false

    var body: some View {
        let tint = AccountRole.of(account).color
        AccountBlock(account: account, now: now, rows: rows, sessionRow: sessionRow)
            .padding(.horizontal, PanelMetrics.cardPadding)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .cardSurface()
            .overlay {
                if let tint {
                    Theme.cardShape.fill(tint.opacity(0.07)).allowsHitTesting(false)
                    Theme.cardShape.strokeBorder(tint.opacity(0.85), lineWidth: 1.5).allowsHitTesting(false)
                }
            }
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
    /// Limit rows to reserve, so rows after them line up across cards.
    var rows = 0
    /// Other cards show Session; one without it says "None" in that row.
    var sessionRow = false
    @Environment(\.isSnapshot) private var isSnapshot

    /// Weekly first on every card so the rows line up; Session, which only
    /// some plans have, comes last.
    private var lines: [UsageLine] {
        let windows = account.relevantWindows
        let ordered = windows.filter { $0.label == "Week" }
            + windows.filter { $0.label != "5h" && $0.label != "Week" }
            + windows.filter { $0.label == "5h" }
        return ordered.map { UsageLine(account: account, window: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            caption
            if !account.email.isEmpty {
                // The whole address, wrapping if it must: it tells same-named accounts apart.
                Text(account.email)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityLabel("Email \(account.email)")
            }
            ReadingNote(account: account, now: now)
            Color.clear.frame(height: 4)
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
            // Blank rows for limits this plan doesn't have (no Session, say).
            // Measured from the rows actually drawn: a skeleton is two rows.
            let noSession = sessionRow && !lines.isEmpty && !lines.contains { $0.window.label == "5h" }
            if noSession { NoLimitRow(title: UsageLine.title(for: "5h")) }
            let drawn = lines.isEmpty ? (account.problem == nil || account.awaitingFirstReading ? 2 : 1) : lines.count + (noSession ? 1 : 0)
            ForEach(0..<max(0, rows - drawn), id: \.self) { _ in Color.clear.frame(height: PanelMetrics.rowHeight) }
            // A late-reading note above can make one card taller; pinning keeps
            // Free Resets on its card's last line.
            Spacer(minLength: 0)
            if account.provider == .codex && (!account.resetCredits.isEmpty || account.pendingResetID != nil) {
                FreeResetsRow(account: account)
            }
            if account.provider == .claude
                && (AppModel.shared.claudeResets.usable(for: account.email) > 0 || (account.isBlocked && !isSnapshot)) {
                ClaudeResetsRow(account: account)
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
                    .help("Rename")
            }
            StatusGlyph(account: account, now: now)
            Spacer(minLength: 8)
            // Every chip has the same size, so the columns line up across cards.
            if account.isActive {
                HeaderChip(text: "Active", color: account.activeIdentityVerified ? Theme.positive : Theme.amber)
                    .help(account.activeIdentityVerified ? "The default \(account.provider.title) login" : "Selected, login not yet verified")
            } else {
                if AccountRole.of(account) == .next {
                    let threshold = account.provider == .claude ? AppModel.shared.claudeThreshold : AppModel.shared.codexThreshold
                    HeaderChip(text: "Next", color: Theme.violet)
                        .help("Auto-switch moves here when the active account reaches \(Format.pct(threshold))")
                }
                if !isSnapshot { SwitchChip(account: account) }
            }
            if !account.plan.isEmpty { HeaderChip(text: account.plan).help(account.plan) }
        }
        .frame(height: PanelMetrics.chipHeight)
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

/// A limit this plan doesn't have, in the row other cards use for it.
struct NoLimitRow: View {
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title).lineLimit(1).frame(width: PanelMetrics.labelWidth, alignment: .leading)
            Text("None").foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .frame(height: PanelMetrics.rowHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): no limit on this plan")
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

/// Confirmations stay inside the row: a dialog or sheet would take focus from
/// the menu bar panel, which closes it before the choice registers.
struct FreeResetsRow: View {
    let account: Account
    @State private var confirming = false
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        let model = AppModel.shared
        HStack(spacing: 8) {
            if confirming && !isSnapshot {
                Text(account.pendingResetID == nil ? "Reset limits now?" : "Retry the same reset?").lineLimit(1)
                Spacer(minLength: 0)
                Button("Cancel") { confirming = false }.buttonStyle(.link).foregroundStyle(.secondary)
                Button(account.pendingResetID == nil ? "Reset" : "Retry") { confirming = false; model.useResetCredit(account) }
                    .buttonStyle(.link).fontWeight(.semibold)
            } else {
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
        }
        .font(.system(size: 12))
        .frame(height: PanelMetrics.rowHeight)
        .task(id: confirming) {
            guard confirming else { return }
            try? await Task.sleep(for: .seconds(10))
            confirming = false
        }
    }
}

/// A used-up Claude account's way to a free reset. Claude only shows and spends
/// them on claude.ai, so this opens that page for the account's own sign-in.
struct ClaudeResetsRow: View {
    let account: Account
    @State private var confirming = false
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        let model = AppModel.shared
        let left = model.claudeResets.usable(for: account.email)
        let expiry = model.claudeResets.balance(for: account.email)?.expiryDate()
        HStack(spacing: 8) {
            if confirming && left > 0 && !isSnapshot {
                Text("Count one used?").lineLimit(1)
                Spacer(minLength: 0)
                Button("Cancel") { confirming = false }.buttonStyle(.link).foregroundStyle(.secondary)
                Button("claude.ai") { NSWorkspace.shared.open(ClaudeService.usagePage) }
                    .buttonStyle(.link)
                    .help("Claim it in Settings › Usage, signed in as \(account.email)")
                Button("Count") { confirming = false; model.countClaudeResetUsed(account, openClaude: false) }
                    .buttonStyle(.link).fontWeight(.semibold)
                    .help("\(left - 1) left after this")
            } else {
                Text("Free Resets").lineLimit(1)
                Spacer(minLength: 0)
                if left > 0 {
                    Text("\(left)").monospacedDigit()
                        .help(expiry.map { "Entered by hand · usable through \(Format.dateText($0, format: "MMM d"))" } ?? "Entered by hand")
                    if !isSnapshot {
                        Button("Use") { confirming = true }.buttonStyle(.link)
                    }
                } else if !isSnapshot {
                    Button("Check") { NSWorkspace.shared.open(ClaudeService.usagePage) }
                        .buttonStyle(.link)
                        .help("Opens Settings › Usage on claude.ai. Sign in there as \(account.email).")
                }
            }
        }
        .font(.system(size: 12))
        .frame(height: PanelMetrics.rowHeight)
        // A confirmation left open shouldn't wait for a stray click later.
        .task(id: confirming) {
            guard confirming else { return }
            try? await Task.sleep(for: .seconds(15))
            confirming = false
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
            Button("Check Free Resets on claude.ai") { NSWorkspace.shared.open(ClaudeService.usagePage) }
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
