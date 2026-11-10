import AppKit
import SwiftUI

/// System colours that follow light and dark mode, after OpenUsage's panel
/// (MIT, Robin Ebers; see THIRD_PARTY_NOTICES.md).
enum Theme {
    // Surfaces
    static let bg = Color(nsColor: .windowBackgroundColor)
    static let sunken = adaptive(light: NSColor(white: 0, alpha: 0.035), dark: NSColor(white: 0, alpha: 0.18))
    static let card = Color(nsColor: .quaternarySystemFill)
    static let cardBorder = adaptive(light: NSColor(white: 0, alpha: 0.05), dark: NSColor(white: 1, alpha: 0.06))
    static let hairline = cardBorder
    static let inset = Color(nsColor: .quaternarySystemFill)
    static let hover = adaptive(light: NSColor(white: 0, alpha: 0.05), dark: NSColor(white: 1, alpha: 0.07))
    static let selected = adaptive(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.1))
    static let track = adaptive(light: NSColor(white: 0, alpha: 0.09), dark: NSColor(white: 1, alpha: 0.12))
    static let line = Color(nsColor: .separatorColor)
    static let controlFill = adaptive(light: NSColor(white: 0, alpha: 0.06), dark: NSColor(white: 1, alpha: 0.1))
    static let segmentThumb = adaptive(light: .white, dark: NSColor(white: 1, alpha: 0.18))
    static let skeleton = adaptive(light: NSColor(white: 0, alpha: 0.075), dark: NSColor(white: 1, alpha: 0.086))

    // Text
    static let text = Color(nsColor: .labelColor)
    static let text2 = Color(nsColor: .secondaryLabelColor)
    static let muted = Color(nsColor: .secondaryLabelColor)
    static let faint = Color(nsColor: .tertiaryLabelColor)
    /// Text drawn on an accent fill.
    static let onAccent = Color.white

    // Meaning
    static let accent = Color(nsColor: .systemBlue)
    static let positive = Color(nsColor: .systemGreen)
    static let mint = positive
    static let blue = accent
    static let amber = Color(nsColor: .systemOrange)
    static let coral = Color(nsColor: .systemRed)
    static let violet = Color(nsColor: .systemPurple)
    static let claudeMark = Color(nsColor: .systemOrange)
    static let codexMark = Color(nsColor: .systemBlue)

    static let avatarHues: [Color] = [.green, .blue, .purple, .orange, .pink, .teal].map { $0 }

    enum Severity: Equatable { case normal, warning, critical }

    /// OpenUsage's rule: 30% or less left warns, 10% or less is critical.
    static func severity(_ usedPct: Double) -> Severity {
        usedPct >= 90 ? .critical : usedPct >= 70 ? .warning : .normal
    }

    static func severityColor(_ severity: Severity) -> Color {
        switch severity {
        case .normal: accent
        case .warning: amber
        case .critical: coral
        }
    }

    /// Severity colours dark enough to read as small text on a light panel.
    static func severityText(_ severity: Severity) -> Color {
        switch severity {
        case .normal: text
        case .warning: adaptive(light: NSColor(red: 0.7, green: 0.37, blue: 0, alpha: 1), dark: .systemOrange)
        case .critical: adaptive(light: NSColor(red: 0.84, green: 0, blue: 0.08, alpha: 1), dark: .systemRed)
        }
    }

    static func tone(_ pct: Double) -> Color { severityColor(severity(pct)) }

    static func hue(for id: String) -> Color {
        let sum = id.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return avatarHues[sum % avatarHues.count]
    }

    /// Equal-width digits in the system face, so changing numbers never shift a row.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }

    static let cardCornerRadius: CGFloat = 12
    static var cardShape: RoundedRectangle { RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous) }

    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

enum PanelMetrics {
    static let width: CGFloat = 340
    static let margin: CGFloat = 12
    static let cardPadding: CGFloat = 12
    static let rowHeight: CGFloat = 22
    static let labelWidth: CGFloat = 72
    static let valueWidth: CGFloat = 40
    static let resetWidth: CGFloat = 60
    static let gaugeSide: CGFloat = 32
    static let cardWidth: CGFloat = 320
    static let cardGap: CGFloat = 12
    static let maxColumns = 3

    /// All Usage lays accounts out side by side so none are cut off or hidden
    /// behind a scroll; the panel widens by one card per column.
    static func columns(accounts: Int) -> Int { min(maxColumns, max(1, accounts)) }
    static func width(for tab: PanelTab, accounts: Int) -> CGFloat {
        guard tab == .allUsage else { return width }
        let n = CGFloat(columns(accounts: accounts))
        return max(width, n * cardWidth + (n - 1) * cardGap + 2 * margin)
    }
}

extension View {
    func cardSurface() -> some View {
        background {
            Theme.cardShape
                .fill(Theme.card)
                .overlay { Theme.cardShape.strokeBorder(Theme.hairline, lineWidth: 0.5) }
        }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}
