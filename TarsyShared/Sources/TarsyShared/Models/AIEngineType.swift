import Foundation

public enum AIEngineType: String, Codable, Sendable, CaseIterable {
    case claude
    case gemini
    case codex
    case aider
    case cursor
    case windsurf
    case amp
    case cline
    case copilot
    case custom

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .gemini: return "Gemini CLI"
        case .codex: return "Codex CLI"
        case .aider: return "Aider"
        case .cursor: return "Cursor CLI"
        case .windsurf: return "Windsurf CLI"
        case .amp: return "Amp"
        case .cline: return "Cline"
        case .copilot: return "Copilot CLI"
        case .custom: return "Custom"
        }
    }

    /// SF Symbol name (fallback icon)
    public var iconName: String {
        switch self {
        case .claude: return "brain.head.profile"
        case .gemini: return "sparkles"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .aider: return "wrench.and.screwdriver"
        case .cursor: return "cursorarrow.rays"
        case .windsurf: return "wind"
        case .amp: return "bolt.fill"
        case .cline: return "command.circle"
        case .copilot: return "airplane"
        case .custom: return "terminal"
        }
    }

    /// Asset Catalog image name (nil = use SF Symbol fallback)
    public var iconAsset: String? {
        switch self {
        case .claude: return "ClaudeIcon"
        case .gemini: return "GeminiIcon"
        case .codex: return "CodexIcon"
        case .aider: return "AiderIcon"
        case .cursor: return "CursorIcon"
        case .windsurf: return "WindsurfIcon"
        case .amp: return "AmpIcon"
        case .cline: return "ClineIcon"
        case .copilot: return "CopilotIcon"
        case .custom: return nil
        }
    }

    public var defaultCommand: String? {
        switch self {
        case .claude: return nil // handled specially
        case .gemini: return "gemini"
        case .codex: return "codex"
        case .aider: return "aider"
        case .cursor: return "cursor"
        case .windsurf: return "windsurf"
        case .amp: return "amp"
        case .cline: return "cline"
        case .copilot: return "gh"
        case .custom: return nil
        }
    }

    /// The binary name used for path detection (covers engines where defaultCommand is nil).
    public var primaryBinaryName: String? {
        switch self {
        case .claude: return "claude"
        case .gemini: return "gemini"
        case .codex: return "codex"
        case .aider: return "aider"
        case .cursor: return "cursor"
        case .windsurf: return "windsurf"
        case .amp: return "amp"
        case .cline: return "cline"
        case .copilot: return "gh"
        case .custom: return nil
        }
    }

    public var envKeyName: String? {
        switch self {
        case .claude: return "ANTHROPIC_API_KEY"
        case .gemini: return "GOOGLE_API_KEY"
        case .codex: return "OPENAI_API_KEY"
        case .aider: return nil // uses provider keys
        case .cursor: return nil
        case .windsurf: return nil
        case .amp: return nil
        case .cline: return nil
        case .copilot: return nil
        case .custom: return nil
        }
    }

    /// Whether this engine uses a dedicated session handler (vs GenericCLIEngine).
    public var usesDedicatedSession: Bool {
        self == .claude || self == .gemini
    }

    /// Random fun ready message shown when the engine starts.
    public var readyMessage: String {
        let name = displayName
        let messages = [
            "\(name) locked and loaded. What are we building?",
            "Your AI minion is ready. Command me, master.",
            "\(name) online. Let's write some beautiful code.",
            "Reporting for duty. Coffee not required (for me at least).",
            "\(name) initialized. Time to make some magic happen.",
            "Ready to rock. Just don't ask me to center a div... kidding, I got this.",
            "System online. Brain at 100%. Humility at 12%. Let's go.",
            "\(name) at your service. No bugs were harmed... yet.",
            "Connected and caffeinated (metaphorically). What's the mission?",
            "All systems go. Warning: may produce unreasonably good code.",
            "\(name) is up. Let's write some code!",
            "Engines on. Seatbelts fastened. Destination: production.",
            "I'm here, I'm ready, and I have mass opinions about tabs vs spaces.",
            "\(name) activated. Today's forecast: 100% chance of shipping.",
            "Online and dangerously motivated. What are we breaking... I mean building?",
        ]
        return messages.randomElement()!
    }

    /// Whether this engine supports MCP (Model Context Protocol) servers.
    public var supportsMCP: Bool {
        switch self {
        case .claude, .gemini, .cursor, .windsurf, .amp, .cline, .copilot:
            return true
        case .codex, .aider, .custom:
            return false
        }
    }
}
