import SwiftUI

enum TarsyTheme {
    // Backgrounds — adaptive via asset catalog (dark/light variants)
    static let backgroundPrimary = Color("bgPrimary")
    static let backgroundSecondary = Color("bgSecondary")
    static let backgroundTertiary = Color("bgTertiary")

    // Text — adaptive via asset catalog
    static let textPrimary = Color("textPrimary")
    static let textSecondary = Color("textSecondary")
    static let textAccent = Color("textAccent")

    // Accents — dynamic via ThemeManager
    static var accentAmber: Color { ThemeManager.shared.accentColor }
    static let accentTerracotta = Color(hex: "e5716a")
    static let accentMoss = Color(hex: "6bc77b")

    // Status
    static let statusRunning = Color(hex: "6bc77b")
    static let statusStarting = Color(hex: "e0a86a")
    static let statusIdle = Color(hex: "52525b")
    static let statusError = Color(hex: "e5716a")

    // Fonts — dynamic via ThemeManager
    static var monoFont: Font { Font.system(.body, design: ThemeManager.shared.currentFontDesign) }
    static var monoFontSmall: Font { Font.system(.caption, design: ThemeManager.shared.currentFontDesign) }
    static var monoFontLarge: Font { Font.system(.title3, design: ThemeManager.shared.currentFontDesign) }

    // Aliases
    static var bodyFont: Font { monoFont }
    static var bodyFontSmall: Font { monoFontSmall }
    static var bodyFontLarge: Font { monoFontLarge }

    /// Central font factory
    static func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.system(size: size, weight: weight, design: ThemeManager.shared.currentFontDesign)
    }
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
