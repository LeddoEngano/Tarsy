import Foundation

public enum AIEngineType: String, Codable, Sendable, CaseIterable {
    case claude
    case gemini
    case codex
    case aider
    case custom

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .gemini: return "Gemini CLI"
        case .codex: return "Codex CLI"
        case .aider: return "Aider"
        case .custom: return "Custom"
        }
    }

    public var iconName: String {
        switch self {
        case .claude: return "brain.head.profile"
        case .gemini: return "sparkles"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .aider: return "wrench.and.screwdriver"
        case .custom: return "terminal"
        }
    }

    public var defaultCommand: String? {
        switch self {
        case .claude: return nil // handled specially
        case .gemini: return "gemini"
        case .codex: return "codex"
        case .aider: return "aider"
        case .custom: return nil
        }
    }

    public var envKeyName: String? {
        switch self {
        case .claude: return "ANTHROPIC_API_KEY"
        case .gemini: return "GOOGLE_API_KEY"
        case .codex: return "OPENAI_API_KEY"
        case .aider: return nil // uses provider keys
        case .custom: return nil
        }
    }
}
