import SwiftUI

enum Theme {
    static let bg = Color(hex: 0x131417)
    static let sunken = Color(hex: 0x101113)
    static let card = Color(hex: 0x1A1C20)
    static let cardBorder = Color(hex: 0x262930)
    static let inset = Color(hex: 0x15171A)
    static let hover = Color(hex: 0x1D1F24)
    static let track = Color(hex: 0x2A2D34)
    static let line = Color(hex: 0x22242A)
    static let text = Color(hex: 0xECEDEF)
    static let text2 = Color(hex: 0xC4C6CC)
    static let muted = Color(hex: 0x8E919A)
    static let faint = Color(hex: 0x9296A1)
    static let mint = Color(hex: 0x7CE0B5)
    static let amber = Color(hex: 0xF5A524)
    static let coral = Color(hex: 0xFF6B5E)
    static let blue = Color(hex: 0x8AB4FF)
    static let violet = Color(hex: 0xC9A7FF)
    static let claudeMark = Color(hex: 0xD9A27C)
    static let codexMark = Color(hex: 0x8AB4FF)

    static let avatarHues: [Color] = [mint, blue, violet, Color(hex: 0xF5B94F), Color(hex: 0xF29CB7), Color(hex: 0x7FD1E8)]

    static func tone(_ pct: Double) -> Color {
        pct >= 90 ? coral : pct >= 70 ? amber : mint
    }

    static func hue(for id: String) -> Color {
        let sum = id.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return avatarHues[sum % avatarHues.count]
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
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
