import SwiftUI
import UIKit
import Combine

@Observable
final class ThemeManager {
    static let shared = ThemeManager()

    // MARK: - Accent Color

    enum AccentPreset: String, CaseIterable, Identifiable, Sendable {
        case ghost = "ghost"
        case cyber = "cyber"
        case neon = "neon"
        case coral = "coral"
        case solar = "solar"
        case acid = "acid"
        case gold = "gold"
        case ice = "ice"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .ghost: return "ghost"
            case .cyber: return "cyber"
            case .neon: return "neon"
            case .coral: return "coral"
            case .solar: return "solar"
            case .acid: return "acid"
            case .gold: return "gold"
            case .ice: return "ice"
            }
        }

        var color: Color {
            switch self {
            case .ghost: return Color(hex: "ffffff")
            case .cyber: return Color(hex: "00d4ff")
            case .neon: return Color(hex: "bb86fc")
            case .coral: return Color(hex: "ff6b8a")
            case .solar: return Color(hex: "ff9f43")
            case .acid: return Color(hex: "a8e06c")
            case .gold: return Color(hex: "ffd700")
            case .ice: return Color(hex: "88c8f7")
            }
        }

        var emoji: String {
            switch self {
            case .ghost: return "👻"
            case .cyber: return "⚡"
            case .neon: return "🔮"
            case .coral: return "🪸"
            case .solar: return "☀️"
            case .acid: return "🧪"
            case .gold: return "✨"
            case .ice: return "🧊"
            }
        }
    }

    // MARK: - Font Design

    enum FontDesign: String, CaseIterable, Identifiable, Sendable {
        case monospaced
        case rounded
        case serif
        case system

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .monospaced: return "terminal"
            case .rounded: return "friendly"
            case .serif: return "editorial"
            case .system: return "clean"
            }
        }

        var swiftUIDesign: Font.Design {
            switch self {
            case .monospaced: return .monospaced
            case .rounded: return .rounded
            case .serif: return .serif
            case .system: return .default
            }
        }

        var emoji: String {
            switch self {
            case .monospaced: return ">"
            case .rounded: return "○"
            case .serif: return "T"
            case .system: return "A"
            }
        }
    }

    // MARK: - Cursor Style (fun)

    enum CursorStyle: String, CaseIterable, Identifiable, Sendable {
        case block
        case underscore
        case beam

        var id: String { rawValue }

        var displayName: String { rawValue }

        var symbol: String {
            switch self {
            case .block: return "▊"
            case .underscore: return "_"
            case .beam: return "|"
            }
        }
    }

    // MARK: - Appearance Mode

    enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
        case dark
        case light
        case system

        var id: String { rawValue }

        var displayName: String { rawValue }
    }

    // MARK: - Stored Properties

    var appearanceMode: AppearanceMode {
        didSet {
            UserDefaults.standard.set(appearanceMode.rawValue, forKey: "theme_appearance")
            applyAppearance()
        }
    }
    var accentPreset: AccentPreset {
        didSet { UserDefaults.standard.set(accentPreset.rawValue, forKey: "theme_accent") }
    }
    var fontDesign: FontDesign {
        didSet { UserDefaults.standard.set(fontDesign.rawValue, forKey: "theme_font") }
    }
    var cursorStyle: CursorStyle {
        didSet { UserDefaults.standard.set(cursorStyle.rawValue, forKey: "theme_cursor") }
    }
    var hapticsEnabled: Bool {
        didSet { UserDefaults.standard.set(hapticsEnabled, forKey: "theme_haptics") }
    }
    var compactMode: Bool {
        didSet { UserDefaults.standard.set(compactMode, forKey: "theme_compact") }
    }
    var showTerminalGreeting: Bool {
        didSet { UserDefaults.standard.set(showTerminalGreeting, forKey: "theme_greeting") }
    }

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Computed

    var accentColor: Color { accentPreset.color }

    var currentFontDesign: Font.Design { fontDesign.swiftUIDesign }

    var preferredScheme: ColorScheme? {
        switch appearanceMode {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }

    func font(_ style: Font.TextStyle = .body) -> Font {
        Font.system(style, design: fontDesign.swiftUIDesign)
    }

    func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.system(size: size, weight: weight, design: fontDesign.swiftUIDesign)
    }

    // MARK: - Init

    private init() {
        let appearance = UserDefaults.standard.string(forKey: "theme_appearance") ?? "dark"
        self.appearanceMode = AppearanceMode(rawValue: appearance) ?? .dark

        let accent = UserDefaults.standard.string(forKey: "theme_accent") ?? "ghost"
        self.accentPreset = AccentPreset(rawValue: accent) ?? .ghost

        let font = UserDefaults.standard.string(forKey: "theme_font") ?? "monospaced"
        self.fontDesign = FontDesign(rawValue: font) ?? .monospaced

        let cursor = UserDefaults.standard.string(forKey: "theme_cursor") ?? "block"
        self.cursorStyle = CursorStyle(rawValue: cursor) ?? .block

        self.hapticsEnabled = UserDefaults.standard.object(forKey: "theme_haptics") as? Bool ?? true
        self.compactMode = UserDefaults.standard.object(forKey: "theme_compact") as? Bool ?? false
        self.showTerminalGreeting = UserDefaults.standard.object(forKey: "theme_greeting") as? Bool ?? true

        // Apply appearance when windows are ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.applyAppearance()
        }

        // Also observe scene connection to apply on late-loading windows
        NotificationCenter.default.publisher(for: UIScene.didActivateNotification)
            .sink { [weak self] _ in self?.applyAppearance() }
            .store(in: &cancellables)
    }

    func applyAppearance() {
        let style: UIUserInterfaceStyle = {
            switch appearanceMode {
            case .dark: return .dark
            case .light: return .light
            case .system: return .unspecified
            }
        }()

        DispatchQueue.main.async {
            for scene in UIApplication.shared.connectedScenes {
                guard let windowScene = scene as? UIWindowScene else { continue }
                for window in windowScene.windows {
                    window.overrideUserInterfaceStyle = style
                }
            }
        }
    }
}
