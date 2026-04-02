import SwiftUI

enum TarsyTheme {
    // Backgrounds
    static let backgroundPrimary = Color(hex: "0a0a0a")
    static let backgroundSecondary = Color(hex: "111111")
    static let backgroundTertiary = Color(hex: "222222")

    // Text
    static let textPrimary = Color(hex: "ededed")
    static let textSecondary = Color(hex: "666666")
    static let textAccent = Color(hex: "ffffff")

    // Accents
    static let accentAmber = Color(hex: "ffffff")
    static let accentTerracotta = Color(hex: "888888")
    static let accentMoss = Color(hex: "b0b0b0")

    // Status
    static let statusRunning = Color(hex: "b0b0b0")
    static let statusStarting = Color(hex: "ffffff")
    static let statusIdle = Color(hex: "555555")
    static let statusError = Color(hex: "888888")

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
