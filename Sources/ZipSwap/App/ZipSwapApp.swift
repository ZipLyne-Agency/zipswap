import AppKit
import Sparkle
import SwiftUI
import UserNotifications

@main
struct ZipSwapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            PanelView()
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}

/// The dashboard lives in a plain AppKit window: SwiftUI's openWindow is
/// unreliable from a menu-bar-only app.
@MainActor
final class Dashboard: NSObject, NSWindowDelegate {
    static let shared = Dashboard()
    private var window: NSWindow?

    func showHandoffs() {
        show(handoffs: true)
        NotificationCenter.default.post(name: .showHandoffs, object: nil)
    }

    func show(handoffs: Bool = false) {
        // Dismiss the menu bar panel so it doesn't sit over the dashboard.
        for w in NSApp.windows where w !== window && w.className.contains("MenuBarExtra") { w.close() }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "ZipSwap"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.backgroundColor = .windowBackgroundColor
            w.contentMinSize = NSSize(width: 860, height: 540)
            w.contentViewController = NSHostingController(rootView: DashboardView(initialSelection: handoffs ? "handoffs" : "overview"))
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            w.setFrameAutosaveName("ZipSwapDashboard")
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a pure menu bar app once the dashboard is gone.
        NSApp.setActivationPolicy(.accessory)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { Dashboard.shared.show() }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Updater.shared.start()
        MainActor.assumeIsolated { AppModel.shared.start() }
        UNUserNotificationCenter.current().delegate = self
        MainActor.assumeIsolated { HandoffController.shared.start() }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.content.userInfo["handoffID"] is String {
            Task { @MainActor in Dashboard.shared.showHandoffs() }
        }
        completionHandler()
    }
}

extension Notification.Name {
    static let showHandoffs = Notification.Name("ZipSwapShowHandoffs")
}

final class Updater {
    static let shared = Updater()
    private var controller: SPUStandardUpdaterController?

    func start() {
        // Without a real signing key the feed can't be trusted, so stay off.
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              !key.isEmpty, key != "SPARKLE_PUBLIC_KEY" else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }
}

/// The menu bar strip, after OpenUsage: each item is the provider's mark (with
/// the account's initial when there are several) over a short label and value.
/// The active Claude account always shows; Codex joins when it runs low but isn't used up.
struct MenuBarLabel: View {
    let model = AppModel.shared

    var body: some View {
        Image(nsImage: render())
            .accessibilityLabel(accessibility)
    }

    private var items: [UsageLine] {
        var lines: [UsageLine] = []
        if let claude = model.activeClaude, let line = tightest(claude) { lines.append(line) }
        // As in OpenUsage, a used-up limit never takes menu bar room; its card shows it.
        if let codex = model.activeCodex, !codex.isBlocked, let line = tightest(codex), line.usedPct >= 70 { lines.append(line) }
        return lines
    }

    private func tightest(_ account: Account) -> UsageLine? {
        account.relevantWindows.map { UsageLine(account: account, window: $0) }.max { $0.usedPct < $1.usedPct }
    }

    private var accessibility: String {
        let parts = items.map { "\($0.account.title) \($0.title) \(UsageText.amount($0))\($0.account.stale ? ", last known" : "")" }
        return (["ZipSwap"] + parts).joined(separator: ", ")
    }

    @MainActor
    private func render() -> NSImage {
        let renderer = ImageRenderer(content: strip)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        // A template image: the system draws it for light, dark and tinted menu bars.
        image.isTemplate = true
        return image
    }

    private var strip: some View {
        HStack(spacing: 9) {
            if items.isEmpty || model.isFlashing {
                SwapGlyph(size: 16, color: .black)
            }
            ForEach(items) { item in
                HStack(spacing: 4) {
                    mark(item)
                    VStack(alignment: .leading, spacing: -2) {
                        Text(item.title).font(.system(size: 9, weight: .medium))
                        Text(UsageText.value(item)).font(.system(size: 11, weight: .bold))
                    }
                    .fixedSize()
                }
                .opacity(item.account.stale ? 0.45 : 1)
            }
        }
        .foregroundStyle(.black)
        .monospacedDigit()
        .padding(.horizontal, 2)
        .padding(.vertical, 1)
        .fixedSize()
        .compositingGroup()
    }

    @ViewBuilder
    private func mark(_ item: UsageLine) -> some View {
        let siblings = (item.account.provider == .claude ? model.claude : model.codex).count
        let glyph = ProviderMark(provider: item.account.provider, size: 16, style: AnyShapeStyle(Color.black))
        if siblings > 1 {
            glyph
                .overlay(alignment: .bottomTrailing) {
                    AccountBadge(text: item.account.initial).offset(x: 5, y: 2.5)
                }
                .compositingGroup()
                .padding(.trailing, 5)
                .padding(.vertical, 2.5)
        } else {
            glyph
        }
    }
}

/// An account's initial, punched out of its menu bar mark (OpenUsage, MIT).
struct AccountBadge: View {
    let text: String

    var body: some View {
        ZStack {
            Capsule().fill(Color.black).padding(-1.25).blendMode(.destinationOut)
            Capsule().fill(Color.black)
            Text(text)
                .font(.system(size: 6.5, weight: .heavy))
                .padding(.horizontal, 2)
                .frame(minWidth: 8, minHeight: 8)
                .foregroundStyle(Color.black)
                .blendMode(.destinationOut)
        }
        .fixedSize()
    }
}
