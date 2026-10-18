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
            w.backgroundColor = NSColor(srgbRed: 0x13 / 255, green: 0x14 / 255, blue: 0x17 / 255, alpha: 1)
            w.appearance = NSAppearance(named: .darkAqua)
            w.contentMinSize = NSSize(width: 980, height: 680)
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

/// The menu bar item: glyph, active Claude account with 5h and weekly use,
/// then Codex weekly use. Rendered to an image so the numbers can carry color.
struct MenuBarLabel: View {
    let model = AppModel.shared

    var body: some View {
        Image(nsImage: render())
            .accessibilityLabel(accessibility)
    }

    private var accessibility: String {
        guard let c = model.activeClaude else { return "ZipSwap" }
        let five = c.fiveHour.map { Format.pct($0.pct) } ?? "unknown"
        let week = c.weekly.map { Format.pct($0.pct) } ?? "unknown"
        return "ZipSwap, \(c.title): 5-hour \(five), weekly \(week)"
    }

    @MainActor
    private func render() -> NSImage {
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        // Healthy: a template image the system tints for light or dark menu bars.
        // Warnings and fresh switches keep their color.
        image.isTemplate = !needsColor
        return image
    }

    private var worst: Double {
        let c = model.activeClaude
        return max(c?.fiveHour?.pct ?? 0, c?.weekly?.pct ?? 0)
    }

    private var needsColor: Bool { model.isFlashing || worst >= 70 }

    private var content: some View {
        let flashing = model.isFlashing
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let base: Color = needsColor ? (dark ? .white.opacity(0.9) : .black.opacity(0.85)) : .black
        let claude = model.activeClaude
        return HStack(spacing: 5) {
            SwapGlyph(size: 15, color: flashing ? Theme.mint : glyphColor(base))
            if let claude {
                number(claude.fiveHour, base: base, flashing: flashing)
                Circle().fill(base.opacity(0.45)).frame(width: 2.5, height: 2.5)
                number(claude.weekly, base: base, flashing: flashing)
            }
        }
        .padding(.horizontal, 2)
        .frame(height: 18)
    }

    private func number(_ window: UsageWindow?, base: Color, flashing: Bool) -> some View {
        let pct = window?.pct ?? 0
        return Text(window.map { Format.pct($0.pct) } ?? "–")
            .font(.system(size: 12, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(flashing ? Theme.mint : (pct >= 70 ? numberColor(pct) : base))
    }

    private func numberColor(_ pct: Double) -> Color {
        if pct >= 90 { return Color(hex: 0xFF6B5E) }
        if pct >= 70 { return Color(hex: 0xE8960C) }
        return needsColor ? Color.gray : Color.black.opacity(0.6)
    }

    private func glyphColor(_ base: Color) -> Color {
        worst >= 90 ? Color(hex: 0xFF6B5E) : base
    }
}
