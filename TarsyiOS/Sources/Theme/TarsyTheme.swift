import SwiftUI

enum TarsyTheme {
    // Backgrounds
    static let backgroundPrimary = Color(hex: "131316")
    static let backgroundSecondary = Color(hex: "1c1c21")
    static let backgroundTertiary = Color(hex: "2a2a30")

    // Text
    static let textPrimary = Color(hex: "e4e4e7")
    static let textSecondary = Color(hex: "71717a")
    static let textAccent = Color(hex: "ffffff")

    // Accents
    static let accentAmber = Color(hex: "ffffff")
    static let accentTerracotta = Color(hex: "e5716a")
    static let accentMoss = Color(hex: "6bc77b")

    // Status
    static let statusRunning = Color(hex: "6bc77b")
    static let statusStarting = Color(hex: "e0a86a")
    static let statusIdle = Color(hex: "52525b")
    static let statusError = Color(hex: "e5716a")

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
