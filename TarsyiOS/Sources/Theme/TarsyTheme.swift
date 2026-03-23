import SwiftUI

enum TarsyTheme {
    // Backgrounds
    static let backgroundPrimary = Color(hex: "1a1a1a")
    static let backgroundSecondary = Color(hex: "2a2a2a")
    static let backgroundTertiary = Color(hex: "3a3a3a")

    // Text
    static let textPrimary = Color(hex: "e8e0d4")
    static let textSecondary = Color(hex: "a89e91")
    static let textAccent = Color(hex: "d4a574")

    // Accents
    static let accentAmber = Color(hex: "d4a574")
    static let accentTerracotta = Color(hex: "c4704b")
    static let accentMoss = Color(hex: "7a8b6f")

    // Status
    static let statusRunning = Color(hex: "7a8b6f")
    static let statusStarting = Color(hex: "d4a574")
    static let statusIdle = Color(hex: "6b6b6b")
    static let statusError = Color(hex: "c4704b")

    // Fonts
    static let monoFont = Font.system(.body, design: .monospaced)
    static let monoFontSmall = Font.system(.caption, design: .monospaced)
    static let monoFontLarge = Font.system(.title3, design: .monospaced)
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 6:
            (a, r, g, b) = (255, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = ((int >> 24) & 0xFF, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
